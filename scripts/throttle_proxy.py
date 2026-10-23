#!/usr/bin/env python3
"""A local proxy that carries the app's connections over a slow link (a
profile's link half, slow_link.py), to see a real server through a bad
network.

    python3 scripts/throttle_proxy.py 8859 worst [seed]

HTTPS comes as CONNECT: a tunnel the TLS goes through untouched, so the
proxy never sees a request or a key. The tunnel waits the link's handshakes
before it opens, everything the app sends arrives a round trip late, and
what comes back goes at the link's pace, with its stalls; at the network
change every tunnel is dropped at once. The server half is the server's
own: the real one's, or the test server's profile (with link=none, so the
link is carried once). Plain HTTP (the test server) comes as requests, each
a round trip late and its connection's first the handshakes too.

Prints counts only, at the end: never a host, an address or a request.
"""

import os
import signal
import socket
import struct
import sys
import threading
import time
from collections import deque
from urllib.parse import urlsplit

from slow_link import Link

TOTALS = {"tunnels": 0, "requests": 0, "playlists": 0, "segments": 0, "failed": 0, "down": 0, "up": 0}
FAILURES = set()
LOCK = threading.Lock()
OPEN = set()


def count(key, n=1):
    with LOCK:
        TOTALS[key] += n


class Reader:
    def __init__(self, sock):
        self.sock, self.buffer = sock, b""

    def more(self):
        data = self.sock.recv(65536)
        if not data:
            raise EOFError
        self.buffer += data

    def head(self):
        while b"\r\n\r\n" not in self.buffer:
            self.more()
        head, self.buffer = self.buffer.split(b"\r\n\r\n", 1)
        return head + b"\r\n\r\n"

    def exactly(self, n):
        while len(self.buffer) < n:
            self.more()
        data, self.buffer = self.buffer[:n], self.buffer[n:]
        return data

    def rest(self):
        data, self.buffer = self.buffer, b""
        return data or self.sock.recv(65536)


def serve(client, link):
    connection = link.connection()
    try:
        reader = Reader(client)
        head = reader.head()
        method, target, _ = head.split(b"\r\n", 1)[0].split(b" ", 2)
        tunnel = method == b"CONNECT"
        if tunnel:
            host, _, port = target.decode().rpartition(":")
            server = (host.strip("[]"), int(port))
        else:
            origin = urlsplit(target.decode())
            server = (origin.hostname, origin.port or 80)
            if origin.hostname not in ("127.0.0.1", "localhost", "::1"):
                raise PermissionError("plain HTTP to a real server would carry the key in clear")
        upstream = socket.create_connection(server, timeout=30)
        upstream.settimeout(None)
    except Exception as error:
        count("failed")
        FAILURES.add(type(error).__name__)
        client.close()
        return
    down = threading.Thread(target=pump_down, args=(upstream, client, connection), daemon=True)
    with LOCK:
        OPEN.update((client, upstream))
    try:
        if tunnel:
            time.sleep(connection.handshake())
            client.sendall(b"HTTP/1.1 200 Connection established\r\n\r\n")
            count("tunnels")
            down.start()
            delay_up(reader, upstream, connection.round_trip)
        else:
            down.start()
            forward(reader, head, upstream, connection, server)
        down.join()
    except (OSError, EOFError):
        pass
    finally:
        with LOCK:
            OPEN.difference_update((client, upstream))
        for sock in (client, upstream):
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            sock.close()


def drop_all():
    """The network change: every open connection dropped at once."""
    with LOCK:
        dropped = list(OPEN)
    for sock in dropped:
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass


def forward(reader, head, upstream, connection, server):
    """Plain HTTP, one request at a time, each held as the link says."""
    while True:
        line, fields = head.split(b"\r\n", 1)
        method, target, version = line.split(b" ", 2)
        origin = urlsplit(target.decode())
        if (origin.hostname, origin.port or 80) != server:
            raise ConnectionRefusedError
        path = (origin.path or "/") + (f"?{origin.query}" if origin.query else "")
        length = next((int(f.split(b":", 1)[1]) for f in fields.split(b"\r\n") if f.lower().startswith(b"content-length:")), 0)
        body = reader.exactly(length)
        time.sleep(connection.wait_before_answer())
        upstream.sendall(b" ".join([method, path.encode(), version]) + b"\r\n" + fields + body)
        count("requests")
        count("playlists", origin.path.endswith(".m3u8"))
        count("segments", origin.path.endswith(".ts"))
        count("up", len(head) + length)
        try:
            head = reader.head()
        except EOFError:
            upstream.shutdown(socket.SHUT_WR)
            return


def pump_down(upstream, client, connection):
    try:
        while True:
            data = upstream.recv(65536)
            if not data:
                break
            connection.send(client.sendall, data)
            count("down", len(data))
        client.shutdown(socket.SHUT_WR)
    except OSError:
        pass


def delay_up(reader, upstream, delay):
    """What the app sends, each piece a round trip (`delay()`) after it came."""
    line, ready = deque(), threading.Condition()

    def send():
        while True:
            with ready:
                while not line:
                    ready.wait()
                due, data = line.popleft()
            if data is None:
                upstream.shutdown(socket.SHUT_WR)
                return
            time.sleep(max(0.0, due - time.monotonic()))
            upstream.sendall(data)
            count("up", len(data))

    sender = threading.Thread(target=send, daemon=True)
    sender.start()
    try:
        while True:
            data = reader.rest()
            with ready:
                line.append((time.monotonic() + delay(), data or None))
                ready.notify()
            if not data:
                break
    finally:
        with ready:
            line.append((time.monotonic(), None))
            ready.notify()
        sender.join()


def main():
    port, name = int(sys.argv[1]), sys.argv[2]
    seed = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    link = Link(name, seed, on_change=drop_all)

    def stop(*_):
        done = link.readout()
        print(f"proxy {name}: {TOTALS['tunnels']} tunnels, {TOTALS['requests']} plain requests "
              f"({TOTALS['playlists']} playlists, {TOTALS['segments']} segments), "
              f"{TOTALS['down'] / 1e6:.1f} MB down, {TOTALS['up'] / 1e6:.1f} MB up, {TOTALS['failed']} failed "
              f"({', '.join(sorted(FAILURES)) or 'none'}) | link {done['mb_s'] or '-'} MB/s while carrying data, "
              f"{done['stalls']} stalls ({done['stalled_s']} s waited), {done['changes']} network changes", flush=True)
        os._exit(0)

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    listener = socket.create_server(("127.0.0.1", port))
    print(f"proxy {name} ready, seed {seed}", flush=True)
    while True:
        client, _ = listener.accept()
        threading.Thread(target=serve, args=(client, link), daemon=True).start()


if __name__ == "__main__":
    main()

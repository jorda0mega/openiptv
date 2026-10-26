#!/usr/bin/env python3
"""What a slow-network profile does, measured from outside: a new
connection's cost, the round trip, a media answer's first byte, the plan's
answer (PlaybackInfo), and the film's pace on one connection and on four,
with its stalls. Numbers only.

    python3 scripts/net_profile_check.py 8858 [--proxy 8859] [--seconds 20] [--events]

Asks the test server on that local port (its film and its own account),
directly or through the throttling proxy on the other. --events (the test
server only) also meets the link's network change and its first two offline
windows: it takes the profile again begun just before each (/mock/profile's
ago), so none is waited for.
"""

import argparse
import http.client
import json
import socket
import statistics
import threading
import time
import urllib.request

HEADERS = {"X-Emby-Token": "tok", "User-Agent": "Openreel/check"}
GAP = 0.4


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("server", type=int)
    parser.add_argument("--proxy", type=int)
    parser.add_argument("--seconds", type=float, default=20)
    parser.add_argument("--events", action="store_true")
    args = parser.parse_args()

    def connect():
        return http.client.HTTPConnection("127.0.0.1", args.proxy or args.server, timeout=120)

    def ask(connection, path, headers=None, method="GET"):
        """Seconds to the answer's first byte; the body is read and dropped."""
        asked = time.monotonic()
        connection.request(method, f"http://127.0.0.1:{args.server}{path}" if args.proxy else path,
                           headers={**HEADERS, **(headers or {})})
        answer = connection.getresponse()
        waited = time.monotonic() - asked
        answer.read()
        return waited

    info = "/emby/System/Info/Public"
    film = "/emby/Videos/m1/stream?Static=true"
    fresh, again = [], []
    for _ in range(5):
        connection = connect()
        fresh.append(ask(connection, info))
        again.append(ask(connection, info))
        connection.close()
    print(f"new connection: {statistics.median(fresh) - statistics.median(again):+.2f} s, "
          f"round trip: {statistics.median(again):.2f} s (median of 5)")

    connection = connect()
    ask(connection, info)
    waits, cut = [], 0
    for _ in range(4):
        try:
            waits.append(ask(connection, film, {"Range": "bytes=0-0"}) - statistics.median(again))
        except (http.client.HTTPException, OSError):
            cut += 1
            connection.close()
            connection = connect()
            ask(connection, info)
    connection.close()
    print("media first byte: " + ", ".join(f"{w:.1f}" for w in sorted(waits)) + " s (less the round trip)"
          + (f", {cut} cut short by the server's resets" if cut else ""))

    connection = connect()
    ask(connection, info)
    plans = [ask(connection, "/emby/Items/m7/PlaybackInfo", method="POST") - statistics.median(again) for _ in range(2)]
    connection.close()
    print("plan: " + ", ".join(f"{p:.1f}" for p in plans) + " s (less the round trip)")

    for count in (1, 4):
        print(pace(connect, film, count, args))

    if args.events and not args.proxy:
        events(args.server, connect, ask, info, film)


def control(port, path):
    with urllib.request.urlopen(f"http://127.0.0.1:{port}{path}", timeout=30) as answer:
        return json.loads(answer.read())


def events(port, connect, ask, info, film):
    net = control(port, "/mock/net")
    if net["profile"] == "none" and net.get("link", "none") == "none":
        return print("events: no profile")
    schedule = net["schedule"]

    def begin_at(second):
        control(port, f"/mock/profile?name={net['profile']}&link={net['link']}&seed={net['seed']}&ago={second}")
        return time.monotonic() - second

    if schedule["change_s"] is None:
        print("network change: none")
    else:
        began = begin_at(schedule["change_s"] - 20)
        dropped = []

        def hold():
            connection = connect()
            ask(connection, info)
            dropped.append(ended(connection.sock, timeout=40))

        holders = [threading.Thread(target=hold) for _ in range(3)]
        for holder in holders:
            holder.start()
        for holder in holders:
            holder.join()
        at = sorted(d - began for d in dropped if d is not None)
        print(f"network change: {len(at)} of 3 open connections dropped at "
              + ", ".join(f"{a:.1f}" for a in at) + f" s (due {schedule['change_s']:.1f} s)"
              + (", to a phone network" if schedule["metered_after_change"] else ""))
    for n, (start, end, kind) in enumerate(schedule["offline"][:2], 1):
        began = begin_at(start - 25)
        reading = connect()
        reading.request("GET", info, headers=HEADERS)
        reading.getresponse().read()
        reading.request("GET", film, headers={**HEADERS, "Range": "bytes=0-"})
        answer = reading.getresponse()
        arrivals = []

        def pull():
            try:
                while time.monotonic() - began < end + 8:
                    chunk = answer.read1(65536)
                    if not chunk:
                        break
                    arrivals.append(time.monotonic() - began)
            except OSError:
                pass
            arrivals.append(None)

        puller = threading.Thread(target=pull, daemon=True)
        puller.start()
        time.sleep(max(0.0, began + start + 2 - time.monotonic()))
        asked = time.monotonic() - began
        try:
            ask(connect(), info)
            fresh = f"answered {time.monotonic() - began - start:.1f} s after the window began"
        except OSError:
            fresh = f"refused {time.monotonic() - began - asked:.1f} s after it asked"
        puller.join(timeout=end - start + 40)
        reading.close()
        times = [a for a in arrivals if a is not None]
        gap = max(zip(times, times[1:]), key=lambda pair: pair[1] - pair[0], default=(0, 0))
        cut = arrivals[-1:] == [None] and times and times[-1] < end + 7
        print(f"offline {n} ({kind}, due {start:.1f}-{end:.1f} s, {end - start:.1f} s): the open read "
              + (f"stopped at {times[-1]:.1f} s" if cut else f"got nothing {gap[0]:.1f}-{gap[1]:.1f} s ({gap[1] - gap[0]:.1f} s)")
              + f"; a new connection {asked - start:.1f} s in {fresh}")
    control(port, f"/mock/profile?name={net['profile']}&link={net['link']}&seed={net['seed']}")


def ended(sock, timeout):
    """When the server ended an open connection (it reads nothing more from it), or None."""
    sock.settimeout(timeout)
    try:
        sock.recv(1)
    except socket.timeout:
        return None
    except OSError:
        pass
    return time.monotonic()


def pace(connect, film, count, args):
    arrivals = [[] for _ in range(count)]

    def pull(mine):
        connection = connect()
        path = f"http://127.0.0.1:{args.server}{film}" if args.proxy else film
        connection.request("GET", path, headers={**HEADERS, "Range": "bytes=0-"})
        answer = connection.getresponse()
        deadline = None
        while True:
            try:
                chunk = answer.read1(65536)
            except (http.client.HTTPException, OSError):
                break
            now = time.monotonic()
            if not chunk:
                break
            deadline = deadline or now + args.seconds
            mine.append((now, len(chunk)))
            if now >= deadline:
                break
        connection.close()

    threads = [threading.Thread(target=pull, args=(mine,)) for mine in arrivals]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    if any(len(mine) < 2 for mine in arrivals):
        return f"{count} connection(s): no data"
    merged = sorted(a for mine in arrivals for a in mine)
    # Each starts after its own first byte: the pace together is read
    # while all of them are reading.
    start, end = max(mine[0][0] for mine in arrivals), min(mine[-1][0] for mine in arrivals)
    span = end - start
    rate = sum(size for t, size in merged if start < t <= end) / span / 1e6
    each = [sum(size for _, size in mine[1:]) / (mine[-1][0] - mine[0][0]) / 1e6 for mine in arrivals]
    link_gaps = gaps(merged)
    connection_gaps = [g for mine in arrivals for g in gaps(mine)]
    flowing = rate * span / (span - sum(gaps([a for a in merged if start < a[0] <= end]))) if span else 0
    return (f"{count} connection(s): {rate:.2f} MB/s together over {span:.1f} s ({flowing:.2f} between stalls), each "
            + ", ".join(f"{r:.2f}" for r in each) + " MB/s; "
            + f"link stalls {len(link_gaps)} ({sum(link_gaps):.1f} s), "
            + f"connection stalls {len(connection_gaps)} ({sum(connection_gaps):.1f} s)")


def gaps(arrivals):
    return [b[0] - a[0] for a, b in zip(arrivals, arrivals[1:]) if b[0] - a[0] >= GAP]


if __name__ == "__main__":
    main()

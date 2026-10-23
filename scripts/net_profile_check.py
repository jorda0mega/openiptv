#!/usr/bin/env python3
"""What a slow-network profile does, measured from outside: a new
connection's cost, the round trip, a media answer's first byte, and the
film's pace on one connection and on four, with its stalls. Numbers only.

    python3 scripts/net_profile_check.py 8858 [--proxy 8859] [--seconds 20]

Asks the test server on that local port (its film and its own account),
directly or through the throttling proxy on the other.
"""

import argparse
import http.client
import statistics
import threading
import time

HEADERS = {"X-Emby-Token": "tok", "User-Agent": "Openreel/check"}
GAP = 0.4


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("server", type=int)
    parser.add_argument("--proxy", type=int)
    parser.add_argument("--seconds", type=float, default=20)
    args = parser.parse_args()

    def connect():
        return http.client.HTTPConnection("127.0.0.1", args.proxy or args.server, timeout=120)

    def ask(connection, path, headers=None):
        """Seconds to the answer's first byte; the body is read and dropped."""
        asked = time.monotonic()
        connection.request("GET", f"http://127.0.0.1:{args.server}{path}" if args.proxy else path,
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
    waits = sorted(ask(connection, film, {"Range": "bytes=0-0"}) - statistics.median(again) for _ in range(4))
    connection.close()
    print("media first byte: " + ", ".join(f"{w:.1f}" for w in waits) + " s (less the round trip)")

    for count in (1, 4):
        print(pace(connect, film, count, args))


def pace(connect, film, count, args):
    arrivals = [[] for _ in range(count)]

    def pull(mine):
        connection = connect()
        path = f"http://127.0.0.1:{args.server}{film}" if args.proxy else film
        connection.request("GET", path, headers={**HEADERS, "Range": "bytes=0-"})
        answer = connection.getresponse()
        deadline = None
        while True:
            chunk = answer.read1(65536)
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

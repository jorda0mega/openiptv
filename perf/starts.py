#!/usr/bin/env python3 -I
"""StartTimingTests' starts, each split where its time went, from its START lines.

    starts.py TEST.log...

A START line carries the app's own parts (debug-start-parts): the plan
(PlaybackInfo: "kept" when fetched ahead, "asked" when asked at the tap),
then the time to the open, the open (the file's first reads), and the
first frame after it; and the server's own state at that start (the first
file request's connect and first byte, the relay's slowest first byte, the
server's wait before the plan). Prints one waterfall line per start and, per kind,
the count, p50, p95 and max of tap to first frame, and of each part.
"""

import re
import sys

PARTS = [("plan", r"plan ([0-9.]+) s \((\w+)\)"), ("to open", r"then ([0-9.]+) s to the open"),
         ("open", r"open ([0-9.]+) s,"), ("first frame", r"first frame ([0-9.]+) s after")]


def pct(values, p):
    values = sorted(values)
    return values[min(len(values) - 1, round(p / 100 * (len(values) - 1)))]


def main(paths):
    kinds = {}
    for path in paths:
        for line in open(path, errors="replace"):
            m = re.match(r"START (\w+): ([0-9.]+) s(?: \(([^)]*)\))? \| (.*)", line.strip())
            if not m:
                continue
            kind, total, note, parts = m.group(1), float(m.group(2)), m.group(3), m.group(4)
            row = dict(total=total)
            shown = [f"{kind:12} {total:6.2f} s"]
            for name, pattern in PARTS:
                found = re.search(pattern, parts)
                if found:
                    row[name] = float(found.group(1))
                    shown.append(f"{name} {row[name]:.2f}" + (f" ({found.group(2)})" if name == "plan" else ""))
            # The server's own state at this start: the first file request's connect (TCP and TLS) and first byte,
            # the slowest first byte of the relay's reads, and the server's wait before the plan (PlaybackInfo).
            request = re.search(r"first request: queued \d+ ms, DNS \d+ ms, TCP (\d+) ms, TLS (\d+) ms, wait (\d+) ms", parts)
            relay = re.search(r"first byte up to (\d+) ms", parts)
            plan = re.search(r"copy \d+ item [0-9.]+ s \[sent [^,]+, queued [0-9.]+, connect [0-9.]+, wait ([0-9.]+)", parts)
            server = []
            if request:
                server.append(f"connect {int(request.group(1)) + int(request.group(2))} ms, first byte {request.group(3)} ms")
            if relay:
                server.append(f"slowest first byte {relay.group(1)} ms")
            if plan:
                server.append(f"plan wait {float(plan.group(1)):.2f} s")
            if server:
                shown.append("server: " + ", ".join(server))
            ahead = re.search(r"start ahead ([a-z ]+?)(?:[;,(]|$)", parts)
            if ahead:
                shown.append(f"start ahead {ahead.group(1).strip()}")
            if note:
                shown.append(note)
            print(" | ".join(shown))
            kinds.setdefault(kind, []).append(row)
    print()
    for kind, rows in kinds.items():
        line = [f"{kind:12} n={len(rows)}"]
        for name in ["total"] + [p for p, _ in PARTS]:
            values = [r[name] for r in rows if name in r]
            if values:
                line.append(f"{name} p50 {pct(values, 50):.2f} p95 {pct(values, 95):.2f} max {max(values):.2f} s")
        print(" | ".join(line))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

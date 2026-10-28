#!/usr/bin/env python3 -I
"""Each ±10 s tap of JumpTimingTests timed, from the app's log and a screen
recording of perf/make_jump_film.sh's film.

    jumps.py decode RECORDING.mp4 SERIES.json
    jumps.py time SERIES.json RECORDER.log TEST.log SEEKS.ndjson [--metric]

decode: each film frame carries its number in 14 blocks across its top and
bottom bands; SERIES.json holds (seconds into the recording, the number when
both bands agree, else null) on a 60 fps grid.

time: per tap, three parts. The tap to the app's seek, from the test's tap
time and the app's "PERF cache at" line (both on the Mac's clock). The seek
to libmpv's restart, the app's own "jumps" readout. And how long the picture
stood still: in the recording, from the last change of the old place to the
first frame of the new one (a jump of more than 5 s). The recorder drops
seconds when the Mac is busy, so its clock times only the stretch around
each jump, never the taps. Visible jumps pair with taps in order and
direction. Prints a line per tap and p50, p95 and max each way of the tap to
the new picture (tap to seek + picture stood still); --metric adds METRIC lines.
"""

import json
import os
import re
import subprocess
import sys
from datetime import datetime

FPS = 60
FILM_FPS = 24000 / 1001
LANDED = 5 * FILM_FPS


def decode(path):
    out = subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height",
                          "-of", "json", path], capture_output=True, text=True, check=True).stdout
    s = json.loads(out)["streams"][0]
    fw, fh = s["width"], s["width"] * 9 // 16
    top = (s["height"] - fh) // 2
    w, h = 384, 216
    raw = subprocess.run(["ffmpeg", "-v", "error", "-i", path, "-vf", f"fps={FPS},crop={fw}:{fh}:0:{top},scale={w}:{h}",
                          "-f", "rawvideo", "-pix_fmt", "gray", "-"], capture_output=True, check=True).stdout
    size, series = w * h, []
    for k in range(len(raw) // size):
        frame = raw[k * size:(k + 1) * size]

        def band(y):
            return sum(1 << b for b in range(14) if frame[int(y * h) * w + int((b * 137 + 65) / 1920 * w)] > 128)
        a, b = band(75 / 1080), band(1005 / 1080)
        series.append((round(k / FPS, 4), a if a == b and a > 0 else None))
    return series


def taps(test_log):
    found = []
    for line in open(test_log, errors="replace"):
        m = re.search(r"JUMP ([+-])10 n=(\d+) tap=([0-9.]+) from=(\S+) to=(\S+) seek=(\S+) loading=(\w+)", line)
        if m:
            seek = re.match(r"(\d+)_ms_([0-9.]+)_MB", m.group(6))
            found.append(dict(sign=m.group(1), n=int(m.group(2)), tap=float(m.group(3)), loading=m.group(7) == "yes",
                              restart=int(seek.group(1)) if seek else None, mb=float(seek.group(2)) if seek else None))
    return found


def seeks(ndjson):
    """(Mac time, film second, by) of each "PERF cache at <s> by <+n> ..." line."""
    found = []
    for line in open(ndjson, errors="replace"):
        try:
            entry = json.loads(line.rstrip(",\n"))
        except ValueError:
            continue
        m = re.match(r"PERF cache at ([0-9.]+) by ([+-]\d+)", entry.get("eventMessage", ""))
        if m:
            found.append((datetime.strptime(entry["timestamp"], "%Y-%m-%d %H:%M:%S.%f%z").timestamp(), float(m.group(1)),
                          int(m.group(2))))
    return found


def steady(series):
    """The series with each number that agrees with neither grid neighbour (the same frame or up to two on)
    taken out: a picture dimmed under the loading view reads as noise."""
    def agrees(a, b):
        return a is not None and b is not None and 0 <= b - a <= 2
    out = []
    for k, (t, n) in enumerate(series):
        before = series[k - 1][1] if k else None
        after = series[k + 1][1] if k + 1 < len(series) else None
        out.append((t, n if agrees(before, n) or agrees(n, after) else None))
    return out


def visible_jumps(series):
    """Each jump of the picture: when the new place showed, how long the old picture stood still before it,
    when it moved on, and by how much it moved."""
    out, last_t, last_n, changed = [], None, None, None
    for t, n in steady(series):
        if n is None:
            continue
        if last_n is None or n != last_n:
            if last_n is not None and abs(n - last_n) > LANDED:
                out.append(dict(at=t, still=t - changed, by=(n - last_n) / FILM_FPS, moving=None))
            elif out and out[-1]["moving"] is None and last_n is not None:
                out[-1]["moving"] = t - out[-1]["at"]
            last_n, changed = n, t
        last_t = t
    return out


def pct(values, p):
    values = sorted(values)
    return values[min(len(values) - 1, round(p / 100 * (len(values) - 1)))]


def time(series_path, recorder_log, test_log, ndjson, metric):
    # No recording (the real feeds): the picture is taken as back at libmpv's restart, which the
    # test server's recordings match within a frame or two.
    recorded = os.path.exists(series_path) and os.path.exists(recorder_log)
    series = [(t, n or None) for t, n in json.load(open(series_path))] if recorded else []
    found, logged, shown = taps(test_log), seeks(ndjson), visible_jumps(series)
    started = next((float(line.split()[0]) for line in open(recorder_log) if "Recording started" in line), 0) if recorded else 0
    drift, calibrated = 0.0, False
    print(f"{len(found)} taps, {sum(1 for s in logged if abs(s[2]) == 10)} seeks in the app's log, {len(shown)} jumps of the picture, "
          f"{sum(1 for _, n in series if n is not None)} of {len(series)} recorded frames read")
    queue = list(shown)
    by = {"+": [], "-": []}
    for j in found:
        seek = next((s for s in logged if s[0] >= j["tap"] - 0.05 and s[2] == (10 if j["sign"] == "+" else -10)), None)
        if seek:
            logged.remove(seek)
        j["to_seek"] = seek[0] - j["tap"] if seek else None
        # Where the new picture should be in the recording: the tap (or the seek) on the recorder's clock, as
        # far off as the last pair was, plus libmpv's restart; the nearest picture jump that way within 3 s.
        expected = (seek[0] if seek else j["tap"]) - started + drift + (j["restart"] or 0) / 1000
        # A picture jump of about 10 s that way (more when the new place played on under a loading view).
        def fits(v):
            return (v["by"] > 0) == (j["sign"] == "+") and 7 <= abs(v["by"]) <= 14 + (j["restart"] or 0) / 1000
        near = [v for v in queue if fits(v) and abs(v["at"] - expected) < 3]
        pair = min(near, key=lambda v: abs(v["at"] - expected), default=None)
        if pair is None:
            # The recorder's clock slipped further: the next picture jump that way, in order, within 8 s.
            pair = next((v for v in queue if fits(v) and abs(v["at"] - expected) < 8), None)
        if pair:
            queue = queue[queue.index(pair) + 1:]
        # From the seek at the earliest: a picture already stopped by a stall before the tap isn't the jump's
        # (unless the recorder's clock isn't known yet, or has slipped past the seek: then from the last change).
        since_seek = pair and pair["at"] - (expected - (j["restart"] or 0) / 1000)
        j["still"] = pair and (min(pair["still"], since_seek) if calibrated and since_seek > 0 else pair["still"])
        j["moving"] = pair and pair["moving"]
        j["by"] = pair and pair["by"]
        if pair:
            drift += pair["at"] - expected
            calibrated = True
        if not recorded and j["restart"] is not None:
            j["still"] = j["restart"] / 1000
        total = None if j["to_seek"] is None or j["still"] is None else j["to_seek"] + j["still"]
        j["total"] = total
        ms = lambda s: "-" if s is None else f"{s * 1000:.0f}"
        print(f"{j['sign']}10 n={j['n']:2d} tap to new picture {ms(total):>5} ms = tap to seek {ms(j['to_seek']):>4} + picture still "
              f"{ms(j['still']):>5} | libmpv restart {j['restart']} ms, {j['mb']} MB from the server | moved "
              f"{(j['by'] or 0):+5.1f} s | loading view {'yes' if j['loading'] else 'no'}")
        if total is not None:
            by[j["sign"]].append(total * 1000)
    for sign, name in (("+", "forward_10s"), ("-", "back_10s")):
        v, mine = by[sign], [j for j in found if j["sign"] == sign]
        restarts = [j["restart"] for j in mine if j["restart"] is not None]
        if v:
            print(f"{sign}10: {len(v)} of {len(mine)} timed, tap to new picture p50 {pct(v, 50):.0f} ms, p95 {pct(v, 95):.0f} ms, "
                  f"max {max(v):.0f} ms | libmpv restart p50 {pct(restarts, 50)} ms, max {max(restarts)} ms | "
                  f"read from the server {sum(1 for j in mine if (j['mb'] or 0) > 0)} | loading view {sum(1 for j in mine if j['loading'])}")
            if metric:
                for x in v:
                    print(f"METRIC film.jump.{name} {x:.0f} ms")
    if metric:
        print(f"METRIC film.jump.loading_shown {sum(1 for j in found if j['loading'])} count")


def main(argv):
    if argv[:1] == ["decode"]:
        json.dump(decode(argv[1]), open(argv[2], "w"))
    elif argv[:1] == ["time"]:
        time(argv[1], argv[2], argv[3], argv[4], "--metric" in argv)
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

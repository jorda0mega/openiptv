#!/usr/bin/env python3
"""The film runner's printed lines (apple/scripts/real-feed-film-buffering.sh) as
numbers, and two sets of them side by side: the real server's against the
test server's under the profile meant to copy it.

    python3 scripts/film_numbers.py extract --as real-busy run.txt > numbers.json
    python3 scripts/film_numbers.py extract --as probe run.txt > numbers.json
    python3 scripts/film_numbers.py compare real.json mock.json

extract keeps counts and times only, never a word of a line but the names
below. A two-platform run's lines go under the label with " tvos" added
for the Apple TV, and the network and phone network setting added past
unmetered (" metered daily"). --as probe files each line under real-quiet or real-busy by the
server's own state on it (-debugServerProbe: a first byte under 0.3 s is
quiet, between the 0.17-0.23 s measured quiet and the 0.4 s that starts
busy); a line without it goes under --unprobed. Lines of the old way are
left out. The numbers file is {label: {line: {"unit", "values"}}}; extract
with --into adds to one.

compare prints each line both have, under each label both have: the real
median, the test server's, and how far off it is, "!" past --off percent
(20) when also more than --floor (0.1) apart.
"""

import argparse
import json
import re
import statistics
import sys

QUIET_PROBE_S = 0.3

START = re.compile(r"REAL (?:link )?(?:start (?:card \d+ )?(ready|cold)|(playback) start): (.*)")
START_PARTS = [
    ("tap to first frame", "s", r"tap to first frame ([\d.]+) s"),
    ("plan", "s", r"plan ([\d.]+) s"),
    ("open", "s", r"open ([\d.]+) s"),
    ("first frame after the open", "s", r"first frame ([\d.]+) s after"),
    ("slowest first byte", "s", r"first byte up to (\d+) ms", 1e-3),
    ("MB from the server", "MB", r"from the server \d+ reads ([\d.]+) MB"),
    ("MB ahead, the open's own reads", "MB", r"took ahead: open ([\d.]+) MB"),
    ("reads ahead, the open's own", "count", r"took ahead: open [\d.]+ MB in (\d+) read"),
    ("MB ahead, the rest", "MB", r"took ahead: .*?rest ([\d.]+) MB"),
    ("reads ahead, the rest", "count", r"took ahead: .*?rest [\d.]+ MB in (\d+) read"),
]
KEPT = [("used", r"kept start: used(?! in part)"), ("used in part", r"kept start: used in part"),
        ("not done at the tap", r"kept start: not done at the tap"), ("unused", r"kept start: unused")]
LINES = [
    (r"REAL (?:link )?first \d+ s: pauses (\d+)", [("playback: pauses", "count", 1)]),
    (r"REAL (?:link )?first \d+ s: pauses \d+: ([\d ]+) ms", [("playback: paused", "s", "sum_ms")]),
    (r"REAL (?:link )?first \d+ s: .*?MB from the server, ([\d.]+) MB/s", [("playback: MB/s", "MB/s", 1)]),
    (r"REAL playback after \d+ s: [\d.]+ MB from the server, ([\d.]+) MB/s on average", [("playback: MB/s", "MB/s", 1)]),
    (r"REAL playback at \d+ s: .*?speed ([\d.]+) MB/s", [("playback: read speed", "MB/s", 1)]),
    (r"REAL (?:link )?lower quality: decided ([\d.]+) s after the tap, its first frame ([\d.]+) s after the tap",
     [("lower quality: decided", "s", 1), ("lower quality: first frame", "s", 2), ("conversion wait", "s", "2-1")]),
    (r"REAL converted start: converted ([\d.]+) s: server (\d+) ms .*?\(([^)]*)\)",
     [("converted start: open", "s", 1), ("converted start: server", "s", "2ms"), ("conversion wait: first segment", "s", "segment")]),
    (r"REAL (?:link )?jump \+5 min: (\d+) ms ([\d.]+) MB", [("jump +5 min", "s", "1ms"), ("jump +5 min: MB", "MB", 2)]),
    (r"REAL jump -30 s: (\d+) ms ([\d.]+) MB", [("jump -30 s", "s", "1ms"), ("jump -30 s: MB", "MB", 2)]),
    (r"REAL (?:link )?audio[^:]*: (\d+) ms to its sound", [("audio switch", "s", "1ms")]),
    (r"REAL (?:link )?subtitles[^:]*: switch .*?after=(\d+)", [("subtitle switch: first line", "s", "1ms")]),
    (r"REAL (?:link )?subtitles[^:]*: switch .*?(no line in \d+ s)", [("subtitle switch: no line", "count", "one")]),
    (r"REAL (?:link )?subtitles[^:]*: switch .*?(rebuffer)", [("subtitle switch: stalls", "count", "one")]),
    (r"== (?:link|ios|tvos) \S+ .*?(\d+) MB free", [("Mac free disk", "MB", 1)]),
    (r"test server .*?link ([\d.]+) MB/s while carrying data", [("link: MB/s while carrying data", "MB/s", 1)]),
    (r"test server .*?(\d+) network changes", [("link: network changes", "count", 1)]),
    (r"server: connect ([\d.]+) s, first byte ([\d.]+) s$", [("server probe: connect", "s", 1), ("server probe: first byte", "s", 2)]),
]
PROBE = re.compile(r"server: connect [\d.]+ s, first byte ([\d.]+) s$")
RUN = re.compile(r"^(?:\[([^\]]+)\] |== ((?:ios|tvos) [^,]+?) \d\d:\d\d)")


def value(match, how):
    if isinstance(how, int):
        return float(match.group(how))
    if how == "sum_ms":
        return sum(int(n) for n in match.group(1).split()) / 1000
    if how == "2-1":
        return float(match.group(2)) - float(match.group(1))
    if how == "one":
        return 1.0
    if how == "segment":
        segments = re.findall(r"\bs(\d+)", match.group(3))
        return int(segments[0]) / 1000 if segments else None
    return float(match.group(int(how[0]))) / 1000


def line_numbers(line):
    """[(name, unit, number)] for one printed line."""
    line = re.sub(r"^\[[^\]]+\] ", "", line.rstrip("\n"))
    if "(old way)" in line:
        return []
    found = []
    start = START.search(line)
    if start:
        kind = "start " + start.group(1) if start.group(1) else "playback start"
        for name, unit, pattern, *scale in START_PARTS:
            part = re.search(pattern, start.group(3))
            if part:
                found.append((f"{kind}: {name}", unit, float(part.group(1)) * (scale[0] if scale else 1)))
        kept = next((name for name, pattern in KEPT if re.search(pattern, line)), None)
        if kept:
            for name, _ in KEPT:
                found.append((f"{kind}: kept start {name}", "share", float(name == kept)))
    for pattern, names in LINES:
        match = re.search(pattern, line)
        if match:
            for name, unit, how in names:
                number = value(match, how)
                if number is not None:
                    found.append((name, unit, number))
    return found


def run_of(line):
    """What a two-platform run's line adds to its label: the Apple TV, and a
    network other than unmetered with its phone network setting."""
    run = RUN.match(line)
    words = (run.group(1) or run.group(2)).split() if run else []
    if len(words) < 3:
        return ""
    platform, _, *network = words
    return "".join(" " + word for word in ([platform] if platform != "ios" else []) + (network if network != ["unmetered"] else []))


def extract(lines, label, unprobed):
    numbers = {}
    for line in lines:
        probe = PROBE.search(line.rstrip("\n"))
        where = label if label != "probe" else (
            ("real-quiet" if float(probe.group(1)) < QUIET_PROBE_S else "real-busy") if probe else unprobed)
        if where is None:
            continue
        where += run_of(line)
        for name, unit, number in line_numbers(line):
            numbers.setdefault(where, {}).setdefault(name, {"unit": unit, "values": []})["values"].append(number)
    return numbers


def merge(into, more):
    for label, lines in more.items():
        for name, line in lines.items():
            into.setdefault(label, {}).setdefault(name, {"unit": line["unit"], "values": []})["values"] += line["values"]
    return into


def middle(line):
    values = line["values"]
    return statistics.mean(values) if line["unit"] in ("share", "count") else statistics.median(values)


def shown(line):
    number, unit = middle(line), line["unit"]
    if unit == "share":
        return f"{sum(line['values']):.0f} of {len(line['values'])}"
    if unit == "count":
        return f"{number:.1f}"
    return f"{number:.2f} {unit} ({len(line['values'])})"


def compare(real, mock, off=20.0, floor=0.1):
    rows = []
    for label in [label for label in real if label in mock]:
        rows.append(f"== {label}")
        rows.append(f"{'line':44} {'real':>16} {'test server':>16} {'off':>7}")
        for name in [name for name in real[label] if name in mock[label]]:
            a, b = real[label][name], mock[label][name]
            x, y = middle(a), middle(b)
            if a["unit"] == "share":
                apart, percent = (y - x) * 100, (y - x) * 100
                text = f"{percent:+.0f} pt"
            else:
                apart = y - x
                percent = apart / x * 100 if x else (0.0 if not y else float("inf"))
                text = f"{percent:+.0f}%" if abs(percent) != float("inf") else "new"
            flag = "!" if abs(percent) > off and abs(apart) > (floor * 100 if a["unit"] == "share" else floor) else ""
            rows.append(f"{name:44} {shown(a):>16} {shown(b):>16} {text:>7} {flag}".rstrip())
        missing = [name for name in real[label] if name not in mock[label]]
        if missing:
            rows.append("not on the test server: " + ", ".join(missing))
    return "\n".join(rows) if rows else "no label in both"


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    pull = commands.add_parser("extract")
    pull.add_argument("--as", dest="label", required=True)
    pull.add_argument("--unprobed")
    pull.add_argument("--into")
    pull.add_argument("runs", nargs="+")
    side = commands.add_parser("compare")
    side.add_argument("real")
    side.add_argument("mock")
    side.add_argument("--off", type=float, default=20.0)
    side.add_argument("--floor", type=float, default=0.1)
    args = parser.parse_args()
    if args.command == "extract":
        numbers = json.load(open(args.into)) if args.into else {}
        for run in args.runs:
            with open(run) as f:
                merge(numbers, extract(f, args.label, args.unprobed))
        text = json.dumps(numbers, indent=1)
        if args.into:
            with open(args.into, "w") as f:
                f.write(text + "\n")
        else:
            print(text)
    else:
        print(compare(json.load(open(args.real)), json.load(open(args.mock)), args.off, args.floor))


if __name__ == "__main__":
    sys.exit(main())

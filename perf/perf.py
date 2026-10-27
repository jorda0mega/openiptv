#!/usr/bin/env python3 -I
"""The app's named measurements, read from runner output, against the best
table (perf/best.json). Names come from apple/OpenIPTV/Player/PerfMetric.swift
and nowhere else.

    perf.py names                       every metric name and unit
    perf.py parse FILE...               runner output to JSON lines, one sample each
    perf.py best [--keep-current]       rebuild best.json from SOURCES (the recorded runs)
    perf.py live LOG.ndjson              the app's live opens as METRIC lines (live.start, then live.switch)
    perf.py compare SAMPLES.jsonl...     a table against best.json: better, same or REGRESSION (PLATFORMS)

A sample is {metric, value, unit, platform, target, link, commit, source}; target
is "real" or "mock:<profile>". Counts and numbers only: runner lines carry no
address, and nothing here prints one.
"""

import glob
import json
import os
import re
import statistics
import subprocess
import sys
from datetime import datetime

REPO = os.environ.get("REPO") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REGISTRY = os.path.join(REPO, "apple/OpenIPTV/Player/PerfMetric.swift")
BEST = os.path.join(REPO, "perf/best.json")
RESULTS = "/tmp/openiptv"

# TestFlight builds and the commit each was archived from (/tmp/openiptv/release-*.log).
RELEASES = [
    ("202610261136", "bdbea0d"), ("202610261439", "4ff57a0"), ("202610261728", "6bcd699"),
    ("202610261846", "3169823"), ("202610262013", "719f1de"), ("202610262043", "ebfec05"),
    ("202610271425", "09afc6f"),
]

# Runner output whose lines say neither their build nor their target: (glob, what they were).
UNSTAMPED = [
    ("pip-notes/before-gaps.txt", dict(commit="4ff57a0", platform="ipad", target="mock:none", first_only=True)),
    ("subs-fix-runs/run-pip*.out", dict(commit="09afc6f", platform="ipad", target="mock:none")),
    ("pip-return-runs/before-*.out", dict(commit="09afc6f", platform="ipad", target="mock:none")),
]
STAMPED = ["*/run.txt", "filmbuf/*/*.txt", "fsr-*/*.txt", "fsn-runs/*.txt", "calibration/mock-*.txt"]
# Runs of code paths the app ships switched off (old-way launch flags) or of injected faults, by their file names.
NOT_SHIPPED = re.compile(r"before|-e\.txt$|-eg\.txt$|nohidden|stuck-")
# Launch flags that change only what a test reads, not what the app does.
READING_FLAGS = {"-noFileProbe", "-debugHTTP2", "YES"}


def names():
    with open(REGISTRY) as f:
        text = f.read()
    cases = dict(re.findall(r'case (\w+) = "([a-z0-9_]+\.[a-z0-9_.]+)"', text))
    units = {}
    for block, unit in re.findall(r"case ((?:\.\w+, )*\.\w+): \.(\w+)", text):
        for case in re.findall(r"\.(\w+)", block):
            units[cases[case]] = unit
    default = re.search(r"default: \.(\w+)", text).group(1)
    symbol = dict(seconds="s", milliseconds="ms", count="count", ratio="ratio")
    return {name: symbol[units.get(name, default)] for name in cases.values()}


# Each runner line that is a sample: (pattern on the text after "REAL ", metric).
REAL_LINES = [
    (r"(?:link start cold|start card \d+ cold): tap to first frame ([0-9.]+) s", "film.start.first_tap"),
    (r"(?:link start ready|start card \d+ ready): tap to first frame ([0-9.]+) s", "film.start.prepared"),
    (r"link playback start: tap to first frame ([0-9.]+) s", "film.start.launch_tap"),
    (r"(?:link )?jump \+5 min: (\d+) ms", "film.jump.forward_5min"),
    (r"link first 120 s: pauses (\d+)", "film.play.pauses_120s"),
    (r"link subtitles: switch .*? ; after=(\d+) ;", "film.subtitles.first_line"),
]
METRIC_LINE = re.compile(r"METRIC ([a-z0-9_.]+) (-?[0-9.]+) (\S+)")
TAG = re.compile(r"^\[([^\]]+)\] (.*)$")


def parse_tag(tag):
    words = tag.split()
    if words[0] in ("ios", "tvos", "ipad"):
        return words[0], words[1] if len(words) > 1 else "none"
    return "ios", words[0]


def parse(path, commit=None, platform=None, target=None, first_only=False):
    """Samples in one runner output. Stamped output says its commit in its first
    line and its target in its "test server" lines; `commit`, `platform` and
    `target` stand in for output that says neither."""
    with open(path, errors="replace") as f:
        lines = f.read().splitlines()
    head = re.match(r"^([0-9a-f]{7})( with changes)? (\d\d:\d\d)", lines[0]) if lines else None
    commit = commit or (head and head.group(1))
    changed = bool(head and head.group(2))
    day = datetime.fromtimestamp(os.path.getmtime(path)).strftime("%Y-%m-%d")
    profiles = {}
    for line in lines:
        m = TAG.match(line)
        server = m and re.match(r"test server (\S+) over (\S+):", m.group(2))
        if server:
            profiles[m.group(1)] = server.group(1)
    hint = next((p for p in ("real-quiet", "real-busy", "extreme", "worst") if p in os.path.basename(path)), None)
    samples, seen, flagged = [], set(), set()
    for line in lines:
        m = TAG.match(line)
        tag, text = (m.group(1), m.group(2)) if m else (None, line)
        launched = re.search(r"REAL app build .*, launched with (.*)$", text)
        if launched and set(launched.group(1).split()) - READING_FLAGS:
            flagged.add(tag)
        if tag in flagged:
            continue
        rows = []
        if text.startswith("REAL ") and "(old way)" not in text:
            for pattern, metric in REAL_LINES:
                found = re.match(pattern, text[5:])
                if found:
                    rows.append((metric, float(found.group(1))))
        elif text.startswith("PIP gap start"):
            parts = dict(re.findall(r"(start|return) (.*?)(?: \||$)", text[8:]))
            for kind, part in parts.items():
                fields = dict((k, float(v)) for k, v in re.findall(r"(\w+)=(\d+)", part))
                rows += [(f"pip.{kind}.picture_gap", fields.get("frames")), (f"pip.{kind}.sound_gap", fields.get("audio"))]
        elif text.startswith("PERF live open"):
            fields = dict(re.findall(r"(\w+)=(-?\d+)", text))
            if int(fields.get("tap", -1)) >= 0:
                rows.append(("live.start", float(fields["tap"])))
        found = METRIC_LINE.search(text)
        if found:
            rows.append((found.group(1), float(found.group(2))))
        for metric, value in rows:
            if value is None or (first_only and metric in seen):
                continue
            seen.add(metric)
            where, link = parse_tag(tag) if tag else (platform or "ios", "none")
            profile = profiles.get(tag) or hint
            samples.append(dict(metric=metric, value=value, platform=platform or where, link=link,
                                target=target or (f"mock:{profile}" if profile else "real"),
                                commit=commit, changed=changed, date=day, source=os.path.relpath(path, RESULTS)))
    return samples


def git(*args):
    return subprocess.run(["git", "-C", REPO, *args], capture_output=True, text=True).stdout.strip()


def landed(commit, cache={}):
    """The main commit `commit`'s change landed as, or None: itself when on main;
    else the nearest of its last 6 commits whose subject main has, with the
    app's code unchanged from it to `commit`."""
    if commit in cache:
        return cache[commit]
    found = None
    if commit and subprocess.run(["git", "-C", REPO, "merge-base", "--is-ancestor", commit, "HEAD"]).returncode == 0:
        found = git("rev-parse", "--short", commit)
    elif commit and git("cat-file", "-t", commit) == "commit":
        for ancestor in git("log", "--format=%h", "-6", commit).split():
            subject = git("log", "-1", "--format=%s", ancestor)
            on_main = git("log", "--format=%h", "-F", f"--grep={subject}", "HEAD").split()
            if on_main:
                if not git("diff", "--name-only", ancestor, commit, "--", "apple/OpenIPTV", "apple/OpenIPTV-tvOS"):
                    found = on_main[-1]
                break
    cache[commit] = found
    return found


def first_build(commit):
    for build, release in RELEASES:
        if subprocess.run(["git", "-C", REPO, "merge-base", "--is-ancestor", commit, release]).returncode == 0:
            return build
    return None


def recorded():
    samples = []
    for pattern in STAMPED:
        for path in sorted(glob.glob(os.path.join(RESULTS, pattern))):
            if not NOT_SHIPPED.search(os.path.basename(path)):
                samples += parse(path)
    for pattern, what in UNSTAMPED:
        for path in sorted(glob.glob(os.path.join(RESULTS, pattern))):
            what = dict(what, commit=what["commit"] and git("rev-parse", "--short", what["commit"]))
            samples += parse(path, **what)
    for path in sorted(glob.glob(os.path.join(RESULTS, "perf-runs/**/samples.jsonl"), recursive=True)):
        samples += [dict(dict(changed=False, link="none"), **json.loads(line)) for line in open(path) if line.strip()]
    return samples


def pct(values, p):
    values = sorted(values)
    return values[min(len(values) - 1, round(p / 100 * (len(values) - 1)))]


# Below this, a difference is no change whatever the run's own spread: a frame at 24 fps, a tenth of a second.
FLOOR = dict(s=0.1, ms=42, count=0.5, ratio=0.05)


def compare(paths, known, platforms):
    """Each metric this run measured against the best for its target, link and platform: better or
    REGRESSION when its median is further from the best than the run's own spread (its interquartile
    range, at least FLOOR), else same."""
    samples = [json.loads(line) for path in paths for line in open(path) if line.strip()]
    with open(BEST) as f:
        table = json.load(f)["metrics"]
    groups = {}
    for s in samples:
        groups.setdefault((s["platform"], s["metric"], s["target"], s.get("link", "none")), []).append(s["value"])
    targets = sorted({(s["target"], s.get("link", "none")) for s in samples})
    print(f"{'platform':8} {'metric':28} {'n':>3} {'p50':>9} {'p95':>9} {'max':>9}  {'best':>9} {'set by':<22} verdict")
    for platform in platforms:
        for metric, unit in known.items():
            for target, link in targets:
                values = groups.get((platform, metric, target, link))
                best = next((b for b in table.get(metric, {}).get("best", [])
                             if (b["target"], b["link"], b["platform"]) == (target, link, platform)), None)
                fmt = (lambda v: f"{v:.2f} {unit}") if unit in ("s", "ratio") else (lambda v: f"{v:.0f} {unit}")
                set_by = f"{best['testflight'] or best['commit']} {best['date'][5:]}" if best else "-"
                if not values:
                    print(f"{platform:8} {metric:28} {0:>3} {'-':>9} {'-':>9} {'-':>9}  {fmt(best['value']) if best else '-':>9} {set_by:<22} not measured")
                    continue
                p50, p95, top = pct(values, 50), pct(values, 95), max(values)
                noise = max(pct(values, 75) - pct(values, 25), FLOOR[unit])
                verdict = ("no best yet" if best is None else "better" if p50 < best["value"] - noise
                           else "REGRESSION" if p50 > best["value"] + noise else "same")
                print(f"{platform:8} {metric:28} {len(values):>3} {fmt(p50):>9} {fmt(p95):>9} {fmt(top):>9}  "
                      f"{fmt(best['value']) if best else '-':>9} {set_by:<22} {verdict}")


def best(samples, known):
    """Per metric, target, link and platform: the run (one source file) with the lowest median, with its
    build, sample count and spread. A run's median, not its single best sample, so that perf.py compare
    weighs like against like."""
    runs, skipped = {}, 0
    for s in samples:
        main = None if s["changed"] else landed(s["commit"])
        if s["metric"] not in known or not main:
            skipped += 1
            continue
        runs.setdefault((s["metric"], s["target"], s["link"], s["platform"], s["source"]), []).append((s, main))
    table = {}
    for (metric, target, link, platform, source), found in runs.items():
        values = sorted(s["value"] for s, _ in found)
        median, (first, main) = pct(values, 50), found[0]
        entry = table.setdefault((metric, target, link, platform), dict(runs=0))
        entry["runs"] += 1
        if "value" not in entry or median < entry["value"]:
            entry.update(value=median, samples=len(values), spread=round(pct(values, 75) - pct(values, 25), 3),
                         commit=first["commit"], landed_as=main, testflight=first_build(main), date=first["date"], source=source)
    out = {}
    for (metric, target, link, platform), entry in sorted(table.items()):
        out.setdefault(metric, []).append(dict(target=target, link=link, platform=platform, unit=known[metric], **entry))
    return out, skipped


def main(argv):
    known = names()
    if argv[:1] == ["names"]:
        for name, unit in known.items():
            print(name, unit)
    elif argv[:1] == ["parse"]:
        for path in argv[1:]:
            for s in parse(path):
                print(json.dumps(s))
    elif argv[:1] == ["best"]:
        samples = recorded()
        table, skipped = best(samples, known)
        unknown = sorted({s["metric"] for s in samples} - set(known))
        assert not unknown, f"samples under names PerfMetric lacks: {unknown}"
        with open(BEST, "w") as f:
            json.dump(dict(about="Best recorded run per metric, target (real Emby or mock:<profile>), link and platform: the "
                                 "run's median (value), its sample count and interquartile spread, and the build. Lower is "
                                 "better for every metric. Rebuilt by perf/perf.py best from the runs under /tmp/openiptv, "
                                 "eval runs (perf/eval.sh) included.",
                           metrics={name: dict(unit=unit, best=table.get(name, [])) for name, unit in known.items()}),
                      f, indent=1)
            f.write("\n")
        print(f"{len(samples)} samples, {len(samples) - skipped} from code on main, "
              f"{sum(len(v) for v in table.values())} best entries over {len(table)} of {len(known)} metrics")
    elif argv[:1] == ["live"]:
        # The app's "PERF live open ... tap=<ms>" lines with a frame, in order: the first opens the channel, each
        # next one is a switch.
        opens = []
        for line in open(argv[1], errors="replace"):
            m = re.search(r"PERF live open .*\btap=(\d+)", line)
            if m:
                opens.append(int(m.group(1)))
        for k, ms in enumerate(opens):
            print(f"METRIC {'live.start' if k == 0 else 'live.switch'} {ms} ms")
        platforms = (os.environ.get("PLATFORMS") or "ios tvos").split()
        compare(argv[1:], known, platforms)
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))

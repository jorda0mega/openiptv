#!/usr/bin/env python3
"""Phase 0 for the app's Live TV probes: each test-server switch's known
answer against the app's `PERF live` lines (.audit/live-perf/fable-plan.md
§4.1 and §4.3).

    python3 -I scripts/live_app_phase0.py --port <free port> --phone <simulator id> \\
        --derived-data <folder> [--build]

Starts the test server on the port with the test film (OPENIPTV_MOCK_VIDEO,
else /tmp/openreel-media/test.mkv), builds for testing with --build, runs
LivePerfProbeTests on the booted iPhone simulator, and reads the app's
lines from the simulator's log by the app's process ids, with a `PERF live`
filter. Each test plays its own channel, so a line's `tok` names its row.
Local only: nothing here reaches a provider. Exits 1 if a row misses its
known value, a line breaks the probe's rule (shown as [withheld]), or the
app's log names the test server's address or a login word in clear.
"""

import argparse
import json
import os
import re
import statistics
import subprocess
import sys
import threading
import time
import urllib.request
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
APPLE = os.path.join(HERE, "..", "apple")
APP = "UIKitApplication:com.jorda0mega.openiptv["


def fields(line):
    return dict(word.split("=", 1) for word in line.split()[3:] if "=" in word)


def leaks(line):
    return bool(re.search(r"[^A-Za-z0-9_=.\- ]", line) or any(
        len(word) > 32 or ("." in word and not re.fullmatch(r"[A-Za-z0-9_]+=-?\d+\.\d+", word)) for word in line.split()))


def near(value, known, within):
    return abs(float(value) - known) <= within


def kind(line, name):
    return line.split()[2] == name


def opens(lines):
    return [fields(l) for l in lines if kind(l, "open")]


def check_delay(lines):
    o = [x for x in opens(lines) if x["frame"] != "-1"]
    return "open opened >= 3000", f"opened={o[0]['opened']}", int(o[0]["opened"]) >= 3000


def check_status(code):
    def check(lines):
        f = [fields(l) for l in lines if kind(l, "fail")]
        return f"fail class=http_{code} phase=open", f"class={f[0]['class']} phase={f[0]['phase']}", \
            f[0]["class"] == f"http_{code}" and f[0]["phase"] == "open"
    return check


def check_stall(lines):
    s = [fields(l) for l in lines if kind(l, "stall")]
    return "one stall, dur ~5 at ~20", f"{len(s)} stall(s)" + "".join(f" dur={x['dur']} at={x['at']}" for x in s), \
        len(s) == 1 and near(s[0]["dur"], 5, 1.5) and near(s[0]["at"], 20, 3)


def check_rate(lines):
    rates = [float(fields(l)["Mbps"]) for l in lines if kind(l, "net")]
    middle = statistics.median(rates[1:] or rates)
    return "net Mbps ~1.5 (median after the first)", f"Mbps={rates} median={middle:.2f}", near(middle, 1.5, 0.3)


def check_cut(lines):
    e = [fields(l) for l in lines if kind(l, "end")]
    return "end reason=eof watched ~20", " ".join(f"reason={x['reason']} watched={x['watched']}" for x in e) or "no end", \
        bool(e) and e[0]["reason"] == "eof" and near(e[0]["watched"], 20, 3)


def check_reset(lines):
    e = [fields(l) for l in lines if kind(l, "end")]
    return "end reason=eof watched ~5 class=none", " ".join(f"reason={x['reason']} watched={x['watched']} class={x['class']}" for x in e[:2]), \
        bool(e) and e[0]["reason"] == "eof" and near(e[0]["watched"], 5, 1.5) and e[0]["class"] == "none"


def check_dead(lines):
    f = [fields(l) for l in lines if kind(l, "fail")]
    return "fail class=no_data at ~3000", f"class={f[0]['class']} at={f[0]['at']}", \
        f[0]["class"] == "no_data" and near(f[0]["at"], 3000, 600)


ROWS = [
    ("live_delay=3", "2", check_delay),
    ("live_status=403", "3", check_status(403)),
    ("live_status=404", "4", check_status(404)),
    ("live_stall=20:5", "5", check_stall),
    ("live_rate=1500", "6", check_rate),
    ("live_cut=20", "7", check_cut),
    ("live_chunked=1 live_cut=5 live_cut_reset=1", "8", check_reset),
    ("dead_live (start limit 3 s)", "9", check_dead),
]


def app_pids(phone, seen, stop):
    while not stop.is_set():
        listing = subprocess.run(["xcrun", "simctl", "spawn", phone, "launchctl", "list"], capture_output=True, text=True).stdout
        for row in listing.splitlines():
            parts = row.split("\t")
            if len(parts) == 3 and parts[2].startswith(APP) and parts[0].isdigit() and int(parts[0]) not in seen:
                seen.append(int(parts[0]))
        stop.wait(0.5)


def log_show(phone, began, predicate, style):
    return subprocess.run(["xcrun", "simctl", "spawn", phone, "log", "show", "--style", style, "--info", "--debug",
                           "--start", began, "--predicate", predicate], capture_output=True, text=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--phone", required=True)
    parser.add_argument("--derived-data", required=True)
    parser.add_argument("--build", action="store_true")
    parser.add_argument("--only", help="one test, e.g. testDelay")
    args = parser.parse_args()
    base = f"http://127.0.0.1:{args.port}"
    destination = f"platform=iOS Simulator,id={args.phone}"

    def get(path):
        return json.loads(urllib.request.urlopen(base + path, timeout=10).read())

    film = os.environ.get("OPENIPTV_MOCK_VIDEO") or "/tmp/openreel-media/test.mkv"
    if not os.path.exists(film):
        sys.exit(f"no test film at {film} (verify media, or set OPENIPTV_MOCK_VIDEO)")
    if args.build:
        subprocess.run(["xcodebuild", "build-for-testing", "-scheme", "OpenIPTV", "-destination", destination,
                        "-derivedDataPath", args.derived_data, "-quiet"], cwd=APPLE, check=True)
    began = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    server_log = open(os.path.join(args.derived_data, f"mock-{args.port}.log"), "w")
    mock = subprocess.Popen([sys.executable, "-I", os.path.join(HERE, "mock_server.py"), str(args.port)],
                            env=dict(os.environ, OPENIPTV_MOCK_VIDEO=film), stdout=server_log, stderr=server_log)
    pids, stop = [], threading.Event()
    try:
        for _ in range(100):
            try:
                get("/mock/set?reset=1")
                break
            except OSError:
                time.sleep(0.1)
        if mock.poll() is not None:
            sys.exit(f"the test server did not start on port {args.port}")
        poller = threading.Thread(target=app_pids, args=(args.phone, pids, stop), daemon=True)
        poller.start()
        account = json.dumps({"serverURL": base, "serverName": "Mock", "userId": "U1", "userName": "tester", "accessToken": "tok"})
        only = "OpenIPTV UITests/LivePerfProbeTests" + (f"/{args.only}" if args.only else "")
        test = subprocess.run(["xcodebuild", "test-without-building", "-scheme", "OpenIPTV", "-destination", destination,
                               "-derivedDataPath", args.derived_data, "-only-testing:" + only],
                              cwd=APPLE, env=dict(os.environ, TEST_RUNNER_DEBUG_EMBY=account), capture_output=True, text=True)
        stop.set()
        poller.join()
        with open(os.path.join(args.derived_data, "live-app-phase0-xcodebuild.log"), "w") as out:
            out.write(test.stdout + test.stderr)
        for row in test.stdout.splitlines():
            if re.search(r"Test Case .*(passed|failed)|error:|Executed .* tests?,", row):
                print(re.sub(r"^.*Test Case ", "", row))
        agents = sorted({i["ua"] for i in get("/mock/live_requests?since=0")["items"]})
    finally:
        stop.set()
        mock.kill()
        mock.wait()
        server_log.close()
    if not pids:
        print("no app process seen: nothing to read")
        return 1

    time.sleep(3)
    by_pid = "processID IN {" + ", ".join(map(str, pids)) + "}"
    shown = log_show(args.phone, began, by_pid + ' AND eventMessage BEGINSWITH "PERF live"', "ndjson")
    entries = [json.loads(row) for row in shown.stdout.splitlines() if row.startswith("{")]
    lines = [(e["processID"], e["eventMessage"]) for e in entries if e.get("eventMessage", "").startswith("PERF live ")]
    print(f"\n{len(lines)} PERF live lines from {len(pids)} app launches\n")
    toks = {pid: {fields(l).get("tok") for p, l in lines if p == pid} - {None} for pid in pids}

    def row_lines(tok):
        return [l for p, l in lines if tok in toks.get(p, set())]

    failed = 0
    print(f"{'row':<44} {'known':<40} {'measured':<52} result")
    for name, tok, check in ROWS:
        mine = row_lines(tok)
        mine = [l for l in mine if fields(l).get("tok", tok) == tok]
        try:
            known, measured, passed = check(mine)
        except (IndexError, KeyError, ValueError, statistics.StatisticsError) as missing:
            known, measured, passed = "", f"no line ({type(missing).__name__})", False
        failed += not passed
        print(f"{name:<44} {known:<40} {measured:<52} {'pass' if passed else 'FAIL'}")
        for line in mine:
            print("    " + ("[withheld]" if leaks(line) else line))

    floor = [x for x in opens([l for l in row_lines("1") if fields(l).get("tok", "1") == "1"]) if x["frame"] != "-1"]
    print(f"\nlocalhost floor, {len(floor)} opens of channel 1 (p50, min-max, ms):")
    for key in ("tap", "setup", "closewait", "address", "opened", "frame"):
        values = sorted(int(x[key]) for x in floor)
        if values:
            print(f"    {key:<10} p50={statistics.median(values):.0f}  {values[0]}-{values[-1]}")
    for name in ("mpv", "path", "codec"):
        said = sorted({l.split(" ", 3)[3] for _, l in lines if kind(l, name)})
        print(f"{name} lines: {said or 'none'}")
    print(f"user agents the test server saw (last test): {agents}")

    withheld = [l for _, l in lines if leaks(l)]
    if withheld:
        print(f"withheld lines by kind: { {w: sum(l.split()[2] == w for l in withheld) for w in {l.split()[2] for l in withheld}} }")
    every = log_show(args.phone, began, by_pid, "ndjson")
    logged = [json.loads(row) for row in every.stdout.splitlines() if row.startswith("{")]
    logged = [e for e in logged if "eventMessage" in e]
    words = [rf"127\.0\.0\.1:{args.port}", rf"localhost:{args.port}", "/live/", "u/p/", "username", "password", "player_api"]
    clear = {word: sum(bool(re.search(word, e["eventMessage"])) for e in logged) for word in words}
    senders = {}
    for e in logged:
        if any(re.search(word, e["eventMessage"]) for word in words):
            where = (os.path.basename(e.get("senderImagePath", "")), e.get("subsystem", ""), e.get("category", ""))
            senders[where] = senders.get(where, 0) + 1
    for where, count in sorted(senders.items(), key=lambda item: -item[1]):
        print(f"    in clear from {where[0]} {where[1]} {where[2]}: {count}")
    read = every.returncode == 0 and bool(logged)
    print(f"\nthe app's log, {len(logged)} lines; in clear: {clear}" if read
          else f"\nthe app's log: unread (exit {every.returncode}, {len(every.stderr)} chars on stderr)")
    print(f"PERF lines withheld by the rule: {len(withheld)}")
    clean = read and not withheld and not any(clear.values())
    print(f"\n{len(ROWS) - failed} of {len(ROWS)} rows match; log checks {'pass' if clean else 'FAIL'}")
    return 1 if failed or not clean or test.returncode else 0


if __name__ == "__main__":
    sys.exit(main())

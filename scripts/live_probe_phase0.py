#!/usr/bin/env python3
"""Phase 0 for the Mac live probe: each test-server switch's known answer
against what the probe measures (.audit/live-perf/fable-plan.md §4.2-4.3).

    python3 scripts/live_probe_phase0.py --port <free port> [--probe PATH]

Starts the test server on the port with the test film (OPENIPTV_MOCK_VIDEO,
else /tmp/openreel-media/test.mkv) and a login holder for it, builds the
probe unless --probe names one, then runs one probe per row. Local only:
nothing here reaches a provider. Exits 1 if a row misses its known value,
a probe line breaks the probe's own output rule (shown as [withheld]), or
the Mac's log names the test server's address or login in clear.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
APPLE = os.path.join(HERE, "..", "apple")


def fields(line):
    return dict(word.split("=", 1) for word in line.split()[2:] if "=" in word)


def leaks(line):
    return bool(re.search(r"[^A-Za-z0-9_=.> -]", line) or any(
        len(word) > 32 or ("." in word and not re.fullmatch(r"[a-z0-9_]+=-?\d+\.\d+", word)) for word in line.split()))


def near(value, known, within):
    return abs(float(value) - known) <= within


def gaps(server):
    times = [i["t"] for i in server["live"]]
    return [round(b - a, 1) for a, b in zip(times, times[1:])]


def one(o, *keys):
    return " ".join(f"{k}={o[0].get(k)}" for k in keys)


# libmpv's default user agent, its version string: `strings` on MPVKit
# 1.0.0's Libmpv (apple/mpvkit.lock) finds this one.
LIBMPV = "mpv v0.41.0-dirty"
APP_VERSION = re.search(r'MARKETING_VERSION: "([^"]+)"', open(os.path.join(APPLE, "project.yml")).read()).group(1)


def film_kb(seconds, kbps):
    return seconds * int(kbps) / 8 / 1.024


# (name, switches, probe environment, check[, exit code]). check(opens,
# other probe lines by kind, what the test server saw) gives (known,
# measured, passed).
ROWS = [
    ("live_delay=3", {"live_delay": 3}, {},
     lambda o, *_: ("ttfb ~ 3000", one(o, "ttfb"), near(o[0]["ttfb"], 3000, 300))),
    ("live_first_data_delay=4", {"live_first_data_delay": 4}, {},
     lambda o, *_: ("ttfb < 500, first_data ~ 4300 (4 s + 0.3 s server + ffmpeg)", one(o, "ttfb", "first_data"),
                    int(o[0]["ttfb"]) < 500 and near(o[0]["first_data"], 4300, 500))),
    ("dead_live=1, cap 4 s", {"dead_live": 1}, {"OPENIPTV_PROBE_SECONDS": "4"},
     lambda o, *_: ("headers=yes first_data=-1 bytes=0 error=no_data", one(o, "status", "headers", "first_data", "bytes", "error"),
                    (o[0]["headers"], o[0]["first_data"], o[0]["bytes"], o[0]["error"]) == ("yes", "-1", "0", "no_data"))),
    ("dead_live=1, sustain 70 s", {"dead_live": 1}, {"OPENIPTV_PROBE_IDS": "", "OPENIPTV_PROBE_SUSTAIN": "1:70"},
     lambda o, *_: ("stopped_at ~ 70 error=no_data (the cap, not a 60 s timeout)", one(o, "stopped_at", "headers", "error"),
                    near(o[0]["stopped_at"], 70, 1) and o[0]["error"] == "no_data")),
    ("live_first_data_delay=6, cap 4 s", {"live_first_data_delay": 6}, {"OPENIPTV_PROBE_SECONDS": "4"},
     lambda o, *_: ("headers=yes ttfb < 500 bytes=0 error=no_data", one(o, "status", "headers", "ttfb", "bytes", "error"),
                    o[0]["headers"] == "yes" and int(o[0]["ttfb"]) < 500 and (o[0]["bytes"], o[0]["error"]) == ("0", "no_data"))),
    ("live_delay=6, cap 4 s", {"live_delay": 6}, {"OPENIPTV_PROBE_SECONDS": "4"},
     lambda o, *_: ("headers=no status=0 ttfb=-1 error=timeout", one(o, "headers", "status", "ttfb", "error"),
                    (o[0]["headers"], o[0]["status"], o[0]["ttfb"], o[0]["error"]) == ("no", "0", "-1", "timeout"))),
    ("live_status=403", {"live_status": 403}, {},
     lambda o, *_: ("status=403", one(o, "status", "bytes"), o[0]["status"] == "403")),
    ("live_status=200 (an empty 200)", {"live_status": 200}, {},
     lambda o, rest, _: ("status=200 bytes=0 framing=length error=none, with_data=0 ended_early=0",
                         one(o, "status", "bytes", "framing", "error")
                         + f" with_data={rest['summary'][0]['with_data']} ended_early={rest['summary'][0]['ended_early']}",
                         (o[0]["status"], o[0]["bytes"], o[0]["framing"], o[0]["error"]) == ("200", "0", "length", "none")
                         and (rest["summary"][0]["with_data"], rest["summary"][0]["ended_early"]) == ("0", "0"))),
    ("live_redirect=1", {"live_redirect": 1}, {},
     lambda o, *_: ("hops=1, redirect_ms >= 0", one(o, "hops", "redirect_ms", "cross_host", "status"),
                    o[0]["hops"] == "1" and int(o[0]["redirect_ms"]) >= 0 and o[0]["status"] == "200")),
    ("live_redirect_loop=1", {"live_redirect_loop": 1}, {},
     lambda o, *_: ("error=redirect_loop, over 10 hops", one(o, "status", "hops", "error"),
                    o[0]["error"] == "redirect_loop" and int(o[0]["hops"]) > 10)),
    ("live_stall=20:5 (sustain 30 s)", {"live_stall": "20:5"}, {"OPENIPTV_PROBE_IDS": "", "OPENIPTV_PROBE_SUSTAIN": "1:30"},
     lambda o, *_: ("gap_max ~ 5, gaps_1s=1", one(o, "gap_max", "gaps_1s"), near(o[0]["gap_max"], 5, 0.5) and o[0]["gaps_1s"] == "1")),
    ("live_rate=1500", {"live_rate": 1500}, {},
     lambda o, *_: ("rate_kbps, rate_tail_kbps ~ 1500, first_1s_kb ~ 183", one(o, "rate_kbps", "rate_tail_kbps", "first_1s_kb"),
                    near(o[0]["rate_kbps"], 1500, 150) and near(o[0]["rate_tail_kbps"], 1500, 150) and near(o[0]["first_1s_kb"], 183, 40))),
    ("live_burst=3", {"live_burst": 3}, {},
     lambda o, *_: ("first_1s_kb ~ 4 s of the film at rate_tail_kbps", one(o, "first_1s_kb", "rate_tail_kbps"),
                    near(o[0]["first_1s_kb"], film_kb(4, o[0]["rate_tail_kbps"]), 0.3 * film_kb(4, o[0]["rate_tail_kbps"])))),
    ("live_cut=20", {"live_cut": 20}, {"OPENIPTV_PROBE_SECONDS": "30"},
     lambda o, rest, _: ("stopped_at ~ 20, error=none, ended_early=1",
                         one(o, "stopped_at", "error") + f" ended_early={rest['summary'][0]['ended_early']}",
                         near(o[0]["stopped_at"], 20.3, 1) and o[0]["error"] == "none" and rest["summary"][0]["ended_early"] == "1")),
    ("live_cut=5 live_cut_reset=1", {"live_cut": 5, "live_cut_reset": 1}, {},
     lambda o, *_: ("an end: error=none framing=close ~ 5 s", one(o, "error", "framing", "stopped_at"),
                    o[0]["error"] == "none" and o[0]["framing"] == "close" and near(o[0]["stopped_at"], 5.3, 1))),
    ("live_cut=5 live_cut_reset=1 live_chunked=1", {"live_cut": 5, "live_cut_reset": 1, "live_chunked": 1}, {},
     lambda o, *_: ("error=reset framing=chunked", one(o, "error", "framing", "stopped_at"),
                    o[0]["error"] == "reset" and o[0]["framing"] == "chunked")),
    ("live_max_connections=1 live_linger=2 (pair)", {"live_max_connections": 1, "live_linger": 2},
     {"OPENIPTV_PROBE_IDS": "", "OPENIPTV_PROBE_PAIR": "1,2,1,5"},
     lambda o, rest, _: ("B at +1 s 403, at +5 s 200", " ".join(f"+{p['delay']}s={p['b_status']}" for p in rest.get("pair", [])),
                         [(p["delay"], p["b_status"]) for p in rest.get("pair", [])] == [("1.0", "403"), ("5.0", "200")])),
    ("same, past the limit 200 and empty", {"live_max_connections": 1, "live_linger": 2, "live_limit_status": 200},
     {"OPENIPTV_PROBE_IDS": "", "OPENIPTV_PROBE_PAIR": "1,2,1,5"},
     lambda o, rest, _: ("B at +1 s 200 empty, at +5 s 200 with data",
                         " ".join(f"+{p['delay']}s={p['b_status']}/b_bytes={p['b_bytes']}" for p in rest.get("pair", [])),
                         [(p["delay"], p["b_status"], p["b_bytes"] == "0") for p in rest.get("pair", [])]
                         == [("1.0", "200", True), ("5.0", "200", False)])),
    ("xtream_formats=m3u8 (account)", {"xtream_formats": "m3u8"}, {"OPENIPTV_PROBE_IDS": "", "OPENIPTV_PROBE_ACCOUNT": "1"},
     lambda o, rest, _: ("m3u8=yes ts=no", " ".join(f"{k}={v}" for k, v in rest["account"][0].items()),
                         rest["account"][0].get("m3u8") == "yes" and rest["account"][0].get("ts") == "no")),
    ("xtream_max_connections=0 (account)", {"xtream_max_connections": 0}, {"OPENIPTV_PROBE_IDS": "", "OPENIPTV_PROBE_ACCOUNT": "1"},
     lambda o, rest, _: ("max_conn=unlimited", f"max_conn={rest['account'][0].get('max_conn')}",
                         rest["account"][0].get("max_conn") == "unlimited")),
    ("none, .m3u8", {}, {"OPENIPTV_PROBE_EXT": "m3u8"},
     lambda o, rest, _: ("segments=5 target=6.0, a segment read, rate_kbps=-1, ended_early=0",
                         one(o, "segments", "target", "seg_first_data", "rate_kbps") + f" ended_early={rest['summary'][0]['ended_early']}",
                         o[0].get("segments") == "5" and o[0].get("target") == "6.0" and int(o[0].get("seg_first_data", -1)) >= 0
                         and o[0]["rate_kbps"] == "-1" and rest["summary"][0]["ended_early"] == "0")),
    ("none, both user agents, exact (a local echo)", {}, {"OPENIPTV_PROBE_UA": "both", "OPENIPTV_SMOKE_FEED": "echo"},
     lambda o, rest, server: (f"mpv_ua=vendored; {LIBMPV}, Openreel/{APP_VERSION}",
                              f"mpv_ua={rest['start'][0]['mpv_ua']}; {', '.join(map(str, server['echo']))}",
                              rest["start"][0]["mpv_ua"] == "vendored" and server["echo"] == [LIBMPV, f"Openreel/{APP_VERSION}"])),
    ("none, both user agents, mpv's replaced", {}, {"OPENIPTV_PROBE_UA": "both", "OPENIPTV_PROBE_MPV_UA": "mpv phase0"},
     lambda o, rest, server: ("mpv_ua=given; server saw mpv,openreel",
                              f"mpv_ua={rest['start'][0]['mpv_ua']}; server saw {','.join(i['ua'] for i in server['live'])}",
                              rest["start"][0]["mpv_ua"] == "given" and [i["ua"] for i in server["live"]] == ["mpv", "openreel"])),
    ("none, 3 ids, pause after 2 for 3 s", {},
     {"OPENIPTV_PROBE_IDS": "1,2,3", "OPENIPTV_PROBE_SECONDS": "1", "OPENIPTV_PROBE_GAP": "0.5",
      "OPENIPTV_PROBE_PAUSE_EVERY": "2", "OPENIPTV_PROBE_PAUSE_SECONDS": "3"},
     lambda o, rest, server: ("request gaps 1.5 s, then 4 s; reason=pause",
                              f"gaps={gaps(server)} reason={rest.get('wait', [{}])[0].get('reason')}",
                              len(gaps(server)) == 2 and near(gaps(server)[0], 1.5, 0.3) and near(gaps(server)[1], 4, 0.3)
                              and rest.get("wait", [{}])[0].get("reason") == "pause")),
    ("none, 2 rounds, 3 s between", {}, {"OPENIPTV_PROBE_ROUNDS": "2", "OPENIPTV_PROBE_SECONDS": "1", "OPENIPTV_PROBE_ROUND_GAP": "3"},
     lambda o, rest, server: ("request gap 4 s; reason=round", f"gaps={gaps(server)} reason={rest.get('wait', [{}])[0].get('reason')}",
                              len(gaps(server)) == 1 and near(gaps(server)[0], 4, 0.3) and rest.get("wait", [{}])[0].get("reason") == "round")),
    ("none, dry run (no ids)", {}, {"OPENIPTV_PROBE_IDS": ""},
     lambda o, rest, server: ("opens=0 requests=0, server saw nothing",
                              one(rest["done"], "opens", "requests") + f" server={len(server['live'])}+{len(server['xtream'])}",
                              (rest["done"][0]["opens"], rest["done"][0]["requests"]) == ("0", "0")
                              and not server["live"] and not server["xtream"])),
    ("none, login from the environment", {}, {"OPENIPTV_SMOKE_FEED": None},
     lambda o, *_: ("status=200, data", one(o, "status", "bytes", "ctype"),
                    o[0]["status"] == "200" and int(o[0]["bytes"]) > 0 and o[0]["ctype"] == "mp2t")),
]


def holder(port):
    """The login holder's address, as the app's debug sign-in reads it."""
    source = json.dumps({"id": "00000000-0000-0000-0000-000000000001", "name": "Test server",
                         "kind": {"xtream": {"server": f"http://127.0.0.1:{port}/", "username": "u", "password": "p"}}}).encode()

    class Holder(BaseHTTPRequestHandler):
        def do_GET(self):
            self.send_response(200 if self.path == "/iptv" else 404)
            self.send_header("Content-Length", str(len(source)))
            self.end_headers()
            self.wfile.write(source)

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Holder)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_port}/iptv"


def echo():
    """A server that keeps each request's user agent and refuses it: what
    the probe sends, exactly."""
    agents = []

    class Echo(BaseHTTPRequestHandler):
        def do_GET(self):
            agents.append(self.headers.get("User-Agent"))
            self.send_response(403)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Echo)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return f"http://127.0.0.1:{server.server_port}", agents


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--probe")
    args = parser.parse_args()
    base = f"http://127.0.0.1:{args.port}"

    def get(path):
        return json.loads(urllib.request.urlopen(base + path, timeout=10).read())

    film = os.environ.get("OPENIPTV_MOCK_VIDEO") or "/tmp/openreel-media/test.mkv"
    if not os.path.exists(film):
        sys.exit(f"no test film at {film} (verify media, or set OPENIPTV_MOCK_VIDEO)")
    probe = args.probe
    if not probe:
        probe = os.path.join(tempfile.mkdtemp(prefix="openiptv-live-probe."), "smoke")
        subprocess.run([os.path.join(APPLE, "Tools/smoke/run.sh"), "--build-only", probe],
                       env=dict(os.environ, OPENIPTV_SMOKE_MODE="live-probe"), check=True)
    began = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    mock = subprocess.Popen([sys.executable, os.path.join(HERE, "mock_server.py"), str(args.port)],
                            env=dict(os.environ, OPENIPTV_MOCK_VIDEO=film))
    try:
        for _ in range(100):
            try:
                get("/mock/set?reset=1")
                break
            except OSError:
                time.sleep(0.1)
        if mock.poll() is not None:
            sys.exit(f"the test server did not start on port {args.port}")
        feed = holder(args.port)
        echoed, agents = echo()
        failed = 0
        pids = []
        print(f"{'row':<46} {'known':<56} {'measured':<56} result")
        for name, switches, extra, check, *code in ROWS:
            get("/mock/set?reset=1")
            if switches:
                get("/mock/set?" + "&".join(f"{k}={v}" for k, v in switches.items()))
            since = get("/mock/mark")["t"]
            agents.clear()
            env = {k: v for k, v in os.environ.items() if not k.startswith(("OPENIPTV_", "OPENREEL_"))}
            env.update({"OPENIPTV_SMOKE_MODE": "live-probe", "OPENIPTV_SMOKE_FEED": feed, "OPENIPTV_PROBE_IDS": "1",
                        "OPENIPTV_PROBE_ROUNDS": "1", "OPENIPTV_PROBE_SECONDS": "10", "OPENIPTV_PROBE_GAP": "1"})
            for k, v in extra.items():
                # The login from the environment, for the test server or the echo.
                if v in (None, "echo"):
                    env.pop(k)
                    env.update({"OPENIPTV_XTREAM_URL": echoed if v else base, "OPENIPTV_XTREAM_USER": "u", "OPENIPTV_XTREAM_PASS": "p"})
                else:
                    env[k] = v
            run = subprocess.Popen([probe], env=env, cwd=APPLE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            pids.append(run.pid)
            stdout, stderr = run.communicate(timeout=180)
            lines = stdout.splitlines()
            opens = [fields(line) for line in lines if line.startswith("PROBE open ")]
            rest = {}
            for line in lines:
                kind = line.split()[1] if len(line.split()) > 1 else ""
                if kind not in ("open", "block"):
                    rest.setdefault(kind, []).append(fields(line) if kind != "config" else dict.fromkeys(line.split()[2:], ""))
            server = {"live": get(f"/mock/live_requests?since={since}")["items"],
                      "xtream": get(f"/mock/xtream_requests?since={since}")["items"], "echo": list(agents)}
            try:
                known, measured, passed = check(opens, rest, server)
            except (IndexError, KeyError, ValueError) as missing:
                known, measured, passed = "", f"no line ({missing})", False
            withheld = [line for line in lines if leaks(line)]
            if withheld or stderr or run.returncode != (code[0] if code else 0):
                passed = False
                measured += f" [exit {run.returncode}, {len(withheld)} line(s) withheld, stderr {len(stderr)} chars]"
            failed += not passed
            print(f"{name:<46} {known:<56} {measured:<56} {'pass' if passed else 'FAIL'}", flush=True)
            for line in lines:
                print("    " + ("[withheld]" if leaks(line) else line))
        # CFNetwork and the network stack log each open for this process;
        # they hide URLs (<private>) and addresses (a hash) but show the
        # port. Only counts are read: lines naming the test server's host,
        # its login or the holder in clear must be none. By process id: the
        # log names a process after the first path it saw for the binary.
        log = subprocess.run(["/usr/bin/log", "show", "--style", "compact", "--info", "--debug", "--start", began,
                              "--predicate", "processID IN {" + ", ".join(map(str, pids)) + "}"], capture_output=True, text=True)
        logged = [line for line in log.stdout.splitlines() if line[:4].isdigit()]
        clear = [line for line in logged if re.search(r"127\.0\.0\.1|localhost|/live/|u/p/|player_api|username|password|/iptv|http:", line)]
        read = log.returncode == 0 and logged
        print(f"{'the Mac log, lines in clear':<46} {'0 (of the lines the probe logged)':<56} "
              f"{f'{len(clear)} of {len(logged)}' if read else 'unread: 0 lines, check /usr/bin/log and the log level':<56} "
              f"{'pass' if read and not clear else 'FAIL'}")
        failed += not (read and not clear)
        print(f"\n{len(ROWS) + 1 - failed} of {len(ROWS) + 1} rows match")
        return 1 if failed else 0
    finally:
        mock.kill()
        mock.wait()


if __name__ == "__main__":
    sys.exit(main())

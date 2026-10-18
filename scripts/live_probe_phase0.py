#!/usr/bin/env python3
"""Phase 0 for the Mac live probe: each test-server switch's known answer
against what the probe measures (.audit/live-perf/fable-plan.md §4.2-4.3).

    python3 scripts/live_probe_phase0.py [--port 8794] [--probe PATH]

Starts the test server on the port with the test film (OPENIPTV_MOCK_VIDEO,
else /tmp/openreel-media/test.mkv) and a login holder for it, builds the
probe unless --probe names one, then runs one probe per row. Local only:
nothing here reaches a provider. Exits 1 if a row misses its known value
or a probe line breaks the probe's own output rule.
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
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
APPLE = os.path.join(HERE, "..", "apple")


def fields(line):
    return dict(word.split("=", 1) for word in line.split()[2:] if "=" in word)


def leaks(line):
    return bool(re.search(r"[^A-Za-z0-9_=.> -]", line) or re.search(r"[A-Za-z][.][A-Za-z]|\d+[.]\d+[.]\d", line)
                or any(len(word) > 32 for word in line.split()))


def near(value, known, within):
    return abs(float(value) - known) <= within


# (name, switches, probe environment, check) where check(opens, other lines,
# the user agents the test server saw) gives (known, measured, passed).
ROWS = [
    ("live_delay=3", {"live_delay": 3}, {},
     lambda o, *_: ("ttfb ~ 3000", f"ttfb={o[0]['ttfb']}", near(o[0]["ttfb"], 3000, 300))),
    ("live_first_data_delay=4", {"live_first_data_delay": 4}, {},
     lambda o, *_: ("ttfb < 500, first_data ~ 4000", f"ttfb={o[0]['ttfb']} first_data={o[0]['first_data']}",
                   int(o[0]["ttfb"]) < 500 and near(o[0]["first_data"], 4300, 500))),
    ("live_status=403", {"live_status": 403}, {},
     lambda o, *_: ("status=403", f"status={o[0]['status']} bytes={o[0]['bytes']}", o[0]["status"] == "403")),
    ("live_redirect=1", {"live_redirect": 1}, {},
     lambda o, *_: ("hops=1", f"hops={o[0]['hops']} cross_host={o[0]['cross_host']} status={o[0]['status']}",
                   o[0]["hops"] == "1" and o[0]["status"] == "200")),
    ("live_stall=20:5 (sustain 30 s)", {"live_stall": "20:5"}, {"OPENIPTV_PROBE_IDS": "", "OPENIPTV_PROBE_SUSTAIN": "1:30"},
     lambda o, *_: ("gap_max ~ 5, gaps_1s=1", f"gap_max={o[0]['gap_max']} gaps_1s={o[0]['gaps_1s']}",
                   near(o[0]["gap_max"], 5, 0.5) and o[0]["gaps_1s"] == "1")),
    ("live_rate=1500", {"live_rate": 1500}, {},
     lambda o, *_: ("rate_kbps ~ 1500", f"rate_kbps={o[0]['rate_kbps']}", near(o[0]["rate_kbps"], 1500, 150))),
    ("live_cut=20", {"live_cut": 20}, {"OPENIPTV_PROBE_SECONDS": "30"},
     lambda o, *_: ("stopped_at ~ 20, error=none", f"stopped_at={o[0]['stopped_at']} error={o[0]['error']}",
                   near(o[0]["stopped_at"], 20.3, 1) and o[0]["error"] == "none")),
    ("live_cut=5 live_cut_reset=1", {"live_cut": 5, "live_cut_reset": 1}, {},
     lambda o, *_: ("an end: error=none framing=close ~ 5 s", f"error={o[0]['error']} framing={o[0]['framing']} stopped_at={o[0]['stopped_at']}",
                   o[0]["error"] == "none" and o[0]["framing"] == "close" and near(o[0]["stopped_at"], 5.3, 1))),
    ("live_cut=5 live_cut_reset=1 live_chunked=1", {"live_cut": 5, "live_cut_reset": 1, "live_chunked": 1}, {},
     lambda o, *_: ("error=reset framing=chunked", f"error={o[0]['error']} framing={o[0]['framing']} stopped_at={o[0]['stopped_at']}",
                   o[0]["error"] == "reset" and o[0]["framing"] == "chunked")),
    ("live_max_connections=1 live_linger=2 (pair)", {"live_max_connections": 1, "live_linger": 2},
     {"OPENIPTV_PROBE_IDS": "", "OPENIPTV_PROBE_PAIR": "1,2,1,5"},
     lambda o, rest, *_: ("B at +1 s 403, at +5 s 200",
                      " ".join(f"+{p['delay']}s={p['b_status']}" for p in rest.get("pair", [])),
                      [(p["delay"], p["b_status"]) for p in rest.get("pair", [])] == [("1.0", "403"), ("5.0", "200")])),
    ("xtream_formats=m3u8 (account)", {"xtream_formats": "m3u8"}, {"OPENIPTV_PROBE_IDS": "", "OPENIPTV_PROBE_ACCOUNT": "1"},
     lambda o, rest, *_: ("m3u8=yes ts=no", " ".join(f"{k}={v}" for k, v in rest["account"][0].items()),
                      rest["account"][0].get("m3u8") == "yes" and rest["account"][0].get("ts") == "no")),
    ("none, .m3u8", {}, {"OPENIPTV_PROBE_EXT": "m3u8"},
     lambda o, *_: ("segments=5 target=6.0, a segment fetched", f"segments={o[0].get('segments')} target={o[0].get('target')} "
                   f"seg_first_data={o[0].get('seg_first_data')} ctype={o[0]['ctype']}",
                   o[0].get("segments") == "5" and o[0].get("target") == "6.0" and int(o[0].get("seg_first_data", -1)) >= 0)),
    ("none, both user agents", {}, {"OPENIPTV_PROBE_UA": "both"},
     lambda o, _, seen: ("ua=mpv,app; server saw mpv,openreel", f"ua={','.join(x['ua'] for x in o)}; server saw {','.join(seen)}",
                         [x["ua"] for x in o] == ["mpv", "app"] and seen == ["mpv", "openreel"])),
    ("none, login from the environment", {}, {"OPENIPTV_SMOKE_FEED": None},
     lambda o, *_: ("status=200, data", f"status={o[0]['status']} bytes={o[0]['bytes']} ctype={o[0]['ctype']}",
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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8794)
    parser.add_argument("--probe")
    args = parser.parse_args()
    base = f"http://127.0.0.1:{args.port}"
    film = os.environ.get("OPENIPTV_MOCK_VIDEO") or "/tmp/openreel-media/test.mkv"
    if not os.path.exists(film):
        sys.exit(f"no test film at {film} (verify media, or set OPENIPTV_MOCK_VIDEO)")
    probe = args.probe
    if not probe:
        probe = os.path.join(tempfile.mkdtemp(prefix="openiptv-live-probe."), "smoke")
        subprocess.run([os.path.join(APPLE, "Tools/smoke/run.sh"), "--build-only", probe],
                       env=dict(os.environ, OPENIPTV_SMOKE_MODE="live-probe"), check=True)
    mock = subprocess.Popen([sys.executable, os.path.join(HERE, "mock_server.py"), str(args.port)],
                            env=dict(os.environ, OPENIPTV_MOCK_VIDEO=film))
    try:
        for _ in range(100):
            try:
                urllib.request.urlopen(f"{base}/mock/set?reset=1", timeout=2).read()
                break
            except OSError:
                time.sleep(0.1)
        if mock.poll() is not None:
            sys.exit(f"the test server did not start on port {args.port}")
        feed = holder(args.port)
        failed = 0
        print(f"{'row':<46} {'known':<40} {'measured':<50} result")
        for name, switches, extra, check in ROWS:
            urllib.request.urlopen(f"{base}/mock/set?reset=1").read()
            if switches:
                urllib.request.urlopen(f"{base}/mock/set?" + "&".join(f"{k}={v}" for k, v in switches.items())).read()
            since = json.loads(urllib.request.urlopen(f"{base}/mock/mark").read())["t"]
            env = {k: v for k, v in os.environ.items() if not k.startswith(("OPENIPTV_", "OPENREEL_"))}
            env.update({"OPENIPTV_SMOKE_MODE": "live-probe", "OPENIPTV_SMOKE_FEED": feed, "OPENIPTV_PROBE_IDS": "1",
                        "OPENIPTV_PROBE_ROUNDS": "1", "OPENIPTV_PROBE_SECONDS": "10", "OPENIPTV_PROBE_GAP": "1"})
            for k, v in extra.items():
                if v is None:
                    env.pop(k)
                    env.update({"OPENIPTV_XTREAM_URL": base, "OPENIPTV_XTREAM_USER": "u", "OPENIPTV_XTREAM_PASS": "p"})
                else:
                    env[k] = v
            run = subprocess.run([probe], env=env, cwd=APPLE, capture_output=True, text=True, timeout=180)
            lines = run.stdout.splitlines()
            opens = [fields(line) for line in lines if line.startswith("PROBE open ")]
            rest = {}
            for line in lines:
                kind = line.split()[1] if len(line.split()) > 1 else ""
                if kind not in ("open", "block"):
                    rest.setdefault(kind, []).append(fields(line))
            seen = [i["ua"] for i in json.loads(urllib.request.urlopen(f"{base}/mock/live_requests?since={since}").read())["items"]]
            try:
                known, measured, passed = check(opens, rest, seen)
            except (IndexError, KeyError) as missing:
                known, measured, passed = "", f"no line ({missing})", False
            bad = [line for line in lines if leaks(line)] + run.stderr.splitlines()
            if bad or run.returncode != 0:
                passed = False
                measured += f" [exit {run.returncode}, {len(bad)} bad line(s)]"
            failed += not passed
            print(f"{name:<46} {known:<40} {measured:<50} {'pass' if passed else 'FAIL'}", flush=True)
            for line in lines:
                print("    " + line)
        print(f"\n{len(ROWS) - failed} of {len(ROWS)} rows match")
        return 1 if failed else 0
    finally:
        mock.kill()
        mock.wait()


if __name__ == "__main__":
    sys.exit(main())

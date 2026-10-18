#!/usr/bin/env python3
"""Checks the test server's live-channel switches (scripts/mock_server.py).

    python3 scripts/test_mock_live.py

Starts two private test servers on free ports: one streaming a small
test film made with ffmpeg (the switches that shape a stream need it),
one without (the plain answer UI tests get). Needs only Python and ffmpeg.
"""

import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class Mock:
    def __init__(self, video=None):
        self.port = free_port()
        env = dict(os.environ)
        env.pop("OPENIPTV_MOCK_VIDEO", None)
        env.pop("OPENIPTV_MOCK_LIVE_DELAY", None)
        if video:
            env["OPENIPTV_MOCK_VIDEO"] = video
        self.process = subprocess.Popen([sys.executable, os.path.join(HERE, "mock_server.py"), str(self.port)], env=env)
        for _ in range(100):
            try:
                self.get("/mock/set?reset=1")
                return
            except OSError:
                time.sleep(0.05)
        raise RuntimeError("test server did not start")

    def get(self, path):
        with urllib.request.urlopen(f"http://127.0.0.1:{self.port}{path}", timeout=10) as r:
            return json.loads(r.read())

    def set(self, **switches):
        self.get("/mock/set?" + "&".join(f"{k}={v}" for k, v in switches.items()))

    def stop(self):
        self.process.kill()
        self.process.wait()


class Open:
    """One live request on its own connection, read for up to `seconds`:
    status, headers, time to the headers and to the first body byte, the
    body's arrival times, and how it ended ("eof", "reset" or "cap")."""

    def __init__(self, mock, path, seconds=0.0, agent="libmpv"):
        self.sock = socket.create_connection(("127.0.0.1", mock.port), timeout=30)
        start = time.monotonic()
        self.sock.sendall(f"GET {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nUser-Agent: {agent}\r\n\r\n".encode())
        head = b""
        while b"\r\n\r\n" not in head:
            data = self.sock.recv(65536)
            if not data:
                break
            head += data
        self.headers_at = time.monotonic() - start
        head, _, body = head.partition(b"\r\n\r\n")
        lines = head.decode().split("\r\n")
        self.status = int(lines[0].split()[1])
        self.headers = {k.lower(): v.strip() for k, _, v in (line.partition(":") for line in lines[1:])}
        self.arrivals = [(self.headers_at, len(body))] if body else []
        self.ended = "cap"
        self.sock.settimeout(0.25)
        while time.monotonic() - start < seconds:
            try:
                data = self.sock.recv(65536)
            except socket.timeout:
                continue
            except ConnectionResetError:
                self.ended = "reset"
                break
            if not data:
                self.ended = "eof"
                break
            self.arrivals.append((time.monotonic() - start, len(data)))
        self.length = sum(n for _, n in self.arrivals)

    @property
    def first_data(self):
        return self.arrivals[0][0] if self.arrivals else None

    @property
    def gap_max(self):
        times = [t for t, _ in self.arrivals]
        return max((b - a for a, b in zip(times, times[1:])), default=0.0)

    def kbps(self, skip=0.0):
        """The rate from `skip` seconds after the first byte to the last."""
        later = [(t, n) for t, n in self.arrivals if t >= self.first_data + skip]
        return sum(n for _, n in later[1:]) * 8 / 1000 / (later[-1][0] - later[0][0])

    def close(self):
        self.sock.close()


class LiveSwitches(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not shutil.which("ffmpeg"):
            raise unittest.SkipTest("needs ffmpeg")
        cls.folder = tempfile.mkdtemp(prefix="openiptv-mock-test.")
        cls.film = os.path.join(cls.folder, "film.ts")
        # About 3 Mbit/s, steady, like a live channel.
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=640x360:rate=25",
                        "-t", "8", "-c:v", "mpeg2video", "-b:v", "3M", "-minrate", "3M", "-maxrate", "3M",
                        "-bufsize", "1M", "-f", "mpegts", cls.film], check=True)
        cls.mock = Mock(video=cls.film)
        cls.plain = Mock()

    @classmethod
    def tearDownClass(cls):
        cls.mock.stop()
        cls.plain.stop()
        shutil.rmtree(cls.folder, ignore_errors=True)

    def setUp(self):
        self.mock.set(reset=1)
        self.plain.set(reset=1)
        self.opens = []

    def tearDown(self):
        for o in self.opens:
            o.close()

    def open(self, path, seconds=0.0, mock=None, agent="libmpv"):
        o = Open(mock or self.mock, path, seconds, agent)
        self.opens.append(o)
        return o

    def account(self, mock=None):
        return (mock or self.mock).get("/player_api.php?username=u&password=p")["user_info"]

    def test_unset_switches_answer_as_before(self):
        film = self.open("/live/u/p/1.ts", 2)
        self.assertEqual((film.status, film.headers["content-type"], film.ended), (200, "video/mp2t", "cap"))
        self.assertGreater(film.length, 100_000, "the film streams")
        plain = self.open("/live/u/p/1.ts", 2, mock=self.plain)
        self.assertEqual((plain.status, plain.length, plain.headers["content-length"]), (200, 188 * 64, str(188 * 64)))
        playlist = self.open("/live/u/p/1.m3u8", 1)
        self.assertEqual(playlist.headers["content-type"], "application/vnd.apple.mpegurl")
        self.assertNotIn("location", film.headers, "nothing redirects")
        info = self.account()
        self.assertEqual((info["max_connections"], info["active_cons"], info["allowed_output_formats"]),
                         ("2", "0", ["m3u8", "ts"]))

    def test_dead_live_answers_and_sends_nothing(self):
        self.mock.set(dead_live="2003")
        dead = self.open("/live/u/p/2003.ts", 1.5)
        self.assertEqual((dead.status, dead.length, dead.ended), (200, 0, "cap"))

    def test_status_refuses_every_live_request_or_only_the_listed_ones(self):
        self.mock.set(live_status=403)
        for path in ("/live/u/p/1.ts", "/live/u/p/1.m3u8"):
            refused = self.open(path, 1)
            self.assertEqual((refused.status, refused.length, refused.headers["connection"], refused.ended),
                             (403, 0, "close", "eof"), path)
        self.mock.set(live_status=458, live_status_ids="2003,2005")
        self.assertEqual(self.open("/live/u/p/2005.ts").status, 458)
        self.assertEqual(self.open("/live/u/p/1.ts").status, 200)

    def test_delay_holds_the_answer_and_first_data_delay_holds_the_first_byte(self):
        self.mock.set(live_delay=1.5)
        slow = self.open("/live/u/p/1.ts", 2.5)
        self.assertAlmostEqual(slow.headers_at, 1.5, delta=0.3)
        self.mock.set(reset=1)
        self.mock.set(live_first_data_delay=2)
        late = self.open("/live/u/p/1.ts", 3.5)
        self.assertLess(late.headers_at, 0.6)
        self.assertGreater(late.first_data, 2.0)
        self.assertLess(late.first_data, 3.2)
        self.plain.set(live_delay=1)
        self.assertAlmostEqual(self.open("/live/u/p/1.ts", 2, mock=self.plain).headers_at, 1, delta=0.3)

    def test_redirect_sends_ts_to_the_stream_address_and_the_loop_sends_it_back(self):
        self.mock.set(live_redirect=1, live_redirect_delay=1)
        hop = self.open("/live/u/p/7.ts")
        self.assertEqual((hop.status, hop.headers["location"]), (302, "/stream/7.ts"))
        self.assertAlmostEqual(hop.headers_at, 1, delta=0.3)
        target = self.open("/stream/7.ts", 1.5)
        self.assertEqual(target.status, 200)
        self.assertGreater(target.length, 0)
        self.assertEqual(self.open("/live/u/p/7.m3u8").status, 200, "playlists are not redirected")
        self.mock.set(reset=1)
        self.mock.set(live_redirect_loop=1)
        back = self.open("/stream/7.ts")
        self.assertEqual((back.status, back.headers["location"]), (302, "/live/u/p/7.ts"))
        self.assertEqual(self.open("/live/u/p/7.ts").headers["location"], "/stream/7.ts")

    def test_rate_throttles_the_stream(self):
        self.mock.set(live_rate=1000)
        slow = self.open("/live/u/p/1.ts", 5)
        self.assertAlmostEqual(slow.kbps(skip=0.5), 1000, delta=120)

    def test_stall_pauses_the_stream_with_the_connection_open(self):
        self.mock.set(live_stall="1.5:2")
        stalled = self.open("/live/u/p/1.ts", 5)
        self.assertEqual(stalled.ended, "cap")
        self.assertAlmostEqual(stalled.gap_max, 2, delta=0.4)
        gap_at = max(zip(stalled.arrivals, stalled.arrivals[1:]), key=lambda p: p[1][0] - p[0][0])[0][0]
        self.assertAlmostEqual(gap_at - stalled.first_data, 1.5, delta=0.4)

    def test_cut_ends_the_stream_and_cut_reset_resets_it(self):
        self.mock.set(live_cut=2)
        ended = self.open("/live/u/p/1.ts", 6)
        self.assertEqual(ended.ended, "eof")
        self.assertAlmostEqual(ended.arrivals[-1][0] - ended.first_data, 2, delta=0.4)
        self.mock.set(live_cut_reset=1)
        self.assertEqual(self.open("/live/u/p/1.ts", 6).ended, "reset")

    def test_connection_limit_refuses_past_the_limit_until_the_linger_runs_out(self):
        self.mock.set(live_max_connections=1, live_linger=1.5)
        first = self.open("/live/u/p/1.ts", 1)
        self.assertEqual(first.status, 200)
        self.assertEqual((self.account()["max_connections"], self.account()["active_cons"]), ("1", "1"))
        self.assertEqual(self.open("/live/u/p/2.ts").status, 403, "one stream already open")
        first.close()
        time.sleep(0.5)
        self.assertEqual(self.open("/live/u/p/2.ts").status, 403, "the closed stream still counts")
        time.sleep(2)
        self.assertEqual(self.account()["active_cons"], "0")
        self.assertEqual(self.open("/live/u/p/2.ts", 0.5).status, 200)
        self.mock.set(live_limit_status=458)
        self.assertEqual(self.open("/live/u/p/3.ts").status, 458)

    def test_account_answer_follows_its_switches(self):
        self.mock.set(xtream_formats="m3u8", xtream_max_connections=1, xtream_active_cons=1)
        info = self.account()
        self.assertEqual((info["allowed_output_formats"], info["max_connections"], info["active_cons"]), (["m3u8"], "1", "1"))
        self.mock.set(xtream_formats="ts")
        self.assertEqual(self.account()["allowed_output_formats"], ["ts"])

    def test_live_requests_list_each_request_with_its_agent_as_a_word(self):
        since = self.mock.get("/mock/mark")["t"]
        for agent in ("libmpv", "Lavf/61.7.100", "Openreel/0.2.0", "a-private-agent-9f3"):
            self.open("/live/u/p/2001.ts", agent=agent)
        self.mock.set(live_status=404)
        self.open("/live/u/p/2002.m3u8")
        items = self.mock.get(f"/mock/live_requests?since={since}")["items"]
        self.assertEqual([(i["id"], i["ext"], i["status"], i["ua"]) for i in items],
                         [("2001", "ts", 200, "mpv"), ("2001", "ts", 200, "lavf"), ("2001", "ts", 200, "openreel"),
                          ("2001", "ts", 200, "other"), ("2002", "m3u8", 404, "mpv")])
        self.assertNotIn("private-agent", json.dumps(items))
        later = self.mock.get(f"/mock/live_requests?since={time.time()}")["items"]
        self.assertEqual(later, [])

    def test_reset_clears_the_live_switches_and_requests(self):
        self.mock.set(live_status=403, xtream_formats="m3u8")
        self.open("/live/u/p/1.ts")
        self.mock.set(reset=1)
        self.assertEqual(self.mock.get("/mock/live_requests")["items"], [])
        self.assertEqual(self.open("/live/u/p/1.ts").status, 200)
        self.assertEqual(self.account()["allowed_output_formats"], ["m3u8", "ts"])


if __name__ == "__main__":
    unittest.main(verbosity=2)

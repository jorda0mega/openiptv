#!/usr/bin/env python3
"""The timing profiles (net_profiles.json, slow_link.py) and the test server
under them. The live checks start the test server on port 8858 with the film
OPENIPTV_MOCK_VIDEO names (/tmp/openiptv/net-media/net.mkv unless set).

    python3 scripts/test_slow_link.py
"""

import http.client
import json
import math
import os
import socket
import statistics
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import slow_link  # noqa: E402

SERVER_KEYS = {"base", "connect_s", "answer_s", "plan_s", "first_byte_s", "read_mb_s", "convert_first_s", "convert_segment_s",
               "subtitle_extract_s", "hang", "reset", "convert_refused"}
LINK_KEYS = {"connect_s", "round_trip_s", "mbit_s", "stall", "network_change_s"}
PORT = 8858
FILM = os.environ.get("OPENIPTV_MOCK_VIDEO", "/tmp/openiptv/net-media/net.mkv")


class Clock:
    """time.monotonic for a Link, moved on by hand."""

    def __init__(self):
        self.now = 1000.0

    def __call__(self):
        return self.now


def numbers(spec):
    if isinstance(spec, (int, float)):
        return [spec]
    if isinstance(spec, list):
        return spec
    return [n for value in spec.values() for n in numbers(value)]


class Profiles(unittest.TestCase):
    def test_the_file_holds_times_and_rates_only(self):
        table = slow_link.profiles()
        for name, entry in table.items():
            if isinstance(entry, str):
                self.assertIn(entry, table, f"{name} names no profile")
                continue
            self.assertLessEqual(set(entry), {"server", "link"}, name)
            for part, keys in (("server", SERVER_KEYS), ("link", LINK_KEYS)):
                half = entry.get(part, {})
                self.assertLessEqual(set(half), keys, f"{name} {part}")
                for key, spec in half.items():
                    if key == "base":
                        self.assertIn(spec, table)
                    else:
                        self.assertTrue(all(isinstance(n, (int, float)) and n >= 0 for n in numbers(spec)), f"{name} {key}")

    def test_the_old_names_map_onto_the_new_ones(self):
        self.assertEqual(slow_link.half("busy", "server"), slow_link.half("real-busy", "server"))
        self.assertEqual(slow_link.half("busy", "link"), {})
        self.assertEqual(slow_link.half("far", "server"), {})
        self.assertEqual(slow_link.half("far", "link")["mbit_s"], 8)
        self.assertEqual(set(slow_link.half("worst", "link")), LINK_KEYS)

    def test_worst_is_the_busy_server_with_its_faults(self):
        busy, worst = slow_link.half("real-busy", "server"), slow_link.half("worst", "server")
        self.assertEqual({k: worst[k] for k in busy if k != "plan_s"}, {k: busy[k] for k in busy if k != "plan_s"})
        self.assertGreater(worst["plan_s"][0], busy["plan_s"][1] - 0.01)
        self.assertTrue({"hang", "reset", "convert_refused"} <= set(worst))

    def test_the_real_profiles_have_no_link_of_their_own(self):
        self.assertEqual(slow_link.half("real-quiet", "link"), {})
        self.assertEqual(slow_link.half("real-busy", "link"), {})


class Reads(unittest.TestCase):
    def reads(self, name, count, seed=1):
        server = slow_link.Server(name, seed)
        return [server.read() for _ in range(count)]

    def test_reads_repeat_with_the_seed_and_change_with_another(self):
        self.assertEqual(self.reads("worst", 300), self.reads("worst", 300))
        self.assertNotEqual(self.reads("worst", 300), self.reads("worst", 300, seed=2))

    def test_a_quiet_server_answers_a_read_in_its_measured_range_at_its_measured_pace(self):
        reads = self.reads("real-quiet", 2000)
        self.assertTrue(all(0.17 <= r.first_byte <= 0.23 for r in reads))
        self.assertTrue(all(3.5e6 <= r.rate <= 15e6 for r in reads))
        self.assertFalse([r for r in reads if r.hang_at is not None or r.reset_at is not None])

    def test_a_busy_server_answers_heavy_tailed_up_to_9_s(self):
        waits = [r.first_byte for r in self.reads("real-busy", 5000)]
        self.assertTrue(all(0.4 <= w <= 9 for w in waits))
        self.assertAlmostEqual(statistics.median(waits), 0.9, delta=0.1)
        self.assertGreater(sum(w > 4 for w in waits) / len(waits), 0.02)
        self.assertGreater(sum(w == 9 for w in waits), 0)

    def test_worst_hangs_about_1_in_50_reads_and_resets_about_1_in_30(self):
        reads = self.reads("worst", 6000)
        hangs, resets = [r for r in reads if r.hang_at is not None], [r for r in reads if r.reset_at is not None]
        self.assertAlmostEqual(len(hangs), 120, delta=35)
        self.assertAlmostEqual(len(resets), 200, delta=45)
        self.assertTrue(all(15 <= r.hang <= 20 for r in hangs))


class Conversions(unittest.TestCase):
    def test_worst_refuses_each_start_once_then_makes_segments_at_the_measured_pace(self):
        server = slow_link.Server("worst")
        conversion = server.conversion(10, 0.0)
        self.assertTrue(conversion.refuse())
        self.assertFalse(conversion.refuse())
        self.assertTrue(1.1 <= conversion.ready_at(10) <= 5.9)
        steps = [conversion.ready_at(n + 1) - conversion.ready_at(n) for n in range(10, 60)]
        self.assertTrue(all(0.17 <= s <= 2.8 for s in steps))
        self.assertEqual(conversion.made(conversion.ready_at(14)), 5)
        again = slow_link.Server("worst").conversion(10, 0.0)
        self.assertEqual([again.ready_at(n) for n in range(10, 30)], [conversion.ready_at(n) for n in range(10, 30)])

    def test_a_real_server_refuses_no_start(self):
        self.assertFalse(slow_link.Server("real-busy").conversion(0, 0.0).refuse())


class Links(unittest.TestCase):
    def setUp(self):
        self.clock, self.real = Clock(), slow_link.time.monotonic
        slow_link.time.monotonic = self.clock

    def tearDown(self):
        slow_link.time.monotonic = self.real

    def send(self, link, seconds):
        """One connection sending all the time: its bytes and the link's rates seen."""
        connection, sent, rates = link.connection(), 0, set()
        end = self.clock.now + seconds
        while self.clock.now < end:
            self.clock.now = max(self.clock.now, link.book(connection, slow_link.PIECE))
            rates.add(link.rate)
            sent += slow_link.PIECE
        return sent, rates

    def test_worst_carries_about_half_a_megabyte_a_second_swinging_2_to_8_mbit_with_its_stalls(self):
        link = slow_link.Link("worst")
        began = self.clock.now
        sent, rates = self.send(link, 900)
        average = sent / (self.clock.now - began) / 1e6
        self.assertAlmostEqual(average, 0.5, delta=0.08)
        self.assertTrue(all(2 * 125e3 <= r <= 8 * 125e3 for r in rates))
        self.assertGreater(max(rates) / min(rates), 3)
        done = link.readout()
        self.assertAlmostEqual(done["stalls"], 900 / 20, delta=8)
        self.assertAlmostEqual(done["stalled_s"], done["stalls"] * 3, delta=3)
        self.assertAlmostEqual(done["mb_s"], sent / 1e6 / (self.clock.now - began - done["stalled_s"]), delta=0.02)

    def test_far_carries_a_megabyte_a_second_between_its_stalls(self):
        link = slow_link.Link("far")
        began = self.clock.now
        sent, _ = self.send(link, 300)
        self.assertAlmostEqual(sent / (self.clock.now - began) / 1e6, 1 - 0.75 / 10, delta=0.05)

    def test_the_link_repeats_with_the_seed(self):
        first, _ = self.send(slow_link.Link("worst", seed=3), 200)
        self.clock.now = 1000.0
        second, _ = self.send(slow_link.Link("worst", seed=3), 200)
        self.assertEqual(first, second)


class NetworkChange(unittest.TestCase):
    def test_worst_drops_every_connection_once_a_run_within_its_window(self):
        self.assertEqual(slow_link.half("worst", "link")["network_change_s"], [120, 300])
        changes = []
        with Profile({"soon": {"link": {"network_change_s": [0.2, 0.2]}}}):
            link = slow_link.Link("soon", on_change=lambda: changes.append(time.monotonic()))
            time.sleep(0.6)
        self.assertEqual(len(changes), 1)
        self.assertEqual(link.readout()["changes"], 1)

    def test_a_link_given_up_never_changes(self):
        changes = []
        with Profile({"soon": {"link": {"network_change_s": [0.2, 0.2]}}}):
            slow_link.Link("soon", on_change=lambda: changes.append(1)).stop()
            time.sleep(0.4)
        self.assertEqual(changes, [])


class Extractions(unittest.TestCase):
    def test_a_track_of_the_film_waits_for_its_extraction_once(self):
        import mock_server
        mock_server.FAR[0] = (slow_link.Server("real-quiet"), None)
        try:
            first = mock_server.extraction_wait("m7:3")
            self.assertTrue(60 <= first <= 75)
            mock_server.EXTRACTIONS["m7:3"] -= first - 1
            self.assertAlmostEqual(mock_server.extraction_wait("m7:3"), 1, delta=0.1)
            mock_server.EXTRACTIONS["m7:3"] -= 2
            self.assertEqual(mock_server.extraction_wait("m7:3"), 0)
            self.assertEqual(mock_server.FAR[0][0].counts["extractions"], 1)
        finally:
            mock_server.FAR[0] = None
            mock_server.EXTRACTIONS.clear()


class Profile:
    """A profiles file of its own, for slow_link and for a test server started inside."""

    def __init__(self, table):
        self.table = table

    def __enter__(self):
        handle, self.path = tempfile.mkstemp(suffix=".json")
        with os.fdopen(handle, "w") as f:
            json.dump(self.table, f)
        self.was, slow_link.PROFILES_FILE = slow_link.PROFILES_FILE, self.path
        return self

    def __exit__(self, *_):
        slow_link.PROFILES_FILE = self.was
        os.remove(self.path)


LIVE = {
    "paced": {"server": {"connect_s": 0.3, "answer_s": 0.1, "plan_s": 1.0, "first_byte_s": 0.5, "read_mb_s": 2},
              "link": {"round_trip_s": 0.2, "mbit_s": 400, "network_change_s": 8}},
    "hanging": {"server": {"hang": {"one_in": 1, "s": 1.5}}},
    "faulty": {"server": {"read_mb_s": 2, "reset": {"one_in": 1}, "convert_first_s": 0.5, "convert_segment_s": 0.1,
                          "convert_refused": 1}},
}


@unittest.skipUnless(os.path.exists(FILM), "needs the test film")
class TestServer(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with socket.socket() as s:
            if s.connect_ex(("127.0.0.1", PORT)) == 0:
                raise unittest.SkipTest(f"port {PORT} is taken")
        cls.profile = Profile(LIVE).__enter__()
        env = dict(os.environ, OPENIPTV_NET_PROFILES=cls.profile.path, OPENIPTV_MOCK_VIDEO=FILM, OPENIPTV_MOCK_RUNTIME="900")
        cls.process = subprocess.Popen([sys.executable, os.path.join(HERE, "mock_server.py"), str(PORT)], env=env,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            try:
                cls.control("/mock/mark")
                return
            except OSError:
                time.sleep(0.05)
        raise RuntimeError("test server did not start")

    @classmethod
    def tearDownClass(cls):
        cls.process.kill()
        cls.process.wait()
        cls.profile.__exit__()

    @staticmethod
    def control(path):
        with urllib.request.urlopen(f"http://127.0.0.1:{PORT}{path}", timeout=30) as r:
            return json.loads(r.read())

    def ask(self, connection, method, path, headers=None):
        """Seconds to the answer's head, the answer and its body (cut short: what came)."""
        asked = time.monotonic()
        connection.request(method, path, headers={"X-Emby-Token": "tok", "User-Agent": "Openreel/check", **(headers or {})})
        answer = connection.getresponse()
        head = time.monotonic() - asked
        try:
            body = answer.read()
        except (http.client.IncompleteRead, ConnectionResetError) as cut:
            body = getattr(cut, "partial", b"")
        return head, answer, body, time.monotonic() - asked

    def test_paced_every_part_of_the_profile_waits_as_written(self):
        self.control("/mock/profile?name=paced")
        began = time.monotonic()
        connection = http.client.HTTPConnection("127.0.0.1", PORT, timeout=60)
        first, *_ = self.ask(connection, "GET", "/emby/System/Info/Public")
        again, *_ = self.ask(connection, "GET", "/emby/System/Info/Public")
        plan, *_ = self.ask(connection, "POST", "/emby/Items/m7/PlaybackInfo")
        head, answer, body, took = self.ask(connection, "GET", "/emby/Videos/m7/stream?Static=true", {"Range": "bytes=0-3999999"})
        connection.close()
        self.assertAlmostEqual(first, 0.3 + 0.1 + 0.2, delta=0.1)
        self.assertAlmostEqual(again, 0.1 + 0.2, delta=0.1)
        self.assertAlmostEqual(plan, 1.0 + 0.2, delta=0.1)
        self.assertAlmostEqual(head, 0.5 + 0.2, delta=0.1)
        self.assertEqual(len(body), 4_000_000)
        self.assertAlmostEqual(len(body) / (took - head) / 1e6, 2, delta=0.25)
        quiet = http.client.HTTPConnection("127.0.0.1", PORT, timeout=60)
        self.ask(quiet, "GET", "/emby/System/Info/Public")
        time.sleep(max(0.0, began + 8.5 - time.monotonic()))
        with self.assertRaises(OSError):
            self.ask(quiet, "GET", "/emby/System/Info/Public")
        net = self.control("/mock/net")
        self.assertEqual((net["profile"], net["link"]), ("paced", "paced"))
        self.assertEqual((net["server"]["reads"], net["net"]["changes"]), (1, 1))

    def test_a_read_hangs_within_its_first_512_kb_however_much_was_asked(self):
        self.control("/mock/profile?name=hanging")
        connection = http.client.HTTPConnection("127.0.0.1", PORT, timeout=60)
        connection.request("GET", "/emby/Videos/m7/stream?Static=true", headers={"X-Emby-Token": "tok", "Range": "bytes=0-"})
        answer = connection.getresponse()
        asked = time.monotonic()
        answer.read(slow_link.FAULT_SPAN)
        took = time.monotonic() - asked
        connection.close()
        self.assertGreater(took, 1.5)
        self.assertEqual(self.control("/mock/net")["server"]["hangs"], 1)

    def test_faulty_a_read_is_reset_and_a_conversion_refused_once_as_it_starts(self):
        self.control("/mock/profile?name=faulty")
        self.control("/mock/set?emby_convert=1")
        connection = http.client.HTTPConnection("127.0.0.1", PORT, timeout=60)
        _, answer, body, _ = self.ask(connection, "GET", "/emby/Videos/m7/stream?Static=true", {"Range": "bytes=0-3999999"})
        self.assertEqual(answer.status, 206)
        self.assertLess(len(body), 4_000_000)
        connection = http.client.HTTPConnection("127.0.0.1", PORT, timeout=60)
        _, answer, body, _ = self.ask(connection, "GET", "/emby/Videos/m7/stream?Static=true", {"Range": "bytes=0-"})
        self.assertLess(len(body), slow_link.FAULT_SPAN)
        connection = http.client.HTTPConnection("127.0.0.1", PORT, timeout=60)
        self.ask(connection, "GET", "/emby/Videos/m7/master.m3u8?VideoBitrate=2000000&MediaSourceId=ms-m7")
        refused = self.ask(connection, "GET", "/emby/Videos/m7/hls1/main/0.ts")[1].status
        _, made, segment, _ = self.ask(connection, "GET", "/emby/Videos/m7/hls1/main/0.ts")
        connection.close()
        self.assertEqual((refused, made.status), (503, 200))
        self.assertAlmostEqual(len(segment), 2_000_000 * 3 / 8, delta=50_000)
        net = self.control("/mock/net")
        self.assertEqual((net["server"]["resets"], net["server"]["refused"]), (2, 1))
        self.control("/mock/set?reset=1")
        self.control("/mock/profile?name=none")


if __name__ == "__main__":
    unittest.main()

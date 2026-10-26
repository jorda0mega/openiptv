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
LINK_KEYS = {"connect_s", "round_trip_s", "mbit_s", "stall", "network_change_s", "offline", "metered_after_change"}
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
        self.assertEqual(set(slow_link.half("worst", "link")), {"connect_s", "round_trip_s", "mbit_s", "stall", "network_change_s"})

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

    def test_a_phone_network_swings_5_to_20_mbit_with_a_short_stall_now_and_then(self):
        link = slow_link.Link("phone")
        began = self.clock.now
        sent, rates = self.send(link, 900)
        self.assertTrue(all(5 * 125e3 <= r <= 20 * 125e3 for r in rates))
        self.assertGreater(max(rates) / min(rates), 3)
        self.assertAlmostEqual(sent / (self.clock.now - began) / 1e6, 1.35 * (1 - 1.5 / 30), delta=0.15)
        done = link.readout()
        self.assertAlmostEqual(done["stalls"], 900 / 30, delta=6)
        self.assertTrue(done["stalls"] * 1 <= done["stalled_s"] <= done["stalls"] * 2 + 2)
        connection = link.connection()
        trips = [connection.round_trip() for _ in range(200)]
        self.assertTrue(all(0.06 <= t <= 0.12 for t in trips))
        self.assertGreater(statistics.pstdev(trips), 0.01, "no jitter")
        self.assertEqual(slow_link.half("phone", "server"), {})
        self.assertEqual(slow_link.half("phone", "link")["network_change_s"], [120, 300])

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


class Extreme(unittest.TestCase):
    def setUp(self):
        self.clock, self.real = Clock(), slow_link.time.monotonic
        slow_link.time.monotonic = self.clock

    def tearDown(self):
        slow_link.time.monotonic = self.real

    def test_extreme_is_worst_s_server_with_the_plan_at_30_to_40_s_and_no_setup_of_its_own(self):
        worst, extreme = slow_link.half("worst", "server"), slow_link.half("extreme", "server")
        self.assertEqual(extreme, worst | {"plan_s": [30, 40], "connect_s": 0})

    def test_extreme_s_link_as_written(self):
        self.assertEqual(slow_link.half("extreme", "link"), {
            "connect_s": [2, 5], "round_trip_s": [0.6, 0.8], "mbit_s": 1, "stall": {"every_s": 5, "s": [0.5, 3]},
            "offline": {"per_hour": 2, "s": [10, 30]}, "network_change_s": [120, 300], "metered_after_change": 1})

    def test_extreme_carries_1_mbit_between_stalls_of_half_a_second_to_3_s_every_few_seconds(self):
        link = slow_link.Link("extreme")
        connection, began, step = link.connection(), self.clock.now, slow_link.PIECE / 125e3
        gaps, before = [], None
        while self.clock.now < began + 900:
            at = link.book(connection, slow_link.PIECE)
            if before is not None and at - before > step + 0.3:
                gaps.append((before, at - before - step))
            before = self.clock.now = at
        done = link.readout()
        offline = [w for w in link.schedule()["offline"] if w[0] < 900]
        stalls = [g for at, g in gaps if not any(s - 1 <= at - began <= e for s, e, _ in offline)]
        self.assertAlmostEqual(done["mb_s"], 0.125, delta=0.002)
        self.assertTrue(all(0.5 - step - 0.01 <= g <= 3 + 0.01 for g in stalls), stalls)
        self.assertAlmostEqual(len(stalls), 900 / (5 + 1.75), delta=20)
        self.assertAlmostEqual(done["stalls"], len(stalls), delta=2)

    def test_extreme_is_offline_twice_an_hour_for_10_to_30_s_once_in_each_half_and_repeats_with_the_seed(self):
        windows = slow_link.Link("extreme").schedule()["offline"]
        first_hour = [w for w in windows if w[0] < 3600]
        self.assertEqual(len(first_hour), 2)
        for half_hour, (start, end, kind) in enumerate(first_hour):
            self.assertTrue(1800 * half_hour <= start and end <= 1800 * (half_hour + 1))
            self.assertTrue(10 <= end - start <= 30)
        self.assertEqual([w[2] for w in first_hour], ["hang", "refused"])
        self.assertEqual(slow_link.Link("extreme").schedule(), slow_link.Link("extreme").schedule())
        self.assertNotEqual(slow_link.Link("extreme", seed=2).schedule()["offline"], windows)

    def test_every_connection_waits_out_an_offline_window(self):
        link = slow_link.Link("extreme")
        start, end, _ = link.schedule()["offline"][0]
        connection = link.connection()
        self.clock.now = link.began + start + 0.5
        self.assertAlmostEqual(link.book(connection, slow_link.PIECE), link.began + end, delta=0.01)
        self.assertEqual(link.offline(link.began + start + 0.5), "hang")
        self.assertIsNone(link.offline(link.began + end + 0.1))

    def test_the_schedule_names_the_change_and_counts_from_the_run_s_start_however_far_in_it_begins(self):
        fresh, later = slow_link.Link("extreme"), slow_link.Link("extreme", ago=600)
        self.assertEqual(fresh.schedule(), later.schedule())
        self.assertTrue(120 <= fresh.schedule()["change_s"] <= 300)
        self.assertTrue(fresh.schedule()["metered_after_change"])
        self.assertFalse(slow_link.Link("worst").schedule()["metered_after_change"])
        self.assertEqual(later.began, self.clock.now - 600)
        self.assertAlmostEqual(later.schedule()["change_at"] - fresh.schedule()["change_at"], -600, delta=0.01)
        self.assertEqual(slow_link.Link("worst").schedule()["offline"], [])

    def test_a_refused_window_drops_every_open_connection_as_it_begins(self):
        slow_link.time.monotonic = self.real
        dropped = []
        with Profile({"blinking": {"link": {"offline": {"per_hour": 3600, "s": [0.2, 0.2]}}}}):
            link = slow_link.Link("blinking", on_offline=lambda: dropped.append(time.monotonic() - link.began))
            time.sleep(2.1)
            link.stop()
        refused = [s for s, _, kind in link.schedule()["offline"] if kind == "refused" and s < 2]
        self.assertEqual(len(dropped), len(refused))
        for at, start in zip(dropped, refused):
            self.assertAlmostEqual(at, start, delta=0.1)


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
    "offline": {"link": {"offline": {"per_hour": 3600, "s": [0.6, 0.6]}}},
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

    def test_offline_a_request_waits_out_a_hang_window_and_is_reset_in_a_refused_one(self):
        self.control("/mock/profile?name=offline")
        windows = self.control("/mock/net")["schedule"]["offline"]
        began = time.monotonic()
        hang = next(w for w in windows if w[2] == "hang" and w[0] > 0.3)
        refused = next(w for w in windows if w[2] == "refused" and w[0] > hang[1])
        time.sleep(max(0.0, began + hang[0] + 0.1 - time.monotonic()))
        connection = http.client.HTTPConnection("127.0.0.1", PORT, timeout=60)
        head, *_ = self.ask(connection, "GET", "/emby/System/Info/Public")
        self.assertAlmostEqual(time.monotonic() - began, hang[1], delta=0.15)
        connection.close()
        time.sleep(max(0.0, began + refused[0] + 0.1 - time.monotonic()))
        with self.assertRaises(OSError):
            self.ask(http.client.HTTPConnection("127.0.0.1", PORT, timeout=60), "GET", "/emby/System/Info/Public")
        self.assertEqual(self.control("/mock/net")["profile"], "offline", "/mock/ answers in a window")
        self.control("/mock/profile?name=none")


if __name__ == "__main__":
    unittest.main()

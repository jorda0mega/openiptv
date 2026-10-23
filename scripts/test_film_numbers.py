#!/usr/bin/env python3
"""film_numbers.py on lines as the film runner prints them.

    python3 scripts/test_film_numbers.py
"""

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import film_numbers  # noqa: E402

BASELINE = """\
== link none 20:32, 4210 MB free
[none] REAL link start ready: tap to first frame 2.4 s at 216 s (a new player) | plan 0.00 s (kept), then 0.16 s to the open, open 2.23 s, first frame 0.10 s after, subtitles hidden, read before the start none | relay reads 6, from the device 10.0 MB, from the server 1 reads 6.6 MB first byte up to 203 ms | kept start: not done at the tap, 1 of 3 reads done, 2.1 s after it began | 8 ms at 0.00% 0.52 MB: device 0.52, server 0.00 | server: connect 0.51 s, first byte 0.19 s
[none] REAL link start cold: tap to first frame 1.3 s at 216 s (a new player) | plan 0.41 s (asked), then 0.11 s to the open, open 0.58 s, first frame 0.65 s after, subtitles hidden, read before the start none | relay reads 5, from the device 0.5 MB, from the server 5 reads 2.7 MB first byte up to 227 ms | kept start: unused, nothing fetched ahead | server: connect 0.52 s, first byte 1.20 s
[none] REAL link playback start: tap to first frame 0.7 s at 216 s (a new player) | plan 0.00 s (kept), then 0.11 s to the open, open 0.57 s, first frame 0.00 s after, subtitles off, read before the start none | relay reads 6, from the device 10.0 MB, from the server 1 reads 1.6 MB first byte up to 238 ms | kept start: used | server: connect 0.51 s, first byte 0.20 s
[none] REAL link first 120 s: pauses 2: 500 1500 ms | film 400.0 MB from the server, 3.20 MB/s since the tap | original | server: connect 0.51 s, first byte 0.20 s
[none] REAL link lower quality: decided 3.1 s after the tap, its first frame 10.6 s after the tap | server: connect 0.51 s, first byte 0.20 s
[none] REAL link jump +5 min: 273 ms 0.3 MB to the next frame (MB from the server) | server: connect 0.51 s, first byte 0.20 s
[none] REAL link subtitles: switch t=245169 n=2 from=off to=own lang=eng hidden=yes ; after=900 ; no stall ; read 0.0 MB from the device | server: connect 0.51 s, first byte 0.20 s
[none] test server real-quiet over real-quiet: 140 reads, 0 hung, 0 reset, 2 conversions, 0 refused, 0 subtitle extractions | link - MB/s while carrying data, 300.0 MB, 0 stalls (0.0 s waited), 0 network changes
"""

AS_SEEN_NOW = """\
REAL start card 1 cold: tap to first frame 9.8 s (a new player) | plan 0.61 s (asked), then 0.17 s to the open, open 6.53 s, first frame 2.50 s after, subtitles hidden, read before the start none | relay reads 5, from the device 7.6 MB, from the server 4 reads 13.3 MB first byte up to 2283 ms | 11 ms at 0.00% 0.52 MB: device 0.00, server 0.52
REAL start card 1 ready (old way): tap to first frame 10.6 s (a new player) | plan 0.00 s (kept), then 0.11 s to the open, open 10.26 s, first frame 0.27 s after
REAL playback after 241 s: 1510.4 MB from the server, 6.28 MB/s on average
REAL converted start: converted 2.26 s: server 1100 ms client 1161 ms (p162 p162 p178 p1 p1 s758) | converted 5.0 Mbps
REAL jump -30 s: 346 ms 4.2 MB to the next frame (MB from the server)
REAL subtitles to=own: switch t=308832 n=2 from=own to=own lang=es hidden=no ; no line in 20 s ; no stall ; read 583.7 MB from the device
"""

TWO_PLATFORMS = """\
== ios none unmetered 09:10, 4100 MB free
[ios none unmetered] REAL link start ready: tap to first frame 1.1 s at 216 s (a new player) | plan 0.00 s (kept), start ahead done; took ahead: open 9.62 MB in 4 reads, rest 0.31 MB in 3 reads, then 0.12 s to the open, open 0.50 s, first frame 0.10 s after | server: connect 0.51 s, first byte 0.19 s
[ios phone metered daily] REAL link start ready: tap to first frame 2.9 s at 216 s (a new player) | plan 0.00 s (kept), start ahead not asked, not allowed now: network expensive; took ahead: open 0.00 MB in 0 reads, rest 0.00 MB in 2 reads, then 0.14 s to the open, open 2.10 s | server: connect 0.51 s, first byte 0.19 s
[tvos none unmetered] REAL link start ready: tap to first frame 1.4 s at 216 s (a new player) | plan 0.00 s (kept), start ahead done; took ahead: open 9.80 MB in 5 reads, rest 0.00 MB in 1 read, then 0.10 s to the open, open 0.70 s | server: connect 0.51 s, first byte 0.19 s
"""


class Extract(unittest.TestCase):
    def test_each_platform_and_network_apart_and_what_a_card_took_ahead(self):
        numbers = film_numbers.extract(TWO_PLATFORMS.splitlines(), "real-quiet", None)
        self.assertEqual(numbers["real-quiet"]["start ready: tap to first frame"]["values"], [1.1])
        self.assertEqual(numbers["real-quiet"]["start ready: MB ahead, the open's own reads"]["values"], [9.62])
        self.assertEqual(numbers["real-quiet"]["start ready: reads ahead, the open's own"]["values"], [4.0])
        self.assertEqual(numbers["real-quiet"]["start ready: MB ahead, the rest"]["values"], [0.31])
        self.assertEqual(numbers["real-quiet"]["start ready: open"]["values"], [0.5])
        metered = numbers["real-quiet metered daily"]
        self.assertEqual(metered["start ready: tap to first frame"]["values"], [2.9])
        self.assertEqual(metered["start ready: MB ahead, the open's own reads"]["values"], [0.0])
        self.assertEqual(metered["start ready: reads ahead, the rest"]["values"], [2.0])
        self.assertEqual(numbers["real-quiet tvos"]["start ready: reads ahead, the rest"]["values"], [1.0])

    def test_the_baseline_split_by_the_servers_own_state(self):
        numbers = film_numbers.extract(BASELINE.splitlines(), "probe", None)
        quiet, busy = numbers["real-quiet"], numbers["real-busy"]
        self.assertEqual(busy["start cold: plan"]["values"], [0.41])
        self.assertNotIn("start cold: plan", quiet)
        self.assertEqual(quiet["start ready: tap to first frame"]["values"], [2.4])
        self.assertEqual(quiet["start ready: slowest first byte"]["values"], [0.203])
        self.assertEqual(quiet["start ready: kept start not done at the tap"]["values"], [1.0])
        self.assertEqual(quiet["playback start: kept start used"]["values"], [1.0])
        self.assertEqual(busy["start cold: kept start unused"]["values"], [1.0])
        self.assertEqual(quiet["playback: pauses"]["values"], [2.0])
        self.assertEqual(quiet["playback: paused"]["values"], [2.0])
        self.assertEqual(quiet["playback: MB/s"]["values"], [3.2])
        self.assertAlmostEqual(quiet["conversion wait"]["values"][0], 7.5)
        self.assertEqual(quiet["jump +5 min"]["values"], [0.273])
        self.assertEqual(quiet["subtitle switch: first line"]["values"], [0.9])
        self.assertNotIn("Mac free disk", quiet)

    def test_unprobed_lines_go_where_they_are_told(self):
        numbers = film_numbers.extract(BASELINE.splitlines(), "probe", "mock")
        self.assertEqual(numbers["mock"]["Mac free disk"]["values"], [4210.0])
        self.assertEqual(numbers["mock"]["link: network changes"]["values"], [0.0])

    def test_the_old_test_without_its_old_way(self):
        line = film_numbers.extract(AS_SEEN_NOW.splitlines(), "real-busy", None)["real-busy"]
        self.assertEqual(line["start cold: open"]["values"], [6.53])
        self.assertNotIn("start ready: open", line)
        self.assertEqual(line["playback: MB/s"]["values"], [6.28])
        self.assertEqual(line["converted start: open"]["values"], [2.26])
        self.assertEqual(line["conversion wait: first segment"]["values"], [0.758])
        self.assertEqual(line["jump -30 s: MB"]["values"], [4.2])
        self.assertEqual(line["subtitle switch: no line"]["values"], [1.0])

    def test_numbers_only(self):
        numbers = film_numbers.extract((BASELINE + AS_SEEN_NOW).splitlines(), "probe", "mock")
        for lines in numbers.values():
            for line in lines.values():
                self.assertTrue(all(isinstance(n, float) for n in line["values"]))


class Compare(unittest.TestCase):
    def table(self, real, mock, unit="s"):
        return film_numbers.compare({"real-busy": {"open": {"unit": unit, "values": real}}},
                                    {"real-busy": {"open": {"unit": unit, "values": mock}}})

    def test_more_than_20_percent_off_is_flagged(self):
        self.assertTrue(self.table([1.0, 2.0, 3.0], [2.5]).endswith("+25% !"))
        self.assertTrue(self.table([2.0], [2.3]).endswith("+15%"))

    def test_a_small_gap_is_not_flagged_however_many_percent(self):
        self.assertTrue(self.table([0.05], [0.1]).endswith("+100%"))

    def test_a_share_is_off_by_points(self):
        self.assertTrue(self.table([1.0, 0.0, 0.0], [1.0, 1.0], "share").endswith("+67 pt !"))

    def test_a_line_the_test_server_lacks_is_named(self):
        table = film_numbers.compare({"real-busy": {"open": {"unit": "s", "values": [1.0]}, "plan": {"unit": "s", "values": [1.0]}}},
                                     {"real-busy": {"open": {"unit": "s", "values": [1.0]}}})
        self.assertIn("not on the test server: plan", table)


if __name__ == "__main__":
    unittest.main()

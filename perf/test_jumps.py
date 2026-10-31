import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import jumps


class SeeksTests(unittest.TestCase):
    def test_a_cache_range_that_starts_below_zero_is_read(self):
        entry = {"timestamp": "2026-10-29 00:05:01.250000-0400",
                 "eventMessage": "PERF cache at 12.0 by +10 ahead 4.5 readahead 30.0 ranges -0.04-30.0,41.5-60.0"}
        with tempfile.NamedTemporaryFile("w", suffix=".ndjson", delete=False) as log:
            log.write(json.dumps(entry) + "\n")
        try:
            found = jumps.seeks(log.name)
        finally:
            os.unlink(log.name)
        self.assertEqual(len(found), 1)
        self.assertEqual(found[0][1:5], (12.0, 10, 4.5, 30.0))
        self.assertTrue(found[0][5], "a landing inside the range from -0.04 s was not seen as kept")


if __name__ == "__main__":
    unittest.main()

#!/usr/bin/env python3

import gzip
import json
import re
import unittest

import sentry_capture


def envelope(*items):
    parts = [json.dumps({"event_id": "0" * 32}).encode()]
    for kind, payload, sized in items:
        header = {"type": kind, "length": len(payload)} if sized else {"type": kind}
        parts += [json.dumps(header).encode(), payload]
    return b"\n".join(parts) + b"\n"


class SentryCaptureTests(unittest.TestCase):
    def test_unpacks_what_the_sdk_compresses(self):
        body = envelope(("session", b"{}", True))
        self.assertEqual(sentry_capture.unpacked(gzip.compress(body), "gzip"), body)
        self.assertEqual(sentry_capture.unpacked(body, ""), body)

    def test_reads_items_with_and_without_a_length(self):
        body = envelope(("event", b'{"message":{"formatted":"a\\nb"}}', True), ("attachment", b"one\ntwo", True),
                        ("trace_metric", b'{"items":[]}', False), ("session", b"{}", True))
        self.assertEqual([kind for kind, _ in sentry_capture.items(body)], ["event", "attachment", "trace_metric", "session"])
        self.assertEqual(sentry_capture.items(body)[1][1], b"one\ntwo")

    def test_counts_metrics_problems_and_leak_words_only(self):
        metrics = json.dumps({"items": [{"name": "live.start"}, {"name": "live.start"}, {"name": "made.up"}]}).encode()
        problem = json.dumps({"message": {"formatted": "live_did_not_start"}, "tags": {"reason": "status_404"}}).encode()
        crash = json.dumps({"level": "fatal", "exception": {"values": [{"value": "at 127.0.0.1:8890"}]}}).encode()
        body = envelope(("trace_metric", metrics, True), ("event", problem, True), ("event", crash, True))
        counts = sentry_capture.seen([body, body], {"address": re.compile(rb"127\.0\.0\.1"), "token": re.compile(rb"tk0")},
                                     ["live.start", "live.switch"], ["live_did_not_start"])
        self.assertEqual(counts, {"envelopes": 2, "items": {"trace_metric": 2, "event": 4}, "crashes": 2,
                                  "metrics": {"live.start": 4, "live.switch": 0}, "problems": {"live_did_not_start": 2},
                                  "leaks": {"address": 2, "token": 0}})

    def test_the_envelope_address(self):
        self.assertTrue(sentry_capture.ENVELOPE.match("/api/1/envelope/"))
        self.assertFalse(sentry_capture.ENVELOPE.match("/emby/api/1/envelope/x"))


if __name__ == "__main__":
    unittest.main()

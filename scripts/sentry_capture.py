"""The app's Sentry envelopes on the test server, read back as counts only.

mock_server.py keeps each envelope it gets at POST /api/<project>/envelope/ in memory,
unpacked, and answers GET /mock/sentry_seen?since= with seen() of the ones since then.
The leak words (the made-up login, the token, the server's address, the titles) stay in
the server: the test gets how many times each was found, never the words or the envelopes.
"""

import gzip
import json
import re
import zlib

ENVELOPE = re.compile(r"^/api/\d+/envelope/$")


def unpacked(body, encoding):
    if encoding == "gzip":
        return gzip.decompress(body)
    if encoding == "deflate":
        return zlib.decompress(body)
    return body


def line_end(data, at):
    end = data.find(b"\n", at)
    return len(data) if end < 0 else end


def items(envelope):
    found = []
    at = line_end(envelope, 0) + 1
    while at < len(envelope):
        end = line_end(envelope, at)
        try:
            header = json.loads(envelope[at:end])
        except ValueError:
            break
        length = header.get("length")
        start = end + 1
        stop = start + length if length is not None else line_end(envelope, start)
        found.append((header.get("type", "unknown"), envelope[start:stop]))
        at = stop + 1
    return found


def seen(envelopes, leaks, metric_names, problem_kinds):
    counts = {"envelopes": len(envelopes), "items": {}, "crashes": 0, "metrics": {name: 0 for name in metric_names},
              "problems": {kind: 0 for kind in problem_kinds}, "leaks": {name: 0 for name in leaks}}
    for envelope in envelopes:
        for name, pattern in leaks.items():
            counts["leaks"][name] += len(pattern.findall(envelope))
        for kind, payload in items(envelope):
            counts["items"][kind] = counts["items"].get(kind, 0) + 1
            try:
                body = json.loads(payload)
            except ValueError:
                continue
            if kind == "trace_metric":
                for metric in body.get("items", []):
                    if metric.get("name") in counts["metrics"]:
                        counts["metrics"][metric["name"]] += 1
            if kind == "event":
                counts["crashes"] += body.get("level") == "fatal"
                message = (body.get("message") or {}).get("formatted")
                if message in counts["problems"]:
                    counts["problems"][message] += 1
    return counts

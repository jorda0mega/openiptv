"""Slow-network profiles, shared by the test server (OPENIPTV_MOCK_PROFILE)
and the throttling proxy (throttle_proxy.py). The test server's CONTROL
comment says what each part does per connection, per request and per link.
Every random draw comes from the seed, so a run repeats."""

import random
import threading
import time
from typing import NamedTuple, Optional, Tuple

PIECE = 16 << 10


class Profile(NamedTuple):
    connect: float = 0.0
    request: Tuple[float, float] = (0.0, 0.0)
    first_byte: Optional[Tuple[float, float]] = None
    connection_rate: float = 0.0
    link_rate: float = 0.0
    link_stall: Optional[Tuple[float, float, float]] = None


PROFILES = {
    "busy": Profile(connect=0.5, first_byte=(2, 9), connection_rate=10e6, link_rate=10e6),
    "far": Profile(request=(0.08, 0.15), connection_rate=1e6, link_rate=1e6, link_stall=(10, 0.5, 1)),
    "worst": Profile(connect=0.5, request=(0.4, 0.4), first_byte=(2, 9), connection_rate=0.25e6, link_rate=0.5e6,
                     link_stall=(20, 3, 3)),
}


def opens_file(path):
    return ("/Videos/" in path or "/Audio/" in path) and "/stream" in path


class Link:
    def __init__(self, name, seed=1):
        self.name, self.profile, self.seed = name, PROFILES[name], seed
        self.lock = threading.Lock()
        self.due = 0.0
        self.opened = 0
        self.fades = random.Random(f"{seed}:link")
        self.fade = (float("inf"), float("inf"))
        if self.profile.link_stall:
            self.fade = self.next_fade(time.monotonic())

    def next_fade(self, after):
        every, shortest, longest = self.profile.link_stall
        start = after + self.fades.uniform(every * 0.75, every * 1.25)
        return start, start + self.fades.uniform(shortest, longest)

    def connection(self):
        with self.lock:
            self.opened += 1
            return Connection(self, self.opened)

    def book(self, connection, size):
        """When `size` more bytes of `connection` may go."""
        p = self.profile
        with self.lock:
            at = max(time.monotonic(), connection.due, self.due)
            while self.fade[1] <= at:
                self.fade = self.next_fade(self.fade[1])
            if self.fade[0] <= at:
                at = self.fade[1]
            connection.due = at + size / p.connection_rate
            self.due = at + size / p.link_rate
            return at


class Connection:
    def __init__(self, link, number):
        self.link = link
        self.first_bytes = random.Random(f"{link.seed}:{number}:first")
        self.round_trips = random.Random(f"{link.seed}:{number}:trips")
        self.due = 0.0
        self.answered = False

    def round_trip(self):
        return self.round_trips.uniform(*self.link.profile.request)

    def wait_before_answer(self, opens_file):
        """Seconds before this request's answer may start: the connection's
        setup on its first, the round trip on each, and the server's own
        wait when it opens a file."""
        p = self.link.profile
        wait = self.round_trip() + (0 if self.answered else p.connect)
        if opens_file and p.first_byte:
            wait += self.first_bytes.uniform(*p.first_byte)
        self.answered = True
        return wait

    def send(self, write, data):
        for at in range(0, len(data), PIECE):
            piece = data[at:at + PIECE]
            time.sleep(max(0.0, self.link.book(self, len(piece)) - time.monotonic()))
            write(piece)


class ShapedWriter:
    """A handler's wfile, paced as its connection's profile says while `on`."""

    def __init__(self, raw, connection):
        self.raw, self.connection, self.on = raw, connection, True

    @property
    def closed(self):
        return self.raw.closed

    def write(self, data):
        if self.on:
            self.connection.send(self.raw.write, bytes(data))
        else:
            self.raw.write(data)
        return len(data)

    def flush(self):
        self.raw.flush()

    def close(self):
        self.raw.close()

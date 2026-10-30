"""Timing profiles, shared by the test server (OPENIPTV_MOCK_PROFILE) and the
throttling proxy (throttle_proxy.py), read from net_profiles.json (or the file
OPENIPTV_NET_PROFILES names): times and rates only, taken from the real
server's printed runs.

A profile has two halves. Its server half is the far end as the device sees
it, the home link inside: "connect_s" for a new connection (TCP and TLS),
"answer_s" of work before any answer, "plan_s" before PlaybackInfo's,
"page_s" before a page of the library listing's, "first_byte_s" before a
file read's, "read_mb_s" each read's pace, "convert_first_s" to a
converted version's first segment, "convert_segment_s" to make each next one,
"subtitle_extract_s" to take one of the film's own subtitle tracks out,
"capacity" (the work the server does at once: each request under way gets
an even share of it, at most a whole one, so an answer waits on every other
request the server is working on, the app's own included), "file_wake" ({idle_s, s}: a
film read when none came for `idle_s` waits `s` more for its first byte,
a disk woken), and its faults: "hang" ({one_in, s}: a read stops that long, part way), "reset"
({one_in}: a read's connection reset part way), "convert_refused" (503s each
time a conversion starts). Its link half is a network in between:
"connect_s" more for each new connection, "round_trip_s" for each request,
"mbit_s" for every connection together ({low, high, every_s}: it swings),
"stall" ({every_s, s}: every connection stops at once, about that often),
"offline" ({per_hour, s}: fully offline that long, once in each share of the
hour at a drawn second; the first window of each pair hangs every connection
as a dead link does, the second refuses every new one and drops the open
ones as it begins), "network_change_s" (once a run, that long in: every open
connection dropped at once) and "metered_after_change" (1: the change is from
Wi-Fi to a phone network, which the app is told with -debugNetwork). The test server takes the server half, and the link half unless
the proxy carries it; the proxy takes only the link half.

A spec is a number; [low, high], drawn evenly; or {median, spread, low,
high}, drawn heavy-tailed (lognormal) and held within. A profile that is a
name is that profile; "base" in a half puts the half's numbers over that
profile's. Every draw comes from the seed: a connection's from its number, a
read's from its number, a conversion's from its start's number, the link's
from its own, so a run repeats."""

import bisect
import json
import math
import os
import random
import threading
import time
from typing import NamedTuple, Optional

PIECE = 16 << 10
FAULT_SPAN = 512 << 10
OFFLINE_HOURS = 2
PROFILES_FILE = os.environ.get("OPENIPTV_NET_PROFILES") or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                                                        "net_profiles.json")


def profiles():
    with open(PROFILES_FILE) as f:
        return json.load(f)


def half(name, part, table=None):
    """Profile `name`'s "server" or "link" half: {} when it has none."""
    if name == "none":
        return {}
    table = table or profiles()
    entry = table[name]
    if isinstance(entry, str):
        return half(entry, part, table)
    own = dict(entry.get(part) or {})
    base = own.pop("base", None)
    return {**(half(base, part, table) if base else {}), **own}


def draw(spec, rng):
    if spec is None:
        return 0.0
    if isinstance(spec, (int, float)):
        return float(spec)
    if isinstance(spec, list):
        return rng.uniform(*spec)
    return min(spec["high"], max(spec["low"], rng.lognormvariate(math.log(spec["median"]), spec["spread"])))


def opens_file(path):
    return ("/Videos/" in path or "/Audio/" in path) and "/stream" in path


class Read(NamedTuple):
    """A file read as the server answers it: its first byte's work, its pace
    (bytes a second), and how far into it it hangs (for `hang` s) or its
    connection is reset: a share of its first FAULT_SPAN bytes, the least the
    app's relay asks at once, so a fault comes before the player has moved on,
    however much was asked; `wake`, a disk woken before its first byte."""
    number: int
    first_byte: float
    rate: float
    hang_at: Optional[float]
    hang: float
    reset_at: Optional[float]
    wake: float = 0.0


class Work:
    """The server's work shared out: each job under way gets an even share
    of `capacity` (at most a whole one), so a job takes longer the more
    there are."""

    def __init__(self, capacity, clock=time.monotonic):
        self.capacity, self.clock = capacity, clock
        self.turn = threading.Condition()
        self.left = {}
        self.at = clock()
        self.jobs = 0
        self.most = 0

    def share(self):
        busy = sum(1 for left in self.left.values() if left > 0)
        return min(1.0, self.capacity / busy) if busy else 1.0

    def advance(self):
        now = self.clock()
        done = (now - self.at) * self.share()
        for job in self.left:
            self.left[job] -= done
        self.at = now

    def do(self, seconds):
        if seconds <= 0:
            return
        with self.turn:
            self.advance()
            self.jobs += 1
            job = self.jobs
            self.left[job] = seconds
            self.most = max(self.most, len(self.left))
            self.turn.notify_all()
            while self.left[job] > 1e-4:
                self.turn.wait(self.left[job] / self.share())
                self.advance()
            del self.left[job]
            self.turn.notify_all()


class Conversion:
    """A converted version started at segment `first`: its first segment
    ready `first_s` after it began, each next one `segment_s` after the last,
    and `refusals` 503s before it answers."""

    def __init__(self, first, began, first_s, segment_s, rng=None, refusals=0):
        self.first, self.segment_s, self.rng, self.refusals = first, segment_s, rng, refusals
        self.ready = [began + draw(first_s, rng)]

    def ready_at(self, n):
        while len(self.ready) <= n - self.first:
            self.ready.append(self.ready[-1] + draw(self.segment_s, self.rng))
        return self.ready[n - self.first]

    def made(self, now):
        while self.ready[-1] <= now:
            self.ready_at(self.first + len(self.ready))
        return sum(1 for at in self.ready if at <= now)

    def refuse(self):
        self.refusals -= 1
        return self.refusals >= 0


class Server:
    """A profile's server half, and what it has done (`counts`)."""

    def __init__(self, name, seed=1):
        self.name, self.seed, self.p = name, seed, half(name, "server")
        self.lock = threading.Lock()
        self.counts = dict(reads=0, hangs=0, resets=0, conversions=0, refused=0, extractions=0)
        self.work = Work(self.p["capacity"]) if self.p.get("capacity") else None
        self.last_read = -math.inf

    def count(self, key):
        with self.lock:
            self.counts[key] += 1
            return self.counts[key]

    def setup(self, rng):
        return draw(self.p.get("connect_s"), rng)

    def answer(self, kind, rng):
        """The server's work before an answer that isn't a file read's: "plan"
        PlaybackInfo, "page" a page of the library listing, else any other."""
        spec = {"plan": "plan_s", "page": "page_s"}.get(kind, "answer_s")
        return draw(self.p.get(spec, self.p.get("answer_s")), rng)

    def serve(self, seconds):
        """`seconds` of the server's work, shared with every other request under way when it has a capacity."""
        if self.work:
            self.work.do(seconds)
        else:
            time.sleep(seconds)

    def read(self, now=None):
        number = self.count("reads")
        rng = random.Random(f"{self.seed}:read:{number}")
        now = time.monotonic() if now is None else now
        wake = self.p.get("file_wake")
        with self.lock:
            woken = wake and now - self.last_read >= wake["idle_s"]
            self.last_read = now
        hang, reset = self.p.get("hang"), self.p.get("reset")
        first_byte, rate = draw(self.p.get("first_byte_s"), rng), draw(self.p.get("read_mb_s"), rng) * 1e6
        woke = draw(wake["s"], rng) if woken else 0.0
        hangs, hang_at, hang_s = rng.random(), rng.random(), draw(hang and hang["s"], rng)
        resets, reset_at = rng.random(), rng.random()
        return Read(number, first_byte, rate or math.inf,
                    hang_at if hang and hangs < 1 / hang["one_in"] else None, hang_s,
                    reset_at if reset and resets < 1 / reset["one_in"] else None, woke)

    def conversion(self, first, began):
        number = self.count("conversions")
        return Conversion(first, began, self.p.get("convert_first_s"), self.p.get("convert_segment_s"),
                          random.Random(f"{self.seed}:convert:{number}"), self.p.get("convert_refused", 0))

    def extraction(self, track):
        return draw(self.p.get("subtitle_extract_s"), random.Random(f"{self.seed}:extract:{track}"))


class Link:
    """A profile's link half for every connection over it, and what it has
    done (`counts`). `on_change` drops every open connection at the network
    change, `on_offline` as a refusing offline window begins. `ago` begins
    the run that many seconds in, so a check reaches the change or a window
    at once."""

    def __init__(self, name, seed=1, on_change=None, on_offline=None, ago=0.0):
        self.name, self.seed, self.p = name, seed, half(name, "link")
        self.lock = threading.Lock()
        self.due = 0.0
        self.began = time.monotonic() - ago
        self.wall_began = time.time() - ago
        self.windows = self.offline_windows()
        self.starts = [start for start, _, _ in self.windows]
        self.fades = random.Random(f"{seed}:link")
        self.fade = (math.inf, math.inf)
        if self.p.get("stall"):
            self.fade = self.next_fade(self.began)
        self.swings = random.Random(f"{seed}:rate")
        self.rate, self.rate_until = math.inf, self.began
        self.counts = dict(connections=0, stalls=0, changes=0, sent=0, carrying_s=0.0, stalled_s=0.0, offline_s=0.0)
        self.change_s = draw(self.p["network_change_s"], random.Random(f"{seed}:change")) if self.p.get("network_change_s") else None
        self.timers = []
        if self.change_s is not None and on_change and self.change_s > ago:
            self.after(self.change_s - ago, self.change, on_change)
        if on_offline:
            self.next_drop(on_offline)

    def after(self, seconds, action, *args):
        timer = threading.Timer(seconds, action, args)
        timer.daemon = True
        with self.lock:
            self.timers.append(timer)
        timer.start()

    def change(self, on_change):
        with self.lock:
            self.counts["changes"] += 1
        on_change()

    def offline_windows(self):
        """(start, end, "hang" or "refused"), seconds from the run's start, for its first OFFLINE_HOURS."""
        spec = self.p.get("offline")
        if not spec:
            return []
        rng, share, windows = random.Random(f"{self.seed}:offline"), 3600 / spec["per_hour"], []
        for n in range(int(spec["per_hour"] * OFFLINE_HOURS)):
            length = draw(spec["s"], rng)
            start = n * share + rng.uniform(0, share - length)
            windows.append((start, start + length, ("hang", "refused")[n % 2]))
        return windows

    def window(self, at):
        """The offline window at monotonic `at`, or None."""
        n = bisect.bisect_right(self.starts, at - self.began) - 1
        return self.windows[n] if n >= 0 and at - self.began < self.windows[n][1] else None

    def offline(self, at):
        window = self.window(at)
        return window and window[2]

    def offline_until(self, at):
        window = self.window(at)
        return self.began + window[1] if window else at

    def next_drop(self, on_offline, after=None):
        elapsed = time.monotonic() - self.began
        upcoming = [start for start, _, kind in self.windows if kind == "refused" and start > (after if after is not None else elapsed - 0.001)]
        if upcoming:
            self.after(max(0.0, upcoming[0] - elapsed), self.drop, on_offline, upcoming[0])

    def drop(self, on_offline, start):
        on_offline()
        self.next_drop(on_offline, after=start)

    def stop(self):
        with self.lock:
            timers, self.timers = self.timers, []
        for timer in timers:
            timer.cancel()

    def schedule(self):
        """When the network change and the first hour's offline windows come, in seconds from the run's
        start, and the change as a time of day (change_at) for the app's -debugNetwork: times only."""
        return {"change_s": self.change_s, "change_at": None if self.change_s is None else self.wall_began + self.change_s,
                "metered_after_change": bool(self.p.get("metered_after_change")),
                "offline": [list(window) for window in self.windows if window[0] < 3600]}

    def next_fade(self, after):
        stall = self.p["stall"]
        start = after + self.fades.uniform(stall["every_s"] * 0.75, stall["every_s"] * 1.25)
        return start, start + draw(stall["s"], self.fades)

    def rate_at(self, at):
        """Bytes a second for every connection together at `at`."""
        spec = self.p.get("mbit_s")
        if not isinstance(spec, dict):
            return spec * 125e3 if spec else math.inf
        while self.rate_until <= at:
            self.rate_until += self.swings.uniform(spec["every_s"] * 0.75, spec["every_s"] * 1.25)
            self.rate = spec["low"] * (spec["high"] / spec["low"]) ** self.swings.random() * 125e3
        return self.rate

    def connection(self):
        with self.lock:
            self.counts["connections"] += 1
            return Connection(self, self.counts["connections"])

    def book(self, connection, size):
        """When `size` more bytes of `connection` may go."""
        with self.lock:
            now = time.monotonic()
            at = max(now, connection.due, self.due)
            if self.window(at):
                until = self.offline_until(at)
                self.counts["offline_s"] += until - at
                at = until
            while self.fade[1] <= at:
                self.counts["stalls"] += 1
                self.fade = self.next_fade(self.fade[1])
            if self.fade[0] <= at:
                self.counts["stalled_s"] += self.fade[1] - at
                at = self.fade[1]
            connection.due = at + size / connection.rate
            self.due = at + size / self.rate_at(at)
            self.counts["carrying_s"] += self.due - at
            self.counts["sent"] += size
            return at

    def readout(self):
        """What it has done, numbers only: its pace while it carried data, and
        the seconds data waited on its stalls."""
        with self.lock:
            counts = dict(self.counts)
        sent, carrying = counts.pop("sent") / 1e6, counts.pop("carrying_s")
        elapsed = time.monotonic() - self.began
        return counts | {"mb": round(sent, 1), "stalled_s": round(counts["stalled_s"], 1), "offline_s": round(counts["offline_s"], 1),
                         "offline": sum(1 for start, _, _ in self.windows if start <= elapsed),
                         "mb_s": round(sent / carrying, 2) if "mbit_s" in self.p and carrying > 0 else None}


class Connection:
    """One connection over a link: its writes go at the link's pace and no
    faster than the read under way (`rate`, the server's pace); its round
    trips and the server's waits are drawn from its number."""

    def __init__(self, link, number):
        self.link = link
        self.draws = random.Random(f"{link.seed}:{number}:trips")
        self.answers = random.Random(f"{link.seed}:{number}:answers")
        self.due = 0.0
        self.rate = math.inf
        self.answered = False

    def round_trip(self):
        return draw(self.link.p.get("round_trip_s"), self.draws)

    def handshake(self):
        return draw(self.link.p.get("connect_s"), self.draws)

    def wait_before_answer(self):
        """The link's part: the round trip, and the handshakes on the first request."""
        wait = self.round_trip() + (0 if self.answered else self.handshake())
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

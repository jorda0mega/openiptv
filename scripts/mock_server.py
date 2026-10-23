#!/usr/bin/env python3
"""Fake Xtream panel + Emby server for developing without real credentials.

    python3 scripts/mock_server.py 8765
    OPENIPTV_XTREAM_URL=http://127.0.0.1:8765 OPENIPTV_XTREAM_USER=u OPENIPTV_XTREAM_PASS=p \
    OPENIPTV_EMBY_URL=http://127.0.0.1:8765 OPENIPTV_EMBY_USER=u OPENIPTV_EMBY_PASS=p \
    cargo run -p openiptv-probe

The panel runs at UTC+1, channel 5's short EPG deliberately disagrees with
XMLTV, and some Emby image tags are stale (404), so the probe's diagnostics
have something to find.
"""

import base64
import secrets
import select
import socket
import shutil
import subprocess
import json
import math
import threading
import os
import struct
import zlib
import sys
import time
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlencode, urlparse
import slow_link
from slow_link import Conversion, Link, ShapedWriter, opens_file

PANEL_TZ = timezone(timedelta(hours=1))
EASTERN = ZoneInfo("America/New_York")
CHANNELS = 40
SLOT = 1800
CONNECTIONS = set()
# How the server behaves, set by UI tests at run time (GET /mock/set?k=v,
# /mock/set?reset=1): "latency" (seconds per request), "home_delay" (seconds
# for Continue Watching), "fail=persons" (a person's titles fail),
# "resume_episode" (the episode a show's Continue Watching card is on),
# "video_delay" (seconds before each video response), "hls_delay" (seconds
# before a converted stream's playlist: a server starting a conversion),
# "video_fail" (every video request answered 503: the connection lost),
# "intro" ("5,45": an episode's intro marks, in seconds), "copy_audio"
# ("a8:fre": one copy of a film with only that language's sound;
# "a8:spa+spa+jpn": those tracks, in that order), "min_resume_pct" ("5":
# like Emby, a stop before 5% of a title keeps no place), "imdb" ("k8:tt0000001":
# that copy listed with another IMDb id, its TMDb id the same),
# "watched_elsewhere" ("m7": a film just played on another device), "added"
# ("z9": a film added to the library on another device, the one answer to
# what changed since a date),
# "favorites_delay" (seconds before My List answers: a slow refresh),
# "reference_delay" (seconds before one of the film's own subtitle tracks
# answers: a real server reads the whole film to take it out),
# "subtitle_fail" ("1": the first request for each subtitle track of an
# item answers 503, a server that gave up taking it out), "subtitle_redirect"
# ("1": each subtitle request is redirected to its own address with the key
# in it, a server choosing where it sends the app),
# "xtream_status" ("429": every player_api.php request past the login check
# answers with that HTTP status and an empty body, a provider refusing; 0 or
# unset: as normal), "xtream_empty" ("streams" or "categories": that list
# for the whole lineup, get_live_streams or get_live_categories, answers an
# empty list, HTTP 200, a provider that sent nothing; other requests as
# normal), "emby_convert" ("1": the converted version made from the film
# as Emby makes it, see converted_segment), "convert_delay" (seconds before
# a conversion's first segment), "convert_clock" (see converted_segment),
# "resume_movies" ("1,2,3": those films in Continue Watching after the
# rest, each stopped 5 minutes in), "wide_pictures" ("1": Thumb and Backdrop
# pictures 16:9, as a real server's are, not the 2:3 of a poster),
# "redirect_film" and "redirect_segment" ("same" or "elsewhere": each
# request for the film's file, or for a converted version's segment, is
# redirected to its own address, on this server or at localhost, which the
# app takes for another server), "connect_delay" (seconds before a new
# connection's first answer: a real server's connect and TLS, about 0.5 s),
# "plan_delay" (seconds before PlaybackInfo answers: 0.2-4 s on a real one),
# "copies" ("m7": that film has a second copy, c7, in another library: the
# same IMDb id, the same picture width).
#
# A real server's timing and a slow network, apart from CONTROL (a reset
# keeps it): OPENIPTV_MOCK_PROFILE (a name in net_profiles.json: real-quiet,
# real-busy, worst, far; busy is real-busy) takes the profile's server half,
# and its link half unless OPENIPTV_MOCK_LINK names another profile's ("none"
# when the throttling proxy carries the link). GET /mock/profile?name=&link=
# switches ("none" for none; &ago=N begins the run N s in) and closes every
# other connection so the next ones take it; GET /mock/net says what each
# half has done, counts only, and the link's schedule (its network change
# and offline windows, times only).
# OPENIPTV_MOCK_SEED (1 unless set; ?seed= too) fixes every random draw, so a
# run repeats. slow_link.py defines each part. Under a profile, /mock/
# requests go at full speed, the film's own pace in send_file is off, a
# converted version is made at the profile's pace in segments of the
# bitrate asked, and the film's own subtitle tracks wait for their
# extraction.
CONTROL = {}
CONTROL.update({k: v[0] for k, v in parse_qs(os.environ.get("OPENIPTV_MOCK_SET", "")).items()})
SEED = int(os.environ.get("OPENIPTV_MOCK_SEED", "1"))
# The profile's (Server, Link), or None.
FAR = [None]
TOKEN = os.environ.get("OPENIPTV_MOCK_TOKEN", "tok")
# Until then, every connection is dropped at once: a server gone down.
DOWN_UNTIL = [0.0]
# A film's length (seconds; OPENIPTV_MOCK_RUNTIME): two hours unless the
# test film is shorter and its length matters (stretches of its sound).
# Apps' own records in the user's display preferences, by (id, client):
# the app keeps when each title was put on My List there.
PREFERENCES = {}
# Requests for a film's file, (time, item id): GET /mock/video_requests?since=
# (a time from GET /mock/mark) lists the items asked for since.
VIDEO_REQUESTS = []
SUBTITLE_REQUESTS = []
PLAYBACKINFO_REQUESTS = []
KEY_CHECKS = []
CANCELLED = []
SUBTITLES_CUT = []

# The video's bytes sent (GET /mock/video_bytes), and those sent a second
# time or more: a player reading again what it was already sent.
VIDEO_SENT = {}
VIDEO_BYTES = {"sent": 0, "again": 0}
VIDEO_LOCK = threading.Lock()

# Requests for a stretch of a film's sound, and those with the key in
# their address (GET /mock/audio_requests).
AUDIO_REQUESTS = [0, 0]
# Xtream API requests, (time, name): "account", "get_live_categories",
# "get_live_streams", "get_live_streams:10" (the action, and the category
# asked for); refused ones too. GET /mock/xtream_requests?since= (a time
# from /mock/mark) lists them. Only action names and category ids, never a
# login or an address.
XTREAM_REQUESTS = []
# A made-up IPTV login for one leak test run (GET /mock/iptv_login?fresh=1):
# the provider takes it beside u/p, and the simulator's log and the API
# addresses are searched for it. Never printed or sent back.
FAKE_LOGIN = {}
IPTV_ADDRESSES = []
LIVE_REQUESTS = []
LIVE_HELD = {}
LIVE_LOCK = threading.Lock()
MOVIE_TICKS = int(float(os.environ.get("OPENIPTV_MOCK_RUNTIME", "7200")) * 10_000_000)
# Stories long enough to be cut to two lines on a title's page.
LONG_OVERVIEWS = {"a8": "Paul Atreides unites with Chani and the Fremen while on a path of revenge against the conspirators "
                        "who destroyed his family. Facing a choice between the love of his life and the fate of the known "
                        "universe, he endeavors to prevent a terrible future only he can foresee."}
# Its other copy (k8, the same film) tells the same story.
LONG_OVERVIEWS["k8"] = LONG_OVERVIEWS["a8"]
# The test user's My List (favorites), by item id.
FAVORITES = []
# Where each title was last reported (Progress and Stopped), in ticks: its
# resume point from then on, as on Emby.
POSITIONS = {}
# Real IMDb ids for the mock shows (ratings come from IMDb's public dataset).
SHOW_IMDB = {"Forensic Files": "tt0247882", "Forensic Files II": "tt11840612",
             "The Office": "tt0290978", "The Office (US)": "tt0386676"}
SHOW_TMDB = {"Forensic Files": "11105", "Forensic Files II": "99751", "The Office": "2996", "The Office (US)": "2316"}
# Real titles with real IMDb and TMDb ids, so search ranking, popularity and
# Home's rows can be checked against the real public datasets. k-ids are 4K
# copies (same ids, another library) that must show as one title.
KNOWN_TITLES = [
    ("a0", "Animals", "Movie", 2019, "tt4426738", "513340"), ("a1", "Animals", "Movie", 2009, "tt1056036", "25713"),
    ("a2", "Animal House", "Movie", 1978, "tt0077975", "8469"), ("a3", "Nocturnal Animals", "Movie", 2016, "tt4550098", "340666"),
    ("a4", "Animals", "Movie", 2026, "tt31049299", "1236045"), ("a5", "American Animals", "Movie", 2018, "tt6212478", "489931"),
    ("a6", "Dangerous Animals", "Movie", 2025, "tt32299316", "1285965"), ("a7", "Animals.", "Series", 2016, "tt4953128", "65228"),
    ("a8", "Dune: Part Two", "Movie", 2024, "tt15239678", "693134"), ("a9", "Oppenheimer", "Movie", 2023, "tt15398776", "872585"),
    ("a10", "Inception", "Movie", 2010, "tt1375666", "27205"), ("a11", "Weapons", "Movie", 2025, "tt26581740", "1078605"),
    ("a12", "F1", "Movie", 2025, "tt16311594", "911430"), ("a13", "Caught Stealing", "Movie", 2025, None, "1245993"),
    ("k8", "Dune: Part Two", "Movie", 2024, "tt15239678", "693134"), ("k10", "Inception", "Movie", 2010, "tt1375666", "27205"),
    ("z0", "The Mask of Zorro", "Movie", 1998, "tt0120746", "9342"), ("z1", "The Legend of Zorro", "Movie", 2005, "tt0386140", "1656"),
    ("z2", "Zorro", "Series", 1990, "tt0098957", None), ("z3", "Zorro", "Movie", 1975, "tt0072448", "18450"),
    ("z4", "The Mark of Zorro", "Movie", 1940, "tt0032762", None),
    # Recent and well rated on IMDb, for New & notable.
    ("n0", "Sinners", "Movie", 2025, "tt31193180", "1233413"), ("n1", "Superman", "Movie", 2025, "tt5950044", "1061474"),
    ("n2", "The Fantastic Four: First Steps", "Movie", 2025, "tt10676052", "617126"),
    ("n3", "Thunderbolts*", "Movie", 2025, "tt20969586", "986056"),
]
# Release dates (fixtures, not the real ones, except Weapons): New & notable
# keeps the last year's, so Weapons (August 2025) drops out.
PREMIERES = {"n0": "2025-12-05", "n1": "2026-01-16", "n2": "2026-02-20", "n3": "2026-03-13", "a11": "2025-08-08"}
# Genres and cast (searching "zorro antonio", "zorro comedy", "antonio banderas").
GENRES = {"z0": ["Action", "Adventure"], "z1": ["Action", "Adventure", "Western"], "z2": ["Action", "Adventure"],
          "z3": ["Adventure", "Western"], "z4": ["Adventure", "Romance"], "a9": ["Drama", "History"], "a10": ["Action", "Science Fiction"],
          "a2": ["Comedy"], "a8": ["Science Fiction", "Adventure"]}
CAST = {"z0": [("Antonio Banderas", "Actor"), ("Anthony Hopkins", "Actor"), ("Catherine Zeta-Jones", "Actor"), ("Martin Campbell", "Director")],
        "z1": [("Antonio Banderas", "Actor"), ("Catherine Zeta-Jones", "Actor"), ("Martin Campbell", "Director")],
        "z2": [("Duncan Regehr", "Actor"), ("Patrice Martinez", "Actor")],
        "z3": [("Alain Delon", "Actor"), ("Stanley Baker", "Actor")],
        "z4": [("Tyrone Power", "Actor"), ("Linda Darnell", "Actor")],
        "a9": [("Cillian Murphy", "Actor"), ("Christopher Nolan", "Director")],
        "a10": [("Leonardo DiCaprio", "Actor"), ("Christopher Nolan", "Director")]}


# Subtitles downloaded through the providers (RemoteSearch), by language.
DOWNLOADED = []


def file_streams():
    """The test video's audio and subtitle tracks as Emby lists them
    (language, default, index), read once with ffprobe, then any files
    beside it and any downloaded."""
    _file_streams_cached()
    # (Files downloaded through the providers are listed fresh each time.)
    return _STREAMS + [{"Type": "Subtitle", "Index": 200 + n, "Language": lang, "Codec": "srt", "IsExternal": True,
                        "IsTextSubtitleStream": True, "DeliveryMethod": "External"} for n, (_, lang) in enumerate(DOWNLOADED)]


_STREAMS_LOCK = threading.Lock()


def _file_streams_cached():
    """Read once. Under a lock and assigned when complete: a request during
    the read got an empty list (the app asks for several titles at once at
    launch, and kept the ones with no tracks)."""
    global _STREAMS
    with _STREAMS_LOCK:
        if _STREAMS is not None:
            return
        streams = []
        video = os.environ.get("OPENIPTV_MOCK_VIDEO")
        if video and shutil.which("ffprobe"):
            out = subprocess.run(["ffprobe", "-v", "error", "-show_streams", "-of", "json", video],
                                 capture_output=True, text=True).stdout
            for s in json.loads(out or "{}").get("streams", []):
                kind = {"audio": "Audio", "subtitle": "Subtitle"}.get(s.get("codec_type"))
                if kind:
                    streams.append({"Type": kind, "Index": s.get("index"),
                                    "Language": (s.get("tags") or {}).get("language"),
                                    "Codec": s.get("codec_name"),
                                    "IsForced": bool((s.get("disposition") or {}).get("forced")),
                                    "IsDefault": bool((s.get("disposition") or {}).get("default"))})
        # Subtitle files beside the film, as Emby lists them after its own
        # tracks: "language|title|path;…".
        for n, spec in enumerate(f for f in os.environ.get("OPENIPTV_MOCK_SUBTITLE_FILES", "").split(";") if f):
            language, title, _ = spec.split("|", 2)
            streams.append({"Type": "Subtitle", "Index": 100 + n, "Language": language, "Title": title or None,
                            "Codec": "srt", "IsExternal": True, "IsTextSubtitleStream": True,
                            "IsHearingImpaired": "sdh" in title.lower(), "DeliveryMethod": "External"})
        _STREAMS = streams


# Titles added to the library on another device ("added": "z9,z10").
ADDED = {"z9": ("z9", "Zorro Returns", "Movie", 2026, None, None), "z10": ("z10", "Zorro Rides Again", "Movie", 2026, None, None)}


def added_titles():
    return [known_item(ADDED[i]) for i in CONTROL.get("added", "").split(",") if i in ADDED]


def remote_subtitles():
    """The providers' subtitles on offer ("path;path;…", most downloaded
    first): their paths."""
    return [f for f in os.environ.get("OPENIPTV_MOCK_REMOTE_SUBTITLE", "").split(";") if f]


def remote_subtitle(subtitle_id):
    """The path of the provider's subtitle "os-<n>-<language>" (n from 1)."""
    try:
        n = int(subtitle_id.split("-")[1])
    except (IndexError, ValueError):
        return None
    files = remote_subtitles()
    return files[n - 1] if 1 <= n <= len(files) else None


def subtitle_file(index):
    """The path of subtitle file `index` (100, 101, … beside the film; 200,
    201, … downloaded)."""
    if index >= 200:
        return remote_subtitle(DOWNLOADED[index - 200][0]) if index - 200 < len(DOWNLOADED) else None
    files = [f for f in os.environ.get("OPENIPTV_MOCK_SUBTITLE_FILES", "").split(";") if f]
    n = index - 100
    return files[n].split("|", 2)[2] if 0 <= n < len(files) else None


_STREAMS = None


def iptv_login_ok(username, password):
    return (username, password) == ("u", "p") or (bool(FAKE_LOGIN) and (username, password) == (FAKE_LOGIN["username"], FAKE_LOGIN["password"]))


def iptv_path_login_ok(path, kind):
    parts = path.split("/")
    return len(parts) > 4 and parts[1] == kind and iptv_login_ok(parts[2], parts[3])


def simulator_log(since):
    simulator = os.environ.get("OPENIPTV_MOCK_SIMULATOR", "")
    if not simulator:
        return ""
    window = ["--start", datetime.fromtimestamp(since).strftime("%Y-%m-%d %H:%M:%S")] if since else ["--last", "5m"]
    return subprocess.run(["xcrun", "simctl", "spawn", simulator, "log", "show", *window, "--style", "compact"],
                          capture_output=True, text=True).stdout


def user_agent_word(header):
    agent = (header or "").lower()
    if agent.startswith("openreel"):
        return "openreel"
    if "mpv" in agent:
        return "mpv"
    if agent.startswith("lavf"):
        return "lavf"
    return "other"


def live_counted():
    now = time.time()
    for key in [k for k, frees in LIVE_HELD.items() if frees is not None and frees <= now]:
        del LIVE_HELD[key]
    return len(LIVE_HELD)


def live_take():
    limit = int(CONTROL.get("live_max_connections", 0))
    with LIVE_LOCK:
        if limit and live_counted() >= limit:
            return None
        key = object()
        LIVE_HELD[key] = None
        return key


def live_release(key):
    with LIVE_LOCK:
        if key in LIVE_HELD:
            LIVE_HELD[key] = time.time() + float(CONTROL.get("live_linger", 0))


def live_stalls():
    return sorted(tuple(float(x) for x in spec.split(":")) for spec in CONTROL.get("live_stall", "").split(",") if spec)


def live_chosen(key, channel):
    return channel in (CONTROL.get(key) or channel).split(",")


def backdrop_tag(tag):
    """A wide picture is another picture: its own tag, as Emby's are."""
    return tag + "w" if CONTROL.get("wide_pictures") else tag


def known_item(entry, played=False):
    id_, name, kind, year, imdb, tmdb = entry
    # "imdb": "k8:tt0000001": that copy's IMDb id is another (a server's
    # metadata gets one copy wrong; it keeps its TMDb id).
    for spec in filter(None, CONTROL.get("imdb", "").split(",")):
        copy, other = spec.split(":")
        if copy == id_:
            imdb = other
    providers = {"Tmdb": tmdb} | ({"Imdb": imdb} if imdb else {})
    return {"Id": id_, "Name": name, "Type": kind, "ProductionYear": year, "ProviderIds": providers,
            "PrimaryImageAspectRatio": 0.6667, "ImageTags": {"Primary": f"t{len(id_) * 7 + int(id_[1:])}"},
            "BackdropImageTags": [backdrop_tag(f"b{id_}")], "Overview": LONG_OVERVIEWS.get(id_, f"{name} ({year}), a title from the test library."),
            "DateCreated": f"2026-10-{10 - int(id_[1:]) % 10:02d}T12:00:00.0000000Z", "RunTimeTicks": MOVIE_TICKS,
            "UserData": {"Played": played, "LastPlayedDate": "2026-10-09T20:00:00.0000000Z" if played else None,
                         "IsFavorite": id_ in FAVORITES} | (
                {"PlaybackPositionTicks": POSITIONS[id_]} if POSITIONS.get(id_) else {}),
            "Genres": GENRES.get(id_, []),
            # Where it was made (which language it starts in), when asked.
            "ProductionLocations": [c for c in os.environ.get("OPENIPTV_MOCK_COUNTRIES", "").split(",") if c]} | (
            {"PremiereDate": f"{PREMIERES[id_]}T00:00:00.0000000Z"} if id_ in PREMIERES else {})


KNOWN_BY_ID = {entry[0]: entry for entry in KNOWN_TITLES}


def png(seed, w=60, h=90):
    """A small solid-colour PNG so covers visibly render in UI tests."""
    r, g, b = (seed * 70) % 256, (seed * 130 + 80) % 256, (seed * 40 + 160) % 256
    raw = b"".join(b"\x00" + bytes((r, g, b)) * w for _ in range(h))
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b""))


def b64(s):
    return base64.b64encode(s.encode()).decode()


def slots(now, count=4):
    start = now - now % SLOT
    return [(start + i * SLOT, start + (i + 1) * SLOT) for i in range(count)]


def wall(ts):
    return datetime.fromtimestamp(ts, PANEL_TZ).strftime("%Y-%m-%d %H:%M:%S")


def title(ch, start):
    return f"Show {ch}-{start // SLOT % 100}"


def xmltv_time(ts):
    return datetime.fromtimestamp(ts, PANEL_TZ).strftime("%Y%m%d%H%M%S +0100")


GUIDE_TITLES = ["The Simpsons", "Friends", "SportsCenter", "World News Tonight", "The Office", "Seinfeld",
                "NFL Live", "Law & Order: SVU", "Jeopardy!", "Wheel of Fortune", "Family Guy", "Bob's Burgers",
                "Chopped", "Diners, Drive-Ins and Dives", "Property Brothers", "House Hunters", "Paw Patrol",
                "Bluey", "SpongeBob SquarePants", "The Big Bang Theory", "Modern Family", "Dateline", "60 Minutes",
                "NBA Today", "College GameDay", "Pardon the Interruption", "The Daily Show", "Saturday Night Live",
                "Shark Tank", "Survivor", "Grey's Anatomy", "Chicago Fire", "NCIS", "Blue Bloods", "Yellowstone"]
LINEUP = None

# /mock/set?sports=1: one game listed by three services, as real event
# lists name them, in English, Spanish and French (Watch On).
SPORTS_CATEGORIES = [("10", "NFL"), ("11", "ESPN Unlimited"), ("12", "DAZN CA"), ("13", "Football / Soccer")]


def sports_games(now):
    # Stamped in Eastern time, as real providers stamp event channels.
    kickoff = float(CONTROL["sports_kickoff"]) if "sports_kickoff" in CONTROL else now - 60 * int(CONTROL.get("sports_started", 20))
    start = datetime.fromtimestamp(kickoff, EASTERN).strftime("%Y-%m-%d %H:%M:%S")
    games = [("NFL 01: Eagles vs. Jaguars", "10"),
             ("ESPN UNLTD 015: Football: Eagles vs. Jaguars", "11"),
             ("ESPN UNLTD 016: Football: Eagles vs. Jaguars (Eagles vs. Jaguars (ESP))", "11"),
             ("DAZN CA 17: Eagles vs. Jaguars", "12"),
             ("DAZN CA 19: Eagles vs. Jaguars (In French)", "12")]
    # "sports_dupes": "1": one feed listed in two slots of a sport's own
    # category (the user's OneSoccer twice).
    if CONTROL.get("sports_dupes") == "1":
        games += [("Soccer04: Eagles vs. Jaguars ( OneSoccer Feed )", "13"), ("Soccer05: Eagles vs. Jaguars ( OneSoccer Feed )", "13")]
    return [{"num": 2001 + n, "name": f"{name} ({start})", "stream_id": str(2001 + n), "stream_icon": "",
             "epg_channel_id": None, "category_id": cat, "tv_archive": 0, "tv_archive_duration": 0}
            for n, (name, cat) in enumerate(games)]
PICK_CATEGORIES = [("20", "NFL"), ("21", "NBA"), ("22", "NHL"), ("23", "ESPN Unlimited"), ("24", "US | Sports"),
                   ("25", "US | News"), ("26", "US | Entertainment"), ("27", "Account Info"), ("28", "Max Connections 1")]


def pick_lineup(now):
    def at(minutes):
        # Eastern time, as event lists stamp their games.
        return datetime.fromtimestamp(now + 60 * minutes, EASTERN).strftime("%Y-%m-%d %H:%M:%S")
    streams = [(3001, f"NFL 01: Bills vs. Dolphins ({at(-30)})", "20"), (3002, f"NFL 02: Bills vs. Dolphins ({at(-30)})", "20"),
               (3003, f"NFL 03: Chiefs vs. Raiders ({at(120)})", "20"), (3004, "NFL 04: NO EVENT", "20"),
               (3011, f"NBA 01: Lakers vs. Celtics ({at(-60)})", "21"), (3012, f"NBA 02: Knicks vs. Bulls ({at(-240)})", "21"),
               (3021, f"NHL 01: Bruins vs. Rangers ({at(-10)})", "22"), (3022, f"NHL 02: Oilers vs. Flames ({at(-50)})", "22"),
               (3023, f"NHL 03: Kings vs. Ducks ({at(-20)})", "22"),
               (3031, f"ESPN UNLTD 01: basketball: Lakers vs. Celtics ({at(-60)})", "23"),
               (3041, "US: ESPN FHD", "24"), (3042, "US: ESPN HD", "24"), (3043, "US: ESPN SD", "24"),
               (3044, "US: ESPN2 HD", "24"), (3045, "US: FS1 HD", "24"),
               (3051, "US: CNN HD", "25"), (3052, "US: CNN SD", "25"), (3053, "US: FOX NEWS HD", "25"),
               (3061, "US: TLC HD", "26"), (3062, "US: TLC SD", "26"), (3063, "US: TLC FHD", "26"), (3064, "US: HGTV HD", "26"),
               (3071, "Username: u", "27"), (3072, "Password: p", "27"), (3073, "US: ESPN FHD", "27"),
               (3081, "US: QVC FHD", "28"), (3082, "US: QVC HD", "28"), (3083, "US: QVC SD", "28"), (3084, "US: QVC 4K", "28")]
    return [{"num": id_, "name": name, "stream_id": str(id_), "stream_icon": "", "epg_channel_id": None,
             "category_id": cat, "tv_archive": 0, "tv_archive_duration": 0} for id_, name, cat in streams]


if os.environ.get("OPENIPTV_MOCK_LINEUP"):
    with open(os.environ["OPENIPTV_MOCK_LINEUP"]) as f:
        LINEUP = json.load(f)

_RECORDED = None

# Emby's conversions of a film, by item: (the segment it started at, when).
SEGMENT = 3
CONVERSIONS = {}
_CONVERSIONS_LOCK = threading.Lock()
# What each item's conversion was asked for: (VideoBitrate, MaxWidth).
QUALITIES = {}


def server_half():
    return FAR[0] and FAR[0][0].p and FAR[0][0]


def restart_conversion(item, segment, bitrate=None):
    server = server_half()
    conversion = server.conversion(segment, time.time()) if server else \
        Conversion(segment, time.time(), float(CONTROL.get("convert_delay", 6)), SEGMENT / 4)
    with _CONVERSIONS_LOCK:
        CONVERSIONS[item] = conversion
    print(f"{time.time():.2f} convert {item} from {segment * SEGMENT} s" + (f" at {bitrate} b/s" if bitrate else ""), flush=True)
    return conversion


def converted_segment(item, n):
    """Segment n of the film converted as Emby does: made in turn after a
    slow first one ("convert_delay" s), four times faster than it plays, or
    at the profile's pace. Asked for one behind it or far ahead, the
    conversion starts again there. None: refused, as a busy server refuses a
    conversion as it starts."""
    with _CONVERSIONS_LOCK:
        conversion = CONVERSIONS.get(item)
        made = conversion.made(time.time()) if conversion else 0
    if conversion is None or n < conversion.first or n > conversion.first + made + 12:
        conversion = restart_conversion(item, n)
    with _CONVERSIONS_LOCK:
        if conversion.refuse():
            server_half().count("refused")
            return None
        ready = conversion.ready_at(n)
    time.sleep(max(0.0, ready - time.time()))
    timestamp_flags = ["-output_ts_offset", str((n - conversion.first) * SEGMENT)] if CONTROL.get("convert_clock") == "restart" else ["-copyts"]
    bitrate, width = QUALITIES.get(item, (None, None))
    if bitrate and server_half():
        video = str(int(int(bitrate) * 0.85))
        quality = ["-maxrate", video, "-bufsize", video, "-muxrate", bitrate]
    else:
        quality = ["-maxrate", bitrate, "-bufsize", bitrate] if bitrate else []
    quality += ["-vf", f"scale='min({width},iw)':-2"] if width else []
    return subprocess.run(["ffmpeg", "-v", "error", "-ss", str(n * SEGMENT), "-t", str(SEGMENT), "-i", os.environ["OPENIPTV_MOCK_VIDEO"],
                           "-c:v", "libx264", "-preset", "ultrafast", *quality, "-g", "72", "-c:a", "aac", "-b:a", "32k", *timestamp_flags,
                           "-f", "mpegts", "-"], capture_output=True).stdout


def recorded_ts():
    """The test video as MPEG-TS (made once), served as catch-up."""
    global _RECORDED
    source = os.environ.get("OPENIPTV_MOCK_VIDEO")
    if _RECORDED is None and source and shutil.which("ffmpeg"):
        target = os.path.splitext(source)[0] + ".ts"
        if not os.path.exists(target):
            subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", source, "-c", "copy", "-f", "mpegts", target], check=False)
        _RECORDED = target if os.path.exists(target) else ""
    return _RECORDED or None


def note_video_sent(path, start, end):
    with VIDEO_LOCK:
        runs = VIDEO_SENT.setdefault(path, [])
        VIDEO_BYTES["sent"] += end - start
        VIDEO_BYTES["again"] += sum(max(0, min(end, b) - max(start, a)) for a, b in runs)
        merged = [start, end]
        kept = []
        for a, b in runs:
            if b < merged[0] or a > merged[1]:
                kept.append((a, b))
            else:
                merged = [min(a, merged[0]), max(b, merged[1])]
        VIDEO_SENT[path] = sorted(kept + [tuple(merged)])


def close(connections, abrupt):
    for connection in list(connections):
        try:
            if abrupt:
                connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
            connection.shutdown(socket.SHUT_RDWR)
            connection.close()
        except OSError:
            pass


def network_change():
    """Every open connection dropped at once, and every conversion with them."""
    close(CONNECTIONS, abrupt=True)
    with _CONVERSIONS_LOCK:
        CONVERSIONS.clear()


def take_profile(name, link=None, seed=SEED, ago=0.0):
    """Profile `name`'s server half, over `link`'s link half (name's own unless given)."""
    if FAR[0]:
        FAR[0][1].stop()
    link = link or name
    FAR[0] = (slow_link.Server(name, seed), Link(link, seed, on_change=network_change, on_offline=network_change, ago=ago)) \
        if "none" != name or "none" != link else None
    EXTRACTIONS.clear()


# When each of the film's own subtitle tracks ("item:index") is out, under a profile.
EXTRACTIONS = {}


def extraction_wait(track):
    server = server_half()
    if not server:
        return 0.0
    now = time.time()
    with _CONVERSIONS_LOCK:
        if track not in EXTRACTIONS:
            server.count("extractions")
            EXTRACTIONS[track] = now + server.extraction(track)
        return max(0.0, EXTRACTIONS[track] - now)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def setup(self):
        super().setup()
        self.server_half, link = FAR[0] or (None, None)
        self.link = link and link.connection()
        self.read = None
        if self.link:
            self.wfile = ShapedWriter(self.wfile, self.link)

    def parse_request(self):
        if not super().parse_request():
            return False
        self.read = None
        if self.link:
            path = urlparse(self.path).path
            self.wfile.on = not path.startswith("/mock/")
            if self.wfile.on:
                link = self.link.link
                if link.offline(time.monotonic()) == "refused":
                    self.close_connection = True
                    close([self.connection], abrupt=True)
                    return False
                time.sleep(max(0.0, link.offline_until(time.monotonic()) - time.monotonic()))
                first, server, rng = not self.link.answered, self.server_half, self.link.answers
                if self.headers.get("X-Openreel-Launch"):
                    server.launched(self.headers["X-Openreel-Launch"], time.time())
                wait = self.link.wait_before_answer() + (server.setup(rng) if first else 0)
                if opens_file(path) and server.p:
                    self.read = server.read()
                    wait += self.read.first_byte
                else:
                    wait += server.answer(self.command == "POST" and "/PlaybackInfo" in path, rng)
                time.sleep(wait)
        return True

    def close_others(self, abrupt):
        close(CONNECTIONS - {self.connection}, abrupt)

    def handle(self):
        if time.time() < DOWN_UNTIL[0]:
            try:
                self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                self.connection.close()
            except OSError:
                pass
            return
        CONNECTIONS.add(self.connection)
        time.sleep(float(CONTROL.get("connect_delay", 0)))
        try:
            super().handle()
        finally:
            CONNECTIONS.discard(self.connection)

    def client_gone(self):
        ready, _, _ = select.select([self.connection], [], [], 0)
        if not ready:
            return False
        try:
            return self.connection.recv(1, socket.MSG_PEEK) == b""
        except OSError:
            return True

    def key_check(self, kind, q):
        headed = self.headers.get("X-Emby-Token") == TOKEN
        # The app's own requests name it; the player's (ffmpeg's) don't.
        player = not self.headers.get("User-Agent", "").startswith("Openreel/")
        KEY_CHECKS.append((time.time(), kind, "api_key" in q, headed, player))
        return headed

    def log_message(self, *args):
        pass

    def send(self, body, ctype="application/json", status=200, headers=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body)
        if isinstance(body, str):
            body = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (headers or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def do_DELETE(self):
        path = urlparse(self.path).path
        if path.startswith("/emby/Users/U1/FavoriteItems/") and self.headers.get("X-Emby-Token") == TOKEN:
            item = path.rsplit("/", 1)[1]
            if item in FAVORITES:
                FAVORITES.remove(item)
            return self.send({"IsFavorite": False})
        self.send({"error": "not found"}, status=404)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length).decode()
        # Emby accepts both; its own web client sends a form.
        if self.headers.get("Content-Type", "").startswith("application/x-www-form-urlencoded"):
            body = {k: v[0] for k, v in parse_qs(raw).items()}
        else:
            body = json.loads(raw or "{}")
        url = urlparse(self.path)
        if url.path in ("/player_api.php", "/xmltv.php", "/get.php"):
            IPTV_ADDRESSES.append((time.time(), self.path))
            time.sleep(float(CONTROL.get("xtream_latency", 0)))
            fields = {k: v[0] for k, v in parse_qs(url.query).items()}
            fields.update({k: str(v) for k, v in body.items()})
            if url.path == "/player_api.php":
                return self.xtream(fields)
            if url.path == "/get.php":
                return self.m3u(url.path, fields)
            return self.xmltv()
        if self.path.endswith("/Sessions/Logout") and self.headers.get("X-Emby-Token") == TOKEN:
            return self.send(b"", status=204)
        if "/Sessions/Playing" in self.path and self.headers.get("X-Emby-Token") == TOKEN:
            # "ignore_reports": a server that hasn't heard (or kept) them.
            if self.path.split("?")[0].endswith(("/Progress", "/Stopped")) and body.get("ItemId") \
                    and CONTROL.get("ignore_reports") != "1":
                ticks = int(float(body.get("PositionTicks") or 0))
                # "min_resume_pct": "5": like Emby, a place before that share
                # of the title isn't kept (it isn't in Continue Watching).
                if ticks < MOVIE_TICKS * float(CONTROL.get("min_resume_pct", 0)) / 100:
                    ticks = 0
                POSITIONS[body["ItemId"]] = ticks
            return self.send(b"", status=204)
        if "/RemoteSearch/Subtitles/" in self.path and self.headers.get("X-Emby-Token") == TOKEN:
            # Download one: it's a subtitle file of the item from now on.
            # "subtitle_rights": "none": an account that may not manage
            # subtitles (Emby refuses it).
            subtitle = unquote(urlparse(self.path).path.rsplit("/", 1)[1])
            if CONTROL.get("subtitle_rights") == "none":
                print(f"{time.time():.2f} subtitle download {subtitle} refused", flush=True)
                return self.send({"error": "forbidden"}, status=403)
            DOWNLOADED.append((subtitle, subtitle.rsplit("-", 1)[1]))
            print(f"{time.time():.2f} subtitle download {subtitle}", flush=True)
            return self.send({"NewIndex": 199 + len(DOWNLOADED)})
        if "/DisplayPreferences/" in self.path and self.headers.get("X-Emby-Token") == TOKEN:
            key = (urlparse(self.path).path.rsplit("/", 1)[1], (parse_qs(urlparse(self.path).query).get("client") or [""])[0])
            PREFERENCES[key] = dict(body.get("CustomPrefs") or {})
            print(f"{time.time():.2f} preferences {key[0]} saved: {len(PREFERENCES[key])} entries", flush=True)
            return self.send(b"", status=204)
        if "/Users/U1/FavoriteItems/" in self.path and self.headers.get("X-Emby-Token") == TOKEN:
            item = urlparse(self.path).path.rsplit("/", 1)[1]
            if item not in FAVORITES:
                FAVORITES.append(item)
            return self.send({"IsFavorite": True})
        if os.environ.get("OPENIPTV_MOCK_LOG"):
            print(f"{time.time():.2f} POST {self.path.split('?')[0]}", flush=True)
        if "/PlaybackInfo" in self.path and self.headers.get("X-Emby-Token") == TOKEN:
            item = self.path.split("/Items/", 1)[1].split("/", 1)[0]
            PLAYBACKINFO_REQUESTS.append((time.time(), item))
            time.sleep(float(CONTROL.get("plan_delay", 0)))
            width = 3840 if item.startswith("k") else 1920
            streams = file_streams()
            # "copy_audio": "a8:fre": that copy's sound in that language only;
            # "a8:spa+spa+jpn": those tracks in that order (another copy of the
            # same film keeps the file's).
            for spec in filter(None, CONTROL.get("copy_audio", "").split(",")):
                copy, languages = spec.split(":")
                if copy == item:
                    streams = [s for s in streams if s["Type"] != "Audio"] + \
                              [{"Type": "Audio", "Index": 1 + n, "Language": language, "Codec": "aac"}
                               # "+" arrives as a space (a query's way).
                               for n, language in enumerate(languages.replace("+", " ").split())]
            # The app picks a quality from the file's bitrate.
            bitrate = int(os.environ.get("OPENIPTV_MOCK_BITRATE", "8000000"))
            return self.send({"MediaSources": [{"Id": f"ms-{item}", "Protocol": "File", "Container": "mkv", "Bitrate": bitrate,
                                                "SupportsDirectPlay": True, "SupportsDirectStream": True,
                                                "MediaStreams": [{"Type": "Video", "Width": width}] + streams}],
                              "PlaySessionId": "ps1"})
        if self.path.endswith("/Users/AuthenticateByName") and body.get("Pw") == "p":
            return self.send({"AccessToken": TOKEN, "User": {"Id": "U1", "Name": body["Username"]}})
        self.send({"error": "unauthorized"}, status=401)

    def do_GET(self):
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        path = url.path
        if path == "/embywebsocket":
            # Emby's websocket takes its key only in the address: recorded,
            # and refused.
            self.key_check("websocket", q)
            return self.send({"error": "unauthorized"}, status=401)
        if path == "/mock/close_connections":
            # The server closes every other connection ("abrupt": dropped,
            # as a server going down does).
            self.close_others(q.get("abrupt") == "1")
            return self.send({"closed": True})
        if path == "/mock/profile":
            name, link = q.get("name", "none"), q.get("link")
            if {name, link or name} - set(slow_link.profiles()) - {"none"}:
                return self.send({"error": "no such profile"}, status=400)
            take_profile(name, link, int(q.get("seed", SEED)), float(q.get("ago", 0)))
            self.close_others(False)
            return self.send({"profile": name, "link": link or name})
        if path == "/mock/net":
            if not FAR[0]:
                return self.send({"profile": "none"})
            server, link = FAR[0]
            return self.send({"profile": server.name, "link": link.name, "seed": server.seed,
                              "server": dict(server.counts), "net": link.readout(), "schedule": link.schedule()})
        if path == "/mock/down":
            # Gone down for "seconds": every connection dropped at once.
            DOWN_UNTIL[0] = time.time() + float(q.get("seconds", "10"))
            return self.send({"down": True})
        if path == "/mock/log_matches":
            simulator = os.environ.get("OPENIPTV_MOCK_SIMULATOR", "")
            out = subprocess.run(["xcrun", "simctl", "spawn", simulator, "log", "show", "--last", "5m", "--style", "compact"],
                                 capture_output=True, text=True).stdout if simulator else ""
            return self.send({"count": out.count(TOKEN), "read": bool(out)})
        if path == "/mock/iptv_login":
            if q.get("fresh") == "1":
                FAKE_LOGIN.update({"username": "lu" + secrets.token_hex(8), "password": "lp" + secrets.token_hex(8)})
            return self.send({"set": bool(FAKE_LOGIN)})
        if path == "/mock/feed/emby":
            return self.send({"serverURL": f"http://{self.headers.get('Host')}", "serverName": "Mock", "userId": "U1",
                              "userName": "tester", "accessToken": TOKEN})
        if path == "/mock/feed/iptv":
            return self.send({"id": "6F9A1E52-0000-4000-8000-000000000004", "name": "Test feed", "kind": {"xtream": {
                "server": f"http://{self.headers.get('Host')}/", "username": "u", "password": "p"}}})
        if path == "/mock/iptv_source":
            if not FAKE_LOGIN:
                return self.send({"error": "no login"}, status=404)
            return self.send({"id": "6F9A1E52-0000-4000-8000-000000000003", "name": "Leak test", "kind": {"xtream": {
                "server": f"http://{self.headers.get('Host')}/", "username": FAKE_LOGIN["username"], "password": FAKE_LOGIN["password"]}}})
        if path == "/mock/iptv_leaks":
            since = float(q.get("since", "0"))
            log = simulator_log(since)
            addresses = [a for t, a in IPTV_ADDRESSES if t >= since]
            def found(text, key):
                return text.count(FAKE_LOGIN[key]) if FAKE_LOGIN else -1
            return self.send({"log_read": bool(log), "log_lines": log.count("\n"), "log_perf_open": log.count("PERF live open"),
                              "log_failing_url": log.count("NSErrorFailingURLStringKey"), "log_private": log.count("<private>"),
                              "log_api": log.count("player_api.php"), "log_mock_port": log.count(":" + str(self.server.server_port)),
                              "log_username": found(log, "username"), "log_password": found(log, "password"),
                              "requests": len(addresses), "address_username": sum(found(a, "username") for a in addresses),
                              "address_password": sum(found(a, "password") for a in addresses)})
        if path == "/mock/mark":
            return self.send({"t": time.time()})
        if path == "/mock/video_requests":
            since = float(q.get("since", "0"))
            return self.send({"items": [item for t, item in VIDEO_REQUESTS if t >= since]})
        if path == "/mock/audio_requests":
            return self.send({"count": AUDIO_REQUESTS[0], "keyed": AUDIO_REQUESTS[1]})
        if path == "/mock/video_bytes":
            with VIDEO_LOCK:
                return self.send(dict(VIDEO_BYTES))
        if path == "/mock/key_checks":
            since = float(q.get("since", "0"))
            asked = [r for r in KEY_CHECKS if r[0] >= since]
            return self.send({"items": [r[1] for r in asked], "keyed": [r[1] for r in asked if r[2]],
                              "headerless": [r[1] for r in asked if not r[3]], "player": [r[1] for r in asked if r[4]],
                              "cancelled": [kind for t, kind in CANCELLED if t >= since]})
        if path == "/mock/subtitle_requests":
            since = float(q.get("since", "0"))
            asked = [r for r in SUBTITLE_REQUESTS if r[0] >= since]
            return self.send({"items": [r[1] for r in asked], "keyed": [r[1] for r in asked if r[2]],
                              "headerless": [r[1] for r in asked if not r[3]],
                              "cut": [track for t, track in SUBTITLES_CUT if t >= since]})
        if path == "/mock/playbackinfo_requests":
            since = float(q.get("since", "0"))
            return self.send({"items": [item for t, item in PLAYBACKINFO_REQUESTS if t >= since]})
        if path == "/mock/xtream_requests":
            since = float(q.get("since", "0"))
            return self.send({"items": [name for t, name in XTREAM_REQUESTS if t >= since]})
        if path == "/mock/online":
            return self.send({"online": CONTROL.get("offline") != "1"})
        if path == "/mock/live_requests":
            since = float(q.get("since", "0"))
            return self.send({"items": [r for r in LIVE_REQUESTS if r["t"] >= since]})
        if path == "/mock/set":
            if "reset" in q:
                AUDIO_REQUESTS[0] = AUDIO_REQUESTS[1] = 0
                VIDEO_REQUESTS.clear()
                with VIDEO_LOCK:
                    VIDEO_SENT.clear()
                    VIDEO_BYTES.update(sent=0, again=0)
                SUBTITLE_REQUESTS.clear()
                SUBTITLES_CUT.clear()
                PLAYBACKINFO_REQUESTS.clear()
                KEY_CHECKS.clear()
                CANCELLED.clear()
                XTREAM_REQUESTS.clear()
                IPTV_ADDRESSES.clear()
                LIVE_REQUESTS.clear()
                with LIVE_LOCK:
                    LIVE_HELD.clear()
                PREFERENCES.clear()
                DOWNLOADED.clear()
                CONTROL.clear()
                FAVORITES.clear()
                POSITIONS.clear()
            else:
                CONTROL.update(q)
            return self.send(dict(CONTROL))
        # A remote server's round trip (a real one measured 0.8-2.1 s for
        # API calls and covers), for every request but the video itself.
        latency = float(CONTROL.get("latency", os.environ.get("OPENIPTV_MOCK_LATENCY", "0")))
        if latency and not (path.startswith("/Videos/") or path.endswith((".ts", ".m3u8", ".mkv"))):
            time.sleep(latency)
        if path.startswith("/emby/"):
            if os.environ.get("OPENIPTV_MOCK_LOG") and "/Images/" not in path:
                print(f"{time.time():.2f} GET {path}", flush=True)
            return self.emby(path[len("/emby"):], q)
        if path in ("/player_api.php", "/xmltv.php", "/get.php"):
            IPTV_ADDRESSES.append((time.time(), self.path))
            time.sleep(float(CONTROL.get("xtream_latency", 0)))
            # "xtream_post_only": "1": a panel that reads its fields only from a POST.
            if CONTROL.get("xtream_post_only") == "1":
                return self.send({"error": "post only"}, status=405)
        if path == "/player_api.php":
            return self.xtream(q)
        if path in ("/get.php", "/playlist.m3u"):
            return self.m3u(path, q)
        if path == "/portal.php":
            return self.stalker(q)
        if path == "/xmltv.php":
            return self.xmltv()
        if iptv_path_login_ok(path, "timeshift") or path.startswith("/streaming/timeshift.php"):
            # Catch-up: /timeshift/u/p/{minutes}/{yyyy-MM-dd:HH-mm}/{id}.ts,
            # the start in the panel's time zone.
            parts = path.split("/")
            if os.environ.get("OPENIPTV_MOCK_LOG"):
                print(f"{time.time():.2f} TIMESHIFT minutes={parts[4] if len(parts) > 6 else '?'} start={parts[5] if len(parts) > 6 else '?'}", flush=True)
            recording = recorded_ts()
            if recording:
                return self.send_file(recording, "video/mp2t")
            return self.send(b"\x47" * 188 * 64, "video/mp2t")
        if iptv_path_login_ok(path, "live") or path.startswith("/stream/"):
            return self.live(path)
        if path.startswith("/seg/"):
            time.sleep(0.05)
            return self.send(b"\x47" * 188 * 64, "video/mp2t")
        self.send({"error": "not found"}, status=404)

    def xtream(self, q):
        if not iptv_login_ok(q.get("username"), q.get("password")):
            return self.send({"user_info": {"auth": 0}})
        now = int(time.time())
        action = q.get("action")
        XTREAM_REQUESTS.append((time.time(), (action or "account") + (":" + q["category_id"] if q.get("category_id") else "")))
        status = int(CONTROL.get("xtream_status", 0))
        if status:
            return self.send(b"", status=status)
        empty = {"streams": "get_live_streams", "categories": "get_live_categories"}.get(CONTROL.get("xtream_empty"))
        if empty and action == empty and not q.get("category_id"):
            return self.send([])
        if action is None:
            active = CONTROL.get("xtream_active_cons")
            if active is None:
                with LIVE_LOCK:
                    active = str(live_counted()) if CONTROL.get("live_max_connections") else "0"
            return self.send({
                "user_info": {"auth": 1, "status": "Active", "exp_date": str(now + 86400 * 90),
                              "max_connections": CONTROL.get("xtream_max_connections") or CONTROL.get("live_max_connections") or "2",
                              "active_cons": active,
                              "allowed_output_formats": [f for f in CONTROL.get("xtream_formats", "m3u8,ts").split(",") if f]},
                "server_info": {"timezone": "Europe/London", "timestamp_now": now, "time_now": wall(now)},
            })
        if LINEUP and action == "get_live_categories":
            return self.send(LINEUP["categories"])
        if LINEUP and action == "get_live_streams":
            # A real lineup's names and categories (OPENIPTV_MOCK_LINEUP, saved
            # by the smoke tool's dump-lineup), times moved to today.
            streams = LINEUP["streams"]
            if q.get("category_id"):
                streams = [s for s in streams if str(s.get("category_id")) == q["category_id"]]
            return self.send(streams)
        if action == "get_live_categories":
            return self.send([{"category_id": "1", "category_name": "UK", "parent_id": 0},
                              {"category_id": "2", "category_name": "US | Local ABC", "parent_id": 0},
                              {"category_id": "3", "category_name": "US | Local CBS", "parent_id": 0}]
                             + ([{"category_id": c, "category_name": n, "parent_id": 0} for c, n in SPORTS_CATEGORIES]
                                if CONTROL.get("sports") == "1" else [])
                             + ([{"category_id": c, "category_name": n, "parent_id": 0} for c, n in PICK_CATEGORIES]
                                if CONTROL.get("pick") == "1" else []))
        if action == "get_live_streams" and CONTROL.get("sports") == "1" and q.get("category_id") in dict(SPORTS_CATEGORIES):
            return self.send([g for g in sports_games(now) if g["category_id"] == q["category_id"]])
        if action == "get_live_streams" and CONTROL.get("pick") == "1" and q.get("category_id") in dict(PICK_CATEGORIES):
            return self.send([g for g in pick_lineup(now) if g["category_id"] == q["category_id"]])
        if action == "get_live_streams":
            # A few local stations, named the way real providers name them.
            local = [("TX: ABC 13 Houston (KTRK)", "2"), ("TX: ABC 8 Dallas (WFAA)", "2"), ("NY: ABC 7 New York (WABC)", "2"),
                     ("TX: CBS 11 Dallas (KTVT)", "3"), ("TX: CBS 2 Houston (KHOU)", "3"), ("CA: CBS 2 Los Angeles (KCBS)", "3")]
            return self.send([
                {"num": i, "name": f"UK: Channel {i}", "stream_id": str(i), "stream_icon": f"http://logo/{i}.png",
                 "epg_channel_id": f"ch{i}.uk" if i % 10 else None, "category_id": "1",
                 "tv_archive": i % 2, "tv_archive_duration": "7" if i % 2 else 0}
                for i in range(1, CHANNELS + 1)
            ] + [{"num": 900 + n, "name": name, "stream_id": str(900 + n), "stream_icon": "", "epg_channel_id": None,
                  "category_id": cat, "tv_archive": 0, "tv_archive_duration": 0} for n, (name, cat) in enumerate(local)]
              + [{"num": 950 + i, "name": f"UK: Channel {i} HD", "stream_id": str(950 + i), "stream_icon": f"http://logo/{i}.png",
                  "epg_channel_id": f"ch{i}.uk", "category_id": "1", "tv_archive": 1, "tv_archive_duration": "7"}
                 for i in ([int(CONTROL["hd_copy"])] if CONTROL.get("hd_copy", "").isdigit() else [])]
              + (sports_games(now) if CONTROL.get("sports") == "1" else [])
              + (pick_lineup(now) if CONTROL.get("pick") == "1" else []))
        if action == "get_simple_data_table":
            # A channel's schedule two days back to a day ahead; channels with
            # archives mark what's recorded.
            ch = int(q["stream_id"])
            archived = ch < 900 and ch % 2 == 1
            first = now - now % SLOT - 2 * 86400
            return self.send({"epg_listings": [
                {"id": str(s), "epg_id": f"ch{ch}.uk", "title": b64(title(ch, s)), "description": b64("About it."),
                 "start": wall(s), "end": wall(s + SLOT), "start_timestamp": str(s), "stop_timestamp": str(s + SLOT),
                 "now_playing": 1 if s <= now < s + SLOT else 0, "has_archive": 1 if archived and s < now else 0}
                for s in range(first, now + 86400, SLOT)
            ]})
        if action == "get_short_epg":
            ch = int(q["stream_id"])
            time.sleep(float(os.environ.get("OPENIPTV_MOCK_EPG_DELAY", "0.02")))
            return self.send({"epg_listings": [
                {"title": b64(title(ch, s) + (" (repeat)" if ch == 5 else "")), "description": b64("About it."),
                 "start": wall(s), "end": wall(e), "start_timestamp": str(s), "stop_timestamp": str(e)}
                for s, e in slots(now, int(q.get("limit", 4)))
            ]})
        self.send([])

    def m3u(self, path, q):
        base = f"http://{self.headers.get('Host')}"
        if path == "/get.php" and not iptv_login_ok(q.get("username"), q.get("password")):
            return self.send({"error": "unauthorized"}, status=401)
        login = urlencode({"username": q.get("username", "u"), "password": q.get("password", "p")})
        lines = [f'#EXTM3U url-tvg="{base}/xmltv.php?{login}"']
        for i in range(1, CHANNELS + 1):
            epg = f' tvg-id="ch{i}.uk"' if i % 10 else ""
            group = "UK" if i <= 30 else "Sports"
            lines.append(f'#EXTINF:-1 tvg-chno="{i}"{epg} tvg-logo="http://logo/{i}.png" group-title="{group}",UK: Channel {i}')
            lines.append(f"{base}/live/u/p/{i}.ts")
        lines.append('#EXTINF:-1 group-title="Account Info",Username: u')
        lines.append(f"{base}/live/u/p/999.ts")
        return self.send("\n".join(lines) + "\n", "audio/x-mpegurl")

    def stalker(self, q):
        base = f"http://{self.headers.get('Host')}"
        action = q.get("action")
        if "mac=00:1A:79:00:00:01" not in (self.headers.get("Cookie") or ""):
            return self.send({"js": {"error": "bad mac"}})
        if action == "handshake":
            return self.send({"js": {"token": "T123"}})
        if self.headers.get("Authorization") != "Bearer T123":
            return self.send("Authorization failed.", "text/plain")
        if action == "get_profile":
            return self.send({"js": {"id": "1", "status": 0}})
        if action == "get_genres":
            return self.send({"js": [{"id": "*", "title": "All"}, {"id": "1", "title": "UK"}, {"id": "2", "title": "Sports"}]})
        if action == "get_all_channels":
            return self.send({"js": {"data": [
                {"id": str(i), "name": f"UK: Channel {i}", "number": str(i), "logo": "",
                 "cmd": f"ffmpeg http://localhost/ch/{i}", "tv_genre_id": "1" if i <= 30 else "2",
                 "xmltv_id": f"ch{i}.uk"} for i in range(1, CHANNELS + 1)]}})
        if action == "create_link":
            time.sleep(float(CONTROL.get("stalker_link_delay", 0)))
            if CONTROL.get("stalker_link_status"):
                return self.refuse(int(CONTROL["stalker_link_status"]))
            ch = q.get("cmd", "").rsplit("/", 1)[-1]
            return self.send({"js": {"cmd": f"ffmpeg {base}/live/u/p/{ch}.ts"}})
        if action == "get_short_epg":
            ch = int(q.get("ch_id", "1"))
            now = int(time.time())
            return self.send({"js": [{"name": title(ch, s), "start_timestamp": str(s), "stop_timestamp": str(e)}
                                     for s, e in slots(now, 4)]})
        return self.send({"js": []})

    def xmltv(self):
        now = int(time.time())
        parts = ['<?xml version="1.0" encoding="UTF-8"?>\n<tv>']
        for ch in range(1, CHANNELS + 1):
            parts.append(f'<channel id="ch{ch}.uk"><display-name>Channel {ch}</display-name></channel>')
        for ch in range(1, CHANNELS + 1):
            for s, e in slots(now - SLOT * 4, 48):
                parts.append(f'<programme start="{xmltv_time(s)}" stop="{xmltv_time(e)}" channel="ch{ch}.uk">'
                             f'<title lang="en">{title(ch, s)}</title><desc>About it.</desc></programme>')
        if LINEUP:
            # A guide for a saved lineup's US channels, with familiar titles,
            # a day ahead, so guide search has something real to find.
            from xml.sax.saxutils import escape
            cats = {str(c["category_id"]) for c in LINEUP["categories"]
                    if c["category_name"].startswith("US |") and "Local" not in c["category_name"]}
            ids = sorted({s["epg_channel_id"] for s in LINEUP["streams"]
                          if str(s.get("category_id")) in cats and s.get("epg_channel_id")})
            for n, epg in enumerate(ids):
                for k, (s, e) in enumerate(slots(now - SLOT * 4, 52)):
                    show = GUIDE_TITLES[(n * 7 + k) % len(GUIDE_TITLES)]
                    parts.append(f'<programme start="{xmltv_time(s)}" stop="{xmltv_time(e)}" channel="{escape(epg)}">'
                                 f'<title lang="en">{escape(show)}</title></programme>')
        parts.append("</tv>")
        self.send("\n".join(parts), "application/xml")

    def live(self, path):
        name = path.rsplit("/", 1)[1]
        channel, _, ext = name.partition(".")

        def note(status):
            LIVE_REQUESTS.append({"t": time.time(), "id": channel, "ext": ext, "status": status,
                                  "ua": user_agent_word(self.headers.get("User-Agent"))})

        loop = CONTROL.get("live_redirect_loop") == "1"
        if ext == "ts" and (loop or (CONTROL.get("live_redirect") == "1" and path.startswith("/live/"))):
            time.sleep(float(CONTROL.get("live_redirect_delay", 0)))
            note(302)
            return self.redirect(f"/stream/{name}" if path.startswith("/live/") else f"/live/u/p/{name}")
        if ext == "ts" and CONTROL.get("live_refuse") == "1":
            note(302)
            return self.redirect(f"http://127.0.0.1:1/stream/{name}")
        status = int(CONTROL.get("live_status", 0))
        if status and live_chosen("live_status_ids", channel):
            note(status)
            return self.refuse(status)
        slot = live_take()
        if slot is None:
            status = int(CONTROL.get("live_limit_status", 403))
            note(status)
            return self.refuse(status)
        note(200)
        try:
            if channel in CONTROL.get("slow_live", "").split(","):
                time.sleep(4)
            if channel in CONTROL.get("dead_live", "").split(","):
                self.send_response(200)
                self.send_header("Content-Type", "video/mp2t")
                self.send_header("Connection", "close")
                self.end_headers()
                ends = time.time() + 120
                while time.time() < ends:
                    readable, _, _ = select.select([self.connection], [], [], 0.5)
                    if readable and not self.connection.recv(1, socket.MSG_PEEK):
                        break
                self.close_connection = True
                return
            if ext == "ts" and os.environ.get("OPENIPTV_MOCK_VIDEO") and shutil.which("ffmpeg"):
                return self.live_video(channel)
            if ext == "m3u8":
                segs = "\n".join(f"#EXTINF:6.0,\n/seg/{i}.ts" for i in range(5))
                return self.live_answer(f"#EXTM3U\n#EXT-X-TARGETDURATION:6\n{segs}\n".encode(), "application/vnd.apple.mpegurl", 0)
            return self.live_answer(b"\x47" * 188 * 64, "video/mp2t", 0.15)
        finally:
            live_release(slot)

    def redirect(self, location):
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def redirected(self, switch, q):
        """Redirects the request as CONTROL[switch] says, once: False when it doesn't."""
        where = CONTROL.get(switch)
        if where not in ("same", "elsewhere") or "redirected" in q:
            return False
        host = self.headers.get("Host", "")
        if where == "elsewhere":
            host = host.replace("127.0.0.1", "localhost")
        url = urlparse(self.path)
        self.redirect(f"http://{host}{url.path}?{url.query + '&' if url.query else ''}redirected=1")
        return True

    def refuse(self, status):
        self.send_response(status)
        self.send_header("Content-Length", "0")
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

    def live_answer(self, body, ctype, delay):
        time.sleep(float(CONTROL.get("live_delay", delay)))
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        time.sleep(float(CONTROL.get("live_first_data_delay", 0)))
        self.wfile.write(body)

    def live_video(self, channel):
        """A real live channel: the test video looped and sent at its own
        pace as MPEG-TS, endlessly, like a provider's stream."""
        time.sleep(float(CONTROL.get("live_delay", os.environ.get("OPENIPTV_MOCK_LIVE_DELAY", "0.3"))))
        self.send_response(200)
        self.send_header("Content-Type", "video/mp2t")
        self.send_header("Connection", "close")
        # URLSession takes a reset of an unframed stream for its end,
        # but of a chunked one for an error.
        chunked = CONTROL.get("live_chunked") == "1"
        if chunked:
            self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        time.sleep(float(CONTROL.get("live_first_data_delay", 0)))
        burst = ["-readrate_initial_burst", CONTROL["live_burst"]] if CONTROL.get("live_burst") else []
        ffmpeg = subprocess.Popen(
            ["ffmpeg", "-v", "error", "-re", *burst, "-stream_loop", "-1", "-i", os.environ["OPENIPTV_MOCK_VIDEO"],
             "-c", "copy", "-f", "mpegts", "pipe:1"], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        try:
            if self.live_pump(ffmpeg.stdout, chunked, channel) and chunked:
                self.wfile.write(b"0\r\n\r\n")
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            ffmpeg.kill()
            ffmpeg.wait()
        self.close_connection = True

    def live_pump(self, source, chunked, channel):
        rate = float(CONTROL.get("live_rate", 0)) * 125
        stalls = live_stalls()
        cuts = live_chosen("live_cut_ids", channel)
        cut = float(CONTROL.get("live_cut", 0)) if cuts else 0
        start = sent = None
        while True:
            chunk = source.read(65536)
            if not chunk:
                return True
            now = time.monotonic()
            if start is None:
                start, sent = now, 0
            while stalls and now - start >= stalls[0][0]:
                time.sleep(stalls.pop(0)[1])
                now = time.monotonic()
            if cut and now - start >= cut:
                if CONTROL.get("live_cut_reset") == "1":
                    # Closed with nothing left to linger on: a reset, not an end.
                    self.connection.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
                    self.rfile.close()
                    self.connection.close()
                    return False
                return True
            step = 16384 if rate else len(chunk)
            for i in range(0, len(chunk), step):
                if rate:
                    time.sleep(max(0.0, start + sent / rate - time.monotonic()))
                piece = chunk[i:i + step]
                self.wfile.write(b"%x\r\n%s\r\n" % (len(piece), piece) if chunked else piece)
                sent += len(piece)

    def send_file(self, file_path, ctype="video/x-matroska", kind=None):
        """A real video with Range support, like Emby's static stream, slowed
        to roughly a home connection (~200 ms per request, ~10 MB/s) unless
        a profile paces it: at its read's pace, hung or reset part way as
        the read says."""
        size = os.path.getsize(file_path)
        start, end = 0, size - 1
        rng = self.headers.get("Range", "")
        if rng.startswith("bytes="):
            first, _, last = rng[6:].partition("-")
            start = int(first or 0)
            end = min(int(last), size - 1) if last else size - 1
        paced = not self.link
        time.sleep(0.2 if paced else 0)
        # A test can make the video slow to answer (a remote server's round
        # trip), e.g. while a subtitle track is switched.
        time.sleep(float(CONTROL.get("video_delay", 0)))
        if CONTROL.get("video_fail") == "1":
            print("video failed (test)", flush=True)
            self.send_response(503)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        try:
            self.send_response(206 if rng else 200)
            self.send_header("Content-Type", ctype)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Length", str(end - start + 1))
            if rng:
                self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            read, span = self.read, min(end - start + 1, slow_link.FAULT_SPAN)
            hang = int(read.hang_at * span) if read and read.hang_at is not None else None
            reset = int(read.reset_at * span) if read and read.reset_at is not None else None
            if read:
                self.link.rate = read.rate
            with open(file_path, "rb") as f:
                f.seek(start)
                left = end - start + 1
                while left > 0:
                    sent = end - start + 1 - left
                    if hang is not None and sent >= hang:
                        self.server_half.count("hangs")
                        time.sleep(read.hang)
                        hang = None
                    if reset is not None and sent >= reset:
                        self.server_half.count("resets")
                        close([self.connection], abrupt=True)
                        self.close_connection = True
                        return
                    at = f.tell()
                    chunk = f.read(min([262144, left] + [p - sent for p in (hang, reset) if p is not None and p > sent]))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    note_video_sent(file_path, at, at + len(chunk))
                    left -= len(chunk)
                    time.sleep(0.025 if paced else 0)
        except (BrokenPipeError, ConnectionResetError):
            if kind:
                CANCELLED.append((time.time(), kind))
        finally:
            if self.link:
                self.link.rate = math.inf

    def emby(self, path, q):
        if path == "/System/Info/Public":
            return self.send({"ServerName": "Mock Emby", "Version": "4.10.1.0", "Id": "srv"})
        # Like Emby: the token can come as a header or as ?api_key= (players).
        if self.headers.get("X-Emby-Token") != TOKEN and q.get("api_key") != TOKEN and not path.startswith("/Items/"):
            return self.send({"error": "unauthorized"}, status=401)
        movie = lambda i: {"Id": f"m{i}", "Name": f"Movie {i}", "Type": "Movie", "ProductionYear": 2020,
                           "PrimaryImageAspectRatio": 0.6667,
                           "ImageTags": {"Primary": "stale-t15" if i == 15 else f"t{i}"},
                           "BackdropImageTags": [backdrop_tag(f"b{i}")]} | (
            # Where it was last stopped (reported), as on Emby.
            {"UserData": {"PlaybackPositionTicks": POSITIONS[f"m{i}"]}} if POSITIONS.get(f"m{i}") else {})
        copies = set(filter(None, CONTROL.get("copies", "").split(",")))
        copied = lambda film: film | ({"ProviderIds": {"Imdb": "tt90000" + film["Id"][1:].zfill(2)}} if film["Id"] in copies else {})
        # Each episode has its own still (a frame from it), but every fifth,
        # to check the fall back to the show's art.
        episode = lambda i: {"Id": f"e{i}", "Name": f"Episode {i}", "Type": "Episode", "SeriesId": "s1",
                             "SeriesName": "Show", "SeriesPrimaryImageTag": "st",
                             "ImageTags": {"Primary": f"still{i}"} if i % 5 != 4 else {},
                             "PrimaryImageAspectRatio": 1.7778,
                             "ParentBackdropItemId": "s1", "ParentBackdropImageTags": ["stale-sb"],
                             # "episode_resume": seconds in (the test film is 10 min).
                             "UserData": {"PlaybackPositionTicks": int(float(CONTROL.get("episode_resume", 600)) * 10_000_000),
                                          "PlayedPercentage": 40.0}}
        if path == "/Users/U1/Views":
            return self.send({"Items": [{"Id": "v1", "Name": "Movies", "Type": "CollectionFolder", "CollectionType": "movies"},
                                        {"Id": "v2", "Name": "TV Shows", "Type": "CollectionFolder", "CollectionType": "tvshows"},
                                        {"Id": "v9", "Name": "Movies 4K", "Type": "CollectionFolder", "CollectionType": "movies"}]
                                       # A long home page, like a real server with many libraries.
                                       + [{"Id": f"v{n}", "Name": f"Library {n}", "Type": "CollectionFolder", "CollectionType": "movies"}
                                          for n in range(3, 3 + int(os.environ.get("OPENIPTV_MOCK_EXTRA_LIBRARIES", "0")))]})
        if path.startswith("/Users/U1/Items/") and path.count("/") == 4 and not path.endswith(("/Latest", "/Resume")):
            item_id = path.rsplit("/", 1)[1]
            if item_id in KNOWN_BY_ID:
                item = known_item(KNOWN_BY_ID[item_id], played=item_id == "a9")
                if "People" in q.get("Fields", ""):
                    item["People"] = [{"Name": n, "Type": t, "Id": "p_" + n.replace(" ", "_")} for n, t in CAST.get(item_id, [])]
                return self.send(item)
            if item_id.startswith("s"):
                names = ["Forensic Files", "Forensic Files II", "Spider-Man", "Grey's Anatomy", "The Office"]
                n = int(item_id[1:]) if item_id[1:].isdigit() and int(item_id[1:]) < len(names) else 1
                return self.send({"Id": item_id, "Name": names[n], "Type": "Series", "ProductionYear": 2000 + n,
                                  "ProviderIds": {"Imdb": SHOW_IMDB.get(names[n], "")},
                                  "Overview": "Real cases solved with forensic science.",
                                  "ImageTags": {"Primary": "p"}, "BackdropImageTags": ["b"]})
            if item_id.startswith("e"):
                item = episode(int(item_id[1:])) | {"RunTimeTicks": 18000000000}
                # "intro": "start,end" seconds, marked as Emby's intro
                # detection marks them (chapters with a MarkerType).
                if CONTROL.get("intro"):
                    start, end = (float(x) for x in CONTROL["intro"].split(","))
                    item["Chapters"] = [{"StartPositionTicks": 0, "Name": "Chapter 1", "MarkerType": "Chapter"},
                                        {"StartPositionTicks": int(start * 1e7), "Name": "Intro", "MarkerType": "IntroStart"},
                                        {"StartPositionTicks": int(end * 1e7), "Name": "Intro End", "MarkerType": "IntroEnd"}]
                return self.send(item)
            return self.send(copied(movie(int(item_id[1:]))) | {"Id": item_id, "RunTimeTicks": MOVIE_TICKS})
        if path.startswith("/Shows/") and path.endswith("/Seasons"):
            return self.send({"Items": [{"Id": f"season{n}", "Name": f"Season {n}", "Type": "Season", "IndexNumber": n,
                                         "UserData": {"Played": n == 1}} for n in (1, 2)]})
        if path.startswith("/Shows/") and path.endswith("/Episodes"):
            # Specials plus ten seasons, like a long-running show.
            seasons = [int(q["SeasonId"][-1])] if "SeasonId" in q else list(range(0, 11))
            return self.send({"Items": [episode(s * 100 + i) | {"Name": f"Case {i}", "IndexNumber": i, "ParentIndexNumber": s,
                                                                "RunTimeTicks": 13200000000, "Overview": "A small-town mystery.",
                                                                "UserData": {"Played": s == 1 or (s == 2 and i < 3),
                                                                             "PlayedPercentage": 40 if (s, i) == (2, 3) else None,
                                                                             "PlaybackPositionTicks": 5280000000 if (s, i) == (2, 3) else 0}}
                                         for s in seasons for i in range(1, 9)]})
        if path == "/Shows/NextUp":
            items = [episode(203) | {"Name": "Case 3", "IndexNumber": 3, "ParentIndexNumber": 2,
                                     "UserData": {"PlaybackPositionTicks": 5280000000, "PlayedPercentage": 40}}] \
                if q.get("SeriesId") else [episode(i) for i in range(3, 5)]
            return self.send({"Items": items, "TotalRecordCount": len(items)})
        hls = os.environ.get("OPENIPTV_MOCK_HLS")
        converting = CONTROL.get("emby_convert") == "1" and os.environ.get("OPENIPTV_MOCK_VIDEO")
        if path.startswith("/Videos/") and path.endswith("/master.m3u8") and not self.key_check(f"hls:{path.split('/')[2]}", q):
            return self.send({"error": "unauthorized"}, status=401)
        if converting and path.startswith("/Videos/") and path.endswith("/master.m3u8"):
            time.sleep(float(CONTROL.get("hls_delay", 0)))
            start = int(int(q.get("StartTimeTicks", "0")) / 10_000_000 / SEGMENT)
            QUALITIES[path.split("/")[2]] = (q.get("VideoBitrate"), q.get("MaxWidth"))
            restart_conversion(path.split("/")[2], start, q.get("MaxStreamingBitrate"))
            variant = f"main.m3u8?MediaSourceId={q.get('MediaSourceId', '')}&PlaySessionId={q.get('PlaySessionId', '')}"
            return self.send(f"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=480x270\n{variant}\n".encode(),
                             ctype="application/vnd.apple.mpegurl")
        if converting and path.startswith("/Videos/") and path.endswith("/main.m3u8"):
            if not self.key_check(f"playlist:{path.split('/')[2]}", q):
                return self.send({"error": "unauthorized"}, status=401)
            # Emby's: the whole film from 0:00 whatever StartTimeTicks asked.
            count = -(-MOVIE_TICKS // (SEGMENT * 10_000_000))
            lines = ["#EXTM3U", "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-VERSION:3", f"#EXT-X-TARGETDURATION:{SEGMENT}",
                     "#EXT-X-MEDIA-SEQUENCE:0"]
            for n in range(count):
                lines += [f"#EXTINF:{SEGMENT}.000000, nodesc", f"hls1/main/{n}.ts?PlaySessionId={q.get('PlaySessionId', '')}"]
            return self.send(("\n".join(lines + ["#EXT-X-ENDLIST"]) + "\n").encode(), ctype="application/vnd.apple.mpegurl")
        if converting and path.startswith("/Videos/") and "/hls1/main/" in path and path.endswith(".ts"):
            if self.redirected("redirect_segment", q):
                return
            item, n = path.split("/")[2], int(os.path.basename(path)[:-3])
            if not self.key_check(f"segment:{n}", q):
                return self.send({"error": "unauthorized"}, status=401)
            segment = converted_segment(item, n)
            if segment is None:
                return self.send({"error": "unavailable"}, status=503)
            try:
                return self.send(segment, ctype="video/mp2t")
            except (BrokenPipeError, ConnectionResetError):
                # Dropped: Emby stops the conversion, and the next request starts it again.
                with _CONVERSIONS_LOCK:
                    CONVERSIONS.pop(item, None)
                raise
        if hls and path.startswith("/Videos/") and path.endswith("/master.m3u8"):
            time.sleep(float(CONTROL.get("hls_delay", 0)))
            # As the real Emby answers a master asked with the key in a
            # header: one variant, no address with the key in it.
            variant = f"main.m3u8?MediaSourceId={q.get('MediaSourceId', '')}&PlaySessionId={q.get('PlaySessionId', '')}"
            return self.send(f"#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=640x360\n{variant}\n".encode(),
                             ctype="application/vnd.apple.mpegurl")
        if hls and path.startswith("/Videos/") and path.endswith("/main.m3u8"):
            if not self.key_check(f"playlist:{path.split('/')[2]}", q):
                return self.send({"error": "unauthorized"}, status=401)
            # The whole film listed from 0:00 whatever StartTimeTicks asks
            # (the player has to jump).
            with open(os.path.join(hls, "index.m3u8")) as f:
                playlist = f.read().replace("seg", "/emby/hls/seg")
            return self.send(playlist.encode(), ctype="application/vnd.apple.mpegurl")
        if hls and path.startswith("/hls/seg") and path.endswith(".ts"):
            name = os.path.basename(path)
            if not self.key_check(f"segment:{name}", q):
                return self.send({"error": "unauthorized"}, status=401)
            with open(os.path.join(hls, name), "rb") as f:
                return self.send(f.read(), ctype="video/mp2t")
        if path.startswith("/Videos/") and path.endswith("/master.m3u8"):
            # Server-converted HLS: hand off to Apple's public test stream so a
            # fallback can be seen playing real video.
            self.send_response(302)
            self.send_header("Location", "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if path.startswith("/Videos/") and path.endswith("/index.bif"):
            # Preview thumbnails (Roku BIF), when the library has them.
            bif = os.environ.get("OPENIPTV_MOCK_BIF")
            if bif and os.path.exists(bif):
                with open(bif, "rb") as f:
                    return self.send(f.read(), "application/octet-stream")
            return self.send({"error": "not found"}, status=404)
        if "/RemoteSearch/Subtitles/" in path:
            # The providers' subtitles for an item in a language.
            language = path.rsplit("/", 1)[1]
            remote = remote_subtitles()
            print(f"{time.time():.2f} subtitle search {language} ({len(remote)} offered)", flush=True)
            return self.send([{"Id": f"os-{n}-{language}", "Name": f"Release.{n}.{language}", "ProviderName": "Open Subtitles",
                               "Format": "srt", "Language": language, "IsHashMatch": False, "DownloadCount": 100 - n}
                              for n in range(1, len(remote) + 1)])
        if path.startswith("/Providers/Subtitles/Subtitles/"):
            # A provider's subtitle read through the server (nothing saved).
            subtitle = unquote(path.rsplit("/", 1)[1])
            found = remote_subtitle(subtitle)
            print(f"{time.time():.2f} subtitle read {subtitle}", flush=True)
            if not found:
                return self.send({"error": "not found"}, status=404)
            with open(found, "rb") as f:
                return self.send(f.read(), "text/plain; charset=utf-8")
        if path.startswith("/DisplayPreferences/"):
            key = (path.rsplit("/", 1)[1], q.get("client", ""))
            return self.send({"Id": key[0], "Client": key[1], "SortBy": "SortName", "CustomPrefs": PREFERENCES.get(key, {})})
        if path.startswith("/Audio/") and "/stream" in path:
            # A stretch of the film's sound alone, from StartTimeTicks, as
            # MP3 (Emby converts it; read for as long as it's wanted).
            start = int(q.get("StartTimeTicks", "0")) / 10_000_000
            AUDIO_REQUESTS[0] += 1
            # The key in the address: the system logs it when the app stops
            # the request, as it does each once a minute is read.
            if "api_key" in q:
                AUDIO_REQUESTS[1] += 1
            print(f"{time.time():.2f} audio {path.split('/')[2]} from {start:.0f} s, session {q.get('PlaySessionId', '-')}", flush=True)
            video = os.environ.get("OPENIPTV_MOCK_VIDEO")
            if not video or not shutil.which("ffmpeg"):
                return self.send({"error": "not found"}, status=404)
            out = subprocess.run(["ffmpeg", "-v", "error", "-ss", str(start), "-i", video, "-t", "70", "-vn", "-ac", "1",
                                  "-b:a", "64k", "-f", "mp3", "-"], capture_output=True).stdout
            return self.send(out, "audio/mpeg")
        if path.startswith("/Videos/") and "/Subtitles/" in path:
            # /Videos/{id}/{source}/Subtitles/{index}/Stream.srt
            index = int(path.split("/Subtitles/", 1)[1].split("/", 1)[0])
            track = f"{path.split('/')[2]}:{index}"
            SUBTITLE_REQUESTS.append((time.time(), track, "api_key" in q, bool(self.headers.get("X-Emby-Token"))))
            if CONTROL.get("subtitle_redirect") == "1" and "redirected" not in q:
                key = self.headers.get("X-Emby-Token") or q.get("api_key", "")
                self.send_response(302)
                self.send_header("Location", f"{urlparse(self.path).path}?redirected=1&api_key={key}")
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if sum(1 for r in SUBTITLE_REQUESTS if r[1] == track) <= int(CONTROL.get("subtitle_fail", 0)):
                return self.send({"error": "unavailable"}, status=503)
            file = subtitle_file(index)
            if file and os.path.exists(file):
                with open(file, "rb") as f:
                    return self.send(f.read(), "application/x-subrip")
            # One of the film's own tracks, extracted as SRT (as Emby does).
            video = os.environ.get("OPENIPTV_MOCK_VIDEO")
            if index < 100 and video and shutil.which("ffmpeg"):
                time.sleep(float(CONTROL.get("reference_delay", 0)) + extraction_wait(track))
                if self.client_gone():
                    SUBTITLES_CUT.append((time.time(), track))
                    self.close_connection = True
                    return
                out = subprocess.run(["ffmpeg", "-v", "error", "-i", video, "-map", f"0:{index}", "-f", "srt", "-"],
                                     capture_output=True).stdout
                if out:
                    return self.send(out, "application/x-subrip")
            return self.send({"error": "not found"}, status=404)
        if path.startswith("/Videos/") and "/stream" in path:
            if self.redirected("redirect_film", q):
                return
            print(f"{time.time():.2f} stream {path.split('/')[2]} {self.headers.get('Range', '')}", flush=True)
            VIDEO_REQUESTS.append((time.time(), path.split('/')[2]))
            first, _, last = self.headers.get("Range", "")[6:].partition("-")
            speed = first.isdigit() and last.isdigit() and int(first) % 4194304 == 0 and int(last) - int(first) == 4194303
            kind = f"{'speed' if speed else 'stream'}:{path.split('/')[2]}"
            if not self.key_check(kind, q):
                return self.send({"error": "unauthorized"}, status=401)
            video = os.environ.get("OPENIPTV_MOCK_VIDEO")
            if video and os.path.exists(video):
                return self.send_file(video, kind=kind)
            return self.send(b"\x1aE\xdf\xa3" + b"\0" * 1000, "video/x-matroska")
        # My List (before the library listing, which would answer it).
        if path == "/Users/U1/Items" and q.get("Filters") == "IsFavorite":
            time.sleep(float(CONTROL.get("favorites_delay", 0)))
            # By name, as Emby lists them.
            return self.send({"Items": sorted((known_item(KNOWN_BY_ID[i]) for i in FAVORITES if i in KNOWN_BY_ID), key=lambda x: x["Name"])})
        if path == "/Users/U1/Items" and q.get("IncludeItemTypes") == "Movie,Series" and "SearchTerm" not in q \
                and "PersonIds" not in q:
            # The library index: movies plus a few real-looking show names.
            names = ["Forensic Files", "Forensic Files II", "Spider-Man", "Grey's Anatomy", "The Office", "The Office (US)"]
            shows = [{"Id": f"s{i}", "Name": n, "Type": "Series", "ProductionYear": 2000 + i,
                      "ProviderIds": {"Imdb": SHOW_IMDB.get(n, ""), "Tmdb": SHOW_TMDB.get(n, "")},
                      "ImageTags": {"Primary": "p"}} for i, n in enumerate(names)]
            # Same-named and similar titles with real IMDb ids, to check
            # that search ranks by popularity (the 2026 "Animals" first).
            known = [known_item(entry) for entry in KNOWN_TITLES] + added_titles()
            # Asked what changed since a date: only the titles added since.
            if "MinDateLastSaved" in q:
                return self.send({"Items": added_titles(), "TotalRecordCount": len(added_titles())})
            # Big enough to page: real libraries run to 100k+ titles.
            extra = [{"Id": f"x{i}", "Name": f"Library Title {i:05d}", "Type": "Movie", "ProductionYear": 2000 + i % 25,
                      "ImageTags": {"Primary": f"t{i % 40}"}} for i in range(23000)]
            films = [copied(movie(i)) for i in range(40)]
            everything = shows + known + films + [film | {"Id": "c" + film["Id"][1:]} for film in films if "ProviderIds" in film] + extra
            start, limit = int(q.get("StartIndex", 0)), int(q.get("Limit", 100))
            time.sleep(0.5)  # a page takes a while on a real server
            while start > 0 and CONTROL.get("library_hold") == "1":
                time.sleep(0.1)
            body = {"Items": everything[start:start + limit]}
            if q.get("EnableTotalRecordCount") == "true":
                body["TotalRecordCount"] = len(everything)
            return self.send(body)
        if path == "/Users/U1/Items" and "SearchTerm" in q:
            term = q["SearchTerm"].lower()
            found = [episode(i) for i in range(3) if term in "episode"] + \
                    [movie(i) for i in range(40) if term in f"movie {i}"]
            return self.send({"Items": found[: int(q.get("Limit", 40))]})
        if path == "/Users/U1/Items" and q.get("IncludeItemTypes") == "Episode" and "ParentId" in q:
            # A show's changed episodes: none, unless asked without a date.
            if "MinDateLastSaved" in q or "MinDateLastSavedForUser" in q:
                return self.send({"Items": []})
        if path == "/Users/U1/Items" and q.get("Filters") == "IsPlayed":
            return self.send({"Items": [known_item(KNOWN_BY_ID["a9"], played=True)]})
        if path == "/Users/U1/Items" and "Ids" in q:
            items = [known_item(KNOWN_BY_ID[i], played=i == "a9") for i in q["Ids"].split(",") if i in KNOWN_BY_ID]
            if "People" in q.get("Fields", ""):
                items = [item | {"People": [{"Name": n, "Type": t, "Id": "p_" + n.replace(" ", "_")} for n, t in CAST.get(item["Id"], [])]}
                     for item in items]
            return self.send({"Items": items})
        if path == "/Persons":
            term = q.get("SearchTerm", "").lower()
            names = sorted({n for cast in CAST.values() for n, _ in cast if term and term in n.lower()})
            return self.send({"Items": [{"Id": "p-" + n.replace(" ", "_"), "Name": n, "Type": "Person"} for n in names[:int(q.get("Limit", 3))]]})
        if path == "/Users/U1/Items" and "PersonIds" in q:
            if CONTROL.get("fail") == "persons":
                return self.send({"error": "unavailable"}, status=503)
            name = q["PersonIds"][2:].replace("_", " ")
            return self.send({"Items": [known_item(KNOWN_BY_ID[i]) for i, cast in CAST.items() if any(n == name for n, _ in cast)]})
        if path.startswith("/Items/") and path.endswith("/Similar"):
            like = ["a8", "a10", "a3", "a11", "a12", "a13", "a5", "a9"] if path.split("/")[2].startswith("a") \
                else ["a7", "a6", "a2", "a0", "a1", "a3"]
            return self.send({"Items": [known_item(KNOWN_BY_ID[i], played=i == "a9") for i in like]})
        if path == "/Users/U1/Items" and q.get("Filters") == "IsResumable":
            # Several episodes of one show (shown as one card) and a movie.
            ep = lambda s, i: episode(s * 100 + i) | {"Name": f"Case {i}", "IndexNumber": i, "ParentIndexNumber": s,
                                                    "UserData": {"PlaybackPositionTicks": 5280000000, "PlayedPercentage": 40}}
            # The show's card is on S2 E3, or the episode a test moved it to
            # (watched elsewhere).
            current = int(CONTROL.get("resume_episode", 3))
            twin = ep(2, current) | {"Id": f"e4k2{current:02d}", "SeriesId": "s1-4k"}  # same show, another library
            # Like a real server: home takes a moment, and progress moves
            # between refreshes.
            print(f"{time.time():.2f} home requested", flush=True)
            time.sleep(float(CONTROL.get("home_delay", os.environ.get("OPENIPTV_MOCK_HOME_DELAY", "0"))))
            progress = 5 + int(time.time()) % 90
            items = [ep(2, current), twin, movie(5) | {"UserData": {"PlayedPercentage": progress}}, ep(1, 4), ep(1, 2)]
            items += [movie(int(i)) | {"UserData": {"PlaybackPositionTicks": 3000000000, "PlayedPercentage": 10}}
                      for i in CONTROL.get("resume_movies", "").split(",") if i]
            # "watched_elsewhere": "m7": that film just played on another
            # device, first in the list.
            if CONTROL.get("watched_elsewhere"):
                items.insert(0, movie(int(CONTROL["watched_elsewhere"][1:])) | {"UserData": {"PlayedPercentage": 30,
                                                                                            "PlaybackPositionTicks": 2160000000}})
            return self.send({"Items": items})
        if path == "/Users/U1/Items/Resume":
            return self.send({"Items": [episode(i) for i in range(3)], "TotalRecordCount": 3})
        if path == "/Users/U1/Items/Latest":
            if q.get("ParentId") == "v9":
                return self.send([known_item(KNOWN_BY_ID[i]) for i in ("k8", "k10")])
            if q.get("ParentId") == "v1":
                return self.send([known_item(KNOWN_BY_ID[i]) for i in ("a4", "a11", "a12", "a6", "a13", "a8")]
                                 + [movie(i) | {"DateCreated": "2026-09-01T00:00:00.0000000Z"} for i in range(10)])
            return self.send([movie(i) for i in range(int(q.get("Limit", 16)))])
        if path.startswith("/Items/") and "/Images/" in path:
            if q.get("tag", "").startswith("stale"):
                return self.send({"error": "image not found"}, status=404)
            time.sleep(0.01)
            wide = CONTROL.get("wide_pictures") and ("/Images/Thumb" in path or "/Images/Backdrop" in path)
            return self.send(png(sum(map(ord, path)), *((160, 90) if wide else ())), "image/png",
                             headers={"Cache-Control": "public, max-age=31536000"})
        self.send({"error": "not found"}, status=404)


class Server(ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        # Clients closing pooled keep-alive connections is normal.
        if not isinstance(sys.exc_info()[1], (ConnectionResetError, BrokenPipeError)):
            super().handle_error(request, client_address)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    if os.environ.get("OPENIPTV_MOCK_PROFILE"):
        take_profile(os.environ["OPENIPTV_MOCK_PROFILE"], os.environ.get("OPENIPTV_MOCK_LINK"))
    Server(("127.0.0.1", port), Handler).serve_forever()

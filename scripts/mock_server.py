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
import json
import os
import struct
import zlib
import sys
import time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PANEL_TZ = timezone(timedelta(hours=1))
CHANNELS = 40
SLOT = 1800
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
]
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


def known_item(entry, played=False):
    id_, name, kind, year, imdb, tmdb = entry
    providers = {"Tmdb": tmdb} | ({"Imdb": imdb} if imdb else {})
    return {"Id": id_, "Name": name, "Type": kind, "ProductionYear": year, "ProviderIds": providers,
            "PrimaryImageAspectRatio": 0.6667, "ImageTags": {"Primary": f"t{len(id_) * 7 + int(id_[1:])}"},
            "BackdropImageTags": [f"b{id_}"], "Overview": f"{name} ({year}), a title from the test library.",
            "DateCreated": f"2026-10-{10 - int(id_[1:]) % 10:02d}T12:00:00.0000000Z", "RunTimeTicks": 72000000000,
            "UserData": {"Played": played, "LastPlayedDate": "2026-10-09T20:00:00.0000000Z" if played else None},
            "Genres": GENRES.get(id_, [])}


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


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

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

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(length).decode()
        # Emby accepts both; its own web client sends a form.
        if self.headers.get("Content-Type", "").startswith("application/x-www-form-urlencoded"):
            body = {k: v[0] for k, v in parse_qs(raw).items()}
        else:
            body = json.loads(raw or "{}")
        if self.path.endswith("/Sessions/Logout") and self.headers.get("X-Emby-Token") == "tok":
            return self.send(b"", status=204)
        if "/Sessions/Playing" in self.path and self.headers.get("X-Emby-Token") == "tok":
            return self.send(b"", status=204)
        if os.environ.get("OPENIPTV_MOCK_LOG"):
            print(f"{time.time():.2f} POST {self.path.split('?')[0]}", flush=True)
        if "/PlaybackInfo" in self.path and self.headers.get("X-Emby-Token") == "tok":
            item = self.path.split("/Items/", 1)[1].split("/", 1)[0]
            width = 3840 if item.startswith("k") else 1920
            return self.send({"MediaSources": [{"Id": f"ms-{item}", "Protocol": "File", "Container": "mkv", "Bitrate": 8000000,
                                                "SupportsDirectPlay": True, "SupportsDirectStream": True,
                                                "MediaStreams": [{"Type": "Video", "Width": width}]}],
                              "PlaySessionId": "ps1"})
        if self.path.endswith("/Users/AuthenticateByName") and body.get("Pw") == "p":
            return self.send({"AccessToken": "tok", "User": {"Id": "U1", "Name": body["Username"]}})
        self.send({"error": "unauthorized"}, status=401)

    def do_GET(self):
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        path = url.path
        if path.startswith("/emby/"):
            if os.environ.get("OPENIPTV_MOCK_LOG") and "/Images/" not in path:
                print(f"{time.time():.2f} GET {path}", flush=True)
            return self.emby(path[len("/emby"):], q)
        if path == "/player_api.php":
            return self.xtream(q)
        if path in ("/get.php", "/playlist.m3u"):
            return self.m3u(path, q)
        if path == "/portal.php":
            return self.stalker(q)
        if path == "/xmltv.php":
            return self.xmltv()
        if path.startswith("/live/u/p/"):
            name = path.rsplit("/", 1)[1]
            if name.endswith(".m3u8"):
                segs = "\n".join(f"#EXTINF:6.0,\n/seg/{i}.ts" for i in range(5))
                return self.send(f"#EXTM3U\n#EXT-X-TARGETDURATION:6\n{segs}\n", "application/vnd.apple.mpegurl")
            time.sleep(0.15)
            return self.send(b"\x47" * 188 * 64, "video/mp2t")
        if path.startswith("/seg/"):
            time.sleep(0.05)
            return self.send(b"\x47" * 188 * 64, "video/mp2t")
        self.send({"error": "not found"}, status=404)

    def xtream(self, q):
        if q.get("username") != "u" or q.get("password") != "p":
            return self.send({"user_info": {"auth": 0}})
        now = int(time.time())
        action = q.get("action")
        if action is None:
            return self.send({
                "user_info": {"auth": 1, "status": "Active", "exp_date": str(now + 86400 * 90),
                              "max_connections": "2", "active_cons": "0",
                              "allowed_output_formats": ["m3u8", "ts"]},
                "server_info": {"timezone": "Europe/London", "timestamp_now": now, "time_now": wall(now)},
            })
        if action == "get_live_categories":
            return self.send([{"category_id": "1", "category_name": "UK", "parent_id": 0}])
        if action == "get_live_streams":
            return self.send([
                {"num": i, "name": f"UK: Channel {i}", "stream_id": str(i), "stream_icon": f"http://logo/{i}.png",
                 "epg_channel_id": f"ch{i}.uk" if i % 10 else None, "category_id": "1",
                 "tv_archive": i % 2, "tv_archive_duration": "7" if i % 2 else 0}
                for i in range(1, CHANNELS + 1)
            ])
        if action == "get_short_epg":
            ch = int(q["stream_id"])
            time.sleep(0.02)
            return self.send({"epg_listings": [
                {"title": b64(title(ch, s) + (" (repeat)" if ch == 5 else "")), "description": b64("About it."),
                 "start": wall(s), "end": wall(e), "start_timestamp": str(s), "stop_timestamp": str(e)}
                for s, e in slots(now, int(q.get("limit", 4)))
            ]})
        self.send([])

    def m3u(self, path, q):
        base = f"http://{self.headers.get('Host')}"
        if path == "/get.php" and (q.get("username") != "u" or q.get("password") != "p"):
            return self.send({"error": "unauthorized"}, status=401)
        lines = [f'#EXTM3U url-tvg="{base}/xmltv.php?username=u&password=p"']
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
        parts.append("</tv>")
        self.send("\n".join(parts), "application/xml")

    def send_file(self, file_path):
        """A real video with Range support, like Emby's static stream, slowed
        to roughly a home connection (~200 ms per request, ~10 MB/s)."""
        size = os.path.getsize(file_path)
        start, end = 0, size - 1
        rng = self.headers.get("Range", "")
        if rng.startswith("bytes="):
            first, _, last = rng[6:].partition("-")
            start = int(first or 0)
            end = min(int(last), size - 1) if last else size - 1
        time.sleep(0.2)
        self.send_response(206 if rng else 200)
        self.send_header("Content-Type", "video/x-matroska")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(end - start + 1))
        if rng:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        with open(file_path, "rb") as f:
            f.seek(start)
            left = end - start + 1
            try:
                while left > 0:
                    chunk = f.read(min(262144, left))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    left -= len(chunk)
                    time.sleep(0.025)
            except (BrokenPipeError, ConnectionResetError):
                pass

    def emby(self, path, q):
        if path == "/System/Info/Public":
            return self.send({"ServerName": "Mock Emby", "Version": "4.10.1.0", "Id": "srv"})
        # Like Emby: the token can come as a header or as ?api_key= (players).
        if self.headers.get("X-Emby-Token") != "tok" and q.get("api_key") != "tok" and not path.startswith("/Items/"):
            return self.send({"error": "unauthorized"}, status=401)
        movie = lambda i: {"Id": f"m{i}", "Name": f"Movie {i}", "Type": "Movie", "ProductionYear": 2020,
                           "PrimaryImageAspectRatio": 0.6667,
                           "ImageTags": {"Primary": "stale-t15" if i == 15 else f"t{i}"},
                           "BackdropImageTags": [f"b{i}"]}
        episode = lambda i: {"Id": f"e{i}", "Name": f"Episode {i}", "Type": "Episode", "SeriesId": "s1",
                             "SeriesName": "Show", "SeriesPrimaryImageTag": "st", "ImageTags": {},
                             "ParentBackdropItemId": "s1", "ParentBackdropImageTags": ["stale-sb"],
                             "UserData": {"PlaybackPositionTicks": 6000000000, "PlayedPercentage": 40.0}}
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
                return self.send(known_item(KNOWN_BY_ID[item_id], played=item_id == "a9"))
            if item_id.startswith("s"):
                names = ["Forensic Files", "Forensic Files II", "Spider-Man", "Grey's Anatomy", "The Office"]
                n = int(item_id[1:]) if item_id[1:].isdigit() and int(item_id[1:]) < len(names) else 1
                return self.send({"Id": item_id, "Name": names[n], "Type": "Series", "ProductionYear": 2000 + n,
                                  "ProviderIds": {"Imdb": SHOW_IMDB.get(names[n], "")},
                                  "Overview": "Real cases solved with forensic science.",
                                  "ImageTags": {"Primary": "p"}, "BackdropImageTags": ["b"]})
            if item_id.startswith("e"):
                return self.send(episode(int(item_id[1:])) | {"RunTimeTicks": 18000000000})
            return self.send(movie(int(item_id[1:])) | {"RunTimeTicks": 72000000000})
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
        if path.startswith("/Videos/") and path.endswith("/master.m3u8"):
            # Server-converted HLS: hand off to Apple's public test stream so a
            # fallback can be seen playing real video.
            self.send_response(302)
            self.send_header("Location", "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_ts/master.m3u8")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if path.startswith("/Videos/") and "/stream" in path:
            print(f"{time.time():.2f} stream {path.split('/')[2]}", flush=True)
            video = os.environ.get("OPENIPTV_MOCK_VIDEO")
            if video and os.path.exists(video):
                return self.send_file(video)
            return self.send(b"\x1aE\xdf\xa3" + b"\0" * 1000, "video/x-matroska")
        if path == "/Users/U1/Items" and q.get("IncludeItemTypes") == "Movie,Series" and "SearchTerm" not in q \
                and "PersonIds" not in q:
            # The library index: movies plus a few real-looking show names.
            names = ["Forensic Files", "Forensic Files II", "Spider-Man", "Grey's Anatomy", "The Office", "The Office (US)"]
            shows = [{"Id": f"s{i}", "Name": n, "Type": "Series", "ProductionYear": 2000 + i,
                      "ProviderIds": {"Imdb": SHOW_IMDB.get(n, ""), "Tmdb": SHOW_TMDB.get(n, "")},
                      "ImageTags": {"Primary": "p"}} for i, n in enumerate(names)]
            # Same-named and similar titles with real IMDb ids, to check
            # that search ranks by popularity (the 2026 "Animals" first).
            known = [known_item(entry) for entry in KNOWN_TITLES]
            # Big enough to page: real libraries run to 100k+ titles.
            extra = [{"Id": f"x{i}", "Name": f"Library Title {i:05d}", "Type": "Movie", "ProductionYear": 2000 + i % 25,
                      "ImageTags": {"Primary": f"t{i % 40}"}} for i in range(23000)]
            everything = shows + known + [movie(i) for i in range(40)] + extra
            start, limit = int(q.get("StartIndex", 0)), int(q.get("Limit", 100))
            time.sleep(0.5)  # a page takes a while on a real server
            body = {"Items": everything[start:start + limit]}
            if q.get("EnableTotalRecordCount") == "true":
                body["TotalRecordCount"] = len(everything)
            return self.send(body)
        if path == "/Users/U1/Items" and "SearchTerm" in q:
            term = q["SearchTerm"].lower()
            found = [episode(i) for i in range(3) if term in "episode"] + \
                    [movie(i) for i in range(40) if term in f"movie {i}"]
            return self.send({"Items": found[: int(q.get("Limit", 40))]})
        if path == "/Users/U1/Items" and q.get("Filters") == "IsPlayed":
            return self.send({"Items": [known_item(KNOWN_BY_ID["a9"], played=True)]})
        if path == "/Users/U1/Items" and "Ids" in q:
            items = [known_item(KNOWN_BY_ID[i], played=i == "a9") for i in q["Ids"].split(",") if i in KNOWN_BY_ID]
            if "People" in q.get("Fields", ""):
                items = [item | {"People": [{"Name": n, "Type": t} for n, t in CAST.get(item["Id"], [])]} for item in items]
            return self.send({"Items": items})
        if path == "/Persons":
            term = q.get("SearchTerm", "").lower()
            names = sorted({n for cast in CAST.values() for n, _ in cast if term and term in n.lower()})
            return self.send({"Items": [{"Id": "p-" + n.replace(" ", "_"), "Name": n, "Type": "Person"} for n in names[:int(q.get("Limit", 3))]]})
        if path == "/Users/U1/Items" and "PersonIds" in q:
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
            twin = ep(2, 3) | {"Id": "e4k203", "SeriesId": "s1-4k"}  # same show, another library
            # Like a real server: home takes a moment, and progress moves
            # between refreshes.
            print(f"{time.time():.2f} home requested", flush=True)
            time.sleep(float(os.environ.get("OPENIPTV_MOCK_HOME_DELAY", "0")))
            progress = 5 + int(time.time()) % 90
            return self.send({"Items": [ep(2, 3), twin, movie(5) | {"UserData": {"PlayedPercentage": progress}}, ep(1, 4), ep(1, 2)]})
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
            return self.send(png(sum(map(ord, path))), "image/png",
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
    Server(("127.0.0.1", port), Handler).serve_forever()

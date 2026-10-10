#!/usr/bin/env python3
"""Fake Xtream panel + Emby server for developing without real credentials.

    python3 scripts/mock_server.py 8765
    OPENIPTV_XTREAM_URL=http://127.0.0.1:8765 OPENIPTV_XTREAM_USER=u OPENIPTV_XTREAM_PASS=p \
    OPENIPTV_EMBY_URL=http://127.0.0.1:8765 OPENIPTV_EMBY_USER=u OPENIPTV_EMBY_PASS=p \
    cargo run -p openiptv-probe

The panel runs at UTC+1 and channel 5's short EPG deliberately disagrees with
XMLTV, so the probe's diagnostics have something to find.
"""

import base64
import json
import sys
import time
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PANEL_TZ = timezone(timedelta(hours=1))
CHANNELS = 40
SLOT = 1800


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
        body = json.loads(self.rfile.read(length) or b"{}")
        if self.path.endswith("/Users/AuthenticateByName") and body.get("Pw") == "p":
            return self.send({"AccessToken": "tok", "User": {"Id": "U1", "Name": body["Username"]}})
        self.send({"error": "unauthorized"}, status=401)

    def do_GET(self):
        url = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(url.query).items()}
        path = url.path
        if path.startswith("/emby/"):
            return self.emby(path[len("/emby"):], q)
        if path == "/player_api.php":
            return self.xtream(q)
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

    def emby(self, path, q):
        if path == "/System/Info/Public":
            return self.send({"ServerName": "Mock Emby", "Version": "4.10.1.0", "Id": "srv"})
        if self.headers.get("X-Emby-Token") != "tok" and not path.startswith("/Items/"):
            return self.send({"error": "unauthorized"}, status=401)
        movie = lambda i: {"Id": f"m{i}", "Name": f"Movie {i}", "Type": "Movie", "ProductionYear": 2020,
                           "PrimaryImageAspectRatio": 0.6667, "ImageTags": {"Primary": f"t{i}"},
                           "BackdropImageTags": [f"b{i}"]}
        episode = lambda i: {"Id": f"e{i}", "Name": f"Episode {i}", "Type": "Episode", "SeriesId": "s1",
                             "SeriesName": "Show", "SeriesPrimaryImageTag": "st", "ImageTags": {},
                             "ParentBackdropItemId": "s1", "ParentBackdropImageTags": ["sb"],
                             "UserData": {"PlaybackPositionTicks": 6000000000, "PlayedPercentage": 40.0}}
        if path == "/Users/U1/Views":
            return self.send({"Items": [{"Id": "v1", "Name": "Movies", "Type": "CollectionFolder"},
                                        {"Id": "v2", "Name": "TV Shows", "Type": "CollectionFolder"}]})
        if path == "/Users/U1/Items/Resume":
            return self.send({"Items": [episode(i) for i in range(3)], "TotalRecordCount": 3})
        if path == "/Shows/NextUp":
            return self.send({"Items": [episode(i) for i in range(3, 5)], "TotalRecordCount": 2})
        if path == "/Users/U1/Items/Latest":
            return self.send([movie(i) for i in range(int(q.get("Limit", 16)))])
        if path.startswith("/Items/") and "/Images/" in path:
            time.sleep(0.01)
            return self.send(b"\xff\xd8" + b"\0" * 30000, "image/jpeg",
                             headers={"Cache-Control": "public, max-age=31536000"})
        self.send({"error": "not found"}, status=404)


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8765
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()

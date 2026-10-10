"""1Password helpers for scripts/serve.sh. Reads `op` CLI JSON on stdin.

  find TITLE           -> prints "<vault id> <item id>" of the one item whose
                          title matches (exact, else substring; case-insensitive)
  xtream SUMMARY_PATH  -> prints shell exports for OPENIPTV_XTREAM_* and writes a
                          values-free summary of how the item's fields were used

Secret values only ever go to stdout for the calling shell's `eval`; nothing
secret is written to disk.
"""

import json
import re
import shlex
import sys
from urllib.parse import parse_qs, urlparse


def find(title):
    items = json.load(sys.stdin)
    want = title.lower().strip()
    exact = [i for i in items if (i.get("title") or "").lower().strip() == want]
    loose = [i for i in items if want in (i.get("title") or "").lower()]
    hits = exact or loose
    if len(hits) != 1:
        names = ", ".join(repr(i.get("title")) for i in hits) or "none"
        sys.exit(f"expected one item matching {title!r}, found: {names}")
    print(hits[0].get("vault", {}).get("id", ""), hits[0]["id"])


def xtream(summary_path):
    item = json.load(sys.stdin)
    fields = [f for f in item.get("fields", []) if f.get("value")]
    urls = [u.get("href") for u in item.get("urls") or [] if u.get("href")]
    notes = []

    def by_purpose(purpose):
        return next((f for f in fields if f.get("purpose") == purpose), None)

    def by_label(*patterns):
        for f in fields:
            label = (f.get("label") or f.get("id") or "").lower()
            if any(re.search(p, label) for p in patterns):
                return f
        return None

    user = by_purpose("USERNAME") or by_label(r"user", r"login")
    password = by_purpose("PASSWORD") or by_label(r"pass")
    server_field = by_label(r"server", r"host", r"dns", r"portal", r"url", r"website", r"domain")
    port_field = by_label(r"^port$")

    candidates = urls + ([server_field["value"]] if server_field else [])
    # Fields that contain a full playlist/API URL carry everything at once.
    for f in fields:
        if re.search(r"(get|player_api)\.php\?", f["value"]):
            candidates.insert(0, f["value"])

    servers, seen, username, secret = [], set(), None, None
    for raw in candidates:
        value = raw.strip()
        if not re.match(r"^[a-z]+://", value, re.I):
            value = "http://" + value
        parsed = urlparse(value)
        if not parsed.hostname:
            continue
        q = parse_qs(parsed.query)
        from_playlist = "username" in q and "password" in q
        if from_playlist and not username:
            username, secret = q["username"][0], q["password"][0]
            notes.append("username and password taken from a playlist/API URL")
        port = parsed.port
        if port is None and port_field:
            port = int(port_field["value"])
        server = f"{parsed.scheme}://{parsed.hostname}" + (f":{port}" if port else "")
        if server not in seen:
            seen.add(server)
            servers.append((server, from_playlist))
    # Playlist/API hosts are known IPTV endpoints; loopback addresses (saved
    # app pages) can't be the provider, so they go last.
    servers.sort(key=lambda e: (urlparse(e[0]).hostname in ("localhost", "127.0.0.1", "::1"), not e[1]))
    servers = [s for s, _ in servers]
    notes.append("candidate servers in order: " + ", ".join(servers))
    server = " ".join(servers)

    username = username or (user and user["value"])
    secret = secret or (password and password["value"])
    if user and not any("playlist" in n for n in notes):
        notes.append(f"username from field {user.get('label')!r}")
    if password and not any("playlist" in n for n in notes):
        notes.append(f"password from field {password.get('label')!r}")

    with open(summary_path, "w") as out:
        out.write(f"item: {item.get('title')!r} ({item.get('category')})\n")
        out.write("fields: " + ", ".join(f"{f.get('label')!r}[{f.get('type')}]" for f in fields) + "\n")
        out.write(f"url count: {len(urls)} (scheme://host:port only, paths and queries never written)\n")
        out.write("mapping: " + "; ".join(notes) + "\n")
        missing = [n for n, v in (("server", server), ("username", username), ("password", secret)) if not v]
        out.write(f"missing: {', '.join(missing) or 'nothing'}\n")

    if not (server and username and secret):
        sys.exit("could not find server, username and password in the item; see " + summary_path)
    for name, value in (("URL", server), ("USER", username), ("PASS", secret)):
        print(f"export OPENIPTV_XTREAM_{name}={shlex.quote(value)}")


if __name__ == "__main__":
    {"find": find, "xtream": xtream}[sys.argv[1]](sys.argv[2])

<p align="center"><img src="favicon.svg" width="96" height="96" alt="OpenIPTV logo"></p>

# OpenIPTV

One fast app for your Emby library and your live TV, on iPhone, iPad and
Apple TV (native SwiftUI, Liquid Glass), plus a self-hosted web version.
See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

OpenIPTV is a player only. It ships no channels, playlists or media: you
bring your own Emby server and an IPTV subscription you're entitled to use.

## What it connects to

Sign in inside the app, like TiviMate or Emby's own apps:

- **Emby**: server address with username and password, or an Emby Connect
  account (then pick a server shared with you).
- **IPTV**, any common format, several at once:
  - **Xtream Codes**: server, username, password (or paste a `get.php` link)
  - **M3U playlist** URL, with an optional XMLTV guide URL (playlist links
    that are really Xtream logins are upgraded automatically)
  - **Stalker / Ministra portal**: portal URL and MAC address

## Privacy

- Logins are stored only on the device, encrypted in the Keychain as
  "this device only": not synced to iCloud, not in backups.
- For Emby only the session token is kept, never the password.
- Nothing goes anywhere except to your own Emby server and IPTV providers.
  OpenIPTV has no servers, no analytics, and logs nothing; error messages
  never include URLs (IPTV URLs contain logins); the player's logging is off.
- Settings → *Forget everything on this device* wipes it all.

## iPhone, iPad and Apple TV

`apple/` (SwiftUI, iOS/tvOS 26). Live TV plays through libmpv (MPVKit's LGPL
build), which handles the MPEG-TS streams AVPlayer can't.

- **Simulator:** open `apple/OpenIPTV.xcodeproj` in Xcode 26 and Run. The
  first build fetches MPVKit (`apple/scripts/fetch-mpvkit.sh`, checksum
  verified). After editing `apple/project.yml`, run `xcodegen` in `apple/`.
- **Your devices:** add your Apple ID in Xcode → Settings → Apple Accounts,
  pick your team under Signing & Capabilities, and Run on your iPhone or
  Apple TV. A free Apple ID works; installs then last 7 days.
- **TestFlight** (paid developer account): create the app in App Store
  Connect (platforms iOS + tvOS, bundle ID `com.jorda0mega.openiptv` or your
  own in `apple/project.yml`), then `apple/scripts/testflight.sh <TEAM_ID>`.

## Web version (self-hosted)

The browser can't reach most IPTV servers directly (plain HTTP, no CORS),
so the web app runs behind a small relay, `openiptv-edge`, that you host.
Give it your logins through environment variables (from wherever you keep
them; nothing is written to disk):

```sh
cargo build --release -p openiptv-edge && (cd web && npm ci && npm run build)
OPENIPTV_EMBY_URL=… OPENIPTV_EMBY_USER=… OPENIPTV_EMBY_PASS=… \
OPENIPTV_XTREAM_URL=… OPENIPTV_XTREAM_USER=… OPENIPTV_XTREAM_PASS=… \
  target/release/openiptv-edge            # http://127.0.0.1:8787
```

`OPENIPTV_EMBY_CONNECT_USER`/`_PASS` sign in with Emby Connect instead, and
`OPENIPTV_EDGE_ADDR=0.0.0.0:8787` opens it to your network (other devices
must open a one-time link it prints). An optional 1Password launcher lives
in [contrib/1password](contrib/1password).

## Developer tools

```sh
apple/Tools/smoke/run.sh          # the apps' provider code against real or mock services
scripts/probe.sh                  # latency, guide accuracy and artwork coverage of your servers
python3 scripts/mock_server.py 8765   # fake Emby + Xtream + M3U + Stalker for development
cargo test
```

The smoke test and probe read logins from environment variables and print
only counts, names, timings and hostnames.

## License

MIT

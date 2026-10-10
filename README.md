<p align="center"><img src="favicon.svg" width="96" height="96" alt="OpenIPTV logo"></p>

# OpenIPTV

One fast app for your Emby library and your Xtream live TV, on iOS, Apple TV,
Fire TV and the web. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

**Status:** early. The shared Rust core (Emby + Xtream clients, EPG engine,
streaming XMLTV parser), a diagnostic probe and the **web version** exist.
Native iOS/tvOS/Fire TV apps are next.

OpenIPTV is a player only. It ships no channels, playlists or media: you
bring your own Emby server and an IPTV subscription you're entitled to use.

## Run the web version

Needs Rust, Node.js and the [1Password CLI](https://developer.1password.com/docs/cli/)
with your logins saved as 1Password items:

```sh
scripts/serve.sh --emby "Emby Connect" --xtream "My IPTV"         # http://127.0.0.1:8787
scripts/serve.sh --emby "Emby Connect" --xtream "My IPTV" --lan   # also on your phone
```

Logins are read from 1Password when the server starts and only live in its
memory. With `--lan`, the server prints a one-time link for your phone (same
Wi-Fi); other devices are refused without it. Without 1Password, set the same
`OPENIPTV_*` variables the probe uses and run `target/release/openiptv-edge`.

## Run the iPhone app (native, Liquid Glass)

The iOS app (`apple/`, SwiftUI, iOS 26) talks to the same server, so your
logins stay on your Mac. Live TV plays through libmpv (MPVKit), which handles
the MPEG-TS streams AVPlayer can't.

1. Start the server with `--lan` (above). It prints a pairing link.
2. Open `apple/OpenIPTV.xcodeproj` in Xcode 26. (After changing
   `apple/project.yml`, regenerate it with `xcodegen` from `apple/`.)
3. Simulator: just press Run; it connects to `127.0.0.1:8787` automatically.
4. Your iPhone: Xcode → Settings → Apple Accounts → add your Apple ID; select
   the OpenIPTV target → Signing & Capabilities → choose your team; plug in
   (or Wi-Fi pair) your iPhone and press Run. In the app, paste the pairing
   link. A free Apple ID works; the install then lasts 7 days.

## TestFlight (iPhone, iPad and Apple TV)

Needs a paid Apple Developer Program membership.

1. Xcode → Settings → Apple Accounts: sign in with your developer Apple ID.
2. App Store Connect → Apps → **+** → New App: platforms iOS and tvOS,
   bundle ID `com.jorda0mega.openiptv` (or change it in `apple/project.yml`;
   run `apple/scripts/testflight.sh` once first if the ID isn't listed yet,
   which registers it).
3. `apple/scripts/testflight.sh <TEAM_ID>` archives both apps and uploads
   them. After processing, install from the TestFlight app on your iPhone
   and Apple TV (you're an internal tester as the account holder; external
   testers need a public link and Beta App Review).

## Measure your servers

```sh
scripts/probe.sh            # prompts for URLs and credentials (passwords hidden)
scripts/probe.sh --json report.json --samples 40
```

Reports login and list latency, whether your provider offers HLS, how often
"now playing" is right (short EPG vs XMLTV), stream start time, and Emby
artwork coverage. Credentials are never written to disk; the JSON report
contains no credentials or URLs.

## Develop without real servers

```sh
python3 scripts/mock_server.py 8765 &
OPENIPTV_XTREAM_URL=http://127.0.0.1:8765 OPENIPTV_XTREAM_USER=u OPENIPTV_XTREAM_PASS=p \
OPENIPTV_EMBY_URL=http://127.0.0.1:8765 OPENIPTV_EMBY_USER=u OPENIPTV_EMBY_PASS=p \
cargo run -p openiptv-probe
```

## Tests

```sh
cargo test
cargo run --release -p openiptv-core --example xmltv_bench -- 3000 7
```

## License

MIT

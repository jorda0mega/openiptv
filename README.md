# OpenIPTV

One fast app for your Emby library and your Xtream live TV, on iOS, Apple TV,
Fire TV and the web. See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

**Status:** early. The shared Rust core (Emby + Xtream clients, EPG engine,
XMLTV parser) and a diagnostic probe exist; the apps don't yet.

OpenIPTV is a player only. It ships no channels, playlists or media: you
bring your own Emby server and an IPTV subscription you're entitled to use.

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

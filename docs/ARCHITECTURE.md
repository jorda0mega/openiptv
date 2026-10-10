# OpenIPTV architecture

One app for an existing **Emby** library and an **Xtream Codes** live TV
subscription, on iOS, Apple TV, Fire TV and the web. Priority order:
speed (instant UI, fast start, no buffering) → correct metadata (covers, live
titles) → everything else.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Shared logic | **Rust** crate `openiptv-core` | Fastest option that runs everywhere: compiled into the iOS/tvOS and Fire TV apps via UniFFI, and into the web relay. Parsing, EPG, caching and artwork rules are written once. |
| Apple UI (iOS + tvOS) | **Swift**, one codebase, SwiftUI with UIKit for the big grids | Native focus engine and scrolling; no JS bridge. |
| Fire TV UI | **Kotlin**, Compose for TV | Fire OS is Android; native is fastest on low-end sticks. |
| Web UI | **TypeScript**, minimal framework (Solid) | Smallest runtime; the heavy lifting is server-side. |
| Web relay (`openiptv-edge`) | **Rust** (axum) using `openiptv-core` | Browsers can't reach most Xtream panels directly (plain HTTP, no CORS). The relay proxies streams and serves a pre-digested guide. |
| Cross-platform UI frameworks | Rejected | Flutter has no tvOS support; React Native puts a JS bridge between the UI and the data, and low-end Fire Sticks are where it shows. The cost is three thin UI layers, so they contain no logic. |

### Players

| Platform | Live TV | Emby library |
|---|---|---|
| Apple | AVPlayer when the provider offers HLS (hardware decode, PiP, AirPlay); libmpv (MPVKit) for TS-only providers | libmpv: direct-plays MKV/HEVC/DTS without asking Emby to transcode |
| Fire TV | Media3 ExoPlayer (HLS and TS) | ExoPlayer, direct play first |
| Web | hls.js (native HLS on Safari); mpegts.js for TS via the relay | Direct play when the browser can, Emby HLS transcode otherwise |

The probe tells us which live path applies: `output formats` and the
`m3u8` vs `ts` start times.

## Speed tactics

1. **Cache-first.** Every screen renders the last known data from local
   storage immediately and refreshes in the background. Nothing waits on the
   network to draw.
2. **Live titles that are never stale.** Times are handled only as UTC unix
   timestamps (`epg.rs`). Every now/next answer carries `refresh_at`, the
   exact second it stops being true, so the UI updates on programme
   boundaries with one timer rather than polling. The short EPG is re-fetched
   on channel focus/zap; XMLTV fills the guide grid.
3. **Guide only for channels you use.** A 250 MB / 1M-programme XMLTV parses
   in ~0.4 s on an M-series Mac (`examples/xmltv_bench.rs`); a Fire TV Stick
   is several times slower with a fraction of the memory. `xmltv::parse`
   takes a channel filter, so devices keep only favourites/visible groups.
4. **Fast zapping.** One warm HTTP connection pool; stream URLs are known
   before the click; the player instance is reused. Preloading the next
   channel is only possible if `max_connections` > 1.
5. **Artwork.** Image URLs include Emby's image tag, so they never change for
   the same picture and are cached forever on device. Images are requested at
   rendered size × screen scale. Card shape comes from
   `PrimaryImageAspectRatio` before the image loads, so grids don't jump.
   Fallback rules: see `emby-client-behavior.md`.
6. **Small payloads.** Emby list calls request only the card fields
   (`emby.rs::card_query`).

## Milestones

- **M0 — core + probe** (done): Xtream and Emby clients, EPG engine, XMLTV
  parser, `openiptv-probe` against real servers.
- **M1 — Apple TV vertical slice:** home (Continue Watching, Latest, Live
  Now), channel list with now/next, player. Measure cold start and zap time.
- **M2 — iOS** from the same Swift codebase.
- **M3 — Fire TV.**
- **M4 — Web + `openiptv-edge` relay.**

## Reverse engineering (REA)

REA is used to learn behaviour, not to copy code: Emby's own web client is
traced to get artwork fallbacks and request shapes right. UHF/iSTB can be
studied through their network traffic (HAR captures) for zapping and EPG
tricks. No decompiled code goes into this repo.

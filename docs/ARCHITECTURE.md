# Zapline architecture

One app for an existing **Emby** library and **IPTV** subscriptions, on
iPhone, iPad and Apple TV, plus a self-hosted web version. Priority order:
speed (instant UI, fast start, no buffering) → correct metadata (covers, live
titles) → everything else. Users sign in inside the app; nothing depends on
any particular password manager or on a server we run.

## Pieces

| Piece | Language | Role |
|---|---|---|
| `apple/` | Swift / SwiftUI (iOS & tvOS 26) | Native apps with Liquid Glass. Talk to Emby and IPTV providers directly from the device. |
| `crates/core` | Rust | Emby, Xtream and XMLTV logic for the web relay and the probe. The Swift data layer mirrors it. |
| `crates/edge` | Rust (axum) | Self-hosted relay for the web app: browsers can't reach most IPTV servers (plain HTTP, no CORS). |
| `web/` | TypeScript, no framework | Web app served by the relay; 5 KB gzipped before playback. |
| `crates/probe`, `apple/Tools/smoke` | Rust, Swift | Measure real servers; run the apps' provider code outside the UI. |

The Apple apps use Swift rather than the Rust core because Rust's tvOS
targets need the nightly toolchain; the logic is small and mirrored.

## Sources

- **Emby:** server login or Emby Connect (pick a linked server, then trade
  its access key for a session). Only the session token is kept.
- **IPTV**, any number of subscriptions:
  - **Xtream Codes** (`player_api.php`): lenient decoding (numbers as
    strings, `false` for empty lists…), base64 EPG text, short EPG for
    instant now/next, `xmltv.php` for the full guide.
  - **M3U**: `#EXTINF` attributes (`tvg-id`, `tvg-logo`, `group-title`,
    `tvg-chno`), `#EXTVLCOPT` user agent/referrer, guide from the header or
    a user-entered XMLTV URL. `get.php` links are upgraded to Xtream.
  - **Stalker/Ministra**: MAC-identified handshake → token → genres,
    channels, per-play `create_link`, short EPG.
- Channels named like account details (login, expiry, connections), or that
  contain the login itself, are dropped; some panels list those as channels.

## Privacy

- Credentials: Keychain only, `AfterFirstUnlockThisDeviceOnly`, not
  synchronizable (no iCloud, no backups). Emby passwords are never kept.
- Caches hold display data only (home rows with tag-based image URLs, the
  parsed guide); never credentials or stream URLs. Favorites drop playlist
  stream URLs before saving and re-resolve them from the live lineup.
- No logging: libmpv `msg-level=all=no`; user-facing errors come from
  `SourceError`, which never includes URLs (IPTV URLs carry logins).
- The web relay keeps logins in memory only; sign-out clears them.

## Speed tactics

1. **Cache-first.** Home rows render from the on-device cache, then refresh.
2. **Live titles that are never stale.** Times are UTC unix seconds; every
   now/next carries `refreshAt`, and one timer fires at the earliest
   programme change among visible channels. Full guide first (placeholder
   titles like "No Information Available" don't count), provider short EPG
   as fallback. On one real provider the full guide covered 20 of 24 sampled
   channels and the short EPG only 8.
3. **Guide off the critical path.** The XMLTV file (195 MB on one provider)
   downloads to a temporary file in the background, is gunzipped if needed,
   stream-parsed keeping only the user's channels and the next 12 hours, and
   cached; refreshed every 6 hours.
4. **Faster Emby queries.** Continue Watching via `Items?Filters=IsResumable`
   (0.8 s vs 2.1 s for `Items/Resume` on a real server); Latest per library
   in parallel instead of one all-library query.
5. **Artwork.** Every usable image in Emby's order (series art first on
   Continue Watching), falling through on load errors; sized to the card;
   tag-based URLs cached for good. Card shape from `PrimaryImageAspectRatio`
   before images load.
6. **Playback.** libmpv (MPVKit, LGPL) plays MPEG-TS that AVPlayer can't,
   Vulkan-on-Metal rendering, VideoToolbox decoding, one player reused across
   channel changes; profiles trade start-up speed against buffering.

## Reverse engineering (REA)

REA was used to learn Emby's web client behaviour (artwork fallbacks,
request shapes, live TV refresh); see `emby-client-behavior.md`. No
decompiled code is in this repository.

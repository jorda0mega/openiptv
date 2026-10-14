# How the Apple TV app keeps playback smooth (research, 2026-10-13)

Clean-room notes: only class and method names were read, no code. Method:
the Mac TV app (`/System/Applications/TV.app`) links the private frameworks
VideosUI and TVPlayback, which live in macOS's shared library cache, so REA
(no disassembler installed) and `strings` can't read them. A small program
loaded each framework and listed its Objective-C class and method names
(`objc_copyClassNamesForImage`, `class_copyMethodList`). The TV app's web
bundle is a small native stub, nothing to read. Netflix's iOS app is
encrypted (App Store), and its web player needs a signed-in session, so it
wasn't read.

## What the names show

| Apple TV app (class, method names) | What it does | Ours |
|---|---|---|
| VideosUI `VUIMediaInfoFetchController`: `_createPlayerWithPlaylist:isForPrewarming:`, `prewarmedPlayers`, `_prewarmIndices`, `playerPreloadOffset`, `preloadPlayback` | Players made ahead for the titles near the one in view, by index | A player opened ahead for Continue Watching's first title and a show page's main button, on unmetered networks (`AppModel.warmUp`) |
| `VUIBackgroundMediaController`: `_prefetchNextVideo`, `prefetchPlayer`, `prefetchesVideoFrame` | The next video and even its first frame fetched ahead | The next episode's playback worked out at 80% (`prepareNext`); played at the end in the same screen |
| `VUILaunchConfig`: `prewarmUTSConnection`, `prewarmImageConnection`, `prefetchLastSelectedTab` | Network connections opened at launch, before the first request | Not done: the first Home request opens the connection |
| TVPlayback `TVPPlayer`: `maximumBitRate`, `preferredForwardBufferDuration`, `preferredMaximumResolution`, `preferredMaximumResolutionForExpensiveNetworks` | A bitrate cap, how far ahead to buffer, and a lower resolution on cellular | Readahead by network (`MPVPlayer.setReadahead`); the original file, stepping down to a converted stream after stalls (`QualityGovernor`); no cellular cap |
| `_currentPlayerItemDidStall:`, `_currentPlayerItemLikelyToKeepUpDidChangeTo:` | Stalls watched as they happen | `paused-for-cache` and buffer readings feed the quality governor |
| `TVPPlayerBookmarkMonitor`: `_bookmarkPeriodicSaveTimerFired:`, `playbackOfMediaItemIsEnding` | The resume point saved on a timer and at the end | Progress every 10 s and at the stop (`AppModel.report`) |
| `playerItem:shouldSeekToTime:toleranceBefore:toleranceAfter:` | The seek tolerance chosen per jump | Keyframe-fast skips, exact seeks when scrubbing slowly |

## Possible next steps (not done; each needs the user's go)

1. Open the Emby connection at launch (as `prewarmUTSConnection`).
2. A lower cap on cellular (as `preferredMaximumResolutionForExpensiveNetworks`).
3. Players made ahead for the hero's titles, not only Continue Watching's
   first (as `_prewarmIndices`).

# Title page and player

A film's or show's page shows its art, story and a main button (`Play`, `Resume` or `Continue`) with `Add to My List` beside it. The player plays the title with controls for pause, skipping 10 seconds, audio and subtitles, speed and info, and keeps the user's place on the server.

## Sub-features

- `title-page` shows the title, its story (two lines and `More of the story`) and the main button.
- `title-mylist` adds the title to My List (`Add to My List` turns into `Remove from My List`) and removes it.
- `player-play` plays from the start or resumes where the user stopped.
- `player-controls` pauses, plays, and skips back and forward 10 seconds.
- `player-tracks` picks audio and subtitles in `Audio and Subtitles`.
- `player-close` closes the player and stores the position on the server.

## How to get to it (user POV)

- Choose a result in Search, or a card on Home.
- Choose the main button on the title page.
- Choose a `Continue Watching` card on Home: it plays from the stored position.

## Driving it with agent-device

Preconditions:

- Baseline preconditions in the [index](./README.md), with the test films present (`$V doctor` warns when they are missing).
- `$V mock reset`, then `$V relaunch`.

- **Open a film.** Search `dune` and choose `Dune: Part Two` (see [Search](./search.md)). The page shows `Play` and `Add to My List`. Run `$V shot title-page`.
- **Story.** Choose `More of the story`. Run `$V ad press 'label="More of the story"' --settle`. The whole story shows.
- **Add to My List.** Run `$V ad press 'label="Add to My List"' --settle`. The button becomes `Remove from My List`. Read it back: `curl -s "$($V url)/emby/Users/U1/Items/a8?api_key=tok"` has `"IsFavorite": true`. The second view is Home's `My List` row (see [Home](./home.md)).
- **Play.** Run `$V ad snapshot -i`, then press the button whose label starts with `Play`. The player opens. Within 10 seconds `$V ad get text 'id="debug-position"'` reads `<seconds> playing` with seconds rising. Run `$V shot player-playing`.
- **Controls.** Tap the video to show the controls, then choose `Pause`. Run `$V ad press 'label="Pause"' --settle`. `debug-position` ends in `paused` and its seconds stop. `Forward 10 seconds` adds 10 seconds.
- **Tracks.** Choose `Audio and Subtitles`. The sheet lists the film's audio and subtitle tracks and `Off`.
- **Close and resume.** Choose `Close player`. Read it back: the item's `UserData` has `PlaybackPositionTicks` (seconds times 10,000,000). Reopen the page: the main button says `Resume`.
- **Reset.** Run `$V mock reset`.

## Gotchas

- Without the test films, `debug-position` never rises. Run `$V media` first.
- The controls hide after a few seconds. Tap the video again before each control press.
- Emby keeps no place for a stop in the first few percent when `min_resume_pct` is set. With the switches reset it keeps every stop.
- `a8` and `k8` are two copies of `Dune: Part Two` (1080p and 4K). The page shows one title; the item read back is the copy that played (`$V ad get text 'id="debug-item"'` names it).

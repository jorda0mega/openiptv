# Openreel verification map

This directory is the maintained source for verifying what an Openreel iPhone user sees and does. Read this index before you drive the app, then use the matching feature file as the recipe. `$V` is `.claude/skills/verify-openiptv/scripts/verify`, run from the repo root.

## Baseline preconditions

- `$V up` has printed `ready.` and `$V doctor` prints no `FAIL`.
- The app is signed in to the test server (`scripts/mock_server.py`): an Emby library of about 30 titles and an Xtream lineup of 40 `UK: Channel <n>` channels plus 6 US local stations.
- The test server's switches are at their defaults (`$V mock reset`) unless a recipe says otherwise.
- The test films are in `/tmp/openreel-media` when the recipe plays video.
- Drive only the private instance the helper started.

## Driving conventions

- Start each recipe from a fresh launch: `$V relaunch`.
- The iPhone tab bar has three tabs: `Home`, `Live TV` and `Search`.
- Prefer accessibility identifiers (`id="row-My List"`, `id="debug-live-copy"`) and exact labels (`label="Watch On"`) over coordinates. For a row whose label is long or changes (a game, a search result), take its `@e` ref from `$V ad snapshot -i`.
- The selectors here come from the XCUITests in `apple/UITests-iOS/` and from runs. agent-device shows list rows and menu items as `cell` where XCUITest sees a button: use the ref. When a selector misses, find the element in `$V ad snapshot -i`, use its ref, and correct the recipe.
- Check that a press changed the screen: a settle diff of `+0 -0` after a tab press means the press was lost (seen once right after a launch). Press again.
- After a press, continue from the `--settle` diff. Wait for server-loaded content with `$V ad wait text "<text>" <ms>`.
- Reset what a recipe changed (`$V mock reset`). Cleanup never removes proof.

## Proof and skip reporting

- Capture the action and the result: `$V shot <feature>-<step>` before and after.
- Proof is the visible screen plus its snapshot text. Debug readouts (`debug-live-copy`, `debug-live-state`, `debug-position`) back it up.
- A change to stored state is proved twice: on a second screen in the app, and read back from the server (`curl -s "$($V url)/emby/Users/U1/Items/<id>?api_key=tok"`).
- Record the feature file and entry point with every shot.
- Report an entry point you could not reach with the command you tried and the missing precondition. Do not report it as verified through another entry point.

## Feature entry contract

Each feature file starts with an H1 title and one paragraph that describes what the user sees. It then has exactly four H2 sections, in this order:

1. `Sub-features` lists short IDs, one line each.
2. `How to get to it (user POV)` lists every entry point a user has.
3. `Driving it with agent-device` starts with `Preconditions:`, then labeled bullets that pair each user action with an exact command and the observable result.
4. `Gotchas` lists traps that waste or invalidate a run.

Keep implementation details out of the map: name user paths, stable handles, required state, commands and observable proof.

## Features

- [Live TV sports](./live-sports.md) covers the Sports shelf: game rows, LIVE, the channel count, the long-press channel list and Watch On in the player.
- [Live TV channels](./live-channels.md) covers the shelves, channel rows, playing a channel and favorites.
- [Search](./search.md) covers genre tiles, typed searches, the scope filters and opening a result.
- [Title page and player](./title-and-player.md) covers a film's page, My List, playback and the player controls.
- [Home](./home.md) covers Home's rows, Continue Watching, My List and opening a whole row.

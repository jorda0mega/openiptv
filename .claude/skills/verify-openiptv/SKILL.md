---
name: verify-openiptv
description: Proof on the Openreel (OpenIPTV) iPhone app. Drives it on a private simulator against the repo's test server, as a user would, and saves screenshots and accessibility snapshots. Use to prove an iPhone UI change, to reproduce a UI bug before fixing it, or to run the XCUITests (iPhone; Apple TV secondary).
---

# Verify Openreel (OpenIPTV)

Openreel is a SwiftUI player for an Emby library and IPTV live TV. The primary surface is the iPhone app: scheme `OpenIPTV`, bundle `com.jorda0mega.openiptv`, project `apple/OpenIPTV.xcodeproj`. The Apple TV app (scheme `OpenIPTV TV`) is secondary, see [Apple TV](#apple-tv-secondary).

Run everything through the helper, from the repo root:

```sh
V=.claude/skills/verify-openiptv/scripts/verify
```

## Rules

- Read `AGENTS.md` first. Its login rules are absolute.
- Other agents share this Mac, its simulators and this checkout. Drive only the **private** instance that `$V up` starts: the simulator "Zapline Verify iPhone", its own test-server port, the build folder `/tmp/openiptv/dd-verify`, and the agent-device session `openiptv-verify`. Leave every other simulator, server, port and build folder alone. Stop processes by the PID the helper recorded, never by name.
- The helper signs the app in to the test server with its fake account (token `tok`, Xtream `u`/`p`) through the launch environment. That is the only login that may go there. The real feeds have their own rules, see [Real feeds](#real-feeds).

## Launch

```sh
$V up
```

Ready when it prints `ready. Evidence goes to <folder>`. It refuses to start, and starts nothing, while another run is active or when the disk has less than 4 GB free (6 GB when it must create the simulator: a new simulator takes about 2 GB on first boot). In order, it:

1. Makes the evidence folder `.audit/verify/<YYYYMMDD-HHMM>/`.
2. Starts `scripts/mock_server.py` (Emby + Xtream) on the first free port from 8790, logging to `mock-server.log` in the evidence folder.
3. Finds or creates "Zapline Verify iPhone" (iPhone 17 Pro, newest iOS) and boots it.
4. Builds Debug into `/tmp/openiptv/dd-verify` (about 0.4 GB) and installs it. The first build takes 1 to 15 minutes, depending on Xcode's caches.
5. Launches the app signed in to the test server and attaches the agent-device session.

What it started is in `.audit/verify/state.env`. For a second run at the same time, prefix every command with `VERIFY_ID=<name>`: it gets its own simulator, port, build folder and state.

After you change app code: `$V build && $V relaunch`. A build error in a file you did not edit can be another agent's edit in progress: wait 2 minutes, retry once, then report it.

Video playback needs the test films in `/tmp/openreel-media` (`test.mkv`, `hls/`, `test.bif`). The nightly `/tmp` cleanup can delete them. Other runs share the folder, so `$V media` rebuilds it with ffmpeg only when it is missing; then run `$V down && $V up`. Lists, pages and menus work without them.

## Doctor

```sh
$V doctor
```

Read-only. Run it first whenever something looks wrong, and before you trust a result. Each line is `ok` or `FAIL` with its fix. It checks that the recorded PID runs `mock_server.py` and holds the port, the server answers (and prints its current switches), the simulator is booted, the app is installed, running and built from the current checkout, and the agent-device session is open. It warns when the test films are missing or disk is low.

## Drive

Drive with agent-device through `$V ad <command> [args]`. It adds `--platform ios --udid <ours> --session openiptv-verify --state-dir <ours>`, so every command lands on the private simulator. Run them one at a time. For command shapes, run `agent-device help workflow`.

```sh
$V ad snapshot -i                               # refs for the visible controls
$V ad press 'label="Live TV"' --settle          # tab bar
$V ad wait 'label="Sports"' 10000
$V ad longpress @e12 1200                       # a ref from the last snapshot -i
$V ad get text 'id="debug-live-state"'
```

- **Test server switches.** `$V mock k=v ...` sets them, `$V mock reset` clears them. The list is the comment over `CONTROL` near the top of `scripts/mock_server.py`, plus `sports`, `sports_started`, `sports_dupes` and `dead_live` next to their code. Set a switch, then `$V relaunch`, when it changes what the app loads at launch (the lineup, Home).
- **Launches.** `$V relaunch [args]` restarts the app with `-freshLineup YES -forgetWatchOnPicks YES` and your extra arguments, then reattaches the session. Debug knobs go in its environment: `OPENREEL_DEBUG_LIVE_START_LIMIT=3 $V relaunch`. Find the knobs with `grep -rn OPENREEL_DEBUG_ apple/OpenIPTV`. Use `$V relaunch`, not `$V ad open --relaunch`: only the helper passes the test-server sign-in.
- **Debug readouts.** Debug builds put app state in hidden text elements: `debug-live-copy` (the channel open in the live player), `debug-live-state` (`starting`, `playing` or `failed`), `debug-position` (`<seconds> playing|paused`), `debug-item` (the title playing). Read them with `$V ad get text 'id="<name>"'`. They support a proof; the visible screen is the proof.

Recipes per feature, with the handles to use, are in [`features/README.md`](features/README.md). Read it before you drive a feature.

## Evidence

```sh
$V shot <name>        # <folder>/<name>.png and <folder>/<name>.snapshot.txt
```

A proof meets all of these:

- It reaches the feature as a user does: tabs, buttons, long presses, typing. Launch shortcuts such as `-debugSearch` and `/mock/` calls that fake app state are setup tools, not proof.
- It captures the action and the result: a shot before the action and one after.
- It checks side effects as well as the screen. Read stored state back from the server, for example a title's `UserData` (`IsFavorite`, `PlaybackPositionTicks`): `curl -s "$($V url)/emby/Users/U1/Items/a0?api_key=tok"`. `mock-server.log` lists the app's Emby GETs (not images) and some POSTs. It does not list Xtream, live-channel, playback-report or My List requests.
- It names, for every shot, the feature file and entry point it proves.

## UI tests

```sh
$V uitest LiveSportsTests/testLongPressListsTheGamesChannels [Class/test ...]
```

Runs XCUITests from `apple/UITests-iOS/` on the private simulator and test server. It closes the agent-device session first (one UI-testing runner per simulator; `$V relaunch` reattaches it), builds for testing, and retries a simulator start-up error up to 3 times. It prints each test's result and keeps the log in the evidence folder; a failed run also keeps its `.xcresult` (screenshots).

The first test after `$V up` can fail because its setup request to the test server did not take effect (seen once). The test then reports, for example, `the game isn't in Sports`, and `curl -s "$($V url)/mock/set"` shows only the switches its teardown set. Rerun the test once before you report a failure.

## Apple TV (secondary)

`$V uitest --tv <Class/test>` runs `apple/UITests-tvOS/` on "Zapline Verify Apple TV" (created on first use) with its own build folder, `/tmp/openiptv/dd-verify-tv` (about 600 MB more). Driving tvOS by hand is focus-first (`agent-device help tv`) and the helper does not do it. Neither path is proven by a run yet: treat the first run as unverified and fix this section from what it shows.

## Real feeds

The real feeds are the user's own Emby server and IPTV subscription. This helper never touches them.

- The only route is `../release/hold-real-feeds.sh` (one level above the repo) with `RealFeedTests`. The holder reads the logins itself, keeps them in memory, serves them on port 8799 and checks the shared test simulators for leaks afterwards. Run that round only when the user asks for it, on the simulators it names.
- Keep logins out of your context. Never read them, never run the `op` (1Password) command, never run agent-device `network` or `logs` against the real feeds: Xtream stream URLs carry the username and password.
- Keep IPTV lineup loads under about 10 per 30 minutes. Each app launch can load the lineup; the provider answers HTTP 429 above that.

## Cleanup

```sh
$V down             # end the run, keep evidence, simulator and build folder
$V down --purge     # also delete the private simulators and build folders
```

`down` closes the session, stops the private agent-device daemon, stops the test server by its recorded PID (after it checks the PID runs `mock_server.py` on that port), shuts down the private simulators and removes the state file. It prints the evidence folder and its files: they stay. Use `--purge` when the disk is low or the work is done. `down` is safe to repeat and cleans up after a failed `up`.

## Helpers

- `scripts/verify` is the only helper. `$V` with no command prints its usage line.

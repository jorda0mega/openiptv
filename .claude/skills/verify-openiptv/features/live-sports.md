# Live TV sports

Sports lists games by when they are on (`Live now`, `Later today`, `Tomorrow`, `Coming up`, `Earlier today`). A game that several channels show is one row that says `LIVE` once it has started and how many channels show it. A long press on the row lists those channels (Watch On); the one picked plays. In the player, `Watch On` lists the same channels and marks the one playing.

## Sub-features

- `sports-row` shows one row per game with `LIVE` and `<n> channels`.
- `sports-longpress` lists the game's channels in the order they play, each with its language.
- `sports-play` plays the best channel on a tap, or the channel picked from the list.
- `sports-watchon` lists the channels in the player and switches between them.
- `sports-pick-remembered` plays the channel last picked for that league first next time.
- `sports-when` puts a game under the right heading (`Live now`, `Earlier today`, later) from its start time.
- `sports-not-playing` says `Not playing` on a game none of whose channels sends a picture.
- `sports-current` keeps the games current: a refused check (`xtream_status=429`) says `Couldn't update the games` with the list's age and the reason, instead of `Nothing on right now`; an empty answer (`xtream_empty=streams` or `categories`) keeps the games listed.

## How to get to it (user POV)

- Choose the `Live TV` tab, then the `Sports` shelf.
- Long-press a game row.
- Tap a game row, show the player controls, then choose `Watch On`.

## Driving it with agent-device

Preconditions:

- `$V mock reset`, then `$V mock sports=1 dead_live=none`, then `$V relaunch`. With `sports=1` the test server lists one game, `Eagles vs. Jaguars`, on five channels: `NFL 01` (NFL), `ESPN UNLTD 015` and `016` (ESPN Unlimited, English and Spanish), `DAZN CA 17` and `19` (DAZN CA, English and French). It started 20 minutes ago.
- `$V doctor` prints no `FAIL`.

- **Open Sports.** Choose `Live TV`, then `Sports`. Run `$V ad press 'label="Live TV"' --settle`, then `$V ad press 'label="Sports"' --settle`, then `$V ad wait text "Jaguars" 15000`. The filter pills `Top`, `All`, `NFL` and `Channels` show, and the heading `Live now` shows over the game.
- **Read the row.** Run `$V ad snapshot -i`. The game is a cell labelled like `NF, Football: Eagles vs. Jaguars, LIVE, Started 6:35 PM · NFL · 5 channels`: it contains `LIVE` and `5 channels`. Run `$V shot sports-row`. On screen the count is cut to `5 chann…`; the snapshot text carries it whole.
- **List the channels.** Long-press the row. Run `$V ad snapshot -i`, then `$V ad longpress @eN 1200` with the game cell's ref. A menu, a collection labelled `Watch On · 5 channels`, lists the cells `NFL`, `ESPN Unlimited`, `DAZN CA`, `ESPN Unlimited`, `DAZN CA`, in that order. On screen the last two have a second line, `Spanish` and `French`; the accessibility labels carry only the network, so the screenshot proves the languages. Run `$V shot sports-longpress`.
- **Play the channel picked.** Run `$V ad snapshot -i`, then `$V ad press @eN --settle` with the ref of the second `ESPN Unlimited`. The live player opens with `LIVE`, the game's title, `Guide` and `Watch On`. `$V ad get text 'id="debug-live-copy"'` starts with `ESPN UNLTD 016`. With the test films, `$V ad get text 'id="debug-live-state"'` reads `playing` within a few seconds. Run `$V shot sports-picked-playing`.
- **Close the player.** Tap the middle of the video to show the controls, then choose `Close player`. Run `$V ad snapshot -i` to find the video's ref, `$V ad press @eN`, then `$V ad press 'label="Close player"' --settle`. The Sports list returns.
- **Play the best channel.** `$V relaunch`, open Sports again and tap the game row: `$V ad press @eN --settle`. `debug-live-copy` starts with `NFL 01`.
- **Watch On in the player.** Show the controls, then choose `Watch On`. Run `$V ad press 'label="Watch On"' --settle`. Five cards with ids starting `player.card.` appear. The `NFL` card's label contains `Playing`; a `DAZN CA` card contains `French`; an `ESPN Unlimited` card contains `Spanish`. Run `$V shot sports-watchon`.
- **Pick remembered.** Pick the Spanish card, close the player, and tap the game again without `$V relaunch`. `debug-live-copy` starts with `ESPN UNLTD 016`.
- **Start time.** `$V mock sports_started=230`, `$V relaunch`, open Sports. The row has no `LIVE`, and the heading is `Earlier today`, not `Live now`. With `sports_started=-180` the row has no `LIVE` and there is no `Live now`.
- **Not playing.** `$V mock dead_live=2001,2002,2003,2004,2005`, then `OPENREEL_DEBUG_LIVE_START_LIMIT=3 $V relaunch`. Open Sports and tap the game. Within 40 seconds `debug-live-state` reads `failed` and a message contains `playing right now`. Close the player: the row says `Not playing`, not `LIVE`.
- **Same feed twice.** `$V mock sports_dupes=1`, `$V relaunch`. The row says `6 channels`, and Watch On lists one `OneSoccer` card that contains `Football · Soccer`.
- **Refused check.** `OPENREEL_DEBUG_GAMES_MAX_AGE=5 $V relaunch` and open Sports (the game is listed). Then `$V mock xtream_status=429` and wait about 6 s with Sports open. Sports shows `Couldn't update the games` and a line with `Last updated` and `too many requests`; the games stay listed. `$V mock xtream_status=0`: within about 5 s the notice goes. `curl -s "$($V url)/mock/xtream_requests?since=0"` lists the Xtream actions the app sent (names and category ids only). Not yet driven by hand: written from the UI tests `testSportsSaysWhenItCouldNotUpdate` and `testSportsLeftOpenStaysCurrent`, which pass; fix this recipe from what the first run shows.
- **Reset.** Run `$V mock reset`.

## Gotchas

- The lineup loads at launch. Set switches first, then `$V relaunch`. While Sports stays open, the app checks the lineup again once it is 15 minutes old; `OPENREEL_DEBUG_GAMES_MAX_AGE=<seconds> $V relaunch` shortens that wait, so a switch set with Sports open shows within those seconds.
- Switches stay set across relaunches until `$V mock reset`.
- `$V relaunch` passes `-forgetWatchOnPicks YES`, so every relaunch forgets the league's pick. Prove `sports-pick-remembered` inside one launch.
- Without the test films, a channel never starts: `debug-live-state` stays `starting` and the player moves on to the next channel after its start limit. Prove playback only with the films present (`$V doctor` warns).
- A long press shorter than about one second taps the row and opens the player instead of the menu.
- `$V shot` takes a full snapshot, which renumbers the refs. Run `$V ad snapshot -i` again before you use a ref.
- The game's start is stamped in US Eastern time, as real providers stamp event channels. A wrong heading can be a time-zone bug, not a test-server problem.

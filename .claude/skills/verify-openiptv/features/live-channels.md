# Live TV channels

Live TV groups the provider's channels into shelves by what is on (`Sports`, `Local`, `News`, `Entertainment` and more), in a tab strip under the title. Each channel is one row with what is on now, however many copies the provider lists. A tap plays the channel. A long press favorites it. The provider's own categories are a tap away.

## Sub-features

- `live-shelves` shows the shelf tab strip and each shelf's rows.
- `live-play` plays a channel from its row.
- `live-favorite` adds a channel to `Favorites` from a long press, and removes it.
- `live-categories` lists the provider's categories with their channel counts; a long press hides one.
- `live-local` asks for the user's area (`Set your area`) and then shows its local stations.

## How to get to it (user POV)

- Choose the `Live TV` tab, then a shelf in the tab strip.
- Choose `Provider categories` (the list button at the top right), then a category.
- Long-press a channel row, or a category in the list.

## Driving it with agent-device

Preconditions:

- Baseline preconditions in the [index](./README.md). `$V mock reset`, then `$V relaunch`. The test lineup has the categories `UK` (`UK: Channel 1` to `UK: Channel 40`), `US | Local ABC` and `US | Local CBS` (three stations each, in Texas, New York and California).

- **Open Live TV.** Choose `Live TV`. Run `$V ad press 'label="Live TV"' --settle`, then `$V ad snapshot -i`. The navigation bar reads `Live TV` and the strip lists the shelves (`Sports`, `Local` and `More` in a run with `sports=1`). `More` holds the `UK` channels as cells labelled like `CH, Show 1-9, 4m left · Channel 1`. Run `$V shot live-shelves`.
- **Provider categories.** Choose the list button. Run `$V ad press 'label="Provider categories"' --settle`. A sheet lists `UK`, `US | Local ABC` and `US | Local CBS` with their channel counts. Choose `UK`: its rows, `UK: Channel 1` first, replace the shelf.
- **Play a channel.** Choose a row. Run `$V ad press @eN --settle` with the row's ref. The live player opens and `$V ad get text 'id="debug-live-copy"'` names the channel. With the test films, `debug-live-state` reads `playing` within 15 seconds. Run `$V shot live-playing`. Close with `Close player`.
- **Favorite.** Long-press a row. Run `$V ad longpress @eN 1200`, then `$V ad press 'label="Add to Favorites"' --settle`. The row shows a star (`label="Favorite"`) and a `Favorites` shelf appears. Run `$V relaunch`: Live TV opens on `Favorites` with that channel. Undo with `Remove from Favorites`.
- **Local stations.** Choose the `Local` shelf. `Where are you?` shows with `Set your area`. Choose it: the sheet `Your area` lists states. Choose `Texas`, type `Houston` in `City (optional)` and submit. Close the sheet: the Local shelf lists the Texas stations, `TX: ABC 13 Houston (KTRK)` and `TX: CBS 2 Houston (KHOU)` first. Avoid `Use my location`: it asks for the simulator's location permission.

## Gotchas

- Favorites live on the device only. `$V mock reset` does not clear them; remove them in the app, or `$V down --purge` for a clean simulator.
- With favorites present, Live TV opens on `Favorites`, not the first shelf.
- The shelves come from channel names, not from the provider's categories. A shelf missing from the strip means no channel classified into it, which is the thing to report.
- Channel rows load what is on for the rows on screen and the 30 below. Wait for the row's programme text before you read it.

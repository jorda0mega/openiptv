# Home

Home opens on a large featured title (the hero) over rows of titles: `Continue Watching`, `My List` and recommendation rows. A row's name opens the whole row as a grid of posters, three across. Home stays as it is while the user looks at it; changes from the server (a title watched or added elsewhere) show when the user comes back to Home.

## Sub-features

- `home-rows` shows the hero and the rows.
- `home-continue` shows `Continue Watching` cards that play from the stored position.
- `home-mylist` shows the `My List` row, newest first.
- `home-whole-row` opens a row's grid from its name.
- `home-stays-put` keeps the rows unchanged while on screen, and shows server changes after the user leaves and comes back.

## How to get to it (user POV)

- Launch the app: Home is the first tab.
- Choose the `Home` tab from another tab.
- Choose a row's name (a button with an id starting `row-`).

## Driving it with agent-device

Preconditions:

- Baseline preconditions in the [index](./README.md). `$V mock reset`, then `$V relaunch`.

- **Rows.** Wait for the first build. Run `$V ad wait 'label="Continue Watching"' 15000`. Scroll down with `$V ad scroll down`, then `$V ad snapshot -i`. Row names show as buttons with ids `row-<name>`. Run `$V shot home-rows`.
- **Whole row.** Choose a row name. Run `$V ad press @eN --settle` with a `row-` ref. A page with that row's name lists its posters three across. Choose a poster: its title page opens with `Play`, `Resume` or `Continue`.
- **Continue Watching.** Cards have ids `continue-<item id>`. Choose the first. Run `$V ad press @eN --settle` with a `continue-` ref. The player opens at the stored position (`debug-position` starts well above 0).
- **My List.** Add a title from its page (see [Title page and player](./title-and-player.md)), then `$V relaunch`. Scroll until `id="row-My List"` shows. The title is the first card under it. Run `$V shot home-mylist`.
- **Watched elsewhere.** On Home there is no `id="continue-m7"`. Leave the app with `$V ad home`, run `$V mock watched_elsewhere=m7`, wait 3 seconds, and come back with `$V ad open com.jorda0mega.openiptv`. Within 8 seconds `id="continue-m7"` shows in `Continue Watching`. Run `$V shot home-continue`.
- **Reset.** Run `$V mock reset`.

## Gotchas

- Home builds in the background for several seconds after a launch. Wait for its rows before you read them.
- Titles left on My List by an earlier run change the row order. Start with `$V mock reset`.
- `-forgetMyListOrder YES` clears the device's own My List order; pass it with `$V relaunch -forgetMyListOrder YES` when the order matters.
- `watched_elsewhere` stands in for another device. The proof is what Home shows after the user comes back, not the switch.

# Search

Search finds films, shows, people and what's on TV. With nothing typed it shows the library's genres as poster tiles, three across. Typed text lists results at once from the device, then adds the server's matches (cast, people, episodes) without moving what is already listed. Scope pills narrow the list.

## Sub-features

- `search-genres` shows genre tiles with nothing typed; a tile opens its genre's titles.
- `search-results` lists matches for typed text and keeps them in place while the server answers.
- `search-server-match` adds the server's matches (`zorro antonio` adds the films with Antonio Banderas).
- `search-scope` narrows results with `All`, `Movies`, `Shows` and `Live TV`.
- `search-empty` says `No Results` for text that matches nothing, only after the search has finished.
- `search-open` opens a result's page.

## How to get to it (user POV)

- Choose the `Search` tab and type in the search field (prompt `Movies, shows, people, what's on TV`).
- Choose a genre tile with nothing typed.

## Driving it with agent-device

Preconditions:

- Baseline preconditions in the [index](./README.md). `$V mock reset`, then `$V relaunch`.

- **Open Search.** Choose `Search`. Run `$V ad press 'label="Search"' --settle`. Tiles with ids starting `genre-` and the pill `id="scope-All"` show. Run `$V shot search-genres`.
- **Genre page.** Choose the first tile. Run `$V ad snapshot -i`, then `$V ad press @eN --settle` with the first `genre-` tile's ref. A page named after the genre lists its titles. The library's largest genre, Adventure, lists at least two `Zorro` titles.
- **Type a search.** Run `$V ad snapshot -i` for the search field's ref, then `$V ad fill @eN "zorro" --settle`. Results show, each with a `More for <title>` button, among them `More for The Mask of Zorro`. Run `$V shot search-zorro`.
- **Server match.** Search `zorro antonio`. To see the device's part and the server's part apart, slow the server's part: `OPENREEL_DEBUG_SEARCH_DELAY=4 $V relaunch`. `Searching…` shows while the server works; when it goes, `More for The Mask of Zorro` is listed and nothing listed before moved.
- **Scope.** Choose `Movies`. Run `$V ad press 'id="scope-Movies"' --settle`. The series `Zorro` (1990) is gone; the films stay. `id="scope-Live TV"` lists channels and what's on them.
- **No match.** Search `qqqzz`. After `Searching…` goes, `No Results` shows.
- **Open a result.** Choose a result. Run `$V ad press 'label="The Mask of Zorro"' --settle` or the result's ref. The title page opens with a `Play` button.

## Gotchas

- `-debugSearch <text>` at launch pre-fills the search. It is a test shortcut, not a user path: type into the field for proof.
- `Animals` is both films and a series named `Animals.` (with the period). Match the exact label you mean.
- Results arrive in two parts. Wait for `Searching…` to go before you assert on the full list or on `No Results`.
- The search field keeps the keyboard open. Press the next target directly; dismiss the keyboard only when it covers the target.

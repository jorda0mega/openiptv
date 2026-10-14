# UI audit against the Apple TV app

The goal (set 2026-10-12): make the iPhone, iPad and Apple TV apps look and
behave like the Apple TV app and other premium streaming apps, with no
flickers or jumps. Each item below has a UI test that fails without it.

## Method

- **REA** (rea-agents MCP 6.4): `open_binary` on `/System/Applications/TV.app`,
  then `observe_native_ui` on its window (evidence
  `ev_17f41052bc6b108d783230bec1d606d4448d98ef90b07ed24a2dcfb541aecaed`).
  REA could not read the window's accessibility tree ("ambiguous-window": no
  accessibility geometry for the TV app), so the measurements come from its
  exact window screenshot (1220 × 720 points).
- **Mobbin** screens of the iOS Apple TV app, measured on the image:
  [playing, portrait](https://mobbin.com/screens/aad496de-a296-423a-94e3-8847b224df4f),
  [Info, portrait](https://mobbin.com/screens/e8aa6469-7107-4664-a568-c7ef1a424ec6),
  [paused, landscape](https://mobbin.com/screens/e819ed3b-d87c-458f-b62f-91170591651f),
  [subtitles and speed, landscape](https://mobbin.com/screens/b7cf172d-ed89-411e-b13d-b95d85c0d04c),
  [subtitles menu, landscape](https://mobbin.com/screens/284596fd-0bd4-4ff6-8120-0ef16cfea74c).
- **Our app**: the UI tests' screenshots on the iPhone 17 Pro Max and iPad
  simulators and the Apple TV simulator, against the mock server.

## Round 5 (2026-10-13)

| Area | Apple TV app | Ours before | Change | Test |
|---|---|---|---|---|
| Home hero height (iPhone) | Mac app: hero ends at 558 of 720 pt (77.5%, REA); iOS about the same | 60% of the screen, then 71% (78% of the space above the tab bar) | 85% of the space above the tab bar: 78% of the screen, the first row's name still in view | `testHeroHeight` |
| Subtitles and audio button | Landscape: a small capsule over the bar's end with subtitles (speech bubble) and speed | "…" in a circle: nothing said it held the subtitles | The subtitles icon (`captions.bubble`) and a speed button in one glass capsule | `testPlayerLook`, `testPickedSubtitlesStay` |
| Playback speed | 0.5× to 2× from the gauge button | None | Menu "Playback Speed": 0.5×, 0.75×, 1×, 1.25×, 1.5×, 2× (pitch kept), for that playback | `testPlaybackSpeed` |
| Menus while playing | The controls stay while a menu is open | The controls hid after 4 s under an open menu, and the player closed with them (the menu's tap hook never fired) | Menus say they are opening through their button style (`MenuPress`) | `testSubtitlesMenuKeepsControls`, `testPlaybackSpeed` |
| Info panel (portrait) | The panel's text on near-black | Text on the picture dimmed to 30% | The picture dimmed to 18% under the panel | screenshot in `testPlayerLook` |
| Info for an episode | From Beginning and Go to Show side by side | From Beginning alone | Go to Show: the player closes on the show's page (opened on Home unless that page is under the player) | `testGoToShow` |
| Continue Watching in the player (iPhone) | A pill beside Info: the other titles as a list (landscape: a row of pictures); one tapped plays in the player | Info alone | The same pill and list, from Home's Continue Watching; the chosen title plays in the same player screen (a fresh player view, no flash of the page behind) | `testContinueWatchingInPlayer` |
| Speed on Apple TV | A speed button beside subtitles and audio | None | A third round button, its menu like the audio and subtitle menus | `testPlaybackSpeed` (tvOS) |
| Picture in Picture | The film moves into the window at once | A second stream had to start (5 s on a real server) | The same playback's frames go to the window | `testPictureInPicture` (its picture check runs on devices only: simulators draw this window black for every app) |

Test fixes found on the way: the test readouts sat over the play button (the
tests tapped its corner and hid the controls), the Live TV empty-state test
now runs only with the server stopped (`LIVE_EMPTY`), and the story test's
film has the same story in both of its copies.

## Earlier rounds (2026-10-12 and 13)

See the commits from `d1a424b` to `0bbcce9`: tracks chosen by language before
the first frame (English unless the film is Spanish), no flashes or jumps on
Home, search and pages, Home's recommendations changing only on pull to
refresh or after a long time away, the Apple TV search field and genre tiles,
Apple's card sizes, MORE under long stories, the mute button, landscape and
pause keeping the picture's size, smaller player buttons, and heroes ending in
their picture's colours.

## Kept different on purpose (the user's decisions)

- The show page is one list of every episode with season headers and a filter
  bar that pins on scroll.
- iPhone search results are a list, not poster columns.
- Specials come after the last season.

## Still open

- Picture in Picture's picture on a real device (the simulator can't show it).

## Not planned

- InSight (who is on screen, the song playing): Emby has no scene-by-scene
  cast or music data to show.
- Speed in Live TV: a live channel can't run ahead of itself.

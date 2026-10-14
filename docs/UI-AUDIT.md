# UI audit against the Apple TV app

The goal (set 2026-10-12): make the iPhone, iPad and Apple TV apps look and
behave like the Apple TV app and other premium streaming apps, with no
flickers or jumps. Each item below has a UI test that fails without it.

## Goal checklist (2026-10-13)

Each item of the goal, where it was done, and the test that checks it. All
these tests passed on 2026-10-13 against `77cf041` or later, and again on
2026-10-14 against `cf644b0`: 21 of 21 on the iPhone 17 Pro Max simulator
(`/tmp/openiptv/run-goal.sh`: 16 with the plain test film, 3 with a US
multi-track film, 1 with SDH subtitles, 1 with a Mexican film).

| Goal item | Commit | Test |
|---|---|---|
| Landscape: Home's hero filled the screen after a film played sideways | `219a4b5` | `HomeAfterLandscapeTests.testHeroSizeAfterLandscapePlayback` |
| The picture changed size when the controls showed (pause) | `82997d9` | `PlayerLookTests.testPlayerLook` (portrait and landscape, playing and paused) |
| Buttons too big | `6c6245a` (Apple's 44, 63, 92 points; the system style's padding removed), `db81d01` | `testPlayerButtonSizes` (all 7 player buttons, the Info pill, centres 117 apart), `testHomeCardSizes`, `testMyList` |
| Change the audio and subtitles; English unless Spanish-made | `79fe646`, `d1a424b`, `02dd23e`, `5a508f4` | `testPickedSubtitlesStay`, `testPickedSDHSubtitlesStay`, `testSubtitleSwitchKeepsPlaying` (US film), `testSpanishFilmStartsInSpanish` (Mexico) |
| No flickers or jumps (search, Continue Watching, pages) | `22016f2`, `b758bea`, `c896690` | `SearchStabilityTests` (4), `testPageReadyWhenPlayerCloses`, `testEpisodeRowsSameHeight`, `testMainButtonKeepsWidthWhileStarting` |
| Recommendations change only at moments (launch, pull, tab change, long away) | `22016f2` | `testHomeStaysPutUntilChosenAgainOrPulled`, `testHomeChangesOnlyAfterLongAway` |
| Audit against the Apple TV app (REA, Mobbin) | this file, rounds 1 to 5 | see the tables below |

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

## Round 6 (2026-10-13): other premium apps

Netflix and Max on Mobbin:
[Netflix player, landscape](https://mobbin.com/screens/f413f7a3-6534-414e-b62e-f25ba79e4f53),
[Netflix title page](https://mobbin.com/screens/f7087383-70ec-4e3a-85c7-a4e5428cdc25),
[Max title page](https://mobbin.com/screens/f48ed50d-049d-41fc-8a25-1c67f3e84910),
[Max episodes](https://mobbin.com/screens/feca44d6-72ba-45db-a800-c39feb506269).

| Area | Premium apps | Ours before | Change | Test |
|---|---|---|---|---|
| The next episode | The Apple TV app's Auto-Play "Play Next Episode" (on by default); its end screen is a post-play page (the next title's preview, logo, "+ Add", "Skip") | The player closed at an episode's end | At the end the next unwatched episode plays in the same player screen. A corner "Up Next" card was tried and removed: it wasn't Apple's design | `testNextEpisodeAtEnd` |
| Player actions | Netflix: labelled text buttons (Speed, Episodes, Audio & Subtitles, Next Ep.) | Apple TV app style icons | Kept the Apple TV app's style (the goal's first reference) | - |
| Title page | Netflix and Max: Episodes / More Like This / Extras tabs, a season menu | One list of every episode with season tabs | Kept (the user's decision) | - |

## Round 7 (2026-10-13): Apple TV design 1:1 (the user: no liberties)

Measured from a full-size Mobbin screenshot of the Apple TV app's Home
([Continue Watching](https://mobbin.com/screens/931b5699-9252-47cc-a9fb-324326addf72)), at 3x:

| Area | Apple TV app | Ours before | Change | Test |
|---|---|---|---|---|
| Continue Watching card | 240 × 170, 12-point corners, a hairline light edge; the picture runs to the bottom, about 35% darker there; on it "▶ ━ S1, E1 · 33m" (time left) and "•••"; no title (the picture carries it) | The title and the line on a frosted band with a hard top edge ("glossy border"), 14-point corners | Apple's: the fade, the edge, 12-point corners, "S1, E1 · 33m" (a film: "1h 2m"), "•••" (Go to Show / Details); the episode's name stays for VoiceOver | `testHomeCardSizes` |
| Subtitles in portrait | On the picture, at the picture's scale | Huge, under the picture, off the screen | Sized by the picture and kept on it | `testSubtitlesOnPictureInPortrait` |
| The player's Continue Watching, upright ([reference](https://mobbin.com/screens/9bd9cdbe-5b3a-4432-820e-5a0bc60d1442)) | 86 × 48 pictures (7-point corners), the title (17 pt) and "Continue · S1, E1" / "Next · S1, E2" (15 pt, grey), "•••" on each row, hairlines from the text | 96-point pictures, a bold 15-point title, the card's line, no "•••" | Apple's sizes, wording and "•••" (Go to Show / Details) | `testContinueWatchingInPlayer` |
| The same, sideways ([reference](https://mobbin.com/screens/e6bc47d3-1449-41d7-9645-fb6be489b8e0)) | No play controls while a panel is open; the pills, then 202 × 147 pictures, 20 apart, with "S1, E2 · 26m" and "•••" on them | Play controls beside the pills; small pictures with text under them | Apple's layout | `testContinueWatchingInLandscape` |
| Picture in Picture hand-over | The picture moves into the window without a stop | Sound and picture froze for a moment (two seeks: the decoder and the output switched) | The decoder stays: one seek left | `testPictureInPicture` (event log: one seek) |

Test fixes found on the way: the test readouts sat over the play button (the
tests tapped its corner and hid the controls), the Live TV empty-state test
now runs only with the server stopped (`LIVE_EMPTY`), and the story test's
film has the same story in both of its copies.

## Round 8 (2026-10-14): the open items with an Apple reference

Measured at 3x from Mobbin screenshots of the Apple TV app:
[Info, sideways](https://mobbin.com/screens/33bd5cb0-b8aa-4bc4-a789-ca1a6cf792da),
[a whole row](https://mobbin.com/screens/9de56288-8834-43a8-94c7-23c52b5aae0e),
[Home's row names](https://mobbin.com/screens/5bc9458e-30cc-437e-94b1-85588060b781).

| Area | Apple TV app | Ours before | Change | Test |
|---|---|---|---|---|
| Info, sideways | Under the pills: a 180 × 101 still, the text 20 to its right, the buttons stacked at the right (200 × 44, 8 apart), level with the still | No still; one full-width button under the text | Apple's layout (an episode's own still, a film's backdrop) | `testInfoAsInAppleTV` |
| Info text and buttons | Title 17 pt bold, story 15 pt, genre and time 13 pt semibold (both ways); buttons 44 high, 15-point words | Title 20 pt, story 17 pt, genre 15 pt; buttons 48 high, 17-point words | Apple's sizes | `testInfoAsInAppleTV` |
| Row names | A grey "›" (67% white, as tall as the capitals) after the name; a tap opens the whole row | Names opened nothing | The "›" and the whole row: the name, then three posters across (12 apart, 20 from the edges, lines 18 apart); iPad: as many as fit at about that size | `testRowNameOpensWholeRow` |
| The next episode on Apple TV | Auto-Play: the next episode plays at the end | The player closed at an episode's end (the iPhone played on) | The next episode plays in the same player, as on the iPhone | `RemoteFocusTests.testNextEpisodeAtEnd` |

## Earlier rounds (2026-10-12 and 13)

See the commits from `d1a424b` to `0bbcce9`: tracks chosen by language before
the first frame (English unless the film is Spanish), no flashes or jumps on
Home, search and pages, Home's recommendations changing only on pull to
refresh or after a long time away, the Apple TV search field and genre tiles,
Apple's card sizes, MORE under long stories, the mute button, landscape and
pause keeping the picture's size, smaller player buttons, and heroes ending in
their picture's colours.

## Delegated audit (Astra, code of 12 October 16:38)

Report: `/tmp/openiptv/astra-ui1/REPORT.md` (delivered 14 October). Status
in today's code:

| Finding | Status |
|---|---|
| Resume progress moved the title's buttons up 28 points | Fixed: the bar is drawn under the button without changing the layout |
| A show opened scrolled down to the next episode | Fixed: only for an episode route, and never after the viewer scrolls |
| Cold Home: Continue Watching landed, then moved below the hero | Fixed (`22016f2`: a hero-sized placeholder) |
| Search results moved about 104 points as suggestions changed | Fixed (`02a3dc3`, `testResultsStayPutWhenServerAnswers`) |
| Search went blank while pending | Fixed ("Searching…") |
| Apple TV rows moved vertically on a sideways focus move | Not checked again yet |
| Glass buttons larger than asked; the player unlike the reference | Fixed (`6c6245a`, `testPlayerButtonSizes`) |
| Apple TV hero hid the next row; dead cast buttons | Fixed |
| Settings grouped Infuse-style; poster-column search; Live copy | Not done: not the Apple TV app's design (the user: 1:1) |

## Delegated audit, round 2 (Astra, `54f31e5`, 12 October 17:53)

Report: `/tmp/openiptv/astra-ui2/REPORT.md`. Status in today's code:

| Finding | Status |
|---|---|
| Landscape Info pushed Close 66 points above the top | Layout replaced on 14 October (no play controls with a panel open, as in the Apple TV app); `testInfoInLandscapeKeepsClose` checks it |
| Remembered English subtitles over English audio came back Off | Fixed later (`testPickedSubtitlesStay`, US film) |
| Search blank while the server's part is pending | Fixed ("Searching…" over the list) |
| Continue Watching swapping a show's episode while Home is visible | Fixed: a card's identity includes its episode |
| An old account's slow Home after sign-out | Fixed (`testSignOutWhileHomeLoads`) |
| A Home built late waits for the next moment | By design: the user asked for changes only at moments (tab, pull, long away) |
| One paused rotation kept a portrait-sized picture once | Not reproduced since (`testPlayerLook` turns while paused) |
| Player times 11 → 13-15 pt; poster-column search; Apple TV shelf captions | Times are Apple's 11 pt (measured); search stays a list (the user); the Apple TV focused-poster caption exists (`d1a424b`) |

## Kept different on purpose (the user's decisions)

- The show page is one list of every episode with season headers and a filter
  bar that pins on scroll.
- iPhone search results are a list, not poster columns.
- Specials come after the last season.

## Still open

- Continue Watching's "›" (Apple's opens the whole list): no reference
  screenshot of that page found, so not added.
- The PiP hand-over's last seek (the video output switch): gone only if
  the picture is always drawn into the window's kind of layer (waits for
  the user's "try it" or "keep it as is").
- Apple's end-of-title post-play page (needs a reference for an episode).

- Skip Intro: Netflix and Max have it; no Apple TV app (iPhone) reference
  found, so not added. Emby marks intros as chapter markers (IntroStart,
  IntroEnd, CreditsStart) when its intro detection runs.
- An Episodes list inside the player (Netflix); ours has Continue Watching
  and Go to Show.

- Picture in Picture's picture on a real device (the simulator can't show it).

## Not planned

- InSight (who is on screen, the song playing): Emby has no scene-by-scene
  cast or music data to show.
- Speed in Live TV: a live channel can't run ahead of itself.

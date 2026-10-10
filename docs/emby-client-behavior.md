# Emby web client (4.10.1.0): artwork, request shaping, and live TV freshness

This spec describes how Emby's own web client (`system/dashboard-ui`, Emby Server 4.10.1.0) builds image URLs, chooses fallback artwork, sizes cards, shapes list requests, keeps live TV "now playing" current, and authenticates. It's written as a clean-room reference for our iOS, tvOS, Fire TV and web client. Behaviour is paraphrased; only endpoint paths, parameter names and field names are quoted.

**Evidence legend**
- **[O]** observed in client code (static read; nothing was executed).
- **[O-srv]** observed in strings inside server DLLs (API metadata), not in client code.
- **[I]** inferred: reasoned from names or usage, not proven.
- **[R]** fact surfaced or cross-checked with REA (see section 9).
- **Rec** is our recommendation for OpenIPTV. It is not Emby behaviour.

Paths are relative to `system/dashboard-ui/`. The shipped JS is single-line minified, so line numbers (`L123`) refer to prettier-formatted copies of those files (not included here). Formatting was the only change.

---

## 1. Image URL construction

### 1.1 URL shape [O]
`modules/emby-apiclient/apiclient.js`, functions `getImageUrl`, `normalizeImageOptions`, `getUrl`.

```
{server}/emby/Items/{itemId}/Images/{ImageType}[/{index}]?{params}
{server}/emby/Users/{userId}/Images/Primary?{params}          (user avatars: getUserImageUrl)
{server}/emby/Plugins/{pluginId}/Thumb?{params}                (plugin cards)
```
- `/emby` is added to the base address unless it already ends in `/emby` or `/mediabrowser` (`getUrl`).
- `index` goes in the path. Cards normally omit it; backdrops pass it (`Backdrop/0`, `/1`, ...). Chapter images use `Images/Chapter/{chapterIndex}`.
- Query params are serialized with `URLSearchParams`, and null or empty values are dropped (`modules/common/querystring.js`). Each call site builds the option object in its own order (for example `maxHeight`, `maxWidth`, `tag`, then `quality`). Treat order as irrelevant.
- **Image URLs carry no auth.** `getImageUrl` goes straight to `getUrl`. It never passes through `setAuthorizationInfoIntoRequest`, so there's no `api_key` and no `X-Emby-Token`. `<img>` tags fetch these URLs directly. [O] The server serving images anonymously is [I], since the web client depends on it.

**Example** (230 CSS-px portrait card at devicePixelRatio 2):
`/emby/Items/abc/Images/Primary?maxHeight=690&maxWidth=460&tag=<ImageTags.Primary>&quality=90`

### 1.2 Parameters the client actually sends [O]
| Param | When | Notes |
|---|---|---|
| `tag` | Always when known | The image tag from `ImageTags[type]`, `BackdropImageTags[i]`, `SeriesPrimaryImageTag`, and so on. It doubles as a cache-buster ([I]: the tag changes when the image changes). |
| `maxWidth` | Cards, lists, backdrops, detail pages | Card width in CSS px times the DPR (see 1.3). |
| `maxHeight` | Only for **Primary** images (and channel logos) | Set to `round(width / uiAspect)`, where `uiAspect` is the card shape's aspect, unless the caller opts out (`ignoreUIAspect`). Thumb, Backdrop, Banner and Logo get `maxWidth` only. |
| `width` / `height` | Rare | For example `height=40` for the channel logo in a card footer, and `width=1` or `12` for the "vibrant" colour sample. |
| `quality` | Always | Defaults to **90**, or **70 when type=Backdrop**, unless the caller sets it (`normalizeImageOptions`). |
| `blur` | Optional | Used for the blurred "vibrant" background sample (`blur=2`). |
| `keepAnimation` | Optional | Removed when false, so it's only sent when true. |
| `EnableImageEnhancers=false` | Detail-page hero image and Primary-as-backdrop | Turns off server-side enhancers (overlays) for big images. |

**Never sent by this client:** `fillWidth`/`fillHeight` (those are Jellyfin parameters and don't appear anywhere in this Emby build, client or server DLLs) and `format`. [O]
**Server-documented but unused by the web client:** the route `/Items/{Id}/Images/{Type}/{Index}/{Tag}/{Format}/{MaxWidth}/{MaxHeight}/{PercentPlayed}/{UnPlayedCount}`, plus request fields `CropWhitespace`, `BackgroundColor`, `ForegroundLayer`, `Blur`, `KeepAnimation`, `AddPlayedIndicator`, `Quality`. [O-srv, `Emby.Api.dll`]

### 1.3 Size selection [O]
| Context | Width rule | DPR | Code |
|---|---|---|---|
| **Grid/row cards** | The card builder measures a hidden "test card" for the current card class, window width and card-size setting, caches it in `cachedWidths`, and uses the `.cardScalable` width (fallback 400). If the window is narrower than the screen by more than 20 px (a resizable desktop window), the width is rounded **up to a multiple of 50** so resizing reuses the same URLs. | Multiplied by `devicePixelRatio` in `normalizeImageOptions`. On web the DPR is `appHost.getDevicePixelRatio()` or `window.devicePixelRatio` (`app.js`). | `modules/cardbuilder/cardbuilder.js` (`setListOptions` image-width block, L331-380) |
| **Poster/primary height** | `maxHeight = round(width / uiAspect)`, so the server returns art that fits the card box. | Same DPR multiply. | `modules/common/imagehelper.js` `getImageUrl` |
| **Page backdrop** (behind content) | `srcset` over the standard widths **480, 720, 1280, 1920, 2560, 3840** plus the window width rounded down to 100 (capped at 1920), with `sizes="100vw"`. The browser picks the size. | Off (`adjustForPixelRatio=false`); the browser handles density through `srcset`. | `modules/backdrop/backdrop.js` `getImageSources`; `ApiClient.getImageUrls`; `StandardWidths` |
| **Item detail hero** | `maxWidth = screen.availWidth`, `index=0`. | On. | `item/item.js` (hero image selection, L2690-2760) |
| **Card footer channel logo** | `height=40`. | On. | `cardbuilder.js` L1538 |
| **"Vibrant" placeholder colour** | The same image fetched at `width=1`, or `width=12&blur=2` for "large" mode, and used as a blurred or solid background behind the card. | Off. | `cardbuilder.js` L1465-1477 |

Backdrop `<img>` elements also get `fetchpriority="low"` [O] so they don't compete with posters.

**Rec:** Bucket requested widths (Emby rounds to 50 px on desktop; a fixed ladder per platform works better on TV), multiply by the screen scale, and always include `tag`. Send `quality=90`, or `70` for backdrops.

---

## 2. Fallback chain

### 2.1 Which object supplies the image [O]
`cardbuilder.js` (L1457-1478) and `listview.js` (L186-193):
1. Pick the image item. With `showCurrentProgramImage` (On Now channel cards), use `item.CurrentProgram`. For an `ActiveSession`, use `NowPlayingItem`. Otherwise use `item.ProgramInfo` (Timers and Recordings), and fall back to the item itself.
2. Run the chain below on that object. If it yields **no URL** and the image item wasn't the item itself, run the chain again on the outer item. For example, a channel card whose current program has no art falls back to the channel's own image.
3. If `item.ImageUrl` exists (remote or provider images, server-relative URLs normalised by `normalizeRemoteImagesInResult`), use it directly and skip the chain.
4. **Spoiler hiding:** if the user setting `hideEpisodeSpoilerInfo` is on and `UserData.Played === false`, an **Episode's own Primary is skipped**. A Chapter of such an episode skips its chapter image and switches to thumb preference.

### 2.2 Ordered chain (first match wins) [O]
`modules/common/imagehelper.js`, `getImageUrl`. `T` = `item.ImageTags`. "Inherit allowed" means `options.inheritThumb !== false`.

| # | Condition | Image requested (id / type / tag) | Assumed aspect |
|---|---|---|---|
| 1 | preferThumb **and** preferBackdrop, and `BackdropImageTags[0]` | own id / Backdrop / `BackdropImageTags[0]` | 16:9 |
| 2 | preferThumb and preferBackdrop, Episode, inherit allowed, `ParentBackdropImageTags[0]` | `ParentBackdropItemId` / Backdrop | 16:9 |
| 3 | preferThumb and `T.Thumb` | own / Thumb | 16:9 |
| 4 | (preferBanner or shape=banner) and `T.Banner` | own / Banner | 1000:185 |
| 5 | preferDisc and `T.Disc` | own / Disc | 1:1 |
| 6 | preferLogo and `T.Logo` | own / Logo | 16:9 |
| 7 | preferLogo and `ParentLogoImageTag` + `ParentLogoItemId` | parent / Logo | 16:9 |
| 8 | showChannelLogo and `ChannelPrimaryImageTag` + `ChannelId` | `ChannelId` / Primary | 16:9 |
| 9 | preferThumb, `ParentThumbItemId`, inherit allowed, not Photo | `ParentThumbItemId` / Thumb / `ParentThumbImageTag` | 16:9 |
| 10 | preferThumb and `BackdropImageTags[0]` | own / Backdrop | 16:9 |
| 11 | preferThumb, Episode, inherit allowed, `ParentBackdropImageTags[0]` | `ParentBackdropItemId` / Backdrop | 16:9 |
| 12 | preferSeriesImage and `SeriesPrimaryImageTag` | `SeriesId` / Primary | 2:3 |
| 13 | `T.Primary` (and not spoiler-hidden) | own / Primary, with `maxHeight` from the UI aspect. **TvChannel / ChannelManagementInfo:** the logo chain in 2.4 instead. | `PrimaryImageAspectRatio` |
| 14 | backdropAsSecondary and `ParentBackdropImageTags[0]` | parent / Backdrop | 16:9 |
| 15 | Plugin with `ImageTag` | `Plugins/{id}/Thumb` | 16:9 |
| 16 | `ImageTag` + `ChapterIndex` (chapter cards) | `ItemId` / Chapter / index | `PrimaryImageAspectRatio` |
| 17 | `PrimaryImageTag` (not spoiler-hidden) | `PrimaryImageItemId` or `Id` or `ItemId` / Primary (a `User` goes to `Users/{id}/Images/Primary`) | `PrimaryImageAspectRatio` |
| 18 | `AlbumId` + `AlbumPrimaryImageTag` | `AlbumId` / Primary | 1:1 |
| 19 | `ParentThumbItemId`, inherit allowed, **card aspect ≥ 1.4**, not Photo | parent / Thumb | 16:9 |
| 20 | `ParentPrimaryImageTag` | `ParentPrimaryImageItemId` / Primary | 2:3 if Episode, else 1:1 |
| 21 | `SeriesPrimaryImageTag` | `SeriesId` / Primary | 2:3 |
| 22 | Season and `T.Thumb` | own / Thumb | 16:9 |
| 23 | `ChannelPrimaryImageTag` + `ChannelId` | `ChannelId` / Primary | 16:9 |
| 24 | `BackdropImageTags[0]` | own / Backdrop | 16:9 |
| 25 | `T.Thumb` | own / Thumb | 16:9 |
| 26 | `ParentThumbItemId`, inherit allowed (any card shape) | parent / Thumb | 16:9 |
| 27 | `ParentBackdropImageTags[0]`, inherit allowed (any type) | parent / Backdrop | 16:9 |
| 28 | `PrimaryImageItemId` | that id / Primary, **no tag** | `PrimaryImageAspectRatio` |
| 29 | `UserPrimaryImageTag` (not an ActiveSession) | `Users/{UserId}/Images/Primary` | 1:1 |
| none | No URL | Default icon or text (2.5) | — |

### 2.3 Context presets (these drive which branches fire) [O]
`home/hometab.js` `fetchSections` (L287-321), `sectionscontroller.getSectionListOptions`, `listcontroller.getCardOptions`, `cardbuilder.setListOptions`:
| Context | preferThumb | inheritThumb | Other |
|---|---|---|---|
| Home **Continue Watching / Next Up / Active Recordings** | `true` (landscape cards) | allowed | |
| Home rows with server `ImageType=Primary` | null | — | `preferSeriesImage=true`, so episodes show the series poster |
| Other home rows (Latest, etc.) | `"auto"` | **false**, except for music and audiobooks | |
| Home **On Now** | auto | false | `showCurrentProgramImage=true`, `defaultShape=portrait` |
| Spotlight rows | true | — | `preferBackdrop=true`, `shape=backdrop`, `coverImage=true` |
| Library grid, "primary" view | unset | allowed | `shape=auto`; Next Up list uses `shape=backdrop` |
| Library grid, "thumb" / "banner" / "disc" / "logo" view | thumb: true | | `preferBanner` / `preferDisc` / `preferLogo`, with a fixed shape |
| Live TV suggestions and OSD channel lists | auto | **false** | `programsAsSeries` |
| Cast/crew (People, item page) | — | — | `shape=portrait`, `coverImage=true`. Person/MusicArtist cards become round only when the shape is square. |

`preferThumb="auto"` resolves after the shape is known: square gives null, backdrop or fourThree gives true, anything else gives false (`cardbuilder.js` L175-177).

### 2.4 TvChannel logo chain [O]
`ApiClient.getLogoImageUrl` and `skinmanager.getPreferredLogoImageTypes`. Branch 13 only applies when the channel has `ImageTags.Primary`. It then tries the theme's preferred logo types in order:
- **Dark themes:** `LogoLightColor`, `LogoLight`, `Logo` (from the themes' `theme.json`).
- **Default:** `Logo`.

Next it tries `ParentLogoImageTag`, and finally the channel `Primary`. Card fit for a channel is "contain" (letterboxed), except for backdrops (`imagehelper.getCoveredImageFit`).

### 2.5 When nothing resolves [O]
- The card gets the `defaultCardBackground` class plus an icon from `itemmanager.getDefaultIcon`. The icon is looked up by **CollectionType**, then **Type**, then **StreamType**, then **MediaType**, falling back to a generic icon (`baseitemcontroller.js` L796). If there's no icon, the display name is shown as text. Folders can render a CSS "folder" visual (`cardContent-emptyfolder`).
- **Load errors are not handled.** No `onerror` handler exists in cardbuilder, listview, itemscontainer, lazyloader, backdrop or the item page. A stale or 404 URL just shows an empty box; `alt=" "` suppresses the broken-image glyph. The fallback is decided **only from tags present in the JSON**.

### 2.6 Resolved order per item type (typical fields) [O for chain order; I for what the server populates]
Steps in brackets only fire under the stated condition. Context **A** = poster/auto card (preferThumb off). Context **B** = landscape thumb card (preferThumb on, inherit allowed). In context **C** (inheritThumb false), drop steps 2, 9, 11, 19, 26 and 27.

| Type | Fields consulted | A: poster / auto | B: thumb card (Continue Watching, Next Up) |
|---|---|---|---|
| **Movie / Series** | `ImageTags.Primary/Thumb/Banner/Logo/Disc`, `BackdropImageTags`, `PrimaryImageAspectRatio` | Primary, Backdrop[0], Thumb, icon | Thumb, Backdrop[0], Primary. Spotlight: Backdrop[0] first |
| **Season** | own Primary/Thumb, `SeriesPrimaryImageTag`+`SeriesId`, `ParentThumbItemId/ImageTag`, `ParentBackdropItemId/ImageTags`, (`ParentPrimaryImageTag`) | Primary, [ParentThumb if card ≥1.4], [ParentPrimary], **SeriesPrimary**, own Thumb, Backdrop, ParentThumb, ParentBackdrop | own Thumb, **ParentThumb (series)**, own Backdrop, own Primary, then as A |
| **Episode** | own Primary (the still), `SeriesPrimaryImageTag`+`SeriesId`, `ParentThumb*`, `ParentBackdrop*`, `ParentPrimaryImageTag`+`ParentPrimaryImageItemId`, `ParentLogo*` | own Primary (skipped when spoiler-hidden), [ParentThumb if card ≥1.4], ParentPrimary (2:3, season or series [I]), **SeriesPrimary**, own Backdrop, own Thumb, ParentThumb, ParentBackdrop | own Thumb, **ParentThumb (series thumb)**, own Backdrop, **ParentBackdrop (series)**, [SeriesPrimary if preferSeriesImage], own Primary (still), then as A. **On home "Continue Watching", the series Thumb or Backdrop wins over the episode still.** |
| **MusicAlbum** | Primary, `ParentPrimaryImageTag` (artist [I]), `ParentBackdrop*` | Primary, ParentPrimary, Backdrop, Thumb, ParentThumb, ParentBackdrop | (rarely thumb) |
| **Audio** | Primary, **`AlbumId`+`AlbumPrimaryImageTag`**, `ParentThumb*`, `ParentPrimary*`, `ParentBackdrop*` | own Primary, **AlbumPrimary**, [ParentThumb if card ≥1.4], ParentPrimary, ..., ParentBackdrop | |
| **Program** (EPG) | Primary/Thumb, `BackdropImageTags`, `SeriesPrimaryImageTag`, **`ChannelPrimaryImageTag`+`ChannelId`** | Primary, (SeriesPrimary), **ChannelPrimary**, Backdrop, Thumb | Thumb, Backdrop, Primary, ..., ChannelPrimary |
| **TvChannel** (On Now card) | `CurrentProgram.*` first, then channel `ImageTags` | Program chain on `CurrentProgram`; if empty, the channel: logo chain (2.4), Backdrop, Thumb | same |
| **Recording / Timer / SeriesTimer** | `ProgramInfo` (if present), then own fields | Program chain on `ProgramInfo`, then own Primary, ..., ChannelPrimary | |
| **Person** | `PrimaryImageTag`+`Id` (in `People[]`) or `ImageTags.Primary` | Primary, otherwise person icon. No inheritance. | |
| **Folders / CollectionFolder / BoxSet / Playlist** | Primary, Backdrop, Thumb, `PrimaryImageItemId` | Primary, Backdrop, Thumb, [ParentThumb/ParentBackdrop], PrimaryImageItemId (no tag), icon by CollectionType | |

Request-side note [O]: Live TV program queries add the field **`ChannelImageIfNoImage`** (`livetv/suggestions.js`, `sectionscontroller` "livetvtags"). By its name [I], it asks the server to substitute the channel image when a program has none.

**Rec (OpenIPTV):** Port the chain as a pure function, `resolveArtwork(item, ctx) -> [candidates]`, and return the **whole ordered candidate list**, not just the first. On load error, advance to the next candidate (Emby doesn't, which is how covers go blank). Only render the placeholder after the list is exhausted.

---

## 3. Aspect ratio and layout before images load [O]

`imagehelper.getShape`, `getPrimaryImageAspectRatio`, `getShapeFromAspect`, `getAspectFromShape`; `cardbuilder.setListOptions`; `card.css`.
1. **Per-list shape, computed once from the first batch of items.** For each item (or its `CurrentProgram`/`ProgramInfo`), take `PrimaryImageAspectRatio` (counted as 2:3 when `preferSeriesImage` and a series poster exists) and snap it to a bucket: **≥1.5556 → 16:9; ≥1.1333 → 4:3; ≥0.8333 → 1:1; else 2:3**. The list shape is the **most common bucket**.
2. Map the bucket to a shape: ≥3 banner, ≥1.4 backdrop, >1.2 fourThree, >0.73 square, else portrait.
3. If no item has the ratio, use the caller's `defaultShape`. Otherwise use the first item's type: Movie, SeriesTimer and Timer are **portrait**; Episode, Program and Video are **backdrop**; anything else is **square**.
4. Thumb or logo preference with auto shape forces backdrop. A side footer forces a square image.
5. The shape's aspect becomes `uiAspect`, which drives both the CSS box and `maxHeight`.
6. **CSS reserves the box before load.** `.cardPadder-{portrait|square|backdrop|fourThree|banner}` uses `aspect-ratio` of 2/3, 1, 16/9, 4/3 or 1000/185 with `contain: strict`. The legacy fallback is `padding-bottom` of 150%, 100%, 56.25%, 75% or 18.5%. Images are absolutely positioned inside, so the grid never reflows.
7. **Fit** (`imagehelper.getCoveredImageFit` + `card.css`): by default an image is **letterboxed** (`object-fit: contain`). If its assumed aspect is within ±0.28 of the card aspect, or the caller forces `coverImage`, the fit depends on type:
   - Logos and channel images (non-backdrop) stay **contain**.
   - Movie, Series, Episode, Season and MusicAlbum primaries are **stretched** to the box (`object-fit: fill`), unless `System/Info` reports `HasImageEnhancers=false`, in which case they're cropped.
   - BoxSet primaries stay contain.
   - Everything else, and all backdrops, is **cropped** (`object-fit: cover`).

   Because the tolerance is ±0.28, a 0.68 poster is silently stretched to 2:3 rather than letterboxed.

**Requirement this places on requests:** always ask for `Fields=PrimaryImageAspectRatio` on lists. For channel lists that show program art, also ask for `ProgramPrimaryImageAspectRatio` (fills the ratio on `CurrentProgram` [I]).

---

## 4. Request shaping for lists [O]

### 4.1 Common building blocks
- **Base `Fields`:** `BasicSyncInfo,CanDelete`, plus `CanDownload` where downloads are supported (`baseview.js` / `basetab.js` constructors). Lists then add **`PrimaryImageAspectRatio`**, and only add other fields when a visible column or text line needs them (`listcontroller.getBaseQuery` appends `ProductionYear,Status,EndDate`, `CommunityRating`, `OfficialRating`, `Genres`, `Overview`, `UserDataPlayCount`, ... only if displayed). Focus-preview mode (TV) adds `Overview,CommunityRating,CriticRating,OfficialRating,PremiereDate,ProductionYear,Container`.
- **Images:** `ImageTypeLimit=1` and `EnableImageTypes=Primary,Backdrop,Thumb`. `Logo` is added on home, spotlight and focus-preview views; `Banner`, `Disc` or `Logo` are added only for those library view types. Data-grid (table) views send neither.
- **`EnableUserData=false`** where watch state is irrelevant: On Now, EPG, OSD channel lists, item-page helper queries.
- **`EnableImages=false`** where no art is shown: EPG program blocks, series and season helper lookups in `item/item.js` (L489, L1423, L3194).
- **`EnableTotalRecordCount=false`** when no count or scrollbar size is needed: search, upcoming, guide programs, item-page helpers, playback queue building.
- **Paging (virtual lists):** `emby-itemscontainer.getVirtualChunkSize` sets `Limit` per chunk and `StartIndex` as the user scrolls. Horizontal rows use **12**, or **16** when the window is at least 2200 px wide. Vertical card grids use **50** (`cardbuilder.virtualChunkSize`). Lists and data grids use **30**. `TotalRecordCount` from the first response pre-sizes the scroll extent with placeholders. A refresh aborts in-flight requests for that container (AbortController per container).
- **Server-driven home (server ≥ 4.10.0.4):** each section gets a **random `RandomSeed`** once. It is re-sent on every page and refresh so random sections stay stable while paging (`ApiClient.getHomeScreenSectionItems`).

### 4.2 Endpoint table
| List | Endpoint | Key params |
|---|---|---|
| Home sections list | `GET Users/{uid}/HomeSections` | `displayMode=tv` or `mobile,desktop` |
| Home section items (4.10+) | `GET Users/{uid}/Sections/{sectionId}/Items` | `Fields=<base>,PrimaryImageAspectRatio,ProgramPrimaryImageAspectRatio,ProductionYear` (+`Status,EndDate` for TV/mixed, +`Genres,OfficialRating,Taglines` for spotlight, +`CommunityRating,CriticRating` for the top spotlight), `ImageTypeLimit=1`, `EnableImageTypes=Primary,Backdrop,Thumb,Logo`, `RandomSeed`, `Limit` = chunk (horizontal), **8** (spotlight), **16** (vertical section), **12** (when the whole home view scrolls horizontally), `StartIndex` (`home/hometab.js` `fetchSectionItems`) |
| Latest (legacy / library tabs) | `GET Users/{uid}/Items/Latest` | `ParentId`, `Limit` (default 24; rows capped 9-12), `GroupItems=true`, `Fields`, `ImageTypeLimit=1`, `EnableImageTypes` |
| Continue Watching | `GET Users/{uid}/Items/Resume` | `MediaTypes=Video` (or `Audio`), `Recursive=true`, `IncludeNextUp` (legacy), `Fields`, `ImageTypeLimit=1`, `EnableImageTypes`, `Limit` |
| Next Up | `GET Shows/NextUp` | `UserId`, `LegacyNextUp=true` (legacy path), `Fields`, `Limit` |
| Library grid | `GET Users/{uid}/Items` | `ParentId`, `IncludeItemTypes`, `Recursive`, `SortBy`/`SortOrder`, `Fields` (visible-column driven), `ImageTypeLimit=1`, `EnableImageTypes`, `StartIndex`/`Limit` (chunk 50) |
| Horizontal row caps (`sectionscontroller.fetchSectionItems`) | — | auto-thumb rows 12, thumb rows 9, music/audiobooks 9, default 10, spotlight 10 |
| Library spotlight hero | `GET Users/{uid}/Items` | `SortBy=Random`, `Limit=1`, **`ImageTypes=Backdrop`** (server returns only items that *have* a backdrop), `EnableImageTypes=Backdrop,Logo`, `Fields=Taglines`; refreshed every 30 s (`tv/suggestions.js`, `videos/moviesuggestions.js`) |
| User views | `GET Users/{uid}/Views` | Memoised promise (see 7) |

---

## 5. Live TV "now playing" freshness [O, timers cross-checked with R]

**Short answer: the web client never schedules a refresh at a program's `EndDate`.** It relies on:

| Mechanism | Where | Behaviour |
|---|---|---|
| **5-minute poll** | `data-refreshinterval=300000` on `list/list.js` for `type=Program/OnNow/TvChannel`, `videoosd/onnowtab.js`, `playqueuetab.js`. `RefreshInterval: 3e5` on every Live TV suggestions section (`livetv/suggestions.js`), the schedule page, and the legacy home "onnow" section (`apiclient.expandSectionBlock`). | `ItemsRefresher` schedules a single `setTimeout(refreshIntervalMs)` and re-arms it after each successful fetch. It **pauses when the view is hidden**. On resume it refetches immediately if the deadline passed while hidden, otherwise it re-arms for the remaining time (`modules/common/itemsrefresher.js` `resetRefreshInterval`, `onPause`, `onResume`). In 4.10 server-driven home, `RefreshInterval` comes from the server's section JSON (value not visible in the client). |
| **Lazy validity check in the player OSD** | `modules/playback/osdcontroller.js` `getDisplayItem` | When the OSD (re)binds or the player state changes (playback start, view resume, media-stream change, remote `statechange`), it checks whether the cached `CurrentProgram.EndDate` has passed. If so it refetches the channel with `GET Users/{uid}/Items/{channelId}?ExcludeFields=VideoChapters,VideoMediaSources,MediaStreams` and shows the new `CurrentProgram`. No timer drives this. |
| **Guide clock** | `modules/emby-elements/guide/guide.js` `startCurrentTimeUpdateInterval` | A `setInterval` every **40 s** moves the "now" line. If the user has been idle at least 60 s, it also scrolls the guide to now. Program data isn't refetched on this tick. |
| **Progress bars** | `modules/indicators/indicators.js` | `(now - StartDate) / (EndDate - StartDate)` is computed **at render**. It isn't animated, and updates only when the list refreshes. |
| **WebSocket** | `modules/common/input/api.js`; `itemsrefresher`; `guide.js`; `livetv/schedule.js` | Only DVR events are used: `TimerCreated`, `TimerCancelled`, `SeriesTimerCreated`, `SeriesTimerUpdated`, `SeriesTimerCancelled`, `RecordingStarted`, `RecordingEnded`, plus `LibraryChanged` and `UserDataChanged`. **No message handler exists for program or EPG changes.** |
| **Guide data** | `apiclient.getEpg`, `guide.loadPrograms` | `GET LiveTv/EPG` with `AddCurrentProgram=false`, `EnableUserData=false`, `EnableImageTypes=Primary`, `Fields=PrimaryImageAspectRatio`, **`Limit=25` channels per page**, `MinEndDate`/`MaxStartDate`, optional `ProgramFields=IsHD,Width`, `TagIds`, and `IsMovie/IsSports/IsKids/IsNews/IsSeries` category filters. Further 8-hour time blocks come from `GET LiveTv/Programs` with `channelIds=...`, `MinEndDate`, `MaxStartDate`, `SortBy=StartDate`, `EnableImages=false`, `EnableUserData=false`, `EnableTotalRecordCount=false`. The request switches to **POST with a JSON body when the `channelIds` string exceeds 1800 chars**. Blocks are cached in memory per `user|blockStart|channelIds` and cleared on guide refresh. Slots are 30 min. |
| **Channel lists with current program** | `apiclient.getLiveTvChannels`; `onnowtab.js`; `channelchanger.js` | `GET LiveTv/Channels` with `UserId`, `IsAiring=true` (On Now), `ImageTypeLimit=1`, `EnableImageTypes=Primary,Thumb,Backdrop`, `Fields=ProgramPrimaryImageAspectRatio,PrimaryImageAspectRatio`, `EnableUserData=false`, `SortBy=ChannelNumber,SortName`, plus the user's channel sorting. `CurrentProgram` comes back by default; the client sends **`AddCurrentProgram=false`** where it isn't needed (guide, channel changer, library tree). Generic `/Items` queries for TvChannel add `Fields=...,CurrentProgram`. |

[R] REA's timer inventory over the 24 relevant modules lists every `setTimeout`/`setInterval`: 40 s guide clock, 3 s refresh debounce, the variable `refreshIntervalMs`, 100-200 ms UI debounces, and a 2 s channel-changer OSD. None takes its delay from an `EndDate`.

**Rec (OpenIPTV, for Xtream live TV):** Keep Emby's two good ideas: pause polling while hidden and catch up on resume, and re-validate `EndDate` when a screen or OSD appears. Instead of a fixed 5-minute poll, schedule one timer for the **earliest `EndDate` among visible channels**, with 1-3 s of jitter. When it fires, fetch the next program for just those channels; fall back to a slow poll for safety. That keeps titles correct to the second without polling the whole list.

---

## 6. Authentication [O unless noted]

**What the web client does:** it sends **no `X-Emby-Authorization` header**. On every API request (`ApiClient.setAuthorizationInfoIntoRequest`) it appends these as **URL query parameters**:
`X-Emby-Client`, `X-Emby-Device-Name`, `X-Emby-Device-Id`, `X-Emby-Client-Version`, `X-Emby-Token` (once logged in), `X-Emby-Language`.
[I] Keeping GET requests free of custom headers avoids CORS preflights in the browser. The same reason likely explains why JSON POST bodies are sent as `text/plain` with `?reqformat=json` (`getFetchPromise`).

**Server-accepted header forms** [O-srv]:
- `Emby.Api.dll` documents the header as named either **`Authorization`** or **`X-Emby-Authorization`**, with this schema:
  `Emby UserId="<guid>", Client="<string>", Device="<string>", DeviceId="<string>", Version="<string>", Token="<string>"`
- `Emby.Server.Implementations.dll` lists these as allowed headers (CORS): `X-MediaBrowser-Token, X-Emby-Token, X-Emby-Client, X-Emby-Client-Version, X-Emby-Device-Id, X-Emby-Device-Name, X-Emby-Authorization`.

**Login** (`ApiClient.authenticateUserByName`):
- `POST {server}/emby/Users/authenticatebyname`, with the client and device query params above (no token yet).
- Body: **form-urlencoded** `Username=<name>&Pw=<password>`, sent with `Accept: application/json`.
- Response fields used: `User` (cached), `User.Id`, `AccessToken` (`connectionmanager.onAuthenticated`). The client then calls `System/Info`.
- Logout: `POST Sessions/Logout`.

**WebSocket:** `ws(s)://{host}/embywebsocket?api_key=<token>&deviceId=<deviceId>` (`openWebSocket`). Messages are JSON `{MessageType, Data, MessageId}`, and duplicate `MessageId`s are dropped. Subscriptions use `{Name}Start` messages with an interval string (for example `Sessions`, `0,1500`), and they're re-sent automatically after a reconnect.

**Rec (native):** Send `X-Emby-Authorization: Emby UserId="...", Client="OpenIPTV", Device="<model>", DeviceId="<stable uuid>", Version="<app ver>", Token="<token>"` (or `X-Emby-Token`) as headers. Keep `DeviceId` stable per install, because the server keys sessions on it. Image URLs need no token.

---

## 7. Other performance techniques [O]
- **Native lazy images:** `<img loading="lazy" decoding="async">`. Where native lazy loading is missing, cards render a `.lazy` div whose background image is suppressed by CSS until an IntersectionObserver with `rootMargin: 50%` removes the class (`modules/lazyloader/*`). Virtual lists (`lazy=2`) always emit a real `<img>` (still with `loading="lazy"` when supported); the virtual scroller only materialises cards near the viewport anyway.
- **Virtualised lists with element recycling** (`emby-itemscontainer`, `virtualScroller`, `onRecycleElement`). The list is sized from `TotalRecordCount` and data is fetched in chunks of 12/16, 30 or 50.
- **The card HTML template is built once per list** (`templateInnerHTML`) and the measured card width is cached per layout key (`cachedWidths`).
- **Placeholder colour:** a 1 px (or 12 px blurred) render of the same image. Tiny and cacheable, it gives a colour field while the full image loads.
- **Backdrops:** `srcset` plus `fetchpriority=low`.
- **Stale-while-revalidate user object:** `getUser` returns the cached user immediately. It revalidates in the background when the copy is older than 60 s and falls back to the cache when offline.
- **Memoised user views:** the `_userViewsPromise` is cleared on `LibraryChanged`, `UserUpdated`, `UserConfigurationUpdated` or `UserPolicyUpdated`.
- **Event-driven refresh with debounce** (`ItemsRefresher.notifyRefreshNeeded`): local or foreground events refresh immediately; background WebSocket events wait **3 s** so bursts coalesce. `UserDataChanged` patches the single item in place (played state, favourite) without refetching. `TimerCreated` patches `TimerId` on the matching program. Lists declare which events they care about (`Monitor`, for example `videoplayback`, `markplayed`, `RecordingStarted`).
- **Abortable requests everywhere:** an AbortController per view lifecycle and per list refresh, with a 30 s fetch timeout and automatic reconnect plus retry on network failure (`fetchWithFailover`).
- **Field minimisation:** fields are added only when a visible column or text line needs them. `EnableImages=false`, `EnableUserData=false` and `EnableTotalRecordCount=false` are used whenever possible.
- **No Service Worker image cache:** `serviceworker-app.js` only handles notifications and the app-version cache. Image caching is left to the HTTP cache, keyed by URL including `tag`.

---

## 8. Could not determine / open questions
1. **Server-driven home section definitions** (4.10): the actual `RefreshInterval`, `Monitor`, `ImageType` and `ViewType` values come from `GET Users/{uid}/HomeSections` at runtime. Only the legacy client-side defaults are visible (5 min for On Now).
2. **Image HTTP caching headers:** the server has Cache-Control, ETag and If-None-Match machinery [O-srv strings], but the policy for `/Images/*` (max-age, immutable) needs a live request to confirm.
3. **Whether `EnableImageTypes` also filters the `ImageTags` dictionary** or only the `Parent*`/`Series*` fields; and whether `LogoLightColor`/`LogoLight` tags come back when not requested. [I] To be safe, request every type you intend to use.
4. **Exact meaning of `ParentPrimaryImageItemId`** for Episodes (season or series), Audio and MusicAlbum (album or artist). It's server-defined; the client only assumes 2:3 for episodes.
5. **`ChannelImageIfNoImage` and `ProgramPrimaryImageAspectRatio` semantics:** inferred from names.
6. **Whether `maxWidth`+`maxHeight` is a bounding-box fit** that preserves aspect ratio [I]. Also which output format the server picks without `format` (WebP negotiation through `Accept`?).
7. **Whether the server pushes any program-change WebSocket message:** the client has no handler for one, which isn't proof the server never sends it.
8. **Anonymous image access:** the client never sends a token on image URLs. Whether a hardened server config can require one wasn't checked.
9. Nothing here covers **Xtream Codes**; this client only talks to Emby.

---

## 9. Method and tooling notes (REA vs grep)
- **Pretty-printing + grep did most of the work.** The 460 shipped files are single-line minified AMD modules. Copies of 447 app files (excluding vendored libraries) were formatted with prettier (formatting only, outside the target dir). Every finding above was then read directly.
- **REA `analyze-javascript-application` on the full tree** (2.5 min, 683 MB of evidence):
  - The structural graph had 1,514 `imports` edges, **all unresolved `require(...)` references**, mostly from webpack-bundled third-party code. REA didn't resolve the app's AMD `define([...deps])` lists, so it produced **no usable module graph** (for example, no importers of `imagehelper.js`; grep found 9).
  - Endpoint discovery found 493 values, mostly settings keys and routes. It found **no Emby API paths**, because those are built by string concatenation through `getUrl`.
  - The semantic graph hit its **100,000-node ceiling** after 68 of 460 modules, taken alphabetically. Two subtitle-renderer worker bundles alone used 40,000 nodes, so `imagehelper`, `cardbuilder` and `apiclient` were not covered.
- **REA on a 24-module subset** (10 s, full semantic coverage) helped in three ways:
  - (a) **Timer inventory** with literal delays. This confirmed there's no `EndDate`-driven timer (section 5).
  - (b) **Request inventory.** All HTTP goes through one `fetch` in `fetchhelper.js` and one `WebSocket` in `apiclient.js`, so there's a single choke point.
  - (c) **Property read-site index.** For example, `ParentThumbItemId` is read in `imagehelper`, `apiclient` (`getThumbImageUrl`) and `apiclientex`.
- **Where REA's semantic traces didn't help:** forward-influence traces on `_devicePixelRatio`, `ParentThumbItemId` and `PrimaryImageAspectRatio` returned "ambiguous" with **zero relations**. Receivers are untyped parameters, and cross-module calls go through `module.default.fn`. Event names weren't recovered either, because Emby uses its own `events.on(obj, name, fn)` helper.
- **Net:** REA was a useful cross-check and inventory tool once the input was narrowed. For this RequireJS/AMD, minified codebase, the answers came from grep plus reading the formatted code.

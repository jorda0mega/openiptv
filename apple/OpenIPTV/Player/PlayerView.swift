import AVFoundation
import SwiftUI

/// What the full-screen player shows.
enum PlayerItem: Identifiable {
    /// The channels to zap through, the one to play; for a game, which of
    /// its channels to start on (picked in its Watch On menu).
    case live([LiveChannel], Int, copy: LiveChannel? = nil)
    case vod(EmbyPlayback)

    var id: String {
        switch self {
        case let .live(channels, index, _): "live-\(channels[index].id)"
        case let .vod(playback): "vod-\(playback.itemId)"
        }
    }

    var isFilm: Bool {
        switch self {
        case .vod: true
        case .live: false
        }
    }
}

struct PlayerScreen: View {
    @Environment(Preferences.self) private var prefs
    let item: PlayerItem
    /// Takes the player away, with no motion of its own (see RootView).
    var remove: () -> Void = {}
    @State private var shown = false

    var body: some View {
        Group {
            switch item {
            case let .live(channels, index, copy): LivePlayerView(channels: channels, index: index, startCopy: copy)
            case let .vod(playback): VODPlayerHost(playback: playback)
            }
        }
        // In and out with the same quick fade, as in the TV app (it slid up
        // for 0.6 s, and went in one frame).
        .opacity(shown ? 1 : 0)
        .onAppear { withAnimation(.easeOut(duration: 0.25)) { shown = true } }
        .environment(\.closePlayer, ClosePlayer {
            withAnimation(.easeIn(duration: 0.2)) { shown = false }
            Task {
                try? await Task.sleep(for: .milliseconds(200))
                remove()
            }
        })
        .presentationBackground(.clear)
        #if os(iOS)
        .onAppear { PlayerOrientation.shared.playerAppeared(film: item.isFilm) }
        .onDisappear { PlayerOrientation.shared.playerDisappeared() }
        #endif
    }
}

/// A film or episode, and then any title chosen from Continue Watching in
/// the player: the player screen stays up while the title changes, with a
/// fresh player view for each.
private struct VODPlayerHost: View {
    @State var playback: EmbyPlayback

    var body: some View {
        MoviePlayerView(playback: playback, switchTo: { playback = $0 })
            .id(playback.itemId)
    }
}

/// Playback speeds, as in the Apple TV app: half to double.
enum PlaybackSpeed {
    static let all: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    /// "1×", "1.25×", "0.5×".
    static func name(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}

#if os(iOS)
/// The player's subtitles button: the audio and subtitle tracks, ticked
/// where they are. Its own view, drawn again only when the tracks change: drawn again with
/// the player (several times a second while the film plays), an open menu
/// closed at once, so subtitles could only be changed with the film paused.
struct TrackMenuButton: View, Equatable {
    let tracks: [Track]
    /// Languages only another copy of the title is heard in ("ja").
    var otherLanguages: [String] = []
    let pick: (Track) -> Void
    var pickOther: (String) -> Void = { _ in }
    let pickSubtitles: (Track?) -> Void
    let opened: () -> Void

    static func == (a: Self, b: Self) -> Bool { a.tracks == b.tracks && a.otherLanguages == b.otherLanguages }

    var body: some View {
        let audio = tracks.filter { $0.kind == .audio }
        let subtitles = tracks.filter { $0.kind == .subtitle }
        Menu {
            if audio.count + otherLanguages.count > 1 {
                Section("Audio") {
                    ForEach(audio) { track in
                        Button { pick(track) } label: { item(track) }
                            .accessibilityIdentifier(track.selected ? "audio-playing" : "audio-track")
                    }
                    // Picked, that copy plays from here.
                    ForEach(otherLanguages, id: \.self) { code in
                        Button(MoviePlayerView.languageName(code)) { pickOther(code) }
                            .accessibilityIdentifier("audio-other-copy")
                    }
                }
            }
            Section("Subtitles") {
                Button { pickSubtitles(nil) } label: {
                    if subtitles.contains(where: \.selected) { Text("Off") } else { Label("Off", systemImage: "checkmark") }
                }
                ForEach(subtitles) { track in
                    Button { pickSubtitles(track) } label: { item(track) }
                }
            }
        } label: {
            // The subtitles icon, as in the Apple TV app ("…" hid what it
            // was for).
            Image(systemName: "captions.bubble")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(MenuPress(pressed: opened))
        // Audio, then Subtitles from Off, as written: opened from the
        // bottom, iOS would turn the list upside down.
        .menuOrder(.fixed)
        .accessibilityLabel("Audio and Subtitles")
    }

    @ViewBuilder private func item(_ track: Track) -> some View {
        if track.selected {
            Label(MoviePlayerView.label(track), systemImage: "checkmark")
        } else {
            Text(MoviePlayerView.label(track))
        }
    }
}

/// A menu's look when pressed, and word that it's opening: a menu has no
/// "opened" of its own, and a tap gesture on one never fired, so the
/// controls hid with the menu open (and the player closed with them).
struct MenuPress: ButtonStyle {
    let pressed: () -> Void

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .onChange(of: configuration.isPressed) { _, down in if down { pressed() } }
    }
}

/// The playback speed, ticked where it is. Its own view for the same
/// reason as the subtitles button.
struct SpeedMenuButton: View, Equatable {
    let speed: Double
    let pick: (Double) -> Void
    let opened: () -> Void

    static func == (a: Self, b: Self) -> Bool { a.speed == b.speed }

    var body: some View {
        Menu {
            Section("Playback Speed") {
                ForEach(PlaybackSpeed.all, id: \.self) { value in
                    Button { pick(value) } label: {
                        let name = PlaybackSpeed.name(value)
                        if value == speed { Label(name, systemImage: "checkmark") } else { Text(name) }
                    }
                }
            }
        } label: {
            Image(systemName: "gauge.with.dots.needle.67percent")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(MenuPress(pressed: opened))
        .menuOrder(.fixed)
        .accessibilityLabel("Playback Speed")
        .accessibilityValue(PlaybackSpeed.name(speed))
    }
}
#endif

/// Closes the player with its fade (the screens inside call this rather
/// than dismiss).
struct ClosePlayer {
    let run: () -> Void
    func callAsFunction() { run() }
}

extension EnvironmentValues {
    @Entry var closePlayer: ClosePlayer?
}

struct VideoSurface: UIViewRepresentable {
    let player: MPVPlayer
    func makeUIView(context: Context) -> MPVHostView { MPVHostView(player: player) }
    func updateUIView(_ view: MPVHostView, context: Context) {}
}

@MainActor
func makePlayer(prefs: Preferences) -> MPVPlayer {
    PlaybackAudio.activate()
    return MPVPlayer(options: prefs.playerProfile.mpvOptions, hardwareDecoding: prefs.hardwareDecoding)
}

/// The audio session set up for films, off the main thread: activating it
/// can take a moment, and the player's screen is opening meanwhile.
enum PlaybackAudio {
    private static let queue = DispatchQueue(label: "openiptv.audio-session", qos: .userInitiated)

    static func activate() {
        queue.async {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
        }
    }
}

// MARK: - Emby movies and episodes

/// Plays an Emby item from its resume point and reports progress back so
/// Continue Watching stays right on every device. iPhone: glass transport
/// controls and a scrubber. Apple TV: the Siri Remote as in Apple's own
/// player (see `remote(_:)`).
struct MoviePlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    @Environment(\.dismiss) private var dismiss
    @Environment(\.closePlayer) private var closePlayer

    let playback: EmbyPlayback
    /// Plays another title in this player screen (Continue Watching).
    var switchTo: ((EmbyPlayback) -> Void)? = nil
    @State private var player: MPVPlayer?
    /// The position and the point being chosen (see PlayerClock): the
    /// handlers read and set them here; the views that show them read the
    /// clock themselves.
    @State private var playClock = PlayerClock()
    private var position: Double {
        get { playClock.position }
        nonmutating set { playClock.position = newValue }
    }
    @State private var duration: Double?
    @State private var paused = false
    @State private var started = false
    @State private var buffering = false
    @State private var error: String?
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var lastReport: Double = 0
    private var scrubbing: Double? {
        get { playClock.scrubbing }
        nonmutating set { playClock.scrubbing = newValue }
    }
    /// How many fallback streams have been tried after the first failed.
    @State private var attempt = 0
    @State private var stream: FilmStream = .whole
    @State private var convertedOpen: Task<Void, Never>?
    private var offset: Double { stream.clockStart }
    /// "Started in …" for a few seconds after the first frame (development
    /// builds with the stats on).
    @State private var timing: String?
    @State private var warmStart = false
    @State private var track = LoadTrack(began: Date(), stage: .fetching)
    /// The file's audio and subtitle tracks, and the picture's badges ("4K",
    /// "HDR") for the Info panel.
    @State private var tracks: [Track] = []
    @State private var badges: [String] = []
    /// The title being started in this player screen (the next episode, or
    /// one from Continue Watching).
    @State private var switching: String?
    /// This player, to ScreenAwake.
    @State private var awakeID = UUID()
    /// An episode: its season's episodes, for the player's Episodes list
    /// (as on the show's page).
    @State private var seasonEpisodes: [EmbyItem] = []
    #if os(iOS)
    /// The Info panel, and the picture filling the screen (cropped) rather
    /// than fitting it.
    @State private var showInfo = false
    /// The player's Continue Watching open.
    @State private var showContinue = false
    /// The Episodes list open.
    @State private var showEpisodes = false
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSize
    /// Sideways on iPhone.
    private var compactHeight: Bool { verticalSize == .compact }
    #endif
    @State private var filled = false
    @State private var muted = false
    /// The film went on in Picture in Picture: closing here isn't stopping.
    @State private var handedOff = false
    #endif
    #if os(tvOS)
    /// Where the current swipe started from.
    @State private var swipeFrom: Double?
    /// Buttons moved along by the current swipe (on the round buttons).
    @State private var buttonSwipeSteps = 0
    /// Rewinding or fast-forwarding while left or right is held, and which
    /// way (+1 forward, −1 back).
    @State private var holdTask: Task<Void, Never>?
    @State private var holdDirection: Double?
    /// The bar alone, as in Apple's player while playing or just after a
    /// jump; paused, the title, buttons and Info tab too.
    @State private var compact = true
    /// The Info panel or a track menu, and what the remote is on.
    @State private var panel: TVPlayerPanel?
    @State private var focus: TVPlayerFocus = .bar
    /// The latest track-menu request: an older one finishing late (the
    /// player busy) doesn't open its menu.
    @State private var menuRequest = 0
    #endif
    /// iPhone scrubbing: speed label, and live seeks so the picture follows.
    @State private var scrubSpeed: String?
    @State private var resumeAfterScrub = false
    /// Where the current scrub started, for "+1:30" / "−0:45".
    @State private var scrubOrigin: Double?
    /// Exact-frame seek once the finger rests.
    @State private var settleSeek: Task<Void, Never>?
    /// Testing the connection while a converted version plays.
    @State private var probeTask: Task<Void, Never>?
    @State private var thumbnailTask: Task<Void, Never>?
    /// The next episode got ready (near the end of this one).
    @State private var preparedNext = false
    /// That episode, played at the end (as the Apple TV app's "Play Next
    /// Episode" does).
    @State private var upNext: EmbyItem?
    /// The film's preview thumbnails, when the server has them, and where
    /// the last preview the player has on screen is (its seconds).
    @State private var thumbnails: PreviewThumbnails?
    @State private var previewShown: Double?
    /// Just after a jump the player still reports where it was for a
    /// moment: until it lands (or this time passes), the bar stays put.
    @State private var jumpUntil: Date?
    /// The last jump: the player waits for data after one, which isn't the
    /// connection stalling.
    @State private var lastSeek = Date.distantPast
    /// Picks original vs a server-converted lower bitrate to avoid stalls.
    @State private var governor: QualityGovernor?
    @State private var temporaryMessage: String?
    /// The converted bitrate playing before a switch back to the original,
    /// to return to if the original won't open.
    @State private var revertTo: Int?
    @State private var lastConverted: Int?
    /// The first start has been reported (later starts are quality switches).
    @State private var startedOnce = false
    /// Where the player was when it was closed (already on the page behind).
    @State private var closedAt: Double?
    /// Playback speed (1: normal), for this playback only.
    @State private var speed = 1.0
    #if DEBUG
    /// Debug builds: current quality, measured speed and buffer.
    @State private var stats = ""
    /// Debug builds: the tracks playing, for UI tests ("audio=eng subtitles=off").
    @State private var trackReadout = ""
    /// Debug builds: "original" or "converted 4.0 Mbps", for UI tests.
    @State private var qualityReadout = "original"
    /// Debug builds: "72.4 playing" (the player's second, and whether it
    /// plays), for UI tests.
    /// Reads back into the film so far (see StreamRelay.readsBack).
    @State private var relayReadout = ""
    /// Debug builds: how it started ("warm 0.3": a player kept or opened
    /// ahead; "cold 2.1": opened on the tap), and where.
    @State private var startReadout = ""
    @State private var startParts = ""
    @State private var convertedReadout = ""
    #endif

    var body: some View {
        #if DEBUG
        let _ = PlayerRenders.note()
        #endif
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoSurface(player: player)
                    .ignoresSafeArea()
                    #if os(iOS)
                    .gesture(MagnifyGesture().onEnded { pinch in
                        if pinch.magnification > 1.08, !filled { setFilled(true) }
                        if pinch.magnification < 0.92, filled { setFilled(false) }
                    })
                    #endif
                    .accessibilityElement()
                    .accessibilityLabel(playback.title)
                    .accessibilityHint("Shows the player controls")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { showControls() }
                    .accessibilityAction(.escape) { close() }
            }
            // Choosing where to jump: the still for that moment, full-screen,
            // until the player has the frame itself.
            StillWhileChoosing(clock: playClock, thumbnails: thumbnails, previewShown: previewShown, offset: offset)
            #if os(iOS)
            // Taps on the picture show and hide the controls (a tap on the
            // Info panel's background closes it first). Under the controls:
            // a tap on one of them, the "…" menu too, isn't also one on the
            // picture (that hid the controls, and the menu with them).
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture {
                    if showInfo { toggleInfo() } else if showContinue { toggleContinue() } else if showEpisodes { toggleEpisodes() } else { toggleControls() }
                }
                .gesture(DragGesture(minimumDistance: 30).onEnded { drag in
                    guard !showInfo, !showContinue, !showEpisodes, scrubbing == nil,
                          let swipe = PlayerFacing.swipe(dx: drag.translation.width, dy: drag.translation.height) else { return }
                    PlayerOrientation.shared.swiped(swipe)
                }, isEnabled: UIDevice.current.userInterfaceIdiom == .phone)
                .accessibilityHidden(true)
            #endif
            // With the controls up, their play button turns into the progress.
            if let load, !controlsVisible {
                LoadProgressView(load: load, actions: loadActions, overPicture: true)
            }
            if controlsVisible { controls.transition(.opacity) }
            #if os(iOS)
            DuringIntro(clock: playClock, intro: playback.intro, allowed: skipIntroAllowed) {
                skipIntroButton.transition(.opacity)
            }
            #else
            DuringIntro(clock: playClock, intro: playback.intro, allowed: skipIntroAllowed) {
                // Apple TV: the one thing a click does meanwhile, so it
                // looks focused, as Apple's does.
                Text("Skip Intro")
                    .font(.system(size: 29, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 36)
                    .frame(height: 66)
                    .background(.white, in: .capsule)
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 90)
                    .padding(.bottom, controlsVisible ? 200 : 70)
                    .transition(.opacity)
                    .accessibilityIdentifier("Skip Intro")
            }
            #endif
            if let temporaryMessage, !controlsVisible {
                Text(temporaryMessage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .padding(.top, 12)
                    .transition(.opacity)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("player-note")
            }
            #if DEBUG
            // Readouts for the UI tests, one point each in a corner: over the
            // play button, the tests tapped its corner instead, outside the
            // circle, and hid the controls.
            ZStack {
                debugReadout(trackReadout, "debug-tracks")
                debugReadout(qualityReadout, "debug-quality")
                ClockReadout(clock: playClock)
                debugReadout(startReadout, "debug-start")
                debugReadout(startParts, "debug-start-parts")
                debugReadout(error ?? "", "debug-start-error")
                debugReadout(convertedReadout, "debug-converted")
                debugReadout(relayReadout, "debug-reads-back")
                debugReadout(playback.itemId, "debug-item")
                debugReadout(String(keyedAddresses), "debug-keyed")
                PlayerRenders.Readout()
                // Not the player's own state: read again every half second
                // (the player isn't drawn again for the clock any more).
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    ZStack {
                        debugReadout(String(player?.pictureReturnsFromAway ?? 0), "debug-away")
                        debugReadout(player?.hlsKeys ?? "", "debug-hls-keys")
                        debugReadout(UIApplication.shared.isIdleTimerDisabled ? "awake" : "idle", "debug-awake")
                        debugReadout(player?.stopwatch.readout ?? "", "debug-subs-timing")
                        debugReadout(player?.bufferingReadout ?? "", "debug-buffering")
                        debugReadout(StreamRelay.shared.startReadsReadout, "debug-relay")
                        #if os(iOS)
                        debugReadout(player?.subtitleShift ?? "", "debug-subshift")
                        debugReadout(player?.subtitleLine ?? "", "debug-subtext")
                        debugReadout(redirectsReadout, "debug-redirects")
                        debugReadout(model.debugCopySwitch, "debug-copy-switch")
                        #endif
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .ignoresSafeArea()
            .allowsHitTesting(false)
            #endif
            #if os(tvOS)
            // On top and see-through: it takes the remote.
            TVRemoteSurface { remote($0) }
                .ignoresSafeArea()
            #endif
        }
        #if os(tvOS)
        .onExitCommand { remote(.menu) }
        #endif
        #if os(iOS)
        .statusBarHidden(!controlsVisible)
        #endif
        .persistentSystemOverlays(.hidden)
        .task {
            start()
            await watchTheOpen()
        }
        .task(id: load?.deadline) { await endWait(at: load?.deadline) }
        .task(id: playback.itemId) { await loadSeason() }
        .onAppear {
            PlaybackActivity.began()
            model.playerShown = true
            // What was fetched ahead for other titles stops (and none starts
            // while this plays): it has the connection to itself.
            StreamRelay.shared.stopAhead(keeping: playback.url)
            #if DEBUG
            model.debugPlayerUp = true
            #endif
        }
        .onDisappear {
            PlaybackActivity.ended()
            model.playerShown = false
            ScreenAwake.set(awakeID, playing: false)
            #if DEBUG
            model.debugPlayerUp = false
            #endif
            finish()
        }
    }

    /// Minimal, like the streaming apps (see PlayerChrome): the episode and
    /// show at the bottom over one bar with the times and rotate. Apple TV:
    /// Apple's own player's look (see TVMovieOverlay).
    private var controls: some View {
        #if os(tvOS)
        // A film: its title alone over the bar, and in Info its name with
        // the year and length under it (it showed the year as the heading);
        // an episode: "S1:E3 · Name" over the show, and as Info's heading.
        let film = playback.seriesId == nil
        return TVMovieOverlay(caption: film ? nil : playback.subtitle, title: playback.title, note: note,
                       load: load, loadActions: loadActions, bar: TVClockedBar(clock: playClock, total: total, holdDirection: holdDirection, paused: paused), compact: compact,
                       panel: panel, focus: focus, hasSubtitles: tracks.contains { $0.kind == .subtitle },
                       info: TVPlayerInfo(heading: film ? playback.title : playback.subtitle, overview: playback.overview,
                                          runtime: film ? [playback.subtitle, runtime].compactMap(\.self).joined(separator: " · ") : runtime,
                                          badges: badges),
                       menu: menu,
                       episodes: seasonEpisodes.count > 1 ? seasonEpisodes.map { episode in
                           TVPlayerEpisode(id: episode.id, title: episodeTitle(episode), line: episodeStatus(episode),
                                           images: model.emby?.card(for: episode, landscape: true, width: 320).images ?? [])
                       } : [])
        #else
        // A film shows its title alone, as in the Apple TV app; an episode
        // its "S1:E3 · Name" over the show.
        PlayerChrome(caption: playback.seriesId == nil ? nil : playback.subtitle, title: playback.title, note: note,
                     paused: paused, load: load, loadActions: loadActions, ready: started,
                     topActions: pictureActions, pills: pills,
                     selectedPill: showInfo ? "Info" : showEpisodes ? "Episodes" : showContinue ? "Continue Watching" : nil,
                     panel: showInfo ? infoPanel : showEpisodes ? episodesPanel : showContinue ? continuePanel : nil,
                     muted: muted, toggleMute: {
                         muted.toggle()
                         player?.setMuted(muted)
                         showControls()
                     },
                     close: { close() }, back: { skip(-10) },
                     playPause: {
                         // The button changes at once; the player confirms.
                         paused.toggle()
                         player?.togglePause()
                     }, forward: { skip(10) }) {
            trackMenu
        } accessory: {
            EmptyView()
        } bar: {
            scrubber
        }
        #endif
    }

    #if os(iOS)
    /// The Info panel, as in the Apple TV app: the title, its story, genre
    /// and running time, and From Beginning.
    private var infoPanel: PlayerInfoPanel {
        let genre = playback.seriesId == nil ? playback.subtitle?.components(separatedBy: " · ").last : playback.subtitle
        let meta = [genre, runtime].compactMap(\.self).filter { !$0.isEmpty }
        var actions = [PlayerAction(title: "From Beginning", systemImage: "play.fill") {
            restart()
            toggleInfo()
        }]
        // An episode: its show's page, as in the Apple TV app.
        if let show = playback.seriesId {
            actions.append(PlayerAction(title: "Go to Show", systemImage: "info.circle") {
                model.showRequest = ShowRoute(id: show, title: playback.title, episodeId: playback.itemId)
                close()
            })
        }
        return PlayerInfoPanel(title: playback.title, overview: playback.overview, meta: meta.joined(separator: " · "),
                               badges: badges, actions: actions, images: playback.stills)
    }

    /// Info, and Continue Watching when it has other titles, as in the
    /// Apple TV app.
    private var pills: [PlayerAction] {
        var pills = [PlayerAction(title: "Info") { toggleInfo() }]
        if seasonEpisodes.count > 1 { pills.append(PlayerAction(title: "Episodes") { toggleEpisodes() }) }
        if !otherTitles.isEmpty { pills.append(PlayerAction(title: "Continue Watching") { toggleContinue() }) }
        return pills
    }

    /// Home's Continue Watching, but this title.
    private var otherTitles: [Card] {
        guard switchTo != nil else { return [] }
        let row = model.rows.first { $0.title == "Continue Watching" }?.cards ?? []
        return row.filter { $0.id != playback.itemId && $0.episodeId != playback.itemId && $0.id != playback.seriesId }
    }

    /// As in the Apple TV app: "Continue · S1, E1" for an episode under
    /// way, "Next · S1, E2" for the next one, "Continue" for a film; "•••"
    /// for the title's page (the player closes over it).
    private var continuePanel: PlayerInfoPanel {
        PlayerInfoPanel(title: "Continue Watching", meta: "", cards: otherTitles.map { card in
            let code = card.episodeId == nil ? nil : card.subtitle?.components(separatedBy: " · ").first
            let status = (card.progress ?? 0) > 0 || card.episodeId == nil ? "Continue" : "Next"
            let page = card.kind == "Series"
                ? PlayerAction(title: "Go to Show", systemImage: "info.circle") {
                    model.showRequest = ShowRoute(id: card.id, title: card.title, episodeId: card.episodeId)
                    close()
                }
                : PlayerAction(title: "Details", systemImage: "info.circle") {
                    model.movieRequest = MovieRoute(id: card.id, title: card.title)
                    close()
                }
            return PlayerCard(id: card.id, title: card.title, subtitle: [status, code].compactMap(\.self).joined(separator: " · "),
                              images: card.images, loading: switching == card.id, spoken: card.episodeName,
                              line: card.subtitle, more: [page]) { playInstead(card) }
        })
    }

    private func toggleContinue() {
        withAnimation(.snappy(duration: 0.3 * PlayerMotion.scale)) {
            showInfo = false
            showEpisodes = false
            showContinue.toggle()
        }
        // Open: the controls stay until it's closed.
        showControls(autoHide: !showContinue)
    }

    /// Another title from Continue Watching, in this player screen: this
    /// one's stop goes on the pages behind first (as on closing), then a
    /// fresh player view takes the new one.
    private func playInstead(_ card: Card) {
        guard let switchTo, switching == nil else { return }
        switching = card.id
        Task {
            defer { switching = nil }
            do {
                let next = if let episode = card.episodeId {
                    try await model.playback(itemId: episode, kind: "Episode")
                } else {
                    try await model.playback(itemId: card.id, kind: card.kind)
                }
                if closedAt == nil {
                    closedAt = position
                    var quiet = Transaction(animation: nil)
                    quiet.disablesAnimations = true
                    withTransaction(quiet) { model.noteStop(playback, seconds: position) }
                }
                switchTo(next)
            } catch {
                note("Couldn't play \(card.title)")
            }
        }
    }

    private func toggleInfo() {
        withAnimation(.snappy(duration: 0.3 * PlayerMotion.scale)) {
            showContinue = false
            showEpisodes = false
            showInfo.toggle()
        }
        // Open: the controls stay until it's closed.
        showControls(autoHide: !showInfo)
    }

    private func toggleEpisodes() {
        withAnimation(.snappy(duration: 0.3 * PlayerMotion.scale)) {
            showInfo = false
            showContinue = false
            showEpisodes.toggle()
        }
        showControls(autoHide: !showEpisodes)
    }

    /// The season's episodes: "3. Case 3", "Playing" for this one, how far
    /// one under way is, else its length. A tap plays it in this player.
    private var episodesPanel: PlayerInfoPanel {
        PlayerInfoPanel(title: "Episodes", meta: "", cards: seasonEpisodes.map { episode in
            let playing = episode.id == playback.itemId
            let code = [episode.parentIndexNumber.map { "S\($0)" }, episode.indexNumber.map { "E\($0)" }]
                .compactMap(\.self).joined(separator: ", ")
            return PlayerCard(id: episode.id, title: episodeTitle(episode), subtitle: episodeStatus(episode),
                              images: model.emby?.card(for: episode, landscape: true, width: 180).images ?? [],
                              loading: switching == episode.id,
                              line: [code, episodeLength(episode)].compactMap(\.self).filter { !$0.isEmpty }.joined(separator: " · ")) {
                if playing { toggleEpisodes() } else { playEpisode(episode) }
            }
        }, focus: playback.itemId)
    }

    /// Another episode of the season, in this player screen (as a title
    /// from Continue Watching).
    private func playEpisode(_ episode: EmbyItem) {
        var card = Card(id: episode.id, kind: "Episode", title: episode.name, subtitle: nil, images: [], progress: nil, playable: true)
        card.seriesId = playback.seriesId
        playInstead(card)
    }

    /// At the bottom right, above the title and bar when they're up.
    private var skipIntroButton: some View {
        Button { skipIntro() } label: {
            Text("Skip Intro")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .frame(height: 44)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 20)
        .padding(.bottom, controlsVisible ? (compactHeight ? 112 : 150) : (compactHeight ? 24 : 48))
    }


    /// Fill the screen (the picture cropped at its edges) or fit it, like
    /// pinching in the Apple TV app.
    private var fillAction: PlayerAction {
        PlayerAction(title: filled ? "Fit to Screen" : "Fill Screen",
                     systemImage: filled ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
            setFilled(!filled)
        }
    }

    /// Picture in Picture (where the device has it), then fill or fit.
    private var pictureActions: [PlayerAction] {
        guard PictureInPicture.isSupported, started else { return [fillAction] }
        return [PlayerAction(title: "Picture in Picture", systemImage: "pip.enter") { startPictureInPicture() }, fillAction]
    }

    /// This player's picture moves into the floating window and the film
    /// plays on there, the same playback (see PictureInPicture); this
    /// screen closes once the window is up, leaving the player running.
    private func startPictureInPicture() {
        guard let player else { return }
        // The picture's way out changes (a moment's refresh): not a stall
        // to lower the quality for.
        trackSwitched()
        convertedOpen?.cancel()
        PictureInPicture.shared.start(player, playback: playback, stream: stream, position: position, total: total, paused: paused,
                                      started: {
            handedOff = true
            if let closePlayer { closePlayer() } else { dismiss() }
        }, failed: {
            note("Picture in Picture isn't available for this video")
        })
    }

    private func setFilled(_ fill: Bool) {
        filled = fill
        player?.setFill(fill)
        showControls()
    }

    /// Subtitles (with the audio track) and speed, in one capsule over the
    /// bar's end, as in the Apple TV app.
    private var trackMenu: some View {
        HStack(spacing: 0) {
            TrackMenuButton(tracks: menuTracks, otherLanguages: otherLanguages, pick: { pick($0) },
                            pickOther: { playHeard(in: $0) }, pickSubtitles: { pickSubtitles($0) }) {
                // Open: the controls stay up until something is picked.
                showControls(autoHide: false)
                Task {
                    guard let player else { return }
                    let fresh = await player.tracks()
                    if fresh != tracks { tracks = fresh }
                }
            }
            .equatable()
            SpeedMenuButton(speed: speed, pick: { value in
                speed = value
                player?.setSpeed(value)
                showControls()
            }, opened: {
                #if DEBUG
                NSLog("%@", "PERF menu opened speed")
                #endif
                showControls(autoHide: false)
            })
            .equatable()
        }
        .padding(.horizontal, 4)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    private func pick(_ track: Track) {
        trackSwitched()
        player?.selectAudio(track.id)
        markSelected(track.id, kind: .audio)
        TrackChoice.rememberAudio(track.language, role: track.role, for: trackKeys)
        showControls()
    }

    private func pickSubtitles(_ track: Track?) {
        trackSwitched()
        player?.selectSubtitle(track?.id)
        markSelected(track?.id, kind: .subtitle)
        TrackChoice.rememberSubtitles(track?.language, role: track?.role, for: trackKeys)
        showControls()
        #if DEBUG
        Task { await readTracks() }
        #endif
    }
    #endif

    /// A track switch: the player reads the file again from just before
    /// where it is (for the new track's data), and on a remote server waits
    /// a moment. That isn't the connection being slow: no lower quality for
    /// it (that brought up a note and jumped the picture).
    private func trackSwitched() {
        lastSeek = Date().addingTimeInterval(5)
    }

    /// The tracks the plan calls for, with the viewer's newest picks. The
    /// player picks them before the file plays; this corrects one that got
    /// ready before a pick (a playback prepared ahead) with the old plan.
    private func enforceTracks() {
        guard let plan = playback.tracks?.refreshed(), let player else { return }
        let choice = TrackChoice.choose(tracks, plan: plan)
        let audioNow = tracks.first { $0.kind == .audio && $0.selected }?.id
        if let audio = choice.audio, audio != audioNow {
            trackSwitched()
            player.selectAudio(audio)
            markSelected(audio, kind: .audio)
        }
        let subtitlesNow = tracks.first { $0.kind == .subtitle && $0.selected }?.id
        if choice.subtitle != subtitlesNow {
            trackSwitched()
            player.selectSubtitle(choice.subtitle)
            markSelected(choice.subtitle, kind: .subtitle)
        }
    }

    /// What a choice of tracks is kept for: the show (every episode), or
    /// the film.
    private var trackKey: String { playback.seriesId ?? playback.itemId }
    /// Every copy's key: a pick counts for the title, whichever copy plays.
    private var trackKeys: [String] { playback.trackKeys.isEmpty ? [trackKey] : playback.trackKeys }

    /// English or Spanish that only the title's other copies are heard in,
    /// for the audio menu after the file's own ("Spanish" in Dragon Ball
    /// Z's English copy), as the menu lists languages (see
    /// TrackChoice.menu). None while another title can't take this one's
    /// place.
    private var otherLanguages: [String] {
        guard switchTo != nil else { return [] }
        let here = Set(tracks.filter { $0.kind == .audio }.compactMap { $0.language.flatMap(TrackChoice.normalized) })
            .union(playback.tracks?.basis?.audio.compactMap { $0.flatMap(TrackChoice.normalized) } ?? [])
        var out: [String] = []
        for code in playback.otherCopies.flatMap(\.languages) where ["en", "es"].contains(code) && !here.contains(code) && !out.contains(code) {
            out.append(code)
        }
        return out
    }

    /// "Japanese" for "ja".
    static func languageName(_ code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code) ?? code.uppercased()
    }

    /// The copy heard in `language` (only another copy has it), with no
    /// wait and no picture loading (the user: "I don't want the picture to
    /// load while the audio is switching"): this one plays on while the
    /// other opens out of sight a few seconds ahead, and takes over once its
    /// picture is ready and the film reaches that moment.
    private func playHeard(in language: String) {
        guard let switchTo, switching == nil else { return }
        switching = language
        let lead = paused ? 0.0 : 6.0
        #if DEBUG
        let tapped = Date()
        #endif
        Task {
            defer { switching = nil }
            do {
                let next = try await model.playback(heardIn: language, instead: playback, from: position + lead)
                #if DEBUG
                let planned = Date()
                #endif
                let hidden = model.warmSwitch(next, options: prefs.playerProfile.mpvOptions, hardwareDecoding: prefs.hardwareDecoding)
                let ready = Date().addingTimeInterval(30)
                while !hidden.hasStarted, !hidden.hasFailed, Date() < ready { try await Task.sleep(for: .milliseconds(50)) }
                #if DEBUG
                let opened = Date()
                #endif
                guard hidden.hasStarted else {
                    model.coolDown()
                    return note("Couldn't play it in \(Self.languageName(language))")
                }
                // Its picture is ready: over at the moment it's ready from.
                let at = next.startSeconds ?? 0
                let reached = Date().addingTimeInterval(lead + 5)
                while !paused, position < at - 0.05, Date() < reached { try await Task.sleep(for: .milliseconds(20)) }
                if closedAt == nil {
                    closedAt = position
                    var quiet = Transaction(animation: nil)
                    quiet.disablesAnimations = true
                    withTransaction(quiet) { model.noteStop(playback, seconds: position) }
                }
                #if DEBUG
                model.debugCopySwitch = String(format: "plan %.2f s, its picture ready %.2f s after, on screen %.2f s after the tap (%.0f s lead)",
                                               planned.timeIntervalSince(tapped), opened.timeIntervalSince(planned),
                                               Date().timeIntervalSince(tapped), lead)
                #endif
                switchTo(next)
            } catch {
                note("Couldn't play it in \(Self.languageName(language))")
            }
        }
    }

    #if DEBUG
    /// What the player plays once the choices are in, for UI tests
    /// ("audio=eng subtitles=eng+sdh": a language, then the kind of track).
    private func readTracks() async {
        try? await Task.sleep(for: .milliseconds(500))
        guard let player else { return }
        let playing = await player.tracks()
        func describe(_ track: Track, role: Bool) -> String {
            let language: String = track.language ?? "und"
            let variant: String = track.variant.map { "~" + $0.rawValue } ?? ""
            let kind: String = role ? (track.role.map { "+" + $0 } ?? "") : ""
            return language + variant + kind
        }
        let audio = playing.first { $0.kind == .audio && $0.selected }.map { describe($0, role: false) } ?? "none"
        let subtitles = playing.first { $0.kind == .subtitle && $0.selected }.map { describe($0, role: true) } ?? "off"
        trackReadout = "audio=\(audio) subtitles=\(subtitles)"
    }
    #endif

    /// The tick moves at once (the player confirms on its own queue).
    private func markSelected(_ id: Int?, kind: Track.Kind) {
        tracks = tracks.map { track in
            guard track.kind == kind else { return track }
            var marked = track
            marked.selected = track.id == id
            return marked
        }
    }

    private var note: (text: String, color: Color)? {
        if error != nil { return nil }
        if let temporaryMessage { return (temporaryMessage, .yellow) }
        if let timing { return (timing, .white.opacity(0.6)) }
        #if DEBUG
        if prefs.performanceStats, !stats.isEmpty { return (stats, .white.opacity(0.6)) }
        #endif
        return nil
    }

    private var total: Double { duration ?? playback.durationSeconds ?? 0 }

    private var load: LoadProgress? {
        let subject = LoadProgress.Subject.film(playback.title)
        let cause: LoadProgress.Cause = NetworkStatus.shared.online ? .server : .offline
        if let error {
            return LoadProgress(subject: subject, cause: cause, began: track.began, failure: track.failure(.refused(error)))
        }
        if !started { return LoadProgress(subject: subject, stage: track.stage, cause: cause, began: track.began) }
        guard buffering, let since = track.stalledSince else { return nil }
        return LoadProgress(subject: subject, wait: .stall, stage: track.stage, cause: cause, began: since)
    }

    private var loadActions: LoadActions { LoadActions(tryAgain: { retry() }) }

    private func retry() {
        error = nil
        attempt = 0
        started = false
        let now = Date()
        track.restart(at: now)
        playFile(playback.url, headers: playback.headers, at: startedOnce ? position : playback.startSeconds,
                 readahead: NetworkStatus.shared.fileReadahead, attempt: track.asked(.fetching, at: now))
        showControls()
    }

    @ViewBuilder private var scrubber: some View {
        // While scrubbing the picture itself shows where it'll land (no
        // preview box), and a slower drag says its speed at the end.
        #if os(iOS)
        PhoneClockBar(clock: playClock, total: total, speedLabel: $scrubSpeed,
                      onChanged: { liveScrub($0) }, onCommit: { commitScrub($0) })
        #else
        TVClockedBar(clock: playClock, total: total, holdDirection: holdDirection, paused: paused)
        #endif
    }

    #if os(tvOS)
    private var menu: TVTrackMenu? {
        switch panel {
        case .audio:
            TVTrackMenu(heading: "Audio Track", rows: audioTracks.map {
                .init(label: label($0), checked: $0.selected, identifier: $0.selected ? "audio-playing" : "audio-track")
            } + otherLanguages.map { .init(label: Self.languageName($0), checked: false, identifier: "audio-other-copy") })
        case .subtitles:
            TVTrackMenu(heading: "Subtitles", rows: [.init(label: "Off", checked: !subtitleTracks.contains(where: \.selected), identifier: "subtitle-row")]
                + subtitleTracks.map { .init(label: label($0), checked: $0.selected, identifier: "subtitle-row") })
        case .speed:
            TVTrackMenu(heading: "Playback Speed", rows: PlaybackSpeed.all.map { .init(label: PlaybackSpeed.name($0), checked: $0 == speed) })
        default:
            nil
        }
    }

    #endif

    /// "From Beginning": the start, playing.
    private func restart() {
        jump(to: 0) { $0.seek(to: $1, exact: true) }
        lastSeek = Date()
        position = 0
        jumpUntil = Date().addingTimeInterval(1.5)
        if paused { player?.setPaused(false) }
    }

    // MARK: Tracks and times (both platforms)

    private func clock(_ seconds: Double) -> String { PlayerClock.tvTime(seconds) }

    /// "10 min", "1 hr 52 min".
    private var runtime: String? {
        guard total > 0 else { return nil }
        let minutes = Int((total / 60).rounded())
        guard minutes >= 60 else { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) hr" : "\(minutes / 60) hr \(minutes % 60) min"
    }

    /// The tracks the viewer chooses from (see TrackChoice.menu): no
    /// duplicates, English and Spanish.
    private var menuTracks: [Track] {
        TrackChoice.menu(tracks, spanish: TrackChoice.spanish(for: playback.tracks?.basis?.countries ?? []))
    }
    private var audioTracks: [Track] { menuTracks.filter { $0.kind == .audio } }
    private var subtitleTracks: [Track] { menuTracks.filter { $0.kind == .subtitle } }

    private func phoneClock(_ seconds: Double) -> String { PlayerClock.phoneTime(seconds, total: total) }

    private func label(_ track: Track) -> String { Self.label(track) }

    /// The language and kind, as in the Apple TV app: "English",
    /// "English SDH", "Spanish", "English (Commentary)" (one of each shows:
    /// a file's own names, "Castellano" or "English [Full]", only repeated
    /// it).
    static func label(_ track: Track) -> String {
        let code = track.language.flatMap { TrackChoice.normalized($0) }
        let language = code.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
            ?? track.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Unknown language"
        switch track.role {
        case "commentary": return "\(language) (Commentary)"
        case "sdh": return "\(language) SDH"
        case "forced": return "\(language) (Forced)"
        default: return language
        }
    }

    /// The tracks, and the picture's size and range, once it's playing.
    private func loadTrackInfo() async {
        guard let player else { return }
        tracks = await player.tracks()
        enforceTracks()
        #if DEBUG
        let audio = tracks.first { $0.kind == .audio && $0.selected }?.language ?? "none"
        let subtitles = tracks.first { $0.kind == .subtitle && $0.selected }?.language ?? "off"
        NSLog("%@", "PERF tracks audio=\(audio) subtitles=\(subtitles) of \(tracks.count)")
        await readTracks()
        #endif
        if let format = await player.videoFormat() {
            var badges = [format.height >= 1800 ? "4K" : format.height >= 700 ? "HD" : "SD"]
            if format.gamma == "pq" || format.gamma == "hlg" { badges.append("HDR") }
            self.badges = badges
        }
    }


    /// The film's preview thumbnails: at once when they came with the
    /// player got ready before the tap, else a second after the first frame
    /// (so they don't slow the start), on Wi-Fi; the stills around where
    /// it's playing decoded straight away.
    private func loadThumbnails() async {
        // Fetched with the player got ready before the tap: straight away.
        var data = model.cachedPreviewStills(playback.itemId)
        if data == nil {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, NetworkStatus.shared.knownUnmetered else { return }
            data = await model.previewStills(playback.itemId)
        }
        guard !Task.isCancelled, let data else { return }
        thumbnails = await Task.detached(priority: .utility) { PreviewThumbnails(data) }.value
        thumbnails?.warm(around: position)
        #if DEBUG
        NSLog("%@", "PERF thumbnails \(thumbnails?.count ?? 0)")
        #endif
    }

    private func start() {
        #if os(iOS)
        // Back from Picture in Picture (or chosen again while it's there):
        // the same player, where it has got to.
        if let back = PictureInPicture.shared.takeBack(playback.itemId) {
            adopt(back)
            return
        }
        // A film in Picture in Picture stops (where it got to) for this one.
        PictureInPicture.shared.close()
        #endif
        position = playback.startSeconds ?? 0
        #if DEBUG
        // UI tests (OPENREEL_DEBUG_LOWER_AFTER=seconds): a converted version
        // then, as for a slow connection.
        if let after = ProcessInfo.processInfo.environment["OPENREEL_DEBUG_JUMPS_AFTER"].flatMap(Double.init) {
            Task {
                try? await Task.sleep(for: .seconds(after))
                skip(300)
                try? await Task.sleep(for: .seconds(20))
                skip(-30)
            }
        }
        if let after = ProcessInfo.processInfo.environment["OPENREEL_DEBUG_LOWER_AFTER"].flatMap(Double.init) {
            Task {
                try? await Task.sleep(for: .seconds(after))
                let bitrate = QualityGovernor.ladder[3]
                governor = QualityGovernor(original: playback.bitrate, current: bitrate)
                apply(.converted(bitrate))
            }
        }
        #endif
        if let warmPlayer = model.takeWarm(playback.itemId, at: playback.startSeconds) {
            // Already open and paused at the resume point: just show and play.
            warmStart = true
            PlaybackAudio.activate()
            track = LoadTrack(began: playback.requestedAt, stage: .fetching, attempt: warmPlayer.currentAttempt)
            warmPlayer.onEvent = { event, attempt in handle(event, attempt) }
            self.player = warmPlayer
            #if DEBUG
            warmPlayer.stopwatch.tapped(at: playback.requestedAt.timeIntervalSinceReferenceDate)
            #endif
            if warmPlayer.hasStarted { handle(.started(0), track.attempt) }
            // Now it's being watched: download the rest of it.
            warmPlayer.setReadahead(NetworkStatus.shared.fileReadahead)
            warmPlayer.setPaused(false)
        } else {
            // A player warmed up for something else would only compete for
            // the connection.
            model.coolDown()
            let player = makePlayer(prefs: prefs)
            player.onEvent = { event, attempt in handle(event, attempt) }
            self.player = player
            track = LoadTrack(began: playback.requestedAt, stage: .fetching)
            #if DEBUG
            player.stopwatch.tapped(at: playback.requestedAt.timeIntervalSinceReferenceDate)
            #endif
            // Always the original file first: it's on screen in about a
            // second, while a server-converted version takes 5-15 s to
            // begin (and every seek restarts it). Quality only drops if the
            // original actually stalls.
            player.load(playback.url, headers: playback.headers, start: playback.startSeconds, file: true,
                        readahead: NetworkStatus.shared.fileReadahead, tracks: playback.tracks,
                        attempt: track.asked(.fetching, at: Date()))
            player.addSubtitles(playback.subtitleFiles, references: playback.subtitleReferences, speech: playback.speechStretches)
            player.addCopies(playback.subtitleCopies)
        }
        if governor == nil, prefs.adaptiveQuality { governor = QualityGovernor(original: playback.bitrate) }
        showControls()
        probeTask = Task { await probeWhileConverted() }
    }

    /// Till the first frame: the start's stage for the loading progress.
    private func watchTheOpen() async {
        let askedAgain = StreamRelay.shared.askedAgain.value
        while !started, error == nil {
            model.noteStart(player?.openedAfter == nil ? .openingFilm : .starting)
            if StreamRelay.shared.askedAgain.value > askedAgain { model.noteStartAskedAgain() }
            guard (try? await Task.sleep(for: .milliseconds(500))) != nil else { break }
        }
        model.endStart(failure: error)
    }

    /// A wait still on at its deadline (the start, Try again, a stall)
    /// stops the film and says so, rather than leave the ring up.
    private func endWait(at deadline: Date?) async {
        guard let deadline else { return }
        try? await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
        guard !Task.isCancelled, load?.overdue(at: Date()) == true else { return }
        convertedOpen?.cancel()
        player?.stop {}
        error = StartPatience.tooLong.localizedDescription
        track.failed(at: Date())
        showControls(autoHide: false)
    }

    #if os(iOS)
    /// The player from Picture in Picture, drawing on this screen again.
    private func adopt(_ back: (player: MPVPlayer, stream: FilmStream, position: Double, paused: Bool)) {
        PlaybackAudio.activate()
        stream = back.stream
        position = back.position
        paused = back.paused
        started = true
        startedOnce = true
        warmStart = true
        track = LoadTrack(began: Date(), stage: .fetching, attempt: back.player.currentAttempt)
        back.player.onEvent = { event, attempt in handle(event, attempt) }
        player = back.player
        trackSwitched()
        back.player.drawOnScreen()
        if governor == nil, prefs.adaptiveQuality, back.stream.isOriginal { governor = QualityGovernor(original: playback.bitrate) }
        Task { await loadTrackInfo() }
        thumbnailTask = Task { await loadThumbnails() }
        if paused { showControls(autoHide: false) } else { showControls() }
        probeTask = Task { await probeWhileConverted() }
    }
    #endif

    /// While playing a converted version, test the connection every 20 s by
    /// fetching 4 MB of the original, so it can return to full quality.
    private func probeWhileConverted() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(20))
            guard governor?.current != nil, player != nil, !paused else { continue }
            var request = URLRequest(url: playback.url)
            request.timeoutInterval = 15
            let from = Int.random(in: 0...50) * 4_194_304
            request.setValue("bytes=\(from)-\(from + 4_194_303)", forHTTPHeaderField: "Range")
            for header in playback.headers {
                let pair = header.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if pair.count == 2 { request.setValue(pair[1], forHTTPHeaderField: pair[0]) }
            }
            // Streamed and cut off at 4 MB: a server that ignores the range
            // would otherwise send (and this would hold) the whole film.
            let begun = Date()
            guard let (bytes, response) = try? await HTTP.ahead.bytes(for: request, delegate: HTTP.keyOutOfRedirects),
                  (response as? HTTPURLResponse)?.statusCode == 206 else { continue }
            var count = 0
            do {
                for try await _ in bytes {
                    count += 1
                    if count >= 4_194_304 { break }
                }
            } catch { continue }
            guard count > 500_000 else { continue }
            governor?.noteProbe(bitsPerSecond: Double(count * 8) / max(Date().timeIntervalSince(begun), 0.05))
        }
    }

    /// Switches quality at the current position.
    private func apply(_ decision: QualityGovernor.Decision) {
        guard let player else { return }
        let at = position
        switch decision {
        case let .converted(bitrate):
            revertTo = nil
            lastConverted = bitrate
            guard let url = model.convertedURL(for: playback, bitrate: bitrate, start: at, audio: player.audioStreamIndex) else { return }
            playConverted(url, attempt: track.nextAttempt())
        case .original:
            revertTo = lastConverted
            jumpUntil = Date().addingTimeInterval(1.5)
            playFile(playback.url, headers: playback.headers, at: at, readahead: NetworkStatus.shared.fileReadahead,
                     attempt: track.nextAttempt())
        }
    }

    private func playFile(_ url: URL, headers: [String], at: Double?, readahead: MPVPlayer.Readahead = .live, attempt: Int) {
        convertedOpen?.cancel()
        stream = .whole
        player?.load(url, headers: headers, start: at, file: true, readahead: readahead, tracks: playback.tracks, sameFilm: 0,
                     attempt: attempt)
    }

    /// Opens from where the film is once the playlists arrive, so a jump during the wait holds.
    private func playConverted(_ url: URL, attempt: Int) {
        guard let player else { return }
        #if DEBUG
        player.askedForConverted()
        #endif
        let headers = playback.fallbackHeaders
        convertedOpen?.cancel()
        convertedOpen = Task {
            let address = await playback.opening(url)
            let opening = await ConvertedPlaylist.load(address, headers: headers)
            guard !Task.isCancelled, self.player === player else { return }
            switch opening {
            case let .refused(why): refuseConverted(why, player)
            case let .listed(list):
                guard let opened = player.openConverted(address, list, at: position, for: playback, attempt: attempt) else {
                    return refuseConverted("relay not running", player)
                }
                // The stream playing reports where it was for a moment after
                // the clock moves: the bar stays put meanwhile.
                jumpUntil = Date().addingTimeInterval(1.5)
                stream = opened
            }
        }
    }

    private func refuseConverted(_ why: String, _ player: MPVPlayer) {
        #if DEBUG
        convertedReadout = "not opened, " + why
        #endif
        if player.hasFailed { return handle(.failed("The converted version didn't open.", nil), track.attempt) }
        governor = nil
    }

    private func jump(to target: Double, seek: (MPVPlayer, Double) -> Void) {
        guard let player else { return }
        stream = player.jump(in: stream, to: target, for: playback) { seek(player, $0) }
    }

    /// Shows a timing under the title for a few seconds.
    private func showTiming(_ text: String, for seconds: Double) {
        timing = text
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if timing == text { timing = nil }
        }
    }

    /// The next episode, in this player screen (at the end, as the Apple TV
    /// app's "Play Next Episode" does).
    private func playNext(_ episode: EmbyItem) {
        guard let switchTo, switching == nil else { return }
        switching = episode.id
        Task {
            defer { switching = nil }
            do {
                let next = try await model.playback(itemId: episode.id, kind: "Episode")
                if closedAt == nil {
                    closedAt = position
                    var quiet = Transaction(animation: nil)
                    quiet.disablesAnimations = true
                    withTransaction(quiet) { model.noteStop(playback, seconds: position) }
                }
                switchTo(next)
            } catch {
                note("Couldn't play the next episode")
                close()
            }
        }
    }

    private func note(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { temporaryMessage = text }
        Task {
            try? await Task.sleep(for: .seconds(4))
            if temporaryMessage == text { withAnimation(.easeIn(duration: 0.3)) { temporaryMessage = nil } }
        }
    }

    /// An event of a load replaced since (Try again, the next way to open
    /// it, another quality) changes nothing; the player's own pause, jumps
    /// and tracks aren't any one load's.
    private func handle(_ event: MPVPlayer.Event, _ loadAttempt: Int) {
        switch event {
        case .paused, .seeked, .previewShown, .tracksChanged: break
        default: guard track.isCurrent(loadAttempt) else { return }
        }
        switch event {
        case let .started(playerSeconds):
            ScreenAwake.set(awakeID, playing: !paused)
            started = true
            buffering = false
            track.pictured()
            governor?.notePlaying()
            guard !startedOnce else { return }
            startedOnce = true
            // Whole start from the tap: server, then screen/player setup,
            // opening the file, and seeking + the first frame.
            let total = Date().timeIntervalSince(playback.requestedAt)
            if warmStart {
                timing = String(format: "Started in %.1f s · ready before you tapped", total)
            } else {
                let opened = player?.openedAfter ?? 0
                let setup = max(0, total - playback.resolvedIn - playerSeconds)
                timing = String(format: "Started in %.1f s · server %.1f · setup %.1f · open %.1f · first frame %.1f",
                                total, playback.resolvedIn, setup, opened, playerSeconds - opened)
            }
            #if DEBUG
            NSLog("%@", "PERF start " + (timing ?? ""))
            startReadout = String(format: "%@ %.1f at %.0f", warmStart ? "warm" : "cold", total, position)
            if let player, !warmStart {
                let loading = player.startLoadedAt - playback.requestedAt.timeIntervalSinceReferenceDate - playback.resolvedIn
                startParts = String(format: "plan %.2f s (%@), start ahead %@, then %.2f s to the open, ", playback.resolvedIn,
                                    model.lastPlanKept ? "kept" : "asked", model.lastStartAhead, loading) + player.startNote
                    + PhoneNetworkUse.shared.debugReadout(over: NetworkStatus.shared.network)
                    + " | plan: " + model.lastPlan
            }
            #endif
            Task { await loadTrackInfo() }
            // No subtitles a foreign film needs: the server's providers
            // find some, and the one that fits the film best stays.
            if playback.mediaSourceId != nil {
                Task {
                    let files = await model.findMissingSubtitles(for: playback)
                    guard !files.isEmpty else { return }
                    let (item, source) = (playback.itemId, playback.mediaSourceId)
                    player?.addFound(files, references: playback.subtitleReferences, speech: playback.speechStretches) { url in
                        Task { @MainActor in model.notePickedSubtitle(itemId: item, mediaSourceId: source, url: url) }
                    }
                }
            }
            #if DEBUG && os(iOS)
            NSLog("%@", "PERF pip supported=\(PictureInPicture.isSupported)")
            #endif
            thumbnailTask = Task { await loadThumbnails() }
            // Development builds with the stats on: shown for a moment.
            if prefs.performanceStats { showTiming(timing ?? "", for: 5) } else { timing = nil }
            if controlsVisible { showControls() }
            Task { await model.report(playback, seconds: position, event: .started) }
        case let .seeked(seconds):
            jumpUntil = nil
            if prefs.performanceStats { showTiming(String(format: "Jumped in %.1f s", seconds), for: 3) }
            #if DEBUG
            NSLog("%@", String(format: "PERF seek %.3f at %.1f", seconds, position))
            #endif
        case let .buffering(isBuffering):
            buffering = isBuffering
            if isBuffering, started { track.stalled(at: Date()) } else { track.flowing() }
            #if DEBUG
            NSLog("%@", "PERF buffering \(isBuffering)")
            #endif
            // A stall: drop quality straight away rather than wait it out.
            // Not waiting for data just after a jump (or while choosing),
            // which used to drop a film to the server-converted version after
            // a few skips, and every skip after that waited for the server.
            if isBuffering, started, scrubbing == nil, Date().timeIntervalSince(lastSeek) > 3,
               let decision = governor?.observe(buffer: 0, bytesPerSecond: 0, stalled: true, left: secondsLeft) {
                apply(decision)
            }
        case let .network(buffer, bytesPerSecond):
            // Just after a jump the buffer is refilling: not a slow connection.
            if started, !paused, scrubbing == nil, Date().timeIntervalSince(lastSeek) > 3,
               let decision = governor?.observe(buffer: buffer, bytesPerSecond: bytesPerSecond, stalled: false, left: secondsLeft) {
                apply(decision)
            }
            #if DEBUG
            NSLog("%@", String(format: "PERF net %.1f Mbps buffer %.1f s at %.1f", bytesPerSecond * 8 / 1e6, buffer, position))
            let quality = governor?.current.map { String(format: "converted %.1f Mbps", Double($0) / 1e6) } ?? "original"
            if quality != qualityReadout { qualityReadout = quality }
            playClock.readout = String(format: "%.1f %@", position, paused ? "paused" : "playing")
            relayReadout = String(StreamRelay.shared.readsBack)
            let file = playback.bitrate.map { String(format: "file %.1f Mbps", Double($0) / 1e6) } ?? "file bitrate ?"
            stats = String(format: "%@ · %@ · speed %.1f Mbps · %.0f s buffered", quality, file,
                           (governor?.speed ?? bytesPerSecond * 8) / 1e6, buffer)
            #endif
        case let .failed(message, _):
            // Back to full quality didn't open: carry on at the lower one.
            if started, let bitrate = revertTo,
               let url = model.convertedURL(for: playback, bitrate: bitrate, start: position, audio: player?.audioStreamIndex) {
                revertTo = nil
                governor?.revert(to: bitrate)
                playConverted(url, attempt: track.nextAttempt())
                return
            }
            // A converted version the server won't make: go back to the
            // original and stop adapting.
            if started, governor?.current != nil {
                governor = nil
                playFile(playback.url, headers: playback.headers, at: position, attempt: track.nextAttempt())
                return
            }
            if !started, attempt < playback.fallbacks.count {
                // The original didn't open; try the next way Emby offers.
                let next = playback.fallbacks[attempt]
                attempt += 1
                let asked = track.asked(.fetching, at: Date())
                if next.path().hasSuffix(".m3u8") { playConverted(next, attempt: asked); return }
                playFile(next, headers: playback.fallbackHeaders, at: playback.startSeconds, attempt: asked)
                return
            }
            error = message.prefix(1).uppercased() + message.dropFirst()
            track.failed(at: Date())
            showControls(autoHide: false)
            // Say why: how the server answered each way of opening it.
            Task {
                let why = await model.diagnose(playback)
                if !why.isEmpty, error != nil { error = why }
            }
        case let .time(rawPosition, newDuration):
            if let newDuration, offset == 0, duration != newDuration { duration = newDuration }
            if let until = jumpUntil {
                guard Date() >= until else { return }
                jumpUntil = nil
            }
            let newPosition = rawPosition + offset
            position = newPosition
            #if DEBUG
            // With the position itself: the network reports (about once a
            // second, none once the buffer is full) left it a second behind.
            playClock.readout = String(format: "%.1f %@", newPosition, paused ? "paused" : "playing")
            playClock.streamReadout = String(format: "%.1f", rawPosition + (player?.streamStartTime ?? 0))
            #endif
            // Into the last fifth of an episode: the next one, ready.
            if !preparedNext, playback.seriesId != nil, total > 0, newPosition >= total * 0.8 {
                preparedNext = true
                model.prepareNext(after: playback)
                if switchTo != nil { Task { upNext = await model.episode(after: playback) } }
            }
            // Not while choosing where to jump: the picture's previews
            // aren't where the viewer is.
            if abs(newPosition - lastReport) >= 10, scrubbing == nil {
                lastReport = newPosition
                Task { await model.report(playback, seconds: newPosition, event: .progress) }
            }
        case let .paused(isPaused):
            paused = isPaused
            if started { ScreenAwake.set(awakeID, playing: !isPaused) }
            #if DEBUG
            // At once: the network reports that also refresh it stop once
            // the buffer is full, and it said "playing" after a pause.
            playClock.readout = String(format: "%.1f %@", position, isPaused ? "paused" : "playing")
            #endif
            // Paused: choosing where to go is likely next.
            if isPaused { thumbnails?.warm(around: position) }
            #if os(tvOS)
            // Paused by the viewer (not to choose where to jump): the title,
            // buttons and Info tab; playing, the bar alone.
            if isPaused, scrubbing == nil, !resumeAfterScrub { compact = false }
            if !isPaused {
                compact = true
                // Playing again: the bar alone, and the remote back on it
                // (a hidden button kept it, and swallowed the skips).
                if panel == nil {
                    menuRequest += 1
                    focus = .bar
                }
            }
            #endif
            if isPaused { showControls(autoHide: false) } else { showControls() }
        case .ended:
            position = total
            if let next = upNext, switchTo != nil { return playNext(next) }
            close()
        case let .previewShown(seconds):
            previewShown = seconds
        case .tracksChanged:
            // The menu lists them at once (it showed the tracks read at
            // the start, and a file came a moment later).
            Task {
                guard let player else { return }
                let fresh = await player.tracks()
                #if DEBUG
                NSLog("%@", "PERF tracks changed: \(fresh.count) tracks, was \(tracks.count)")
                #endif
                if fresh != tracks { tracks = fresh }
                #if DEBUG
                await readTracks()
                #endif
            }
        case .opened:
            if !started { track.opened() }
        case .opening, .window:
            break
        }
    }

    private func finish() {
        hideTask?.cancel()
        probeTask?.cancel()
        convertedOpen?.cancel()
        thumbnailTask?.cancel()
        settleSeek?.cancel()
        #if os(tvOS)
        holdTask?.cancel()
        #endif
        if let speed = governor?.speed, speed > 0 { model.knownSpeed = speed }
        let seconds = closedAt ?? position
        #if os(iOS)
        // Playing on in Picture in Picture: the window has the player now,
        // and reports when it stops.
        if handedOff {
            player = nil
            return
        }
        #endif
        // Kept, paused here, for a moment: chosen again, it carries on at
        // once (it closed, and the next tap waited for the server and a
        // new stream, then started where the server last heard).
        if let player {
            if started, error == nil, stream.isOriginal { model.park(player, playback.resuming(at: seconds)) } else { player.shutdown() }
        }
        player = nil
        let noted = closedAt != nil
        Task { await model.report(playback, seconds: seconds, event: .stopped, noted: noted) }
    }

    /// Closes the player. The stop goes on the page behind (its resume
    /// point, Continue Watching's order) first, with no animation, while
    /// the player still covers it: the page appears as it will stay.
    /// Changing it after it showed made "Play" fade into "Continue" and
    /// Continue Watching's cards swap places under the viewer's eyes.
    private func close() {
        if closedAt == nil {
            closedAt = position
            var quiet = Transaction(animation: nil)
            quiet.disablesAnimations = true
            withTransaction(quiet) { model.noteStop(playback, seconds: position) }
        }
        if let closePlayer { closePlayer() } else { dismiss() }
    }

    #if DEBUG
    private var keyedAddresses: Int {
        let all = [playback.url] + playback.fallbacks + playback.subtitleFiles.map(\.url) + playback.subtitleCopies.map(\.subtitle.address)
            + playback.subtitleReferences.map(\.subtitle.address) + playback.speechStretches.map(\.url)
        return all.filter { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name.lowercased() == "api_key" } == true }.count
    }

    /// The film's requests, and a converted version's first segments
    /// (-debugRedirectCounts YES), the server answered with a redirect.
    private var redirectsReadout: String {
        let converted = ConvertedPlaylist.redirects.value
        return "film \(StreamRelay.redirects.value.readout) | converted \(converted.count.readout) of \(converted.asked) asked"
    }

    private func debugReadout(_ text: String, _ id: String) -> some View {
        Text(text)
            .font(.caption2)
            .lineLimit(1)
            .frame(width: 1, height: 1)
            .opacity(0.02)
            .accessibilityLabel(text)
            .accessibilityIdentifier(id)
    }
    #endif

    private func toggleControls() {
        #if DEBUG
        NSLog("%@", "PERF picture tapped controls=\(controlsVisible)")
        #endif
        if controlsVisible {
            hideTask?.cancel()
            withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = false }
        } else {
            showControls()
        }
    }

    private func showControls(autoHide: Bool = true) {
        hideTask?.cancel()
        withAnimation(.easeOut(duration: 0.12)) { controlsVisible = true }
        guard autoHide, !paused, started, error == nil else { return }
        #if os(tvOS)
        // On a button or in a menu: stays until the remote leaves it.
        guard focus == .bar, panel == nil else { return }
        #endif
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, error == nil else { return }
            withAnimation(.easeInOut(duration: 0.3)) { controlsVisible = false }
            #if os(tvOS)
            compact = true
            #endif
        }
    }

    /// While dragging: pause, and move the picture so it follows the finger:
    /// the exact frame when scrubbing slowly or resting, the nearest
    /// keyframe while sweeping fast. `settle: false` (a held button, which
    /// moves on every quarter second): keyframes only, since each exact
    /// frame costs a moment of decoding the picture would wait for.
    private func liveScrub(_ target: Double, settle: Bool = true) {
        showControls(autoHide: false)
        if scrubOrigin == nil { scrubOrigin = position }
        if !resumeAfterScrub, !paused {
            resumeAfterScrub = true
            player?.setPaused(true)
        }
        // When the finger rests, show the exact frame at that second (the
        // server's thumbnails are 10 s apart, keyframes several seconds).
        settleSeek?.cancel()
        if settle {
            settleSeek = Task {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled else { return }
                showPreview(target, exact: true)
            }
        }
        // Moving: keyframes only when sweeping at full speed, where a pixel
        // is many seconds anyway (the player keeps up as fast as it can).
        showPreview(target, exact: scrubSpeed != nil)
    }

    /// Not before a listed version's first segment: the player shows that
    /// segment's start for any second before it.
    private func showPreview(_ target: Double, exact: Bool) {
        if target >= offset { player?.follow(to: target - offset, exact: exact) }
        lastSeek = Date()
    }

    /// On release: carry on from the picture on screen, which is already
    /// where it was chosen (no second jump, so it plays at once). Only when
    /// the picture is a moment behind, jump: to the keyframe before the
    /// target, which plays without decoding up to the second (exact when
    /// scrubbing slowly on iPhone).
    private func commitScrub(_ target: Double, byClick: Bool = false) {
        settleSeek?.cancel()
        // Carries on from the picture on screen when it's already there (no
        // second jump); otherwise one jump, replacing any preview still on
        // its way, so nothing lands after letting go.
        jump(to: target) { $0.settle(at: $1, exact: scrubSpeed != nil) }
        lastSeek = Date()
        position = target
        jumpUntil = Date().addingTimeInterval(0.5)
        scrubbing = nil
        scrubOrigin = nil
        let play = RemoteSwipe.playsAfterChoosing(byClick: byClick, wasPlaying: resumeAfterScrub)
        resumeAfterScrub = false
        if play { player?.setPaused(false) }
        showControls()
    }

    #if os(tvOS)
    /// The Siri Remote, as in Apple's player:
    /// - click left or right: back or forward 10 seconds, straight away;
    /// - hold left or right: rewind or fast-forward, faster the longer it's
    ///   held, jumping there on release;
    /// - swipe across the touch surface, paused: the picture follows to
    ///   where it would jump; click to play from there, Menu to stay.
    ///   Playing, a swipe only shows the controls (see RemoteSwipe);
    /// - click the centre or Play/Pause: pause or play;
    /// - up: the round buttons (subtitles, audio, speed), whose menus open with a
    ///   click; down: the Info panel and "From Beginning";
    /// - Menu: close a menu or the panel, stop choosing, hide the controls,
    ///   then leave.
    private func remote(_ input: TVRemoteSurface.Input) {
        if inLoad(input) { return }
        if let panel { return inPanel(panel, input) }
        if focus == .audio || focus == .subtitles || focus == .speed { return onButtons(input) }
        switch input {
        case let .click(direction):
            guard started else { return }
            compact = true
            if let target = scrubbing {
                preview(target + direction * 10)
            } else {
                skip(direction * 10)
            }
        case let .hold(direction):
            guard started else { return }
            compact = true
            holdDirection = direction
            holdTask?.cancel()
            holdTask = Task {
                var step = 10.0
                while !Task.isCancelled {
                    preview((scrubbing ?? position) + direction * step, settle: false)
                    try? await Task.sleep(for: .milliseconds(250))
                    // 40 s a second at first, up to 4 minutes a second.
                    step = min(step * 1.12, 60)
                }
            }
        case .released:
            holdTask?.cancel()
            holdTask = nil
            holdDirection = nil
            if let target = scrubbing { commitScrub(target) }
        case let .swipe(began, distance, ended):
            guard started else { return }
            guard RemoteSwipe.action(at: .bar, paused: paused, scrubbing: scrubbing != nil, distance: distance) == .scrub else {
                // Playing: a swipe on the way to the buttons isn't a jump.
                showControls()
                return
            }
            compact = true
            if began { swipeFrom = scrubbing ?? position }
            guard let from = swipeFrom else { return }
            if distance != 0 { preview(from + Double(distance) * secondsPerPoint) }
            if ended { swipeFrom = nil }
        case .up:
            guard started, scrubbing == nil else { return }
            compact = false
            focus = .audio
            showControls(autoHide: false)
        case .down:
            guard started, scrubbing == nil else { return }
            panel = .info
            // On its tab, as in Apple's player: "From Beginning" is one
            // more press down, so a click meant for the film can't start it
            // over.
            focus = .infoTab
            showControls(autoHide: false)
        case .select, .playPause:
            if let target = scrubbing {
                commitScrub(target, byClick: true)
            } else if case .select = input, showsSkipIntro {
                skipIntro()
            } else {
                togglePlay()
            }
        case .menu:
            if scrubbing != nil {
                cancelScrub()
            } else if controlsVisible, !paused, started {
                hideTask?.cancel()
                withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = false }
            } else {
                close()
            }
        }
    }

    private func inLoad(_ input: TVRemoteSurface.Input) -> Bool {
        guard load?.shown(at: Date())?.buttons.contains(.tryAgain) == true else { return false }
        switch input {
        case .select:
            retry()
            return true
        case .click:
            return true
        default:
            return false
        }
    }

    /// On the round buttons: left and right between them (a click on the
    /// ring, or a swipe), a click opens its menu, down or Menu back to the
    /// bar.
    private func onButtons(_ input: TVRemoteSurface.Input) {
        func move(_ by: Int) {
            let buttons: [TVPlayerFocus] = (subtitleTracks.isEmpty ? [] : [.subtitles]) + [.audio, .speed]
            guard by != 0, let at = buttons.firstIndex(of: focus) else { return }
            let next = buttons[min(max(at + by, 0), buttons.count - 1)]
            guard next != focus else { return }
            // Off the button: a menu asked for there no longer opens.
            menuRequest += 1
            focus = next
        }
        switch input {
        case let .click(direction):
            move(direction < 0 ? -1 : 1)
        case let .swipe(began, distance, ended):
            if began { buttonSwipeSteps = 0 }
            if case let .moveFocus(by) = RemoteSwipe.action(at: .buttons, paused: paused, scrubbing: false,
                                                            distance: distance, stepsTaken: buttonSwipeSteps), by != 0 {
                move(by)
                buttonSwipeSteps += by
            }
            if ended { buttonSwipeSteps = 0 }
        case .select:
            openMenu(Self.menu(for: focus))
        case .playPause:
            togglePlay()
        case .down, .menu:
            backToBar()
        default:
            break
        }
    }

    /// The Info panel or a menu open: up and down through a menu, a click
    /// picks, Menu (or up, from the Info panel) closes it.
    private func inPanel(_ open: TVPlayerPanel, _ input: TVRemoteSurface.Input) {
        if open == .info || open == .episodes { return inInfo(input) }
        let rows = menu?.rows.count ?? 0
        let button = Self.button(for: open)
        switch (open, input) {
        case (_, .playPause):
            togglePlay()
        case (_, .up):
            if case let .row(i) = focus { focus = .row(max(i - 1, 0)) }
        case (_, .down):
            if case let .row(i) = focus { focus = .row(min(i + 1, rows - 1)) }
        case (_, .select):
            if case let .row(i) = focus { choose(i, in: open) }
            panel = nil
            focus = button
        case (_, .menu):
            panel = nil
            focus = button
        default:
            break
        }
    }

    /// The Info and Episodes tabs, as in Apple's player: left and right
    /// between the tabs (each shows its page), down into the page ("From
    /// Beginning", or the row of episodes, on the one playing), left and
    /// right along the row; a click carries it out (on a tab, nothing);
    /// up back to the tab, then away; Menu away.
    private func inInfo(_ input: TVRemoteSurface.Input) {
        let tabs: [TVPlayerFocus] = seasonEpisodes.count > 1 ? [.infoTab, .episodesTab] : [.infoTab]
        func moveTab(_ by: Int) {
            guard let at = tabs.firstIndex(of: focus) else { return }
            let tab = tabs[min(max(at + by, 0), tabs.count - 1)]
            focus = tab
            panel = tab == .episodesTab ? .episodes : .info
        }
        func moveEpisode(_ by: Int) {
            guard case let .episode(i) = focus else { return }
            focus = .episode(min(max(i + by, 0), seasonEpisodes.count - 1))
        }
        func move(_ by: Int) {
            if case .episode = focus { moveEpisode(by) } else { moveTab(by) }
        }
        switch input {
        case let .click(direction):
            move(direction < 0 ? -1 : 1)
        case let .swipe(began, distance, ended):
            if began { buttonSwipeSteps = 0 }
            if case let .moveFocus(by) = RemoteSwipe.action(at: .buttons, paused: paused, scrubbing: false,
                                                            distance: distance, stepsTaken: buttonSwipeSteps), by != 0 {
                move(by)
                buttonSwipeSteps += by
            }
            if ended { buttonSwipeSteps = 0 }
        case .down:
            if focus == .infoTab {
                focus = .fromBeginning
            } else if focus == .episodesTab {
                focus = .episode(seasonEpisodes.firstIndex { $0.id == playback.itemId } ?? 0)
            }
        case .up:
            switch focus {
            case .fromBeginning: focus = .infoTab
            case .episode: focus = .episodesTab
            default:
                panel = nil
                backToBar()
            }
        case .select:
            if focus == .fromBeginning {
                restart()
                panel = nil
                backToBar()
            } else if case let .episode(i) = focus, seasonEpisodes.indices.contains(i) {
                let episode = seasonEpisodes[i]
                if episode.id == playback.itemId {
                    panel = nil
                    backToBar()
                } else {
                    playNext(episode)
                }
            }
        case .playPause:
            togglePlay()
        case .menu:
            panel = nil
            backToBar()
        default:
            break
        }
    }

    /// Back on the bar: playing, the controls hide again in a moment.
    private func backToBar() {
        // A menu still being fetched for a button doesn't open later.
        menuRequest += 1
        focus = .bar
        if !paused { compact = true }
        showControls(autoHide: !paused)
    }

    /// The menu a round button opens, and the button a menu closes back to.
    private static func menu(for button: TVPlayerFocus) -> TVPlayerPanel {
        switch button {
        case .subtitles: .subtitles
        case .speed: .speed
        default: .audio
        }
    }

    private static func button(for menu: TVPlayerPanel) -> TVPlayerFocus {
        switch menu {
        case .subtitles: .subtitles
        case .speed: .speed
        default: .audio
        }
    }

    /// A menu, on the track (or speed) in use.
    private func openMenu(_ kind: TVPlayerPanel) {
        menuRequest += 1
        let request = menuRequest
        let button = Self.button(for: kind)
        Task {
            var fresh: [Track]?
            if kind != .speed { fresh = await player?.tracks() }
            // Still asked for: the latest request, the remote still on its
            // button, nothing else opened meanwhile.
            guard request == menuRequest, focus == button, panel == nil else { return }
            if let fresh { tracks = fresh }
            let chosen = switch kind {
            case .audio: audioTracks.firstIndex(where: \.selected) ?? 0
            case .speed: PlaybackSpeed.all.firstIndex(of: speed) ?? 2
            default: subtitleTracks.firstIndex(where: \.selected).map { $0 + 1 } ?? 0
            }
            panel = kind
            focus = .row(chosen)
            showControls(autoHide: false)
        }
    }

    /// Plays the audio track in this row, shows these subtitles (row 0:
    /// none), or plays at this speed; the tick moves at once.
    private func choose(_ row: Int, in kind: TVPlayerPanel) {
        guard let player else { return }
        if kind == .speed {
            guard PlaybackSpeed.all.indices.contains(row) else { return }
            speed = PlaybackSpeed.all[row]
            player.setSpeed(speed)
            return
        }
        let trackKind: Track.Kind = kind == .audio ? .audio : .subtitle
        // The rows as shown (see `menu`). Regression: the row picked the
        // file's track at that place among all of them, so English chose
        // the Spanish listed first in the file.
        let list = kind == .audio ? audioTracks : subtitleTracks
        let id: Int?
        if kind == .audio {
            // After the file's own: languages only another copy has.
            if row >= list.count, otherLanguages.indices.contains(row - list.count) {
                return playHeard(in: otherLanguages[row - list.count])
            }
            guard list.indices.contains(row) else { return }
            trackSwitched()
            id = list[row].id
            player.selectAudio(list[row].id)
            TrackChoice.rememberAudio(list[row].language, role: list[row].role, for: trackKeys)
        } else {
            trackSwitched()
            let track = row > 0 && list.indices.contains(row - 1) ? list[row - 1] : nil
            id = track?.id
            player.selectSubtitle(id)
            TrackChoice.rememberSubtitles(track?.language, role: track?.role, for: trackKeys)
        }
        tracks = tracks.map { track in
            guard track.kind == trackKind else { return track }
            var marked = track
            marked.selected = track.id == id
            return marked
        }
        #if DEBUG
        Task { await readTracks() }
        #endif
    }

    /// A swipe across the whole touch surface (about the screen's width)
    /// moves a quarter of the film, at least two and a half minutes.
    private var secondsPerPoint: Double { max(total, 600) / 4 / 1920 }

    /// Moves where a jump would land; the picture pauses and follows.
    private func preview(_ target: Double, settle: Bool = true) {
        let clamped = min(max(target, 0), max(total - 1, 0))
        scrubbing = clamped
        liveScrub(clamped, settle: settle)
    }

    /// Menu while choosing: back to where it was, playing if it was.
    private func cancelScrub() {
        settleSeek?.cancel()
        if let origin = scrubOrigin {
            jump(to: origin) { $0.seek(to: $1, exact: true) }
            lastSeek = Date()
        }
        scrubbing = nil
        scrubOrigin = nil
        if resumeAfterScrub {
            resumeAfterScrub = false
            player?.setPaused(false)
        }
        showControls()
    }

    private func togglePlay() {
        let pausing = !paused
        player?.togglePause()
        showControls(autoHide: !pausing)
    }

    #endif

    /// The season of the episode playing, as on its show's page (the
    /// show as saved, else fetched).
    private func loadSeason() async {
        guard let series = playback.seriesId else { return }
        let data: AppModel.ShowData?
        if let saved = model.cachedShow(series), saved.episodes.contains(where: { $0.id == playback.itemId }) {
            data = saved
        } else {
            data = await model.loadShow(series)
        }
        guard let data, let current = data.episodes.first(where: { $0.id == playback.itemId }) else { return }
        seasonEpisodes = data.episodes
            .filter { $0.parentIndexNumber == current.parentIndexNumber }
            .sorted { ($0.indexNumber ?? 0) < ($1.indexNumber ?? 0) }
    }

    /// "3. Case 3".
    private func episodeTitle(_ episode: EmbyItem) -> String {
        (episode.indexNumber.map { "\($0). " } ?? "") + episode.name
    }

    /// "22m", "1h 2m".
    private func episodeLength(_ episode: EmbyItem) -> String? {
        episode.runTimeTicks.map { ticks in
            let minutes = max(1, Int((Double(ticks) / 6e8).rounded()))
            return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
        }
    }

    /// "Playing" for this one, "12m left" for one under way, else its length.
    private func episodeStatus(_ episode: EmbyItem) -> String? {
        if episode.id == playback.itemId { return "Playing" }
        if episode.resumeFraction != nil, let left = EmbyClient.timeLeft(episode) { return "\(left) left" }
        return episodeLength(episode)
    }

    /// During the intro the server has marked: "Skip Intro", until a
    /// second before its end; not with a panel open, or while choosing a
    /// point on the bar. Apple TV: while it plays (a click then skips).
    private var showsSkipIntro: Bool {
        skipIntroAllowed && PlayerClock.inIntro(position, scrubbing: scrubbing, intro: playback.intro)
    }

    /// When else Skip Intro may show (the clock says whether it's the intro).
    private var skipIntroAllowed: Bool {
        guard playback.intro != nil, started else { return false }
        #if os(iOS)
        return !showInfo && !showContinue && !showEpisodes
        #else
        return panel == nil && !paused
        #endif
    }

    /// Seconds from here to the end of the file, when its length is known.
    private var secondsLeft: Double? { total > 0 ? max(0, total - position) : nil }

    /// To the intro's end, straight away.
    private func skipIntro() {
        guard let end = playback.intro?.upperBound else { return }
        jump(to: end) { $0.seek(to: $1, exact: false) }
        lastSeek = Date()
        position = end
        jumpUntil = Date().addingTimeInterval(1.5)
    }

    /// Back or forward 10 s, straight away: the bar moves at once, and the
    /// picture follows from the nearest keyframe past the ten seconds.
    private func skip(_ seconds: Double) {
        guard started else { return }
        let target = min(max(position + seconds, 0), max(total, 1))
        jump(to: target) { player, _ in player.seek(by: seconds, exact: false) }
        lastSeek = Date()
        position = target
        jumpUntil = Date().addingTimeInterval(1.5)
        showControls(autoHide: !paused)
    }

    private func timeString(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// Round Liquid Glass icon button used across the player.
struct GlassIconButton: View {
    let systemName: String
    let label: String
    var size: CGFloat = 44
    let action: () -> Void

    /// Exactly `size` across: the system's glass button style padded the
    /// label, which made a 44-point button about 58.
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(size > 60 ? .title.weight(.semibold) : size < 40 ? .body.weight(.semibold) : .title3.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }
}

extension Int64 {
    /// Unix seconds as a short local time, e.g. "9:30 PM".
    var clock: String {
        Date(timeIntervalSince1970: TimeInterval(self)).formatted(date: .omitted, time: .shortened)
    }
}

#if DEBUG
/// UI tests: how many times the player screen has been drawn (its body
/// run), read once a second by a view of its own, so reading it doesn't
/// draw the player again.
@MainActor
enum PlayerRenders {
    private(set) static var count = 0
    static func note() { count += 1 }

    struct Readout: View {
        var body: some View {
            TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                let text = String(PlayerRenders.count)
                Text(text)
                    .font(.caption2)
                    .lineLimit(1)
                    .frame(width: 1, height: 1)
                    .opacity(0.02)
                    .accessibilityLabel(text)
                    .accessibilityIdentifier("debug-player-renders")
            }
        }
    }
}
#endif

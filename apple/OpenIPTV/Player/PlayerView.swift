import AVFoundation
import SwiftUI

/// What the full-screen player shows.
enum PlayerItem: Identifiable {
    case live([LiveChannel], Int)
    case vod(EmbyPlayback)

    var id: String {
        switch self {
        case let .live(channels, index): "live-\(channels[index].id)"
        case let .vod(playback): "vod-\(playback.itemId)"
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
            case let .live(channels, index): LivePlayerView(channels: channels, index: index)
            case let .vod(playback): MoviePlayerView(playback: playback)
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
        .onAppear { PlayerOrientation.shared.playerAppeared() }
        .onDisappear { PlayerOrientation.shared.playerDisappeared() }
        #endif
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
    let tracks: [MPVPlayer.Track]
    let pick: (MPVPlayer.Track) -> Void
    let pickSubtitles: (MPVPlayer.Track?) -> Void
    let opened: () -> Void

    static func == (a: Self, b: Self) -> Bool { a.tracks == b.tracks }

    var body: some View {
        let audio = tracks.filter { $0.kind == .audio }
        let subtitles = tracks.filter { $0.kind == .subtitle }
        Menu {
            if audio.count > 1 {
                Section("Audio") {
                    ForEach(audio) { track in
                        Button { pick(track) } label: { item(track) }
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

    @ViewBuilder private func item(_ track: MPVPlayer.Track) -> some View {
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
    @State private var player: MPVPlayer?
    @State private var position: Double = 0
    @State private var duration: Double?
    @State private var paused = false
    @State private var started = false
    @State private var buffering = false
    @State private var error: String?
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    @State private var lastReport: Double = 0
    @State private var scrubbing: Double?
    /// How many fallback streams have been tried after the first failed.
    @State private var attempt = 0
    /// Where a server-converted (HLS) fallback starts, since its clock starts at 0.
    @State private var offset: Double = 0
    /// "Started in …" for a few seconds after the first frame (development
    /// builds with the stats on).
    @State private var timing: String?
    @State private var warmStart = false
    /// The file's audio and subtitle tracks, and the picture's badges ("4K",
    /// "HDR") for the Info panel.
    @State private var tracks: [MPVPlayer.Track] = []
    @State private var badges: [String] = []
    #if os(iOS)
    /// The Info panel, and the picture filling the screen (cropped) rather
    /// than fitting it.
    @State private var showInfo = false
    @State private var filled = false
    @State private var muted = false
    /// The film went on in Picture in Picture: closing here isn't stopping.
    @State private var handedOff = false
    #endif
    #if os(tvOS)
    /// Where the current swipe started from.
    @State private var swipeFrom: Double?
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
    /// Shown briefly when the quality changes.
    @State private var qualityNote: String?
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
    @State private var positionReadout = ""
    /// Debug builds: how it started ("warm 0.3": a player kept or opened
    /// ahead; "cold 2.1": opened on the tap), and where.
    @State private var startReadout = ""
    #endif

    var body: some View {
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
            if let still = stillWhileChoosing {
                Image(uiImage: still)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
            }
            #if os(iOS)
            // Taps on the picture show and hide the controls (a tap on the
            // Info panel's background closes it first). Under the controls:
            // a tap on one of them, the "…" menu too, isn't also one on the
            // picture (that hid the controls, and the menu with them).
            Color.clear
                .contentShape(Rectangle())
                .ignoresSafeArea()
                .onTapGesture { if showInfo { toggleInfo() } else { toggleControls() } }
                .accessibilityHidden(true)
            #endif
            // With the controls up, their play button turns into the spinner.
            if (buffering || !started), error == nil, !controlsVisible {
                ProgressView().controlSize(.large).tint(.white)
            }
            if controlsVisible { controls.transition(.opacity) }
            if let qualityNote, !controlsVisible {
                Text(qualityNote)
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
                debugReadout(positionReadout, "debug-position")
                debugReadout(startReadout, "debug-start")
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
        .task { start() }
        .onAppear {
            PlaybackActivity.began()
            #if DEBUG
            model.debugPlayerUp = true
            #endif
        }
        .onDisappear {
            PlaybackActivity.ended()
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
                       busy: (buffering || !started) && error == nil, bar: transportBar, compact: compact,
                       panel: panel, focus: focus, hasSubtitles: tracks.contains { $0.kind == .subtitle },
                       info: TVPlayerInfo(heading: film ? playback.title : playback.subtitle, overview: playback.overview,
                                          runtime: film ? [playback.subtitle, runtime].compactMap(\.self).joined(separator: " · ") : runtime,
                                          badges: badges),
                       menu: menu)
        #else
        // A film shows its title alone, as in the Apple TV app; an episode
        // its "S1:E3 · Name" over the show.
        PlayerChrome(caption: playback.seriesId == nil ? nil : playback.subtitle, title: playback.title, note: note,
                     paused: paused, busy: (buffering || !started) && error == nil, ready: started,
                     topActions: pictureActions, pills: [PlayerAction(title: "Info") { toggleInfo() }],
                     selectedPill: showInfo ? "Info" : nil, panel: showInfo ? infoPanel : nil,
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
                               badges: badges, actions: actions)
    }

    private func toggleInfo() {
        withAnimation(.snappy(duration: 0.3)) { showInfo.toggle() }
        // Open: the controls stay until it's closed.
        showControls(autoHide: !showInfo)
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
        PictureInPicture.shared.start(player, playback: playback, offset: offset, position: position, total: total, paused: paused,
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
            TrackMenuButton(tracks: tracks, pick: { pick($0) }, pickSubtitles: { pickSubtitles($0) }) {
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

    private func pick(_ track: MPVPlayer.Track) {
        trackSwitched()
        player?.selectAudio(track.id)
        markSelected(track.id, kind: .audio)
        TrackChoice.rememberAudio(track.language, role: track.role, for: trackKey)
        showControls()
    }

    private func pickSubtitles(_ track: MPVPlayer.Track?) {
        trackSwitched()
        player?.selectSubtitle(track?.id)
        markSelected(track?.id, kind: .subtitle)
        TrackChoice.rememberSubtitles(track?.language, role: track?.role, for: trackKey)
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

    #if DEBUG
    /// What the player plays once the choices are in, for UI tests
    /// ("audio=eng subtitles=eng+sdh": a language, then the kind of track).
    private func readTracks() async {
        try? await Task.sleep(for: .milliseconds(500))
        guard let player else { return }
        let playing = await player.tracks()
        let audio = playing.first { $0.kind == .audio && $0.selected }?.language ?? "none"
        let shown = playing.first { $0.kind == .subtitle && $0.selected }
        let subtitles = shown.map { ($0.language ?? "und") + ($0.role.map { "+" + $0 } ?? "") } ?? "off"
        trackReadout = "audio=\(audio) subtitles=\(subtitles)"
    }
    #endif

    /// The tick moves at once (the player confirms on its own queue).
    private func markSelected(_ id: Int?, kind: MPVPlayer.Track.Kind) {
        tracks = tracks.map { track in
            guard track.kind == kind else { return track }
            var marked = track
            marked.selected = track.id == id
            return marked
        }
    }

    /// An error, a quality change, or how fast it started (briefly).
    private var note: (text: String, color: Color)? {
        if let error { return (error, .red) }
        if let qualityNote { return (qualityNote, .yellow) }
        if let timing { return (timing, .white.opacity(0.6)) }
        #if DEBUG
        if prefs.performanceStats, !stats.isEmpty { return (stats, .white.opacity(0.6)) }
        #endif
        return nil
    }

    private var total: Double { duration ?? playback.durationSeconds ?? 0 }

    @ViewBuilder private var scrubber: some View {
        // While scrubbing the picture itself shows where it'll land (no
        // preview box), and a slower drag says its speed at the end.
        #if os(iOS)
        TimeBar(leading: phoneClock(scrubbing ?? position),
                trailing: scrubSpeed ?? "−" + phoneClock(max(0, total - (scrubbing ?? position)))) {
            Scrubber(position: position, total: max(total, 1), scrubbing: $scrubbing, speedLabel: $scrubSpeed,
                     onChanged: { liveScrub($0) }, onCommit: commitScrub)
        }
        #else
        transportBar
        #endif
    }

    #if os(tvOS)
    private var transportBar: TVTransportBar {
        let at = scrubbing ?? position
        let state: TVTransportBar.State = if let holdDirection {
            holdDirection > 0 ? .forward : .backward
        } else if paused, scrubbing == nil {
            .paused
        } else {
            .playing
        }
        return TVTransportBar(fraction: at / max(total, 1), time: clock(at), remaining: "-" + clock(max(0, total - at)), state: state)
    }

    private var menu: TVTrackMenu? {
        switch panel {
        case .audio:
            TVTrackMenu(heading: "Audio Track", rows: audioTracks.map { .init(label: label($0), checked: $0.selected) })
        case .subtitles:
            TVTrackMenu(heading: "Subtitles", rows: [.init(label: "Off", checked: !subtitleTracks.contains(where: \.selected))]
                + subtitleTracks.map { .init(label: label($0), checked: $0.selected) })
        case .speed:
            TVTrackMenu(heading: "Playback Speed", rows: PlaybackSpeed.all.map { .init(label: PlaybackSpeed.name($0), checked: $0 == speed) })
        default:
            nil
        }
    }

    #endif

    /// "From Beginning": the start, playing.
    private func restart() {
        if offset > 0, let bitrate = governor?.current,
           let url = model.convertedURL(for: playback, bitrate: bitrate, start: 0) {
            offset = 0
            player?.load(url, headers: playback.fallbackHeaders, file: false, tracks: playback.tracks)
        } else {
            player?.seek(to: 0, exact: true)
        }
        lastSeek = Date()
        position = 0
        jumpUntil = Date().addingTimeInterval(1.5)
        if paused { player?.setPaused(false) }
    }

    // MARK: Tracks and times (both platforms)

    /// "07:48" under an hour, "1:52:07" over, as Apple's player writes it.
    private func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

    /// "10 min", "1 hr 52 min".
    private var runtime: String? {
        guard total > 0 else { return nil }
        let minutes = Int((total / 60).rounded())
        guard minutes >= 60 else { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) hr" : "\(minutes / 60) hr \(minutes % 60) min"
    }

    private var audioTracks: [MPVPlayer.Track] { tracks.filter { $0.kind == .audio } }
    private var subtitleTracks: [MPVPlayer.Track] { tracks.filter { $0.kind == .subtitle } }

    /// iPhone, as the Apple TV app writes it: "0:00:03" when the film runs
    /// an hour or more, "4:05" otherwise.
    private func phoneClock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return total >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }

    private func label(_ track: MPVPlayer.Track) -> String { Self.label(track) }

    /// "English", "English (Commentary)", "Spanish 5.1", "French (Forced)".
    static func label(_ track: MPVPlayer.Track) -> String {
        let language = track.language.flatMap { $0 == "und" ? nil : Locale.current.localizedString(forLanguageCode: $0) }
        var text: String
        if let title = track.title, !title.isEmpty {
            if let language, !title.localizedCaseInsensitiveContains(language) {
                text = "\(language) (\(title))"
            } else {
                text = title
            }
        } else {
            text = language ?? "Unknown language"
            if track.kind == .audio, let channels = track.channels {
                switch channels {
                case 6: text += " 5.1"
                case 8: text += " 7.1"
                default: break
                }
            }
        }
        if track.forced { text += " (Forced)" }
        // Two tracks in one language told apart (the file's flag, no title).
        if track.hearingImpaired, !text.localizedCaseInsensitiveContains("SDH") { text += " SDH" }
        return text
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

    /// The preview still for where a jump would land, while the player's
    /// own picture is still on its way there.
    private var stillWhileChoosing: UIImage? {
        guard let target = scrubbing, let thumbnails else { return nil }
        if let shown = previewShown, abs(shown - (target - offset)) < 2 { return nil }
        return thumbnails.image(near: target)
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
        // UI tests (OPENREEL_DEBUG_NOTE_AFTER=seconds): a quality note then.
        if let after = ProcessInfo.processInfo.environment["OPENREEL_DEBUG_NOTE_AFTER"].flatMap(Double.init) {
            Task {
                try? await Task.sleep(for: .seconds(after))
                note("Lower quality for a smoother picture")
            }
        }
        #endif
        if let (warmPlayer, _) = model.takeWarm(playback.itemId, at: playback.startSeconds) {
            // Already open and paused at the resume point: just show and play.
            warmStart = true
            PlaybackAudio.activate()
            warmPlayer.onEvent = { event in handle(event) }
            self.player = warmPlayer
            if warmPlayer.hasStarted { handle(.started(0)) }
            // Now it's being watched: download the rest of it.
            warmPlayer.setReadahead(NetworkStatus.shared.fileReadahead)
            warmPlayer.setPaused(false)
        } else {
            // A player warmed up for something else would only compete for
            // the connection.
            model.coolDown()
            let player = makePlayer(prefs: prefs)
            player.onEvent = { event in handle(event) }
            self.player = player
            // Always the original file first: it's on screen in about a
            // second, while a server-converted version takes 5-15 s to
            // begin (and every seek restarts it). Quality only drops if the
            // original actually stalls.
            player.load(playback.url, headers: playback.headers, start: playback.startSeconds, file: true,
                        readahead: NetworkStatus.shared.fileReadahead, tracks: playback.tracks)
        }
        if governor == nil, prefs.adaptiveQuality { governor = QualityGovernor(original: playback.bitrate) }
        showControls()
        probeTask = Task { await probeWhileConverted() }
    }

    #if os(iOS)
    /// The player from Picture in Picture, drawing on this screen again.
    private func adopt(_ back: (player: MPVPlayer, offset: Double, position: Double, paused: Bool)) {
        PlaybackAudio.activate()
        offset = back.offset
        position = back.position
        paused = back.paused
        started = true
        startedOnce = true
        warmStart = true
        back.player.onEvent = { event in handle(event) }
        player = back.player
        trackSwitched()
        back.player.drawOnScreen()
        if governor == nil, prefs.adaptiveQuality, offset == 0 { governor = QualityGovernor(original: playback.bitrate) }
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
            guard let (bytes, response) = try? await HTTP.ahead.bytes(for: request),
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
            guard let url = model.convertedURL(for: playback, bitrate: bitrate, start: at) else { return }
            offset = at
            player.load(url, headers: playback.fallbackHeaders, file: false, tracks: playback.tracks)
            note("Lower quality to keep playing smoothly")
        case .original:
            revertTo = lastConverted
            offset = 0
            player.load(playback.url, headers: playback.headers, start: at, file: true,
                        readahead: NetworkStatus.shared.fileReadahead, tracks: playback.tracks)
            note("Back to full quality")
        }
    }

    /// Shows a timing under the title for a few seconds.
    private func showTiming(_ text: String, for seconds: Double) {
        timing = text
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if timing == text { timing = nil }
        }
    }

    /// A quality change or a short message: a small note at the top for a
    /// few seconds (it brought up every control for four seconds mid-film).
    private func note(_ text: String) {
        withAnimation(.easeOut(duration: 0.2)) { qualityNote = text }
        Task {
            try? await Task.sleep(for: .seconds(4))
            if qualityNote == text { withAnimation(.easeIn(duration: 0.3)) { qualityNote = nil } }
        }
    }

    private func handle(_ event: MPVPlayer.Event) {
        switch event {
        case let .started(playerSeconds):
            started = true
            buffering = false
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
            #endif
            Task { await loadTrackInfo() }
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
            #if DEBUG
            NSLog("%@", "PERF buffering \(isBuffering)")
            #endif
            // A stall: drop quality straight away rather than wait it out.
            // Not waiting for data just after a jump (or while choosing),
            // which used to drop a film to the server-converted version after
            // a few skips, and every skip after that waited for the server.
            if isBuffering, started, scrubbing == nil, Date().timeIntervalSince(lastSeek) > 3,
               let decision = governor?.observe(buffer: 0, bytesPerSecond: 0, stalled: true) {
                apply(decision)
            }
        case let .network(buffer, bytesPerSecond):
            // Just after a jump the buffer is refilling: not a slow connection.
            if started, !paused, scrubbing == nil, Date().timeIntervalSince(lastSeek) > 3,
               let decision = governor?.observe(buffer: buffer, bytesPerSecond: bytesPerSecond, stalled: false) {
                apply(decision)
            }
            #if DEBUG
            NSLog("%@", String(format: "PERF net %.1f Mbps buffer %.1f s at %.1f", bytesPerSecond * 8 / 1e6, buffer, position))
            let quality = governor?.current.map { String(format: "converted %.1f Mbps", Double($0) / 1e6) } ?? "original"
            if quality != qualityReadout { qualityReadout = quality }
            positionReadout = String(format: "%.1f %@", position, paused ? "paused" : "playing")
            let file = playback.bitrate.map { String(format: "file %.1f Mbps", Double($0) / 1e6) } ?? "file bitrate ?"
            stats = String(format: "%@ · %@ · speed %.1f Mbps · %.0f s buffered", quality, file,
                           (governor?.speed ?? bytesPerSecond * 8) / 1e6, buffer)
            #endif
        case let .failed(message):
            // Back to full quality didn't open: carry on at the lower one.
            if started, let bitrate = revertTo, let url = model.convertedURL(for: playback, bitrate: bitrate, start: position) {
                revertTo = nil
                governor?.revert(to: bitrate)
                offset = position
                player?.load(url, headers: playback.fallbackHeaders, file: false, tracks: playback.tracks)
                note("Staying at lower quality")
                return
            }
            // A converted version the server won't make: go back to the
            // original and stop adapting.
            if started, governor?.current != nil {
                governor = nil
                offset = 0
                player?.load(playback.url, headers: playback.headers, start: position, file: true, tracks: playback.tracks)
                note("Couldn't lower the quality; playing the original")
                return
            }
            if !started, attempt < playback.fallbacks.count {
                // The original didn't open; try the next way Emby offers.
                let next = playback.fallbacks[attempt]
                attempt += 1
                let converted = next.path().hasSuffix(".m3u8")
                offset = converted ? (playback.startSeconds ?? 0) : 0
                player?.load(next, headers: playback.fallbackHeaders, start: converted ? nil : playback.startSeconds, file: !converted,
                              tracks: playback.tracks)
                return
            }
            error = "Couldn't play: \(message)"
            showControls(autoHide: false)
            // Say why: how the server answered each way of opening it.
            Task {
                let why = await model.diagnose(playback)
                if !why.isEmpty, error != nil { error = "Couldn't play. \(why)" }
            }
        case let .time(rawPosition, newDuration):
            if let newDuration, offset == 0 { duration = newDuration }
            if let until = jumpUntil {
                guard Date() >= until else { return }
                jumpUntil = nil
            }
            let newPosition = rawPosition + offset
            position = newPosition
            // Into the last fifth of an episode: the next one, ready.
            if !preparedNext, playback.seriesId != nil, total > 0, newPosition >= total * 0.8 {
                preparedNext = true
                model.prepareNext(after: playback)
            }
            // Not while choosing where to jump: the picture's previews
            // aren't where the viewer is.
            if abs(newPosition - lastReport) >= 10, scrubbing == nil {
                lastReport = newPosition
                Task { await model.report(playback, seconds: newPosition, event: .progress) }
            }
        case let .paused(isPaused):
            paused = isPaused
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
            close()
        case let .previewShown(seconds):
            previewShown = seconds
        case .window:
            break
        }
    }

    private func finish() {
        hideTask?.cancel()
        probeTask?.cancel()
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
            if started, offset == 0, error == nil { model.park(player, playback.resuming(at: seconds)) } else { player.shutdown() }
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

    private func showPreview(_ target: Double, exact: Bool) {
        player?.follow(to: max(0, target - offset), exact: exact)
        lastSeek = Date()
    }

    /// On release: carry on from the picture on screen, which is already
    /// where it was chosen (no second jump, so it plays at once). Only when
    /// the picture is a moment behind, jump: to the keyframe before the
    /// target, which plays without decoding up to the second (exact when
    /// scrubbing slowly on iPhone).
    private func commitScrub(_ target: Double) {
        settleSeek?.cancel()
        // Carries on from the picture on screen when it's already there (no
        // second jump); otherwise one jump, replacing any preview still on
        // its way, so nothing lands after letting go.
        player?.settle(at: max(0, target - offset), exact: scrubSpeed != nil)
        lastSeek = Date()
        position = target
        jumpUntil = Date().addingTimeInterval(0.5)
        scrubbing = nil
        scrubOrigin = nil
        if resumeAfterScrub {
            resumeAfterScrub = false
            player?.setPaused(false)
        }
        showControls()
    }

    #if os(tvOS)
    /// The Siri Remote, as in Apple's player:
    /// - click left or right: back or forward 10 seconds, straight away;
    /// - hold left or right: rewind or fast-forward, faster the longer it's
    ///   held, jumping there on release;
    /// - swipe across the touch surface: the picture pauses and follows to
    ///   where it would jump; click to play from there, Menu to stay;
    /// - click the centre or Play/Pause: pause or play;
    /// - up: the round buttons (subtitles, audio, speed), whose menus open with a
    ///   click; down: the Info panel and "From Beginning";
    /// - Menu: close a menu or the panel, stop choosing, hide the controls,
    ///   then leave.
    private func remote(_ input: TVRemoteSurface.Input) {
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
            focus = .fromBeginning
            showControls(autoHide: false)
        case .select, .playPause:
            if let target = scrubbing {
                commitScrub(target)
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

    /// On the round buttons: left and right between them, a click opens
    /// its menu, down or Menu back to the bar.
    private func onButtons(_ input: TVRemoteSurface.Input) {
        switch input {
        case let .click(direction):
            let buttons: [TVPlayerFocus] = (subtitleTracks.isEmpty ? [] : [.subtitles]) + [.audio, .speed]
            guard let at = buttons.firstIndex(of: focus) else { return }
            let next = buttons[min(max(at + (direction < 0 ? -1 : 1), 0), buttons.count - 1)]
            guard next != focus else { return }
            // Off the button: a menu asked for there no longer opens.
            menuRequest += 1
            focus = next
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
        let rows = menu?.rows.count ?? 0
        let button = Self.button(for: open)
        switch (open, input) {
        case (.info, .select):
            restart()
            panel = nil
            backToBar()
        case (.info, .up), (.info, .menu):
            panel = nil
            backToBar()
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
            var fresh: [MPVPlayer.Track]?
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
        let trackKind: MPVPlayer.Track.Kind = kind == .audio ? .audio : .subtitle
        let list = tracks.filter { $0.kind == trackKind }
        let id: Int?
        trackSwitched()
        if kind == .audio {
            guard list.indices.contains(row) else { return }
            id = list[row].id
            player.selectAudio(list[row].id)
            TrackChoice.rememberAudio(list[row].language, role: list[row].role, for: trackKey)
        } else {
            let track = row > 0 && list.indices.contains(row - 1) ? list[row - 1] : nil
            id = track?.id
            player.selectSubtitle(id)
            TrackChoice.rememberSubtitles(track?.language, role: track?.role, for: trackKey)
        }
        tracks = tracks.map { track in
            guard track.kind == trackKind else { return track }
            var marked = track
            marked.selected = track.id == id
            return marked
        }
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
            player?.seek(to: max(0, origin - offset), exact: true)
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

    /// Back or forward 10 s, straight away: the bar moves at once, and the
    /// picture follows from the nearest keyframe past the ten seconds.
    private func skip(_ seconds: Double) {
        guard started else { return }
        player?.seek(by: seconds, exact: false)
        lastSeek = Date()
        position = min(max(position + seconds, 0), max(total, 1))
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

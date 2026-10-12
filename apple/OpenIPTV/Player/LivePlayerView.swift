import SwiftUI

/// Full-screen live TV. Everything since tuning in is kept (on disk), so
/// any channel can be paused, rewound and scrubbed back, and LIVE jumps to
/// the newest picture. Channels the provider records can start the current
/// show over, and their guide plays earlier ones.
/// iPhone: glass buttons and vertical swipes change channel. Apple TV:
/// swipe up/down to change channel, left/right for 10 s, Play/Pause, Menu
/// closes.
struct LivePlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(Preferences.self) private var prefs
    @Environment(\.dismiss) private var dismiss

    let channels: [LiveChannel]
    @State var index: Int
    @State private var loadTask: Task<Void, Never>?
    @State private var player: MPVPlayer?
    @State private var timing = "Starting…"
    @State private var started = false
    @State private var buffering = false
    @State private var paused = false
    @State private var error: String?
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?
    /// Where playback is, in the stream's own seconds.
    @State private var position: Double?
    /// What's kept to jump back into, in the same seconds.
    @State private var window: Window?
    /// Playing at the live edge (not paused or rewound). Meanwhile the gap
    /// to the newest data received is what "live" is on this stream.
    @State private var following = true
    @State private var liveGap: Double = 0
    @State private var scrubbing: Double?
    @State private var scrubSpeed: String?
    @State private var lastScrubSeek = Date.distantPast
    /// A recorded programme playing from its start instead of live.
    @State private var recording: Programme?
    @State private var showGuide = false
    @State private var showMore = false
    /// Zapping quickly: the screen changes at once, and the stream opens
    /// once the presses stop (the provider allows one stream at a time).
    @State private var lastStep = Date.distantPast
    /// "Started in 0.6 s" shows until then.
    @State private var timingUntil = Date.distantPast
    /// Copies of this channel already tried (the provider often lists one
    /// channel several times; if one won't start, the next is tried).
    @State private var tried: Set<String> = []

    struct Window: Equatable {
        var start: Double
        var end: Double
        var seekable: Bool
    }

    private var channel: LiveChannel { model.current(channels[index]) }
    /// "TLC" rather than "US: TLC HD".
    private var displayName: String { model.title(of: channel) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoSurface(player: player)
                    .ignoresSafeArea()
                    .accessibilityElement()
                    .accessibilityLabel(displayName)
                    .accessibilityHint("Shows the player controls")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { showControls() }
                    .accessibilityAction(.escape) { dismiss() }
            }
            if !controlsVisible { picture.ignoresSafeArea() }
            // With the controls up, their play button turns into the spinner.
            if (buffering || !started), error == nil, !controlsVisible {
                ProgressView().controlSize(.large).tint(.white)
            }
            if controlsVisible { controls.transition(.opacity) }
        }
        #if os(iOS)
        .statusBarHidden(!controlsVisible)
        .sheet(isPresented: $showGuide) {
            ChannelGuideSheet(channel: channel, playing: recording, onWatch: watch, onLive: { play() })
                .presentationDetents([.medium, .large])
        }
        #else
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .up: step(-1)
            case .down: step(1)
            case .left: skip(-10)
            case .right: skip(10)
            default: showControls()
            }
        }
        .onPlayPauseCommand { error == nil ? togglePause() : play() }
        .onExitCommand { dismiss() }
        #endif
        .persistentSystemOverlays(.hidden)
        .task { start() }
        .onDisappear {
            hideTask?.cancel()
            loadTask?.cancel()
            player?.shutdown()
            player = nil
        }
    }

    // MARK: Screen

    /// Minimal, like the streaming apps (see PlayerChrome): what's on and
    /// the channel at the bottom over one bar (everything kept since tuning
    /// in, or the whole recording) with LIVE beside it; rotate and a "…"
    /// menu (guide, start over, channels) at the top. Swipe up or down on
    /// the picture to change channel.
    private var controls: some View {
        let info = model.nowNext[channel.id]
        let event = recording == nil ? model.event(of: channel) : nil
        return PlayerChrome(caption: caption(info: info, event: event), title: heading(info: info, event: event),
                            note: note, paused: paused, canGoForward: !(recording == nil && atLive),
                            busy: (buffering || !started) && error == nil, ready: started,
                            close: { dismiss() }, back: { skip(-10) },
                            playPause: { error == nil ? togglePause() : retry() }, forward: { skip(10) }) {
            #if os(iOS)
            more(info: info)
            #endif
        } accessory: {
            if started, error == nil { liveButton }
        } bar: {
            bar
        }
        .background { picture }
    }

    /// Taps and swipes on the picture: the whole screen while the controls
    /// are hidden, behind them otherwise.
    private var picture: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture { toggleControls() }
            #if os(iOS)
            .gesture(
                DragGesture(minimumDistance: 40).onEnded { value in
                    guard abs(value.translation.height) > abs(value.translation.width) else { return }
                    step(value.translation.height < 0 ? 1 : -1)
                }
            )
            #endif
            .accessibilityHidden(true)
    }

    /// The small line over the title: the channel, a game's league and
    /// start, or when a recording started.
    private func caption(info: NowNext?, event: LiveOrganizer.Event?) -> String? {
        if let recording { return "\(displayName) · from \(recording.start.clock)" }
        if let event {
            let start = event.start.map { ($0 <= Date() ? "Started " : "Starts ") + $0.formatted(date: .omitted, time: .shortened) }
            return [event.league, start].compactMap { $0 }.joined(separator: " · ")
        }
        return info?.now == nil ? nil : displayName
    }

    /// What's on (or the game, or the recording); the channel when the
    /// guide has nothing.
    private func heading(info: NowNext?, event: LiveOrganizer.Event?) -> String {
        if let recording { return recording.title }
        if event != nil { return displayName }
        return info?.now?.title ?? displayName
    }

    /// An error; how far behind; how fast it started, briefly. Paused shows
    /// on the play button, not here too.
    private var note: (text: String, color: Color)? {
        if let error { return (error, .red) }
        if recording == nil, !atLive || (paused && behind >= 3) { return (status, .white.opacity(0.75)) }
        if started, Date() < timingUntil { return (timing, .white.opacity(0.6)) }
        return nil
    }

    private var status: String {
        if let recording { return "From the start · \(recording.start.clock)" }
        if paused || !atLive { return "\(Self.time(behind)) behind live" }
        return timing
    }

    /// LIVE, before the caption like the Apple TV app's: red at the live
    /// picture, grey when behind (or watching a recording), and on iPhone a
    /// tap catches up.
    @ViewBuilder private var liveButton: some View {
        let live = recording == nil && atLive
        let badge = Text("LIVE")
            .font(.caption.weight(.heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(live ? Color.red : Color.white.opacity(0.3), in: .capsule)
        #if os(iOS)
        // At live there's nothing to catch up on: no seek.
        Button { if !live { goLive() } } label: {
            badge
                .padding(.vertical, 8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -8)
        .accessibilityLabel(live ? "Live" : "Go to live")
        #else
        badge
        #endif
    }

    /// The scrubber: everything kept since tuning in (or the recording),
    /// with where it starts and how far behind live.
    @ViewBuilder private var bar: some View {
        #if os(iOS)
        if started, error == nil, let span, let position {
            TimeBar(leading: leftLabel, trailing: scrubSpeed ?? rightLabel) {
                Scrubber(position: position - span.lower, total: span.upper - span.lower,
                         scrubbing: $scrubbing, speedLabel: $scrubSpeed,
                         onChanged: scrubMoved, onCommit: scrubEnded)
            }
        } else {
            TimeBar(leading: "", trailing: "") {
                Capsule().fill(.white.opacity(0.25)).frame(height: 4).frame(maxWidth: .infinity)
            }
        }
        #else
        if started, error == nil, let span, let position {
            TVTransportBar(fraction: (position - span.lower) / max(span.upper - span.lower, 1),
                           time: leftLabel, remaining: rightLabel, paused: paused)
        } else {
            TVTransportBar(fraction: 0, time: "", remaining: "", paused: false)
        }
        #endif
    }

    #if os(iOS)
    private func more(info: NowNext?) -> some View {
        GlassIconButton(systemName: "ellipsis", label: "More", size: 44) {
            showMore = true
            showControls(autoHide: false)
        }
        .confirmationDialog(displayName, isPresented: $showMore, titleVisibility: .hidden) {
            Button("Guide") { showGuide = true }
            if recording == nil, channel.archiveDays != nil, let now = info?.now {
                Button("Start Over") { watch(now) }
            }
            if recording != nil {
                Button("Back to Live") { play() }
            }
            Button("Previous Channel") { step(-1) }
            Button("Next Channel") { step(1) }
        }
    }
    #endif

    private var leftLabel: String {
        guard let span, let position else { return "" }
        let at = scrubbing.map { span.lower + $0 } ?? position
        if recording != nil { return Self.time(at - span.lower) }
        // The clock time of what's on screen, like the Apple TV app's.
        return Date().addingTimeInterval(-behind(at)).formatted(date: .omitted, time: .shortened)
    }

    private var rightLabel: String {
        guard let span, let position else { return "" }
        let at = scrubbing.map { span.lower + $0 } ?? position
        if recording != nil { return "−" + Self.time(max(0, span.upper - at)) }
        // At live the LIVE button says so; the bar's end stays blank.
        let gap = behind(at)
        return gap >= 3 ? "−" + Self.time(gap) : ""
    }

    // MARK: Where "live" is

    /// The newest picture: the newest data received, less the gap this
    /// stream plays at.
    private var liveTarget: Double? {
        window.map { max($0.start, $0.end - max(liveGap, 1)) }
    }

    /// Seconds behind live at `at` (the current position by default).
    private func behind(_ at: Double? = nil) -> Double {
        guard let window, let at = at ?? position else { return 0 }
        if at == position, following { return 0 }
        return max(0, window.end - at - liveGap)
    }

    private var behind: Double { behind() }
    private var atLive: Bool { recording == nil && behind < 3 }

    /// What the bar spans, in stream seconds: everything kept, up to live;
    /// or the whole recording.
    private var span: (lower: Double, upper: Double)? {
        if let recording {
            // Its length from the guide: read straight through, the
            // player's own estimate only covers what's downloaded so far.
            return (0, max(Double(recording.stop - recording.start), 1))
        }
        guard let window, let liveTarget else { return nil }
        return (window.start, max(liveTarget, window.start + 1))
    }

    /// Keeps a jump where there's something to play: within what's kept,
    /// unless the server can jump anywhere in a recording.
    private func reachable(_ target: Double) -> Double {
        var target = target
        if let span { target = min(max(target, span.lower), span.upper) }
        if let window, !(recording != nil && window.seekable) {
            let upper = recording == nil ? (liveTarget ?? window.end) : max(window.start, window.end - 1)
            target = min(max(target, window.start), upper)
        }
        return target
    }

    // MARK: Playing

    private func start() {
        let player = makePlayer(prefs: prefs)
        player.onEvent = { event in handle(event) }
        self.player = player
        play()
    }

    /// Live, after `delay` seconds (zapping quickly).
    private func play(after delay: Double = 0) {
        reset()
        recording = nil
        tried = [channel.id]
        open(channel, after: delay)
        showAround()
        showControls()
    }

    /// Opens one copy of the channel.
    private func open(_ copy: LiveChannel, after delay: Double = 0) {
        loadTask?.cancel()
        loadTask = Task {
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
            }
            do {
                let stream = try await model.playable(copy)
                guard !Task.isCancelled else { return }
                player?.load(stream.url, headers: stream.headers)
            } catch {
                guard !Task.isCancelled else { return }
                if !fallBack() { fail(SourceError.wrap(error).localizedDescription) }
            }
        }
    }

    /// The next copy of this channel, if one hasn't been tried; false when
    /// there's none left.
    private func fallBack() -> Bool {
        guard recording == nil, !started,
              let next = model.copies(of: channel).first(where: { !tried.contains($0.id) }) else { return false }
        tried.insert(next.id)
        timing = "Trying another copy…"
        open(next)
        return true
    }

    private func showAround() {
        // What's on here and either side, so zapping shows it at once.
        let around = [-1, 0, 1].map { model.current(channels[(index + $0 + channels.count) % channels.count]) }
        Task { await model.ensureNowNext(around) }
    }

    /// A recorded programme from its start.
    private func watch(_ programme: Programme) {
        reset()
        recording = programme
        let channel = channel
        loadTask?.cancel()
        loadTask = Task {
            do {
                let stream = try await model.catchup(channel, programme: programme)
                guard !Task.isCancelled else { return }
                player?.load(stream.url, headers: stream.headers, sequential: true)
            } catch {
                guard !Task.isCancelled else { return }
                fail(SourceError.wrap(error).localizedDescription)
            }
        }
        showControls()
    }

    private func retry() {
        if let recording { watch(recording) } else { play() }
    }

    private func reset() {
        if paused { player?.setPaused(false) }
        timing = "Starting…"
        started = false
        buffering = false
        error = nil
        position = nil
        window = nil
        following = true
        liveGap = 0
        scrubbing = nil
    }

    private func handle(_ event: MPVPlayer.Event) {
        switch event {
        case let .started(seconds):
            started = true
            buffering = false
            // Development builds with the stats on.
            if prefs.performanceStats {
                timing = String(format: "Started in %.1f s", seconds)
                timingUntil = Date().addingTimeInterval(3)
            }
            if controlsVisible { showControls() }
        case let .buffering(isBuffering):
            buffering = isBuffering
        case let .paused(isPaused):
            paused = isPaused
        case let .time(now, _):
            guard abs(now - (position ?? -10)) >= 0.25 else { return }
            position = now
            track()
        case let .window(start, end, seekable):
            window = Window(start: start, end: end, seekable: seekable)
            track()
        case let .failed(message):
            if !fallBack() { fail("Couldn't play: \(message)") }
        case .ended:
            // A recording finished, or the provider closed the stream (a long
            // pause can outlast what it holds): carry on live.
            if started { play() } else if !fallBack() { fail("The channel stopped before it started.") }
        default:
            break
        }
    }

    /// While following live, remember how far behind the newest data this
    /// stream plays; once rewound, notice catching up with it again.
    private func track() {
        guard started, recording == nil, scrubbing == nil, let window, let position else { return }
        let gap = window.end - position
        if following {
            liveGap = max(0, gap)
        } else if !paused, gap - liveGap < 1.5 {
            following = true
        }
    }

    // MARK: Moving around

    private func jump(to target: Double) {
        let target = reachable(target)
        player?.seek(to: target, exact: true)
        position = target
        if recording == nil, let liveTarget { following = !paused && target >= liveTarget - 1 }
    }

    private func skip(_ seconds: Double) {
        guard started, let position else { return showControls() }
        if seconds < 0 { following = false }
        jump(to: position + seconds)
        showControls()
    }

    private func togglePause() {
        guard started else { return }
        if !paused, recording == nil { following = false }
        player?.togglePause()
        showControls()
    }

    private func goLive() {
        if recording != nil { return play() }
        guard let liveTarget else { return }
        if paused { player?.setPaused(false) }
        player?.seek(to: liveTarget, exact: true)
        position = liveTarget
        following = true
        showControls()
    }

    private func scrubMoved(_ value: Double) {
        guard let span else { return }
        following = false
        showControls(autoHide: false)
        guard Date().timeIntervalSince(lastScrubSeek) > 0.15 else { return }
        lastScrubSeek = Date()
        player?.seek(to: reachable(span.lower + value), exact: false)
    }

    private func scrubEnded(_ value: Double) {
        guard let span else { return }
        scrubbing = nil
        jump(to: span.lower + value)
        showControls()
    }

    /// Nothing to watch, so the controls (and the way out) stay up.
    private func fail(_ message: String) {
        error = message
        showControls()
    }

    private func step(_ delta: Int) {
        index = (index + delta + channels.count) % channels.count
        let quick = Date().timeIntervalSince(lastStep) < 0.8
        lastStep = Date()
        play(after: quick ? 0.35 : 0)
    }

    private func toggleControls() {
        if controlsVisible {
            hideTask?.cancel()
            withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = false }
        } else {
            showControls()
        }
    }

    /// Shows the controls; they hide themselves only once video is playing
    /// (not while paused, behind live or scrubbing).
    private func showControls(autoHide: Bool = true) {
        hideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = true }
        guard autoHide, started, error == nil, !paused else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, started, error == nil, !paused, scrubbing == nil, !showGuide, !showMore else { return }
            withAnimation(.easeInOut(duration: 0.3)) { controlsVisible = false }
        }
    }

    static func time(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

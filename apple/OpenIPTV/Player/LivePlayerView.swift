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
    /// Zapping quickly: the screen changes at once, and the stream opens
    /// once the presses stop (the provider allows one stream at a time).
    @State private var lastStep = Date.distantPast

    struct Window: Equatable {
        var start: Double
        var end: Double
        var seekable: Bool
    }

    private var channel: LiveChannel { model.current(channels[index]) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoSurface(player: player)
                    .ignoresSafeArea()
                    .accessibilityElement()
                    .accessibilityLabel(channel.name)
                    .accessibilityHint("Shows the player controls")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { showControls() }
                    .accessibilityAction(.escape) { dismiss() }
            }
            if !controlsVisible { picture.ignoresSafeArea() }
            if !started && error == nil {
                tuning.transition(.opacity)
            } else if buffering && error == nil {
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

    /// While a channel opens: its logo, name and what's on, straight away.
    private var tuning: some View {
        let showing = recording ?? model.nowNext[channel.id]?.now
        return VStack(spacing: 10) {
            ChannelLogo(url: channel.logo, name: channel.name)
            Text(channel.name).font(.title3.weight(.semibold)).lineLimit(1)
            if let showing {
                Text(recording == nil ? showing.title : "\(showing.title) · from the start")
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            ProgressView().tint(.white).padding(.top, 4)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
        .padding(.horizontal, 40)
        .allowsHitTesting(false)
    }

    private var controls: some View {
        VStack {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    #if os(iOS)
                    GlassIconButton(systemName: "xmark", label: "Close player") { dismiss() }
                    #endif
                    VStack(alignment: .leading, spacing: 2) {
                        Text(channel.name).font(.headline).lineLimit(1)
                        Text(error ?? status)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(error == nil ? (recording == nil ? .green : .secondary) : .red)
                            .lineLimit(error == nil ? 1 : 2)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular, in: .capsule)
                    #if os(iOS)
                    GlassIconButton(systemName: "list.bullet.rectangle", label: "Guide") { showGuide = true }
                    GlassIconButton(systemName: "rotate.right", label: "Rotate") { PlayerOrientation.shared.toggle() }
                    if error != nil {
                        GlassIconButton(systemName: "arrow.clockwise", label: "Try again") { retry() }
                    }
                    #endif
                }
            }
            picture
            // Not one glass container: buttons inside a panel's glass there
            // don't get their taps.
            VStack(spacing: 10) {
                    HStack(spacing: 12) {
                        #if os(iOS)
                        GlassIconButton(systemName: "chevron.up", label: "Previous channel", size: 52) { step(-1) }
                        #endif
                        shows
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassEffect(.regular, in: .rect(cornerRadius: 22))
                        #if os(iOS)
                        GlassIconButton(systemName: "chevron.down", label: "Next channel", size: 52) { step(1) }
                        #endif
                    }
                    #if os(iOS)
                    if started, error == nil {
                        transport
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background {
                                Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 22))
                            }
                    }
                    #endif
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    /// Taps and swipes on the picture: the whole screen while the controls
    /// are hidden, the space between them otherwise. Never under the
    /// controls: a tap there would reach it instead of their buttons.
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

    private var status: String {
        if let recording { return "From the start · \(recording.start.clock)" }
        if paused { return behind >= 3 ? "Paused · \(Self.time(behind)) behind live" : "Paused" }
        if !atLive { return "\(Self.time(behind)) behind live" }
        return timing
    }

    @ViewBuilder private var shows: some View {
        let info = model.nowNext[channel.id]
        VStack(alignment: .leading, spacing: 4) {
            if let recording {
                Text(recording.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text("Recorded · \(recording.start.clock)–\(recording.stop.clock)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else if let now = info?.now {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(now.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 0)
                    #if os(iOS)
                    if channel.archiveDays != nil {
                        Button { watch(now) } label: {
                            Label("Start over", systemImage: "backward.end.fill")
                                .font(.caption.weight(.semibold))
                                .labelStyle(.titleAndIcon)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.white)
                        .fixedSize()
                    }
                    #endif
                }
                ProgressView(value: now.progress()).tint(.white)
            } else {
                Text(info == nil ? "Loading guide…" : "No guide data").font(.subheadline).foregroundStyle(.secondary)
            }
            if recording == nil, let next = info?.next {
                Text("Next \(next.start.clock) · \(next.title)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            #if os(tvOS)
            Text(error == nil
                 ? "Swipe up or down to change channel · ◀︎ ▶︎ 10 seconds · Play/Pause"
                 : "Press Play to try again · swipe up or down to change channel")
                .font(.caption2).foregroundStyle(.tertiary)
            #endif
        }
    }

    #if os(iOS)
    /// Pause, 10 seconds either way, the bar (everything kept since tuning
    /// in, or the whole recording) and LIVE.
    private var transport: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { skip(-10) } label: { icon("gobackward.10") }
                    .accessibilityLabel("Back 10 seconds")
                Button { togglePause() } label: { icon(paused ? "play.fill" : "pause.fill") }
                    .accessibilityLabel(paused ? "Play" : "Pause")
                Button { skip(10) } label: { icon("goforward.10") }
                    .accessibilityLabel("Forward 10 seconds")
                    .disabled(recording == nil && atLive)
                if let span, let position {
                    Scrubber(position: position - span.lower, total: span.upper - span.lower,
                             scrubbing: $scrubbing, speedLabel: $scrubSpeed,
                             onChanged: scrubMoved, onCommit: scrubEnded)
                } else {
                    Spacer()
                }
                Button(action: goLive) {
                    HStack(spacing: 5) {
                        Circle().fill(atLive ? Color.red : Color.white.opacity(0.55)).frame(width: 7, height: 7)
                        Text("LIVE").font(.caption.weight(.bold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.white.opacity(atLive ? 0 : 0.18), in: .capsule)
                }
                .accessibilityLabel(atLive ? "Live" : "Go to live")
            }
            .padding(.horizontal, -6)
            .font(.title3.weight(.semibold))
            .tint(.white)
            HStack {
                Text(leftLabel)
                Spacer()
                Text(scrubSpeed ?? rightLabel)
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func icon(_ name: String) -> some View {
        Image(systemName: name)
            .frame(width: 36, height: 36)
            .contentShape(Rectangle())
    }
    #endif

    private var leftLabel: String {
        guard let span, let position else { return "" }
        let at = scrubbing.map { span.lower + $0 } ?? position
        if recording != nil { return Self.time(at - span.lower) }
        // The wall-clock time the bar starts at (its end is now).
        let start = Date().addingTimeInterval(-(span.upper - span.lower))
        return "From " + start.formatted(date: .omitted, time: .shortened)
    }

    private var rightLabel: String {
        guard let span, let position else { return "" }
        let at = scrubbing.map { span.lower + $0 } ?? position
        if recording != nil { return "−" + Self.time(max(0, span.upper - at)) }
        let gap = behind(at)
        return gap >= 3 ? "−" + Self.time(gap) : "Live"
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
        let channel = channel
        loadTask?.cancel()
        loadTask = Task {
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
            }
            do {
                let stream = try await model.playable(channel)
                guard !Task.isCancelled else { return }
                player?.load(stream.url, headers: stream.headers)
            } catch {
                guard !Task.isCancelled else { return }
                fail(SourceError.wrap(error).localizedDescription)
            }
        }
        // What's on here and either side, so zapping shows it at once.
        let around = [-1, 0, 1].map { model.current(channels[(index + $0 + channels.count) % channels.count]) }
        Task { await model.ensureNowNext(around) }
        showControls()
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
            timing = String(format: "Started in %.1f s", seconds)
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
            fail("Couldn't play: \(message)")
        case .ended:
            // A recording finished, or the provider closed the stream (a long
            // pause can outlast what it holds): carry on live.
            if started { play() } else { fail("The channel stopped before it started.") }
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
            guard !Task.isCancelled, started, error == nil, !paused, scrubbing == nil, !showGuide else { return }
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

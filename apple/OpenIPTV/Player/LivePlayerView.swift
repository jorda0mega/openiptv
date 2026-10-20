import AVFoundation
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
    @Environment(\.closePlayer) private var closePlayer
    @Environment(\.scenePhase) private var scenePhase

    let channels: [LiveChannel]
    @State var index: Int
    /// A game's channel picked in its Watch On menu: played first, and kept
    /// for the league once it plays.
    var startCopy: LiveChannel? = nil
    @State private var loadTask: Task<Void, Never>?
    @State private var player: MPVPlayer?
    @State private var timing = "Starting…"
    @State private var session = LiveSession<LiveChannel>()
    @State private var frameSeconds = 0.0
    @State private var netWait: Task<Void, Never>?
    /// This player, to ScreenAwake.
    @State private var awakeID = UUID()
    @State private var buffering = false
    @State private var paused = false
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
    /// A recorded programme playing from its start instead of live.
    @State private var recording: Programme?
    @State private var showGuide = false
    @State private var showMore = false
    /// Zapping quickly: the screen changes at once, and the stream opens
    /// once the presses stop (the provider allows one stream at a time).
    @State private var lastStep = Date.distantPast
    /// "Started in 0.6 s" shows until then.
    @State private var timingUntil = Date.distantPast
    /// The copy picked, while the cue says it didn't play.
    @State private var cue: LiveChannel?
    @State private var cueTask: Task<Void, Never>?
    /// Gives up on a copy that sends no picture (see startLimit).
    @State private var startWatch: Task<Void, Never>?
    /// A game: every channel showing it, the one to play first at the top
    /// ("Watch On"); empty for anything else.
    @State private var choices: [AppModel.WatchChoice] = []
    /// Watch On open: iPhone's panel, Apple TV's row (and the card the
    /// remote is on).
    @State private var showWatchOn = false
    @State private var watchOnIndex = 0
    /// A channel picked in Watch On, kept for its league once it plays (a
    /// feed that never starts isn't tried first next time).
    @State private var pendingPick: (choice: AppModel.WatchChoice, league: String)?
    #if DEBUG
    @State private var perf = LivePerf.Watch()
    #endif

    struct Window: Equatable {
        var start: Double
        var end: Double
        var seekable: Bool
    }

    private var channel: LiveChannel { model.current(channels[index]) }
    private var started: Bool { session.hasPicture }
    private var playingCopy: LiveChannel? { session.copy }
    private var error: String? {
        switch session.failure {
        case .notPlaying: notPlaying
        case .ended: "The channel stopped before it started."
        case let .message(text): text
        case nil: nil
        }
    }
    private var loading: Bool { (buffering || session.isLoading) && error == nil }
    private var playingID: String? { error == nil ? playingCopy?.id : nil }
    /// "TLC" rather than "US: TLC HD".
    private var displayName: String { model.title(of: channel) }

    /// Closes the player with its fade.
    private func close() {
        if let closePlayer { closePlayer() } else { dismiss() }
    }

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
                    .accessibilityAction(.escape) { close() }
            }
            if !controlsVisible { picture.ignoresSafeArea() }
            // With the controls up, their play button turns into the spinner.
            if loading, !controlsVisible {
                ProgressView().controlSize(.large).tint(.white)
            }
            if controlsVisible { controls.transition(.opacity) }
            if let cue, let playingCopy { switchCue(cue, playingCopy) }
            #if DEBUG
            debugReadout(playingCopy.map { "\($0.name) tok=\(LivePerf.Token($0).text)" } ?? "", "debug-live-copy")
            debugReadout(session.readout, "debug-live-state")
            debugReadout(perf.failure?.rawValue ?? "none", "debug-live-fail")
            #endif
        }
        #if os(iOS)
        .statusBarHidden(!controlsVisible)
        .sheet(isPresented: $showGuide) {
            ChannelGuideSheet(channel: channel, playing: recording, onWatch: watch, onLive: { play() })
                .presentationDetents([.medium, .large])
        }
        #else
        .focusable()
        // Select on the remote (the picture's own tap reached it only with
        // the controls hidden).
        .onTapGesture { pictureTapped() }
        .onMoveCommand { direction in
            if showWatchOn { return moveInWatchOn(direction) }
            switch direction {
            case .up: step(-1)
            case .down: step(1)
            case .left: skip(-10)
            case .right: skip(10)
            default: showControls()
            }
        }
        .onPlayPauseCommand { error == nil ? togglePause() : play() }
        .onExitCommand { showWatchOn ? closeWatchOn() : close() }
        #endif
        .persistentSystemOverlays(.hidden)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { send(.away(keepsStream: keepsStreamAway)) }
            if phase == .active { send(.back) }
        }
        .task { start() }
        .onAppear {
            PlaybackActivity.began()
            model.playerShown = true
        }
        .onDisappear {
            PlaybackActivity.ended()
            model.playerShown = false
            ScreenAwake.set(awakeID, playing: false)
            hideTask?.cancel()
            loadTask?.cancel()
            startWatch?.cancel()
            netWait?.cancel()
            cueTask?.cancel()
            #if DEBUG
            perf.closed()
            #endif
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
    @ViewBuilder private var controls: some View {
        // This channel's own slot, as the rows read it: the guide filling in
        // for other channels doesn't redraw the player.
        let info = model.slot(channel.id).value
        let event = recording == nil ? model.event(of: channel) : nil
        #if os(tvOS)
        if showWatchOn {
            TVWatchOnRow(choices: choices, playing: playingID, focused: watchOnIndex)
                .transition(.opacity.combined(with: .offset(y: 40)))
        } else {
            chrome(info: info, event: event)
        }
        #else
        chrome(info: info, event: event)
        #endif
    }

    private func chrome(info: NowNext?, event: LiveOrganizer.Event?) -> some View {
        PlayerChrome(caption: caption(info: info, event: event), title: heading(info: info, event: event),
                            note: note, paused: paused, canGoForward: !(recording == nil && atLive),
                            busy: loading, ready: started,
                            pills: livePills, selectedPill: showWatchOn ? "Watch On" : nil,
                            panel: watchOnPanel,
                            close: { close() }, back: { skip(-10) },
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
            #if os(iOS)
            .onTapGesture { pictureTapped() }
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
                           time: leftLabel, remaining: rightLabel, state: paused ? .paused : .playing)
        } else {
            TVTransportBar(fraction: 0, time: "", remaining: "")
        }
        #endif
    }

    /// iPhone: the guide, under the bar like the Apple TV app's pills. A
    /// game on more than one channel: Watch On (Apple TV: under the bar,
    /// Select opens it).
    private var livePills: [PlayerAction] {
        var pills: [PlayerAction] = []
        #if os(iOS)
        pills.append(PlayerAction(title: "Guide") { showGuide = true })
        #endif
        if recording == nil, choices.count > 1 { pills.append(PlayerAction(title: "Watch On") { toggleWatchOn() }) }
        return pills
    }

    private func switchCue(_ picked: LiveChannel, _ open: LiveChannel) -> some View {
        SwitchCue(from: picked, fromName: model.name(of: picked),
                  to: started ? open : nil, toName: started ? model.name(of: open) : nil)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.top, SwitchCue.topClearance)
            .allowsHitTesting(false)
            .transition(.opacity)
    }

    // MARK: Watch On

    /// iPhone: the channels showing the game, as in the Apple TV app's
    /// Episodes panel: the service, then the feed, language and picture;
    /// "Playing" on the one playing. A tap switches to it.
    private var watchOnPanel: PlayerInfoPanel? {
        #if os(iOS)
        guard showWatchOn else { return nil }
        return PlayerInfoPanel(title: "Watch On", meta: "", cards: choices.map { choice in
            let shown = model.watchOnShown(choice, playingCopy: playingID)
            return PlayerCard(id: choice.id, title: choice.label.title, subtitle: shown.line.isEmpty ? nil : shown.line,
                              images: choice.channel.logo.map { [CardImage(url: $0.absoluteString, contain: true)] } ?? [],
                              loading: choice.shows(playingID) && !started,
                              badge: shown.didNotPlay ? .didNotPlay : nil,
                              line: shown.line.isEmpty ? nil : shown.line) { watch(on: choice) }
        }, focus: choices.first { $0.shows(playingCopy?.id) }?.id)
        #else
        return nil
        #endif
    }

    private func toggleWatchOn() {
        if showWatchOn { return closeWatchOn() }
        watchOnIndex = choices.firstIndex { $0.shows(playingCopy?.id) } ?? 0
        withAnimation(.snappy(duration: 0.3 * PlayerMotion.scale)) { showWatchOn = true }
        // Open: the controls stay until it's closed.
        showControls(autoHide: false)
    }

    private func closeWatchOn() {
        withAnimation(.snappy(duration: 0.3 * PlayerMotion.scale)) { showWatchOn = false }
        showControls()
    }

    #if os(tvOS)
    /// Apple TV: left and right along the row, up closes it.
    private func moveInWatchOn(_ direction: MoveCommandDirection) {
        switch direction {
        case .left: watchOnIndex = max(0, watchOnIndex - 1)
        case .right: watchOnIndex = min(choices.count - 1, watchOnIndex + 1)
        case .up: closeWatchOn()
        default: break
        }
    }
    #endif

    /// The channel picked: it plays, and once it does it's first for this
    /// league's games from now on.
    private func watch(on choice: AppModel.WatchChoice) {
        let league = model.event(of: channel)?.league
        withAnimation(.snappy(duration: 0.3 * PlayerMotion.scale)) { showWatchOn = false }
        guard !choice.shows(playingID) else {
            if started, let league { model.pickWatchChoice(choice, league: league) }
            return showControls()
        }
        pendingPick = league.map { (choice, $0) }
        resetScreen()
        recording = nil
        send(.play(choice.channel, feeds: feeds, after: 0, startLimit: startLimit))
        showControls()
    }

    /// The picture's tap (Apple TV: Select): shows or hides the controls.
    /// Apple TV, a game on more than one channel: with the controls up it
    /// opens Watch On, and there plays the card the remote is on.
    private func pictureTapped() {
        #if os(tvOS)
        if showWatchOn {
            if choices.indices.contains(watchOnIndex) { watch(on: choices[watchOnIndex]) }
            return
        }
        if controlsVisible {
            if livePills.contains(where: { $0.title == "Watch On" }) { toggleWatchOn() }
            return
        }
        #endif
        if showWatchOn { return closeWatchOn() }
        toggleControls()
    }

    #if os(iOS)
    private func more(info: NowNext?) -> some View {
        PlayerGlassButton(systemName: "ellipsis", label: "More", size: 44, glyph: 19) {
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
        // A film warmed up in the background would only compete, as would
        // what was fetched ahead for Continue Watching.
        model.coolDown()
        StreamRelay.shared.stopAhead(keeping: nil)
        let player = makePlayer(prefs: prefs)
        player.onEvent = { event, attempt in handle(event, attempt) }
        self.player = player
        #if DEBUG
        perf.player = player
        player.sayLiveConfig()
        NetworkStatus.shared.sayLivePath()
        #endif
        play(copy: startCopy)
        if let startCopy, let choice = choices.first(where: { $0.id == startCopy.id }), let league = model.event(of: channel)?.league {
            pendingPick = (choice, league)
        }
    }

    /// Live, after `delay` seconds (zapping quickly). A game: on the
    /// channel that comes first in Watch On, unless `copy` says which.
    private func play(after delay: Double = 0, copy: LiveChannel? = nil) {
        #if DEBUG
        perf.began()
        #endif
        resetScreen()
        recording = nil
        pendingPick = nil
        choices = model.watchChoices(for: channel)
        let first = copy ?? choices.first?.channel ?? model.liveOrder(of: channel).first ?? channel
        model.noteChannel(channel.id)
        send(.play(first, feeds: feeds, after: delay, startLimit: startLimit))
        showAround()
        showControls()
    }

    private func send(_ input: LiveSession<LiveChannel>.Input) {
        for action in session.handle(input) { run(action) }
    }

    private func run(_ action: LiveSession<LiveChannel>.Action) {
        switch action {
        case let .load(copy, attempt, delay): load(copy, attempt, after: delay)
        case let .loadRecording(attempt): loadRecording(attempt)
        case .stop: stopStream()
        case let .deadline(attempt, limit): watchStart(attempt, limit: limit)
        case .waitForNetwork: waitForNetwork()
        case .clearTimeline:
            position = nil
            window = nil
            following = true
            liveGap = 0
            scrubbing = nil
        case .unpause: if paused { player?.setPaused(false) }
        case .picture: pictureShown()
        case .goLive: play()
        case let .markFailed(copy): model.noteLiveFailure(copy)
        case .markNotPlaying: if model.event(of: channel) != nil { model.noteGameNotPlaying(channel) }
        case let .played(copy):
            model.notePlaying(copy)
            if let pendingPick, pendingPick.choice.shows(copy.id) {
                model.pickWatchChoice(pendingPick.choice, league: pendingPick.league)
            }
            pendingPick = nil
        case let .switching(from):
            cue = from
            announce(WatchOn.switchSentence(from: model.name(of: from), to: nil))
        case let .switched(from, to):
            announce(WatchOn.switchSentence(from: model.name(of: from), to: model.name(of: to)))
            cueTask?.cancel()
            cueTask = Task {
                try? await Task.sleep(for: .seconds(Self.cueSeconds))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.4)) { cue = nil }
            }
        }
    }

    /// Opens one copy of the channel. Regression: a game listed LIVE whose
    /// feed was over (the slot still there) spun forever (see startLimit).
    private func load(_ copy: LiveChannel, _ attempt: Int, after delay: Double) {
        #if DEBUG
        perf.opening(copy, n: session.triedCount, of: feeds.map(\.count).reduce(0, +), delay: delay)
        #endif
        startWatch?.cancel()
        loadTask?.cancel()
        loadTask = Task {
            if delay > 0 {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
            }
            do {
                #if DEBUG
                let asked = CFAbsoluteTimeGetCurrent()
                #endif
                let stream = try await model.playable(copy)
                guard !Task.isCancelled, session.attempt == attempt else { return }
                #if DEBUG
                perf.addressed(in: CFAbsoluteTimeGetCurrent() - asked)
                #endif
                player?.load(stream.url, headers: stream.headers, attempt: attempt)
            } catch {
                guard !Task.isCancelled, session.attempt == attempt else { return }
                let wrapped = SourceError.wrap(error)
                guard let failure = StreamFailure(lookup: wrapped) else { return }
                send(.failed(attempt, reading(failure), shown: .message(wrapped.localizedDescription)))
            }
        }
    }

    private func loadRecording(_ attempt: Int) {
        guard let recording else { return }
        let channel = channel
        startWatch?.cancel()
        loadTask?.cancel()
        loadTask = Task {
            do {
                let stream = try await model.catchup(channel, programme: recording)
                guard !Task.isCancelled, session.attempt == attempt else { return }
                player?.load(stream.url, headers: stream.headers, sequential: true, attempt: attempt)
            } catch {
                guard !Task.isCancelled, session.attempt == attempt else { return }
                send(.failed(attempt, .unknown, shown: .message(SourceError.wrap(error).localizedDescription)))
            }
        }
    }

    private func watchStart(_ attempt: Int, limit: Double) {
        startWatch?.cancel()
        startWatch = Task {
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled, session.attempt == attempt else { return }
            #if DEBUG
            perf.timedOut()
            #endif
            send(.failed(attempt, reading(.no_data), shown: .notPlaying))
        }
    }

    /// Closes the stream (many accounts allow one at a time) and drops what
    /// was on its way to open one.
    private func stopStream() {
        loadTask?.cancel()
        startWatch?.cancel()
        netWait?.cancel()
        #if DEBUG
        perf.closed()
        #endif
        let background = UIApplication.shared.beginBackgroundTask()
        player?.stop { UIApplication.shared.endBackgroundTask(background) }
        guard error != nil else { return }
        cue = nil
        showControls()
    }

    private func waitForNetwork() {
        netWait?.cancel()
        netWait = Task {
            while !NetworkStatus.shared.online {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
            }
            send(.online)
        }
    }

    private func reading(_ failure: StreamFailure) -> StreamFailure {
        NetworkStatus.shared.online ? failure : .offline
    }

    private var keepsStreamAway: Bool {
        #if os(tvOS)
        let onTV = true
        #else
        let onTV = false
        #endif
        let airPlay = AVAudioSession.sharedInstance().currentRoute.outputs.contains { $0.portType == .airPlay }
        return LiveSession<LiveChannel>.keepsStreamAway(airPlay: airPlay, onTV: onTV)
    }

    private var feeds: [[LiveChannel]] {
        choices.isEmpty ? [model.liveOrder(of: channel)] : choices.map(\.channels)
    }

    private func announce(_ sentence: String) {
        AccessibilityNotification.Announcement(sentence).post()
    }

    private func showAround() {
        // What's on here and either side, so zapping shows it at once.
        let around = [-1, 0, 1].map { model.current(channels[(index + $0 + channels.count) % channels.count]) }
        Task { await model.ensureNowNext(around) }
    }

    /// A recorded programme from its start.
    private func watch(_ programme: Programme) {
        #if DEBUG
        perf.closed()
        #endif
        resetScreen()
        recording = programme
        send(.recording)
        showControls()
    }

    private func retry() {
        if let recording { watch(recording) } else { play() }
    }

    private func resetScreen() {
        cueTask?.cancel()
        cue = nil
        timing = "Starting…"
        buffering = false
    }

    private func pictureShown() {
        buffering = false
        ScreenAwake.set(awakeID, playing: !paused)
        #if DEBUG
        perf.started(frame: frameSeconds)
        #endif
        // Development builds with the stats on.
        if prefs.performanceStats {
            timing = String(format: "Started in %.1f s", frameSeconds)
            timingUntil = Date().addingTimeInterval(3)
        }
        if controlsVisible { showControls() }
    }

    private func handle(_ event: MPVPlayer.Event, _ attempt: Int) {
        let current = attempt == session.attempt
        switch event {
        case .opening:
            send(.opening(attempt))
        case let .started(seconds):
            guard current else { return }
            frameSeconds = seconds
            send(.started(attempt))
        case let .buffering(isBuffering):
            guard current else { return }
            buffering = isBuffering
            #if DEBUG
            perf.buffering(isBuffering)
            #endif
        case let .paused(isPaused):
            paused = isPaused
            if started { ScreenAwake.set(awakeID, playing: !isPaused) }
            send(.paused(isPaused))
        case let .time(now, _):
            guard current, abs(now - (position ?? -10)) >= 0.25 else { return }
            position = now
            track()
        case let .window(start, end, seekable):
            guard current else { return }
            window = Window(start: start, end: end, seekable: seekable)
            track()
        case let .failed(message, logged):
            guard current else { return }
            #if DEBUG
            perf.failed()
            #endif
            send(.failed(attempt, reading(logged ?? .unknown), shown: .message("Couldn't play: \(message)")))
        case let .ended(logged):
            guard current else { return }
            #if DEBUG
            perf.ended()
            #endif
            send(.ended(attempt, reading(logged ?? .eof_before_frame)))
        #if DEBUG
        case let .network(buffer, bytesPerSecond):
            guard current else { return }
            perf.network(buffer: buffer, bytesPerSecond: bytesPerSecond, gap: liveGap)
        #endif
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
        guard started, !session.isLoading else { return }
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
        // One jump at a time, the newest next (see MPVPlayer.follow).
        player?.follow(to: reachable(span.lower + value), exact: false)
    }

    private func scrubEnded(_ value: Double) {
        guard let span else { return }
        scrubbing = nil
        jump(to: span.lower + value)
        showControls()
    }

    /// Seconds a copy has to send its first picture once it's asked for. The
    /// provider starts a game's channel on demand: up to 17 s, where a
    /// channel always on sends within 5 s. UI tests:
    /// OPENREEL_DEBUG_LIVE_START_LIMIT.
    private var startLimit: Double {
        #if DEBUG
        if let limit = ProcessInfo.processInfo.environment["OPENREEL_DEBUG_LIVE_START_LIMIT"].flatMap(Double.init) { return limit }
        #endif
        return model.event(of: channel) == nil ? 15 : 25
    }

    private static var cueSeconds: Double {
        #if DEBUG
        if let seconds = ProcessInfo.processInfo.environment["OPENREEL_DEBUG_SWITCH_CUE_SECONDS"].flatMap(Double.init) { return seconds }
        #endif
        return 4
    }

    /// A game or channel that sent no picture on any of its channels.
    private var notPlaying: String {
        model.event(of: channel) != nil ? "This game isn’t playing right now." : "This channel isn’t playing right now."
    }

    private func step(_ delta: Int) {
        showWatchOn = false
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
        withAnimation(.easeOut(duration: 0.12)) { controlsVisible = true }
        guard autoHide, started, error == nil, !paused else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, started, error == nil, !paused, scrubbing == nil, !showGuide, !showMore, !showWatchOn else { return }
            withAnimation(.easeInOut(duration: 0.3)) { controlsVisible = false }
        }
    }

    #if DEBUG
    /// For UI tests: the copy open, and whether it plays.
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

    static func time(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

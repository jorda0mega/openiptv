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

    var body: some View {
        Group {
            switch item {
            case let .live(channels, index): LivePlayerView(channels: channels, index: index)
            case let .vod(playback): MoviePlayerView(playback: playback)
            }
        }
        #if os(iOS)
        .onAppear { PlayerOrientation.shared.playerAppeared() }
        .onDisappear { PlayerOrientation.shared.playerDisappeared() }
        #endif
    }
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
    #if os(tvOS)
    /// Where the current swipe started from.
    @State private var swipeFrom: Double?
    /// Rewinding or fast-forwarding while left or right is held.
    @State private var holdTask: Task<Void, Never>?
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
    #if DEBUG
    /// Debug builds: current quality, measured speed and buffer.
    @State private var stats = ""
    #endif

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoSurface(player: player)
                    .ignoresSafeArea()
                    .accessibilityElement()
                    .accessibilityLabel(playback.title)
                    .accessibilityHint("Shows the player controls")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { showControls() }
                    .accessibilityAction(.escape) { dismiss() }
            }
            // With the controls up, their play button turns into the spinner.
            if (buffering || !started), error == nil, !controlsVisible {
                ProgressView().controlSize(.large).tint(.white)
            }
            if controlsVisible { controls.transition(.opacity) }
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
        .contentShape(Rectangle())
        .onTapGesture { toggleControls() }
        .statusBarHidden(!controlsVisible)
        #endif
        .persistentSystemOverlays(.hidden)
        .task { start() }
        .onDisappear { finish() }
    }

    /// Minimal, like the streaming apps (see PlayerChrome): the episode and
    /// show at the bottom over one bar with the times and rotate.
    private var controls: some View {
        PlayerChrome(caption: playback.subtitle, title: playback.title, note: note, paused: paused,
                     busy: (buffering || !started) && error == nil, ready: started,
                     close: { dismiss() }, back: { skip(-10) },
                     playPause: { player?.togglePause() }, forward: { skip(10) }) {
            EmptyView()
        } bar: {
            scrubber
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
        TimeBar(leading: timeString(scrubbing ?? position),
                trailing: scrubSpeed ?? "-" + timeString(max(0, total - (scrubbing ?? position)))) {
            Scrubber(position: position, total: max(total, 1), scrubbing: $scrubbing, speedLabel: $scrubSpeed,
                     onChanged: { liveScrub($0) }, onCommit: commitScrub)
        }
        #else
        let at = scrubbing ?? position
        let length = max(total, 1)
        TVTransportBar(fraction: at / length, origin: scrubbing == nil ? nil : scrubOrigin.map { $0 / length },
                       time: timeString(at), remaining: "−" + timeString(max(0, total - at)),
                       paused: paused && scrubbing == nil, choosing: scrubbing != nil)
        #endif
    }

    private func start() {
        position = playback.startSeconds ?? 0
        if let (warmPlayer, _) = model.takeWarm(playback.itemId) {
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
                        readahead: NetworkStatus.shared.fileReadahead)
        }
        if governor == nil, prefs.adaptiveQuality { governor = QualityGovernor(original: playback.bitrate) }
        showControls()
        probeTask = Task { await probeWhileConverted() }
    }

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
            guard let (bytes, response) = try? await HTTP.session.bytes(for: request),
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
            player.load(url, headers: playback.fallbackHeaders, file: false)
            note("Lower quality to keep playing smoothly")
        case .original:
            revertTo = lastConverted
            offset = 0
            player.load(playback.url, headers: playback.headers, start: at, file: true,
                        readahead: NetworkStatus.shared.fileReadahead)
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

    private func note(_ text: String) {
        qualityNote = text
        showControls()
        Task {
            try? await Task.sleep(for: .seconds(4))
            if qualityNote == text { qualityNote = nil }
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
            #endif
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
            let quality = governor?.current.map { String(format: "converted %.1f Mbps", Double($0) / 1e6) } ?? "original"
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
                player?.load(url, headers: playback.fallbackHeaders, file: false)
                note("Staying at lower quality")
                return
            }
            // A converted version the server won't make: go back to the
            // original and stop adapting.
            if started, governor?.current != nil {
                governor = nil
                offset = 0
                player?.load(playback.url, headers: playback.headers, start: position, file: true)
                note("Couldn't lower the quality; playing the original")
                return
            }
            if !started, attempt < playback.fallbacks.count {
                // The original didn't open; try the next way Emby offers.
                let next = playback.fallbacks[attempt]
                attempt += 1
                let converted = next.path().hasSuffix(".m3u8")
                offset = converted ? (playback.startSeconds ?? 0) : 0
                player?.load(next, headers: playback.fallbackHeaders, start: converted ? nil : playback.startSeconds, file: !converted)
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
            // Not while choosing where to jump: the picture's previews
            // aren't where the viewer is.
            if abs(newPosition - lastReport) >= 10, scrubbing == nil {
                lastReport = newPosition
                Task { await model.report(playback, seconds: newPosition, event: .progress) }
            }
        case let .paused(isPaused):
            paused = isPaused
            if isPaused { showControls(autoHide: false) } else { showControls() }
        case .ended:
            position = total
            dismiss()
        case .window:
            break
        }
    }

    private func finish() {
        hideTask?.cancel()
        probeTask?.cancel()
        settleSeek?.cancel()
        #if os(tvOS)
        holdTask?.cancel()
        #endif
        if let speed = governor?.speed, speed > 0 { model.knownSpeed = speed }
        let seconds = position
        player?.shutdown()
        player = nil
        Task { await model.report(playback, seconds: seconds, event: .stopped) }
    }

    private func toggleControls() {
        if controlsVisible {
            hideTask?.cancel()
            withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = false }
        } else {
            showControls()
        }
    }

    private func showControls(autoHide: Bool = true) {
        hideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = true }
        guard autoHide, !paused, started, error == nil else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, error == nil else { return }
            withAnimation(.easeInOut(duration: 0.3)) { controlsVisible = false }
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
    /// - swipe on the touch surface: the picture pauses and follows to where
    ///   it would jump; click to play from there, Menu to stay;
    /// - click the centre or Play/Pause: pause or play;
    /// - Menu: stop choosing, then hide the controls, then leave.
    private func remote(_ input: TVRemoteSurface.Input) {
        switch input {
        case let .click(direction):
            guard started else { return }
            if let target = scrubbing {
                preview(target + direction * 10)
            } else {
                skip(direction * 10)
            }
        case let .hold(direction):
            guard started else { return }
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
            if let target = scrubbing { commitScrub(target) }
        case let .swipe(began, distance, ended):
            guard started else { return }
            if began { swipeFrom = scrubbing ?? position }
            guard let from = swipeFrom else { return }
            if distance != 0 { preview(from + Double(distance) * secondsPerPoint) }
            if ended { swipeFrom = nil }
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
                dismiss()
            }
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

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(size > 60 ? .title.weight(.semibold) : size < 40 ? .body.weight(.semibold) : .title3.weight(.semibold))
                .frame(width: size, height: size)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }
}

extension Int64 {
    /// Unix seconds as a short local time, e.g. "9:30 PM".
    var clock: String {
        Date(timeIntervalSince1970: TimeInterval(self)).formatted(date: .omitted, time: .shortened)
    }
}

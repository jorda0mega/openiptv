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
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    try? AVAudioSession.sharedInstance().setActive(true)
    return MPVPlayer(options: prefs.playerProfile.mpvOptions, hardwareDecoding: prefs.hardwareDecoding)
}

// MARK: - Emby movies and episodes

/// Plays an Emby item from its resume point and reports progress back so
/// Continue Watching stays right on every device. iPhone: glass transport
/// controls and a scrubber. Apple TV: left/right seek 10 s, Play/Pause.
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
    /// "Started in …" for a few seconds after the first frame.
    @State private var timing: String?
    @State private var warmStart = false
    /// Scrubbing thumbnails, if the server has them.
    @State private var thumbnails: TrickplayImages?
    /// Apple TV: presses add up into one seek, applied after a short pause.
    @State private var pendingSeek: Task<Void, Never>?
    /// iPhone scrubbing: speed label, and live seeks so the picture follows.
    @State private var scrubSpeed: String?
    @State private var lastLiveSeek = Date.distantPast
    @State private var resumeAfterScrub = false
    /// Where the current scrub started, for "+1:30" / "−0:45".
    @State private var scrubOrigin: Double?
    /// Exact-frame seek once the finger rests.
    @State private var settleSeek: Task<Void, Never>?
    /// Where the last exact-frame preview landed (its data is downloaded).
    @State private var settledAt: Double?
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
        }
        .contentShape(Rectangle())
        .onTapGesture { toggleControls() }
        #if os(iOS)
        .statusBarHidden(!controlsVisible)
        #else
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .left: scrub(by: -10)
            case .right: scrub(by: 10)
            default: break
            }
            showControls()
        }
        .onPlayPauseCommand {
            player?.togglePause()
            showControls()
        }
        .onExitCommand { dismiss() }
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
                     close: { dismiss() }, back: { player?.seek(by: -10) },
                     playPause: { player?.togglePause() }, forward: { player?.seek(by: 10) }) {
            EmptyView()
        } bar: {
            scrubber.overlay(alignment: .topLeading) { scrubPreview }
        }
    }

    /// An error, a quality change, or how fast it started (briefly).
    private var note: (text: String, color: Color)? {
        if let error { return (error, .red) }
        if let qualityNote { return (qualityNote, .yellow) }
        if let timing { return (timing, .white.opacity(0.6)) }
        return nil
    }

    private var total: Double { duration ?? playback.durationSeconds ?? 0 }

    @ViewBuilder private var scrubber: some View {
        TimeBar(leading: timeString(scrubbing ?? position),
                trailing: "-" + timeString(max(0, total - (scrubbing ?? position)))) {
            #if os(iOS)
            Scrubber(position: position, total: max(total, 1), scrubbing: $scrubbing, speedLabel: $scrubSpeed,
                     onChanged: liveScrub, onCommit: commitScrub)
            #else
            ProgressView(value: min(scrubbing ?? position, max(total, 1)), total: max(total, 1))
            #endif
        }
    }

    private func start() {
        position = playback.startSeconds ?? 0
        Task { thumbnails = await model.trickplay(for: playback) }
        if let (warmPlayer, _) = model.takeWarm(playback.itemId) {
            // Already open and paused at the resume point: just show and play.
            warmStart = true
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try? AVAudioSession.sharedInstance().setActive(true)
            warmPlayer.onEvent = { event in handle(event) }
            self.player = warmPlayer
            if warmPlayer.hasStarted { handle(.started(0)) }
            // Now it's being watched: download the rest of it.
            warmPlayer.setReadahead(NetworkStatus.shared.fileReadahead)
            warmPlayer.setPaused(false)
        } else {
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
        Task { await probeWhileConverted() }
    }

    /// While playing a converted version, test the connection every 20 s by
    /// fetching 4 MB of the original, so it can return to full quality.
    private func probeWhileConverted() async {
        while !Task.isCancelled, player != nil || !started {
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
            let begun = Date()
            guard let (data, _) = try? await HTTP.session.data(for: request), data.count > 500_000 else { continue }
            governor?.noteProbe(bitsPerSecond: Double(data.count * 8) / max(Date().timeIntervalSince(begun), 0.05))
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
            showTiming(timing ?? "", for: 5)
            #if DEBUG
            print("PERF start " + (timing ?? ""))
            #endif
            if controlsVisible { showControls() }
            Task { await model.report(playback, seconds: position, event: .started) }
        case let .seeked(seconds):
            showTiming(String(format: "Jumped in %.1f s", seconds), for: 3)
            #if DEBUG
            print(String(format: "PERF seek %.3f", seconds))
            #endif
        case let .buffering(isBuffering):
            buffering = isBuffering
            // A stall: drop quality straight away rather than wait it out.
            if isBuffering, started, let decision = governor?.observe(buffer: 0, bytesPerSecond: 0, stalled: true) {
                apply(decision)
            }
        case let .network(buffer, bytesPerSecond):
            if started, !paused, let decision = governor?.observe(buffer: buffer, bytesPerSecond: bytesPerSecond, stalled: false) {
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
            let newPosition = rawPosition + offset
            position = newPosition
            if let newDuration, offset == 0 { duration = newDuration }
            if abs(newPosition - lastReport) >= 10 {
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

    /// Where a drag or remote presses would land: a thumbnail of that
    /// moment (when the server has them), the time, and how far it jumps.
    @ViewBuilder private var scrubPreview: some View {
        if let target = scrubbing {
            GeometryReader { geo in
                // Slower scrubbing moves second by second, finer than the
                // server's 10-second thumbnails: the picture itself is the
                // preview then.
                let thumb = scrubSpeed == nil ? thumbnails?.image(at: target) : nil
                let width: CGFloat = thumb == nil ? 120 : Layout.scrubPreviewWidth
                let fraction = total > 0 ? min(max(target / total, 0), 1) : 0
                let x = min(max(16 + fraction * (geo.size.width - 32) - width / 2, 0), geo.size.width - width)
                VStack(spacing: 4) {
                    if let thumb {
                        Image(uiImage: thumb)
                            .resizable()
                            .aspectRatio(16 / 9, contentMode: .fill)
                            .frame(width: width, height: width * 9 / 16)
                            .clipShape(.rect(cornerRadius: 10))
                    }
                    Text(timeString(target)).font(.headline.monospacedDigit())
                    if let scrubSpeed {
                        Text(scrubSpeed).font(.caption2).foregroundStyle(.secondary)
                    }
                    let delta = target - (scrubOrigin ?? position)
                    Text((delta < 0 ? "−" : "+") + timeString(abs(delta)))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                .padding(8)
                .frame(width: width + 16)
                .glassEffect(.regular, in: .rect(cornerRadius: 16))
                .offset(x: x - 8, y: -(thumb == nil ? 76 : width * 9 / 16 + 84))
            }
            .allowsHitTesting(false)
        }
    }

    /// While dragging: pause, and move the picture so it follows the finger:
    /// the exact frame when scrubbing slowly or resting, the nearest
    /// keyframe while sweeping fast.
    private func liveScrub(_ target: Double) {
        showControls(autoHide: false)
        if scrubOrigin == nil { scrubOrigin = position }
        if !resumeAfterScrub, !paused {
            resumeAfterScrub = true
            player?.setPaused(true)
        }
        // When the finger rests, show the exact frame at that second (the
        // server's thumbnails are 10 s apart, keyframes several seconds).
        settleSeek?.cancel()
        settleSeek = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            player?.seek(to: max(0, target - offset), exact: true)
            settledAt = target
        }
        // Moving: a few times a second so it keeps up; keyframes only when
        // sweeping at full speed, where a pixel is many seconds anyway.
        guard Date().timeIntervalSince(lastLiveSeek) > 0.12 else { return }
        lastLiveSeek = Date()
        player?.seek(to: max(0, target - offset), exact: scrubSpeed != nil)
    }

    /// On release: land on the exact second and carry on playing.
    private func commitScrub(_ target: Double) {
        settleSeek?.cancel()
        // The exact second when its data is likely here (a short jump, or
        // one the finger rested on); otherwise the keyframe just before it,
        // which plays without downloading and decoding up to the second
        // (a 4K film's jump went from 1.3-2.5 s to well under a second).
        let near = abs(target - (scrubOrigin ?? position)) < 30
        let rested = settledAt.map { abs($0 - target) < 0.5 } ?? false
        player?.seek(to: max(0, target - offset), exact: near || rested, report: true)
        settledAt = nil
        position = target
        scrubbing = nil
        scrubOrigin = nil
        if resumeAfterScrub {
            resumeAfterScrub = false
            player?.setPaused(false)
        }
        showControls()
    }

    /// Apple TV: each press moves the target; the seek happens once the
    /// presses stop, so holding skips far without stuttering.
    private func scrub(by seconds: Double) {
        if scrubOrigin == nil { scrubOrigin = position }
        let target = min(max((scrubbing ?? position) + seconds, 0), max(total, 1))
        scrubbing = target
        pendingSeek?.cancel()
        pendingSeek = Task {
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            // Far jumps land on the keyframe just before (no waiting to
            // download and decode up to the second).
            let near = abs(target - (scrubOrigin ?? position)) < 30
            player?.seek(to: max(0, target - offset), exact: near, report: true)
            position = target
            scrubbing = nil
            scrubOrigin = nil
        }
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

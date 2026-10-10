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
    let item: PlayerItem

    var body: some View {
        switch item {
        case let .live(channels, index): LivePlayerView(channels: channels, index: index)
        case let .vod(playback): MoviePlayerView(playback: playback)
        }
    }
}

struct VideoSurface: UIViewRepresentable {
    let player: MPVPlayer
    func makeUIView(context: Context) -> MPVHostView { MPVHostView(player: player) }
    func updateUIView(_ view: MPVHostView, context: Context) {}
}

@MainActor
private func makePlayer(prefs: Preferences) -> MPVPlayer {
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    try? AVAudioSession.sharedInstance().setActive(true)
    return MPVPlayer(options: prefs.playerProfile.mpvOptions, hardwareDecoding: prefs.hardwareDecoding)
}

// MARK: - Live TV

/// Full-screen live TV. iPhone: glass buttons and vertical swipes change
/// channel. Apple TV: swipe up/down on the remote, Menu closes.
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
    @State private var error: String?
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    private var channel: LiveChannel { channels[index] }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player { VideoSurface(player: player).ignoresSafeArea() }
            if (buffering || !started) && error == nil {
                ProgressView().controlSize(.large).tint(.white)
            }
            if controlsVisible { controls.transition(.opacity) }
        }
        .contentShape(Rectangle())
        .onTapGesture { toggleControls() }
        #if os(iOS)
        .gesture(
            DragGesture(minimumDistance: 40).onEnded { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                step(value.translation.height < 0 ? 1 : -1)
            }
        )
        .statusBarHidden(!controlsVisible)
        #else
        .focusable()
        .onMoveCommand { direction in
            switch direction {
            case .up: step(-1)
            case .down: step(1)
            default: showControls()
            }
        }
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

    private var controls: some View {
        VStack {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    #if os(iOS)
                    GlassIconButton(systemName: "xmark", label: "Close player") { dismiss() }
                    #endif
                    VStack(alignment: .leading, spacing: 2) {
                        Text(channel.name).font(.headline).lineLimit(1)
                        Text(error ?? timing)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(error == nil ? .green : .red)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular, in: .capsule)
                }
            }
            Spacer()
            GlassEffectContainer(spacing: 12) {
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
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder private var shows: some View {
        let info = model.nowNext[channel.id]
        VStack(alignment: .leading, spacing: 4) {
            if let now = info?.now {
                Text(now.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                ProgressView(value: now.progress()).tint(.white)
            } else {
                Text(info == nil ? "Loading guide…" : "No guide data").font(.subheadline).foregroundStyle(.secondary)
            }
            if let next = info?.next {
                Text("Next \(next.start.clock) · \(next.title)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            #if os(tvOS)
            Text("Swipe up or down to change channel").font(.caption2).foregroundStyle(.tertiary)
            #endif
        }
    }

    private func start() {
        let player = makePlayer(prefs: prefs)
        player.onEvent = { event in handle(event) }
        self.player = player
        play()
    }

    private func play() {
        timing = "Starting…"
        started = false
        error = nil
        let channel = channel
        loadTask?.cancel()
        loadTask = Task {
            do {
                let stream = try await model.playable(channel)
                guard !Task.isCancelled else { return }
                player?.load(stream.url, headers: stream.headers)
            } catch {
                self.error = SourceError.wrap(error).localizedDescription
            }
        }
        Task { await model.ensureNowNext([channel]) }
        showControls()
    }

    private func handle(_ event: MPVPlayer.Event) {
        switch event {
        case let .started(seconds):
            started = true
            buffering = false
            timing = String(format: "Started in %.1f s", seconds)
        case let .buffering(isBuffering):
            buffering = isBuffering
        case let .failed(message):
            error = "Couldn't play: \(message)"
        default:
            break
        }
    }

    private func step(_ delta: Int) {
        index = (index + delta + channels.count) % channels.count
        play()
    }

    private func toggleControls() {
        if controlsVisible {
            hideTask?.cancel()
            withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = false }
        } else {
            showControls()
        }
    }

    private func showControls() {
        hideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = true }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) { controlsVisible = false }
        }
    }
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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player { VideoSurface(player: player).ignoresSafeArea() }
            if (buffering || !started) && error == nil {
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
            case .left: player?.seek(by: -10)
            case .right: player?.seek(by: 10)
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

    private var controls: some View {
        VStack {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    #if os(iOS)
                    GlassIconButton(systemName: "xmark", label: "Close player") { dismiss() }
                    #endif
                    VStack(alignment: .leading, spacing: 2) {
                        Text(playback.title).font(.headline).lineLimit(1)
                        if let error {
                            Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
                        } else if let subtitle = playback.subtitle {
                            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassEffect(.regular, in: .capsule)
                }
            }
            Spacer()
            #if os(iOS)
            GlassEffectContainer(spacing: 24) {
                HStack(spacing: 24) {
                    GlassIconButton(systemName: "gobackward.10", label: "Back 10 seconds", size: 56) { player?.seek(by: -10) }
                    GlassIconButton(systemName: paused ? "play.fill" : "pause.fill", label: paused ? "Play" : "Pause", size: 72) {
                        player?.togglePause()
                    }
                    GlassIconButton(systemName: "goforward.10", label: "Forward 10 seconds", size: 56) { player?.seek(by: 10) }
                }
            }
            Spacer()
            #endif
            scrubber
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var total: Double { duration ?? playback.durationSeconds ?? 0 }

    @ViewBuilder private var scrubber: some View {
        VStack(spacing: 6) {
            #if os(iOS)
            Slider(
                value: Binding(get: { scrubbing ?? position }, set: { scrubbing = $0; showControls() }),
                in: 0...max(total, 1),
                onEditingChanged: { editing in
                    if !editing, let target = scrubbing {
                        player?.seek(to: target)
                        position = target
                        scrubbing = nil
                    }
                }
            )
            #else
            ProgressView(value: min(position, max(total, 1)), total: max(total, 1)).tint(.white)
            #endif
            HStack {
                Text(timeString(scrubbing ?? position))
                Spacer()
                #if os(tvOS)
                Text(paused ? "Paused · swipe ◀︎ ▶︎ to seek" : "Swipe ◀︎ ▶︎ to seek 10 s").foregroundStyle(.tertiary)
                Spacer()
                #endif
                Text("-" + timeString(max(0, total - (scrubbing ?? position))))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func start() {
        let player = makePlayer(prefs: prefs)
        player.onEvent = { event in handle(event) }
        self.player = player
        player.load(playback.url, start: playback.startSeconds)
        position = playback.startSeconds ?? 0
        showControls()
    }

    private func handle(_ event: MPVPlayer.Event) {
        switch event {
        case .started:
            started = true
            buffering = false
            Task { await model.report(playback, seconds: position, event: .started) }
        case let .buffering(isBuffering):
            buffering = isBuffering
        case let .failed(message):
            error = "Couldn't play: \(message)"
        case let .time(newPosition, newDuration):
            position = newPosition
            if let newDuration { duration = newDuration }
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
        }
    }

    private func finish() {
        hideTask?.cancel()
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
        guard autoHide, !paused else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) { controlsVisible = false }
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
                .font(size > 60 ? .title.weight(.semibold) : .title3.weight(.semibold))
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

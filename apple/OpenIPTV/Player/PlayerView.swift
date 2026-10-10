import AVFoundation
import SwiftUI

struct PlaybackRequest: Identifiable {
    let id = UUID()
    let channels: [Channel]
    let index: Int
}

struct VideoSurface: UIViewRepresentable {
    let player: MPVPlayer
    func makeUIView(context: Context) -> MPVHostView { MPVHostView(player: player) }
    func updateUIView(_ view: MPVHostView, context: Context) {}
}

/// Full-screen live player with Liquid Glass controls. Swipe up/down to change
/// channel, tap to show or hide the controls.
struct PlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let channels: [Channel]
    @State var index: Int
    @State private var player: MPVPlayer?
    @State private var timing = "Starting…"
    @State private var buffering = false
    @State private var error: String?
    @State private var controlsVisible = true
    @State private var hideTask: Task<Void, Never>?

    private var channel: Channel { channels[index] }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player {
                VideoSurface(player: player).ignoresSafeArea()
            }
            if buffering || timing == "Starting…" {
                ProgressView().controlSize(.large).tint(.white)
            }
            if controlsVisible {
                controls.transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { toggleControls() }
        .gesture(
            DragGesture(minimumDistance: 40).onEnded { value in
                guard abs(value.translation.height) > abs(value.translation.width) else { return }
                step(value.translation.height < 0 ? 1 : -1)
            }
        )
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(.hidden)
        .task { start() }
        .onDisappear {
            hideTask?.cancel()
            player?.shutdown()
            player = nil
        }
    }

    private var controls: some View {
        VStack {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Close player")

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
                    Button { step(-1) } label: {
                        Image(systemName: "chevron.up").font(.title3.weight(.semibold)).frame(width: 52, height: 52)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Previous channel")

                    shows
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .glassEffect(.regular, in: .rect(cornerRadius: 22))

                    Button { step(1) } label: {
                        Image(systemName: "chevron.down").font(.title3.weight(.semibold)).frame(width: 52, height: 52)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Next channel")
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
        }
    }

    private func start() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        let headers = model.server?.cookie.map { ["Cookie: \($0)"] } ?? []
        let player = MPVPlayer(httpHeaders: headers)
        player.onEvent = { event in handle(event) }
        self.player = player
        play()
    }

    private func play() {
        timing = "Starting…"
        error = nil
        guard let url = model.streamURL(for: channel) else { return }
        player?.load(url)
        Task { await model.ensureNowNext([channel.id]) }
        scheduleHide()
    }

    private func handle(_ event: MPVPlayer.Event) {
        switch event {
        case let .started(seconds):
            timing = String(format: "%.1f s", seconds)
            buffering = false
            let id = channel.id
            Task {
                await model.refreshStatus()
                if let zap = model.status?.lastZap, zap.channel == id {
                    timing = String(format: "%.1f s · provider %.1f s", seconds, Double(zap.firstBytesMs) / 1000)
                }
            }
        case let .buffering(isBuffering):
            buffering = isBuffering
        case let .failed(message):
            error = "Couldn't play: \(message)"
        }
    }

    private func step(_ delta: Int) {
        index = (index + delta + channels.count) % channels.count
        play()
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() }
        if controlsVisible { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = true }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) { controlsVisible = false }
        }
    }
}

extension Int64 {
    /// Unix seconds as a short local time, e.g. "9:30 PM".
    var clock: String {
        Date(timeIntervalSince1970: TimeInterval(self)).formatted(date: .omitted, time: .shortened)
    }
}

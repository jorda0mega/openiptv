import SwiftUI

/// The player's controls, like the Apple TV app's player: no bars or
/// panels, a soft shade over the picture; close at the top left; back 10,
/// play/pause and forward 10 in the middle (a spinner in play's place while
/// it opens or buffers); the title with its round buttons beside it, and
/// the bar with the times at its ends.
/// iPhone: Liquid Glass. Apple TV: the system's own look (title, a plain
/// progress bar and times); the remote does the rest.
struct PlayerChrome<Trailing: View, Accessory: View, Bar: View>: View {
    var caption: String?
    let title: String
    /// A short note under the title (an error, "Started in 0.6 s").
    var note: (text: String, color: Color)?
    let paused: Bool
    var canGoForward = true
    /// Opening or buffering: a spinner where play/pause is.
    var busy = false
    /// Playing has started (the skip buttons need something to skip in).
    var ready = true
    let close: () -> Void
    let back: () -> Void
    let playPause: () -> Void
    let forward: () -> Void
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var bar: Bar

    var body: some View {
        ZStack {
            shade
            #if os(iOS)
            phone
            #else
            tv
            #endif
        }
    }

    /// Darker at the top and bottom where the controls are; the picture
    /// stays visible in between.
    private var shade: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom).frame(height: 170)
            Color.black.opacity(0.12)
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom).frame(height: 300)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let caption, !caption.isEmpty {
                Text(caption).font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
            }
            Text(title).font(.title3.weight(.bold)).foregroundStyle(.white).lineLimit(2)
            if let note {
                Text(note.text).font(.caption.monospacedDigit()).foregroundStyle(note.color).lineLimit(3)
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 8)
        .accessibilityElement(children: .combine)
    }

    #if os(iOS)
    /// Like the Apple TV app's player: close at the top left; back 10,
    /// play/pause and forward 10 in the middle; at the bottom the title with
    /// its round buttons beside it (LIVE, "…", rotate), then the bar with the
    /// times at its ends.
    private var phone: some View {
        VStack(spacing: 0) {
            HStack {
                GlassIconButton(systemName: "xmark", label: "Close player", size: 44, action: close)
                Spacer()
            }
            Spacer(minLength: 12)
            HStack(spacing: 44) {
                if ready {
                    GlassIconButton(systemName: "gobackward.10", label: "Back 10 seconds", size: 64, action: back)
                }
                if busy {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                        .frame(width: 88, height: 88)
                        .glassEffect(.regular, in: .circle)
                        .accessibilityLabel("Loading")
                } else {
                    GlassIconButton(systemName: paused ? "play.fill" : "pause.fill", label: paused ? "Play" : "Pause",
                                    size: 88, action: playPause)
                }
                if ready {
                    GlassIconButton(systemName: "goforward.10", label: "Forward 10 seconds", size: 64, action: forward)
                        .disabled(!canGoForward)
                        .opacity(canGoForward ? 1 : 0.45)
                }
            }
            Spacer(minLength: 12)
            HStack(alignment: .bottom, spacing: 10) {
                titles
                Spacer(minLength: 8)
                accessory
                trailing
                GlassIconButton(systemName: "rotate.right", label: "Rotate", size: 44) {
                    PlayerOrientation.shared.toggle()
                }
            }
            .padding(.bottom, 14)
            bar
                .tint(.white)
                .padding(.bottom, 6)
        }
        .padding(.horizontal, 20)
        // Room at the top in landscape too, where there's no status bar.
        .padding(.top, 14)
        .padding(.bottom, 8)
    }
    #else
    private var tv: some View {
        ZStack {
            if busy { ProgressView().controlSize(.large) }
            tvBar
        }
    }

    private var tvBar: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            HStack(alignment: .bottom) {
                titles
                Spacer()
                accessory
            }
            bar.tint(.white)
        }
        .padding(.horizontal, 90)
        .padding(.bottom, 60)
    }
    #endif
}

extension PlayerChrome where Trailing == EmptyView {
    init(caption: String?, title: String, note: (text: String, color: Color)?, paused: Bool, canGoForward: Bool = true,
         busy: Bool = false, ready: Bool = true,
         close: @escaping () -> Void, back: @escaping () -> Void, playPause: @escaping () -> Void, forward: @escaping () -> Void,
         @ViewBuilder accessory: () -> Accessory, @ViewBuilder bar: () -> Bar) {
        self.init(caption: caption, title: title, note: note, paused: paused, canGoForward: canGoForward, busy: busy, ready: ready,
                  close: close, back: back, playPause: playPause, forward: forward, trailing: { EmptyView() },
                  accessory: accessory, bar: bar)
    }
}

/// Elapsed time, the bar, time left: the contents of the scrubber capsule.
struct TimeBar<Track: View>: View {
    let leading: String
    let trailing: String
    @ViewBuilder var track: Track

    var body: some View {
        #if os(iOS)
        HStack(spacing: 12) {
            Text(leading).frame(minWidth: 44, alignment: .leading)
            track
            Text(trailing).frame(minWidth: 44, alignment: .trailing)
        }
        .font(.caption.monospacedDigit().weight(.medium))
        .foregroundStyle(.white.opacity(0.85))
        #else
        VStack(spacing: 10) {
            track
            HStack {
                Text(leading)
                Spacer()
                Text(trailing)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        #endif
    }
}

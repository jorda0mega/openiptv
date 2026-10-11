import SwiftUI

/// The player's controls, distilled from the streaming apps' players (Apple
/// TV, HBO Max, Peacock, Disney+): no bars or panels, a soft shade over the
/// picture; close at the top left and a couple of small buttons at the top
/// right; back 10, play/pause and forward 10 in the middle; the title and
/// one scrubber at the bottom.
/// iPhone: Liquid Glass. Apple TV: the system's own look (title, a plain
/// progress bar and times); the remote does the rest.
struct PlayerChrome<Trailing: View, Accessory: View, Bar: View>: View {
    var caption: String?
    let title: String
    /// A short note under the title (an error, "Started in 0.6 s").
    var note: (text: String, color: Color)?
    let paused: Bool
    var canGoForward = true
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
    private var phone: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                GlassIconButton(systemName: "xmark", label: "Close player", action: close)
                Spacer()
                HStack(spacing: 10) { trailing }
            }
            Spacer(minLength: 12)
            HStack(spacing: 40) {
                GlassIconButton(systemName: "gobackward.10", label: "Back 10 seconds", size: 58, action: back)
                GlassIconButton(systemName: paused ? "play.fill" : "pause.fill", label: paused ? "Play" : "Pause",
                                size: 78, action: playPause)
                GlassIconButton(systemName: "goforward.10", label: "Forward 10 seconds", size: 58, action: forward)
                    .disabled(!canGoForward)
                    .opacity(canGoForward ? 1 : 0.45)
            }
            Spacer(minLength: 12)
            HStack(alignment: .bottom, spacing: 12) {
                titles
                Spacer(minLength: 8)
                accessory
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 10)
            bar
                .tint(.white)
                .padding(.horizontal, 18)
                .frame(height: 46)
                .glassEffect(.regular, in: .capsule)
        }
        .padding(.horizontal, 16)
        // Room at the top in landscape too, where there's no status bar.
        .padding(.top, 14)
        .padding(.bottom, 8)
    }
    #else
    private var tv: some View {
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
         close: @escaping () -> Void, back: @escaping () -> Void, playPause: @escaping () -> Void, forward: @escaping () -> Void,
         @ViewBuilder accessory: () -> Accessory, @ViewBuilder bar: () -> Bar) {
        self.init(caption: caption, title: title, note: note, paused: paused, canGoForward: canGoForward, close: close,
                  back: back, playPause: playPause, forward: forward, trailing: { EmptyView() }, accessory: accessory, bar: bar)
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

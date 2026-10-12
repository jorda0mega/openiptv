import SwiftUI

/// The player's controls, like the Apple TV app's player: no bars or
/// panels, a soft shade over the picture; close and rotate at the top left;
/// back 10, play/pause and forward 10 in the middle (a spinner in play's
/// place while it opens or buffers); the title (live: a LIVE badge before
/// its caption) with "…" beside it, and the bar with the times at its ends.
/// iPhone: Liquid Glass. Apple TV: Apple's own player's look and layout
/// (see TVPlayerLayout); the remote does the rest.
struct PlayerChrome<Trailing: View, Accessory: View, Bar: View>: View {
    var caption: String?
    let title: String
    /// A short note under the title (an error, "2:05 behind live").
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

    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSize
    private var landscape: Bool { verticalSize == .compact }
    #endif

    var body: some View {
        #if os(iOS)
        ZStack {
            shade
            phone
        }
        #else
        tv
        #endif
    }

    #if os(iOS)
    /// Darker at the top and bottom where the controls are, the picture
    /// visible in between.
    private var shade: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom).frame(height: 170)
            Color.black.opacity(0.12)
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom).frame(height: 300)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// The caption line starts with the accessory (live: the LIVE badge),
    /// like the Apple TV app's "LIVE 6:30–9:30 PM · MLS".
    private var titles: some View {
        VStack(alignment: .leading, spacing: 2) {
            if Accessory.self != EmptyView.self || !(caption ?? "").isEmpty {
                HStack(spacing: 10) {
                    accessory
                    if let caption, !caption.isEmpty {
                        Text(caption).font(captionFont).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                }
            }
            Text(title).font(titleFont).foregroundStyle(.white).lineLimit(2)
            if let note {
                Text(note.text).font(.caption.monospacedDigit()).foregroundStyle(note.color).lineLimit(3)
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 8)
        .accessibilityElement(children: .combine)
    }

    private var captionFont: Font { .subheadline.weight(.medium) }
    private var titleFont: Font { .title3.weight(.bold) }

    /// Like the Apple TV app's player: close at the top left; back 10,
    /// play/pause and forward 10 in the middle; at the bottom the title with
    /// its round buttons beside it (LIVE, "…", rotate), then the bar with the
    /// times at its ends.
    private var phone: some View {
        VStack(spacing: 0) {
            // Close, and rotate beside it (where the Apple TV app keeps its
            // picture buttons): the icon shows which way it turns.
            HStack(spacing: 12) {
                GlassIconButton(systemName: "xmark", label: "Close player", size: 44, action: close)
                GlassIconButton(systemName: landscape ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate",
                                label: landscape ? "Rotate to portrait" : "Rotate to landscape", size: 44) {
                    PlayerOrientation.shared.toggle()
                }
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
                trailing
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
            TVPlayerShade(full: true)
            if busy { ProgressView().controlSize(.large) }
            TVPlayerLayout(showsBelow: false) {
                TVPlayerTitles(caption: caption, title: title, note: note) { accessory }
            } buttons: {
                trailing
            } bar: {
                bar
            } below: {
                EmptyView()
            }
        }
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

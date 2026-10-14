import SwiftUI
#if os(iOS)
import AVKit
#endif

/// A button in the player's top capsule or its row of pills.
struct PlayerAction: Identifiable {
    var id: String { title }
    let title: String
    var systemImage: String?
    let action: () -> Void
}

/// The player's controls. iPhone: the Apple TV app's iOS 26 player,
/// measured from it (440-point-wide screen): a 44-point glass close button
/// and a glass capsule of icons at the top left; back 10, play/pause and
/// forward 10 (63, 92 and 63 points) at the centre of the screen; at the
/// bottom the title (20 points, bold) with a "…" button at its right, the
/// bar with the times at its ends, and a row of glass pills ("Info", …).
/// Apple TV: Apple's own player's look and layout (see TVPlayerLayout);
/// the remote does the rest.
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
    /// iPhone: icons in the capsule beside close (after rotate), and the
    /// pills under the bar.
    var topActions: [PlayerAction] = []
    var pills: [PlayerAction] = []
    /// The pill shown selected, and the panel it opened (in place of the
    /// title and bar; the play controls move up above it).
    var selectedPill: String?
    var panel: PlayerInfoPanel?
    /// Sound off, and the button at the top right that turns it off and
    /// on (as in the Apple TV app); none without `toggleMute`.
    var muted = false
    var toggleMute: (() -> Void)? = nil
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
            if panel == nil {
                center
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
            phone
        }
        #else
        tv
        #endif
    }

    #if os(iOS)
    /// The picture dimmed evenly, a little more at the bottom where the
    /// title and times are; much more under the Info panel's text.
    private var shade: some View {
        ZStack {
            Color.black.opacity(panel == nil ? 0.32 : 0.82)
            LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
                .frame(height: 320)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    /// The caption line starts with the accessory (live: the LIVE badge),
    /// like the Apple TV app's "LIVE 6:30–9:30 PM · MLS".
    private var titles: some View {
        VStack(alignment: .leading, spacing: 3) {
            if Accessory.self != EmptyView.self || !(caption ?? "").isEmpty {
                HStack(spacing: 8) {
                    accessory
                    if let caption, !caption.isEmpty {
                        Text(caption).font(.subheadline.weight(.medium)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                    }
                }
            }
            Text(title).font(.title3.weight(.bold)).foregroundStyle(.white).lineLimit(2)
            if let note {
                Text(note.text).font(.caption.monospacedDigit()).foregroundStyle(note.color).lineLimit(3)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// Back 10, play/pause and forward 10, at the middle of the screen
    /// (centres 117 points apart).
    private var center: some View {
        HStack(spacing: 40) {
            PlayerGlassButton(systemName: "gobackward.10", label: "Back 10 seconds", size: 63, glyph: 30, action: back)
                .opacity(ready ? 1 : 0)
                .allowsHitTesting(ready)
            Group {
                if busy {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                        .frame(width: 92, height: 92)
                        .glassEffect(.regular, in: .circle)
                        .accessibilityLabel("Loading")
                } else {
                    // The icon changes at once (a symbol animation took
                    // about half a second).
                    PlayerGlassButton(systemName: paused ? "play.fill" : "pause.fill", label: paused ? "Play" : "Pause",
                                      size: 92, glyph: 42, action: playPause)
                }
            }
            PlayerGlassButton(systemName: "goforward.10", label: "Forward 10 seconds", size: 63, glyph: 30, action: forward)
                .opacity(ready ? (canGoForward ? 1 : 0.4) : 0)
                .disabled(!canGoForward)
                .allowsHitTesting(ready)
        }
    }

    /// Close and the icon capsule at the top; the title, "…", the bar and
    /// the pills at the bottom.
    private var phone: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                PlayerGlassButton(systemName: "xmark", label: "Close player", size: 44, glyph: 19, action: close)
                topCapsule
                Spacer(minLength: 0)
                if let toggleMute {
                    PlayerGlassButton(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                      label: muted ? "Unmute" : "Mute", size: 44, glyph: 17, action: toggleMute)
                }
            }
            if let panel, landscape {
                // Landscape, as in the Apple TV app: the play controls go
                // while a panel is open; the pills and the panel along the
                // bottom, from the left.
                VStack(alignment: .leading, spacing: 0) {
                    Spacer(minLength: 0)
                    pillsRow
                    PlayerInfoPanelView(panel: panel, compact: true).padding(.top, 12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .transition(.opacity)
            } else {
                portraitBody
            }
        }
        .padding(.horizontal, 20)
        // Landscape has no status bar or home indicator to keep clear of.
        .padding(.top, landscape ? 20 : 0)
        .padding(.bottom, landscape ? 16 : 2)
    }

    /// Info open (as in the Apple TV app): the play controls under the top
    /// buttons, the pills and the panel under them, room below; otherwise
    /// the title, "…", the bar and the pills at the bottom.
    @ViewBuilder private var portraitBody: some View {
        // Info open (as in the Apple TV app): the play controls under the
        // top buttons, the pills and the panel under them, room below.
        if panel != nil {
            center.frame(maxWidth: .infinity).padding(.top, 84).padding(.bottom, 93).transition(.opacity)
        } else {
            Spacer(minLength: 12)
        }
        if panel == nil {
            HStack(alignment: .bottom, spacing: 12) {
                titles
                Spacer(minLength: 8)
                trailing
            }
            .transition(.opacity)
            // Title to bar and bar to pills as in the Apple TV app
            // (centres 30 and 41 points apart).
            bar.padding(.top, 3).transition(.opacity)
        }
        if !pills.isEmpty {
            pillsRow.padding(.top, 6)
        }
        if let panel {
            PlayerInfoPanelView(panel: panel)
                .padding(.top, 23)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            Spacer(minLength: 0)
        }
    }

    /// The glass pills under the bar ("Info"), the open one in white.
    private var pillsRow: some View {
        HStack(spacing: 9) {
            ForEach(pills) { pill in
                let selected = pill.title == selectedPill
                Button(action: pill.action) {
                    Text(pill.title)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(selected ? .black : .white)
                        .padding(.horizontal, 14)
                        .frame(height: 40)
                        .background { if selected { Capsule().fill(.white) } }
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .glassEffect(selected ? .identity : .regular.interactive(), in: .capsule)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    /// Rotate (the icon shows which way it turns) and any other picture
    /// actions, in one glass capsule like the Apple TV app's.
    private var topCapsule: some View {
        let rotate = PlayerAction(title: landscape ? "Rotate to portrait" : "Rotate to landscape",
                                  systemImage: landscape ? "rectangle.portrait.rotate" : "rectangle.landscape.rotate") {
            PlayerOrientation.shared.toggle()
        }
        return HStack(spacing: 0) {
            // AirPlay, as in the Apple TV app (to AirPlay speakers and TVs).
            AirPlayButton()
                .frame(width: 54, height: 44)
                .accessibilityLabel("AirPlay")
            ForEach([rotate] + topActions) { item in
                Button(action: item.action) {
                    Image(systemName: item.systemImage ?? "circle")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 54, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.title)
            }
        }
        .padding(.horizontal, 2)
        .glassEffect(.regular.interactive(), in: .capsule)
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
         busy: Bool = false, ready: Bool = true, topActions: [PlayerAction] = [], pills: [PlayerAction] = [],
         close: @escaping () -> Void, back: @escaping () -> Void, playPause: @escaping () -> Void, forward: @escaping () -> Void,
         @ViewBuilder accessory: () -> Accessory, @ViewBuilder bar: () -> Bar) {
        self.init(caption: caption, title: title, note: note, paused: paused, canGoForward: canGoForward, busy: busy, ready: ready,
                  topActions: topActions, pills: pills, close: close, back: back, playPause: playPause, forward: forward,
                  trailing: { EmptyView() }, accessory: accessory, bar: bar)
    }
}

#if os(iOS)
/// A round glass button of an exact size (the system's glass button style
/// adds its own padding around the label, which made ours too big).
struct PlayerGlassButton: View {
    let systemName: String
    let label: String
    let size: CGFloat
    let glyph: CGFloat
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: glyph, weight: size > 80 ? .bold : .medium))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .contentShape(.circle)
                .glassEffect(.regular, in: .circle)
        }
        // A quick press (the interactive glass's own morph was slow to
        // answer a tap).
        .buttonStyle(QuickPress())
        .accessibilityLabel(label)
    }
}
#endif

#if os(iOS)
/// The system's AirPlay button (it lists AirPlay speakers and TVs).
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = .systemBlue
        picker.prioritizesVideoDevices = true
        picker.backgroundColor = .clear
        return picker
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}

/// Pressed: a little smaller and dimmer at once, back as quickly.
struct QuickPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
#endif

/// Elapsed time, the bar, time left: the contents of the scrubber capsule.
struct TimeBar<Track: View>: View {
    let leading: String
    let trailing: String
    @ViewBuilder var track: Track

    var body: some View {
        #if os(iOS)
        // The Apple TV app's: 11-point grey times, 10 points from the bar.
        HStack(spacing: 10) {
            Text(leading).frame(minWidth: 40, alignment: .leading)
            track
            Text(trailing).frame(minWidth: 40, alignment: .trailing)
        }
        .font(.system(size: 11).monospacedDigit())
        .foregroundStyle(.white.opacity(0.55))
        .lineLimit(1)
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

/// What the player's Info panel shows (iPhone).
struct PlayerInfoPanel {
    let title: String
    var overview: String?
    /// "Comedy · 33 min".
    var meta: String
    var badges: [String] = []
    var actions: [PlayerAction] = []
    /// A still, beside the text sideways.
    var images: [CardImage] = []
    /// Continue Watching's titles, in place of the rest.
    var cards: [PlayerCard] = []
}

/// A title in the player's Continue Watching.
struct PlayerCard: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let images: [CardImage]
    var loading = false
    /// For VoiceOver only (an episode's name).
    var spoken: String? = nil
    /// Landscape: the line on the picture ("S1, E2 · 26m").
    var line: String? = nil
    /// "•••": the title's page.
    var more: [PlayerAction] = []
    let action: () -> Void
}

#if os(iOS)
/// The Apple TV app's Info panel in the player: the title, the story, genre
/// and running time, and glass buttons side by side.
struct PlayerInfoPanelView: View {
    let panel: PlayerInfoPanel
    /// Landscape: a shorter story, so it fits beside the controls.
    var compact = false

    var body: some View {
        if panel.cards.isEmpty { details } else { cards }
    }

    /// As in the Apple TV app (measured at 3x from it): upright, a list
    /// of 86 × 48 pictures with the title and "Continue · S1, E1", "•••"
    /// on each row and hairlines between; sideways, a row of 202 × 147
    /// pictures with "S1, E2 · 26m" and "•••" on them. A tap plays it.
    @ViewBuilder private var cards: some View {
        if compact {
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(panel.cards) { card in
                        ZStack(alignment: .bottomTrailing) {
                            Button(action: card.action) { pictureCard(card) }
                                .buttonStyle(.plain)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(label(card))
                                .accessibilityAddTraits(.isButton)
                            more(card)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(panel.cards) { card in
                    HStack(spacing: 0) {
                        Button(action: card.action) {
                            HStack(spacing: 12) {
                                thumbnail(card)
                                caption(card)
                                Spacer(minLength: 8)
                            }
                            .padding(.vertical, 10)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(label(card))
                        .accessibilityAddTraits(.isButton)
                        more(card)
                    }
                    if card.id != panel.cards.last?.id {
                        Rectangle().fill(Color(white: 0.2)).frame(height: 0.5).padding(.leading, 98)
                    }
                }
            }
        }
    }

    private func thumbnail(_ card: PlayerCard) -> some View {
        CoverImage(images: card.images, title: card.title)
            .frame(width: 86, height: 48)
            .overlay { if card.loading { ProgressView().tint(.white) } }
            .clipShape(.rect(cornerRadius: 7))
    }

    private func pictureCard(_ card: PlayerCard) -> some View {
        CoverImage(images: card.images, title: card.title)
            .frame(width: 202, height: 147)
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom).frame(height: 48)
            }
            .overlay(alignment: .bottomLeading) {
                HStack(spacing: 5) {
                    Image(systemName: "play.fill").font(.system(size: 9, weight: .semibold))
                    Text(card.line ?? "").font(.footnote).lineLimit(1)
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(.leading, 10)
                .padding(.trailing, 40)
                .padding(.bottom, 11)
            }
            .overlay { if card.loading { ProgressView().tint(.white) } }
            .clipShape(.rect(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
    }

    /// "•••": the title's page.
    @ViewBuilder private func more(_ card: PlayerCard) -> some View {
        if !card.more.isEmpty {
            Menu {
                ForEach(card.more) { action in
                    Button(action.title, systemImage: action.systemImage ?? "info.circle", action: action.action)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color(white: 0.6))
                    .frame(width: 40, height: 36)
                    .contentShape(.rect)
            }
            .accessibilityLabel("More")
        }
    }

    private func caption(_ card: PlayerCard) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(card.title).font(.body).foregroundStyle(.white).lineLimit(1)
            if let subtitle = card.subtitle {
                Text(subtitle).font(.subheadline).foregroundStyle(Color(white: 0.56)).lineLimit(1)
            }
        }
    }

    private func label(_ card: PlayerCard) -> String {
        [card.title, card.subtitle, card.spoken].compactMap(\.self).joined(separator: ", ")
    }

    /// As in the Apple TV app (measured at 3x from it): upright, the text,
    /// then the buttons side by side; sideways, a 180 × 101 still, the text
    /// beside it and the buttons stacked at the right (200 × 44, 8 apart).
    @ViewBuilder private var details: some View {
        if compact {
            HStack(alignment: .top, spacing: 0) {
                if !panel.images.isEmpty {
                    CoverImage(images: panel.images, title: panel.title)
                        .frame(width: 180, height: 101)
                        .clipShape(.rect(cornerRadius: 8))
                        .accessibilityHidden(true)
                        #if DEBUG
                        // UI tests: the still's own frame (the picture's
                        // counts uncut).
                        .overlay {
                            Color.black.opacity(0.001)
                                .accessibilityElement()
                                .accessibilityLabel("Still")
                                .accessibilityIdentifier("player.info.still")
                        }
                        #endif
                        .padding(.leading, 10)
                        .padding(.trailing, 20)
                }
                text.frame(maxWidth: .infinity, alignment: .leading)
                if !panel.actions.isEmpty {
                    VStack(spacing: 8) {
                        ForEach(panel.actions) { button($0).frame(width: 200) }
                    }
                    .padding(.leading, 16)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                text
                if !panel.actions.isEmpty {
                    HStack(spacing: 10) {
                        ForEach(panel.actions) { button($0).frame(maxWidth: .infinity) }
                    }
                    .padding(.top, 12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The title (17 pt bold), the story (15 pt), genre and running time
    /// (13 pt), as in the Apple TV app.
    private var text: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(panel.title).font(.headline.weight(.bold)).foregroundStyle(.white).lineLimit(1)
            if let overview = panel.overview, !overview.isEmpty {
                Text(overview).font(.subheadline).foregroundStyle(.white).lineLimit(compact ? 3 : 5)
            }
            HStack(spacing: 6) {
                if !panel.meta.isEmpty {
                    Text(panel.meta).font(.footnote.weight(.semibold)).foregroundStyle(.white.opacity(0.5))
                }
                ForEach(panel.badges, id: \.self) { badge in
                    Text(badge)
                        .font(.system(size: 10, weight: .heavy))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.55), lineWidth: 1))
                }
            }
        }
    }

    /// 44 points tall, 15-point text, as in the Apple TV app.
    private func button(_ action: PlayerAction) -> some View {
        Button(action: action.action) {
            Label(action.title, systemImage: action.systemImage ?? "circle")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}
#endif

#if os(tvOS)
import SwiftUI

// Apple TV's own player (tvOS 26's AVPlayerViewController), measured from
// screenshots of it at 1080p: margins of 80 points; paused, the caption
// and title over a thin glass bar, the time under the playhead with a small
// sign for what it's doing, the time left at the end, an Info tab under
// them and round buttons (subtitles, audio, speed) to the right of the title;
// playing, the bar alone. The bar sits at the same height in every state.

/// What the player shows over the picture.
enum TVPlayerPanel: Hashable {
    /// Down from the bar: the title's details and "From Beginning".
    case info
    /// An episode's season, the tab beside Info.
    case episodes
    case audio
    case subtitles
    case speed
}

/// What the remote moves between (the player has no SwiftUI focus: its
/// remote surface takes every press).
enum TVPlayerFocus: Hashable {
    case bar
    case subtitles
    case audio
    case speed
    /// A row of the open audio, subtitle or speed menu.
    case row(Int)
    /// The Info panel's tab, where the panel opens (as in Apple's player:
    /// a click there does nothing, so it can't start the film over).
    case infoTab
    case fromBeginning
    /// The Episodes tab, and an episode in its row.
    case episodesTab
    case episode(Int)
}

/// An episode in the player's Episodes row (Apple TV).
struct TVPlayerEpisode: Identifiable {
    let id: String
    /// "3. Case 3".
    let title: String
    /// "Playing", "12m left", "22m".
    let line: String?
    let images: [CardImage]
}

/// The Info panel's contents.
struct TVPlayerInfo {
    var heading: String?
    var overview: String?
    var runtime: String?
    /// "4K", "HD", "HDR".
    var badges: [String] = []
}

/// The audio or subtitle menu.
struct TVTrackMenu: Equatable {
    struct Row: Equatable {
        let label: String
        let checked: Bool
        var identifier = ""
    }

    let heading: String
    let rows: [Row]
}

/// Darker towards the bottom, under the controls: paused, from a third of
/// the way down to 55% black; with the bar alone, the bottom third.
struct TVPlayerShade: View {
    let full: Bool

    var body: some View {
        ZStack {
            gradient(from: 0.68, to: 1).opacity(full ? 0 : 1)
            gradient(from: 0.36, to: 0.88).opacity(full ? 1 : 0)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    private func gradient(from start: Double, to end: Double) -> LinearGradient {
        LinearGradient(stops: [
            .init(color: .clear, location: start),
            .init(color: .black.opacity(0.54), location: end),
            .init(color: .black.opacity(0.55), location: 1),
        ], startPoint: .top, endPoint: .bottom)
    }
}

/// The caption ("2024 · Drama", or LIVE and what's on) over the title, and
/// a note under them (an error, a quality change).
struct TVPlayerTitles<Accessory: View>: View {
    let caption: String?
    let title: String
    var note: (text: String, color: Color)?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if Accessory.self != EmptyView.self || !(caption ?? "").isEmpty {
                HStack(spacing: 12) {
                    accessory
                    if let caption, !caption.isEmpty {
                        Text(caption).font(.system(size: 26, weight: .medium)).lineLimit(1)
                    }
                }
            }
            Text(title)
                .font(.system(size: 60, weight: .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let note {
                Text(note.text).font(.system(size: 23).monospacedDigit()).foregroundStyle(note.color).lineLimit(3)
            }
        }
        .foregroundStyle(.white)
        .accessibilityElement(children: .combine)
    }
}

/// The titles with the buttons at their right, the bar and times, and the
/// row under them, in their places (absolute, from the screen's edges).
struct TVPlayerLayout<Titles: View, Buttons: View, Bar: View, Below: View>: View {
    var showsTitles = true
    var showsBelow = true
    @ViewBuilder var titles: Titles
    @ViewBuilder var buttons: Buttons
    @ViewBuilder var bar: Bar
    @ViewBuilder var below: Below

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 40) {
                titles
                Spacer(minLength: 0)
                buttons.padding(.bottom, 4)
            }
            .opacity(showsTitles ? 1 : 0)
            .accessibilityHidden(!showsTitles)
            .padding(.bottom, 30)
            bar
            HStack { below }
                .frame(height: 62)
                .opacity(showsBelow ? 1 : 0)
                .accessibilityHidden(!showsBelow)
                .padding(.top, 16)
        }
        .padding(.horizontal, 80)
        .padding(.bottom, 47)
        .ignoresSafeArea()
    }
}

/// Apple TV's transport bar: a thin glass track, the part played in
/// translucent white and a fine playhead; under the playhead the time
/// there with a sign for what's happening (paused, fast-forward, rewind),
/// the time left at the end.
struct TVTransportBar: View {
    enum State {
        case playing, paused, forward, backward

        var symbol: String? {
            switch self {
            case .playing: nil
            case .paused: "pause.circle"
            case .forward: "forward.circle"
            case .backward: "backward.circle"
            }
        }
    }

    let fraction: Double
    let time: String
    let remaining: String
    var state: State = .playing

    @SwiftUI.State private var timeWidth: CGFloat = 0
    @SwiftUI.State private var remainingWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let x = width * min(max(fraction, 0), 1)
            VStack(alignment: .leading, spacing: 8.5) {
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.06)).glassEffect(.clear, in: .capsule)
                    Rectangle().fill(.white.opacity(0.5)).frame(width: x)
                }
                .clipShape(Capsule())
                .frame(height: 13)
                .overlay(alignment: .leading) {
                    Capsule().fill(.white).frame(width: 3, height: 17).offset(x: min(max(x - 1.5, 0), width - 3))
                }
                // The time centred under the playhead (its sign beside it),
                // kept on the bar; the time left steps aside when they'd meet.
                let left = min(max(x - timeWidth / 2, 0), max(width - timeWidth - 44, 0))
                ZStack(alignment: .topLeading) {
                    Text(remaining)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { remainingWidth = $0 }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .opacity(left + timeWidth + 64 > width - remainingWidth ? 0 : 1)
                    Text(time)
                        .fixedSize()
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { timeWidth = $0 }
                        .overlay(alignment: .leading) {
                            if let symbol = state.symbol {
                                Image(systemName: symbol)
                                    .font(.system(size: 29, weight: .medium))
                                    .fixedSize()
                                    .offset(x: timeWidth + 15)
                            }
                        }
                        .offset(x: left)
                }
                .font(.system(size: 25, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
            }
        }
        .frame(height: 51.5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(state == .paused ? "Paused" : "Playing")
        .accessibilityValue("\(time), \(remaining)")
    }
}

/// A round button beside the title (subtitles, audio): glass, white when
/// the remote is on it.
struct TVPlayerRoundButton: View {
    let systemName: String
    let label: String
    let focused: Bool

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(focused ? .black : .white)
            .frame(width: 70, height: 70)
            .background { if focused { Circle().fill(.white) } }
            .glassEffect(focused ? .identity : .regular, in: .circle)
            .scaleEffect(focused ? 1.1 : 1)
            .shadow(color: .black.opacity(focused ? 0.3 : 0), radius: 12, y: 6)
            .accessibilityLabel(label)
            .accessibilityAddTraits(focused ? [.isButton, .isSelected] : .isButton)
    }
}

/// The Info tab: under the bar while paused, over the Info panel (lit)
/// when it's open.
struct TVPlayerInfoTab: View {
    var title = "Info"
    var selected = false
    /// The remote is on it: white, black words, raised.
    var focused = false

    var body: some View {
        Text(title)
            .font(.system(size: 29))
            .foregroundStyle(focused ? .black : .white)
            .padding(.horizontal, 31)
            .frame(height: 62)
            .background { if focused { Capsule().fill(.white.opacity(0.92)) } }
            .glassEffect(focused ? .identity : selected ? .regular.tint(.white.opacity(0.3)) : .regular, in: .capsule)
            .scaleEffect(focused ? 1.05 : 1)
            .shadow(color: .black.opacity(focused ? 0.3 : 0), radius: 12, y: 6)
            .accessibilityIdentifier("player.\(title.lowercased().replacingOccurrences(of: " ", with: "")).tab")
            .accessibilityAddTraits(focused ? [.isButton, .isSelected] : .isButton)
    }
}

/// The film player's controls on Apple TV.
struct TVMovieOverlay: View {
    let caption: String?
    let title: String
    var note: (text: String, color: Color)?
    var load: LoadProgress?
    var loadActions = LoadActions(tryAgain: {})
    let bar: TVClockedBar
    /// The bar alone (playing, or just after a jump).
    let compact: Bool
    let panel: TVPlayerPanel?
    let focus: TVPlayerFocus
    let hasSubtitles: Bool
    let info: TVPlayerInfo
    let menu: TVTrackMenu?
    /// An episode's season (the Episodes tab), when it has more than one.
    var episodes: [TVPlayerEpisode] = []

    var body: some View {
        ZStack {
            TVPlayerShade(full: !compact || panel != nil || note != nil)
            if let load { LoadProgressView(load: load, actions: loadActions) }
            if panel == .episodes {
                // The row has no glass box: a fade from the middle down keeps
                // its words clear of a bright picture.
                LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            if panel == .info || panel == .episodes {
                infoPage.transition(.opacity.combined(with: .offset(y: 40)))
            } else {
                TVPlayerLayout(showsTitles: !compact || panel != nil || note != nil, showsBelow: !compact || panel != nil) {
                    TVPlayerTitles(caption: caption, title: title, note: note) { EmptyView() }
                } buttons: {
                    HStack(spacing: 22) {
                        if hasSubtitles {
                            TVPlayerRoundButton(systemName: "captions.bubble", label: "Subtitles", focused: focus == .subtitles)
                        }
                        TVPlayerRoundButton(systemName: "waveform", label: "Audio", focused: focus == .audio)
                        TVPlayerRoundButton(systemName: "gauge.with.dots.needle.67percent", label: "Playback Speed",
                                            focused: focus == .speed)
                    }
                } bar: {
                    bar
                } below: {
                    TVPlayerInfoTab()
                }
                .transition(.opacity)
            }
            // Over the round buttons, right-aligned with them (from the
            // screen's edges, not the safe area's).
            if let menu {
                TVTrackMenuView(menu: menu, focused: { if case let .row(i) = focus { i } else { nil } }())
                    .padding(.trailing, 80)
                    .padding(.bottom, 308)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .ignoresSafeArea()
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottomTrailing)))
            }
        }
        .animation(.snappy(duration: 0.25), value: compact)
        .animation(.snappy(duration: 0.25), value: panel)
        .animation(.snappy(duration: 0.18), value: focus)
    }

    /// The Info tab lit over a glass panel: the caption, the story, the
    /// running time and picture badges, and "From Beginning".
    private var infoPage: some View {
        VStack(alignment: .leading, spacing: 45) {
            HStack(spacing: 20) {
                TVPlayerInfoTab(selected: panel == .info, focused: focus == .infoTab)
                if !episodes.isEmpty {
                    TVPlayerInfoTab(title: "Episodes", selected: panel == .episodes, focused: focus == .episodesTab)
                }
            }
            if panel == .episodes { episodesRow } else { infoBox }
        }
        .padding(.horizontal, 80)
        .padding(.bottom, 38)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .ignoresSafeArea()
    }

    /// The season, as a row of stills: the remote's in front, raised.
    private var episodesRow: some View {
        let focused: Int? = if case let .episode(i) = focus { i } else { nil }
        return ScrollViewReader { reader in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 40) {
                    ForEach(Array(episodes.enumerated()), id: \.element.id) { index, episode in
                        let on = focused == index
                        VStack(alignment: .leading, spacing: 10) {
                            CoverImage(images: episode.images, title: episode.title)
                                .frame(width: 320, height: 180)
                                .clipShape(.rect(cornerRadius: 16))
                                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(on ? 0.9 : 0.15), lineWidth: on ? 3 : 1))
                            Text(episode.title).font(.system(size: 25, weight: .semibold)).lineLimit(1)
                            if let line = episode.line {
                                Text(line).font(.system(size: 22)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                            }
                        }
                        .foregroundStyle(.white)
                        .frame(width: 320, alignment: .leading)
                        .scaleEffect(on ? 1.08 : 1, anchor: .bottom)
                        .shadow(color: .black.opacity(on ? 0.4 : 0), radius: 16, y: 10)
                        .id(episode.id)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("player.episode.\(episode.id)")
                        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                    }
                }
                .padding(.vertical, 24)
                .padding(.horizontal, 12)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
            .onChange(of: focused) { _, index in
                guard let index, episodes.indices.contains(index) else { return }
                withAnimation(.snappy(duration: 0.25)) { reader.scrollTo(episodes[index].id, anchor: .center) }
            }
        }
        .frame(height: 300)
    }

    private var infoBox: some View {
            HStack(alignment: .top, spacing: 40) {
                VStack(alignment: .leading, spacing: 8) {
                    if let heading = info.heading ?? caption {
                        Text(heading).font(.system(size: 30, weight: .bold)).lineLimit(1)
                    }
                    if let overview = info.overview, !overview.isEmpty {
                        Text(overview).font(.system(size: 25)).foregroundStyle(.white.opacity(0.6)).lineLimit(3)
                    }
                    Spacer(minLength: 0)
                    HStack(spacing: 14) {
                        if let runtime = info.runtime { Text(runtime).font(.system(size: 25)) }
                        ForEach(info.badges, id: \.self) { badge in
                            Text(badge)
                                .font(.system(size: 16, weight: .heavy))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 6)
                                .frame(height: 22)
                                .background(.white, in: .rect(cornerRadius: 4))
                        }
                    }
                }
                .foregroundStyle(.white)
                Spacer(minLength: 0)
                fromBeginning.padding(.top, 14)
            }
            .padding(.horizontal, 23)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 227)
            .glassEffect(.regular, in: .rect(cornerRadius: 40))
    }

    private var fromBeginning: some View {
        let focused = focus == .fromBeginning
        return Label("From Beginning", systemImage: "play.fill")
            .font(.system(size: 29, weight: .medium))
            .foregroundStyle(focused ? .black : .white)
            .padding(.horizontal, 44)
            .frame(height: 73)
            .background { if focused { Capsule().fill(.white.opacity(0.92)) } }
            .glassEffect(focused ? .identity : .regular, in: .capsule)
            .scaleEffect(focused ? 1.05 : 1)
            .shadow(color: .black.opacity(focused ? 0.3 : 0), radius: 14, y: 8)
            .accessibilityIdentifier("player.info.fromBeginning")
            .accessibilityAddTraits(focused ? [.isButton, .isSelected] : .isButton)
    }
}

/// A glass menu over the round buttons: a heading and its rows, a tick by
/// the one in use, the row the remote is on in white. Eight rows at most
/// on screen, moving with the remote.
struct TVTrackMenuView: View {
    let menu: TVTrackMenu
    let focused: Int?

    private let visible = 8

    var body: some View {
        let first = min(max((focused ?? 0) - visible / 2, 0), max(menu.rows.count - visible, 0))
        VStack(alignment: .leading, spacing: 4) {
            Text(menu.heading)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 20)
                .padding(.top, 6)
            ForEach(first..<min(first + visible, menu.rows.count), id: \.self) { index in
                let row = menu.rows[index]
                let on = index == focused
                HStack(spacing: 12) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 21, weight: .semibold))
                        .opacity(row.checked ? 1 : 0)
                    Text(row.label).font(.system(size: 25, weight: .medium)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(on ? .black : .white)
                .padding(.horizontal, 20)
                .frame(height: 56)
                .background { if on { Capsule().fill(.white) } }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(row.checked ? [.isButton, .isSelected] : .isButton)
                .accessibilityIdentifier(row.identifier)
            }
        }
        .padding(12)
        .frame(width: 447)
        .glassEffect(.regular, in: .rect(cornerRadius: 32))
    }
}
#endif

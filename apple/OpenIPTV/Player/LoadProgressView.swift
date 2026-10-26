import SwiftUI

/// What the buttons under a slow or failed start do.
struct LoadActions {
    var tryAgain: () -> Void
    var otherChannels: () -> Void = {}
}

/// A start's progress (see LoadProgress): the ring where play/pause is, at
/// the middle of the screen, and its words under it. `otherwise` shows
/// while it has nothing to draw (a drop's first seconds). Apple TV: the
/// remote moves between the buttons, and `focused` is the one it's on.
struct LoadProgressView<Otherwise: View>: View {
    let load: LoadProgress
    let actions: LoadActions
    var focused: LoadProgress.Button?
    @ViewBuilder var otherwise: Otherwise

    var body: some View {
        TimelineView(.periodic(from: load.began, by: 1)) { context in
            if let shown = load.shown(at: context.date) {
                LoadProgressShown(shown: shown, actions: actions, focused: focused)
            } else {
                otherwise
            }
        }
    }
}

extension LoadProgressView where Otherwise == EmptyView {
    init(load: LoadProgress, actions: LoadActions, focused: LoadProgress.Button? = nil) {
        self.init(load: load, actions: actions, focused: focused) { EmptyView() }
    }
}

private struct LoadProgressShown: View {
    let shown: LoadProgress.Shown
    let actions: LoadActions
    let focused: LoadProgress.Button?

    #if os(tvOS)
    private let ringSize: CGFloat = 80, lineFont: CGFloat = 38, detailFont: CGFloat = 29, gap: CGFloat = 22, width: CGFloat = 1100
    #else
    private let ringSize: CGFloat = 44, lineFont: CGFloat = 17, detailFont: CGFloat = 15, gap: CGFloat = 12, width: CGFloat = 330
    #endif

    var body: some View {
        if let fill = shown.ring {
            // The ring stays at the middle however many lines hang under it.
            LoadRing(fill: fill, size: ringSize)
                .overlay(alignment: .top) {
                    words.offset(y: ringSize + gap)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("load-progress")
        } else {
            words.accessibilityIdentifier("load-progress")
        }
    }

    private var words: some View {
        VStack(spacing: gap * 0.6) {
            if let line = shown.line {
                Text(line)
                    .font(.system(size: lineFont, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            ForEach(shown.details, id: \.self) { detail in
                Text(detail)
                    .font(.system(size: detailFont))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.78))
            }
            if let dashes = shown.dashes { LoadDashes(reached: dashes) }
            if !shown.buttons.isEmpty {
                HStack(spacing: gap * 0.8) {
                    ForEach(shown.buttons, id: \.self) { button in
                        LoadButtonView(button: button, focused: focus == button, action: action(button))
                    }
                }
                .padding(.top, gap * 0.4)
            }
        }
        .multilineTextAlignment(.center)
        .frame(width: width)
        .fixedSize(horizontal: false, vertical: true)
        .shadow(color: .black.opacity(0.45), radius: 6)
        .accessibilityElement(children: .contain)
    }

    /// Apple TV: the remote starts on the first button.
    private var focus: LoadProgress.Button? {
        #if os(tvOS)
        shown.buttons.contains { $0 == focused } ? focused : shown.buttons.first
        #else
        nil
        #endif
    }

    private func action(_ button: LoadProgress.Button) -> () -> Void {
        switch button {
        case .tryAgain: actions.tryAgain
        case .otherChannels: actions.otherChannels
        }
    }
}

/// White on a faint track, turning, so a long step still looks alive.
private struct LoadRing: View {
    let fill: Double
    let size: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turning = false

    var body: some View {
        let width = size / 10
        ZStack {
            Circle().stroke(.white.opacity(0.2), lineWidth: width)
            Circle()
                .trim(from: 0, to: fill)
                .stroke(.white, style: StrokeStyle(lineWidth: width, lineCap: .round))
                .rotationEffect(.degrees(turning ? 270 : -90))
                .animation(.easeInOut(duration: 0.4), value: fill)
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.45), radius: 6)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { turning = true }
        }
        .accessibilityElement()
        .accessibilityLabel("Loading")
    }
}

private struct LoadDashes: View {
    let reached: Int

    #if os(tvOS)
    private let size = CGSize(width: 40, height: 6)
    #else
    private let size = CGSize(width: 20, height: 3.5)
    #endif

    var body: some View {
        HStack(spacing: size.height * 1.5) {
            ForEach(LoadProgress.Stage.allCases, id: \.self) { stage in
                Capsule()
                    .fill(.white.opacity(stage.rawValue < reached ? 1 : 0.25))
                    .frame(width: size.width, height: size.height)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(reached) of \(LoadProgress.Stage.allCases.count)")
    }
}

/// iPhone: Try again in glass, Other channels in white. Apple TV: white is
/// where the remote is, as everywhere on the TV.
private struct LoadButtonView: View {
    let button: LoadProgress.Button
    let focused: Bool
    let action: () -> Void

    private var title: String {
        switch button {
        case .tryAgain: "Try again"
        case .otherChannels: "Other channels with this game"
        }
    }

    var body: some View {
        #if os(tvOS)
        Text(title)
            .font(.system(size: 29, weight: .semibold))
            .foregroundStyle(focused ? .black : .white)
            .padding(.horizontal, 36)
            .frame(height: 66)
            .background(focused ? .white : .white.opacity(0.18), in: .capsule)
            .scaleEffect(focused ? 1.06 : 1)
            .shadow(color: .black.opacity(focused ? 0.3 : 0), radius: 12, y: 6)
            .animation(.easeOut(duration: 0.15), value: focused)
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityAddTraits(focused ? [.isButton, .isSelected] : .isButton)
        #else
        let primary = button == .otherChannels
        Button(action: action) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(primary ? .black : .white)
                .padding(.horizontal, 16)
                .frame(height: 40)
                .background { if primary { Capsule().fill(.white) } }
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(primary ? .identity : .regular.interactive(), in: .capsule)
        #endif
    }
}

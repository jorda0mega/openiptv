import SwiftUI

struct LoadActions {
    var tryAgain: () -> Void
    var otherChannels: () -> Void = {}
}

struct LoadProgressView<Otherwise: View>: View {
    let load: LoadProgress
    let actions: LoadActions
    var focused: LoadProgress.Button?
    var overPicture = false
    @ViewBuilder var otherwise: Otherwise

    var body: some View {
        TimelineView(.periodic(from: load.began, by: 0.5)) { context in
            if let shown = load.shown(at: context.date) {
                let content = LoadProgressShown(shown: shown, actions: actions, focused: focused)
                if overPicture, load.wait != .start || load.failure != nil {
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background { Color.black.opacity(0.5).ignoresSafeArea().allowsHitTesting(false) }
                } else {
                    content
                }
            } else {
                otherwise
            }
        }
    }
}

extension LoadProgressView where Otherwise == EmptyView {
    init(load: LoadProgress, actions: LoadActions, focused: LoadProgress.Button? = nil, overPicture: Bool = false) {
        self.init(load: load, actions: actions, focused: focused, overPicture: overPicture) { EmptyView() }
    }
}

/// Under a film's start: its backdrop, dimmed for the ring.
struct StartBackdrop: View {
    let images: [CardImage]
    let title: String

    var body: some View {
        ZStack {
            Color.black
            CoverImage(images: images, title: title, backdrop: true)
            Color.black.opacity(0.35)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct LoadProgressShown: View {
    let shown: LoadProgress.Shown
    let actions: LoadActions
    let focused: LoadProgress.Button?

    #if os(tvOS)
    private let ringSize: CGFloat = 60, lineFont: CGFloat = 38, detailFont: CGFloat = 29, gap: CGFloat = 22, width: CGFloat = 1100
    #else
    private let ringSize: CGFloat = 34, lineFont: CGFloat = 17, detailFont: CGFloat = 15, gap: CGFloat = 12, width: CGFloat = 330
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
            if !shown.buttons.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: gap * 0.8) { buttons }
                    VStack(spacing: gap * 0.8) { buttons }
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

    private var buttons: some View {
        ForEach(shown.buttons, id: \.self) { button in
            LoadButtonView(button: button, focused: focus == button,
                           action: button == .tryAgain ? actions.tryAgain : actions.otherChannels)
        }
    }

    private var focus: LoadProgress.Button? {
        #if os(tvOS)
        if let focused, shown.buttons.contains(focused) { focused } else { shown.buttons.first }
        #else
        nil
        #endif
    }
}

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
            .fixedSize()
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
                .fixedSize()
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

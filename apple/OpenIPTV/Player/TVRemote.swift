#if os(tvOS)
import SwiftUI
import UIKit

/// The Siri Remote in the player, read the way Apple's own player reads it:
/// clicks on the ring's left and right, holding them, swipes on the touch
/// surface, the centre, Play/Pause and Menu. SwiftUI only offers one move
/// per swipe, so this is a UIKit view that takes focus and sees the touches.
struct TVRemoteSurface: UIViewRepresentable {
    enum Input {
        /// A click on the left (−1) or right (+1) of the ring.
        case click(Double)
        /// Left or right held down (−1 or +1), until `.released`.
        case hold(Double)
        case released
        /// A swipe: how far across the touch surface since it began.
        case swipe(began: Bool, distance: CGFloat, ended: Bool)
        case select
        case playPause
        /// From the player's `onExitCommand` (see `pressesEnded`).
        case menu
    }

    let handle: (Input) -> Void

    func makeUIView(context: Context) -> RemoteView {
        let view = RemoteView()
        view.handle = handle
        return view
    }

    func updateUIView(_ view: RemoteView, context: Context) {
        view.handle = handle
    }

    final class RemoteView: UIView {
        var handle: (Input) -> Void = { _ in }
        /// Turns a press into a hold once it's been down long enough.
        private var holdTimer: Task<Void, Never>?
        private var holding = false

        override var canBecomeFocused: Bool { true }

        override init(frame: CGRect) {
            super.init(frame: frame)
            let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
            addGestureRecognizer(pan)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            // The player's only control: take focus straight away.
            if window != nil { setNeedsFocusUpdate() }
        }

        @objc private func panned(_ pan: UIPanGestureRecognizer) {
            let distance = pan.translation(in: self).x
            switch pan.state {
            case .began: handle(.swipe(began: true, distance: 0, ended: false))
            case .changed: handle(.swipe(began: false, distance: distance, ended: false))
            case .ended, .cancelled, .failed: handle(.swipe(began: false, distance: distance, ended: true))
            default: break
            }
        }

        private static func direction(_ type: UIPress.PressType) -> Double? {
            switch type {
            case .leftArrow: -1
            case .rightArrow: 1
            default: nil
            }
        }

        override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var rest = Set<UIPress>()
            for press in presses {
                if let direction = Self.direction(press.type) {
                    holdTimer?.cancel()
                    holding = false
                    holdTimer = Task { [weak self] in
                        try? await Task.sleep(for: .milliseconds(450))
                        guard !Task.isCancelled, let self else { return }
                        self.holding = true
                        self.handle(.hold(direction))
                    }
                } else if ![.select, .playPause].contains(press.type) {
                    rest.insert(press)
                }
            }
            if !rest.isEmpty { super.pressesBegan(rest, with: event) }
        }

        override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            var rest = Set<UIPress>()
            for press in presses {
                if let direction = Self.direction(press.type) {
                    holdTimer?.cancel()
                    holdTimer = nil
                    if holding {
                        holding = false
                        handle(.released)
                    } else {
                        handle(.click(direction))
                    }
                } else {
                    switch press.type {
                    case .select: handle(.select)
                    case .playPause: handle(.playPause)
                    // Menu goes on to SwiftUI (the player's onExitCommand):
                    // the full-screen cover takes it before this view does.
                    default: rest.insert(press)
                    }
                }
            }
            if !rest.isEmpty { super.pressesEnded(rest, with: event) }
        }

        override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
            if presses.contains(where: { Self.direction($0.type) != nil }) {
                holdTimer?.cancel()
                holdTimer = nil
                if holding {
                    holding = false
                    handle(.released)
                }
            }
            super.pressesCancelled(presses, with: event)
        }
    }
}

/// Apple TV's transport bar, as in its own player: a thin track and how
/// far it's played; under the playhead the time there (a small pause sign
/// before it while paused), the time left at the end. While choosing where
/// to jump, the playhead is where it would land (the picture follows) and
/// a faint mark stays where it was.
struct TVTransportBar: View {
    /// The playhead and where a choice started, 0...1.
    let fraction: Double
    var origin: Double?
    let time: String
    let remaining: String
    let paused: Bool
    var choosing = false

    @State private var timeWidth: CGFloat = 0
    @State private var remainingWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let x = width * min(max(fraction, 0), 1)
            let thickness: CGFloat = choosing ? 10 : 6
            VStack(alignment: .leading, spacing: 14) {
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.3))
                    Capsule().fill(.white).frame(width: max(x, thickness))
                    if let origin {
                        Capsule().fill(.white.opacity(0.7))
                            .frame(width: 3, height: thickness + 12)
                            .offset(x: width * min(max(origin, 0), 1) - 1.5)
                    }
                }
                .frame(height: thickness)
                .frame(height: 22)
                // The time follows the playhead, kept on the bar; the time
                // left steps aside when they'd touch.
                let left = min(max(x - timeWidth / 2, 0), max(width - timeWidth, 0))
                ZStack(alignment: .topLeading) {
                    Text(remaining)
                        .foregroundStyle(.white.opacity(0.6))
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { remainingWidth = $0 }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .opacity(left + timeWidth + 24 > width - remainingWidth ? 0 : 1)
                    HStack(spacing: 8) {
                        if paused { Image(systemName: "pause.fill").font(.caption2) }
                        Text(time)
                    }
                    .foregroundStyle(.white)
                    .fixedSize()
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { timeWidth = $0 }
                    .offset(x: left)
                }
                .font(.caption.monospacedDigit().weight(.semibold))
            }
            .animation(.snappy(duration: 0.2), value: choosing)
        }
        .frame(height: 70)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(paused ? "Paused" : "Playing")
        .accessibilityValue("\(time), \(remaining)")
    }
}
#endif

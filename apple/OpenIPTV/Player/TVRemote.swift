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

/// Apple TV's progress bar: a thin track, how far it's played, and, while
/// choosing where to jump, a marker there.
struct TVProgressBar: View {
    let position: Double
    let total: Double
    /// Where a swipe or hold would jump to.
    let target: Double?

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let played = total > 0 ? min(max(position / total, 0), 1) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.25))
                Capsule().fill(.white).frame(width: width * played)
                if let target, total > 0 {
                    let x = width * min(max(target / total, 0), 1)
                    Capsule().fill(.white)
                        .frame(width: 4, height: 28)
                        .offset(x: x - 2)
                }
            }
            .frame(height: 10)
            .frame(maxHeight: .infinity)
        }
        .frame(height: 28)
    }
}
#endif

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
        /// Up or down: a click on the ring's top or bottom, or a swipe.
        case up
        case down
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
        /// Which way the current swipe goes, once it's clear: across moves
        /// through the film, up or down is one press of the ring.
        private var vertical: Bool?
        /// When this touch began, and the last click: a click during a
        /// touch makes it a click, not a swipe.
        private var touchBegan = Date.distantPast
        private var lastClick = Date.distantPast

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
            let moved = pan.translation(in: self)
            switch pan.state {
            case .began:
                vertical = nil
                touchBegan = Date()
            case .changed:
                if vertical == nil, max(abs(moved.x), abs(moved.y)) > 24 {
                    vertical = abs(moved.y) > abs(moved.x)
                    if vertical == false { handle(.swipe(began: true, distance: 0, ended: false)) }
                }
                if vertical == false { handle(.swipe(began: false, distance: moved.x, ended: false)) }
            case .ended, .cancelled, .failed:
                if vertical == false {
                    handle(.swipe(began: false, distance: moved.x, ended: true))
                } else if vertical == true, pan.state == .ended {
                    // The pan begins once the finger has moved a little, so
                    // a click just before counts as in this touch too.
                    let clicked = lastClick > touchBegan.addingTimeInterval(-0.5)
                    switch RemoteSwipe.vertical(travel: moved.y, clicked: clicked) {
                    case .down: handle(.down)
                    case .up: handle(.up)
                    case nil: break
                    }
                }
                vertical = nil
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
            lastClick = Date()
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
                } else if ![.select, .playPause, .upArrow, .downArrow].contains(press.type) {
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
                    case .upArrow: handle(.up)
                    case .downArrow: handle(.down)
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

#endif

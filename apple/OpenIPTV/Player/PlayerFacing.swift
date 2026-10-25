import Foundation

@MainActor
protocol GravitySource: AnyObject {
    func start(_ felt: @escaping @MainActor (PlayerFacing.Gravity, TimeInterval) -> Void)
    func stop()
}

@MainActor
final class PlayerFacing {
    enum Orientation: Equatable {
        case portrait, landscapeLeft, landscapeRight

        var isLandscape: Bool { self != .portrait }
    }

    enum Swipe: Equatable { case up, down }

    enum Turn: Equatable {
        case hold(Orientation)
        case follow(Orientation)
    }

    struct Gravity: Equatable { var x, y, z: Double }

    static let swipeTravel = 60.0
    static let minimumRise = 0.4
    static let minimumSideShare = 0.7
    static let settle: TimeInterval = 0.3

    private let gravity: GravitySource
    private let turn: (Turn) -> Void
    private var held: Orientation?
    private var sensing = false
    private var inForeground = true
    private var running = false
    private var leaning: Orientation?
    private var otherSideSince: TimeInterval?

    init(gravity: GravitySource, turn: @escaping (Turn) -> Void) {
        self.gravity = gravity
        self.turn = turn
    }

    func playerAppeared(sensing: Bool) {
        held = nil
        self.sensing = sensing
        syncSensor()
    }

    func playerDisappeared() {
        held = nil
        sensing = false
        syncSensor()
    }

    func app(inForeground: Bool) {
        self.inForeground = inForeground
        syncSensor()
    }

    func swiped(_ swipe: Swipe, from current: Orientation) {
        let turns: Bool = switch swipe {
        case .up: !current.isLandscape
        case .down: current.isLandscape
        }
        guard turns else { return }
        rotate(from: current)
    }

    func rotate(from current: Orientation) {
        hold(current.isLandscape ? .portrait : leaning ?? .landscapeRight)
    }

    func phoneTurned(to orientation: Orientation) {
        guard let held, orientation != held else { return }
        self.held = nil
        turn(.follow(orientation))
    }

    static func swipe(dx: Double, dy: Double) -> Swipe? {
        guard abs(dy) >= swipeTravel, abs(dy) > abs(dx) else { return nil }
        return dy < 0 ? .up : .down
    }

    private func hold(_ orientation: Orientation) {
        held = orientation
        otherSideSince = nil
        turn(.hold(orientation))
    }

    private func syncSensor() {
        let wanted = sensing && inForeground
        guard wanted != running else { return }
        running = wanted
        leaning = nil
        otherSideSince = nil
        if wanted {
            gravity.start { [weak self] sample, time in self?.felt(sample, at: time) }
        } else {
            gravity.stop()
        }
    }

    private func felt(_ sample: Gravity, at time: TimeInterval) {
        leaning = Self.side(of: sample)
        guard let held, held.isLandscape, let leaning, leaning != held else {
            otherSideSince = nil
            return
        }
        let since = otherSideSince ?? time
        otherSideSince = since
        if time - since >= Self.settle { hold(leaning) }
    }

    private static func side(of sample: Gravity) -> Orientation? {
        let rise = (sample.x * sample.x + sample.y * sample.y).squareRoot()
        guard rise >= minimumRise else { return nil }
        let across = sample.x / rise
        // Gravity toward the phone's right edge is interface landscape left.
        if across >= minimumSideShare { return .landscapeLeft }
        if across <= -minimumSideShare { return .landscapeRight }
        return nil
    }
}

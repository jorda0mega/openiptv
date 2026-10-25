import Foundation

/// The phone's gravity, as CoreMotion reports it (iPhone; the Mac tests feed
/// their own).
@MainActor
protocol GravitySource: AnyObject {
    func start(_ felt: @escaping @MainActor (PlayerFacing.Gravity, TimeInterval) -> Void)
    func stop()
}

/// Which way the player faces on iPhone. A swipe up on the picture, or the
/// rotate button, turns it sideways and holds it there, even with Rotation
/// Lock on: to the side the phone leans toward, landscape right when it
/// leans to neither. A swipe down, or the button again, turns it upright.
/// Held sideways in the film player, turning the phone over turns the
/// picture over, so it is never upside down. With Rotation Lock off, a phone
/// turned the other way lets iOS follow the phone again, as before.
@MainActor
final class PlayerFacing {
    /// As UIInterfaceOrientation names them.
    enum Orientation: Equatable {
        case portrait, landscapeLeft, landscapeRight

        var isLandscape: Bool { self != .portrait }
    }

    enum Swipe: Equatable { case up, down }

    enum Turn: Equatable {
        /// Turn there and stay, however the phone is held.
        case hold(Orientation)
        /// Turn there and let iOS follow the phone again.
        case follow(Orientation)
    }

    struct Gravity: Equatable { var x, y, z: Double }

    /// The least travel up or down the picture that's a swipe (points).
    static let swipeTravel = 60.0
    /// How far up from flat the screen must stand to lean either way, and
    /// how far it must lean (the share of its fall across the screen).
    static let standing = 0.4
    static let lean = 0.7
    /// How long the phone must stay over on the other side to turn there.
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

    /// `sensing`: the iPhone film player, which follows the phone over.
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
        guard (swipe == .up) != current.isLandscape else { return }
        rotate(from: current)
    }

    /// The rotate button: sideways when upright, upright when sideways.
    func rotate(from current: Orientation) {
        hold(current.isLandscape ? .portrait : leaning ?? .landscapeRight)
    }

    /// The phone reported turning, which it only does with Rotation Lock off.
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
            gravity.start { [weak self] in self?.felt($0, at: $1) }
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
        let standing = (sample.x * sample.x + sample.y * sample.y).squareRoot()
        guard standing >= Self.standing else { return nil }
        // Falling toward the phone's right edge is the interface's landscape left.
        if sample.x / standing >= lean { return .landscapeLeft }
        if sample.x / standing <= -lean { return .landscapeRight }
        return nil
    }
}

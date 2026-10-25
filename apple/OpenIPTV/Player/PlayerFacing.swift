import Foundation

@MainActor
protocol GravitySource: AnyObject {
    func start(_ felt: @escaping @MainActor (PlayerFacing.Gravity, TimeInterval) -> Void)
    func stop()
}

@MainActor
final class PlayerFacing {
    enum Orientation: Equatable { case portrait, landscapeLeft, landscapeRight }
    enum Swipe: Equatable { case up, down }
    enum Turn: Equatable { case hold(Orientation), follow(Orientation) }
    struct Gravity: Equatable { var x, y, z: Double }

    init(gravity: GravitySource, turn: @escaping (Turn) -> Void) {}
    func playerAppeared(sensing: Bool) {}
    func playerDisappeared() {}
    func app(inForeground: Bool) {}
    func swiped(_ swipe: Swipe, from current: Orientation) {}
    func rotate(from current: Orientation) {}
    func phoneTurned(to orientation: Orientation) {}
    static func swipe(dx: Double, dy: Double) -> Swipe? { nil }
}

#if os(iOS)
import CoreMotion
import UIKit

/// Which ways the app may face, and turning it from the player.
///
/// iOS decides as usual: with Rotation Lock off the video turns with the
/// phone; with it on, nothing turns by itself. The player turns it at will
/// and holds it there (see PlayerFacing). If the phone then reports being
/// turned (it only does with Rotation Lock off), iOS takes over again.
@MainActor
final class PlayerOrientation {
    static let shared = PlayerOrientation()

    /// What the app reports to iOS as allowed right now: on iPhone, upright
    /// outside the player (like the Apple TV app; pages laid out sideways
    /// under a film were left that way); iPad, any way.
    private(set) var allowed: UIInterfaceOrientationMask = PlayerOrientation.browsing

    private static var browsing: UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .phone ? .portrait : .allButUpsideDown
    }
    private lazy var facing = PlayerFacing(gravity: MotionGravity()) { [unowned self] in apply($0) }
    private var observers: [NSObjectProtocol] = []

    private var scene: UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    var isLandscape: Bool { scene?.effectiveGeometry.interfaceOrientation.isLandscape ?? false }

    private var current: PlayerFacing.Orientation {
        switch scene?.effectiveGeometry.interfaceOrientation {
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        default: .portrait
        }
    }

    /// `film`: the film and show player, which follows the phone over on
    /// iPhone (Live TV's vertical swipe changes the channel instead).
    func playerAppeared(film: Bool) {
        allowed = .allButUpsideDown
        facing.playerAppeared(sensing: film && UIDevice.current.userInterfaceIdiom == .phone)
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { PlayerOrientation.shared.phoneTurned() }
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { PlayerOrientation.shared.facing.app(inForeground: false) }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { PlayerOrientation.shared.facing.app(inForeground: true) }
            },
        ]
    }

    /// The player closed: upright again for the rest of the app, then free
    /// to turn as iOS decides.
    func playerDisappeared() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        facing.playerDisappeared()
        if isLandscape { apply(.hold(.portrait)) }
        allowed = Self.browsing
        refresh()
    }

    /// The rotate button: sideways when upright, upright when sideways.
    func toggle() {
        facing.rotate(from: current)
    }

    func swiped(_ swipe: PlayerFacing.Swipe) {
        facing.swiped(swipe, from: current)
    }

    private func phoneTurned() {
        guard let orientation = Self.orientation(of: UIDevice.current.orientation) else { return }
        facing.phoneTurned(to: orientation)
    }

    private static func orientation(of device: UIDeviceOrientation) -> PlayerFacing.Orientation? {
        switch device {
        case .portrait: .portrait
        // The device turned left means the interface is landscape right.
        case .landscapeLeft: .landscapeRight
        case .landscapeRight: .landscapeLeft
        default: nil
        }
    }

    private func apply(_ change: PlayerFacing.Turn) {
        switch change {
        case let .hold(orientation):
            allowed = Self.mask(orientation)
            turn(to: orientation)
        case let .follow(orientation):
            allowed = .allButUpsideDown
            turn(to: orientation)
        }
    }

    private func turn(to orientation: PlayerFacing.Orientation) {
        refresh()
        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: Self.mask(orientation))) { _ in }
    }

    private static func mask(_ orientation: PlayerFacing.Orientation) -> UIInterfaceOrientationMask {
        switch orientation {
        case .portrait: .portrait
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        }
    }

    private func refresh() {
        for window in scene?.windows ?? [] {
            var controller = window.rootViewController
            while let current = controller {
                current.setNeedsUpdateOfSupportedInterfaceOrientations()
                controller = current.presentedViewController
            }
        }
    }
}

/// The phone's gravity from CoreMotion, ten times a second (no permission
/// needed). The simulator has none.
private final class MotionGravity: GravitySource {
    private let manager = CMMotionManager()

    func start(_ felt: @escaping @MainActor (PlayerFacing.Gravity, TimeInterval) -> Void) {
        guard manager.isDeviceMotionAvailable else { return }
        manager.deviceMotionUpdateInterval = 0.1
        manager.startDeviceMotionUpdates(to: .main) { motion, _ in
            guard let motion else { return }
            let gravity = PlayerFacing.Gravity(x: motion.gravity.x, y: motion.gravity.y, z: motion.gravity.z)
            MainActor.assumeIsolated { felt(gravity, motion.timestamp) }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }
}

/// Tells iOS which ways the app may face (see PlayerOrientation).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { PlayerOrientation.shared.allowed }
    }
}
#endif

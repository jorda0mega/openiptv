#if os(iOS)
import UIKit

/// Which ways the app may face, and turning it from the player.
///
/// iOS decides as usual: with Rotation Lock off the video turns with the
/// phone; with it on, nothing turns by itself. The rotate button turns it
/// at will (sideways when upright, upright when sideways) and holds it
/// there. If the phone then reports being turned (it only does with
/// Rotation Lock off), iOS takes over again.
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
    /// Set by the rotate button until the phone itself is turned.
    private var held: UIInterfaceOrientation?
    private var observer: NSObjectProtocol?

    private var scene: UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    var isLandscape: Bool { scene?.effectiveGeometry.interfaceOrientation.isLandscape ?? false }

    func playerAppeared() {
        held = nil
        allowed = .allButUpsideDown
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        observer = NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil,
                                                          queue: .main) { _ in
            MainActor.assumeIsolated { PlayerOrientation.shared.phoneTurned() }
        }
    }

    /// The player closed: upright again for the rest of the app, then free
    /// to turn as iOS decides.
    func playerDisappeared() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
        held = nil
        if isLandscape { turn(to: .portrait) }
        allowed = Self.browsing
        refresh()
    }

    /// The rotate button: sideways when upright, upright when sideways.
    func toggle() {
        let target: UIInterfaceOrientation = isLandscape ? .portrait : .landscapeRight
        held = target
        turn(to: target)
    }

    /// The phone reported turning, so Rotation Lock is off: stop holding
    /// the button's way and let iOS follow the phone.
    private func phoneTurned() {
        guard let held else { return }
        let facing: UIInterfaceOrientation? = switch UIDevice.current.orientation {
        case .portrait: .portrait
        // The device turned left means the interface is landscape right.
        case .landscapeLeft: .landscapeRight
        case .landscapeRight: .landscapeLeft
        default: nil
        }
        guard let facing, facing != held else { return }
        self.held = nil
        allowed = .allButUpsideDown
        refresh()
        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: Self.mask(facing))) { _ in }
    }

    private func turn(to orientation: UIInterfaceOrientation) {
        allowed = Self.mask(orientation)
        refresh()
        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: allowed)) { _ in }
    }

    private static func mask(_ orientation: UIInterfaceOrientation) -> UIInterfaceOrientationMask {
        switch orientation {
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        default: .portrait
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

/// Tells iOS which ways the app may face (see PlayerOrientation).
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        MainActor.assumeIsolated { PlayerOrientation.shared.allowed }
    }
}
#endif

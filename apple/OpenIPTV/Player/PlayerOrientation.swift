#if os(iOS)
import CoreMotion
import UIKit

/// Which ways the app may face, and turning it from the player: the rotate
/// button, and (Settings, on by default) following the phone's own tilt
/// while a video plays, read from the motion sensor so it works even with
/// Rotation Lock on. Elsewhere the app turns as iOS decides.
@MainActor
final class PlayerOrientation {
    static let shared = PlayerOrientation()

    /// What the app reports to iOS as allowed right now.
    private(set) var allowed: UIInterfaceOrientationMask = .allButUpsideDown
    private let motion = CMMotionManager()
    /// The way the phone was last held steadily.
    private var held: UIInterfaceOrientation?
    private var candidate: (orientation: UIInterfaceOrientation, since: Date)?

    private var scene: UIWindowScene? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
    }

    var isLandscape: Bool { scene?.effectiveGeometry.interfaceOrientation.isLandscape ?? false }

    /// The player opened: follow the phone's tilt if asked to.
    func playerAppeared(followTilt: Bool) {
        held = scene?.effectiveGeometry.interfaceOrientation
        guard followTilt, motion.isAccelerometerAvailable else { return }
        motion.accelerometerUpdateInterval = 0.15
        motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            guard let g = data?.acceleration else { return }
            MainActor.assumeIsolated { self?.tilt(x: g.x, y: g.y, z: g.z) }
        }
    }

    /// The player closed: upright again for the rest of the app, then free
    /// to turn as iOS decides.
    func playerDisappeared() {
        motion.stopAccelerometerUpdates()
        candidate = nil
        if isLandscape { turn(to: .portrait) }
        allowed = .allButUpsideDown
        refresh()
    }

    /// The rotate button: sideways when upright, upright when sideways. The
    /// tilt only takes over again once the phone is turned.
    func toggle() {
        turn(to: isLandscape ? .portrait : .landscapeRight)
    }

    private func tilt(x: Double, y: Double, z: Double) {
        // Lying flat says nothing about which way it's held.
        guard abs(z) < 0.85 else { candidate = nil; return }
        let reading: UIInterfaceOrientation?
        if abs(x) > 0.6, abs(x) > abs(y) + 0.25 {
            // Gravity to the left means the phone's left side is down.
            reading = x < 0 ? .landscapeRight : .landscapeLeft
        } else if y < -0.6, abs(y) > abs(x) + 0.25 {
            reading = .portrait
        } else {
            reading = nil
        }
        guard let reading, reading != held else { candidate = nil; return }
        // Held that way for a moment, not just passing through.
        if let candidate, candidate.orientation == reading {
            guard Date().timeIntervalSince(candidate.since) >= 0.3 else { return }
            held = reading
            self.candidate = nil
            turn(to: reading)
        } else {
            candidate = (reading, Date())
        }
    }

    private func turn(to orientation: UIInterfaceOrientation) {
        let mask: UIInterfaceOrientationMask = switch orientation {
        case .landscapeLeft: .landscapeLeft
        case .landscapeRight: .landscapeRight
        default: .portrait
        }
        allowed = orientation.isLandscape ? .landscape : .portrait
        refresh()
        scene?.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { _ in }
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

import Foundation
import Network
#if canImport(UIKit)
import UIKit
#endif

/// Whether downloading generously is fine right now: an unmetered
/// connection (not cellular / Low Data Mode) and room on disk.
final class NetworkStatus: @unchecked Sendable {
    static let shared = NetworkStatus()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var unmeteredValue = true
    /// The connection has been seen (until then, it's not known to be
    /// unmetered: nothing is fetched speculatively).
    private var known = false
    private var networkValue = Conditions.Network.unknown
    private var freeDiskRead: (bytes: Int64, at: ContinuousClock.Instant)?
    #if DEBUG && canImport(Libmpv)
    private var path: NWPath?
    #endif

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            lock.lock()
            unmeteredValue = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            known = true
            networkValue = path.status != .satisfied ? .unknown : path.isConstrained ? .constrained : path.isExpensive ? .expensive : .unmetered
            #if DEBUG && canImport(Libmpv)
            self.path = path
            #endif
            lock.unlock()
            #if DEBUG && canImport(Libmpv)
            LivePerf.sayPath(path)
            #endif
        }
        monitor.start(queue: DispatchQueue(label: "openiptv.network-status"))
    }

    #if DEBUG && canImport(Libmpv)
    func sayLivePath() {
        if let path = lock.withLock({ path }) { LivePerf.sayPath(path) }
    }
    #endif

    var unmetered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return unmeteredValue
    }

    /// Unmetered, and known to be: speculative work (warm players, pages
    /// and pictures fetched ahead) needs this.
    var knownUnmetered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return known && unmeteredValue
    }

    var network: Conditions.Network {
        lock.withLock { networkValue }
    }

    /// Live TV keeps what's been watched on disk only with plenty of room
    /// (8 GB free): the file grows with the session until it closes.
    var roomForTimeshift: Bool {
        freeDisk >= 8_000_000_000
    }

    var freeDisk: Int64 {
        if let read = lock.withLock({ freeDiskRead }), ContinuousClock.now - read.at < .seconds(60) { return read.bytes }
        let caches = FileManager.default.temporaryDirectory
        #if os(tvOS)
        let free = Int64((try? caches.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity ?? 0)
        #else
        let free = (try? caches.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        #endif
        lock.withLock { freeDiskRead = (free, .now) }
        return free
    }
}

extension Conditions {
    @MainActor static func current() -> Conditions {
        Conditions(network: NetworkStatus.shared.network, playing: PlaybackActivity.isPlaying,
                   lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermal: ProcessInfo.processInfo.thermalState,
                   memoryWarned: MemoryWarnings.recent, freeDisk: NetworkStatus.shared.freeDisk)
    }
}

@MainActor
enum MemoryWarnings {
    private static var last: ContinuousClock.Instant?

    static var recent: Bool {
        last.map { ContinuousClock.now - $0 < .seconds(30) } ?? false
    }

    #if canImport(UIKit)
    private static var observer: NSObjectProtocol?

    static func watch() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil,
                                                          queue: .main) { _ in
            MainActor.assumeIsolated { last = .now }
        }
    }
    #endif
}

/// Whether something is playing: work done ahead of time (pictures, pages,
/// warm-ups) waits meanwhile, so the stream has the connection to itself.
enum PlaybackActivity {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0

    static var isPlaying: Bool { lock.withLock { count > 0 } }
    static func began() { lock.withLock { count += 1 } }
    static func ended() { lock.withLock { count = max(0, count - 1) } }
}

#if canImport(UIKit)
/// The screen kept on while something plays, as Apple's player does by
/// itself (libmpv doesn't): the Apple TV slept, and the phone locked, in
/// the middle of a film. Off when paused or closed, so the screen saver
/// and sleep come as usual then. Each player says for itself.
@MainActor
enum ScreenAwake {
    private static var playing: Set<UUID> = []

    static func set(_ player: UUID, playing on: Bool) {
        if on { playing.insert(player) } else { playing.remove(player) }
        UIApplication.shared.isIdleTimerDisabled = !playing.isEmpty
    }
}
#endif

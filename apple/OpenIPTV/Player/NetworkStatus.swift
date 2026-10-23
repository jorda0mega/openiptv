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
    private var satisfied = true
    #if DEBUG
    private var debugOnline = true
    #endif
    /// The connection has been seen (until then, it's not known to be
    /// unmetered: nothing is fetched speculatively).
    private var known = false
    private var networkValue = Conditions.Network.unknown
    private var freeDiskRead: (free: Conditions.FreeDisk, at: ContinuousClock.Instant)?
    #if DEBUG && canImport(Libmpv)
    private var path: NWPath?
    #endif

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            lock.lock()
            satisfied = path.status == .satisfied
            unmeteredValue = satisfied && !path.isExpensive && !path.isConstrained
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
        #if DEBUG
        if let url = ProcessInfo.processInfo.environment["OPENREEL_DEBUG_ONLINE_URL"].flatMap(URL.init(string:)) { followDebugOnline(url) }
        #endif
    }

    #if DEBUG
    private func followDebugOnline(_ url: URL) {
        let session = URLSession(configuration: .ephemeral)
        Task.detached { [weak self] in
            while let self {
                if let (data, _) = try? await session.data(from: url),
                   let answer = try? JSONSerialization.jsonObject(with: data) as? [String: Bool], let online = answer["online"] {
                    self.lock.withLock { self.debugOnline = online }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }
    #endif

    #if DEBUG && canImport(Libmpv)
    func sayLivePath() {
        if let path = lock.withLock({ path }) { LivePerf.sayPath(path) }
    }
    #endif

    var online: Bool {
        lock.withLock {
            #if DEBUG
            return satisfied && debugOnline
            #else
            return satisfied
            #endif
        }
    }

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
        freeDisk.bytes >= 8_000_000_000
    }

    var freeDisk: Conditions.FreeDisk {
        if let read = lock.withLock({ freeDiskRead }), ContinuousClock.now - read.at < .seconds(60) { return read.free }
        let caches = FileManager.default.temporaryDirectory
        #if os(tvOS)
        let free = Conditions.FreeDisk(bytes: Int64((try? caches.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity ?? 0),
                                       countsPurgeable: false)
        #else
        let free = Conditions.FreeDisk(bytes: (try? caches.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0, countsPurgeable: true)
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

/// Bytes fetched ahead over a phone network, kept on this device with the
/// local day they came on: no title, address or login.
final class PhoneNetworkUse: @unchecked Sendable {
    static let shared = PhoneNetworkUse(defaults: .standard)

    private static let key = "phoneNetworkUse"
    private let defaults: UserDefaults
    private let calendar: Calendar
    private let lock = NSLock()
    private var kept: (day: String, bytes: Int64)

    init(defaults: UserDefaults, calendar: Calendar = .autoupdatingCurrent) {
        self.defaults = defaults
        self.calendar = calendar
        let stored = defaults.dictionary(forKey: Self.key)
        kept = (stored?["day"] as? String ?? "", (stored?["bytes"] as? NSNumber)?.int64Value ?? 0)
    }

    func usedToday(at now: Date = Date()) -> Int64 {
        let today = day(of: now)
        return lock.withLock { kept.day == today ? kept.bytes : 0 }
    }

    func noteArrived(_ bytes: Int, over network: Conditions.Network, at now: Date = Date()) {
        guard network == .expensive, bytes > 0 else { return }
        let today = day(of: now)
        lock.withLock {
            kept = (today, (kept.day == today ? kept.bytes : 0) + Int64(bytes))
            defaults.set(["day": kept.day, "bytes": kept.bytes], forKey: Self.key)
        }
    }

    private func day(of date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
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

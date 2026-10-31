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

    private let queue = DispatchQueue(label: "openiptv.network-status")
    #if DEBUG
    private let debugNetwork: DebugNetwork?
    /// On `queue`: whether -debugNetwork's time has come, and the link last seen.
    private var debugSwitched = false
    private var seen: Seen?

    private convenience init() {
        self.init(debugNetwork: UserDefaults.standard.string(forKey: "debugNetwork"))
    }

    /// UI tests: -debugNetwork metered or lowData, or metered@120 from 120 s
    /// after launch. The simulator's link is the Mac's, never a phone network.
    init(debugNetwork: String?) {
        self.debugNetwork = DebugNetwork(debugNetwork)
        debugSwitched = self.debugNetwork?.after == .zero
        start()
        if let after = self.debugNetwork?.after, after > .zero {
            queue.asyncAfter(deadline: .now() + after / .seconds(1)) { [weak self] in
                guard let self else { return }
                debugSwitched = true
                if let seen { take(seen) }
            }
        }
    }
    #else
    private init() {
        start()
    }
    #endif

    private struct Seen {
        let satisfied: Bool, expensive: Bool, constrained: Bool
    }

    private func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            #if DEBUG && canImport(Libmpv)
            lock.withLock { self.path = path }
            #endif
            take(Seen(satisfied: path.status == .satisfied, expensive: path.isExpensive, constrained: path.isConstrained))
            #if DEBUG && canImport(Libmpv)
            LivePerf.sayPath(path)
            #endif
        }
        monitor.start(queue: queue)
        #if DEBUG
        if let url = ProcessInfo.processInfo.environment["OPENREEL_DEBUG_ONLINE_URL"].flatMap(URL.init(string:)) { followDebugOnline(url) }
        #endif
    }

    private func take(_ link: Seen) {
        var (expensive, constrained) = (link.expensive, link.constrained)
        #if DEBUG
        seen = link
        switch debugSwitched ? debugNetwork?.reading : nil {
        case .metered: expensive = true
        case .lowData: constrained = true
        case nil: break
        }
        #endif
        let changed = lock.withLock {
            satisfied = link.satisfied
            unmeteredValue = satisfied && !expensive && !constrained
            known = true
            let was = networkValue
            networkValue = !satisfied ? .unknown : constrained ? .constrained : expensive ? .expensive : .unmetered
            return networkValue != was
        }
        if changed { Task { @MainActor in Lane.conditionsChangedEverywhere() } }
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

#if DEBUG
/// -debugNetwork's value: a phone network (metered) or Low Data Mode
/// (lowData), from launch or from that many seconds after it (metered@120).
struct DebugNetwork {
    enum Reading: String { case metered, lowData }

    let reading: Reading
    let after: Duration

    init?(_ value: String?) {
        let parts = (value ?? "").split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let reading = Reading(rawValue: parts[0]), let seconds = parts.count == 1 ? 0 : Double(parts[1]), seconds >= 0
        else { return nil }
        (self.reading, after) = (reading, .seconds(seconds))
    }
}
#endif

extension Conditions {
    @MainActor static func current() -> Conditions {
        Conditions(network: NetworkStatus.shared.network, playing: PlaybackActivity.isPlaying,
                   lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, thermal: ProcessInfo.processInfo.thermalState,
                   memoryWarned: MemoryWarnings.recent, freeDisk: NetworkStatus.shared.freeDisk,
                   phoneNetwork: .chosen(), usedToday: PhoneNetworkUse.shared.usedToday())
    }
}

/// Bytes fetched ahead over a phone network, kept on this device with the
/// local day they came on: no title, address or login.
final class PhoneNetworkUse: @unchecked Sendable {
    static let shared = PhoneNetworkUse(defaults: .standard)

    private static let key = "phoneNetworkUse"
    private let defaults: UserDefaults
    private let calendar: Calendar
    private let network: @Sendable () -> Conditions.Network
    private let lock = NSLock()
    private var kept: (day: String, bytes: Int64)
    private var underWay: Int64 = 0

    init(defaults: UserDefaults, calendar: Calendar = .autoupdatingCurrent,
         network: @escaping @Sendable () -> Conditions.Network = { NetworkStatus.shared.network }) {
        self.defaults = defaults
        self.calendar = calendar
        self.network = network
        let stored = defaults.dictionary(forKey: Self.key)
        kept = (stored?["day"] as? String ?? "", (stored?["bytes"] as? NSNumber)?.int64Value ?? 0)
    }

    func usedToday(at now: Date = Date()) -> Int64 {
        let today = day(of: now)
        return lock.withLock { kept.day == today ? kept.bytes : 0 }
    }

    /// Asked before a read ahead goes, as the choice says: nil refuses it,
    /// else it takes what it returns until noteArrived gives it back. Under
    /// 150 MB a day it goes only if it fits beside the reads under way.
    func reserve(_ bytes: Int64, at now: Date = Date()) -> Int64? {
        switch (network(), PhoneNetworkFilms.chosen(in: defaults)) {
        case (.constrained, _), (.expensive, .none):
            return nil
        case (.expensive, .daily):
            let today = day(of: now)
            return lock.withLock {
                guard (kept.day == today ? kept.bytes : 0) + underWay + bytes <= PhoneNetworkFilms.dailyBytes else { return nil }
                underWay += bytes
                return bytes
            }
        default:
            return 0
        }
    }

    func noteArrived(_ bytes: Int, reserved: Int64, at now: Date = Date()) {
        noteArrived(bytes, reserved: reserved, over: network(), at: now)
    }

    func noteArrived(_ bytes: Int, over network: Conditions.Network, at now: Date = Date()) {
        noteArrived(bytes, reserved: 0, over: network, at: now)
    }

    private func noteArrived(_ bytes: Int, reserved: Int64, over network: Conditions.Network, at now: Date) {
        let today = day(of: now)
        lock.withLock {
            underWay -= reserved
            guard network == .expensive, bytes > 0 else { return }
            kept = (today, (kept.day == today ? kept.bytes : 0) + Int64(bytes))
            defaults.set(["day": kept.day, "bytes": kept.bytes], forKey: Self.key)
            #if DEBUG
            sinceLaunch += Int64(bytes)
            #endif
        }
    }

    #if DEBUG
    private var sinceLaunch: Int64 = 0

    /// A start's line on a phone network: what came ahead over it.
    func debugReadout(over network: Conditions.Network) -> String {
        guard network == .expensive else { return "" }
        return String(format: " | phone network: %.1f MB ahead since launch, %.1f MB today",
                      Double(lock.withLock { sinceLaunch }) / 1e6, Double(usedToday()) / 1e6)
    }
    #endif

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
    enum Kind { case film, live }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0

    static var isPlaying: Bool { lock.withLock { count > 0 } }
    static func began(_ kind: Kind) {
        lock.withLock { count += 1 }
        if kind == .film { HTTP.turns.hold() }
    }

    /// The lanes hear of it: a fetch ahead refused while it played goes now.
    static func ended(_ kind: Kind) {
        lock.withLock { count = max(0, count - 1) }
        if kind == .film { HTTP.turns.release() }
        Task { @MainActor in Lane.conditionsChangedEverywhere() }
    }
}

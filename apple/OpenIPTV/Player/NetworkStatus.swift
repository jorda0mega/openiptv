import Foundation
import Network

/// Whether downloading generously is fine right now: an unmetered
/// connection (not cellular / Low Data Mode) and room on disk.
final class NetworkStatus: @unchecked Sendable {
    static let shared = NetworkStatus()

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var unmeteredValue = true

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            lock.lock()
            unmeteredValue = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "openiptv.network-status"))
    }

    var unmetered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return unmeteredValue
    }

    /// How a file should be buffered: the whole rest of it on disk when the
    /// connection is unmetered and there's room (leaving 3 GB free, at most
    /// 6 GB), otherwise a few minutes in memory.
    var fileReadahead: MPVPlayer.Readahead {
        guard unmetered else { return .modest }
        let caches = FileManager.default.temporaryDirectory
        #if os(tvOS)
        let free = Int64((try? caches.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity ?? 0)
        #else
        let free = (try? caches.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        #endif
        let room = min(free - 3_000_000_000, 6_000_000_000)
        return room >= 1_000_000_000 ? .whole(bytes: room) : .modest
    }
}

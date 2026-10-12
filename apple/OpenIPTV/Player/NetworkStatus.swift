import Foundation
import Network

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

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            lock.lock()
            unmeteredValue = path.status == .satisfied && !path.isExpensive && !path.isConstrained
            known = true
            lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "openiptv.network-status"))
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

    /// How a file should be buffered: generously (in memory) when the
    /// connection is unmetered, otherwise a couple of minutes.
    var fileReadahead: MPVPlayer.Readahead {
        unmetered ? .generous : .modest
    }

    /// Live TV keeps what's been watched on disk only with plenty of room
    /// (8 GB free): the file grows with the session until it closes.
    var roomForTimeshift: Bool {
        let caches = FileManager.default.temporaryDirectory
        #if os(tvOS)
        let free = Int64((try? caches.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity ?? 0)
        #else
        let free = (try? caches.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage ?? 0
        #endif
        return free >= 8_000_000_000
    }
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

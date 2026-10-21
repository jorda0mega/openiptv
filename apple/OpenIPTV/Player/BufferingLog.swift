#if DEBUG
import Foundation

/// Counts and times only.
struct BufferingLog {
    private(set) var rebuffers: [Double] = []
    private(set) var opens: [(converted: Bool, firstFrame: Double, waits: ServerWaits?)] = []
    private(set) var jumps: [(seconds: Double, megabytes: Double)] = []
    private(set) var audioSwitches: [Double] = []
    var cacheSeconds = 0.0
    var bytesPerSecond = 0.0
    private var openingConverted: Bool?
    private var stalledSince: Double?
    private var audioAskedAt: Double?

    /// Until its first frame, a stall is the open's own wait.
    mutating func opening(converted: Bool) {
        openingConverted = converted
        stalledSince = nil
    }

    mutating func firstFrame(after seconds: Double, waits: ServerWaits? = nil) {
        guard let converted = openingConverted else { return }
        opens.append((converted, seconds, waits))
        openingConverted = nil
    }

    mutating func stalled(_ stalled: Bool, at now: Double) {
        guard openingConverted == nil else { return }
        if stalled { return stalledSince = now }
        guard let since = stalledSince else { return }
        rebuffers.append(now - since)
        stalledSince = nil
    }

    mutating func seeked(after seconds: Double, megabytes: Double) {
        jumps.append((seconds, megabytes))
    }

    mutating func audioAsked(at now: Double) {
        audioAskedAt = now
    }

    mutating func audioReconfigured(at now: Double) {
        guard let asked = audioAskedAt else { return }
        audioSwitches.append(now - asked)
        audioAskedAt = nil
    }

    var readout: String {
        func ms(_ values: [Double]) -> String { values.map { String(Int(($0 * 1000).rounded())) }.joined(separator: " ") }
        var parts = ["rebuffers \(rebuffers.count)" + (rebuffers.isEmpty ? "" : ": \(ms(rebuffers)) ms")
            + (stalledSince == nil ? "" : ", stalled now")]
        parts.append(String(format: "cache %.0f s", cacheSeconds))
        parts.append(String(format: "speed %.1f MB/s", bytesPerSecond / 1e6))
        parts.append("opens: " + opens.map { open in
            String(format: "%@ %.2f s", open.converted ? "converted" : "original", open.firstFrame)
                + (open.waits.map { $0.split(of: open.firstFrame) } ?? "")
        }.joined(separator: ", "))
        if !jumps.isEmpty {
            parts.append("jumps: " + jumps.map { String(format: "%.0f ms %.1f MB", $0.seconds * 1000, $0.megabytes) }.joined(separator: ", "))
        }
        if !audioSwitches.isEmpty { parts.append("audio: \(ms(audioSwitches)) ms") }
        return parts.joined(separator: " | ")
    }
}

/// From the ask to the server's first line back.
struct ServerWaits {
    enum Kind: String { case playlist = "p", segment = "s" }
    private(set) var waits: [(kind: Kind, from: Double, to: Double)] = []
    private var asking: [(connection: Int, kind: Kind, from: Double)] = []
    private var segmentNext = false

    /// ffmpeg names a segment just before it asks for it.
    mutating func segmentComing() {
        segmentNext = true
    }

    mutating func asked(on connection: Int, at now: Double) {
        asking.append((connection, segmentNext ? .segment : .playlist, now))
        segmentNext = false
    }

    mutating func answered(on connection: Int, at now: Double) {
        guard let index = asking.firstIndex(where: { $0.connection == connection }) ?? asking.indices.first else { return }
        let asked = asking.remove(at: index)
        waits.append((asked.kind, asked.from, now))
    }

    mutating func fetched(_ kind: Kind, from: Double, to: Double) {
        waits.append((kind, from, to))
    }

    /// Requests waiting at the same time count once.
    var server: Double {
        var total = 0.0, reached = -Double.infinity
        for wait in waits.sorted(by: { $0.from < $1.from }) {
            total += max(0, wait.to - max(wait.from, reached))
            reached = max(reached, wait.to)
        }
        return total
    }

    func split(of open: Double) -> String {
        let each = waits.sorted { $0.from < $1.from }.map { "\($0.kind.rawValue)\(Int((($0.to - $0.from) * 1000).rounded()))" }
        return String(format: ": server %.0f ms client %.0f ms (%@)", server * 1000, max(0, open - server) * 1000,
                      each.joined(separator: " "))
    }
}

/// ffmpeg's log is every player's, so only one open is timed at a time.
enum OpenRequests {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: ServerWaits?

    static func begin() {
        lock.withLock { current = ServerWaits() }
    }

    static func note(_ change: (inout ServerWaits) -> Void) {
        lock.withLock {
            guard var waits = current else { return }
            change(&waits)
            current = waits
        }
    }

    static func finish() -> ServerWaits? {
        lock.withLock {
            defer { current = nil }
            return current
        }
    }
}
#endif

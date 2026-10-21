#if DEBUG
import Foundation

/// UI tests: how a film buffered since it opened. Counts and times only.
struct BufferingLog {
    private(set) var rebuffers: [Double] = []
    private(set) var opens: [(converted: Bool, firstFrame: Double)] = []
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

    mutating func firstFrame(after seconds: Double) {
        guard let converted = openingConverted else { return }
        opens.append((converted, seconds))
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
        parts.append("opens: " + opens.map { String(format: "%@ %.2f s", $0.converted ? "converted" : "original", $0.firstFrame) }
            .joined(separator: ", "))
        if !jumps.isEmpty {
            parts.append("jumps: " + jumps.map { String(format: "%.0f ms %.1f MB", $0.seconds * 1000, $0.megabytes) }.joined(separator: ", "))
        }
        if !audioSwitches.isEmpty { parts.append("audio: \(ms(audioSwitches)) ms") }
        return parts.joined(separator: " | ")
    }
}
#endif

#if DEBUG
import Foundation

struct SwitchGap {
    enum Kind: String { case start, `return` }

    private struct Sample {
        var wall: Double
        var time: Double?
        var audio: Double?
        var paused: Bool
        var drops: Int?
    }

    let kind: Kind
    let began: Double
    private(set) var seeks = 0
    private(set) var restarts = 0
    private var samples: [Sample] = []
    private var frames: [Double] = []

    init(_ kind: Kind, at began: Double) {
        self.kind = kind
        self.began = began
    }

    mutating func seeked() { seeks += 1 }
    mutating func restarted() { restarts += 1 }

    mutating func sample(at wall: Double, time: Double?, audio: Double?, paused: Bool = false, drops: Int? = nil) {
        samples.append(Sample(wall: wall, time: time, audio: audio, paused: paused, drops: drops))
    }

    mutating func frame(at wall: Double) { frames.append(wall) }

    func readout(until end: Double) -> String {
        "\(kind.rawValue) seeks=\(seeks) restarts=\(restarts) paused=\(ms(pausedFor)) drops=\(dropped) time=\(stall(\.time)) "
            + "audio=\(stall(\.audio)) frames=\(ms(longestWait(until: end)))"
    }

    /// "unread" when the clock was read in fewer than half the samples.
    private func stall(_ value: (Sample) -> Double?) -> String {
        guard samples.filter({ value($0) != nil }).count * 2 >= samples.count else { return "unread" }
        return "\(ms(stretchesPlaying.map { Self.longestStall(Self.clock($0, value)) }.max() ?? 0))"
    }

    private var dropped: String {
        let counts = samples.compactMap(\.drops)
        guard counts.count >= 2, let first = counts.first, let last = counts.last, last >= first else { return "unread" }
        return "\(last - first)"
    }

    private var stretchesPlaying: [[Sample]] {
        samples.split(whereSeparator: \.paused).map(Array.init)
    }

    private static func clock(_ samples: [Sample], _ value: (Sample) -> Double?) -> [(wall: Double, position: Double)] {
        samples.compactMap { sample in value(sample).map { (sample.wall, $0) } }
    }

    private var pausedFor: Double {
        zip(samples, samples.dropFirst()).filter { $0.0.paused }.reduce(0) { $0 + $1.1.wall - $1.0.wall }
    }

    static func longestStall(_ readings: [(wall: Double, position: Double)]) -> Double {
        guard let first = readings.first else { return 0 }
        var leastBehind = 0.0, longest = 0.0
        for reading in readings {
            let behind = (reading.wall - first.wall) - (reading.position - first.position)
            leastBehind = min(leastBehind, behind)
            longest = max(longest, behind - leastBehind)
        }
        return longest
    }

    private func longestWait(until end: Double) -> Double {
        var last = began, longest = 0.0
        for frame in frames.sorted() where frame >= began {
            longest = max(longest, frame - last)
            last = frame
        }
        return max(longest, end - last)
    }

    private func ms(_ seconds: Double) -> Int { Int((seconds * 1000).rounded()) }
}
#endif

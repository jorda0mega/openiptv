#if DEBUG
import Foundation

/// What stopped while the picture moved into the Picture in Picture window
/// or back: libmpv's seeks and restarts, how long it was paused, the
/// longest stall of the film's clock and of the sound against the wall
/// clock while it played, and the longest wait between frames reaching the
/// picture.
struct SwitchGap {
    enum Kind: String { case start, `return` }

    private struct Sample {
        var wall: Double
        var time: Double?
        var audio: Double?
        var paused: Bool
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

    mutating func sample(at wall: Double, time: Double?, audio: Double?, paused: Bool = false) {
        samples.append(Sample(wall: wall, time: time, audio: audio, paused: paused))
    }

    mutating func frame(at wall: Double) { frames.append(wall) }

    /// Milliseconds: "start seeks=0 restarts=0 paused=0 time=12 audio=8 frames=45".
    func readout(until end: Double) -> String {
        let playing = stretchesPlaying
        let time = playing.map { Self.longestStall(Self.clock($0, \.time)) }.max() ?? 0
        let audio = playing.map { Self.longestStall(Self.clock($0, \.audio)) }.max() ?? 0
        return "\(kind.rawValue) seeks=\(seeks) restarts=\(restarts) paused=\(ms(pausedFor)) time=\(ms(time)) audio=\(ms(audio)) "
            + "frames=\(ms(longestWait(until: end)))"
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

    /// How far the clock fell behind the wall clock over any stretch: a
    /// clock read late but moved on as far is not a stall.
    static func longestStall(_ readings: [(wall: Double, position: Double)]) -> Double {
        guard let first = readings.first else { return 0 }
        var least = 0.0, longest = 0.0
        for reading in readings {
            let behind = (reading.wall - first.wall) - (reading.position - first.position)
            least = min(least, behind)
            longest = max(longest, behind - least)
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

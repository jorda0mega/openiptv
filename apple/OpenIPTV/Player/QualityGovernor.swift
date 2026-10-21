import Foundation

/// Chooses between the original file and lower-bitrate versions Emby
/// converts on the fly, Netflix-style: drop quality before the buffer runs
/// dry rather than stop to buffer, and climb back once there's headroom.
///
/// Fed once a second with the buffer ahead (seconds) and the download
/// speed while downloading. `nil` bitrate means the original file.
struct QualityGovernor {
    /// Bitrates (bits/s) the server is asked to convert to, best first.
    static let ladder = [20_000_000, 12_000_000, 8_000_000, 5_000_000, 3_000_000, 1_500_000]

    enum Decision: Equatable {
        case original
        case converted(Int)
    }

    /// Bitrate of the original file, when the server reports it.
    let original: Int?
    private(set) var current: Int?
    /// Smoothed download speed in bits/s while data is arriving.
    private(set) var speed: Double = 0
    /// Connection speed measured by test downloads of the original while
    /// playing a converted version (whose own pace is the server's).
    private(set) var probeSpeed: Double = 0

    private var lastSwitch: Date
    private var qualityPlaybackStartedAt: Date?
    /// The original wouldn't play here; stay on converted versions.
    private var originalBlocked = false
    private var lowSince: Date?
    private var headroomSince: Date?

    init(original: Int?, current: Int? = nil, now: Date = Date()) {
        self.original = original
        self.current = current
        lastSwitch = current == nil ? .distantPast : now
    }

    /// The best quality a connection of `bitsPerSecond` keeps up with, for
    /// starting playback from last session's measurement.
    static func startingQuality(original: Int?, knownSpeed bitsPerSecond: Double?) -> Int? {
        guard let original, let speed = bitsPerSecond, speed > 0, Double(original) > speed * 0.8 else { return nil }
        return ladder.first { Double($0) <= speed * 0.7 } ?? ladder.last
    }

    private var currentBitrate: Double { Double(current ?? original ?? Self.ladder[0]) }

    /// `left`: seconds from here to the end of the file, when known.
    mutating func observe(buffer: Double, bytesPerSecond: Double, stalled: Bool, left: Double? = nil,
                          now: Date = Date()) -> Decision? {
        guard lastSwitch == .distantPast || qualityPlaybackStartedAt.map({ now.timeIntervalSince($0) >= 10 }) ?? false else { return nil }
        // With plenty buffered the player only tops up as fast as it plays,
        // so slow samples then say nothing about the connection: let the
        // estimate rise but not fall. With little buffered it downloads flat
        // out, and every sample counts.
        if bytesPerSecond > 0 {
            let sample = bytesPerSecond * 8
            let blended = speed == 0 ? sample : speed * 0.7 + sample * 0.3
            speed = buffer >= 30 ? max(speed, blended) : blended
        }
        let sinceSwitch = now.timeIntervalSince(lastSwitch)
        // Buffered to the file's end: nothing more to download, so a short
        // buffer then says nothing about the connection (it dropped an
        // episode's last seconds to a converted stream, and the next episode
        // never came).
        let toTheEnd = left.map { buffer >= $0 - 1 } ?? false

        // Down: a stall, or the buffer staying low while the connection
        // can't keep up with this bitrate.
        if !toTheEnd, buffer < 5, speed > 0, speed < currentBitrate * 1.1 {
            lowSince = lowSince ?? now
        } else {
            lowSince = nil
        }
        let starving = lowSince.map { now.timeIntervalSince($0) >= 2 } ?? false
        if (stalled && !toTheEnd) || starving, sinceSwitch >= 10 {
            let budget = speed > 0 ? speed * 0.7 : currentBitrate / 2
            guard let lower = Self.ladder.first(where: { Double($0) <= budget && Double($0) < currentBitrate })
                ?? (currentBitrate > Double(Self.ladder.last!) ? Self.ladder.last : nil)
            else { return nil }
            return switchTo(lower, now: now)
        }

        // Up: the connection comfortably faster than a higher quality for
        // half a minute (measured by test downloads while converted); go
        // straight to the best it fits.
        guard current != nil, let target = upTarget() else {
            headroomSince = nil
            return nil
        }
        if buffer >= 10 || probeSpeed > 0 {
            headroomSince = headroomSince ?? now
        } else {
            headroomSince = nil
        }
        if let since = headroomSince, now.timeIntervalSince(since) >= 30, sinceSwitch >= 30 {
            return switchTo(target, now: now)
        }
        return nil
    }

    /// The best quality above the current one the connection fits with
    /// 50% to spare: the original when it fits, else a higher step.
    private func upTarget() -> Decision? {
        guard let current else { return nil }
        let capacity = max(speed, probeSpeed)
        if !originalBlocked, let original, Double(original) * 1.5 <= capacity { return .original }
        guard let step = Self.ladder.first(where: { $0 > current && Double($0) * 1.5 <= capacity }),
              originalBlocked || (original.map({ step < $0 }) ?? true)
        else { return nil }
        return .converted(step)
    }

    mutating func notePlaying(now: Date = Date()) {
        qualityPlaybackStartedAt = qualityPlaybackStartedAt ?? now
    }

    /// Going back to the original failed: return to `bitrate` and don't
    /// try the original again.
    mutating func revert(to bitrate: Int, now: Date = Date()) {
        originalBlocked = true
        current = bitrate
        lastSwitch = now
        qualityPlaybackStartedAt = nil
        headroomSince = nil
    }

    mutating func noteProbe(bitsPerSecond: Double) {
        probeSpeed = probeSpeed == 0 ? bitsPerSecond : probeSpeed * 0.5 + bitsPerSecond * 0.5
    }

    private mutating func switchTo(_ bitrate: Int, now: Date) -> Decision {
        switchTo(.converted(bitrate), now: now)
    }

    private mutating func switchTo(_ decision: Decision, now: Date) -> Decision {
        if case let .converted(bitrate) = decision { current = bitrate } else { current = nil }
        lastSwitch = now
        qualityPlaybackStartedAt = nil
        lowSince = nil
        headroomSince = nil
        probeSpeed = 0
        return decision
    }
}

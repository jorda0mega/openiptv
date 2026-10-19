import Foundation

/// The server cuts some channels mid-stream, some again and again: a cut
/// copy opens again in place after a growing wait, and one cut `limit`
/// times within `span` is given up for the next copy.
struct LiveCuts {
    static let waits: [Double] = [0, 1, 2, 4, 8]
    static let limit = 4
    static let span: TimeInterval = 180
    static let calm: TimeInterval = 60

    enum Next: Equatable {
        case reopen(after: Double)
        case giveUp
    }

    private var copy: String?
    private var cuts: [Date] = []
    private var backoff = 0
    private var playingSince: Date?

    mutating func played(_ id: String, at now: Date = Date()) {
        follow(id)
        playingSince = now
    }

    mutating func cut(_ id: String, at now: Date = Date()) -> Next {
        follow(id)
        if let playingSince, now.timeIntervalSince(playingSince) >= Self.calm { backoff = 0 }
        playingSince = nil
        cuts = cuts.filter { now.timeIntervalSince($0) < Self.span } + [now]
        guard cuts.count < Self.limit else { return .giveUp }
        defer { backoff += 1 }
        return .reopen(after: Self.waits[min(backoff, Self.waits.count - 1)])
    }

    private mutating func follow(_ id: String) {
        guard id != copy else { return }
        self = LiveCuts()
        copy = id
    }
}

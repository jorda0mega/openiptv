import Foundation

/// The provider's server cuts some channels mid-stream, some again and again.
struct LiveCuts {
    static let reopenWaits: [Double] = [0, 1, 2, 4, 8]
    static let cutsThatGiveUp = 4
    static let cutsCountedWithin: TimeInterval = 180
    static let playThatResetsTheWait: TimeInterval = 60

    enum Next: Equatable {
        case reopen(after: Double)
        case giveUp
    }

    private var copy: String?
    private var cuts: [Date] = []
    private var backoff = 0
    private var playingSince: Date?

    mutating func played(_ id: String, at now: Date = Date()) {
        startOver(unless: id)
        playingSince = now
    }

    mutating func cut(_ id: String, at now: Date = Date()) -> Next {
        startOver(unless: id)
        if let playingSince, now.timeIntervalSince(playingSince) >= Self.playThatResetsTheWait { backoff = 0 }
        playingSince = nil
        cuts = cuts.filter { now.timeIntervalSince($0) < Self.cutsCountedWithin } + [now]
        guard cuts.count < Self.cutsThatGiveUp else { return .giveUp }
        let wait = Self.reopenWaits[min(backoff, Self.reopenWaits.count - 1)]
        backoff += 1
        return .reopen(after: wait)
    }

    private mutating func startOver(unless id: String) {
        guard id != copy else { return }
        self = LiveCuts()
        copy = id
    }
}

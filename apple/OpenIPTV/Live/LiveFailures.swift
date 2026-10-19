import Foundation

/// Live channels that sent no picture on this device, and when. A channel
/// counts as failed until it plays, or until the check its failure
/// schedules (AppModel.failureMaxAge later) finds it not failed again since.
struct LiveFailures {
    /// What a channel that failed says on screen: on its row, its Watch On
    /// card, its long-press item, and to VoiceOver.
    static let didNotPlay = "Didn’t play"

    private var noted: [String: Date] = [:]

    /// Every channel failed now (games try them last).
    var ids: Set<String> { Set(noted.keys) }

    func contains(_ id: String) -> Bool { noted[id] != nil }

    /// It sent no picture: the stamp its expiry check must find.
    mutating func note(_ id: String, at date: Date = Date()) -> Date {
        noted[id] = date
        return date
    }

    mutating func played(_ id: String) {
        noted[id] = nil
    }

    /// The check after a failure's time: cleared, unless it failed again
    /// since (that failure's own check clears it).
    mutating func expire(_ id: String, noted date: Date) {
        if noted[id] == date { noted[id] = nil }
    }

    /// Every one of `ids` (a channel's copies, a feed's slots) failed, and
    /// none is the one playing: one copy that plays, and the channel plays.
    func failed(_ ids: [String], playing: String? = nil) -> Bool {
        !ids.isEmpty && !ids.contains { $0 == playing } && ids.allSatisfy(contains)
    }
}

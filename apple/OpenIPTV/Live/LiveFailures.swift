import Foundation

struct LiveFailures: Equatable {
    static let didNotPlay = "Didn’t play"

    struct Mark: Equatable {
        let noted: Date
        var kickoff: Date? = nil

        var beforeKickoff: Bool { kickoff.map { noted < $0 } ?? false }

        func end(after life: TimeInterval) -> Date {
            let end = noted.addingTimeInterval(life)
            guard let kickoff, beforeKickoff else { return end }
            return min(end, kickoff)
        }
    }

    var channelLife: TimeInterval = 600
    var gameLife: TimeInterval = 900
    private var channels: [String: Mark] = [:]
    private var games: [String: Mark] = [:]

    func ids(at now: Date = Date()) -> Set<String> {
        Set(channels.compactMap { id, mark in mark.end(after: channelLife) > now ? id : nil })
    }

    func contains(_ id: String, at now: Date = Date()) -> Bool {
        channels[id].map { $0.end(after: channelLife) > now } ?? false
    }

    mutating func note(_ id: String, at date: Date = Date(), kickoff: Date? = nil) {
        channels[id] = Mark(noted: date, kickoff: kickoff)
    }

    mutating func played(_ id: String) -> Mark? {
        channels.removeValue(forKey: id)
    }

    func failed(_ ids: [String], playingCopy: String? = nil, at now: Date = Date()) -> Bool {
        !ids.isEmpty && !ids.contains { $0 == playingCopy } && ids.allSatisfy { contains($0, at: now) }
    }

    func failedLast<Copy: Identifiable>(_ copies: [Copy], at now: Date = Date()) -> [Copy] where Copy.ID == String {
        var ready: [Copy] = []
        var failed: [Copy] = []
        for copy in copies {
            if contains(copy.id, at: now) { failed.append(copy) } else { ready.append(copy) }
        }
        return ready + failed
    }

    mutating func noteGame(_ ids: [String], at date: Date = Date(), kickoff: Date? = nil, now: Date = Date()) {
        let mark = Mark(noted: date, kickoff: kickoff)
        guard mark.end(after: gameLife) > now else { return }
        for id in ids where games[id].map({ $0.noted < date }) ?? true {
            games[id] = mark
        }
    }

    func gameNotPlaying(_ ids: [String], at now: Date = Date()) -> Bool {
        ids.contains { games[$0].map { $0.end(after: gameLife) > now } ?? false }
    }

    mutating func gamePlayed(_ ids: [String]) -> [String: Mark] {
        var cleared: [String: Mark] = [:]
        for id in ids {
            if let mark = games.removeValue(forKey: id) { cleared[id] = mark }
        }
        return cleared
    }

    var nextEnd: Date? {
        (channels.values.map { $0.end(after: channelLife) } + games.values.map { $0.end(after: gameLife) }).min()
    }

    mutating func dropEnded(at now: Date = Date()) {
        channels = channels.filter { $0.value.end(after: channelLife) > now }
        games = games.filter { $0.value.end(after: gameLife) > now }
    }
}

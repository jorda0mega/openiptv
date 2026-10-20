import Foundation

struct LiveFailures: Equatable {
    static let didNotPlay = "Didn’t play"

    struct Mark: Equatable {
        let noted: Date
        var kickoff: Date? = nil

        var madeBeforeKickoff: Bool { kickoff.map { noted < $0 } ?? false }

        func end(after life: TimeInterval) -> Date {
            let lifeOver = noted.addingTimeInterval(life)
            guard let kickoff, madeBeforeKickoff else { return lifeOver }
            return min(lifeOver, kickoff)
        }
    }

    var channelLife: TimeInterval = 600
    var sharedGameLife: TimeInterval = 900
    private var channelsOnThisDevice: [String: Mark] = [:]
    private var sharedGames: [String: Mark] = [:]

    func ids(at now: Date = Date()) -> Set<String> {
        Set(channelsOnThisDevice.compactMap { id, mark in mark.end(after: channelLife) > now ? id : nil })
    }

    func contains(_ id: String, at now: Date = Date()) -> Bool {
        channelsOnThisDevice[id].map { $0.end(after: channelLife) > now } ?? false
    }

    mutating func note(_ id: String, at date: Date = Date(), kickoff: Date? = nil) {
        channelsOnThisDevice[id] = Mark(noted: date, kickoff: kickoff)
    }

    mutating func played(_ id: String) -> Mark? {
        channelsOnThisDevice.removeValue(forKey: id)
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

    mutating func noteSharedGame(_ ids: [String], at date: Date = Date(), kickoff: Date? = nil, now: Date = Date()) {
        let mark = Mark(noted: date, kickoff: kickoff)
        guard mark.end(after: sharedGameLife) > now else { return }
        for id in ids where sharedGames[id].map({ $0.noted < date }) ?? true {
            sharedGames[id] = mark
        }
    }

    func gameNotPlaying(_ ids: [String], at now: Date = Date()) -> Bool {
        ids.contains { sharedGames[$0].map { $0.end(after: sharedGameLife) > now } ?? false }
    }

    mutating func gamePlayed(_ ids: [String]) -> [String: Mark] {
        var cleared: [String: Mark] = [:]
        for id in ids {
            if let mark = sharedGames.removeValue(forKey: id) { cleared[id] = mark }
        }
        return cleared
    }

    var nextEnd: Date? {
        (channelsOnThisDevice.values.map { $0.end(after: channelLife) } + sharedGames.values.map { $0.end(after: sharedGameLife) }).min()
    }

    mutating func dropEnded(at now: Date = Date()) {
        channelsOnThisDevice = channelsOnThisDevice.filter { $0.value.end(after: channelLife) > now }
        sharedGames = sharedGames.filter { $0.value.end(after: sharedGameLife) > now }
    }
}

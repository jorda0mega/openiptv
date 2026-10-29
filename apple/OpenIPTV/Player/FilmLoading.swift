import Foundation

struct FilmLoading: Equatable {
    struct Patience: Equatable {
        var ringAfter: TimeInterval = 1
        var stallRingAfter: TimeInterval = 3
        var shownAtLeast: TimeInterval = 0.5
        var dimAfter: TimeInterval = 3
        var stillFor: TimeInterval = 30
        var atMost: TimeInterval = 30

        static let current = Patience()
        static let unbounded = Patience(stillFor: .infinity, atMost: .infinity)
    }

    enum Failure: Equatable {
        case noAnswer
        case tooSlow
        case offline
        case refused(String)
        case endedEarly
        case cutOff

        var cause: String {
            switch self {
            case .noAnswer: "Your server didn’t answer."
            case .tooSlow: "Your server is too slow to send it."
            case .offline: "No internet connection."
            case let .refused(why): why
            case .endedEarly: "It stopped before it began."
            case .cutOff: "Your server stopped sending it."
            }
        }
    }

    struct Look: Equatable {
        enum Under: Equatable {
            case held(FirstPicture)
            case film
        }

        enum Over: Equatable {
            case nothing
            case ring(steps: Int, lit: Bool)
            case failure(Failure)
        }

        enum Kind: String {
            case held, ring, film, failed
            case ringDim = "ring-dim"
        }

        let under: Under
        let over: Over

        var failure: Failure? {
            if case let .failure(failure) = over { failure } else { nil }
        }

        var ringShown: Bool {
            if case .ring = over { true } else { false }
        }

        var closes: Bool { under != .film || failure != nil }
        var controls: Bool { under == .film && failure == nil }

        var kind: Kind {
            switch over {
            case .nothing: under == .film ? .film : .held
            case let .ring(_, lit): lit ? .ring : .ringDim
            case .failure: .failed
            }
        }

        func headline(_ title: String) -> String? {
            guard failure != nil else { return nil }
            return under == .film ? "\(title) stopped" : "\(title) didn’t start"
        }
    }

    enum Event: Equatable {
        case planAnswered(ask: Int)
        case planRefused(String, ask: Int)
        case player(Player, attempt: Int)
        case bytes(Int64)
        case seeking(Bool, choosing: Bool)
        case choosingEnded
        case online(Bool)
        case tryAgain
        case close
        case clock

        enum Player: Equatable {
            case opened
            case moving
            case refused(String)
            case dataStopped, dataFlowing
            case landed
            case ended(position: Double, total: Double)
        }
    }

    static let readEvery: TimeInterval = 0.25
    static let endSlack: TimeInterval = 10

    private enum Phase: Equatable {
        case starting(Wait)
        case startFailed(Failure)
        case playing
        case frozen(Wait, Frozen)
        case playFailed(Failure)
        case closed(Look)
    }

    private struct Wait: Equatable {
        let since: Date
        var arrivedAt: Date
        var ringAt: Date?
        var lit = true
        var litChangedAt: Date?
        var failing: Failure?

        var lookShownAt: Date { [since, ringAt, litChangedAt].compactMap(\.self).max() ?? since }

        static func ringAtOnce(_ now: Date) -> Wait {
            Wait(since: now, arrivedAt: now, ringAt: now, litChangedAt: now)
        }
    }

    private struct Frozen: Equatable {
        var dataStoppedAt: Date?
        var jumpAskedAt: Date?
        var reopened = false

        var over: Bool { !reopened && dataStoppedAt == nil && jumpAskedAt == nil }
    }

    private enum Change {
        case ring, dim, relight, limit, failing
    }

    private var phase: Phase
    private let held: FirstPicture
    private let patience: Patience
    private var steps = 0
    private var lastBytes: Int64?
    private var playerSeeking = false
    private var online = true
    private var planAnswered = false
    private(set) var filmShown = false
    private(set) var attempt = 0
    private(set) var ask = 0

    init(tappedAt now: Date, held: FirstPicture, patience: Patience = .current) {
        phase = .starting(Wait(since: now, arrivedAt: now))
        self.held = held
        self.patience = patience
    }

    static func moving(at now: Date, patience: Patience = .current) -> FilmLoading {
        var loading = FilmLoading(tappedAt: now, held: .backdrop, patience: patience)
        loading.play()
        return loading
    }

    mutating func nextAttempt() -> Int {
        attempt += 1
        return attempt
    }

    mutating func takeOver(attempt: Int) {
        self.attempt = attempt
    }

    mutating func nextAsk() -> Int {
        ask += 1
        return ask
    }

    var look: Look {
        switch phase {
        case let .starting(wait): Look(under: .held(held), over: ring(wait))
        case let .startFailed(failure): Look(under: .held(held), over: .failure(failure))
        case .playing: Look(under: .film, over: .nothing)
        case let .frozen(wait, _): Look(under: .film, over: ring(wait))
        case let .playFailed(failure): Look(under: .film, over: .failure(failure))
        case let .closed(look): look
        }
    }

    var waiting: Bool { currentWait != nil }

    var nextChange: Date? { due?.at }

    func isRealEnd(at position: Double, of total: Double) -> Bool {
        guard case .playing = phase else { return false }
        return total <= 0 || total - position <= Self.endSlack
    }

    mutating func send(_ event: Event, at now: Date) {
        advance(to: now)
        switch (phase, event) {
        case (.closed, _), (_, .clock):
            return
        case (_, .close):
            phase = .closed(look)
        case let (_, .online(on)):
            online = on
        case let (_, .bytes(count)):
            let grew = lastBytes.map { count > $0 } ?? false
            lastBytes = count
            if grew { arrive(at: now) }
        case let (.starting, .planAnswered(ask)) where ask == self.ask:
            planAnswered = true
            arrive(at: now)
        case let (.starting, .planRefused(why, ask)) where ask == self.ask:
            fail(refusal(why), at: now)
        case let (_, .player(event, attempt)) where attempt == self.attempt:
            player(event, at: now)
        case let (.playing, .seeking(on, choosing)), let (.frozen, .seeking(on, choosing)):
            playerSeeking = on
            if on, !choosing { jumpAsked(at: now) }
        case (.playing, .choosingEnded), (.frozen, .choosingEnded):
            if playerSeeking { jumpAsked(at: now) }
        case (.startFailed, .tryAgain):
            lastBytes = nil
            phase = .starting(.ringAtOnce(now))
        case (.playFailed, .tryAgain):
            lastBytes = nil
            phase = .frozen(.ringAtOnce(now), Frozen(reopened: true))
        default:
            return
        }
    }

    private mutating func player(_ event: Event.Player, at now: Date) {
        switch (phase, event) {
        case (.starting, .opened):
            arrive(at: now)
        case (.starting, .moving), (.frozen, .moving):
            play()
        case let (.starting, .refused(why)), let (.playing, .refused(why)), let (.frozen, .refused(why)):
            fail(refusal(why), at: now)
        case (.starting, .ended):
            fail(.endedEarly, at: now)
        case let (.playing, .ended(position, total)):
            if !isRealEnd(at: position, of: total) { fail(.cutOff, at: now) }
        case (.frozen, .ended):
            fail(.cutOff, at: now)
        case (.playing, .dataStopped):
            freeze(Frozen(dataStoppedAt: now), at: now)
        case (.frozen(let wait, var frozen), .dataStopped):
            frozen.dataStoppedAt = frozen.dataStoppedAt ?? now
            phase = .frozen(wait, frozen)
        case (.frozen(let wait, var frozen), .dataFlowing):
            frozen.dataStoppedAt = nil
            frozen.over ? play() : (phase = .frozen(wait, frozen))
        case (.frozen(let wait, var frozen), .landed):
            frozen.jumpAskedAt = nil
            frozen.over ? play() : (phase = .frozen(wait, frozen))
        default:
            return
        }
    }

    private mutating func play() {
        phase = .playing
        filmShown = true
        playerSeeking = false
    }

    private mutating func freeze(_ frozen: Frozen, at now: Date) {
        lastBytes = nil
        phase = .frozen(Wait(since: now, arrivedAt: now), frozen)
    }

    private mutating func jumpAsked(at now: Date) {
        switch phase {
        case .playing:
            freeze(Frozen(jumpAskedAt: now), at: now)
        case .frozen(let wait, var frozen):
            frozen.jumpAskedAt = frozen.jumpAskedAt ?? now
            phase = .frozen(wait, frozen)
        default:
            return
        }
    }

    private mutating func arrive(at now: Date) {
        guard var wait = currentWait?.wait else { return }
        wait.arrivedAt = now
        if wait.ringAt != nil, !wait.lit {
            guard let dimmed = wait.litChangedAt, now >= dimmed + patience.shownAtLeast else { return setWait(wait) }
            wait.lit = true
            wait.litChangedAt = now
        }
        steps += 1
        setWait(wait)
    }

    private mutating func fail(_ failure: Failure, at now: Date) {
        switch phase {
        case .playing:
            phase = .playFailed(failure)
        case .starting(var wait), .frozen(var wait, _):
            if now >= wait.lookShownAt + patience.shownAtLeast { return show(failure) }
            wait.failing = wait.failing ?? failure
            setWait(wait)
        default:
            return
        }
    }

    private mutating func show(_ failure: Failure) {
        switch phase {
        case .starting: phase = .startFailed(failure)
        case .frozen: phase = .playFailed(failure)
        default: return
        }
    }

    private func refusal(_ why: String) -> Failure {
        online ? .refused(why) : .offline
    }

    private var limitFailure: Failure {
        guard online else { return .offline }
        if case .frozen = phase { return .cutOff }
        return planAnswered ? .tooSlow : .noAnswer
    }

    private mutating func setWait(_ wait: Wait) {
        switch phase {
        case .starting: phase = .starting(wait)
        case let .frozen(_, frozen): phase = .frozen(wait, frozen)
        default: return
        }
    }

    private func ring(_ wait: Wait) -> Look.Over {
        wait.ringAt == nil ? .nothing : .ring(steps: steps, lit: wait.lit)
    }

    private var currentWait: (wait: Wait, ringAfter: TimeInterval)? {
        switch phase {
        case let .starting(wait): (wait, patience.ringAfter)
        case let .frozen(wait, _): (wait, patience.stallRingAfter)
        default: nil
        }
    }

    private var due: (at: Date, change: Change)? {
        guard let (wait, ringAfter) = currentWait else { return nil }
        if wait.failing != nil { return (wait.lookShownAt + patience.shownAtLeast, .failing) }
        var changes: [(at: Date, change: Change)] = []
        if let ringAt = wait.ringAt {
            let changed = wait.litChangedAt ?? ringAt
            if wait.lit {
                changes.append((max(wait.arrivedAt + patience.dimAfter, changed + patience.shownAtLeast), .dim))
            } else if wait.arrivedAt > changed {
                changes.append((changed + patience.shownAtLeast, .relight))
            }
        } else {
            changes.append((wait.since + ringAfter, .ring))
        }
        let limit = min(patience.stillFor, patience.atMost) == .infinity
            ? nil : min(wait.arrivedAt + patience.stillFor, wait.since + patience.atMost)
        if let limit { changes.append((limit, .limit)) }
        return changes.min { $0.at < $1.at }
    }

    private mutating func advance(to now: Date) {
        while let (at, change) = due, at <= now, var wait = currentWait?.wait {
            switch change {
            case .ring:
                wait.ringAt = at
                wait.lit = at.timeIntervalSince(wait.arrivedAt) < patience.dimAfter
                wait.litChangedAt = at
                setWait(wait)
            case .dim:
                wait.lit = false
                wait.litChangedAt = at
                setWait(wait)
            case .relight:
                wait.lit = true
                wait.litChangedAt = at
                steps += 1
                setWait(wait)
            case .limit:
                fail(limitFailure, at: at)
            case .failing:
                if let failure = wait.failing { show(failure) }
            }
        }
    }
}

extension FirstPicture {
    func goesOn(at second: Double) -> Bool {
        guard case let .still(at: still) = self else { return true }
        return second > still + 0.01
    }
}

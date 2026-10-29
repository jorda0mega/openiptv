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

        struct Summary: Equatable {
            let controls: Bool
            let ringShown: Bool
            let failure: Failure?
        }

        var summary: Summary { Summary(controls: controls, ringShown: ringShown, failure: failure) }

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
        case stillGone
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
            case time(Double)
        }
    }

    static let readEvery: TimeInterval = 0.25
    static let endSlack: TimeInterval = 10

    private enum Ring: Equatable {
        case off
        case lit(since: Date)
        case dim(since: Date)

        var since: Date? {
            switch self {
            case .off: nil
            case let .lit(since), let .dim(since): since
            }
        }
    }

    private enum Phase: Equatable {
        case starting(Wait)
        case playing
        case frozen(Wait, Frozen)
        case failed(Failure)
        case closed(Look)
    }

    private struct Wait: Equatable {
        let since: Date
        var arrivedAt: Date
        var ring = Ring.off
        var failing: Failure?

        var lookShownAt: Date { ring.since ?? since }

        static func showingRing(_ now: Date) -> Wait {
            Wait(since: now, arrivedAt: now, ring: .lit(since: now))
        }
    }

    private struct Frozen: Equatable {
        var dataStopped = false
        var jumpAsked = false
        var reopened = false

        var bothClear: Bool { !reopened && !dataStopped && !jumpAsked }
    }

    private enum Change {
        case showRing, dim, relight, limit, showFailure
    }

    private var phase: Phase
    private var held: FirstPicture
    private let patience: Patience
    private var steps = 0
    private var lastBytes: Int64?
    private var playerSeeking = false
    private var online = true
    private var planAnswered = false
    private var clockAt: Double?
    private(set) var filmShown = false
    private(set) var attempt = 0
    private(set) var ask = 0

    var acceptsPicture: Bool {
        switch phase {
        case .starting, .playing, .frozen: true
        case .failed, .closed: false
        }
    }

    init(tappedAt now: Date, held: FirstPicture, planned: Bool = false, patience: Patience = .current) {
        phase = .starting(Wait(since: now, arrivedAt: now))
        self.held = held
        self.patience = patience
        planAnswered = planned
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
        case let .starting(wait): Look(under: .held(held), over: over(wait))
        case .playing: Look(under: .film, over: .nothing)
        case let .frozen(wait, _): Look(under: .film, over: over(wait))
        case let .failed(failure): Look(under: filmShown ? .film : .held(held), over: .failure(failure))
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
        case (.starting, .stillGone):
            held = .backdrop
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
        case (.failed, .tryAgain) where filmShown:
            lastBytes = nil
            phase = .frozen(.showingRing(now), Frozen(reopened: true))
        case (.failed, .tryAgain):
            lastBytes = nil
            clockAt = nil
            phase = .starting(.showingRing(now))
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
        case let (.starting, .time(position)):
            if let clockAt, position > clockAt + 0.01 { play() } else { clockAt = position }
        case let (.starting, .refused(why)), let (.playing, .refused(why)), let (.frozen, .refused(why)):
            fail(refusal(why), at: now)
        case (.starting, .ended):
            fail(.endedEarly, at: now)
        case let (.playing, .ended(position, total)):
            if !isRealEnd(at: position, of: total) { fail(.cutOff, at: now) }
        case (.frozen, .ended):
            fail(.cutOff, at: now)
        case (.playing, .dataStopped):
            freeze(Frozen(dataStopped: true), at: now)
        case (.frozen(let wait, var frozen), .dataStopped):
            frozen.dataStopped = true
            phase = .frozen(wait, frozen)
        case (.frozen(let wait, var frozen), .dataFlowing):
            frozen.dataStopped = false
            if frozen.bothClear { play() } else { phase = .frozen(wait, frozen) }
        case (.frozen(let wait, var frozen), .landed):
            frozen.jumpAsked = false
            if frozen.bothClear { play() } else { phase = .frozen(wait, frozen) }
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
            freeze(Frozen(jumpAsked: true), at: now)
        case .frozen(let wait, var frozen):
            frozen.jumpAsked = true
            phase = .frozen(wait, frozen)
        default:
            return
        }
    }

    private mutating func arrive(at now: Date) {
        guard var wait = currentWait?.wait else { return }
        wait.arrivedAt = now
        if case let .dim(since) = wait.ring {
            guard now >= since + patience.shownAtLeast else { return setWait(wait) }
            wait.ring = .lit(since: now)
        }
        steps += 1
        setWait(wait)
    }

    private mutating func fail(_ failure: Failure, at now: Date) {
        switch phase {
        case .playing:
            phase = .failed(failure)
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
        case .starting, .frozen: phase = .failed(failure)
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

    private func over(_ wait: Wait) -> Look.Over {
        switch wait.ring {
        case .off: .nothing
        case .lit: .ring(steps: steps, lit: true)
        case .dim: .ring(steps: steps, lit: false)
        }
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
        if wait.failing != nil { return (wait.lookShownAt + patience.shownAtLeast, .showFailure) }
        var changes: [(at: Date, change: Change)] = []
        switch wait.ring {
        case .off:
            changes.append((wait.since + ringAfter, .showRing))
        case let .lit(changed):
            changes.append((max(wait.arrivedAt + patience.dimAfter, changed + patience.shownAtLeast), .dim))
        case let .dim(changed):
            if wait.arrivedAt > changed { changes.append((changed + patience.shownAtLeast, .relight)) }
        }
        if min(patience.stillFor, patience.atMost) != .infinity {
            let limit = min(wait.arrivedAt + patience.stillFor, wait.since + patience.atMost)
            changes.append((limit, .limit))
        }
        return changes.min { $0.at < $1.at }
    }

    private mutating func advance(to now: Date) {
        while let (at, change) = due, at <= now, var wait = currentWait?.wait {
            switch change {
            case .showRing:
                let lit = at.timeIntervalSince(wait.arrivedAt) < patience.dimAfter
                wait.ring = lit ? .lit(since: at) : .dim(since: at)
                setWait(wait)
            case .dim:
                wait.ring = .dim(since: at)
                setWait(wait)
            case .relight:
                wait.ring = .lit(since: at)
                steps += 1
                setWait(wait)
            case .limit:
                fail(limitFailure, at: at)
            case .showFailure:
                if let failure = wait.failing { show(failure) }
            }
        }
    }
}

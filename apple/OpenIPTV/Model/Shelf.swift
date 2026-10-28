import Foundation

enum Weight: Sendable {
    case light
    /// A byte now and then, keeping open the connection playback will use.
    case connection
    case files
    /// Emby reads the whole film for it.
    case heavy
    case bytes
    case images
    case player
    case iptv
}

enum Place: Sendable {
    case posterRow, grid, moreLikeThis, person, searchResult, searchTop
    case continueWatching, hero, episodeRow, page, upNext, homeForecast
    case liveRow, liveLookahead
}

enum Likelihood: Int, Comparable, Sendable {
    case glance, likely, next

    static func < (a: Likelihood, b: Likelihood) -> Bool { a.rawValue < b.rawValue }
}

final class Interest: Identifiable, Sendable {
    let id = UUID()
    let place: Place
    let likelihood: Likelihood
    let since = ContinuousClock.now
    /// Whether its card is the one rested on now (Showing).
    let isRestedOn: @MainActor @Sendable () -> Bool

    init(at place: Place, _ likelihood: Likelihood, isRestedOn: @escaping @MainActor @Sendable () -> Bool = { true }) {
        self.place = place
        self.likelihood = likelihood
        self.isRestedOn = isRestedOn
    }
}

struct Conditions: Equatable, Sendable {
    enum Network: Sendable { case unknown, unmetered, expensive, constrained }

    /// iOS reads the room for important use, which counts what the system
    /// can purge; tvOS has no key for it and reads only what is free now.
    struct FreeDisk: Equatable, Sendable {
        var bytes: Int64
        var countsPurgeable: Bool

        /// Two cards at once (Lane.fileStarts) write at most four reads of
        /// 32 MB each (Matroska.largest), about 0.27 GB: an Apple TV needs
        /// that and as much again. A phone keeps 2 GB of its room for
        /// important use.
        var neededAhead: Int64 { countsPurgeable ? 2_000_000_000 : 500_000_000 }
    }

    enum Refusal: Equatable, Sendable, CustomStringConvertible {
        case network(Network)
        case lowDataMode
        case phoneNetworkNone
        case usedToday
        case notTheRestedStart
        case disk(free: Int64, needs: Int64)
        case playing
        case lowPower
        case thermal(ProcessInfo.ThermalState)
        case memoryWarned

        var description: String {
            switch self {
            case let .network(network): "network \(network)"
            case .lowDataMode: "Low Data Mode"
            case .phoneNetworkNone: "phone network: None"
            case .usedToday: "phone network: today's \(PhoneNetworkFilms.dailyBytes / 1_000_000) MB used"
            case .notTheRestedStart: "phone network: only the start of the card you rest on"
            case let .disk(free, needs): String(format: "disk %.1f GB, needs %.1f GB", Double(free) / 1e9, Double(needs) / 1e9)
            case .playing: "playing"
            case .lowPower: "low power"
            case let .thermal(state): state == .critical ? "thermal critical" : "thermal serious"
            case .memoryWarned: "memory warning"
            }
        }
    }

    var network: Network
    var playing: Bool
    var lowPower: Bool
    var thermal: ProcessInfo.ThermalState
    var memoryWarned: Bool
    var freeDisk: FreeDisk
    var phoneNetwork = PhoneNetworkFilms.none
    var usedToday: Int64 = 0

    /// 150 MB a day on a phone network, with some left: only the one card
    /// most shown is rested on (Showing).
    var restsOnOneCard: Bool { network == .expensive && phoneNetwork == .daily && usedToday < PhoneNetworkFilms.dailyBytes }

    func allows(_ weight: Weight, at place: Place, _ likelihood: Likelihood, restedOn: Bool = true) -> Bool {
        refusal(weight, at: place, likelihood, restedOn: restedOn) == nil
    }

    /// `restedOn`: the card is the one rested on now.
    func refusal(_ weight: Weight, at place: Place, _ likelihood: Likelihood, restedOn: Bool = true) -> Refusal? {
        if network == .constrained { return .lowDataMode }
        if [.serious, .critical].contains(thermal) { return .thermal(thermal) }
        if memoryWarned { return .memoryWarned }
        if playing { return weight == .light && place == .upNext ? nil : .playing }
        if [.light, .iptv].contains(weight) { return nil }
        if network == .expensive, let refusal = phoneNetworkRefusal(weight, at: place, likelihood, restedOn: restedOn) { return refusal }
        if weight == .connection { return nil }
        if network == .unknown { return .network(network) }
        if weight == .bytes, freeDisk.bytes < freeDisk.neededAhead { return .disk(free: freeDisk.bytes, needs: freeDisk.neededAhead) }
        if [.heavy, .player].contains(weight), lowPower { return .lowPower }
        return nil
    }

    private func phoneNetworkRefusal(_ weight: Weight, at place: Place, _ likelihood: Likelihood, restedOn: Bool) -> Refusal? {
        switch phoneNetwork {
        case .none: .phoneNetworkNone
        case .daily where ![.bytes, .files, .connection].contains(weight) || !place.isRestedOn(at: likelihood) || !restedOn: .notTheRestedStart
        case .daily where usedToday >= PhoneNetworkFilms.dailyBytes: .usedToday
        case .daily, .wifi: nil
        }
    }
}

enum FetchAhead {
    /// A shelf's fetch begun for an interest, ahead of a tap, not for a play.
    @TaskLocal static var isUnderWay = false
}

struct Bucket: Sendable {
    let size: Int
    let refillEvery: Duration
    let reserve: Int
}

@MainActor
final class Lane {
    final class Ticket {
        fileprivate(set) var interest: Interest?
        fileprivate(set) var plays: Bool
        fileprivate var turn: CheckedContinuation<Void, Error>?
        fileprivate var running = false
        /// Its owner stops it under way when conditions refuse it (Shelf).
        fileprivate var stop: (@MainActor () -> Void)?

        init(_ interest: Interest?) {
            self.interest = interest
            plays = interest == nil
        }
    }

    let weight: Weight
    private let atOnce: Int
    private let bucket: Bucket?
    private let conditions: @MainActor () -> Conditions
    /// How often a refused interest looks again besides each change the lane hears of (the network, the card rested on):
    /// room on the disk, heat and power change without a word.
    private let recheckEvery: Duration
    private var refused: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var tokens: Int
    private var refilledAt = ContinuousClock.now
    private var refill: Task<Void, Never>?
    private var underWay: [Ticket] = []
    private var waiting: [Ticket] = []
    private static let every = NSHashTable<Lane>.weakObjects()

    init(_ weight: Weight, atOnce: Int, bucket: Bucket? = nil, recheckEvery: Duration = .seconds(15),
         conditions: @escaping @MainActor () -> Conditions) {
        self.weight = weight
        self.atOnce = atOnce
        self.bucket = bucket
        self.recheckEvery = recheckEvery
        self.conditions = conditions
        tokens = bucket?.size ?? 0
        Self.every.add(self)
    }

    static func conditionsChangedEverywhere() {
        for lane in every.allObjects { lane.conditionsChanged() }
    }

    func enter(_ ticket: Ticket) async throws {
        if ticket.running { return }
        try Task.checkCancellation()
        if ticket.plays { return start(ticket) }
        guard ticket.interest != nil, allows(ticket, conditions()) else {
            #if DEBUG
            noteRefused(ticket, conditions())
            #endif
            throw CancellationError()
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { turn in
                ticket.turn = turn
                waiting.append(ticket)
                admit()
            }
        } onCancel: {
            Task { @MainActor in self.withdraw(ticket) }
        }
        if Task.isCancelled {
            leave(ticket)
            throw CancellationError()
        }
    }

    func refuses(_ interest: Interest) -> Bool {
        !allows(Ticket(interest), conditions())
    }

    /// Returns once the conditions allow `interest`; throws when cancelled first.
    func untilAllowed(_ interest: Interest) async throws {
        while refuses(interest) {
            try Task.checkCancellation()
            await nextLook()
        }
        try Task.checkCancellation()
    }

    /// The next change the lane hears of, or `recheckEvery`, or a cancel, whichever comes first.
    private func nextLook() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { look in
                refused[id] = look
                Task { [weak self, recheckEvery] in
                    try? await Task.sleep(for: recheckEvery)
                    self?.refused.removeValue(forKey: id)?.resume()
                }
            }
        } onCancel: {
            Task { @MainActor in self.refused.removeValue(forKey: id)?.resume() }
        }
    }

    func whenAllowed(for interest: Interest, _ work: () async -> Void) async {
        let ticket = Ticket(interest)
        guard (try? await enter(ticket)) != nil else { return }
        defer { leave(ticket) }
        await work()
    }

    func leave(_ ticket: Ticket) {
        guard ticket.running else { return }
        ticket.running = false
        underWay.removeAll { $0 === ticket }
        admit()
    }

    /// A ticket waiting goes by the likeliest interest holding it.
    func raise(_ ticket: Ticket, to interest: Interest) {
        guard let held = ticket.interest, interest.likelihood > held.likelihood else { return }
        ticket.interest = interest
    }

    func playNow(_ ticket: Ticket) {
        ticket.plays = true
        guard waiting.contains(where: { $0 === ticket }) else { return }
        waiting.removeAll { $0 === ticket }
        start(ticket)
    }

    /// What the conditions refuse now stops: waiting, or under way on a
    /// phone network or in Low Data Mode (a play goes on). Wi-Fi that drops
    /// a moment reads as no network known: under way, that goes on.
    func conditionsChanged() {
        let now = conditions()
        if [.expensive, .constrained].contains(now.network) {
            for ticket in underWay where !ticket.plays && !allows(ticket, now) {
                noteRefused(ticket, now)
                ticket.stop?()
            }
        }
        admit()
        let looks = refused.values
        refused = [:]
        looks.forEach { $0.resume() }
    }

    #if DEBUG
    var debugCounts: String { "\(underWay.count) under way, \(waiting.count) waiting" }

    /// Fetches ahead the conditions refused (asked, waiting or under way), and the last refusal.
    private(set) var debugRefused = 0
    private(set) var debugLastRefusal: Conditions.Refusal?

    func debugRefusal(at place: Place, _ likelihood: Likelihood) -> Conditions.Refusal? {
        conditions().refusal(weight, at: place, likelihood)
    }
    #endif

    func withdraw(_ ticket: Ticket) {
        guard waiting.contains(where: { $0 === ticket }) else { return }
        waiting.removeAll { $0 === ticket }
        ticket.turn?.resume(throwing: CancellationError())
        ticket.turn = nil
    }

    private func start(_ ticket: Ticket) {
        refillTokens()
        if tokens > 0 { tokens -= 1 }
        ticket.running = true
        underWay.append(ticket)
        ticket.turn?.resume()
        ticket.turn = nil
    }

    private var hasToken: Bool {
        bucket.map { tokens > $0.reserve } ?? true
    }

    private func admit() {
        let now = conditions()
        for ticket in waiting where !allows(ticket, now) {
            noteRefused(ticket, now)
            withdraw(ticket)
        }
        refillTokens()
        while underWay.count < atOnce, hasToken, let next = waiting.min(by: goesBefore) {
            waiting.removeAll { $0 === next }
            start(next)
        }
        awaitRefill()
    }

    private func allows(_ ticket: Ticket, _ now: Conditions) -> Bool {
        refusal(ticket, now) == nil
    }

    private func refusal(_ ticket: Ticket, _ now: Conditions) -> Conditions.Refusal? {
        guard let interest = ticket.interest else { return now.refusal(weight, at: .page, .next) }
        return now.refusal(weight, at: interest.place, interest.likelihood, restedOn: interest.isRestedOn())
    }

    private func noteRefused(_ ticket: Ticket, _ now: Conditions) {
        #if DEBUG
        debugRefused += 1
        debugLastRefusal = refusal(ticket, now) ?? debugLastRefusal
        #endif
    }

    private func goesBefore(_ a: Ticket, _ b: Ticket) -> Bool {
        let (first, second) = (a.interest?.likelihood ?? .next, b.interest?.likelihood ?? .next)
        if first != second { return first > second }
        return (a.interest?.since ?? .now) > (b.interest?.since ?? .now)
    }

    private func refillTokens() {
        guard let bucket else { return }
        let periods = Int((ContinuousClock.now - refilledAt) / bucket.refillEvery)
        guard periods > 0 else { return }
        tokens = min(bucket.size, tokens + periods)
        refilledAt += bucket.refillEvery * periods
    }

    private func awaitRefill() {
        guard let bucket, refill == nil, !waiting.isEmpty, underWay.count < atOnce, !hasToken else { return }
        let next = refilledAt + bucket.refillEvery
        refill = Task { [weak self] in
            try? await Task.sleep(until: next, clock: .continuous)
            self?.refill = nil
            self?.admit()
        }
    }
}

@MainActor
final class Shelf<Key: Hashable & Sendable, Value: Sendable> {
    struct Policy {
        let lane: Lane
        let lifetime: Duration
        var whenUnused: WhenUnused = .finish
        var retries: [Duration] = []
        var retryable: @Sendable (Error) -> Bool = { _ in false }
        var failureKept: Duration = .seconds(600)
        var stillThere: @MainActor (Value) -> Bool = { _ in true }
    }

    enum WhenUnused: Sendable {
        case finish
        case cancel
    }

    typealias Disk = @Sendable (Key) -> (value: Value, at: Date)?

    private final class Job {
        let ticket: Lane.Ticket
        var began = Date.distantPast
        var task: Task<Void, Never>?
        var holders: Set<Interest.ID> = []
        var waiters: [UUID: CheckedContinuation<Value, Error>] = [:]
        var nonOwningWaiters: [UUID: CheckedContinuation<Value, Error>] = [:]
        var result: Result<Value, Error>?

        init(_ ticket: Lane.Ticket) { self.ticket = ticket }
    }

    private enum Entry {
        case waiting(Job)
        case fetching(Job)
        case kept(Value, until: Date)
        case failed(Error, until: Date)

        var job: Job? {
            switch self {
            case let .waiting(job), let .fetching(job): job
            case .kept, .failed: nil
            }
        }
    }

    private var entries: [Key: Entry] = [:]
    #if DEBUG
    private(set) var fetched = 0
    /// Fetches that failed, the last one's kind (an error's type and code, never its words), and those stopped.
    private(set) var failed = 0, stopped = 0
    private(set) var lastFailure = "none"
    #endif
    private let policy: Policy
    private let disk: Disk?
    private let now: @Sendable () -> Date
    private let fetch: @Sendable (Key) async throws -> Value

    init(_ policy: Policy, disk: Disk? = nil, now: @escaping @Sendable () -> Date = { Date() },
         fetch: @escaping @Sendable (Key) async throws -> Value) {
        self.policy = policy
        self.disk = disk
        self.now = now
        self.fetch = fetch
    }

    func value(for key: Key) async throws -> Value {
        try Task.checkCancellation()
        switch current(key) {
        case let .kept(value, _)?:
            return value
        case let .failed(error, _)?:
            throw error
        case let .waiting(job)?, let .fetching(job)?:
            policy.lane.playNow(job.ticket)
            return try await wait(for: job, key)
        case nil:
            return try await wait(for: start(key, Lane.Ticket(nil)), key)
        }
    }

    func isKept(_ key: Key) -> Bool {
        if case .kept? = current(key) { true } else { false }
    }

    #if DEBUG
    func debugState(_ key: Key, at place: Place, _ likelihood: Likelihood) -> String {
        switch current(key) {
        case .waiting?: "waiting its turn (\(policy.lane.debugCounts))"
        case .fetching?: "under way"
        case .kept?: "done"
        case .failed?: "failed"
        case nil: policy.lane.debugRefusal(at: place, likelihood).map { "not asked, not allowed now: \($0)" } ?? "not asked"
        }
    }
    #endif

    /// Fetched anew, beside any fetch under way and outside the lane, and
    /// not kept: a start's second ask.
    func fresh(_ key: Key) async throws -> Value {
        try await fetch(key)
    }

    func take(_ key: Key) async throws -> Value {
        let value = try await value(for: key)
        if case .kept? = entries[key] { entries[key] = nil }
        return value
    }

    func forget(where matches: (Key) -> Bool) {
        for (key, entry) in entries where matches(key) {
            if let job = entry.job { stop(job) }
            entries[key] = nil
        }
    }

    func warm(_ key: Key, for interest: Interest) async -> Value? {
        let job: Job
        switch current(key) {
        case let .kept(value, _)?:
            return value
        case .failed?:
            return nil
        case let .waiting(running)?, let .fetching(running)?:
            job = running
            policy.lane.raise(job.ticket, to: interest)
        case nil:
            job = start(key, Lane.Ticket(interest))
        }
        job.holders.insert(interest.id)
        let value = try? await wait(for: job, key, keepingJob: false)
        if Task.isCancelled { release(key, from: interest.id) }
        return value
    }

    /// `warm`, and while the device's conditions refuse it, warmed again once they allow it, till the interest goes.
    /// Regression: a card's start refused once (2 GB free for a moment) was never fetched while it stayed on screen.
    func hold(_ key: Key, for interest: Interest) async -> Value? {
        while true {
            if let value = await warm(key, for: interest) { return value }
            guard !Task.isCancelled, policy.lane.refuses(interest) else { return nil }
            guard (try? await policy.lane.untilAllowed(interest)) != nil else { return nil }
        }
    }

    func release(_ key: Key, from interest: Interest.ID) {
        guard let job = entries[key]?.job else { return }
        job.holders.remove(interest)
        stopIfUnwanted(job, key)
    }

    /// What's kept, failures, and fetches asked before `date` go; fetches asked since finish for whoever waits on them.
    func forget(askedBefore date: Date) {
        for (key, entry) in entries {
            if let job = entry.job {
                guard job.began < date else { continue }
                stop(job)
            }
            entries[key] = nil
        }
    }

    func forgetAll() {
        for case let job? in entries.values.map(\.job) { stop(job) }
        entries = [:]
    }

    private func current(_ key: Key) -> Entry? {
        switch entries[key] {
        case let .kept(value, until)? where now() < until && policy.stillThere(value):
            return entries[key]
        case let .failed(_, until)? where now() < until:
            return entries[key]
        case .waiting?, .fetching?:
            return entries[key]
        default:
            entries[key] = nil
            return nil
        }
    }

    private func start(_ key: Key, _ ticket: Lane.Ticket) -> Job {
        let job = Job(ticket)
        job.began = now()
        ticket.stop = { [weak self, weak job] in
            guard let self, let job, entries[key]?.job === job else { return }
            stop(job)
            entries[key] = nil
        }
        job.task = Task(priority: ticket.plays ? nil : .utility) { [self] in await run(job, key) }
        entries[key] = .waiting(job)
        return job
    }

    private func run(_ job: Job, _ key: Key) async {
        let result: Result<(Value, Date), Error>
        do { result = .success(try await tries(job, key)) } catch { result = .failure(error) }
        if entries[key]?.job === job {
            switch result {
            case let .success((value, at)):
                entries[key] = .kept(value, until: at.addingTimeInterval(policy.lifetime / .seconds(1)))
            case let .failure(error):
                #if DEBUG
                if Task.isCancelled || error is CancellationError {
                    stopped += 1
                } else {
                    failed += 1
                    lastFailure = (error as? URLError).map { "URLError \($0.code.rawValue)" } ?? "\(type(of: error))"
                }
                #endif
                entries[key] = Task.isCancelled || error is CancellationError
                    ? nil : .failed(error, until: now().addingTimeInterval(policy.failureKept / .seconds(1)))
            }
        }
        deliver(job, result.map(\.0))
    }

    private func tries(_ job: Job, _ key: Key) async throws -> (Value, Date) {
        if let found = await Self.find(key, in: disk), now() < found.at.addingTimeInterval(policy.lifetime / .seconds(1)),
           policy.stillThere(found.value) {
            return found
        }
        var waits = policy.retries[...]
        while true {
            try await policy.lane.enter(job.ticket)
            if case .waiting? = entries[key], entries[key]?.job === job { entries[key] = .fetching(job) }
            do {
                #if DEBUG
                fetched += 1
                #endif
                let value = try await FetchAhead.$isUnderWay.withValue(!job.ticket.plays) { try await fetch(key) }
                policy.lane.leave(job.ticket)
                return (value, now())
            } catch {
                policy.lane.leave(job.ticket)
                guard !Task.isCancelled, !(error is CancellationError), policy.retryable(error), let pause = waits.popFirst() else {
                    throw error
                }
                try await Task.sleep(for: pause)
            }
        }
    }

    private nonisolated static func find(_ key: Key, in disk: Disk?) async -> (value: Value, at: Date)? {
        disk?(key)
    }

    private func wait(for job: Job, _ key: Key, keepingJob: Bool = true) async throws -> Value {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter in
                if let result = job.result { return waiter.resume(with: result) }
                if keepingJob { job.waiters[id] = waiter } else { job.nonOwningWaiters[id] = waiter }
            }
        } onCancel: {
            Task { @MainActor in self.stopWaiting(id, for: job, key) }
        }
    }

    private func stopWaiting(_ id: UUID, for job: Job, _ key: Key) {
        guard let waiter = job.waiters.removeValue(forKey: id) ?? job.nonOwningWaiters.removeValue(forKey: id) else { return }
        waiter.resume(throwing: CancellationError())
        stopIfUnwanted(job, key)
    }

    private func stopIfUnwanted(_ job: Job, _ key: Key) {
        guard job.result == nil, job.waiters.isEmpty, job.holders.isEmpty, entries[key]?.job === job else { return }
        if case .fetching? = entries[key], policy.whenUnused == .finish { return }
        stop(job)
        entries[key] = nil
    }

    private func stop(_ job: Job) {
        job.task?.cancel()
        policy.lane.withdraw(job.ticket)
        deliver(job, .failure(CancellationError()))
    }

    private func deliver(_ job: Job, _ result: Result<Value, Error>) {
        guard job.result == nil else { return }
        job.result = result
        for waiter in job.waiters.values { waiter.resume(with: result) }
        for listener in job.nonOwningWaiters.values { listener.resume(with: result) }
        job.waiters = [:]
        job.nonOwningWaiters = [:]
    }
}

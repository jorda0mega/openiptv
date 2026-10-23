import Foundation

enum Weight: Sendable {
    case light
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

    init(at place: Place, _ likelihood: Likelihood) {
        self.place = place
        self.likelihood = likelihood
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
        case disk(free: Int64, needs: Int64)
        case playing
        case lowPower
        case thermal(ProcessInfo.ThermalState)
        case memoryWarned

        var description: String {
            switch self {
            case let .network(network): "network \(network)"
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

    func allows(_ weight: Weight, at place: Place, _ likelihood: Likelihood) -> Bool {
        refusal(weight, at: place, likelihood) == nil
    }

    func refusal(_ weight: Weight, at place: Place, _ likelihood: Likelihood) -> Refusal? {
        if network == .constrained { return .network(network) }
        if [.serious, .critical].contains(thermal) { return .thermal(thermal) }
        if memoryWarned { return .memoryWarned }
        if playing { return weight == .light && place == .upNext ? nil : .playing }
        if [.light, .iptv].contains(weight) { return nil }
        if network != .unmetered { return .network(network) }
        if weight == .bytes, freeDisk.bytes < freeDisk.neededAhead { return .disk(free: freeDisk.bytes, needs: freeDisk.neededAhead) }
        if [.heavy, .player].contains(weight), lowPower { return .lowPower }
        return nil
    }
}

struct Bucket: Sendable {
    let size: Int
    let refillEvery: Duration
    let reserve: Int
}

@MainActor
final class Lane {
    final class Ticket {
        let interest: Interest?
        fileprivate(set) var plays: Bool
        fileprivate var turn: CheckedContinuation<Void, Error>?
        fileprivate var running = false

        init(_ interest: Interest?) {
            self.interest = interest
            plays = interest == nil
        }
    }

    let weight: Weight
    private let atOnce: Int
    private let bucket: Bucket?
    private let conditions: @MainActor () -> Conditions
    private var tokens: Int
    private var refilledAt = ContinuousClock.now
    private var refill: Task<Void, Never>?
    private var running = 0
    private var waiting: [Ticket] = []

    init(_ weight: Weight, atOnce: Int, bucket: Bucket? = nil, conditions: @escaping @MainActor () -> Conditions) {
        self.weight = weight
        self.atOnce = atOnce
        self.bucket = bucket
        self.conditions = conditions
        tokens = bucket?.size ?? 0
    }

    func enter(_ ticket: Ticket) async throws {
        if ticket.running { return }
        try Task.checkCancellation()
        if ticket.plays { return start(ticket) }
        guard let interest = ticket.interest, conditions().allows(weight, at: interest.place, interest.likelihood) else { throw CancellationError() }
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

    func whenAllowed(for interest: Interest, _ work: () async -> Void) async {
        let ticket = Ticket(interest)
        guard (try? await enter(ticket)) != nil else { return }
        defer { leave(ticket) }
        await work()
    }

    func leave(_ ticket: Ticket) {
        guard ticket.running else { return }
        ticket.running = false
        running -= 1
        admit()
    }

    func playNow(_ ticket: Ticket) {
        ticket.plays = true
        guard waiting.contains(where: { $0 === ticket }) else { return }
        waiting.removeAll { $0 === ticket }
        start(ticket)
    }

    func conditionsChanged() {
        admit()
    }

    #if DEBUG
    var debugCounts: String { "\(running) under way, \(waiting.count) waiting" }

    func debugRefusal(at place: Place, _ likelihood: Likelihood) -> Conditions.Refusal? { conditions().refusal(weight, at: place, likelihood) }
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
        running += 1
        ticket.turn?.resume()
        ticket.turn = nil
    }

    private var hasToken: Bool {
        bucket.map { tokens > $0.reserve } ?? true
    }

    private func admit() {
        let now = conditions()
        for ticket in waiting where !now.allows(weight, at: ticket.interest?.place ?? .page, ticket.interest?.likelihood ?? .next) { withdraw(ticket) }
        refillTokens()
        while running < atOnce, hasToken, let next = waiting.min(by: goesBefore) {
            waiting.removeAll { $0 === next }
            start(next)
        }
        awaitRefill()
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
        guard let bucket, refill == nil, !waiting.isEmpty, running < atOnce, !hasToken else { return }
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

    #if DEBUG
    func isKept(_ key: Key) -> Bool {
        if case .kept? = current(key) { true } else { false }
    }

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
        case nil:
            job = start(key, Lane.Ticket(interest))
        }
        job.holders.insert(interest.id)
        let value = try? await wait(for: job, key, keepingJob: false)
        if Task.isCancelled { release(key, from: interest.id) }
        return value
    }

    func release(_ key: Key, from interest: Interest.ID) {
        guard let job = entries[key]?.job else { return }
        job.holders.remove(interest)
        stopIfUnwanted(job, key)
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
                let value = try await fetch(key)
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

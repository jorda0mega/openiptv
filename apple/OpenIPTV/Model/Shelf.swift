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

    var network: Network
    var playing: Bool
    var lowPower: Bool
    var thermal: ProcessInfo.ThermalState
    var memoryWarned: Bool
    var freeDisk: Int64

    func allows(_ weight: Weight, at place: Place) -> Bool {
        if network == .constrained || [.serious, .critical].contains(thermal) || memoryWarned { return false }
        if playing { return weight == .light && place == .upNext }
        switch weight {
        case .light, .iptv: return true
        case .files, .images: return network == .unmetered
        case .bytes: return network == .unmetered && freeDisk >= 2_000_000_000
        case .heavy, .player: return network == .unmetered && !lowPower
        }
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
        let interest: Interest
        fileprivate var turn: CheckedContinuation<Void, Error>?
        fileprivate var running = false

        init(_ interest: Interest) { self.interest = interest }
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
        guard conditions().allows(weight, at: ticket.interest.place) else { throw CancellationError() }
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

    func leave(_ ticket: Ticket) {
        guard ticket.running else { return }
        ticket.running = false
        running -= 1
        admit()
    }

    func admitNow(_ ticket: Ticket) {
        guard !ticket.running else { return }
        waiting.removeAll { $0 === ticket }
        start(ticket)
    }

    func conditionsChanged() {
        admit()
    }

    func withdraw(_ ticket: Ticket) {
        guard waiting.contains(where: { $0 === ticket }) else { return }
        waiting.removeAll { $0 === ticket }
        ticket.turn?.resume(throwing: CancellationError())
        ticket.turn = nil
    }

    private func start(_ ticket: Ticket) {
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
        for ticket in waiting where !now.allows(weight, at: ticket.interest.place) { withdraw(ticket) }
        refillTokens()
        while running < atOnce, hasToken, let next = waiting.min(by: goesBefore) {
            waiting.removeAll { $0 === next }
            if bucket != nil { tokens -= 1 }
            start(next)
        }
        awaitRefill()
    }

    private func goesBefore(_ a: Ticket, _ b: Ticket) -> Bool {
        if a.interest.likelihood != b.interest.likelihood { return a.interest.likelihood > b.interest.likelihood }
        return a.interest.since > b.interest.since
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
        var onLeave: OnLeave = .finish
        var retries: [Duration] = []
        var failureKept: Duration = .seconds(600)
    }

    enum OnLeave: Sendable {
        case finish
        case cancel
    }

    struct Disk: Sendable {
        let find: @Sendable (Key) -> (value: Value, at: Date)?
        let removeAll: @Sendable () -> Void
    }

    private final class Job {
        let id: UUID
        let task: Task<Value, Error>
        let ticket: Lane.Ticket?
        var holders: Set<Interest.ID> = []
        var joined: Bool

        init(id: UUID, task: Task<Value, Error>, ticket: Lane.Ticket?) {
            self.id = id
            self.task = task
            self.ticket = ticket
            joined = ticket == nil
        }
    }

    private enum Entry {
        case waiting(Job)
        case fetching(Job)
        case kept(Value, until: Date)
        case failed(until: Date)

        var job: Job? {
            switch self {
            case let .waiting(job), let .fetching(job): job
            case .kept, .failed: nil
            }
        }
    }

    private var entries: [Key: Entry] = [:]
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
        switch entries[key] {
        case let .kept(value, until) where now() < until:
            return value
        case let .waiting(job):
            job.joined = true
            if let ticket = job.ticket { policy.lane.admitNow(ticket) }
            return try await job.task.value
        case let .fetching(job):
            job.joined = true
            return try await job.task.value
        default:
            return try await start(key, ticket: nil).task.value
        }
    }

    func warm(_ key: Key, for interest: Interest) async -> Value? {
        let job: Job
        switch entries[key] {
        case let .kept(value, until) where now() < until:
            return value
        case let .failed(until) where now() < until:
            return nil
        case let .waiting(running), let .fetching(running):
            job = running
        default:
            job = start(key, ticket: Lane.Ticket(interest))
        }
        job.holders.insert(interest.id)
        return try? await job.task.value
    }

    func release(_ key: Key, from interest: Interest.ID) {
        guard let entry = entries[key], let job = entry.job else { return }
        job.holders.remove(interest)
        guard job.holders.isEmpty, !job.joined else { return }
        if case .fetching = entry, policy.onLeave == .finish { return }
        stop(job)
        entries[key] = nil
    }

    func forgetAll() {
        for case let job? in entries.values.map(\.job) { stop(job) }
        entries = [:]
        disk?.removeAll()
    }

    private func stop(_ job: Job) {
        job.task.cancel()
        if let ticket = job.ticket { policy.lane.withdraw(ticket) }
    }

    private func start(_ key: Key, ticket: Lane.Ticket?) -> Job {
        let id = UUID()
        let task = Task(priority: ticket == nil ? nil : .utility) { [self, policy, disk, now, fetch] in
            do {
                if let ticket { try await policy.lane.enter(ticket) }
                defer { if let ticket { policy.lane.leave(ticket) } }
                began(key, id)
                let (value, at) = try await Self.load(key, lifetime: policy.lifetime, retries: policy.retries,
                                                      disk: disk, now: now, fetch: fetch)
                finished(key, id, with: .kept(value, until: at.addingTimeInterval(policy.lifetime / .seconds(1))))
                return value
            } catch {
                let stopped = Task.isCancelled || error is CancellationError
                finished(key, id, with: stopped ? nil : Entry.failed(until: now().addingTimeInterval(policy.failureKept / .seconds(1))))
                throw error
            }
        }
        let job = Job(id: id, task: task, ticket: ticket)
        entries[key] = ticket == nil ? .fetching(job) : .waiting(job)
        return job
    }

    private func began(_ key: Key, _ id: UUID) {
        if case let .waiting(job) = entries[key], job.id == id { entries[key] = .fetching(job) }
    }

    private func finished(_ key: Key, _ id: UUID, with entry: Entry?) {
        guard entries[key]?.job?.id == id else { return }
        entries[key] = entry
    }

    private nonisolated static func load(_ key: Key, lifetime: Duration, retries: [Duration], disk: Disk?, now: @Sendable () -> Date,
                                         fetch: @Sendable (Key) async throws -> Value) async throws -> (Value, Date) {
        if let found = disk?.find(key), now() < found.at.addingTimeInterval(lifetime / .seconds(1)) { return found }
        var waits = retries[...]
        while true {
            do {
                return (try await fetch(key), now())
            } catch where !(error is CancellationError) && !Task.isCancelled && !waits.isEmpty {
                try await Task.sleep(for: waits.removeFirst())
            }
        }
    }
}

import Foundation

struct PlanKey: Hashable, Sendable {
    let itemId: String
    let kind: String?
    let versions: [String]

    static func == (a: PlanKey, b: PlanKey) -> Bool { a.itemId == b.itemId && a.versions == b.versions }

    func hash(into hasher: inout Hasher) {
        hasher.combine(itemId)
        hasher.combine(versions)
    }
}

extension Lane {
    static let emby = Lane(.light, atOnce: 4, conditions: Conditions.current)
}

@MainActor
enum Plans {
    static func shelf(lane: Lane? = nil, now: @escaping @Sendable () -> Date = { Date() },
                      fetch: @escaping @Sendable (PlanKey) async throws -> EmbyPlayback) -> Shelf<PlanKey, EmbyPlayback> {
        Shelf(.init(lane: lane ?? .emby, lifetime: .seconds(180), failureKept: .zero), now: now, fetch: fetch)
    }

    /// A start's plan, asked once more if it fails, and again for the
    /// server's track list if it came without, while time is left; none by
    /// `failAfter`: the server took too long.
    static func forStart(_ key: PlanKey, on shelf: Shelf<PlanKey, EmbyPlayback>, retryAfter: Duration = StartPatience.retryAfter,
                         failAfter: Duration = StartPatience.failAfter,
                         retried: @escaping @MainActor () -> Void = {}) async throws -> EmbyPlayback {
        let deadline = ContinuousClock.now + failAfter
        var playback = try await StartPatience.by(deadline) {
            StartPatience.off ? try await taken(key, on: shelf) : try await asked(key, on: shelf, againAfter: retryAfter, retried: retried)
        }
        if !playback.listed, let listed = try? await StartPatience.by(deadline, { try await shelf.take(key) }) { playback = listed }
        return playback
    }

    private static func taken(_ key: PlanKey, on shelf: Shelf<PlanKey, EmbyPlayback>) async throws -> EmbyPlayback {
        do {
            return try await shelf.take(key)
        } catch {
            return try await shelf.take(key)
        }
    }

    /// The plan, and with none by `againAfter` a fresh ask beside it: the
    /// first answer plays. One that fails before then fails the start.
    private static func asked(_ key: PlanKey, on shelf: Shelf<PlanKey, EmbyPlayback>, againAfter: Duration,
                              retried: @escaping @MainActor () -> Void) async throws -> EmbyPlayback {
        let began = ContinuousClock.now
        return try await withThrowingTaskGroup(of: EmbyPlayback.self) { group in
            group.addTask { try await taken(key, on: shelf) }
            group.addTask {
                try await Task.sleep(for: againAfter)
                await retried()
                return try await shelf.fresh(key)
            }
            defer { group.cancelAll() }
            var failure: Error = CancellationError()
            while let answer = await group.nextResult() {
                switch answer {
                case let .success(playback): return playback
                case let .failure(error):
                    failure = error
                    if ContinuousClock.now - began < againAfter { throw error }
                }
            }
            throw failure
        }
    }

    /// Home's Continue Watching: every card's plan, in the row's order and
    /// one at a time (the server can be slow right after a launch, and the
    /// row's other requests go on meanwhile), each at the least likelihood,
    /// so a card held on screen or tapped goes first.
    static func forecast(_ keys: [PlanKey], on shelf: Shelf<PlanKey, EmbyPlayback>) async {
        for key in keys where !Task.isCancelled {
            _ = await shelf.warm(key, for: Interest(at: .continueWatching, .glance))
        }
    }
}

/// A start, for the loading progress: where it is, since the tap, whether
/// it asked again, and why it failed. What is slow, from `causeAfter`, and
/// whether it has failed, by `failAfter`, follow.
struct StartProgress: Equatable, Sendable {
    enum Stage: Equatable, Sendable {
        /// The plan: the server says how to play it.
        case askingServer
        /// The player asks for the film's first bytes.
        case openingFilm
        /// The film has opened; its first frame is on its way.
        case starting
    }

    enum Cause: Equatable, Sendable {
        case serverSlowToAnswer, filmSlowToArrive, slowToStart
    }

    var stage: Stage
    let tapped: ContinuousClock.Instant
    var retried = false
    var failure: String?
    /// Nil for a start asked inside the player (the next episode, another copy).
    var title: String?
    var backdrop: [CardImage] = []
    var began = Date()

    func waited(at now: ContinuousClock.Instant = .now) -> Duration { now - tapped }

    func cause(at now: ContinuousClock.Instant = .now) -> Cause? {
        guard !failed(at: now), waited(at: now) >= StartPatience.causeAfter else { return nil }
        return switch stage {
        case .askingServer: .serverSlowToAnswer
        case .openingFilm: .filmSlowToArrive
        case .starting: .slowToStart
        }
    }

    func failed(at now: ContinuousClock.Instant = .now) -> Bool {
        failure != nil || (!StartPatience.off && waited(at: now) >= StartPatience.failAfter)
    }
}

/// How long each part of a start may take before the viewer is told: a
/// cause shows from 8 s, a step with no answer is asked once more at 15 s,
/// and the start fails at 30 s.
enum StartPatience {
    static let causeAfter = Duration.seconds(8)
    static let retryAfter = Duration.seconds(15)
    /// A read's first byte took up to 9 s on a busy server.
    static let firstByte = Duration.seconds(15)
    static let failAfter = Duration.seconds(30)
    static let tooLong = SourceError.network("The server took too long to answer.", .timedOut)

    #if DEBUG
    /// -noStartBounds YES: a start waits as long as its requests do (the start before).
    static var off: Bool { UserDefaults.standard.bool(forKey: "noStartBounds") }
    #else
    static let off = false
    #endif

    /// `work`'s answer, or `tooLong` at `deadline`.
    static func by<T: Sendable>(_ deadline: ContinuousClock.Instant, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        if off { return try await work() }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(until: deadline, clock: .continuous)
                throw tooLong
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }
}

#if DEBUG
/// Debug builds: where a plan's time went, request by request: the copy it
/// was for, when it was sent against the tap, how many of the app's other
/// requests to the server were under way then, and its wait for a
/// connection, the server's wait and the answer's transfer. Counts and
/// times only, never an id or an address.
final class PlanClock: Sendable {
    @TaskLocal static var current: PlanClock?
    /// The app's requests to the server under way (HTTP.data), and the library's pages among them.
    static let underWay = Locked(0)
    static let pagesUnderWay = Locked(0)

    struct Request: Sendable {
        let copy: Int?
        let info: Bool
        let sent: Date
        let others: Int
        let pages: Int
        var answered: Date?
        var times: RequestTimes?
    }

    let asked = Date()
    private let copies: [String]
    private let requests = Locked<[Request]>([])

    init(copies: [String]) { self.copies = copies }

    var sent: [Request] { requests.value }

    func sending(_ request: URLRequest) -> Recorder {
        let parts = request.url?.pathComponents ?? []
        let info = parts.last == "PlaybackInfo"
        let id = info ? parts.dropLast().last : parts.last
        let copy = id.flatMap(copies.firstIndex(of:)).map { $0 + 1 }
        var index = 0
        requests.mutate {
            $0.append(Request(copy: copy, info: info, sent: Date(), others: Self.underWay.value, pages: Self.pagesUnderWay.value))
            index = $0.count - 1
        }
        return Recorder(clock: self, index: index)
    }

    func readout(tap: Date) -> String {
        func line(_ request: Request) -> String {
            let name = request.copy.map { "copy \($0) \(request.info ? "info" : "item")" } ?? "other"
            let took = request.answered.map {
                String(format: request.times == nil ? "no answer in %.2f s" : "%.2f s", $0.timeIntervalSince(request.sent))
            } ?? "no answer"
            let times = request.times.map {
                String(format: ", queued %.2f, connect %.2f, wait %.2f, transfer %.2f", $0.queued, $0.connect, $0.wait, $0.transfer)
            } ?? ""
            return "\(name) \(took) [sent " + String(format: "%+.2f s", request.sent.timeIntervalSince(tap))
                + "\(times), \(request.others) under way, \(request.pages) pages]"
        }
        let byCopy = sent.sorted { ($0.copy ?? .max, $0.info ? 1 : 0) < ($1.copy ?? .max, $1.info ? 1 : 0) }
        return "\(copies.count) \(copies.count == 1 ? "copy" : "copies"); " + byCopy.map(line).joined(separator: "; ")
    }

    final class Recorder: NSObject, URLSessionTaskDelegate, Sendable {
        private let clock: PlanClock
        private let index: Int

        init(clock: PlanClock, index: Int) {
            self.clock = clock
            self.index = index
        }

        func answered() {
            clock.requests.mutate { $0[index].answered = $0[index].answered ?? Date() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            guard let times = RequestTimes(metrics) else { return }
            clock.requests.mutate { $0[index].times = $0[index].times ?? times }
        }
    }
}
#endif

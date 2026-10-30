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

    static func forStart(_ key: PlanKey, on shelf: Shelf<PlanKey, EmbyPlayback>, again: Bool = false,
                         retryAfter: Duration = StartPatience.retryAfter) async throws -> EmbyPlayback {
        var playback = if again { try await shelf.fresh(key) }
            else if StartPatience.off { try await takeTwice(key, on: shelf) }
            else { try await asked(key, on: shelf, againAfter: retryAfter) }
        if !playback.listed, let listed = try? await StartPatience.by(.now + retryAfter, { try await shelf.take(key) }) { playback = listed }
        return playback
    }

    private static func takeTwice(_ key: PlanKey, on shelf: Shelf<PlanKey, EmbyPlayback>) async throws -> EmbyPlayback {
        do { return try await shelf.take(key) } catch { return try await shelf.take(key) }
    }

    private static func asked(_ key: PlanKey, on shelf: Shelf<PlanKey, EmbyPlayback>, againAfter: Duration) async throws -> EmbyPlayback {
        let began = ContinuousClock.now
        return try await withThrowingTaskGroup(of: EmbyPlayback.self) { group in
            group.addTask { try await takeTwice(key, on: shelf) }
            group.addTask {
                try await Task.sleep(for: againAfter)
                return try await shelf.fresh(key)
            }
            defer { group.cancelAll() }
            var failure: Error = CancellationError()
            while let answer = await group.nextResult() {
                switch answer {
                case let .success(playback): return playback
                case let .failure(error):
                    failure = error
                    let failedBeforeTheFreshAsk = ContinuousClock.now - began < againAfter
                    if failedBeforeTheFreshAsk { throw error }
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

enum StartPatience {
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
    /// The app's requests to the server under way (HTTP.data) by kind, and the library's pages among them.
    static let underWay = Locked<[UUID: String]>([:])
    static let pagesUnderWay = Locked(0)
    private static let pathWords: Set<String> = [
        "Users", "Items", "Shows", "NextUp", "Episodes", "Seasons", "Similar", "PlaybackInfo", "Latest", "Resume",
        "DisplayPreferences", "zapline-mylist", "zapline-started", "Sessions", "Playing", "Progress", "Stopped",
        "Capabilities", "System", "Info", "Public", "Persons", "Images", "Primary", "Backdrop", "Logo", "Thumb",
        "Subtitles", "RemoteSearch", "PlayedItems", "FavoriteItems", "UserData", "Providers", "Genres", "Studios",
    ]

    /// The request's path with every part but Emby's own words left out (ids, names), "ahead" when fetched ahead.
    static func kind(of request: URLRequest, ahead: Bool) -> String {
        let parts = (request.url?.pathComponents ?? []).filter { $0 != "/" && $0.lowercased() != "emby" }
        return (ahead ? "ahead " : "") + parts.map { pathWords.contains($0) ? $0 : ":x" }.joined(separator: "/")
    }

    private static func kinds(_ underWay: some Collection<String>) -> String {
        Dictionary(underWay.map { ($0, 1) }, uniquingKeysWith: +).sorted { ($1.value, $0.key) < ($0.value, $1.key) }
            .prefix(6).map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }

    struct Request: Sendable {
        let copy: Int?
        let info: Bool
        let sent: Date
        let others: Int
        let pages: Int
        let kinds: String
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
            let underWay = Self.underWay.value.values
            $0.append(Request(copy: copy, info: info, sent: Date(), others: underWay.count, pages: Self.pagesUnderWay.value,
                              kinds: Self.kinds(underWay)))
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
                + "\(times), \(request.others) under way, \(request.pages) pages; most: \(request.kinds)]"
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

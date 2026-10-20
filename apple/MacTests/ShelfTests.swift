import XCTest
@testable import OpenIPTV

@MainActor
final class ShelfTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let open = Conditions(network: .unmetered, playing: false, lowPower: false, thermal: .nominal,
                                  memoryWarned: false, freeDisk: 10_000_000_000)

    private func lane(atOnce: Int = 2, bucket: Bucket? = nil) -> Lane {
        let open = open
        return Lane(.files, atOnce: atOnce, bucket: bucket) { open }
    }

    private func yieldToQueuedTasks() async {
        for _ in 0..<10 { await Task.yield() }
    }

    private func fails(_ work: () async throws -> Int) async -> Bool {
        do {
            _ = try await work()
            return false
        } catch {
            return true
        }
    }

    private final class Fetches: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var gate: [CheckedContinuation<Void, Never>] = []
        private var passing: Bool
        let started: AsyncStream<String>
        let stopped: AsyncStream<String>
        private let startedSignal: AsyncStream<String>.Continuation
        private let stoppedSignal: AsyncStream<String>.Continuation

        init(held: Bool = false) {
            passing = !held
            (started, startedSignal) = AsyncStream.makeStream()
            (stopped, stoppedSignal) = AsyncStream.makeStream()
        }

        var asked: Int { lock.withLock { count } }

        func letThrough() {
            let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                passing = true
                defer { gate = [] }
                return gate
            }
            waiting.forEach { $0.resume() }
        }

        func fetch(_ key: String, failing: @escaping @Sendable (Int) -> Error? = { _ in nil }) async throws -> Int {
            let number = lock.withLock { count += 1; return count }
            startedSignal.yield(key)
            await withCheckedContinuation { continuation in
                let pass = lock.withLock { () -> Bool in
                    if passing { return true }
                    gate.append(continuation)
                    return false
                }
                if pass { continuation.resume() }
            }
            if Task.isCancelled {
                stoppedSignal.yield(key)
                throw CancellationError()
            }
            if let error = failing(number) { throw error }
            return number
        }

        func endless(_ key: String) async throws -> Int {
            lock.withLock { count += 1 }
            startedSignal.yield(key)
            do { try await Task.sleep(for: .seconds(30)) } catch {
                stoppedSignal.yield(key)
                throw error
            }
            return 0
        }
    }

    private func shelf(_ fetches: Fetches, lane: Lane? = nil, lifetime: Duration = .seconds(60), whenUnused: Shelf<String, Int>.WhenUnused = .finish,
                       retries: [Duration] = [], retryable: @escaping @Sendable (Error) -> Bool = { _ in false },
                       now: @escaping @Sendable () -> Date = { Date() }, disk: Shelf<String, Int>.Disk? = nil,
                       stillThere: @escaping @MainActor (Int) -> Bool = { _ in true },
                       failing: @escaping @Sendable (Int) -> Error? = { _ in nil }) -> Shelf<String, Int> {
        Shelf(.init(lane: lane ?? self.lane(), lifetime: lifetime, whenUnused: whenUnused, retries: retries, retryable: retryable,
                    stillThere: stillThere), disk: disk, now: now) { key in
            try await fetches.fetch(key, failing: failing)
        }
    }

    func testTwoAsksAtOnceMakeOneFetch() async throws {
        let fetches = Fetches(held: true)
        let shelf = shelf(fetches)
        async let first = shelf.value(for: "track 3")
        async let second = shelf.value(for: "track 3")
        var started = fetches.started.makeAsyncIterator()
        _ = await started.next()
        await yieldToQueuedTasks()
        fetches.letThrough()
        let answers = try await [first, second]
        XCTAssertEqual(answers, [1, 1])
        XCTAssertEqual(fetches.asked, 1)
    }

    func testKeptForItsLifetime() async throws {
        let fetches = Fetches(), clock = Locked(start)
        let shelf = shelf(fetches, now: { clock.value })
        let first = try await shelf.value(for: "a")
        clock.mutate { $0 += 59 }
        let within = try await shelf.value(for: "a")
        clock.mutate { $0 += 2 }
        let after = try await shelf.value(for: "a")
        XCTAssertEqual([first, within, after], [1, 1, 2])
    }

    func testAKeptValueThatIsGoneIsFetchedAgain() async throws {
        let fetches = Fetches(), present = Locked(true)
        let shelf = shelf(fetches, stillThere: { _ in present.value })
        _ = try await shelf.value(for: "a")
        present.mutate { $0 = false }
        let again = try await shelf.value(for: "a")
        XCTAssertEqual(again, 2)
    }

    func testWarmedThenPlayedMakesOneFetch() async throws {
        let fetches = Fetches()
        let shelf = shelf(fetches)
        let warmed = await shelf.warm("a", for: Interest(at: .posterRow, .likely))
        let played = try await shelf.value(for: "a")
        XCTAssertEqual(warmed, 1)
        XCTAssertEqual(played, 1)
        XCTAssertEqual(fetches.asked, 1)
    }

    func testPlayJoinsAWarmUpUnderWay() async throws {
        let fetches = Fetches(held: true)
        let shelf = shelf(fetches)
        let interest = Interest(at: .posterRow, .likely)
        async let warmed = shelf.warm("a", for: interest)
        var started = fetches.started.makeAsyncIterator()
        _ = await started.next()
        async let played = shelf.value(for: "a")
        await yieldToQueuedTasks()
        fetches.letThrough()
        let (warmedValue, playedValue) = try await (warmed, played)
        XCTAssertEqual(playedValue, 1)
        XCTAssertEqual(warmedValue, 1)
        XCTAssertEqual(fetches.asked, 1)
    }

    func testWaitingWarmUpIsDroppedWhenItsInterestEnds() async throws {
        let lane = lane(atOnce: 1)
        let busy = Lane.Ticket(Interest(at: .posterRow, .glance))
        try await lane.enter(busy)
        let fetches = Fetches()
        let shelf = shelf(fetches, lane: lane)
        let interest = Interest(at: .posterRow, .glance)
        let warmed = Task { await shelf.warm("a", for: interest) }
        await yieldToQueuedTasks()
        shelf.release("a", from: interest.id)
        lane.leave(busy)
        let warmedValue = await warmed.value
        XCTAssertNil(warmedValue)
        XCTAssertEqual(fetches.asked, 0)
    }

    func testPlayStartsAWaitingWarmUpAtOnce() async throws {
        let lane = lane(atOnce: 1)
        try await lane.enter(Lane.Ticket(Interest(at: .posterRow, .glance)))
        let fetches = Fetches()
        let shelf = shelf(fetches, lane: lane)
        let warmed = Task { await shelf.warm("a", for: Interest(at: .posterRow, .glance)) }
        await yieldToQueuedTasks()
        XCTAssertEqual(fetches.asked, 0)
        let played = try await shelf.value(for: "a")
        let warmedValue = await warmed.value
        XCTAssertEqual(played, 1)
        XCTAssertEqual(warmedValue, 1)
        XCTAssertEqual(fetches.asked, 1)
    }

    func testCheapWarmUpFinishesAfterItsInterestEnds() async throws {
        let fetches = Fetches(held: true)
        let shelf = shelf(fetches)
        let interest = Interest(at: .posterRow, .likely)
        let warmed = Task { await shelf.warm("a", for: interest) }
        var started = fetches.started.makeAsyncIterator()
        _ = await started.next()
        shelf.release("a", from: interest.id)
        fetches.letThrough()
        let warmedValue = await warmed.value
        let played = try await shelf.value(for: "a")
        XCTAssertEqual(warmedValue, 1)
        XCTAssertEqual(played, 1)
        XCTAssertEqual(fetches.asked, 1)
    }

    func testHeavyWarmUpStopsWhenItsInterestEnds() async throws {
        let fetches = Fetches()
        let shelf = Shelf<String, Int>(.init(lane: lane(), lifetime: .seconds(60), whenUnused: .cancel)) { try await fetches.endless($0) }
        let interest = Interest(at: .continueWatching, .next)
        let warmed = Task { await shelf.warm("a", for: interest) }
        var started = fetches.started.makeAsyncIterator(), stopped = fetches.stopped.makeAsyncIterator()
        _ = await started.next()
        shelf.release("a", from: interest.id)
        let warmedValue = await warmed.value
        let stoppedKey = await stopped.next()
        XCTAssertNil(warmedValue)
        XCTAssertEqual(stoppedKey, "a")
    }

    func testHeavyWarmUpJoinedByAPlayGoesOn() async throws {
        let fetches = Fetches(held: true)
        let shelf = shelf(fetches, whenUnused: .cancel)
        let interest = Interest(at: .continueWatching, .next)
        let warmed = Task { await shelf.warm("a", for: interest) }
        var started = fetches.started.makeAsyncIterator()
        _ = await started.next()
        let played = Task { try await shelf.value(for: "a") }
        await yieldToQueuedTasks()
        shelf.release("a", from: interest.id)
        fetches.letThrough()
        let playedValue = try await played.value
        let warmedValue = await warmed.value
        XCTAssertEqual(playedValue, 1)
        XCTAssertEqual(warmedValue, 1)
        XCTAssertEqual(fetches.asked, 1)
    }

    func testAFetchNoOneWaitsForAnyMoreStops() async throws {
        let fetches = Fetches()
        let shelf = Shelf<String, Int>(.init(lane: lane(), lifetime: .seconds(60), whenUnused: .cancel)) { try await fetches.endless($0) }
        let played = Task { try await shelf.value(for: "a") }
        var started = fetches.started.makeAsyncIterator(), stopped = fetches.stopped.makeAsyncIterator()
        _ = await started.next()
        played.cancel()
        let result = await played.result
        let stoppedKey = await stopped.next()
        XCTAssertThrowsError(try result.get())
        XCTAssertEqual(stoppedKey, "a")
    }

    func testAPlayIsNotQueuedBehindPlayersOpenedAhead() async throws {
        let fetches = Fetches(held: true)
        let shelf = shelf(fetches, lane: lane(atOnce: 1))
        let ahead = Interest(at: .page, .next)
        let warmPlayers = (0..<4).map { n in Task { try await shelf.value(for: "warm \(n)", ahead: ahead) } }
        var started = fetches.started.makeAsyncIterator()
        let first = await started.next()
        await yieldToQueuedTasks()
        let played = Task { try await shelf.value(for: "played") }
        let next = await started.next()
        XCTAssertEqual(first?.hasPrefix("warm"), true)
        XCTAssertEqual(next, "played")
        warmPlayers.forEach { $0.cancel() }
        played.cancel()
        fetches.letThrough()
    }

    func testAPlayerOpenedAheadGoesAtOnceWhenPlayed() async throws {
        let lane = lane(atOnce: 1)
        try await lane.enter(Lane.Ticket(Interest(at: .posterRow, .glance)))
        let fetches = Fetches()
        let shelf = shelf(fetches, lane: lane)
        let warmPlayer = Task { try await shelf.value(for: "a", ahead: Interest(at: .page, .next)) }
        await yieldToQueuedTasks()
        XCTAssertEqual(fetches.asked, 0)
        shelf.hurry("a")
        let value = try await warmPlayer.value
        XCTAssertEqual(value, 1)
    }

    func testEveryPlayCountsAgainstTheBudget() async throws {
        let fetches = Fetches()
        let shelf = shelf(fetches, lane: lane(atOnce: 4, bucket: Bucket(size: 2, refillEvery: .seconds(3600), reserve: 0)))
        _ = try await shelf.value(for: "a")
        _ = try await shelf.value(for: "b")
        let warmPlayer = Task { try await shelf.value(for: "c", ahead: Interest(at: .page, .next)) }
        await yieldToQueuedTasks()
        _ = try await shelf.value(for: "d")
        warmPlayer.cancel()
        _ = await warmPlayer.result
        XCTAssertEqual(fetches.asked, 3, "a player opened ahead fetched past the budget the plays had spent")
    }

    func testFailureIsKeptForPlaysToo() async throws {
        let fetches = Fetches()
        let shelf = shelf(fetches, failing: { $0 == 1 ? SourceError.http(500) : nil })
        let warmed = await shelf.warm("a", for: Interest(at: .posterRow, .likely))
        let played = await fails { try await shelf.value(for: "a") }
        XCTAssertNil(warmed)
        XCTAssertTrue(played, "a play asked again within the failure's time")
        XCTAssertEqual(fetches.asked, 1)
    }

    func testFailureIsForgottenAfterItsTime() async throws {
        let fetches = Fetches(), clock = Locked(start)
        let shelf = shelf(fetches, now: { clock.value }, failing: { $0 == 1 ? SourceError.http(500) : nil })
        _ = await shelf.warm("a", for: Interest(at: .posterRow, .likely))
        clock.mutate { $0 += 601 }
        let later = try await shelf.value(for: "a")
        XCTAssertEqual(later, 2)
    }

    func testFailuresWorthRetryingAreRetried() async throws {
        let fetches = Fetches()
        let shelf = shelf(fetches, retries: [.milliseconds(1), .milliseconds(1)], retryable: ServerSubtitles.worthRetrying,
                          failing: { $0 < 3 ? ($0 == 1 ? SourceError.http(503) : SourceError.network("The server took too long to answer.")) : nil })
        let played = try await shelf.value(for: "a")
        XCTAssertEqual(played, 3)
    }

    func testAMissingTrackIsAskedForOnce() async throws {
        let fetches = Fetches()
        let shelf = shelf(fetches, retries: [.milliseconds(1), .milliseconds(1)], retryable: ServerSubtitles.worthRetrying,
                          failing: { _ in SourceError.http(404) })
        let failed = await fails { try await shelf.value(for: "a") }
        XCTAssertTrue(failed)
        XCTAssertEqual(fetches.asked, 1)
    }

    func testAStoppedRequestIsNotKeptAsAFailure() async throws {
        let fetches = Fetches()
        let shelf = shelf(fetches, failing: { $0 == 1 ? CancellationError() : nil })
        let stopped = await fails { try await shelf.value(for: "a") }
        let again = try await shelf.value(for: "a")
        XCTAssertTrue(stopped)
        XCTAssertEqual(again, 2)
    }

    func testFreshOnDiskIsReadWithoutAFetch() async throws {
        let fetches = Fetches(), clock = Locked(start)
        let stored = clock.value - 30
        let shelf = shelf(fetches, now: { clock.value }, disk: { _ in (value: 7, at: stored) })
        let played = try await shelf.value(for: "a")
        XCTAssertEqual(played, 7)
        XCTAssertEqual(fetches.asked, 0)
    }

    func testStaleOnDiskIsFetchedAgain() async throws {
        let fetches = Fetches(), clock = Locked(start)
        let stored = clock.value - 61
        let shelf = shelf(fetches, now: { clock.value }, disk: { _ in (value: 7, at: stored) })
        let played = try await shelf.value(for: "a")
        XCTAssertEqual(played, 1)
    }

    func testForgetAllDropsWhatWasKept() async throws {
        let fetches = Fetches()
        let shelf = shelf(fetches)
        _ = try await shelf.value(for: "a")
        shelf.forgetAll()
        let again = try await shelf.value(for: "a")
        XCTAssertEqual(again, 2)
    }

    func testForgetAllKeepsNothingFromAFetchUnderWay() async throws {
        let fetches = Fetches(held: true)
        let shelf = shelf(fetches)
        let first = Task { try await shelf.value(for: "a") }
        var started = fetches.started.makeAsyncIterator()
        _ = await started.next()
        shelf.forgetAll()
        _ = await first.result
        fetches.letThrough()
        let again = try await shelf.value(for: "a")
        XCTAssertEqual(again, 2)
    }

    func testAnInterestIsNeverTakenForAnEarlierOne() {
        var ids: Set<Interest.ID> = []
        for _ in 0..<1000 { ids.insert(Interest(at: .posterRow, .glance).id) }
        XCTAssertEqual(ids.count, 1000)
    }


    func testLaneRunsAtMostItsLimitAtOnce() async throws {
        let lane = lane(atOnce: 1)
        let first = Lane.Ticket(Interest(at: .posterRow, .glance))
        try await lane.enter(first)
        let entered = Locked(false)
        let second = Task {
            try await lane.enter(Lane.Ticket(Interest(at: .posterRow, .glance)))
            entered.mutate { $0 = true }
        }
        await yieldToQueuedTasks()
        XCTAssertFalse(entered.value)
        lane.leave(first)
        try await second.value
        XCTAssertTrue(entered.value)
    }

    func testLikeliestThenNewestGoFirst() async throws {
        let lane = lane(atOnce: 1)
        let busy = Lane.Ticket(Interest(at: .posterRow, .glance))
        try await lane.enter(busy)
        let order = Locked<[String]>([])
        var waiters: [Task<Void, Error>] = []
        for (name, likelihood) in [("glance", Likelihood.glance), ("older likely", .likely), ("newer likely", .likely)] {
            let ticket = Lane.Ticket(Interest(at: .posterRow, likelihood))
            waiters.append(Task {
                try await lane.enter(ticket)
                order.mutate { $0.append(name) }
                lane.leave(ticket)
            })
        }
        await yieldToQueuedTasks()
        lane.leave(busy)
        for waiter in waiters { try await waiter.value }
        XCTAssertEqual(order.value, ["newer likely", "older likely", "glance"])
    }

    func testBucketKeepsItsReserveAndRefills() async throws {
        let open = open
        let lane = Lane(.heavy, atOnce: 4, bucket: Bucket(size: 2, refillEvery: .milliseconds(200), reserve: 1)) { open }
        let began = ContinuousClock.now
        try await lane.enter(Lane.Ticket(Interest(at: .continueWatching, .next)))
        XCTAssertLessThan(ContinuousClock.now - began, .milliseconds(100))
        try await lane.enter(Lane.Ticket(Interest(at: .continueWatching, .next)))
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - began, .milliseconds(150))
    }

    func testLaneRefusesWhatTheDeviceDoesNotAllow() async {
        var cellular = open
        cellular.network = .expensive
        let lane = Lane(.files, atOnce: 1) { cellular }
        do {
            try await lane.enter(Lane.Ticket(Interest(at: .posterRow, .likely)))
            XCTFail("a file was fetched ahead on cellular")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testWaitersGoWhenConditionsClose() async throws {
        let conditions = Locked(open)
        let lane = Lane(.files, atOnce: 1) { conditions.value }
        try await lane.enter(Lane.Ticket(Interest(at: .posterRow, .glance)))
        let waiter = Task { try await lane.enter(Lane.Ticket(Interest(at: .posterRow, .glance))) }
        await yieldToQueuedTasks()
        conditions.mutate { $0.playing = true }
        lane.conditionsChanged()
        do {
            try await waiter.value
            XCTFail("a waiter went on after a film started playing")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testCancelledWaiterTakesNoTurn() async throws {
        let lane = lane(atOnce: 1)
        let busy = Lane.Ticket(Interest(at: .posterRow, .glance))
        try await lane.enter(busy)
        let waiter = Task { try await lane.enter(Lane.Ticket(Interest(at: .posterRow, .glance))) }
        await yieldToQueuedTasks()
        waiter.cancel()
        do {
            try await waiter.value
            XCTFail("a cancelled waiter took a turn")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        lane.leave(busy)
        let next = Lane.Ticket(Interest(at: .posterRow, .glance))
        let entered = Task { try await lane.enter(next) }
        await yieldToQueuedTasks()
        try await entered.value
    }

    func testAPlayGoesAtOnce() async throws {
        let lane = lane(atOnce: 1)
        try await lane.enter(Lane.Ticket(Interest(at: .posterRow, .glance)))
        try await lane.enter(Lane.Ticket(nil))
        let ticket = Lane.Ticket(Interest(at: .posterRow, .glance))
        let waiter = Task { try await lane.enter(ticket) }
        await yieldToQueuedTasks()
        lane.playNow(ticket)
        try await waiter.value
    }


    func testWhatEachConditionAllows() {
        let weights: [Weight] = [.light, .files, .heavy, .bytes, .images, .player, .iptv]
        func allowed(_ change: (inout Conditions) -> Void, at place: Place = .posterRow) -> [Weight] {
            var conditions = open
            change(&conditions)
            return weights.filter { conditions.allows($0, at: place) }
        }
        XCTAssertEqual(allowed { _ in }, weights)
        XCTAssertEqual(allowed { $0.network = .expensive }, [.light, .iptv])
        XCTAssertEqual(allowed { $0.network = .unknown }, [.light, .iptv])
        XCTAssertEqual(allowed { $0.network = .constrained }, [])
        XCTAssertEqual(allowed { $0.thermal = .fair }, weights)
        XCTAssertEqual(allowed { $0.thermal = .serious }, [])
        XCTAssertEqual(allowed { $0.thermal = .critical }, [])
        XCTAssertEqual(allowed { $0.memoryWarned = true }, [])
        XCTAssertEqual(allowed { $0.playing = true }, [])
        XCTAssertEqual(allowed({ $0.playing = true }, at: .upNext), [.light])
        XCTAssertEqual(allowed { $0.lowPower = true }, [.light, .files, .bytes, .images, .iptv])
        XCTAssertEqual(allowed { $0.freeDisk = 1_000_000_000 }, [.light, .files, .heavy, .images, .player, .iptv])
    }
}

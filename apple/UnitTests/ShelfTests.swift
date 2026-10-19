import XCTest

/// One owner per server resource (Shelf): a fetch under way is joined, a
/// result is kept for its lifetime, and work ahead waits for its source's
/// budget (Lane) while a play never does.
@MainActor
final class ShelfTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let open = Conditions(network: .unmetered, playing: false, lowPower: false, thermal: .nominal,
                                  memoryWarned: false, freeDisk: 10_000_000_000)

    private func lane(atOnce: Int = 2) -> Lane {
        let open = open
        return Lane(.files, atOnce: atOnce) { open }
    }

    private func counting<Value: Sendable>(_ asked: Locked<Int>, after wait: Duration = .zero,
                                           _ answer: @escaping @Sendable (Int) throws -> Value) -> @Sendable (String) async throws -> Value {
        { _ in
            asked.mutate { $0 += 1 }
            let count = asked.value
            if wait > .zero { try await Task.sleep(for: wait) }
            return try answer(count)
        }
    }

    func testTwoAsksAtOnceMakeOneFetch() async throws {
        let asked = Locked(0)
        let shelf = Shelf(.init(lane: lane(), lifetime: .seconds(60)), fetch: counting(asked, after: .milliseconds(50)) { $0 })
        async let first = shelf.value(for: "track 3")
        async let second = shelf.value(for: "track 3")
        let answers = try await [first, second]
        XCTAssertEqual(answers, [1, 1])
        XCTAssertEqual(asked.value, 1)
    }

    func testKeptForItsLifetime() async throws {
        let asked = Locked(0), clock = Locked(start)
        let shelf = Shelf(.init(lane: lane(), lifetime: .seconds(60)), now: { clock.value }, fetch: counting(asked) { $0 })
        let first = try await shelf.value(for: "a")
        clock.mutate { $0 += 59 }
        let within = try await shelf.value(for: "a")
        clock.mutate { $0 += 2 }
        let after = try await shelf.value(for: "a")
        XCTAssertEqual([first, within, after], [1, 1, 2])
    }

    func testWarmedThenPlayedMakesOneFetch() async throws {
        let asked = Locked(0)
        let shelf = Shelf(.init(lane: lane(), lifetime: .seconds(60)), fetch: counting(asked) { $0 })
        let warmed = await shelf.warm("a", for: Interest(at: .posterRow, .likely))
        let played = try await shelf.value(for: "a")
        XCTAssertEqual(warmed, 1)
        XCTAssertEqual(played, 1)
        XCTAssertEqual(asked.value, 1)
    }

    func testPlayJoinsAWarmUpUnderWay() async throws {
        let asked = Locked(0)
        let shelf = Shelf(.init(lane: lane(), lifetime: .seconds(60)), fetch: counting(asked, after: .milliseconds(100)) { $0 })
        let interest = Interest(at: .posterRow, .likely)
        async let warmed = shelf.warm("a", for: interest)
        try await Task.sleep(for: .milliseconds(20))
        let played = try await shelf.value(for: "a")
        let warmedValue = await warmed
        XCTAssertEqual(played, 1)
        XCTAssertEqual(warmedValue, 1)
        XCTAssertEqual(asked.value, 1)
    }

    func testWaitingWarmUpIsDroppedWhenItsInterestEnds() async throws {
        let lane = lane(atOnce: 1)
        let busy = Lane.Ticket(Interest(at: .posterRow, .glance))
        try await lane.enter(busy)
        let asked = Locked(0)
        let shelf = Shelf(.init(lane: lane, lifetime: .seconds(60)), fetch: counting(asked) { $0 })
        let interest = Interest(at: .posterRow, .glance)
        async let warmed = shelf.warm("a", for: interest)
        try await Task.sleep(for: .milliseconds(20))
        shelf.release("a", from: interest.id)
        lane.leave(busy)
        let warmedValue = await warmed
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertNil(warmedValue)
        XCTAssertEqual(asked.value, 0)
    }

    func testPlayStartsAWaitingWarmUpAtOnce() async throws {
        let lane = lane(atOnce: 1)
        try await lane.enter(Lane.Ticket(Interest(at: .posterRow, .glance)))
        let asked = Locked(0)
        let shelf = Shelf(.init(lane: lane, lifetime: .seconds(60)), fetch: counting(asked) { $0 })
        let interest = Interest(at: .posterRow, .glance)
        async let warmed = shelf.warm("a", for: interest)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(asked.value, 0)
        let played = try await shelf.value(for: "a")
        let warmedValue = await warmed
        XCTAssertEqual(played, 1)
        XCTAssertEqual(warmedValue, 1)
        XCTAssertEqual(asked.value, 1)
    }

    func testCheapWarmUpFinishesAfterItsInterestEnds() async throws {
        let asked = Locked(0)
        let shelf = Shelf(.init(lane: lane(), lifetime: .seconds(60)), fetch: counting(asked, after: .milliseconds(50)) { $0 })
        let interest = Interest(at: .posterRow, .likely)
        async let warmed = shelf.warm("a", for: interest)
        try await Task.sleep(for: .milliseconds(10))
        shelf.release("a", from: interest.id)
        let warmedValue = await warmed
        let played = try await shelf.value(for: "a")
        XCTAssertEqual(warmedValue, 1)
        XCTAssertEqual(played, 1)
        XCTAssertEqual(asked.value, 1)
    }

    func testHeavyWarmUpStopsWhenItsInterestEnds() async throws {
        let stopped = Locked(false)
        let shelf = Shelf<String, Int>(.init(lane: lane(), lifetime: .seconds(60), onLeave: .cancel)) { _ in
            do { try await Task.sleep(for: .seconds(5)) } catch { stopped.mutate { $0 = true }; throw error }
            return 1
        }
        let interest = Interest(at: .continueWatching, .next)
        async let warmed = shelf.warm("a", for: interest)
        try await Task.sleep(for: .milliseconds(20))
        shelf.release("a", from: interest.id)
        let warmedValue = await warmed
        XCTAssertNil(warmedValue)
        XCTAssertTrue(stopped.value)
    }

    func testHeavyWarmUpJoinedByAPlayGoesOn() async throws {
        let asked = Locked(0)
        let shelf = Shelf(.init(lane: lane(), lifetime: .seconds(60), onLeave: .cancel),
                          fetch: counting(asked, after: .milliseconds(100)) { $0 })
        let interest = Interest(at: .continueWatching, .next)
        async let warmed = shelf.warm("a", for: interest)
        try await Task.sleep(for: .milliseconds(20))
        async let played = shelf.value(for: "a")
        try await Task.sleep(for: .milliseconds(10))
        shelf.release("a", from: interest.id)
        let playedValue = try await played
        let warmedValue = await warmed
        XCTAssertEqual(playedValue, 1)
        XCTAssertEqual(warmedValue, 1)
        XCTAssertEqual(asked.value, 1)
    }

    func testFailureStopsWarmUpsButNotAPlay() async throws {
        let asked = Locked(0)
        let shelf = Shelf(.init(lane: lane(), lifetime: .seconds(60)), fetch: counting(asked) { count in
            if count == 1 { throw SourceError.http(500) }
            return count
        })
        let first = await shelf.warm("a", for: Interest(at: .posterRow, .likely))
        let again = await shelf.warm("a", for: Interest(at: .posterRow, .likely))
        XCTAssertNil(first)
        XCTAssertNil(again)
        XCTAssertEqual(asked.value, 1)
        let played = try await shelf.value(for: "a")
        XCTAssertEqual(played, 2)
    }

    func testFailureIsForgottenAfterItsTime() async throws {
        let asked = Locked(0), clock = Locked(start)
        let shelf = Shelf(.init(lane: lane(), lifetime: .seconds(60), failureKept: .seconds(600)), now: { clock.value },
                          fetch: counting(asked) { count in
                              if count == 1 { throw SourceError.http(500) }
                              return count
                          })
        _ = await shelf.warm("a", for: Interest(at: .posterRow, .likely))
        clock.mutate { $0 += 601 }
        let later = await shelf.warm("a", for: Interest(at: .posterRow, .likely))
        XCTAssertEqual(later, 2)
    }

    func testFailedFetchIsRetried() async throws {
        let asked = Locked(0)
        let shelf = Shelf(.init(lane: lane(), lifetime: .seconds(60), retries: [.milliseconds(10), .milliseconds(10)]),
                          fetch: counting(asked) { count in
                              if count < 3 { throw SourceError.network("The server took too long to answer.") }
                              return count
                          })
        let played = try await shelf.value(for: "a")
        XCTAssertEqual(played, 3)
        XCTAssertEqual(asked.value, 3)
    }

    func testRetriesThatAllFailEndInFailure() async throws {
        let asked = Locked(0)
        let shelf = Shelf<String, Int>(.init(lane: lane(), lifetime: .seconds(60), retries: [.milliseconds(10)]),
                                       fetch: counting(asked) { _ in throw SourceError.http(500) })
        do {
            _ = try await shelf.value(for: "a")
            XCTFail("a fetch that always fails answered")
        } catch {}
        XCTAssertEqual(asked.value, 2)
    }

    func testFreshOnDiskIsReadWithoutAFetch() async throws {
        let asked = Locked(0), clock = Locked(start)
        let stored = clock.value - 30
        let disk = Shelf<String, Int>.Disk(find: { _ in (value: 7, at: stored) }, removeAll: {})
        let shelf = Shelf(.init(lane: lane(), lifetime: .seconds(60)), disk: disk, now: { clock.value },
                          fetch: counting(asked) { $0 })
        let played = try await shelf.value(for: "a")
        XCTAssertEqual(played, 7)
        XCTAssertEqual(asked.value, 0)
    }

    func testStaleOnDiskIsFetchedAgain() async throws {
        let asked = Locked(0), clock = Locked(start)
        let stored = clock.value - 61
        let disk = Shelf<String, Int>.Disk(find: { _ in (value: 7, at: stored) }, removeAll: {})
        let shelf = Shelf(.init(lane: lane(), lifetime: .seconds(60)), disk: disk, now: { clock.value },
                          fetch: counting(asked) { $0 })
        let played = try await shelf.value(for: "a")
        XCTAssertEqual(played, 1)
    }

    func testForgetAllDropsWhatWasKept() async throws {
        let asked = Locked(0), removed = Locked(false)
        let disk = Shelf<String, Int>.Disk(find: { _ in nil }, removeAll: { removed.mutate { $0 = true } })
        let shelf = Shelf(.init(lane: lane(), lifetime: .seconds(60)), disk: disk, fetch: counting(asked) { $0 })
        _ = try await shelf.value(for: "a")
        shelf.forgetAll()
        let again = try await shelf.value(for: "a")
        XCTAssertEqual(again, 2)
        XCTAssertTrue(removed.value)
    }

    func testForgetAllKeepsNothingFromAFetchUnderWay() async throws {
        let asked = Locked(0)
        let shelf = Shelf(.init(lane: lane(), lifetime: .seconds(60)), fetch: counting(asked, after: .milliseconds(50)) { $0 })
        let first = Task { try await shelf.value(for: "a") }
        try await Task.sleep(for: .milliseconds(10))
        shelf.forgetAll()
        _ = try? await first.value
        let again = try await shelf.value(for: "a")
        XCTAssertEqual(again, 2)
    }

    // MARK: Lane

    func testLaneRunsAtMostItsLimitAtOnce() async throws {
        let lane = lane(atOnce: 1)
        let first = Lane.Ticket(Interest(at: .posterRow, .glance))
        try await lane.enter(first)
        let entered = Locked(false)
        let second = Task {
            try await lane.enter(Lane.Ticket(Interest(at: .posterRow, .glance)))
            entered.mutate { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(20))
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
            try await Task.sleep(for: .milliseconds(5))
        }
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
        try await Task.sleep(for: .milliseconds(20))
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
        try await Task.sleep(for: .milliseconds(20))
        waiter.cancel()
        do {
            try await waiter.value
            XCTFail("a cancelled waiter took a turn")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        lane.leave(busy)
        let began = ContinuousClock.now
        try await lane.enter(Lane.Ticket(Interest(at: .posterRow, .glance)))
        XCTAssertLessThan(ContinuousClock.now - began, .milliseconds(100))
    }

    func testAdmittedNowSkipsTheQueue() async throws {
        let lane = lane(atOnce: 1)
        try await lane.enter(Lane.Ticket(Interest(at: .posterRow, .glance)))
        let ticket = Lane.Ticket(Interest(at: .posterRow, .glance))
        let waiter = Task { try await lane.enter(ticket) }
        try await Task.sleep(for: .milliseconds(20))
        lane.admitNow(ticket)
        try await waiter.value
    }

    // MARK: Conditions

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

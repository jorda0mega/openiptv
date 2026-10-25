import XCTest
@testable import OpenIPTV

@MainActor
final class PlansTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let open = Conditions(network: .unmetered, playing: false, lowPower: false, thermal: .nominal,
                                  memoryWarned: false, freeDisk: .init(bytes: 10_000_000_000, countsPurgeable: true))
    private let film = PlanKey(itemId: "m5", kind: "Movie", versions: ["m5"])

    private final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0, underWay = 0
        private(set) var order: [String] = []
        private(set) var mostAtOnce = 0
        private let failing: Set<Int>
        private let wait: Double

        init(failing: Set<Int> = [], wait: Double = 0) {
            self.failing = failing
            self.wait = wait
        }

        var asked: Int { lock.withLock { count } }

        func playback(_ key: PlanKey) async throws -> EmbyPlayback {
            let number = lock.withLock {
                count += 1
                underWay += 1
                mostAtOnce = max(mostAtOnce, underWay)
                order.append(key.itemId)
                return count
            }
            try? await Task.sleep(for: .seconds(wait))
            lock.withLock { underWay -= 1 }
            if failing.contains(number) { throw SourceError.http(503) }
            var playback = EmbyPlayback(itemId: key.itemId, title: key.itemId, subtitle: nil, url: URL(string: "http://server/\(key.itemId)")!,
                                        durationSeconds: 7200)
            playback.playSessionId = "session \(number)"
            return playback
        }
    }

    private func plans(_ server: Server, now: @escaping @Sendable () -> Date = { Date() }) -> Shelf<PlanKey, EmbyPlayback> {
        let open = open
        return Plans.shelf(lane: Lane(.light, atOnce: 4) { open }, now: now) { try await server.playback($0) }
    }

    func testAPlanGotReadyAheadIsPlayedWithoutAskingAgain() async throws {
        let server = Server()
        let plans = plans(server)
        _ = await plans.warm(film, for: Interest(at: .continueWatching, .likely))
        let played = try await plans.take(film)
        XCTAssertEqual(played.playSessionId, "session 1")
        XCTAssertEqual(server.asked, 1)
    }

    func testAPlanServesOnePlayOnly() async throws {
        let server = Server()
        let plans = plans(server)
        let first = try await plans.take(film)
        let second = try await plans.take(film)
        XCTAssertNotEqual(first.playSessionId, second.playSessionId, "two plays shared one play session")
        XCTAssertEqual(server.asked, 2)
    }

    func testAPlanIsKeptThreeMinutes() async throws {
        let server = Server(), clock = Locked(start)
        let plans = plans(server, now: { clock.value })
        _ = await plans.warm(film, for: Interest(at: .continueWatching, .likely))
        clock.mutate { $0 += 179 }
        _ = try await plans.take(film)
        _ = await plans.warm(film, for: Interest(at: .continueWatching, .likely))
        clock.mutate { $0 += 181 }
        _ = try await plans.take(film)
        XCTAssertEqual(server.asked, 3)
    }

    func testAWarmUpThatFailedDoesNotFailThePlay() async throws {
        let server = Server(failing: [1])
        let plans = plans(server)
        let warmed = await plans.warm(film, for: Interest(at: .continueWatching, .likely))
        let played = try await plans.take(film)
        XCTAssertNil(warmed)
        XCTAssertEqual(played.playSessionId, "session 2")
    }

    func testACopyFoundSinceMakesANewPlan() async throws {
        let server = Server()
        let plans = plans(server)
        _ = await plans.warm(film, for: Interest(at: .continueWatching, .likely))
        let played = try await plans.take(PlanKey(itemId: "m5", kind: "Movie", versions: ["m5", "k5"]))
        XCTAssertEqual(played.playSessionId, "session 2")
    }

    func testTheKindAskedWithIsTheSamePlan() async throws {
        let server = Server()
        let plans = plans(server)
        _ = await plans.warm(film, for: Interest(at: .continueWatching, .likely))
        _ = try await plans.take(PlanKey(itemId: "m5", kind: nil, versions: ["m5"]))
        XCTAssertEqual(server.asked, 1)
    }

    func testHomeAsksEveryCardsPlanFirstCardFirstOneAtATime() async throws {
        let server = Server(wait: 0.05)
        let plans = plans(server)
        let cards = ["m1", "e2", "m3"].map { PlanKey(itemId: $0, kind: "Movie", versions: [$0]) }
        await Plans.forecast(cards, on: plans)
        XCTAssertEqual(server.order, ["m1", "e2", "m3"])
        XCTAssertEqual(server.mostAtOnce, 1, "Home's plans went out together")
        _ = try await plans.take(cards[2])
        XCTAssertEqual(server.asked, 3, "the third card's tap asked again")
    }

    func testAPlanAskedByHomeGoesFirstOnceItsCardIsHeldOnScreen() async throws {
        let server = Server(wait: 0.3)
        let open = open
        let plans = Plans.shelf(lane: Lane(.light, atOnce: 1) { open }) { try await server.playback($0) }
        let keys = ["m0", "m1", "m2"].map { PlanKey(itemId: $0, kind: "Movie", versions: [$0]) }
        var asks: [Task<EmbyPlayback?, Never>] = []
        for (key, likelihood) in [(keys[0], Likelihood.likely), (keys[1], .glance), (keys[2], .glance), (keys[1], .likely)] {
            asks.append(Task { await plans.warm(key, for: Interest(at: .continueWatching, likelihood)) })
            try await Task.sleep(for: .milliseconds(30))
        }
        for ask in asks { _ = await ask.value }
        XCTAssertEqual(server.order, ["m0", "m1", "m2"], "the card held on screen waited behind one only Home asked for")
    }

    func testAStopForgetsThatTitlesPlanOnly() async throws {
        let server = Server()
        let plans = plans(server)
        let other = PlanKey(itemId: "m6", kind: "Movie", versions: ["m6"])
        _ = await plans.warm(film, for: Interest(at: .continueWatching, .likely))
        _ = await plans.warm(other, for: Interest(at: .continueWatching, .likely))
        plans.forget { $0.itemId == "m5" }
        _ = try await plans.take(film)
        _ = try await plans.take(other)
        XCTAssertEqual(server.asked, 3)
    }
}

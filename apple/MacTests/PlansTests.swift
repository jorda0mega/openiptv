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
        private var count = 0
        private let failing: Set<Int>

        init(failing: Set<Int> = []) { self.failing = failing }

        var asked: Int { lock.withLock { count } }

        func playback(_ key: PlanKey) throws -> EmbyPlayback {
            let number = lock.withLock { count += 1; return count }
            if failing.contains(number) { throw SourceError.http(503) }
            var playback = EmbyPlayback(itemId: key.itemId, title: key.itemId, subtitle: nil, url: URL(string: "http://server/\(key.itemId)")!,
                                        durationSeconds: 7200)
            playback.playSessionId = "session \(number)"
            return playback
        }
    }

    private func plans(_ server: Server, now: @escaping @Sendable () -> Date = { Date() }) -> Shelf<PlanKey, EmbyPlayback> {
        let open = open
        return Plans.shelf(lane: Lane(.light, atOnce: 4) { open }, now: now) { try server.playback($0) }
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

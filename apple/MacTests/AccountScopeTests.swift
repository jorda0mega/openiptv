import XCTest
@testable import OpenIPTV

@MainActor
final class AccountScopeTests: XCTestCase {
    private let open = Conditions(network: .unmetered, playing: false, lowPower: false, thermal: .nominal,
                                  memoryWarned: false, freeDisk: .init(bytes: 10_000_000_000, countsPurgeable: true))
    private let tester = EmbyAccount(serverURL: URL(string: "http://server")!, serverName: "Mock", userId: "U1", userName: "tester",
                                     accessToken: "test")
    private let film = PlanKey(itemId: "m1", kind: "Movie", versions: ["m1"])

    private final class Player: KeptPlayer {
        var hasStarted = true
        var hasFailed = false
        private(set) var stopped = 0
        func shutdown() { stopped += 1 }
    }

    private final class Server: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var asked: Int { lock.withLock { count } }

        func plan(_ key: PlanKey) -> EmbyPlayback {
            lock.withLock { count += 1 }
            return EmbyPlayback(itemId: key.itemId, title: key.itemId, subtitle: nil, url: URL(string: "http://server/\(key.itemId)")!,
                                durationSeconds: 7200)
        }
    }

    private func scope(_ server: Server = Server(), sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                       retryHome: @escaping @MainActor () async -> Void = {}) -> AccountScope {
        let open = open
        return AccountScope(client: EmbyClient(account: tester, deviceId: "device"), lane: Lane(.light, atOnce: 4) { open }, sleep: sleep,
                            askPlan: { _, key in server.plan(key) }, retryHome: retryHome)
    }

    private func film(at seconds: Double) -> EmbyPlayback {
        var playback = EmbyPlayback(itemId: "m1", title: "Film", subtitle: nil, url: URL(string: "http://server/m1")!, durationSeconds: 7200)
        playback.startSeconds = seconds
        return playback
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    func testAClosedScopeHasNoServerToAsk() {
        let scope = scope()
        XCTAssertNotNil(scope.emby)
        scope.close()
        XCTAssertNil(scope.emby)
    }

    func testClosingStopsTheAccountsWork() async {
        let scope = scope()
        let work = scope.run { () -> Bool in
            try? await Task.sleep(for: .seconds(3600))
            return Task.isCancelled
        }
        scope.close()
        let stopped = await work.value
        XCTAssertTrue(stopped)
    }

    func testWorkForAClosedScopeIsStoppedBeforeItStarts() async {
        let scope = scope()
        scope.close()
        let stopped = await scope.run { Task.isCancelled }.value
        XCTAssertTrue(stopped)
    }

    func testWorkForTheAccountOnACallersBehalfStopsWhenTheAccountCloses() async {
        let scope = scope()
        let caller = Task { await scope.attach { () -> Bool in
            try? await Task.sleep(for: .seconds(3600))
            return Task.isCancelled
        } }
        await settle()
        scope.close()
        let stopped = await caller.value
        XCTAssertTrue(stopped)
    }

    func testWorkForTheAccountOnACallersBehalfStopsWhenTheCallerDoes() async {
        let scope = scope()
        let caller = Task { await scope.attach { () -> Bool in
            try? await Task.sleep(for: .seconds(3600))
            return Task.isCancelled
        } }
        await settle()
        caller.cancel()
        let stopped = await caller.value
        XCTAssertTrue(stopped)
        XCTAssertTrue(scope.isOpen)
    }

    func testNoPlayerIsKeptWithNoAccountSignedIn() {
        let scope = AccountScope(client: nil), player = Player()
        scope.keepWarm(player, film(at: 600), parked: true, for: .seconds(300))
        XCTAssertEqual(player.stopped, 1)
        XCTAssertNil(scope.warm)
    }

    func testClosingStopsTheWarmPlayer() {
        let scope = scope(), player = Player()
        scope.keepWarm(player, film(at: 600), parked: true, for: .seconds(300))
        scope.close()
        XCTAssertEqual(player.stopped, 1)
        XCTAssertNil(scope.takeWarm("m1", at: 600))
    }

    func testAPlayerKeptForAClosedScopeStopsAtOnce() {
        let scope = scope(), player = Player()
        scope.close()
        scope.keepWarm(player, film(at: 600), parked: true, for: .seconds(300))
        XCTAssertEqual(player.stopped, 1)
        XCTAssertNil(scope.warm)
    }

    func testAWarmPlayerStopsWhenItsTimeIsUp() async {
        let scope = scope(sleep: { _ in }), player = Player()
        scope.keepWarm(player, film(at: 600), parked: true, for: .seconds(300))
        await settle()
        XCTAssertEqual(player.stopped, 1)
        XCTAssertNil(scope.warm)
    }

    func testAWarmPlayerIsHandedOverOnlyWhereItStopped() {
        let scope = scope(), player = Player()
        scope.keepWarm(player, film(at: 600), parked: true, for: .seconds(300))
        XCTAssertTrue(scope.takeWarm("m1", at: 601) === player)
        XCTAssertEqual(player.stopped, 0)
        let other = Player()
        scope.keepWarm(other, film(at: 600), parked: true, for: .seconds(300))
        XCTAssertNil(scope.takeWarm("m1", at: 900))
        XCTAssertEqual(other.stopped, 1)
    }

    func testClosingForgetsThePlansAndAsksTheServerNoMore() async {
        let server = Server()
        let scope = scope(server)
        _ = await scope.plans.warm(film, for: Interest(at: .continueWatching, .likely))
        XCTAssertTrue(scope.plans.isKept(film))
        scope.close()
        XCTAssertFalse(scope.plans.isKept(film))
        _ = await scope.plans.warm(film, for: Interest(at: .continueWatching, .likely))
        XCTAssertEqual(server.asked, 1)
    }

    func testClosingStopsTheHomeRetry() async {
        var asked = 0
        let scope = scope(sleep: { _ in }, retryHome: { asked += 1 })
        scope.homeRetry.askAgainLater()
        scope.close()
        await settle()
        XCTAssertEqual(asked, 0)
        XCTAssertFalse(scope.homeRetry.failing)
    }

    func testTitlePagesShowNothingOnceTheScopeCloses() throws {
        let scope = scope()
        let item = try JSONDecoder().decode(EmbyItem.self, from: Data(#"{"Id":"s1","Name":"Show","Type":"Series"}"#.utf8))
        let show = scope.showState("s1"), movie = scope.movieState("m1")
        scope.shows["s1"] = ShowData(show: item, episodes: [], nextUp: nil, loadedAt: Date())
        scope.movies["m1"] = MovieData(item: item, similar: [], loadedAt: Date())
        XCTAssertNotNil(show.value)
        XCTAssertNotNil(movie.value)
        scope.close()
        XCTAssertNil(show.value)
        XCTAssertNil(movie.value)
    }
}

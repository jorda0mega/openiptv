import XCTest
@testable import OpenIPTV

final class FetchAheadTests: XCTestCase {
    func testFetchedAheadRequestsReachTheServerFourAtATimeWhenItsConnectionsCapNothing() async throws {
        let arrived = Locked<[ContinuousClock.Instant]>([])
        let server = try LocalServer(wait: 0.3) { _ in
            arrived.mutate { $0.append(.now) }
            return (200, [:], "ok")
        }
        defer { server.stop() }
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 100
        let asOnHTTP2 = URLSession(configuration: config)
        for n in 0..<12 {
            Task(priority: .utility) {
                let url = URL(string: "http://127.0.0.1:\(server.port)/ahead/\(n)")!
                _ = try? await HTTP.data(URLRequest(url: url), aheadOn: asOnHTTP2)
            }
        }
        for _ in 0..<100 where arrived.value.count < 12 { try await Task.sleep(for: .milliseconds(50)) }
        let times = arrived.value.sorted()
        XCTAssertEqual(times.count, 12)
        let mostAtOnce = times.indices.map { i in times[i...].prefix { $0 - times[i] < .milliseconds(250) }.count }.max() ?? 0
        XCTAssertLessThanOrEqual(mostAtOnce, 4, "fetched ahead under way at once on the server")
    }

    func testNothingFetchedAheadGoesWhileAStartWaitsOnTheServer() async throws {
        let arrived = Locked(0)
        let server = try LocalServer { _ in
            arrived.mutate { $0 += 1 }
            return (200, [:], "ok")
        }
        defer { server.stop() }
        let start = Task { await HTTP.turns.whileStarting() }
        try await Task.sleep(for: .milliseconds(50))
        let url = URL(string: "http://127.0.0.1:\(server.port)/ahead")!
        _ = Task(priority: .utility) { try await HTTP.data(URLRequest(url: url)) }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(arrived.value, 0, "asked while a start waited")
        start.cancel()
        for _ in 0..<20 where arrived.value == 0 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(arrived.value, 1, "asked once the start played")
    }

    func testNothingFetchedAheadGoesWhileAFilmPlays() async throws {
        let arrived = Locked(0)
        let server = try LocalServer { _ in
            arrived.mutate { $0 += 1 }
            return (200, [:], "ok")
        }
        defer { server.stop() }
        PlaybackActivity.began(.film)
        let url = URL(string: "http://127.0.0.1:\(server.port)/ahead")!
        _ = Task(priority: .utility) { try await HTTP.data(URLRequest(url: url)) }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(arrived.value, 0, "asked while a film played")
        PlaybackActivity.ended(.film)
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(arrived.value, 0, "asked as the film ended, when a tap on the next title likely comes")
        try await Task.sleep(for: PlaybackActivity.quietAfterFilm)
        XCTAssertEqual(arrived.value, 1, "asked once the film had ended a while ago")
    }

    func testWhatAPlayingFilmAsksForGoesAtOnce() async throws {
        let server = try LocalServer { _ in (200, [:], "ok") }
        defer { server.stop() }
        PlaybackActivity.began(.film)
        let url = URL(string: "http://127.0.0.1:\(server.port)/season")!
        let began = ContinuousClock.now
        let answer = try await Task(priority: .userInitiated) { try await HTTP.data(URLRequest(url: url)) }.value
        XCTAssertEqual(String(decoding: answer, as: UTF8.self), "ok")
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(1))
        await filmEnded()
    }

    func testLiveTVLeavesWhatIsFetchedAheadGoing() async throws {
        let arrived = Locked(0)
        let server = try LocalServer { _ in
            arrived.mutate { $0 += 1 }
            return (200, [:], "ok")
        }
        defer { server.stop() }
        PlaybackActivity.began(.live)
        defer { PlaybackActivity.ended(.live) }
        let url = URL(string: "http://127.0.0.1:\(server.port)/ahead")!
        _ = Task(priority: .utility) { try await HTTP.data(URLRequest(url: url)) }
        for _ in 0..<20 where arrived.value == 0 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(arrived.value, 1, "held while live TV played")
    }

    @MainActor
    func testTheLibrarysCheckForChangesWaitsWhileAFilmPlays() async throws {
        let arrived = Locked(0)
        let server = try LocalServer { _ in
            arrived.mutate { $0 += 1 }
            return (200, [:], #"{"Items":[],"TotalRecordCount":0}"#)
        }
        defer { server.stop() }
        let account = EmbyAccount(serverURL: URL(string: "http://127.0.0.1:\(server.port)")!, serverName: "Mock", userId: "U1",
                                  userName: "tester", accessToken: "tok")
        let emby = EmbyClient(account: account, deviceId: "mac-test"), library = LibraryIndex()
        PlaybackActivity.began(.film)
        let checking = Task(priority: .background) { await library.prepare(emby, checkingChanges: true) }
        defer { checking.cancel() }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(arrived.value, 0, "the library's listing went out while a film played")
        PlaybackActivity.ended(.film)
        try await Task.sleep(for: PlaybackActivity.quietAfterFilm + .seconds(2))
        XCTAssertGreaterThan(arrived.value, 0, "the library's listing went out once the film ended")
    }

    @MainActor
    func testUpNextIsFetchedWhileAFilmPlays() async throws {
        let arrived = Locked(0)
        let server = try LocalServer { _ in
            arrived.mutate { $0 += 1 }
            return (200, [:], "ok")
        }
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/next")!
        var playing = allowed
        playing.playing = true
        let open = playing
        let shelf = Shelf<String, Data>(.init(lane: Lane(.light, atOnce: 4) { open }, lifetime: .seconds(60))) { _ in
            try await HTTP.data(URLRequest(url: url))
        }
        PlaybackActivity.began(.film)
        let warming = Task { await shelf.warm("next episode", for: Interest(at: .upNext, .likely)) }
        defer { warming.cancel() }
        for _ in 0..<20 where arrived.value == 0 { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(arrived.value, 1, "the next episode's plan waited for the film to end")
        await filmEnded()
    }

    func testAFetchedAheadRequestThatAStartWaitsForGoesAtOnce() async throws {
        let server = try LocalServer { _ in (200, [:], "ok") }
        defer { server.stop() }
        let start = Task { await HTTP.turns.whileStarting() }
        defer { start.cancel() }
        try await Task.sleep(for: .milliseconds(50))
        let url = URL(string: "http://127.0.0.1:\(server.port)/plan")!
        let ahead = Task(priority: .utility) { try await HTTP.data(URLRequest(url: url)) }
        try await Task.sleep(for: .milliseconds(100))
        let began = ContinuousClock.now
        let answer = try await Task(priority: .userInitiated) { try await ahead.value }.value
        XCTAssertEqual(String(decoding: answer, as: UTF8.self), "ok")
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(1))
    }

    func testARequestUnderWayThatSomethingThenWaitsForIsNotAskedTwice() async throws {
        let arrived = Locked(0)
        let server = try LocalServer(wait: 0.5) { _ in
            arrived.mutate { $0 += 1 }
            return (200, [:], "ok")
        }
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/page")!
        let ahead = Task(priority: .utility) { try await HTTP.data(URLRequest(url: url)) }
        for _ in 0..<20 where arrived.value == 0 { try await Task.sleep(for: .milliseconds(20)) }
        _ = try await Task(priority: .userInitiated) { try await ahead.value }.value
        XCTAssertEqual(arrived.value, 1)
    }

    @MainActor
    func testAPlanFetchedAheadThatATapTakesGoesAtOnceWhileTheStartHoldsTheTurns() async throws {
        let server = try LocalServer { _ in (200, [:], "ok") }
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/item")!
        let open = Conditions(network: .unmetered, playing: false, lowPower: false, thermal: .nominal,
                              memoryWarned: false, freeDisk: .init(bytes: 10_000_000_000, countsPurgeable: true))
        let shelf = Shelf<String, Data>(.init(lane: Lane(.light, atOnce: 4) { open }, lifetime: .seconds(60))) { _ in
            try await HTTP.data(URLRequest(url: url))
        }
        let start = Task { await HTTP.turns.whileStarting() }
        let giveUp = Task {
            try await Task.sleep(for: .seconds(3))
            start.cancel()
        }
        defer { giveUp.cancel(); start.cancel() }
        try await Task.sleep(for: .milliseconds(50))
        let warming = Task { await shelf.warm("film", for: Interest(at: .continueWatching, .likely)) }
        defer { warming.cancel() }
        try await Task.sleep(for: .milliseconds(200))
        let tapped = ContinuousClock.now
        let plan = try await shelf.take("film")
        XCTAssertEqual(String(decoding: plan, as: UTF8.self), "ok")
        XCTAssertLessThan(ContinuousClock.now - tapped, .seconds(1), "the tap waited on its own start's hold")
    }

    @MainActor
    func testAPlanAskedFromATaskOfItsOwnThatATapTakesGoesAtOnceWhileTheStartHoldsTheTurns() async throws {
        let server = try LocalServer { _ in (200, [:], "ok") }
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/item")!
        let open = Conditions(network: .unmetered, playing: false, lowPower: false, thermal: .nominal,
                              memoryWarned: false, freeDisk: .init(bytes: 10_000_000_000, countsPurgeable: true))
        let shelf = Shelf<String, Data>(.init(lane: Lane(.light, atOnce: 4) { open }, lifetime: .seconds(60))) { _ in
            let (answers, answer) = AsyncStream.makeStream(of: Data.self)
            Task {
                answer.yield((try? await HTTP.data(URLRequest(url: url))) ?? Data())
                answer.finish()
            }
            for await data in answers { return data }
            return Data()
        }
        let start = Task { await HTTP.turns.whileStarting() }
        let giveUp = Task {
            try await Task.sleep(for: .seconds(3))
            start.cancel()
        }
        defer { giveUp.cancel(); start.cancel() }
        try await Task.sleep(for: .milliseconds(50))
        let warming = Task { await shelf.warm("film", for: Interest(at: .continueWatching, .glance)) }
        defer { warming.cancel() }
        try await Task.sleep(for: .milliseconds(200))
        let tapped = ContinuousClock.now
        let plan = try await shelf.take("film")
        XCTAssertEqual(String(decoding: plan, as: UTF8.self), "ok")
        XCTAssertLessThan(ContinuousClock.now - tapped, .seconds(1), "the tap waited on its own start's hold")
    }

    func testLaterWorkGoesOneAtATimeAndNoneWhileAStartWaits() async throws {
        let turns = ServerTurns(atOnce: 4)
        let log = Locked<[String]>([]), later = Locked((now: 0, most: 0))
        let start = Task { await turns.whileStarting() }
        try await Task.sleep(for: .milliseconds(50))
        for n in 0..<3 {
            Task(priority: .background) {
                try await turns.taking(.later, at: "emby", owner: nil) { _ in
                    later.mutate { $0.now += 1; $0.most = max($0.most, $0.now) }
                    log.mutate { $0.append("later \(n)") }
                    try await Task.sleep(for: .milliseconds(40))
                    later.mutate { $0.now -= 1 }
                }
            }
        }
        for n in 0..<5 {
            Task(priority: .utility) {
                try await turns.taking(.ahead, at: "emby", owner: nil) { _ in
                    log.mutate { $0.append("ahead \(n)") }
                    try await Task.sleep(for: .milliseconds(40))
                    log.mutate { $0.append("ahead \(n) done") }
                }
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(log.value, [], "a turn while a start waited")
        start.cancel()
        for _ in 0..<100 where log.value.count < 13 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(log.value.count, 13)
        XCTAssertEqual(later.value.most, 1)
    }

    private var allowed: Conditions {
        Conditions(network: .unmetered, playing: false, lowPower: false, thermal: .nominal,
                   memoryWarned: false, freeDisk: .init(bytes: 10_000_000_000, countsPurgeable: true))
    }

    @MainActor
    func testALikelyCardsPlanWaitsForAStartLikeEverythingFetchedAhead() async throws {
        let arrived = Locked(0)
        let server = try LocalServer { _ in
            arrived.mutate { $0 += 1 }
            return (200, [:], "ok")
        }
        defer { server.stop() }
        let url = URL(string: "http://127.0.0.1:\(server.port)/item")!
        let open = allowed
        let shelf = Shelf<String, Data>(.init(lane: Lane(.light, atOnce: 4) { open }, lifetime: .seconds(60))) { _ in
            try await HTTP.data(URLRequest(url: url))
        }
        let start = Task { await HTTP.turns.whileStarting() }
        defer { start.cancel() }
        try await Task.sleep(for: .milliseconds(50))
        let likely = Task { await shelf.warm("card", for: Interest(at: .continueWatching, .likely)) }
        defer { likely.cancel() }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(arrived.value, 0, "a likely card's plan asked while a start waited")
    }

    func testALikelyCardsRequestGoesFirstOnceTheStartPlays() async throws {
        let turns = ServerTurns(atOnce: 1)
        let log = Locked<[String]>([])
        let start = Task { await turns.whileStarting() }
        try await Task.sleep(for: .milliseconds(50))
        let likely = ServerTurns.Fetch()
        for (name, fetch) in [("glance 1", nil), ("glance 2", nil), ("likely", likely)] as [(String, ServerTurns.Fetch?)] {
            Task(priority: .utility) {
                try await ServerTurns.$fetch.withValue(fetch) {
                    try await turns.taking(.current, at: "emby", owner: nil) { _ in
                        log.mutate { $0.append(name) }
                        try await Task.sleep(for: .milliseconds(20))
                    }
                }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        likely.raise(to: .soon)
        start.cancel()
        for _ in 0..<100 where log.value.count < 3 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(log.value, ["likely", "glance 1", "glance 2"])
    }

    func testAPlanAskedAheadTakesItsTurnForItsPlaybackInfoToo() async throws {
        let arrived = Locked(0)
        let server = try LocalServer { _ in
            arrived.mutate { $0 += 1 }
            return (200, [:], "ok")
        }
        defer { server.stop() }
        var info = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/Items/m1/PlaybackInfo")!)
        info.httpMethod = "POST"
        let start = Task { await HTTP.turns.whileStarting() }
        try await Task.sleep(for: .milliseconds(50))
        let done = Locked(false)
        Task(priority: .utility) {
            _ = try? await HTTP.data(info)
            done.mutate { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(arrived.value, 0, "a PlaybackInfo fetched ahead went while a start waited")
        start.cancel()
        for _ in 0..<50 where !done.value { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(arrived.value, 1, "asked once the start played")
    }

    @MainActor
    func testALikelyTicketIsNotHeldBehindGlancedWorkFillingTheLane() async throws {
        let open = allowed
        let lane = Lane(.light, atOnce: 2) { open }
        let (held, release) = AsyncStream.makeStream(of: Void.self)
        defer { release.finish() }
        for _ in 0..<2 {
            Task { await lane.whenAllowed(for: Interest(at: .posterRow, .glance)) { for await _ in held {} } }
        }
        try await Task.sleep(for: .milliseconds(100))
        let ran = Locked(false)
        let likely = Task { await lane.whenAllowed(for: Interest(at: .continueWatching, .likely)) { ran.mutate { $0 = true } } }
        defer { likely.cancel() }
        for _ in 0..<25 where !ran.value { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(ran.value, "a likely card's plan waited for glanced pages")
    }

    @MainActor
    func testACardRestedOnWaitsForALikelyCardsWorkInALaneOfOne() async throws {
        let open = allowed
        let lane = Lane(.connection, atOnce: 1) { open }
        let (held, release) = AsyncStream.makeStream(of: Void.self)
        defer { release.finish() }
        Task { await lane.whenAllowed(for: Interest(at: .homeForecast, .likely)) { for await _ in held {} } }
        try await Task.sleep(for: .milliseconds(100))
        let ran = Locked(false)
        let restedOn = Task { await lane.whenAllowed(for: Interest(at: .continueWatching, .next)) { ran.mutate { $0 = true } } }
        defer { restedOn.cancel() }
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(ran.value, "two cards' film reads at once in a lane of one")
    }

    func testBackgroundWorkKeepsGoingOneAtATimeWhileFetchedAheadWorkFillsTheTurns() async throws {
        let turns = ServerTurns(atOnce: 2)
        let pages = Locked((now: 0, most: 0, done: 0))
        let (held, release) = AsyncStream.makeStream(of: Void.self)
        defer { release.finish() }
        for _ in 0..<3 {
            Task(priority: .utility) { try await turns.taking(.ahead, at: "emby", owner: nil) { _ in for await _ in held {} } }
        }
        try await Task.sleep(for: .milliseconds(50))
        for _ in 0..<3 {
            Task(priority: .background) {
                try await turns.taking(.later, at: "emby", owner: nil) { _ in
                    pages.mutate { $0.now += 1; $0.most = max($0.most, $0.now) }
                    try await Task.sleep(for: .milliseconds(20))
                    pages.mutate { $0.now -= 1; $0.done += 1 }
                }
            }
        }
        for _ in 0..<25 where pages.value.done < 3 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(pages.value.done, 3, "the library's pages waited for every fetch ahead")
        XCTAssertEqual(pages.value.most, 1)
    }

    func testAWaitingLibraryLoadGoesAtOnceWhenSearchWantsIt() async throws {
        let turns = ServerTurns(atOnce: 4)
        let start = Task { await turns.whileStarting() }
        defer { start.cancel() }
        try await Task.sleep(for: .milliseconds(50))
        let load = ServerTurns.Fetch(), pages = Locked(0)
        for _ in 0..<3 {
            Task(priority: .background) {
                try await ServerTurns.$fetch.withValue(load) {
                    try await turns.taking(.later, at: "emby", owner: nil) { _ in pages.mutate { $0 += 1 } }
                }
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(pages.value, 0)
        load.raise(to: .now)
        for _ in 0..<25 where pages.value < 3 { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(pages.value, 3, "Search waited for the start")
    }

    @MainActor
    func testASignedOutAccountsWaitingRequestNeverGoesOut() async throws {
        let arrived = Locked(0)
        let server = try LocalServer { _ in
            arrived.mutate { $0 += 1 }
            return (200, [:], "ok")
        }
        defer { server.stop() }
        let account = EmbyAccount(serverURL: URL(string: "http://127.0.0.1:\(server.port)")!, serverName: "Mock", userId: "U1",
                                  userName: "tester", accessToken: "signed-out")
        let scope = AccountScope(client: EmbyClient(account: account, deviceId: "device"), readsSaved: false)
        var noted = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/emby/DisplayPreferences/zapline-started")!)
        noted.setValue("signed-out", forHTTPHeaderField: "X-Emby-Token")
        let start = Task { await HTTP.turns.whileStarting() }
        try await Task.sleep(for: .milliseconds(50))
        let asked = noted
        Task(priority: .utility) { _ = try? await HTTP.data(asked) }
        try await Task.sleep(for: .milliseconds(100))
        scope.close()
        start.cancel()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(arrived.value, 0, "the old account's request went out after sign-out")
    }

    func testEachServerHasItsOwnTurns() async throws {
        let turns = ServerTurns(atOnce: 1)
        let held = AsyncStream<Void>.makeStream()
        let emby = Task { try await turns.taking(.ahead, at: "emby", owner: nil) { _ in for await _ in held.stream {} } }
        defer { held.continuation.finish() }
        try await Task.sleep(for: .milliseconds(50))
        let began = ContinuousClock.now
        try await turns.taking(.ahead, at: "provider", owner: nil) { _ in }
        XCTAssertLessThan(ContinuousClock.now - began, .milliseconds(200))
        held.continuation.finish()
        try await emby.value
    }
}

extension XCTestCase {
    func filmEnded() async {
        PlaybackActivity.ended(.film)
        try? await Task.sleep(for: PlaybackActivity.quietAfterFilm + .milliseconds(200))
    }
}

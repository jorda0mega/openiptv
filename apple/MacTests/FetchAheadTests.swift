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

    func testLaterWorkGoesOneAtATimeOnceNothingFetchedAheadIsUnderWay() async throws {
        let turns = ServerTurns(atOnce: 4)
        let log = Locked<[String]>([]), later = Locked((now: 0, most: 0))
        let start = Task { await turns.whileStarting() }
        try await Task.sleep(for: .milliseconds(50))
        for n in 0..<3 {
            Task(priority: .background) {
                try await turns.taking(.later, at: "emby") { _ in
                    later.mutate { $0.now += 1; $0.most = max($0.most, $0.now) }
                    log.mutate { $0.append("later \(n)") }
                    try await Task.sleep(for: .milliseconds(40))
                    later.mutate { $0.now -= 1 }
                }
            }
        }
        for n in 0..<5 {
            Task(priority: .utility) {
                try await turns.taking(.ahead, at: "emby") { _ in
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
        XCTAssertEqual(log.value.prefix(10).allSatisfy { $0.hasPrefix("ahead") }, true, log.value.joined(separator: ", "))
        XCTAssertEqual(log.value.count, 13)
        XCTAssertEqual(later.value.most, 1)
    }

    func testEachServerHasItsOwnTurns() async throws {
        let turns = ServerTurns(atOnce: 1)
        let held = AsyncStream<Void>.makeStream()
        let emby = Task { try await turns.taking(.ahead, at: "emby") { _ in for await _ in held.stream {} } }
        defer { held.continuation.finish() }
        try await Task.sleep(for: .milliseconds(50))
        let began = ContinuousClock.now
        try await turns.taking(.ahead, at: "provider") { _ in }
        XCTAssertLessThan(ContinuousClock.now - began, .milliseconds(200))
        held.continuation.finish()
        try await emby.value
    }
}

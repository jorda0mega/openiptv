import XCTest
@testable import OpenIPTV

/// A title's plan when it has several copies, on a server on this Mac that
/// answers each copy's item and PlaybackInfo after its own wait.
final class PlanCopiesTests: XCTestCase {
    private static let ids = ["copy-hd-0001", "copy-4k-0002"]

    /// `info`: each copy's PlaybackInfo wait, by its place in `ids`;
    /// `item`: each item's wait; `width`: the picture's width in each;
    /// `itemSource`: the protocol of the source in each copy's item, as
    /// Emby lists it in an item's full record (nil: the item lists none);
    /// `failing`: answered 500.
    private func server(info: [Double], item: Double = 0, width: [Int] = [1280, 1920], itemSource: String? = nil,
                        failing: @escaping @Sendable (String) -> Bool = { _ in false }) throws -> (LocalServer, EmbyClient) {
        let ids = Self.ids
        func copy(_ target: String) -> Int? { ids.firstIndex { target.contains("/\($0)") } }
        func source(_ n: Int, _ protocolName: String) -> String {
            """
            {"Id": "ms\(n)", "Protocol": "\(protocolName)", "Container": "mkv", "Path": "http://elsewhere.invalid/film.mkv",
             "SupportsDirectPlay": true, "SupportsDirectStream": true,
             "MediaStreams": [{"Type": "Video", "Width": \(width[n])}, {"Type": "Audio", "Index": 1, "Language": "eng"}]}
            """
        }
        let server = try LocalServer(pause: { target in
            guard let n = copy(target) else { return 0 }
            return target.contains("/PlaybackInfo") ? info[n] : item
        }, answer: { target in
            guard let n = copy(target), !failing(target) else { return (500, [:], "{}") }
            if target.contains("/PlaybackInfo") {
                return (200, ["Content-Type": "application/json"],
                        "{\"PlaySessionId\": \"ps\(n)\", \"MediaSources\": [\(source(n, itemSource ?? "File"))]}")
            }
            return (200, ["Content-Type": "application/json"], """
                {"Id": "\(ids[n])", "Name": "Film", "Type": "Movie", "RunTimeTicks": 72000000000,
                 "ProductionLocations": ["United States of America"],
                 "UserData": {"PlaybackPositionTicks": \((n + 1) * 300_000_000), "LastPlayedDate": "2026-10-0\(n + 1)T00:00:00Z"}
                 \(itemSource.map { ", \"MediaSources\": [\(source(n, $0))]" } ?? "")}
                """)
        })
        let account = EmbyAccount(serverURL: URL(string: "http://127.0.0.1:\(server.port)")!, serverName: "test", userId: "U1",
                                  userName: "viewer", accessToken: "tok")
        return (server, EmbyClient(account: account, deviceId: "mac-test"))
    }

    func testThePlanSaysEachCopysRequestsApart() async throws {
        let (server, client) = try server(info: [0, 0.6])
        defer { server.stop() }
        let clock = PlanClock(copies: Self.ids)
        _ = try await PlanClock.$current.withValue(clock) {
            try await client.playback(versions: Self.ids, kind: "Movie", maxWidth: nil)
        }
        let sent = clock.sent
        XCTAssertEqual(Set(sent.compactMap { request in request.copy.map { "\($0) \(request.info ? "info" : "item")" } }),
                       ["1 item", "1 info", "2 item", "2 info"])
        let slow = try XCTUnwrap(sent.first { $0.copy == 2 && $0.info }?.times)
        XCTAssertGreaterThan(slow.wait, 0.5, "the server's wait for the slow copy's PlaybackInfo")
        let quick = try XCTUnwrap(sent.first { $0.copy == 1 && $0.info }?.times)
        XCTAssertLessThan(quick.wait, 0.3)
        let readout = clock.readout(tap: clock.asked)
        XCTAssertFalse(Self.ids.contains(where: readout.contains) || readout.contains("127.0.0.1"), "an id or an address in the readout")
    }

    func testACopyThatFitsPlaysWithoutWaitingForASlowOne() async throws {
        let (server, client) = try server(info: [0, 4], width: [1920, 1920])
        defer { server.stop() }
        let began = ContinuousClock.now
        let playback = try await client.playback(versions: Self.ids, kind: "Movie", maxWidth: 1920)
        let took = ContinuousClock.now - began
        XCTAssertEqual(playback.itemId, Self.ids[0])
        XCTAssertLessThan(took, .seconds(2), "the plan waited \(took) for the slow copy")
        XCTAssertEqual(playback.copyIds, Self.ids, "the slow copy is still one of the title's copies")
    }

    func testASharperCopyInTimeIsStillTheOnePlayed() async throws {
        let (server, client) = try server(info: [0, 0.5], width: [1280, 1920])
        defer { server.stop() }
        let playback = try await client.playback(versions: Self.ids, kind: "Movie", maxWidth: 1920)
        XCTAssertEqual(playback.itemId, Self.ids[1])
    }

    func testTheCopyWatchedLastSetsTheStartEvenWhenItsPlanIsLate() async throws {
        let (server, client) = try server(info: [0, 4], width: [1920, 1920])
        defer { server.stop() }
        let playback = try await client.playback(versions: Self.ids, kind: "Movie", maxWidth: 1920)
        XCTAssertEqual(playback.startSeconds, 60, "the second copy, watched last, was left at 60 s")
    }

    func testAFilmStartsFromItsItemsSourceAndReportsWithItsLatePlaySession() async throws {
        let (server, client) = try server(info: [3, 3], itemSource: "File")
        defer { server.stop() }
        let began = ContinuousClock.now
        let playback = try await client.playback(versions: [Self.ids[0]], kind: "Movie", maxWidth: 1920)
        let took = ContinuousClock.now - began
        XCTAssertLessThan(took, .seconds(1), "the start waited \(took) for PlaybackInfo")
        XCTAssertEqual(playback.mediaSourceId, "ms0")
        let query = URLComponents(url: playback.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "MediaSourceId" }?.value, "ms0")
        XCTAssertTrue(playback.listed, "its tracks came from the item's list")
        let session = await playback.session(within: .seconds(10))
        XCTAssertEqual(session, "ps0", "the reports' play session, once PlaybackInfo answered")
    }

    func testCopiesWhoseItemsTellTheirSourcesPlayWithoutWaitingForPlaybackInfo() async throws {
        let (server, client) = try server(info: [3, 3], width: [1280, 1920], itemSource: "File")
        defer { server.stop() }
        let began = ContinuousClock.now
        let playback = try await client.playback(versions: Self.ids, kind: "Movie", maxWidth: 1920)
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(1))
        XCTAssertEqual(playback.itemId, Self.ids[1], "the sharper copy")
    }

    func testACopyWhoseItemOrPlanFailsLeavesTheOtherToPlay() async throws {
        for failing in ["/Items/\(Self.ids[1])", "/\(Self.ids[1])/PlaybackInfo"] {
            let (server, client) = try server(info: [0, 0], width: [1920, 1920], failing: { $0.contains(failing) })
            defer { server.stop() }
            let plan = Task { try await client.playback(versions: Self.ids, kind: "Movie", maxWidth: 1920) }
            let late = Task {
                try await Task.sleep(for: .seconds(5))
                plan.cancel()
            }
            let playback = try await plan.value
            late.cancel()
            XCTAssertEqual(playback.itemId, Self.ids[0], "with \(failing) failing")
        }
    }

    func testAPlaySessionIsAskedAgainWhenTheLatePlaybackInfoFails() async throws {
        let asked = Locked(0)
        let (server, client) = try server(info: [0.3, 0.3], itemSource: "File", failing: { target in
            guard target.contains("/PlaybackInfo") else { return false }
            var first = false
            asked.mutate { $0 += 1; first = $0 == 1 }
            return first
        })
        defer { server.stop() }
        let playback = try await client.playback(versions: [Self.ids[0]], kind: "Movie", maxWidth: 1920)
        let session = await playback.session()
        XCTAssertEqual(session, "ps0", "the reports carried no play session")
    }

    func testAPlaySessionIsAskedAgainWhenPlaybackInfoFailedBeforeTheItemCame() async throws {
        let asked = Locked(0)
        let (server, client) = try server(info: [0], item: 0.5, itemSource: "File", failing: { target in
            guard target.contains("/PlaybackInfo") else { return false }
            var first = false
            asked.mutate { $0 += 1; first = $0 == 1 }
            return first
        })
        defer { server.stop() }
        let playback = try await client.playback(versions: [Self.ids[0]], kind: "Movie", maxWidth: 1920)
        XCTAssertEqual(playback.mediaSourceId, "ms0", "it started from its item's source")
        let session = await playback.session(within: .seconds(10))
        XCTAssertEqual(session, "ps0", "the reports carried no play session")
    }

    /// Reports go one after another: one waiting for a PlaybackInfo the
    /// server held (about 40 s) held Stopped back too.
    func testAReportWaitsForALatePlaySessionAtMostTwoSeconds() async throws {
        let (server, client) = try server(info: [6, 6], itemSource: "File")
        defer { server.stop() }
        let playback = try await client.playback(versions: [Self.ids[0]], kind: "Movie", maxWidth: 1920)
        let began = ContinuousClock.now
        let session = await playback.session()
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(3), "a report waited for the play session the server held")
        XCTAssertNil(session)
    }

    private func playSession(_ address: URL) -> String? {
        URLComponents(url: address, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "PlaySessionId" }?.value
    }

    func testAConversionOpenedOnceTheLatePlaySessionCameCarriesIt() async throws {
        let (server, client) = try server(info: [0.5, 0.5], itemSource: "File")
        defer { server.stop() }
        let playback = try await client.playback(versions: [Self.ids[0]], kind: "Movie", maxWidth: 1920)
        let converted = try XCTUnwrap(playback.fallbacks.last)
        let opened = await playback.opening(converted)
        XCTAssertEqual(playSession(opened), "ps0")
    }

    /// The server stops the conversion its Stopped names.
    func testAConversionOpenedBeforeTheLatePlaySessionCameCarriesTheSameAsItsReports() async throws {
        let (server, client) = try server(info: [4, 4], itemSource: "File")
        defer { server.stop() }
        let playback = try await client.playback(versions: [Self.ids[0]], kind: "Movie", maxWidth: 1920)
        let converted = try XCTUnwrap(playback.fallbacks.last)
        let began = ContinuousClock.now
        let opened = await playback.opening(converted)
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(3), "the conversion waited for the play session the server held")
        let stopped = await playback.session(within: .seconds(10))
        XCTAssertEqual(playSession(opened), stopped, "Stopped named another play session than the conversion")
    }

    func testARemoteFileStillWaitsForPlaybackInfo() async throws {
        let (server, client) = try server(info: [1.5, 1.5], itemSource: "Http")
        defer { server.stop() }
        let began = ContinuousClock.now
        let playback = try await client.playback(versions: [Self.ids[0]], kind: "Movie", maxWidth: 1920)
        XCTAssertGreaterThan(ContinuousClock.now - began, .seconds(1.4))
        XCTAssertEqual(playback.playSessionId, "ps0")
    }
}

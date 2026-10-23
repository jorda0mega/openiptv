import XCTest
@testable import OpenIPTV

/// A title's plan when it has several copies, on a server on this Mac that
/// answers each copy's item and PlaybackInfo after its own wait.
final class PlanCopiesTests: XCTestCase {
    private static let ids = ["copy-hd-0001", "copy-4k-0002"]

    /// `info`: each copy's PlaybackInfo wait, by its place in `ids`;
    /// `width`: the picture's width in each.
    private func server(info: [Double], width: [Int] = [1280, 1920]) throws -> (LocalServer, EmbyClient) {
        let ids = Self.ids
        func copy(_ target: String) -> Int? { ids.firstIndex { target.contains("/\($0)") } }
        let server = try LocalServer(pause: { target in
            guard target.contains("/PlaybackInfo"), let n = copy(target) else { return 0 }
            return info[n]
        }, answer: { target in
            guard let n = copy(target) else { return (404, [:], "{}") }
            if target.contains("/PlaybackInfo") {
                return (200, ["Content-Type": "application/json"], """
                    {"PlaySessionId": "ps\(n)", "MediaSources": [{"Id": "ms\(n)", "Protocol": "File", "Container": "mkv",
                     "SupportsDirectPlay": true, "SupportsDirectStream": true,
                     "MediaStreams": [{"Type": "Video", "Width": \(width[n])}, {"Type": "Audio", "Index": 1, "Language": "eng"}]}]}
                    """)
            }
            return (200, ["Content-Type": "application/json"], """
                {"Id": "\(ids[n])", "Name": "Film", "Type": "Movie", "RunTimeTicks": 72000000000,
                 "ProductionLocations": ["United States of America"],
                 "UserData": {"PlaybackPositionTicks": \((n + 1) * 300_000_000), "LastPlayedDate": "2026-10-0\(n + 1)T00:00:00Z"}}
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
}

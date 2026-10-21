import XCTest
@testable import OpenIPTV

final class IPTVLoginTests: XCTestCase {
    private func server() throws -> URL {
        guard let raw = ProcessInfo.processInfo.environment["DEBUG_EMBY"],
              let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let address = (json["serverURL"] as? String).flatMap(URL.init(string:)) else {
            throw XCTSkip(#"needs the test server: DEBUG_EMBY='{"serverURL": "http://127.0.0.1:<port>"}' swift test"#)
        }
        return address
    }

    private func control(_ server: URL, _ path: String, _ settings: [String: String] = [:]) async throws -> Data {
        let url = server.appending(path: path).appending(queryItems: settings.map { .init(name: $0.key, value: $0.value) })
        return try await URLSession.shared.data(from: url).0
    }

    private func object(_ data: Data) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func madeUpSource(_ server: URL) async throws -> IPTVSource {
        _ = try await control(server, "mock/set", ["reset": "1"])
        let made = object(try await control(server, "mock/iptv_login", ["fresh": "1"]))
        XCTAssertEqual(made["set"] as? Bool, true, "the test server made up no login")
        return try JSONDecoder().decode(IPTVSource.self, from: try await control(server, "mock/iptv_source"))
    }

    private func loginInAddresses(_ server: URL, since: Double) async throws -> (username: Int, password: Int, requests: Int) {
        let found = object(try await control(server, "mock/iptv_leaks", ["since": String(since)]))
        return (found["address_username"] as? Int ?? -1, found["address_password"] as? Int ?? -1, found["requests"] as? Int ?? -1)
    }

    private func mark(_ server: URL) async throws -> Double {
        object(try await control(server, "mock/mark"))["t"] as? Double ?? 0
    }

    func testXtreamKeepsTheLoginOutOfEveryAPIAddress() async throws {
        let server = try server()
        let source = try await madeUpSource(server)
        _ = try await control(server, "mock/set", ["xtream_post_only": "1"])
        let provider = XtreamProvider(source: source)
        let since = try await mark(server)
        let lineup = try await provider.load()
        let channel = try XCTUnwrap(lineup.channels.first { $0.archiveDays != nil }, "no channel kept for catch-up")
        _ = await provider.schedule(for: channel)
        _ = await provider.shortEPG(for: channel)
        _ = try await provider.catchup(channel, programme: Programme(start: 1_792_000_000, stop: 1_792_003_600, title: "Recorded"))
        let stopped = Task { await provider.shortEPG(for: channel) }
        stopped.cancel()
        _ = await stopped.value
        let guide = GuideStore()
        await guide.refresh(from: lineup.guides, keep: Set(lineup.channels.compactMap(\.epgId)))
        let guideRead = await guide.state
        await guide.clear()
        if case let .ready(programmes, _) = guideRead {
            XCTAssertGreaterThan(programmes, 0, "the guide had no programmes")
        } else {
            XCTFail("the guide wasn't read: \(guideRead)")
        }
        let found = try await loginInAddresses(server, since: since)
        XCTAssertGreaterThanOrEqual(found.requests, 7, "not every API request reached the test server")
        XCTAssertEqual(found.username, 0, "the username was in \(found.username) API addresses")
        XCTAssertEqual(found.password, 0, "the password was in \(found.password) API addresses")
    }

    func testAPlaylistsLoginStaysOutOfItsAddressAndItsGuides() async throws {
        let server = try server()
        let made = try await madeUpSource(server)
        guard case let .xtream(_, username, password) = made.kind else { return XCTFail("not an Xtream login") }
        let playlist = server.appending(path: "get.php").appending(queryItems: [.init(name: "username", value: username),
                                                                                .init(name: "password", value: password)])
        let provider = M3UProvider(source: IPTVSource(name: "Playlist", kind: .m3u(playlist: playlist, guide: nil)))
        _ = try await control(server, "mock/set", ["xtream_post_only": "1"])
        let since = try await mark(server)
        let lineup = try await provider.load()
        let guide = GuideStore()
        await guide.refresh(from: lineup.guides, keep: Set(lineup.channels.compactMap(\.epgId)))
        let guideRead = await guide.state
        await guide.clear()
        if case let .ready(programmes, _) = guideRead {
            XCTAssertGreaterThan(programmes, 0, "the guide had no programmes")
        } else {
            XCTFail("the guide wasn't read: \(guideRead)")
        }
        let found = try await loginInAddresses(server, since: since)
        XCTAssertEqual(found.requests, 2, "the playlist and its guide weren't both asked for")
        XCTAssertEqual(found.username, 0, "the username was in \(found.username) addresses")
        XCTAssertEqual(found.password, 0, "the password was in \(found.password) addresses")
    }

    func testTheHLSKeyCountReadsOnlyEmbyStreams() async throws {
        let xtream = try XCTUnwrap(URL(string: "http://127.0.0.1:1/live/someone/secret/1.m3u8"))
        let counted = await PlaylistKeys.count(xtream, headers: [])
        XCTAssertEqual(counted, "not an Emby stream", "an IPTV stream's address, login and all, was asked for")
    }

    func testAFormCarriesEveryCharacterOfALogin() throws {
        let url = try XCTUnwrap(URL(string: "http://panel.invalid/player_api.php"))
        let request = HTTP.form(url, [.init(name: "username", value: "a b"), .init(name: "password", value: "p+q&r=s/é~")])
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url, url)
        XCTAssertEqual(request.httpBody.map { String(decoding: $0, as: UTF8.self) }, "username=a%20b&password=p%2Bq%26r%3Ds%2F%C3%A9~")
    }

    func testOnlyAnAddressWithALoginBecomesAForm() throws {
        let guide = try XCTUnwrap(URL(string: "http://panel.invalid/xmltv.php?username=someone&password=secret&next_days=1"))
        let moved = HTTP.loginInForm(guide)
        XCTAssertEqual(moved.url?.absoluteString, "http://panel.invalid/xmltv.php")
        XCTAssertEqual(moved.httpBody.map { String(decoding: $0, as: UTF8.self) }, "username=someone&password=secret&next_days=1")
        let plain = try XCTUnwrap(URL(string: "http://lists.invalid/channels.m3u?region=uk"))
        XCTAssertEqual(HTTP.loginInForm(plain).url, plain)
        XCTAssertEqual(HTTP.loginInForm(plain).httpMethod, "GET")
    }
}

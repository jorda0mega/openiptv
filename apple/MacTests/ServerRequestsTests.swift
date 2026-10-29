import XCTest
@testable import OpenIPTV

final class ServerRequestsTests: XCTestCase {
    private func server() throws -> URL {
        guard let raw = ProcessInfo.processInfo.environment["DEBUG_EMBY"],
              let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let address = (json["serverURL"] as? String).flatMap(URL.init(string:)) else {
            throw XCTSkip(#"needs the test server: DEBUG_EMBY='{"serverURL": "http://127.0.0.1:<port>"}' swift test"#)
        }
        return address
    }

    private func get(_ url: URL, range: String? = nil, token: String? = nil) async throws -> (Data, Int) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        if let token { request.setValue(token, forHTTPHeaderField: "X-Emby-Token") }
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    private func listed(_ server: URL, _ path: String, since: Double, _ field: String = "items") async throws -> [String] {
        let url = server.appending(path: path).appending(queryItems: [.init(name: "since", value: String(since))])
        let (data, _) = try await get(url)
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: [String]])?[field] ?? []
    }

    private func mark(_ server: URL) async throws -> Double {
        let (data, _) = try await get(server.appending(path: "mock/mark"))
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Double])?["t"] ?? 0
    }

    private func configure(_ server: URL, _ settings: [String: String]) async throws {
        _ = try await get(server.appending(path: "mock/set").appending(queryItems: settings.map { .init(name: $0.key, value: $0.value) }))
    }

    func testCopiesLeaveTheSoundItsConnections() async throws {
        let server = try server()
        try await configure(server, ["reference_delay": "4"])
        let film = "t" + UUID().uuidString.prefix(8)
        let since = try await mark(server)
        let copies = (3...4).map { index in
            Task {
                await ServerSubtitles.local(ServerSubtitle(address: server.appending(path: "emby/Videos/\(film)/ms-\(film)/Subtitles/\(index)/Stream.srt"),
                                                           token: "tok", kind: .inFile, version: film))
            }
        }
        var looked = 0
        while try await listed(server, "mock/subtitle_requests", since: since).count < 2, looked < 50 {
            looked += 1
            try await Task.sleep(for: .milliseconds(100))
        }
        let began = ContinuousClock.now
        var sound = URLRequest(url: server.appending(path: "emby/Audio/\(film)/stream.mp3").appending(queryItems: [.init(name: "StartTimeTicks", value: "0")]))
        sound.setValue("tok", forHTTPHeaderField: "X-Emby-Token")
        _ = try await HTTP.patient.data(for: sound)
        let waited = ContinuousClock.now - began
        try await configure(server, ["reset": "1"])
        for copy in copies { _ = await copy.value }
        XCTAssertLessThan(waited, .seconds(3), "a stretch of sound waited \(waited) behind the copies")
    }

    func testSignOutLeavesNoBytesForTheNextAccount() async throws {
        let server = try server()
        let film = "r" + UUID().uuidString.prefix(8)
        let address = server.appending(path: "emby/Videos/\(film)/stream.mkv").appending(queryItems: [.init(name: "Static", value: "true")])
        let first = try XCTUnwrap(StreamRelay.shared.localURL(for: address, headers: ["X-Emby-Token: tok"], film: film))
        let (bytes, status) = try await get(first, range: "bytes=0-65535")
        XCTAssertEqual(status, 206)
        XCTAssertEqual(bytes.count, 65536)
        StreamRelay.shared.forgetAccount()
        let since = try await mark(server)
        let again = try XCTUnwrap(StreamRelay.shared.localURL(for: address, headers: ["X-Emby-Token: tok"], film: film))
        _ = try await get(again, range: "bytes=0-65535")
        let asked = try await listed(server, "mock/video_requests", since: since)
        XCTAssertTrue(asked.contains(film), "the next account was given the bytes fetched for the last")
    }
}

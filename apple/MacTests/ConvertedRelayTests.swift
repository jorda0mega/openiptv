import Network
import XCTest
@testable import OpenIPTV

/// A converted version is read through the relay: the player is given the
/// relay's addresses and no key, and the relay alone asks the server.
final class ConvertedRelayTests: XCTestCase {
    private let key = ["X-Emby-Token: test-key"]

    private func list(_ addresses: [String], at variant: URL) throws -> ConvertedPlaylist {
        let lines = ["#EXTM3U", "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-TARGETDURATION:3", "#EXT-X-MEDIA-SEQUENCE:0"]
            + addresses.flatMap { ["#EXTINF:3.000000, nodesc", $0] } + ["#EXT-X-ENDLIST"]
        let list: ConvertedPlaylist? = if case let .listed(list) = ConvertedPlaylist.listing(lines, at: variant) { list } else { nil }
        return try XCTUnwrap(list, "not listed")
    }

    /// The segments the player reads, as it reads them from the list it opens.
    private func segments(_ opened: URL) async throws -> [URL] {
        let (data, _) = try await URLSession.shared.data(from: opened)
        return String(decoding: data, as: UTF8.self).split(separator: "\n").filter { !$0.hasPrefix("#") }
            .compactMap { URL(string: String($0), relativeTo: opened)?.absoluteURL }
    }

    private func get(_ url: URL) async throws -> (status: Int, body: String) {
        let (data, response) = try await URLSession.shared.data(from: url)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    func testThePlayerReadsOnlyTheRelaysAddresses() async throws {
        let master = URL(string: "https://emby.example/emby/Videos/m1/master.m3u8?MediaSourceId=m1")!
        let list = try list((0..<200).map { "hls1/main/\($0).ts?PlaySessionId=p1" }, at: master)
        for (second, old) in [(301.5, false), (301.5, true)] {
            let opened = try XCTUnwrap(FilmStream.converted(master, list, at: second, headers: key, old: old), "the relay isn't running")
            let read = try await segments(opened.address)
            XCTAssertEqual(read.count, old ? 200 : 100)
            let away = read.filter { !HTTP.sameServer($0, opened.address) }
            XCTAssertEqual(away.count, 0, "segments read from elsewhere than the relay\(old ? ", the old way" : ""): \(Set(away.compactMap { $0.host() }))")
        }
    }

    func testThePlayerIsGivenNoKey() throws {
        let master = URL(string: "https://emby.example/emby/Videos/m1/master.m3u8?MediaSourceId=m1")!
        let list = try list((0..<200).map { "hls1/main/\($0).ts" }, at: master)
        for old in [false, true] {
            let opened = try XCTUnwrap(FilmStream.converted(master, list, at: 301.5, headers: key, old: old) { _, _, _ in URL(string: "http://127.0.0.1:8/list.m3u8") })
            XCTAssertFalse(opened.headers.contains { $0.contains("test-key") }, "the player sends the key\(old ? ", the old way" : "")")
        }
    }

    /// Asked again on the server, a segment keeps the key; elsewhere, it
    /// goes there without it, in its header or its address.
    func testTheRelayAsksForASegmentWithTheKeyOnlyOnTheGivenServer() async throws {
        let server = try Upstream { path, port in
            switch path {
            case "/hls1/main/1.ts": (302, ["Location": "/again/1.ts"], "")
            case "/hls1/main/2.ts": (302, ["Location": "http://localhost:\(port)/cdn/2.ts?api_key=test-key&b=1"], "")
            default: (200, [:], "bytes of \(path)")
            }
        }
        defer { server.stop() }
        let given = URL(string: "http://127.0.0.1:\(server.port)/emby/Videos/m1/master.m3u8?MediaSourceId=m1")!
        let list = try list((0..<3).map { "/hls1/main/\($0).ts" }, at: given)
        let opened = try XCTUnwrap(FilmStream.converted(given, list, at: 0, headers: key), "the relay isn't running")
        let read = try await segments(opened.address)
        XCTAssertEqual(read.count, 3)
        var bodies: [String] = []
        for segment in read { bodies.append(try await get(segment).body) }
        XCTAssertEqual(bodies, ["bytes of /hls1/main/0.ts", "bytes of /again/1.ts", "bytes of /cdn/2.ts"])
        let asked = server.asked.value
        XCTAssertEqual(asked.map(\.path), ["/hls1/main/0.ts", "/hls1/main/1.ts", "/again/1.ts", "/hls1/main/2.ts", "/cdn/2.ts"])
        for request in asked {
            let elsewhere = request.host.hasPrefix("localhost")
            XCTAssertEqual(request.key, elsewhere ? nil : "test-key", "\(request.path) as \(elsewhere ? "another server" : "the server")")
            XCTAssertFalse(request.query.contains("test-key"), "\(request.path): the key in its address")
        }
    }

    func testASegmentElsewhereIsRefused() async throws {
        let server = try Upstream { path, _ in (200, [:], "bytes of \(path)") }
        defer { server.stop() }
        let given = URL(string: "http://127.0.0.1:\(server.port)/emby/Videos/m1/master.m3u8")!
        let list = try list(["/hls1/main/0.ts", "http://localhost:\(server.port)/hls1/main/1.ts"], at: given)
        let opened = try XCTUnwrap(FilmStream.converted(given, list, at: 0, headers: key), "the relay isn't running")
        let read = try await segments(opened.address)
        XCTAssertEqual(read.count, 2)
        let here = try await get(read[0]), away = try await get(read[1])
        XCTAssertEqual(here.status, 200, "the segment on the server")
        XCTAssertFalse((200..<400).contains(away.status), "the segment elsewhere: \(away.status)")
        XCTAssertEqual(server.asked.value.map(\.path), ["/hls1/main/0.ts"])
    }
}

/// A server on this Mac's loopback, also reached as localhost (another
/// server to the app). It answers each path as told and keeps what it was
/// asked.
private final class Upstream: @unchecked Sendable {
    struct Asked {
        let host: String
        let path: String
        let query: String
        let key: String?
    }

    let asked = Locked<[Asked]>([])
    let port: UInt16
    private let listener: NWListener
    private let queue = DispatchQueue(label: "upstream")

    init(answer: @escaping @Sendable (_ path: String, _ port: UInt16) -> (Int, [String: String], String)) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        let (asked, listening) = (asked, Locked<UInt16>(0))
        listener.newConnectionHandler = { [queue] connection in
            connection.start(queue: queue)
            Self.read(connection, Data()) { head in
                let lines = head.components(separatedBy: "\r\n")
                let target = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                let parts = URLComponents(string: target)
                func header(_ name: String) -> String? {
                    lines.dropFirst().first { $0.lowercased().hasPrefix(name.lowercased() + ":") }
                        .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
                }
                let path = parts?.path ?? target
                asked.mutate { $0.append(Asked(host: header("Host") ?? "", path: path, query: parts?.query ?? "", key: header("X-Emby-Token"))) }
                let (status, headers, body) = answer(path, listening.value)
                var reply = "HTTP/1.1 \(status) Answer\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n"
                for (name, value) in headers { reply += "\(name): \(value)\r\n" }
                connection.send(content: Data((reply + "\r\n" + body).utf8), contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 2) == .success, let port = listener.port?.rawValue else { throw XCTSkip("no local server") }
        self.port = port
        listening.mutate { $0 = port }
    }

    private static func read(_ connection: NWConnection, _ buffer: Data, then: @escaping (String) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, done, error in
            let buffer = buffer + (data ?? Data())
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                then(String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if done || error != nil {
                connection.cancel()
            } else {
                read(connection, buffer, then: then)
            }
        }
    }

    func stop() { listener.cancel() }
}

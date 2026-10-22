import Network
import XCTest
@testable import OpenIPTV

/// A server for one film of zeros: each answer after `delay`, and each
/// range asked for noted.
private final class FilmServer: @unchecked Sendable {
    private let size: Int64
    private let delay: Double
    private let listener: NWListener
    private let queue = DispatchQueue(label: "film-server")
    private let lock = NSLock()
    private var asked: [String] = []

    init(size: Int64, delay: Double) throws {
        self.size = size
        self.delay = delay
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.newConnectionHandler = { [unowned self] in self.serve($0) }
        listener.start(queue: queue)
        ready.wait()
    }

    deinit { listener.cancel() }

    var film: URL { URL(string: "http://127.0.0.1:\(listener.port?.rawValue ?? 0)/emby/Videos/m1/stream.mkv?Static=true&MediaSourceId=m1")! }

    var ranges: [String] { lock.withLock { asked } }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] data, _, _, _ in
            let lines = String(decoding: data ?? Data(), as: UTF8.self).components(separatedBy: "\r\n")
            let range = lines.first { $0.lowercased().hasPrefix("range:") }.map { $0.dropFirst(6).trimmingCharacters(in: .whitespaces) } ?? ""
            lock.withLock { asked.append(range) }
            let parts = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
            let from = Int64(parts.first ?? "") ?? 0
            let to = min(parts.count == 2 ? Int64(parts[1]) ?? size - 1 : size - 1, size - 1)
            queue.asyncAfter(deadline: .now() + delay) {
                let head = "HTTP/1.1 206 Partial Content\r\nContent-Type: video/x-matroska\r\nContent-Length: \(to - from + 1)\r\n"
                    + "Content-Range: bytes \(from)-\(to)/\(size)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data(head.utf8) + Data(count: Int(to - from + 1)), contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}

final class KeptStartUseTests: XCTestCase {
    /// The tap came while the fetch ahead was reading the file's first
    /// bytes, as on a server 1-3 s a read: the player's first read is the
    /// same one.
    func testAStartsFirstReadWaitsForTheBytesOnTheirWayRatherThanAskingAgain() async throws {
        let server = try FilmServer(size: 64 << 20, delay: 0.5)
        let relay = StreamRelay()
        let film = EmbyPlayback(itemId: "m1", title: "Film", subtitle: nil, url: server.film, durationSeconds: 7200)
        let ahead = Task { await relay.fetchStart(FileStart(film)) }
        for _ in 0..<100 where server.ranges.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(server.ranges, ["bytes=0-524287"], "the fetch ahead didn't begin with the first read")
        var read = URLRequest(url: try XCTUnwrap(relay.localURL(for: film.url, headers: [])))
        read.setValue("bytes=0-524287", forHTTPHeaderField: "Range")
        let (bytes, response) = try await URLSession(configuration: .ephemeral).data(for: read)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(bytes.count, 524_288)
        XCTAssertEqual(server.ranges.filter { $0 == "bytes=0-524287" }.count, 1, "the first read asked the server again for bytes on their way")
        _ = await ahead.value
    }
}

#if DEBUG
final class KeptStartTests: XCTestCase {
    private let film = URL(string: "http://server/emby/Videos/m1/stream.mkv?Static=true&MediaSourceId=ms1&PlaySessionId=a")!

    private func reason(_ address: URL? = nil, cache: ByteCache?, device: Int64 = 0, _ records: [String: AheadRecord]) -> String {
        KeptStart.reason(address: address ?? film, key: "k", cache: cache, device: device, asked: 524_288, records: records, at: 12.4)
    }

    func testAFirstReadFromTheDeviceUsedTheKeptStart() throws {
        let cache = try XCTUnwrap(ByteCache(limit: 1 << 20))
        XCTAssertEqual(reason(cache: cache, device: 524_288, [:]), "used")
        XCTAssertEqual(reason(cache: cache, device: 4096, [:]), "used in part")
    }

    func testAFetchAheadUnderWayAtTheTapSaysHowFarItGot() throws {
        let cache = try XCTUnwrap(ByteCache(limit: 1 << 20))
        var record = AheadRecord(address: film, began: 10, cache: cache)
        record.asked = 2
        record.answered = 1
        XCTAssertEqual(reason(cache: cache, ["k": record]), "unused, 1 of 2 reads done at the tap, 2.4 s after it began")
        record.finished = false
        record.noteAnswer(status: 200, bytes: 9, total: nil, known: 100)
        XCTAssertEqual(reason(cache: cache, ["k": record]), "unused, stopped after 1 reads: status 200")
    }

    func testAStoreLetGoBeforeTheTapIsSaid() throws {
        let kept = try XCTUnwrap(ByteCache(limit: 1 << 20)), now = try XCTUnwrap(ByteCache(limit: 1 << 20))
        let record = AheadRecord(address: film, began: 10, cache: kept)
        XCTAssertEqual(reason(cache: now, ["k": record]), "unused, let go before the tap")
    }

    func testAnotherKeyForTheSameFileCountsItsFieldsNotItsValues() throws {
        let cache = try XCTUnwrap(ByteCache(limit: 1 << 20))
        let other = URL(string: "http://server/emby/Videos/m1/stream.mkv?Static=true&MediaSourceId=ms2&PlaySessionId=b")!
        let said = reason(cache: cache, ["other": AheadRecord(address: other, began: 10, cache: cache)])
        XCTAssertEqual(said, "unused, key differs in 1 field")
        XCTAssertFalse(said.contains("ms"), "a field's value was said")
        XCTAssertEqual(reason(cache: cache, [:]), "unused, nothing fetched ahead")
        let elsewhere = URL(string: "http://server/emby/Videos/m2/stream.mkv")!
        XCTAssertEqual(reason(cache: cache, ["other": AheadRecord(address: elsewhere, began: 10, cache: cache)]),
                       "unused, none fetched ahead for this file (1 others)")
    }

    func testRequestTimesSayTheConnectionApartFromTheServersWait() {
        let times = RequestTimes(queued: 0.0004, dns: 0.003, tcp: 0.121, tls: 0.38, wait: 0.19, reused: false, http: "h2")
        XCTAssertEqual(times.readout, "queued 0 ms, DNS 3 ms, TCP 121 ms, TLS 380 ms, wait 190 ms (new, h2)")
    }
}
#endif

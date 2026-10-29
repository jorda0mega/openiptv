import Network
import XCTest
@testable import OpenIPTV

/// A server for one film of zeros: each answer after `delay`, none to the
/// first `silent` asks, and each range asked for noted.
private final class FilmServer: @unchecked Sendable {
    private let size: Int64
    private let delay: Double
    private var silent: Int
    private let listener: NWListener
    private let queue = DispatchQueue(label: "film-server")
    private let lock = NSLock()
    private var asked: [String] = []

    init(size: Int64, delay: Double, silent: Int = 0) throws {
        self.size = size
        self.delay = delay
        self.silent = silent
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
            let answers = lock.withLock {
                asked.append(range)
                silent -= 1
                return silent < 0
            }
            guard answers else { return }
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

final class FirstByteTests: XCTestCase {
    private func read(through relay: StreamRelay, _ server: FilmServer) async throws -> (Data, URLResponse) {
        let film = EmbyPlayback(itemId: "m1", title: "Film", subtitle: nil, url: server.film, durationSeconds: 7200)
        var read = URLRequest(url: try XCTUnwrap(relay.localURL(for: film.url, headers: [])))
        read.setValue("bytes=0-524287", forHTTPHeaderField: "Range")
        read.timeoutInterval = 5
        return try await URLSession(configuration: .ephemeral).data(for: read)
    }

    func testAReadTheServerNeverAnswersIsAskedOnceMore() async throws {
        let server = try FilmServer(size: 64 << 20, delay: 0, silent: 1)
        let relay = StreamRelay()
        relay.firstByteWait = .milliseconds(500)
        let (bytes, response) = try await read(through: relay, server)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(bytes.count, 524_288)
        XCTAssertEqual(server.ranges, ["bytes=0-524287", "bytes=0-524287"])
    }

    /// The first answer came as the wait for it ran out: the player reads
    /// only the answer to the ask that replaced it.
    func testAnAnswerComingAsItsReadIsAskedAgainIsNotSentToThePlayer() async throws {
        let server = try FilmServer(size: 64 << 20, delay: 0.3)
        let relay = StreamRelay()
        relay.firstByteWait = .milliseconds(600)
        // The relay hears of the first answer only once its wait ran out.
        HTTP.session.delegateQueue.addOperation { Thread.sleep(forTimeInterval: 1) }
        let (bytes, response) = try await read(through: relay, server)
        XCTAssertEqual(server.ranges.count, 2)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(bytes, Data(count: 524_288), "the player read the second answer's header as film")
    }

    /// Over a bare connection: URLSession sends an unanswered read again by itself.
    func testAReadNeverAnsweredTwiceEndsSoTheStartCanGoOn() async throws {
        let server = try FilmServer(size: 64 << 20, delay: 0, silent: 2)
        let relay = StreamRelay()
        relay.firstByteWait = .milliseconds(500)
        let film = EmbyPlayback(itemId: "m1", title: "Film", subtitle: nil, url: server.film, durationSeconds: 7200)
        let local = try XCTUnwrap(relay.localURL(for: film.url, headers: []))
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(try XCTUnwrap(local.port)))!, using: .tcp)
        let began = ContinuousClock.now
        let answer = await withCheckedContinuation { (done: CheckedContinuation<Data, Never>) in
            var got = Data()
            func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                    got += data ?? Data()
                    if isComplete || error != nil { done.resume(returning: got) } else { receive() }
                }
            }
            connection.start(queue: .global())
            let path = local.path + (local.query.map { "?" + $0 } ?? "")
            connection.send(content: Data("GET \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nRange: bytes=0-524287\r\n\r\n".utf8),
                            completion: .contentProcessed { _ in receive() })
        }
        connection.cancel()
        XCTAssertTrue(answer.isEmpty, "the relay answered a read the server never did")
        XCTAssertEqual(server.ranges.count, 2)
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(2), "the player waited past two waits for a first byte")
    }
}

final class RelayArrivedTests: XCTestCase {
    func testArrivedCountsServerAndDeviceBytesAndNeverGoesDown() async throws {
        let server = try FilmServer(size: 64 << 20, delay: 0)
        let relay = StreamRelay()
        let film = EmbyPlayback(itemId: "m1", title: "Film", subtitle: nil, url: server.film, durationSeconds: 7200)
        func read() async throws -> Int {
            var read = URLRequest(url: try XCTUnwrap(relay.localURL(for: film.url, headers: [])))
            read.setValue("bytes=0-524287", forHTTPHeaderField: "Range")
            read.timeoutInterval = 5
            return try await URLSession(configuration: .ephemeral).data(for: read).0.count
        }
        let fromServer = try await read()
        XCTAssertEqual(relay.arrived.value, Int64(fromServer))
        #if DEBUG
        relay.beginStartReads()
        #endif
        let fromDevice = try await read()
        XCTAssertEqual(server.ranges.count, 1, "the second read went to the server, not the device")
        XCTAssertEqual(relay.arrived.value, Int64(fromServer + fromDevice), "the device's bytes didn't count, or the count went back")
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

    /// Asked once the film plays, a read ahead goes no faster than the
    /// player's own: waiting for it (all at once, at its end) would hold
    /// the start back.
    func testAReadAskedAheadAfterTheTapIsNotWaitedFor() async throws {
        let server = try FilmServer(size: 64 << 20, delay: 0.5)
        let relay = StreamRelay()
        let film = EmbyPlayback(itemId: "m1", title: "Film", subtitle: nil, url: server.film, durationSeconds: 7200)
        relay.stopAhead(keeping: film.url)
        let ahead = Task { await relay.fetchStart(FileStart(film)) }
        for _ in 0..<100 where server.ranges.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        var read = URLRequest(url: try XCTUnwrap(relay.localURL(for: film.url, headers: [])))
        read.setValue("bytes=0-524287", forHTTPHeaderField: "Range")
        let (bytes, _) = try await URLSession(configuration: .ephemeral).data(for: read)
        XCTAssertEqual(bytes.count, 524_288)
        XCTAssertEqual(server.ranges.filter { $0 == "bytes=0-524287" }.count, 2, "the player waited for a read asked after the tap")
        _ = await ahead.value
    }

    /// The fetch ahead has no wait for a first byte of its own: the
    /// player's read waits for it 3 s, then asks the server itself.
    func testAReadWaitsForTheBytesOnTheirWayOnlyOnce() async throws {
        let server = try FilmServer(size: 64 << 20, delay: 0, silent: 1)
        let relay = StreamRelay()
        let film = EmbyPlayback(itemId: "m1", title: "Film", subtitle: nil, url: server.film, durationSeconds: 7200)
        let ahead = Task { await relay.fetchStart(FileStart(film)) }
        for _ in 0..<100 where server.ranges.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        var read = URLRequest(url: try XCTUnwrap(relay.localURL(for: film.url, headers: [])))
        read.setValue("bytes=0-524287", forHTTPHeaderField: "Range")
        read.timeoutInterval = 6
        let began = ContinuousClock.now
        let answer = try? await URLSession(configuration: .ephemeral).data(for: read)
        XCTAssertEqual(answer?.0.count, 524_288, "the player's read waited past 3 s for bytes on their way")
        XCTAssertLessThan(ContinuousClock.now - began, .seconds(5))
        relay.stopAhead(keeping: nil)
        _ = await ahead.value
    }
}

final class PhoneNetworkDayTests: XCTestCase {
    func testAStartAheadNeverTakesTheDayPast150MB() async throws {
        let suite = "phone-network-\(UUID())"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let use = PhoneNetworkUse(defaults: try XCTUnwrap(UserDefaults(suiteName: suite))) { .expensive }
        use.noteArrived(Int(PhoneNetworkFilms.dailyBytes - StreamRelay.firstRead / 2), over: .expensive)
        let server = try FilmServer(size: 64 << 20, delay: 0)
        let relay = StreamRelay()
        relay.phoneNetworkUse = use
        _ = await relay.fetchStart(FileStart(EmbyPlayback(itemId: "m1", title: "Film", subtitle: nil, url: server.film, durationSeconds: 7200)))
        XCTAssertLessThanOrEqual(use.usedToday(), PhoneNetworkFilms.dailyBytes, "a start ahead took the day past 150 MB")
        XCTAssertEqual(server.ranges, [], "a read that didn't fit in what was left was asked")
    }

    func testAStartAheadStoppedStopsItsReadUnderWay() async throws {
        let server = try FilmServer(size: 64 << 20, delay: 2)
        let relay = StreamRelay()
        let ahead = Task { await relay.fetchStart(FileStart(EmbyPlayback(itemId: "m1", title: "Film", subtitle: nil, url: server.film,
                                                                        durationSeconds: 7200))) }
        for _ in 0..<100 where server.ranges.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        let stopped = ContinuousClock.now
        ahead.cancel()
        let fetched = await ahead.value
        XCTAssertFalse(fetched)
        XCTAssertLessThan(ContinuousClock.now - stopped, .seconds(1), "the read under way went on after its start was stopped")
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
        XCTAssertEqual(reason(cache: cache, ["k": record]), "not done at the tap, 1 of 2 reads done, 2.4 s after it began")
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

/// The start line says what its card took from the server before the tap,
/// so a phone network's cost per card is read off each run.
final class AheadTakenTests: XCTestCase {
    func testACardSaysWhatItTookAheadTheOpensOwnReadsApartFromTheRest() async throws {
        let server = try FilmServer(size: 64 << 20, delay: 0)
        let item = "taken-\(UUID().uuidString)"
        let film = FileStart(EmbyPlayback(itemId: item, title: "Film", subtitle: nil, url: server.film, durationSeconds: 7200))
        let relay = StreamRelay()
        XCTAssertEqual(AheadTaken.readout(item), "took ahead: open 0.00 MB in 0 reads, rest 0.00 MB in 0 reads")
        // A film of zeros: its first read, then no layout to go on with.
        _ = await relay.fetchStart(film)
        await relay.warmConnection(film)
        AheadTaken.note(item, .rest, bytes: 41_000)
        XCTAssertEqual(AheadTaken.readout(item), "took ahead: open 0.52 MB in 1 read, rest 0.04 MB in 2 reads")
    }

    func testASubtitleOrStillsAddressNamesItsTitle() {
        XCTAssertEqual(AheadTaken.itemId(in: URL(string: "http://server/emby/Videos/m5/ms-m5/Subtitles/3/Stream.srt")!), "m5")
        XCTAssertNil(AheadTaken.itemId(in: URL(string: "http://server/emby/Items/m5")!))
    }
}
#endif

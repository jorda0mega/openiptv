#if DEBUG
import XCTest
@testable import OpenIPTV

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

import XCTest

final class StreamFailureTests: XCTestCase {
    /// ffmpeg's and libmpv's warnings, the address made up.
    func testClassFromTheWarning() {
        let lines: [(String, StreamFailure?)] = [
            ("HTTP error 404 Not Found", .http_404),
            ("HTTP error 403 Forbidden", .http_403),
            ("HTTP error 401 Unauthorized", .http_401),
            ("HTTP error 429 Too Many Requests", .http_429),
            ("HTTP error 503 Service Unavailable", .http_5xx),
            ("Server returned 5XX Server Error reply", .http_5xx),
            ("Server returned 400 Bad Request", .http_other),
            ("Connection to tcp://192.0.2.1:8080 failed: Connection refused", .refused),
            ("Connection reset by peer", .reset),
            ("Connection timed out", .timeout),
            ("Failed to resolve hostname example.invalid: nodename nor servname provided, or not known", .dns),
            ("Invalid data found when processing input", .probe_failed),
            ("Could not open codec h264", .decode),
            ("Stream ends prematurely at 1234, should be 5678", nil),
            ("Opening done: http://example.invalid/live/u/p/1.ts", nil),
        ]
        for (line, failure) in lines {
            XCTAssertEqual(StreamFailure(logged: line), failure, line)
        }
    }

    func testKinds() {
        let kinds: [(StreamFailure, StreamFailure.Kind)] = [
            (.http_404, .gone), (.no_data, .gone), (.eof_before_frame, .gone), (.probe_failed, .gone), (.unknown, .gone),
            (.http_5xx, .flaky), (.timeout, .flaky), (.reset, .flaky),
            (.http_401, .turnedAway), (.http_403, .turnedAway),
            (.http_429, .tooMany),
            (.dns, .unreachable), (.refused, .unreachable), (.tls, .unreachable),
            (.offline, .offline),
        ]
        for (failure, kind) in kinds {
            XCTAssertEqual(failure.kind, kind, failure.rawValue)
        }
    }

    func testClassOfAnAddressLookup() {
        XCTAssertEqual(StreamFailure(lookup: .offline), .offline)
        XCTAssertEqual(StreamFailure(lookup: .http(429)), .http_429)
        XCTAssertEqual(StreamFailure(lookup: .http(403)), .http_403)
        XCTAssertEqual(StreamFailure(lookup: .http(502)), .http_5xx)
        XCTAssertEqual(StreamFailure(lookup: .rejected), .http_401)
        XCTAssertEqual(StreamFailure(lookup: .network("Couldn't connect to the server.")), .unknown)
        XCTAssertNil(StreamFailure(lookup: .cancelled), "a lookup the screen stopped counted as a failure")
    }

    /// ffmpeg's own format strings: only those that can say why a stream
    /// failed are written out.
    func testOnlyFailureLinesAreRead() {
        for format in ["HTTP error %d %s\n", "Connection to %s failed: %s\n", "Failed to resolve hostname %s: %s\n",
                       "Could not find codec parameters for stream %d (%s): %s\n"] {
            XCTAssertTrue(StreamFailure.worthReading(format: format), format)
        }
        for format in ["error while decoding MB %d %d, bytestream %d\n", "Packet corrupt (stream = %d, dts = %s).\n",
                       "PES packet size mismatch\n", "%s"] {
            XCTAssertFalse(StreamFailure.worthReading(format: format), format)
        }
    }

    func testFfmpegFailuresBelongToTheOnlyPlayerOpen() {
        var ledger = FailureLedger()
        ledger.record(.http_404, at: 1)
        XCTAssertNil(ledger.failure(of: 1, since: 0), "a failure with no player open was kept")
        ledger.began(1)
        ledger.record(.http_404, at: 2)
        XCTAssertEqual(ledger.failure(of: 1, since: 2), .http_404)
        XCTAssertNil(ledger.failure(of: 1, since: 3), "a failure from before the load counted")
        ledger.began(2)
        ledger.record(.http_5xx, at: 4)
        XCTAssertEqual(ledger.failure(of: 1, since: 2), .http_404, "a failure while two players were open went to one")
        XCTAssertNil(ledger.failure(of: 2, since: 0))
        ledger.closed(2)
        ledger.began(1)
        ledger.ended(1)
        ledger.record(.http_403, at: 5)
        XCTAssertEqual(ledger.failure(of: 1, since: 5), .http_403, "the replaced load's end closed the new one")
    }
}

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

    func testStepAtTheOpen() {
        func step(_ failure: StreamFailure, triedAgain: Bool = false, sinceSwitch: Double = 60) -> StreamFailure.Step {
            failure.step(played: false, triedAgain: triedAgain, sinceSwitch: sinceSwitch)
        }
        for failure in [StreamFailure.http_404, .no_data, .eof_before_frame, .probe_failed, .unknown] {
            XCTAssertEqual(step(failure), .nextCopy, failure.rawValue)
        }
        for failure in [StreamFailure.http_5xx, .timeout, .reset] {
            XCTAssertEqual(step(failure), .sameCopy(after: 1), failure.rawValue)
            XCTAssertEqual(step(failure, triedAgain: true), .nextCopy, failure.rawValue)
        }
        XCTAssertEqual(step(.http_403, sinceSwitch: 0.5), .sameCopy(after: 1.5), "a refusal right after a switch")
        XCTAssertEqual(step(.http_403, triedAgain: true, sinceSwitch: 2), .stop)
        XCTAssertEqual(step(.http_401), .stop, "a refusal long after a switch")
        XCTAssertEqual(step(.http_429), .stop)
        for failure in [StreamFailure.offline, .dns, .refused, .tls] {
            XCTAssertEqual(step(failure), .stop, failure.rawValue)
        }
    }

    func testStepOnceItPlayed() {
        for failure in StreamFailure.allCases where failure != .http_429 {
            XCTAssertEqual(failure.step(played: true, triedAgain: true, sinceSwitch: 0), .reconnect, failure.rawValue)
        }
        XCTAssertEqual(StreamFailure.http_429.step(played: true, triedAgain: false, sinceSwitch: 60), .stop)
    }
}

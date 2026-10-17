import XCTest

/// A source's record of being asked for its lineup (LineupCheck): only an
/// answer makes the lineup newer, and a busy provider isn't asked again
/// and again.
final class LineupCheckTests: XCTestCase {
    private let answered = Date(timeIntervalSince1970: 1_800_000_000)
    private let maxAge: TimeInterval = 15 * 60

    /// A refused ask records the ask and the reason; the lineup is as old
    /// as before. An answer makes it new and clears the reason.
    func testFailureNeverMovesAnsweredAt() {
        var check = LineupCheck(answeredAt: answered)
        check.record(.failure(.http(429)), at: answered + 600)
        XCTAssertEqual(check.answeredAt, answered)
        XCTAssertEqual(check.askedAt, answered + 600)
        XCTAssertEqual(check.problem?.localizedDescription, "Your provider is busy right now (too many requests).")
        check.record(.success(()), at: answered + 1200)
        XCTAssertEqual(check.answeredAt, answered + 1200)
        XCTAssertNil(check.problem)
    }

    /// Anything the provider answered (a 429 here) waits the page's whole
    /// interval from the ask.
    func testBusyProviderWaitsTheInterval() {
        var check = LineupCheck(answeredAt: answered)
        check.record(.failure(.http(429)), at: answered + 600)
        XCTAssertEqual(check.nextAsk(maxAge: maxAge), answered + 600 + maxAge)
    }

    /// No connection: the provider was never reached, so again within a
    /// minute (or sooner, when the page's interval is shorter).
    func testOfflineAsksAgainWithinAMinute() {
        var check = LineupCheck(answeredAt: answered)
        check.record(.failure(.offline), at: answered + 600)
        XCTAssertEqual(check.nextAsk(maxAge: maxAge), answered + 660)
        XCTAssertEqual(check.nextAsk(maxAge: 5), answered + 605)
    }

    /// Restored from the saved lineup: due by the time it was answered;
    /// never answered, due now.
    func testRestoredCheckIsDueByItsSavedTime() {
        XCTAssertEqual(LineupCheck(answeredAt: answered).nextAsk(maxAge: maxAge), answered + maxAge)
        XCTAssertEqual(LineupCheck().nextAsk(maxAge: maxAge), .distantPast)
    }
}

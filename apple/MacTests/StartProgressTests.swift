import XCTest
@testable import OpenIPTV

/// What a start tells the loading progress: its stage, what is slow from
/// 8 s, and its failure by 30 s.
final class StartProgressTests: XCTestCase {
    private let tap = ContinuousClock.now

    func testASlowStartNamesWhatIsSlowFromEightSeconds() {
        var start = StartProgress(stage: .askingServer, tapped: tap)
        XCTAssertNil(start.cause(at: tap + .seconds(7.9)))
        XCTAssertEqual(start.cause(at: tap + .seconds(8)), .serverSlowToAnswer)
        start.stage = .openingFilm
        XCTAssertEqual(start.cause(at: tap + .seconds(12)), .filmSlowToArrive)
        start.stage = .starting
        XCTAssertEqual(start.cause(at: tap + .seconds(12)), .slowToStart)
    }

    func testAStartFailsAtThirtySecondsOrAtItsError() {
        var start = StartProgress(stage: .openingFilm, tapped: tap)
        XCTAssertFalse(start.failed(at: tap + .seconds(29.9)))
        XCTAssertTrue(start.failed(at: tap + .seconds(30)))
        XCTAssertNil(start.cause(at: tap + .seconds(31)), "a failure, not a cause")
        start.failure = "The server answered with an error (HTTP 500)."
        XCTAssertTrue(start.failed(at: tap + .seconds(1)))
        XCTAssertNil(start.cause(at: tap + .seconds(9)))
    }
}

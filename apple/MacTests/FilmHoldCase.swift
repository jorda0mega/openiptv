import XCTest
@testable import OpenIPTV

class FilmHoldCase: XCTestCase {
    override func setUp() {
        super.setUp()
        PlaybackActivity.quietAfterFilm = .zero
    }

    override func tearDown() async throws {
        for _ in 0..<50 where HTTP.turns.isHeld { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertFalse(HTTP.turns.isHeld, "a test left what's fetched ahead held")
        PlaybackActivity.quietAfterFilm = .seconds(5)
        try await super.tearDown()
    }
}

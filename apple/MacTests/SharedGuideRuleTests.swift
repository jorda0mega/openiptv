import XCTest
@testable import OpenIPTV

final class SharedGuideRuleTests: XCTestCase {
    private let now: Int64 = 1_800_000_000

    func testWords() {
        XCTAssertEqual(SharedGuideRule.words(in: "Simpsons FOX"), ["simpsons", "fox"])
        XCTAssertEqual(SharedGuideRule.words(in: "a 1 Café"), ["1", "cafe"])
    }

    func testAWordMustBeInTheTitle() {
        let words = SharedGuideRule.words(in: "channel 14")
        XCTAssertTrue(SharedGuideRule.findsProgramme(words, title: "show 14-4", channel: "channel 14", stop: now + 60, now: now))
        XCTAssertFalse(SharedGuideRule.findsProgramme(SharedGuideRule.words(in: "channel"), title: "show 14-4", channel: "channel 14", stop: now + 60, now: now),
                       "found by its channel's name alone")
        XCTAssertFalse(SharedGuideRule.findsProgramme(words, title: "show 12-4", channel: "channel 12", stop: now + 60, now: now))
    }

    func testAProgrammeOverIsntFound() {
        XCTAssertFalse(SharedGuideRule.findsProgramme(["show"], title: "show 1-4", channel: nil, stop: now, now: now))
        XCTAssertFalse(SharedGuideRule.findsProgramme(["show"], title: "show 1-4", channel: nil, stop: now - 1, now: now))
    }

    func testGamesInTheirLeagueWhileListed() {
        let words = SharedGuideRule.words(in: "eagles nfl")
        XCTAssertTrue(SharedGuideRule.findsGame(words, text: "eagles vs. jaguars nfl", start: now - 600, now: now))
        XCTAssertTrue(SharedGuideRule.findsGame(words, text: "eagles vs. jaguars nfl", start: nil, now: now))
        XCTAssertFalse(SharedGuideRule.findsGame(words, text: "eagles vs. jaguars nfl", start: now - Int64(GameTime.listed) - 1, now: now))
        XCTAssertFalse(SharedGuideRule.findsGame(words, text: "eagles vs. jaguars", start: now, now: now))
    }
}

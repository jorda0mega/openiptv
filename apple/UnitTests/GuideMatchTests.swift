import XCTest

final class GuideMatchTests: XCTestCase {
    private let now: Int64 = 1_800_000_000

    func testWords() {
        XCTAssertEqual(GuideMatch.words("Simpsons FOX"), ["simpsons", "fox"])
        XCTAssertEqual(GuideMatch.words("a 1 Café"), ["1", "cafe"])
    }

    func testAWordMustBeInTheTitle() {
        let words = GuideMatch.words("channel 14")
        XCTAssertTrue(GuideMatch.programme(words, title: "show 14-4", channel: "channel 14", stop: now + 60, now: now))
        XCTAssertFalse(GuideMatch.programme(GuideMatch.words("channel"), title: "show 14-4", channel: "channel 14", stop: now + 60, now: now),
                       "found by its channel's name alone")
        XCTAssertFalse(GuideMatch.programme(words, title: "show 12-4", channel: "channel 12", stop: now + 60, now: now))
    }

    func testAProgrammeOverIsntFound() {
        XCTAssertFalse(GuideMatch.programme(["show"], title: "show 1-4", channel: nil, stop: now, now: now))
        XCTAssertFalse(GuideMatch.programme(["show"], title: "show 1-4", channel: nil, stop: now - 1, now: now))
    }

    func testGamesInTheirLeagueWhileListed() {
        let words = GuideMatch.words("eagles nfl")
        XCTAssertTrue(GuideMatch.game(words, text: "eagles vs. jaguars nfl", start: now - 600, now: now))
        XCTAssertTrue(GuideMatch.game(words, text: "eagles vs. jaguars nfl", start: nil, now: now))
        XCTAssertFalse(GuideMatch.game(words, text: "eagles vs. jaguars nfl", start: now - Int64(GameTime.listed) - 1, now: now))
        XCTAssertFalse(GuideMatch.game(words, text: "eagles vs. jaguars", start: now, now: now))
    }
}

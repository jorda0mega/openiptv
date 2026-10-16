import XCTest

/// How long a game counts as live (GameTime): its sport's usual length.
final class GameTimeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    /// The user's game: soccer that started at 10:00, seen at 1:10.
    func testSoccerThreeHoursInIsOver() {
        XCTAssertEqual(GameTime.state(start: ago(190), league: "Soccer", title: "Purdue Northwest vs Davenport · Men's", now: now), .over)
        XCTAssertEqual(GameTime.state(start: ago(100), league: "Soccer", title: "Purdue Northwest vs Davenport · Men's", now: now), .live)
    }

    func testEachSportsLength() {
        XCTAssertEqual(GameTime.length(league: "Premier League", title: "Arsenal vs. Chelsea"), 2.5 * 3600)
        XCTAssertEqual(GameTime.length(league: "NBA", title: "Raptors vs. Knicks"), 2.75 * 3600)
        XCTAssertEqual(GameTime.length(league: "NHL", title: "Hockey: Flyers vs. Red Wings"), 3 * 3600)
        XCTAssertEqual(GameTime.length(league: "NFL", title: "Eagles vs. Jaguars"), 3.75 * 3600)
        XCTAssertEqual(GameTime.length(league: "MLB", title: "Yankees vs. Red Sox"), 3.75 * 3600)
        XCTAssertEqual(GameTime.length(league: "UFC", title: "UFC 320"), GameTime.listed)
        XCTAssertEqual(GameTime.length(league: "DAZN", title: "Live Stream"), 3 * 3600)
    }

    /// "Football / Soccer" is soccer; a service's name (no league) goes by
    /// the sport the title starts with.
    func testSportFromTheTitle() {
        XCTAssertEqual(GameTime.length(league: "Football / Soccer", title: "Barcelona vs Paris FC"), 2.5 * 3600)
        XCTAssertEqual(GameTime.length(league: "ESPN Unlimited", title: "Hockey: Islanders vs. Senators"), 3 * 3600)
        XCTAssertEqual(GameTime.length(league: "ESPN Unlimited", title: "Football: Eagles vs. Jaguars"), 3.75 * 3600)
    }

    func testUpcomingAndUndated() {
        XCTAssertEqual(GameTime.state(start: now.addingTimeInterval(600), league: "NFL", title: "", now: now), .upcoming)
        XCTAssertNil(GameTime.state(start: nil, league: "NFL", title: "", now: now))
    }
}

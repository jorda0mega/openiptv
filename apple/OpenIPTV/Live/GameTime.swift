import Foundation

/// How long a game lasts, by its league or sport: a game listed as started
/// longer ago than that is probably over, though its slot is still listed
/// (event lists name a start, never an end). Regression: a soccer game three
/// hours in was LIVE in Sports and didn't play.
enum GameTime {
    enum State: Equatable { case upcoming, live, over }

    /// Listed at all until this long after the start.
    static let listed: TimeInterval = 4 * 3600

    /// Live from the start for as long as such a game lasts (with its usual
    /// extra: stoppage, overtime, a delay), then over.
    static func state(start: Date?, league: String, title: String, now: Date = Date()) -> State? {
        guard let start else { return nil }
        if start > now { return .upcoming }
        return now.timeIntervalSince(start) < length(league: league, title: title) ? .live : .over
    }

    /// Soccer and rugby 2.5 h; basketball 2.75 h; hockey 3 h; American
    /// football and baseball 3.75 h; fight cards, golf, tennis and cricket
    /// the whole 4 h they're listed; anything else 3 h. By the league's name,
    /// else the sport the title starts with ("Hockey: Flyers vs. Red Wings").
    static func length(league: String, title: String) -> TimeInterval {
        let text = "\(league) | \(title)".lowercased()
        // Whole words ("nba" isn't in "unbalanced").
        func any(_ words: [String]) -> Bool {
            words.contains { text.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }
        }
        // Before "football": soccer leagues, and "football / soccer".
        if any(["soccer", "premier league", "la liga", "laliga", "serie a", "bundesliga", "ligue 1", "uefa", "mls", "efl",
                "spfl", "national league", "liga mx", "copa", "rugby", "fc"]) { return 2.5 * 3600 }
        if any(["nba", "wnba", "basketball"]) { return 2.75 * 3600 }
        if any(["nhl", "hockey"]) { return 3 * 3600 }
        if any(["nfl", "football", "mlb", "baseball", "softball", "minor league"]) { return 3.75 * 3600 }
        if any(["ufc", "boxing", "wrestling", "mma", "pfl", "bkfc", "golf", "pga", "tennis", "cricket"]) { return listed }
        return 3 * 3600
    }
}

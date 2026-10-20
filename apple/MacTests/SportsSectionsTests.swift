import XCTest
@testable import OpenIPTV

final class SportsSectionsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_000_000)

    func testGameLongStartedIsntLive() throws {
        let game = try XCTUnwrap(jaguars(startedMinutesAgo: 230))
        XCTAssertEqual(game.section, "Earlier today")
    }

    /// Providers stamp event channels in Eastern time.
    func testGameLaterTodayIsntLive() throws {
        let game = try XCTUnwrap(jaguars(startedMinutesAgo: -180))
        XCTAssertEqual(try XCTUnwrap(game.entry.event?.start).timeIntervalSince(now), 3 * 3600, accuracy: 60)
        XCTAssertNotEqual(game.section, "Live now")
    }

    private func jaguars(startedMinutesAgo minutes: Double) -> (section: String, entry: LiveOrganizer.Entry)? {
        let (categories, channels) = sportsLineup(start: now.addingTimeInterval(-minutes * 60))
        let library = LiveOrganizer.organize(categories: categories, channels: channels, home: "US", now: now)
        let games = library.shelves.first { $0.id == LiveOrganizer.sportsID }?.sections.first { $0.id == "events" }?.entries ?? []
        for section in LiveOrganizer.gameSections(games, now: now) {
            if let entry = section.entries.first(where: { $0.title.contains("Jaguars") }) { return (section.title, entry) }
        }
        return nil
    }

    /// scripts/mock_server.py's `sports=1` lineup.
    private func sportsLineup(start: Date) -> ([LiveCategory], [LiveChannel]) {
        let eastern = DateFormatter()
        eastern.locale = Locale(identifier: "en_US_POSIX")
        eastern.timeZone = TimeZone(identifier: "America/New_York")
        eastern.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let stamp = eastern.string(from: start)
        let source = UUID()
        let categories = [("10", "NFL"), ("11", "ESPN Unlimited"), ("12", "DAZN CA")]
            .map { LiveCategory(id: "\(source)|\($0.0)", name: $0.1, channels: 0) }
        let games = [("NFL 01: Eagles vs. Jaguars", "10"),
                     ("ESPN UNLTD 015: Football: Eagles vs. Jaguars", "11"),
                     ("ESPN UNLTD 016: Football: Eagles vs. Jaguars (Eagles vs. Jaguars (ESP))", "11"),
                     ("DAZN CA 17: Eagles vs. Jaguars", "12"),
                     ("DAZN CA 19: Eagles vs. Jaguars (In French)", "12")]
        let channels = games.enumerated().map { n, game in
            LiveChannel(id: "\(source)|\(2001 + n)", sourceId: source, number: Int64(2001 + n), name: "\(game.0) (\(stamp))", logo: nil,
                        categoryId: "\(source)|\(game.1)", epgId: nil, nativeId: "\(2001 + n)", stream: .xtream(streamId: Int64(2001 + n)))
        }
        return (categories, channels)
    }
}

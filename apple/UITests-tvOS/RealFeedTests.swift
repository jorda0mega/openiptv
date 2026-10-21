import XCTest

/// Apple TV on the real feeds: the IPTV lineup and Emby server the app is
/// for, not the test server. The logins come from a helper on this Mac
/// that holds them in memory (TEST_RUNNER_REAL_FEED, its address); skipped
/// without it. Screenshots go to /tmp/openiptv/uitest-real.
final class RealFeedTests: XCTestCase {
    private let app = XCUIApplication()
    private let remote = XCUIRemote.shared
    private let shots = URL(fileURLWithPath: "/tmp/openiptv/uitest-real")
    private var step = 0

    override func setUpWithError() throws {
        continueAfterFailure = false
        let feed = ProcessInfo.processInfo.environment["REAL_FEED"].flatMap(URL.init(string:))
        try XCTSkipIf(feed == nil, "needs the real feeds (TEST_RUNNER_REAL_FEED)")
        // The helper's addresses, not the logins: the simulator's system
        // log records the launch environment. The app fetches them.
        app.launchEnvironment["OPENREEL_DEBUG_EMBY_URL"] = feed!.appending(path: "emby").absoluteString
        app.launchEnvironment["OPENREEL_DEBUG_IPTV_URL"] = feed!.appending(path: "iptv").absoluteString
        // The viewer's own account: playing reports nothing to the server;
        // what the tests cache is kept apart from the test server's.
        app.launchArguments = ["-readOnlyServer", "YES", "-cacheFolder", "real"]
    }

    /// A live game on several channels, with the remote: it starts on one;
    /// Select opens Watch On, Right and Select play another.
    func testLiveGameWatchOn() throws {
        app.launchArguments += ["-tvTab", "live", "-tvLiveTab", "shelf:sports", "-forgetWatchOnPicks", "YES"]
        // A fresh lineup unless told to use the one kept from a run minutes
        // before (REAL_FEED_KEPT_LINEUP): the provider refuses after about
        // twelve loads in half an hour.
        if ProcessInfo.processInfo.environment["REAL_FEED_KEPT_LINEUP"] == nil { app.launchArguments += ["-freshLineup", "YES"] }
        app.launch()
        // The real lineup takes a while. A wait that keeps the run loop
        // going: a 20 s sleep got the test runner stopped by the watchdog.
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "the lineup loads")], timeout: 20)
        shot("launched")
        say("REAL focus at launch: \(focused())")
        // Into the page once it's there (the real lineup can take a minute).
        for _ in 0..<12 where focused() == "Live TV" || focused() == "nothing" {
            press(.down)
            if focused() == "Live TV" { _ = XCTWaiter.wait(for: [XCTestExpectation(description: "the lineup loads")], timeout: 5) }
        }
        // The page opens on the league picked last (here NFL, left by an
        // earlier run). Left opens the list of sections and leagues, as a
        // viewer would, on that league; All Games is just above it.
        let allGames = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'All Games'")).firstMatch
        for _ in 0..<4 where !allGames.exists { press(.left) }
        shot("list")
        for _ in 0..<20 where !focused().contains("All Games") { press(focused().contains("Top Games") ? .down : .up) }
        XCTAssertTrue(focused().contains("All Games"), "no All Games in Sports: \(focused())")
        press(.select)
        for _ in 0..<3 where !focused().contains("Live,") { press(.down) }
        XCTAssertTrue(focused().contains("Live,"), "no game on now: \(focused())")
        shot("games")

        let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'player.watchon.' AND identifier != 'player.watchon.tab'"))
        var game: String?
        var onSeveral = 0
        for _ in 0..<40 where game == nil && onSeveral < 8 {
            let label = focused()
            if label.firstMatch(of: #/\d+ channels/#) != nil {
                onSeveral += 1
                press(.select)
                _ = waitForCopy(timeout: 15)
                let state = waitForState(timeout: 25)
                for _ in 0..<2 where state == "playing" && !cards.firstMatch.exists { press(.select) }
                say("REAL tried \(label): \(state), \(cards.firstMatch.exists ? "Watch On" : "one channel")")
                if state == "playing", cards.firstMatch.exists {
                    game = label
                    break
                }
                press(.menu)
                // Back on the card before moving on (a Right while focus is
                // still coming back is lost, and the same game is tried again).
                for _ in 0..<20 where !focused().contains(", ") { usleep(250_000) }
            }
            let before = focused()
            press(.right)
            if focused() == before {
                say("REAL end of the row")
                break
            }
        }
        guard onSeveral > 0 else {
            say("REAL no game on 2+ channels")
            throw XCTSkip("no game on 2+ channels")
        }
        let name = try XCTUnwrap(game, "no live game on 2+ channels played")
        say("REAL game: \(name)")
        XCTAssertGreaterThanOrEqual(cards.count, 2, "Watch On has one channel")
        for card in cards.allElementsBoundByIndex { say("REAL choice: \(card.label)") }
        shot("watch on")
        let started = liveCopy()
        say("REAL first channel: \(started)")
        press(.right)
        press(.select)
        let deadline = Date().addingTimeInterval(10)
        while liveCopy() == started, Date() < deadline { usleep(250_000) }
        XCTAssertTrue(liveCopy() != started, "Right and Select didn't switch")
        say("REAL picked: \(liveCopy()) (\(waitForState(timeout: 20)))")
        shot("picked")
        press(.menu)
    }

    // MARK: Helpers

    private func press(_ button: XCUIRemote.Button) {
        remote.press(button)
        sleep(1)
        say("REAL focus after \(button.rawValue): \(focused())")
    }

    private func say(_ line: String) {
        print(line.replacing(#/tok=\w+/#, with: "tok=#"))
    }

    private func focused() -> String {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        return element.exists ? element.label : "nothing"
    }

    private func liveCopy() -> String {
        let readout = app.staticTexts["debug-live-copy"].firstMatch
        return readout.exists ? readout.label : ""
    }

    private func waitForCopy(timeout: TimeInterval) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while liveCopy().isEmpty, Date() < deadline { usleep(250_000) }
        return liveCopy()
    }

    private func waitForState(timeout: TimeInterval) -> String {
        let readout = app.staticTexts["debug-live-state"].firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if readout.exists, readout.label != "starting" { return readout.label }
            usleep(500_000)
        }
        return readout.exists ? readout.label : "no player"
    }

    private func shot(_ note: String) {
        step += 1
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let file = "tv-" + String(format: "%02d", step) + "-\(note.replacingOccurrences(of: " ", with: "-")).png"
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: file))
    }
}

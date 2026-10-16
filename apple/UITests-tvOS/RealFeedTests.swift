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
    }

    /// A live game on several channels, with the remote: it starts on one;
    /// Select opens Watch On, Right and Select play another.
    func testLiveGameWatchOn() throws {
        app.launchArguments = ["-tvTab", "live", "-tvLiveTab", "shelf:sports", "-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        // The real lineup takes a while. A wait that keeps the run loop
        // going: a 20 s sleep got the test runner stopped by the watchdog.
        _ = XCTWaiter.wait(for: [XCTestExpectation(description: "the lineup loads")], timeout: 20)
        // The list opens on Sports: All Games.
        shot("launched")
        print("REAL focus at launch: \(focused())")
        // Into the page once it's there (the real lineup can take a minute).
        for _ in 0..<12 where focused() == "Live TV" || focused() == "nothing" {
            press(.down)
            if focused() == "Live TV" { _ = XCTWaiter.wait(for: [XCTestExpectation(description: "the lineup loads")], timeout: 5) }
        }
        for _ in 0..<3 where !focused().contains("All Games") && !focused().contains("Top Games") { press(.down) }
        shot("list")
        for _ in 0..<20 where !focused().contains("All Games") { press(focused().contains("Top Games") ? .down : .up) }
        XCTAssertTrue(focused().contains("All Games"), "no All Games in Sports: \(focused())")
        press(.select)
        for _ in 0..<3 where !focused().contains("Live,") { press(.down) }
        XCTAssertTrue(focused().contains("Live,"), "no game on now: \(focused())")
        shot("games")

        let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'player.watchon.' AND identifier != 'player.watchon.tab'"))
        var game: String?
        for _ in 0..<8 {
            let label = focused()
            press(.select)
            _ = waitForCopy(timeout: 15)
            let state = waitForState(timeout: 25)
            for _ in 0..<2 where state == "playing" && !cards.firstMatch.exists { press(.select) }
            print("REAL tried \(label): \(state), \(cards.firstMatch.exists ? "Watch On" : "one channel")")
            if state == "playing", cards.firstMatch.exists {
                game = label
                break
            }
            press(.menu)
            press(.right)
        }
        let name = try XCTUnwrap(game, "no live game on more than one channel")
        print("REAL game: \(name)")
        XCTAssertGreaterThanOrEqual(cards.count, 2, "Watch On has one channel")
        for card in cards.allElementsBoundByIndex { print("REAL choice: \(card.label)") }
        shot("watch on")
        let started = liveCopy()
        print("REAL first channel: \(started)")
        press(.right)
        press(.select)
        let deadline = Date().addingTimeInterval(10)
        while liveCopy() == started, Date() < deadline { usleep(250_000) }
        XCTAssertNotEqual(liveCopy(), started, "Right and Select didn't switch")
        print("REAL picked: \(liveCopy()) (\(waitForState(timeout: 20)))")
        shot("picked")
        press(.menu)
    }

    // MARK: Helpers

    private func press(_ button: XCUIRemote.Button) {
        remote.press(button)
        sleep(1)
        print("REAL focus after \(button.rawValue): \(focused())")
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

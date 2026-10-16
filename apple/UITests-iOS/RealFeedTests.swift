import XCTest

/// iPhone on the real feeds: the Emby server and IPTV lineup the app is
/// for, not the test server. The logins come from a helper on this Mac
/// that holds them in memory (TEST_RUNNER_REAL_FEED, its address); skipped
/// without it. Screenshots go to /tmp/openiptv/uitest-real.
final class RealFeedTests: XCTestCase {
    private let app = XCUIApplication()
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
        // The viewer's own account: playing reports nothing to the server,
        // so where they are in a title stays as it was.
        app.launchArguments = ["-readOnlyServer", "YES", "-cacheFolder", "real"]
        XCUIDevice.shared.orientation = .portrait
    }

    /// Home fills in from the server, and a title from it plays.
    func testHomePlaysATitle() throws {
        // Emby only: no IPTV requests the test doesn't need.
        app.launchEnvironment["OPENREEL_DEBUG_IPTV_URL"] = nil
        app.launch()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'row-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 45), "Home has no rows")
        shot("home")
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "no Continue Watching card to play")
        print("REAL playing: \(card.label)")
        card.tap()
        // The title's page (or the player at once): Play.
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Resume' OR label BEGINSWITH 'Continue'")).firstMatch
        let readout = app.staticTexts["debug-position"].firstMatch
        let deadline = Date().addingTimeInterval(20)
        while !readout.exists, Date() < deadline {
            if play.exists, play.isHittable { play.tap(); break }
            usleep(250_000)
        }
        // Started: the position moves on from where it opened.
        let first = try XCTUnwrap(waitForPosition(timeout: 20), "the player didn't open")
        let opened = Date()
        var moving: Date?
        while moving == nil, Date().timeIntervalSince(opened) < 60 {
            if let now = position(), now > first + 0.5 { moving = Date() }
            usleep(500_000)
        }
        let start = try XCTUnwrap(moving, "the title didn't start in 60 s").timeIntervalSince(opened)
        print("REAL title started \(String(format: "%.1f", start)) s after the player opened")
        let at = position() ?? 0
        sleep(6)
        let later = position() ?? 0
        shot("playing")
        XCTAssertGreaterThan(later, at + 3, "the title doesn't play on (\(at) → \(later))")
    }

    /// A live game on several channels: it starts on one, Watch On lists
    /// them all, another picked plays, and it plays first the next time.
    func testLiveGameWatchOn() throws {
        app.launchArguments += ["-forgetWatchOnPicks", "YES", "-freshLineup", "YES"]
        app.launch()
        let tab = app.tabBars.buttons["Live TV"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "no Live TV tab")
        tab.tap()
        let sports = app.buttons["Sports"].firstMatch
        XCTAssertTrue(sports.waitForExistence(timeout: 90), "the lineup has no Sports")
        sports.tap()
        let games = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Started'"))
        XCTAssertTrue(games.firstMatch.waitForExistence(timeout: 60), "no game on now")
        shot("sports")

        // The first live game that plays and is shown on more than one
        // channel (a game long started can be over: none of its play).
        var title: String?
        var started = ""
        for index in 0..<min(games.count, 12) {
            let game = games.element(boundBy: index)
            guard game.isHittable else { continue }
            let label = game.label
            game.tap()
            _ = waitForCopy(timeout: 10)
            let state = waitForState(timeout: 25)
            showControls()
            let offered = app.buttons["Watch On"].firstMatch.waitForExistence(timeout: 2)
            print("REAL tried \(label): \(state), \(offered ? "Watch On" : "one channel")")
            if state == "playing", offered {
                title = label
                started = liveCopy()
                break
            }
            app.buttons["Close player"].firstMatch.tap()
            sleep(1)
        }
        let game = try XCTUnwrap(title, "no live game that plays on more than one channel")
        print("REAL game: \(game)")
        print("REAL first channel: \(started)")

        showControls()
        app.buttons["Watch On"].firstMatch.tap()
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'player.card.'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5), "Watch On listed nothing")
        XCTAssertGreaterThanOrEqual(cards.count, 2, "Watch On has one channel")
        for card in cards.allElementsBoundByIndex { print("REAL choice: \(card.label)") }
        shot("watch on")
        // The others in turn until one plays (an event's feed can be over).
        let others = cards.allElementsBoundByIndex.map(\.label).filter { !$0.contains("Playing") }
        var picked: String?
        for label in others {
            showControls()
            if !cards.firstMatch.exists { app.buttons["Watch On"].firstMatch.tap() }
            let card = cards.matching(NSPredicate(format: "label == %@", label)).firstMatch
            guard card.waitForExistence(timeout: 5) else { continue }
            let before = liveCopy()
            card.tap()
            let deadline = Date().addingTimeInterval(10)
            while liveCopy() == before, Date() < deadline { usleep(250_000) }
            XCTAssertNotEqual(liveCopy(), before, "picking \(label) didn't switch")
            let state = waitForState(timeout: 20)
            print("REAL picked \(label): \(state) (\(liveCopy()))")
            if state == "playing" {
                picked = liveCopy()
                break
            }
        }
        let pick = try XCTUnwrap(picked, "no other channel played")
        shot("picked")
        // Every other one over or failing: the app fell back to the first.
        guard pick != started else {
            print("REAL no other channel played; the app fell back to \(pick)")
            return
        }

        showControls()
        app.buttons["Close player"].firstMatch.tap()
        let again = app.buttons.matching(NSPredicate(format: "label == %@", game)).firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 10), "the game left the list")
        again.tap()
        XCTAssertEqual(waitForCopy(timeout: 10), pick, "the league's pick didn't play first")
        XCTAssertEqual(waitForState(timeout: 30), "playing", "the pick didn't start the second time")
        shot("pick first")
    }

    /// Dragon Ball Z: two copies on the server (720p with English sound;
    /// 1080p with a Spanish dub first, then Japanese) and no country. It
    /// plays the English copy; the audio menu offers Spanish from the other
    /// one, and Spanish picked takes over with no picture loading.
    func testDragonBallZInEnglish() throws {
        app.launchEnvironment["OPENREEL_DEBUG_IPTV_URL"] = nil
        app.launchArguments += ["-debugSearch", "Dragon Ball Z", "-forgetTrackChoices", "YES"]
        app.launch()
        let tab = app.tabBars.buttons["Search"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "no Search tab")
        tab.tap()
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Dragon Ball Z,' OR label == 'Dragon Ball Z'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30), "no Dragon Ball Z in the results")
        result.tap()
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Resume' OR label BEGINSWITH 'Continue'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 20), "the show's page has no Play")
        play.tap()
        XCTAssertNotNil(waitForPosition(timeout: 45), "the episode didn't open")
        sleep(4)
        let item = app.staticTexts["debug-item"].firstMatch
        let tracks = app.staticTexts["debug-tracks"].firstMatch
        print("REAL Dragon Ball Z: item \(item.label), \(tracks.label)")
        XCTAssertEqual(item.label, "6327691", "not the copy with English sound")
        XCTAssertTrue(tracks.label.hasPrefix("audio=eng"), "not in English: \(tracks.label)")

        showControls()
        app.buttons["Audio and Subtitles"].firstMatch.tap()
        let spanish = app.buttons["Spanish"].firstMatch
        XCTAssertTrue(spanish.waitForExistence(timeout: 5), "no Spanish in the menu")
        shot("dragon ball z audio menu")
        spanish.tap()
        let loading = app.descendants(matching: .any)["Loading"]
        var loaded = false
        let deadline = Date().addingTimeInterval(45)
        while item.label == "6327691", Date() < deadline {
            if loading.exists { loaded = true }
            usleep(100_000)
        }
        print("REAL switched to \(item.label), start \(app.staticTexts["debug-start"].firstMatch.label)")
        XCTAssertEqual(item.label, "7085005", "the Spanish copy didn't take over")
        XCTAssertFalse(loaded, "the picture loaded while the audio switched")
        shot("dragon ball z spanish")
    }

    // MARK: Helpers

    private func liveCopy() -> String {
        let readout = app.staticTexts["debug-live-copy"].firstMatch
        return readout.exists ? readout.label : ""
    }

    private func waitForCopy(timeout: TimeInterval) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while liveCopy().isEmpty, Date() < deadline { usleep(250_000) }
        return liveCopy()
    }

    /// "playing", "failed", or "starting" when it hadn't by then.
    private func waitForState(timeout: TimeInterval) -> String {
        let readout = app.staticTexts["debug-live-state"].firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if readout.exists, readout.label != "starting" { return readout.label }
            usleep(500_000)
        }
        return readout.exists ? readout.label : "no player"
    }

    /// The film player's second, from its debug readout ("72.4 playing").
    private func position() -> Double? {
        let readout = app.staticTexts["debug-position"].firstMatch
        guard readout.exists else { return nil }
        return readout.label.split(separator: " ").first.flatMap { Double($0) }
    }

    private func waitForPosition(timeout: TimeInterval) -> Double? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let seconds = position(), seconds > 0 { return seconds }
            usleep(500_000)
        }
        return nil
    }

    private func showControls() {
        guard !app.buttons["Close player"].firstMatch.exists else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        _ = app.buttons["Close player"].firstMatch.waitForExistence(timeout: 3)
    }

    private func shot(_ note: String) {
        step += 1
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let test = name.split(separator: " ").last.map { String($0.dropLast()) } ?? "test"
        let file = "\(test)-" + String(format: "%02d", step) + "-\(note.replacingOccurrences(of: " ", with: "-")).png"
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: file))
    }
}

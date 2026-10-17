import XCTest

/// iPhone: a game listed by several services (the test server's
/// `sports=1`: one NFL game from NFL, ESPN Unlimited in English and
/// Spanish, DAZN CA in English and French). Run with `xcodebuild test
/// -scheme OpenIPTV` on an iPhone simulator signed in to the test server
/// (scripts/mock_server.py) through TEST_RUNNER_DEBUG_EMBY.
final class LiveSportsTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        if let account = ProcessInfo.processInfo.environment["DEBUG_EMBY"] {
            app.launchEnvironment["OPENREEL_DEBUG_EMBY"] = account
        }
        // The test server's channels too (its test login, for this run).
        if let server = testServer() {
            app.launchEnvironment["OPENREEL_DEBUG_IPTV"] = #"{"id":"6F9A1E52-0000-4000-8000-000000000001","name":"Test","kind":"#
                + #"{"xtream":{"server":"\#(server.absoluteString)","username":"u","password":"p"}}}"#
        }
        XCUIDevice.shared.orientation = .portrait
    }

    /// The game plays on the best channel at once (the main commentary,
    /// as listed first); Watch On lists all five with their language, and
    /// one picked plays and comes first for the league's games after.
    func testGameOnSeveralChannelsOffersWatchOn() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1", "dead_live": "none"])
        addTeardownBlock { [self] in configure(server, ["sports": "0"]) }
        app.launchArguments = ["-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        openGame()
        XCTAssertTrue(playing("NFL 01"), "the game didn't start on the best channel: \(liveCopy())")

        showControls()
        let watchOn = app.buttons["Watch On"].firstMatch
        XCTAssertTrue(watchOn.waitForExistence(timeout: 5), "no Watch On for a game on five channels")
        watchOn.tap()
        let choices = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'player.card.'"))
        XCTAssertTrue(choices.firstMatch.waitForExistence(timeout: 5), "Watch On listed nothing")
        XCTAssertEqual(choices.count, 5, "not every channel showing the game")
        XCTAssertTrue(choices.matching(NSPredicate(format: "label BEGINSWITH 'NFL' AND label CONTAINS 'Playing'")).firstMatch.exists,
                      "the channel playing isn't marked")
        XCTAssertTrue(choices.matching(NSPredicate(format: "label BEGINSWITH 'DAZN CA' AND label CONTAINS 'French'")).firstMatch.exists,
                      "the French feed doesn't say so")
        let spanish = choices.matching(NSPredicate(format: "label BEGINSWITH 'ESPN Unlimited' AND label CONTAINS 'Spanish'")).firstMatch
        XCTAssertTrue(spanish.exists, "the Spanish feed doesn't say so")
        spanish.tap()
        XCTAssertTrue(playing("ESPN UNLTD 016"), "the channel picked didn't open: \(liveCopy())")
        XCTAssertTrue(started(), "the channel picked didn't play")

        // The league's next game (this one again): the pick plays first.
        showControls()
        app.buttons["Close player"].firstMatch.tap()
        openGame()
        XCTAssertTrue(playing("ESPN UNLTD 016"), "the league's pick didn't play first: \(liveCopy())")
    }

    /// Regression: a channel picked in Watch On that never started (an
    /// event feed that was over) was remembered for the league, so the
    /// league's next game opened on it and hung.
    func testFeedThatNeverStartsIsNotRemembered() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1", "dead_live": "2003"])
        addTeardownBlock { [self] in configure(server, ["sports": "0", "dead_live": "none"]) }
        app.launchArguments = ["-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        openGame()
        XCTAssertTrue(playing("NFL 01"), "the game didn't start on the best channel: \(liveCopy())")
        showControls()
        app.buttons["Watch On"].firstMatch.tap()
        let spanish = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'player.card.' AND label CONTAINS 'Spanish'")).firstMatch
        XCTAssertTrue(spanish.waitForExistence(timeout: 5), "no Spanish feed in Watch On")
        spanish.tap()
        XCTAssertTrue(playing("ESPN UNLTD 016"), "the channel picked didn't open: \(liveCopy())")
        sleep(6)
        XCTAssertEqual(app.staticTexts["debug-live-state"].firstMatch.label, "starting", "the dead feed played")

        showControls()
        app.buttons["Close player"].firstMatch.tap()
        openGame()
        XCTAssertTrue(playing("NFL 01"), "the feed that never started was tried first: \(liveCopy())")
    }

    /// A game's best channel that never sends a picture (its feed over, the
    /// slot still listed) gives way to another channel showing the game
    /// after the start limit (shortened to 5 s here). Regression: the user's
    /// game said LIVE and spun forever.
    func testDeadChannelGivesWayToAnother() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1", "dead_live": "2001"])
        addTeardownBlock { [self] in configure(server, ["sports": "0", "dead_live": "none"]) }
        app.launchEnvironment["OPENREEL_DEBUG_LIVE_START_LIMIT"] = "5"
        app.launchArguments = ["-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        openGame()
        XCTAssertTrue(playing("NFL 01"), "the game didn't open on the best channel: \(liveCopy())")
        let readout = app.staticTexts["debug-live-copy"].firstMatch
        let deadline = Date().addingTimeInterval(20)
        while readout.label.hasPrefix("NFL 01"), Date() < deadline { usleep(250_000) }
        XCTAssertFalse(readout.label.hasPrefix("NFL 01"), "still waiting on the channel that sends nothing")
        XCTAssertTrue(started(), "the next channel didn't play: \(liveCopy())")
    }

    /// No channel of the game sends a picture: after trying each, the player
    /// says the game isn't playing, instead of spinning forever, and its row
    /// in Sports says so too instead of LIVE.
    func testGameNotPlayingSaysSo() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1", "dead_live": "2001,2002,2003,2004,2005"])
        addTeardownBlock { [self] in configure(server, ["sports": "0", "dead_live": "none"]) }
        app.launchEnvironment["OPENREEL_DEBUG_LIVE_START_LIMIT"] = "3"
        app.launchArguments = ["-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        openGame()
        let state = app.staticTexts["debug-live-state"].firstMatch
        let deadline = Date().addingTimeInterval(40)
        while state.label != "failed", Date() < deadline { usleep(250_000) }
        XCTAssertEqual(state.label, "failed", "still trying after every channel: \(liveCopy())")
        let note = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'playing right now'")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 3), "no word that the game isn't playing")

        // Back in Sports, the game no longer says LIVE: it says it isn't
        // playing (for half an hour; it's tried again when opened).
        showControls()
        app.buttons["Close player"].firstMatch.tap()
        let game = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Jaguars'")).firstMatch
        XCTAssertTrue(game.waitForExistence(timeout: 10), "the game left Sports")
        XCTAssertFalse(game.label.contains("LIVE"), "still LIVE after no channel played: \(game.label)")
        XCTAssertTrue(game.label.contains("Not playing"), "no word on the row that it isn't playing: \(game.label)")
    }

    /// A game that started longer ago than such a game lasts (an NFL game
    /// 3 h 50 min ago, 3 h 45 min being its length) no longer says LIVE: it's
    /// under "Earlier today".
    /// Regression: the user's soccer game, started three hours before, was
    /// listed LIVE and didn't play.
    func testGameLongStartedIsntLive() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1", "sports_started": "230"])
        addTeardownBlock { [self] in configure(server, ["sports": "0", "sports_started": "20"]) }
        app.launchArguments = ["-freshLineup", "YES"]
        app.launch()
        let tab = app.tabBars.buttons["Live TV"].firstMatch
        if tab.waitForExistence(timeout: 10) { tab.tap() }
        let sports = app.buttons["Sports"].firstMatch
        if sports.waitForExistence(timeout: 10) { sports.tap() }
        let game = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Jaguars'")).firstMatch
        XCTAssertTrue(game.waitForExistence(timeout: 15), "the game isn't in Sports")
        XCTAssertFalse(game.label.contains("LIVE"), "a game 3 h 50 min in still says LIVE: \(game.label)")
        XCTAssertTrue(app.staticTexts["Earlier today"].firstMatch.exists, "no Earlier today section")
        XCTAssertFalse(app.staticTexts["Live now"].firstMatch.exists, "a game 3 h 50 min in is under Live now")
    }

    /// A game that starts in three hours, its channels stamped in the
    /// provider's Eastern time as real event channels are ("(2026-10-17
    /// 12:00:05)"), isn't LIVE yet. Regression: the stamp was read as UTC,
    /// so noon games were LIVE from 8 AM, and didn't play (the user: "a lot
    /// of channels don't play").
    func testGameLaterTodayIsntLive() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1", "sports_started": "-180"])
        addTeardownBlock { [self] in configure(server, ["sports": "0", "sports_started": "20"]) }
        app.launchArguments = ["-freshLineup", "YES"]
        app.launch()
        let tab = app.tabBars.buttons["Live TV"].firstMatch
        if tab.waitForExistence(timeout: 10) { tab.tap() }
        let sports = app.buttons["Sports"].firstMatch
        if sports.waitForExistence(timeout: 10) { sports.tap() }
        let game = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Jaguars'")).firstMatch
        XCTAssertTrue(game.waitForExistence(timeout: 15), "the game isn't in Sports")
        XCTAssertFalse(game.label.contains("LIVE"), "a game three hours away says LIVE: \(game.label)")
        XCTAssertFalse(app.staticTexts["Live now"].firstMatch.exists, "a game three hours away is under Live now")
    }

    /// A game's row says how many channels show it, and a long press on it
    /// lists them (Watch On, as in the player); the one picked plays.
    /// Regression: when Watch On would be there was a guess (the user:
    /// "I don't know when we get Watch On versus no Watch On"), and there
    /// was no long press.
    func testLongPressListsTheGamesChannels() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1", "dead_live": "none"])
        addTeardownBlock { [self] in configure(server, ["sports": "0"]) }
        app.launchArguments = ["-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        let tab = app.tabBars.buttons["Live TV"].firstMatch
        if tab.waitForExistence(timeout: 10) { tab.tap() }
        let sports = app.buttons["Sports"].firstMatch
        if sports.waitForExistence(timeout: 10) { sports.tap() }
        let game = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Jaguars'")).firstMatch
        XCTAssertTrue(game.waitForExistence(timeout: 15), "the game isn't in Sports")
        XCTAssertTrue(game.label.contains("5 channels"), "the row doesn't say how many channels: \(game.label)")
        game.press(forDuration: 1.2)
        // In the order they'd play: NFL, ESPN Unlimited and DAZN CA in
        // English, then ESPN Unlimited in Spanish and DAZN CA in French (the
        // language is each item's second line).
        let espn = app.buttons.matching(NSPredicate(format: "label == 'ESPN Unlimited'"))
        XCTAssertTrue(espn.firstMatch.waitForExistence(timeout: 5),
                      "no channels on a long press: \(app.buttons.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }.prefix(20))")
        XCTAssertEqual(espn.count, 2, "not both ESPN Unlimited feeds")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == 'DAZN CA'")).count, 2, "not both DAZN CA feeds")
        XCTAssertTrue(app.buttons["NFL"].firstMatch.exists, "no NFL channel")
        espn.element(boundBy: 1).tap()
        XCTAssertTrue(playing("ESPN UNLTD 016"), "the channel picked didn't play: \(liveCopy())")
    }

    /// One feed listed in two slots of a sport's own category ("Football /
    /// Soccer: … ( OneSoccer Feed )" twice, as the user saw): one entry in
    /// Watch On, named by the network with the category under it, and
    /// counted once on the game's row. Regression: two identical entries
    /// "Football · Soccer, OneSoccer Feed".
    func testSameFeedOnTwoChannelsIsOneEntry() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1", "sports_dupes": "1", "dead_live": "none"])
        addTeardownBlock { [self] in configure(server, ["sports": "0", "sports_dupes": "0"]) }
        app.launchArguments = ["-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        let tab = app.tabBars.buttons["Live TV"].firstMatch
        if tab.waitForExistence(timeout: 10) { tab.tap() }
        let sports = app.buttons["Sports"].firstMatch
        if sports.waitForExistence(timeout: 10) { sports.tap() }
        let game = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Jaguars'")).firstMatch
        XCTAssertTrue(game.waitForExistence(timeout: 15), "the game isn't in Sports")
        XCTAssertTrue(game.label.contains("6 channels"), "the same feed counted twice: \(game.label)")
        game.tap()
        XCTAssertTrue(playing("NFL 01"), "the game didn't start: \(liveCopy())")
        showControls()
        app.buttons["Watch On"].firstMatch.tap()
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'player.card.'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5), "Watch On listed nothing")
        XCTAssertEqual(cards.count, 6, "the same feed listed twice: \(cards.allElementsBoundByIndex.map(\.label))")
        let soccer = cards.matching(NSPredicate(format: "label BEGINSWITH 'OneSoccer' AND label CONTAINS 'Football · Soccer'"))
        XCTAssertEqual(soccer.count, 1, "not one OneSoccer entry: \(cards.allElementsBoundByIndex.map(\.label))")
    }

    /// A game found playing on none of its channels says so on every
    /// device: the app opened afresh (as another device, nothing of this
    /// one's kept) shows its row "Not playing" from the app's record on the
    /// server. Regression: only the device that tried it knew.
    func testNotPlayingIsSharedAcrossDevices() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["reset": "1"])
        configure(server, ["sports": "1", "dead_live": "2001,2002,2003,2004,2005"])
        addTeardownBlock { [self] in configure(server, ["reset": "1"]) }
        app.launchEnvironment["OPENREEL_DEBUG_LIVE_START_LIMIT"] = "3"
        app.launchArguments = ["-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        openGame()
        let state = app.staticTexts["debug-live-state"].firstMatch
        let deadline = Date().addingTimeInterval(40)
        while state.label != "failed", Date() < deadline { usleep(250_000) }
        XCTAssertEqual(state.label, "failed", "still trying after every channel")
        sleep(2)
        app.terminate()

        // Another device: a fresh start, the server's record only.
        app.launch()
        let tab = app.tabBars.buttons["Live TV"].firstMatch
        if tab.waitForExistence(timeout: 10) { tab.tap() }
        let sports = app.buttons["Sports"].firstMatch
        if sports.waitForExistence(timeout: 10) { sports.tap() }
        let game = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Jaguars'")).firstMatch
        XCTAssertTrue(game.waitForExistence(timeout: 15), "the game isn't in Sports")
        let shown = Date().addingTimeInterval(10)
        while !game.label.contains("Not playing"), Date() < shown { usleep(250_000) }
        XCTAssertTrue(game.label.contains("Not playing"), "the other device's finding isn't shown: \(game.label)")
    }

    /// Live TV → Sports → the game.
    private func openGame() {
        let tab = app.tabBars.buttons["Live TV"].firstMatch
        if tab.waitForExistence(timeout: 10) { tab.tap() }
        let sports = app.buttons["Sports"].firstMatch
        if sports.waitForExistence(timeout: 10) { sports.tap() }
        let game = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Jaguars'")).firstMatch
        XCTAssertTrue(game.waitForExistence(timeout: 15), "the game isn't in Sports")
        game.tap()
    }

    /// The live player shows a picture within 15 s.
    private func started() -> Bool {
        let readout = app.staticTexts["debug-live-state"].firstMatch
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if readout.exists, readout.label == "playing" { return true }
            usleep(250_000)
        }
        return false
    }

    private func liveCopy() -> String {
        app.staticTexts["debug-live-copy"].firstMatch.label
    }

    /// The channel open in the player starts with `name`, within 10 s.
    private func playing(_ name: String) -> Bool {
        let readout = app.staticTexts["debug-live-copy"].firstMatch
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if readout.exists, readout.label.hasPrefix(name) { return true }
            usleep(250_000)
        }
        return false
    }

    private func showControls() {
        guard !app.buttons["Close player"].firstMatch.exists else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        _ = app.buttons["Close player"].firstMatch.waitForExistence(timeout: 3)
    }

    private func testServer() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["DEBUG_EMBY"],
              let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let address = json["serverURL"] as? String else { return nil }
        return URL(string: address)
    }

    /// Sets the test server's behaviour (scripts/mock_server.py, /mock/set).
    private func configure(_ server: URL, _ settings: [String: String]) {
        let url = server.appending(path: "mock/set").appending(queryItems: settings.map { URLQueryItem(name: $0.key, value: $0.value) })
        // A semaphore, not an expectation: it runs in tear-down too.
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 10)
    }
}

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
        configure(server, ["sports": "1"])
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

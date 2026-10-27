import XCTest

/// The timing tests' app (perf/eval.sh): on the test server (TEST_RUNNER_DEBUG_EMBY), or on the feeds a helper
/// on this Mac hands out (TEST_RUNNER_REAL_FEED, its address: the logins stay in it, and the app reports
/// nothing to the server). Films only: no IPTV lineup, whose Account Info channels spell out a login.
class TimingCase: XCTestCase {
    let app = XCUIApplication()
    /// Every launch's arguments come after these.
    private(set) var launchBase: [String] = []
    var onRealFeeds: Bool { ProcessInfo.processInfo.environment["REAL_FEED"] != nil }

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        let environment = ProcessInfo.processInfo.environment
        if let feed = environment["REAL_FEED"].flatMap(URL.init(string:)) {
            app.launchEnvironment["OPENREEL_DEBUG_EMBY_URL"] = feed.appending(path: "emby").absoluteString
            launchBase = ["-readOnlyServer", "YES", "-cacheFolder", environment["REAL_FEED_CACHE"] ?? "real"]
        } else if let account = environment["DEBUG_EMBY"] {
            app.launchEnvironment["OPENREEL_DEBUG_EMBY"] = account
        }
        if let options = environment["MPV_EXTRA"] {
            app.launchEnvironment["OPENREEL_DEBUG_MPV"] = options
        }
        XCUIDevice.shared.orientation = .portrait
    }

    /// A film playing to its first frame: the test server's "Animals" from Search, or Continue Watching's first
    /// card on the real feeds. Seconds from the tap, nil when no first frame in 180 s.
    func openFilm(_ arguments: [String] = []) -> Double? {
        app.launchArguments = launchBase + (onRealFeeds ? [] : ["-debugSearch", "animals"]) + arguments
        app.launch()
        if onRealFeeds {
            let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-'")).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 90), "no Continue Watching card")
            sleep(3)
            card.tap()
        } else {
            sleep(4)
            app.tabBars.buttons["Search"].firstMatch.tap()
            let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Animals' AND NOT label BEGINSWITH 'Animals.'")).firstMatch
            XCTAssertTrue(result.waitForExistence(timeout: 20), "no search result")
            result.tap()
            let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Resume' OR label BEGINSWITH 'Continue'")).firstMatch
            if !play.waitForExistence(timeout: 10), result.exists { result.tap() }
            XCTAssertTrue(play.waitForExistence(timeout: 10), "no play button")
            play.tap()
        }
        let tapped = Date()
        let start = app.staticTexts["debug-start"].firstMatch
        while Date().timeIntervalSince(tapped) < 180, (start.exists ? start.label.split(separator: " ").count : 0) < 4 { sleep(1) }
        guard start.exists, start.label.split(separator: " ").count == 4 else { return nil }
        return Date().timeIntervalSince(tapped)
    }
}

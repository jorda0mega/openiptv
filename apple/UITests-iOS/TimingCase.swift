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
    /// card on the real feeds or with START_FROM=card (tapped once fetched ahead, at most 30 s: the kept player
    /// a viewer's tap takes). Seconds from the tap, nil when no first frame in 180 s; then the app's own reason
    /// is printed (START none: ...).
    func openFilm(_ arguments: [String] = []) -> Double? {
        let fromCard = onRealFeeds || ProcessInfo.processInfo.environment["START_FROM"] == "card"
        app.launchArguments = launchBase + (fromCard ? [] : ["-debugSearch", "animals"]) + arguments
        app.launch()
        if fromCard {
            let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-'")).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 90), "no Continue Watching card")
            let began = Date()
            while Date().timeIntervalSince(began) < 30, !fetchedAhead() { sleep(1) }
            let ahead = app.staticTexts["debug-ahead"].firstMatch
            print("START card after \(Int(Date().timeIntervalSince(began))) s: \(ahead.exists ? ahead.label.replacingOccurrences(of: " | ", with: "; ") : "no readout")")
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
        let start = app.staticTexts["debug-start"].firstMatch, failed = app.staticTexts["debug-start-error"].firstMatch
        while Date().timeIntervalSince(tapped) < 180, (start.exists ? start.label.split(separator: " ").count : 0) < 4,
              !(failed.exists && !failed.label.isEmpty) { sleep(1) }
        guard start.exists, start.label.split(separator: " ").count == 4 else {
            print(String(format: "START none after %.0f s", Date().timeIntervalSince(tapped)))
            sayWhyNoStart()
            return nil
        }
        return Date().timeIntervalSince(tapped)
    }

    /// Continue Watching's first card's plan and start fetched ahead ("plans 1 starts 1").
    func fetchedAhead() -> Bool {
        let readout = app.staticTexts["debug-ahead"].firstMatch
        let words = readout.exists ? readout.label.split(separator: " ") : []
        func count(_ name: String) -> Int { words.firstIndex(of: Substring(name)).flatMap { Int(words[$0 + 1]) } ?? 0 }
        return count("plans") > 0 && count("starts") > 0
    }

    /// No first frame: what the app shows and says instead (words and counts only).
    func sayWhyNoStart() {
        func text(_ id: String) -> String {
            let element = app.descendants(matching: .any)[id].firstMatch
            // On the real feeds only whether it shows: its words can name the film.
            return element.exists ? (element.label.isEmpty || onRealFeeds ? "shown" : element.label) : "none"
        }
        let alert = app.alerts.firstMatch
        let error = app.staticTexts["debug-start-error"].firstMatch
        let message = error.exists && !error.label.isEmpty ? String(error.label.prefix(80)).replacingOccurrences(of: "://", with: " ") : "none"
        print("START none: player \(app.staticTexts["debug-item"].firstMatch.exists ? "open" : "not open") | alert \(alert.exists ? "shown" : "none") | "
              + "error \(message) | loading \(text("load-progress")) | parts \(text("debug-start-parts").replacingOccurrences(of: " | ", with: "; "))")
    }
}

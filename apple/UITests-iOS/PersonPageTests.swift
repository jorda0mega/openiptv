import XCTest

/// iPhone: a film's Cast & Crew opens a person's page with their titles.
final class PersonPageTests: XCTestCase {
    private let app = XCUIApplication()
    private let shots = URL(fileURLWithPath: "/tmp/openiptv/uitest-ios")

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        if let account = ProcessInfo.processInfo.environment["DEBUG_EMBY"] {
            app.launchEnvironment["OPENREEL_DEBUG_EMBY"] = account
        }
    }

    private func shot(_ name: String) {
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: "person-\(name).png"))
    }

    func testCastOpensPersonPage() {
        openPerson()
        let titles = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Zorro'"))
        XCTAssertGreaterThanOrEqual(titles.count, 2, "their films aren't listed")
    }

    /// The server failing: the page says so and offers Try Again, which
    /// lists the titles. Regression: it said "Nothing with … in your
    /// library", as if there were none.
    func testCastPageRetries() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["fail": "persons"])
        defer { configure(server, ["reset": "1"]) }
        openPerson()
        shot("failed")
        let retry = app.buttons["Try Again"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 5), "no Try Again when the server failed")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Nothing with'")).firstMatch.exists,
                       "said there was nothing in the library")
        configure(server, ["reset": "1"])
        retry.tap()
        sleep(3)
        shot("retried")
        let titles = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Zorro'"))
        XCTAssertGreaterThanOrEqual(titles.count, 2, "Try Again didn't list their films")
    }

    /// A film opened from Home: a More Like This film opens its page.
    /// Regression: the tap did nothing (Home's stack had no film route).
    func testMoreLikeThisFromHome() {
        app.launch()
        sleep(6)
        let dune = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Dune: Part Two'")).firstMatch
        for _ in 0..<5 where !dune.isHittable { app.swipeUp(); sleep(1) }
        XCTAssertTrue(dune.isHittable, "no Dune: Part Two on Home")
        dune.tap()
        sleep(3)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '2024'")).firstMatch.exists, "Dune's page didn't open")
        let similar = app.buttons["Inception"].firstMatch
        for _ in 0..<5 where !similar.isHittable { app.swipeUp(); sleep(1) }
        XCTAssertTrue(similar.isHittable, "no Inception in More Like This")
        similar.tap()
        sleep(3)
        shot("more-like-this")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '2010'")).firstMatch.exists,
                      "Inception's page didn't open from More Like This")
    }

    /// A show's page lists Specials after its seasons, as in the Apple TV
    /// app. Regression: it opened on Specials, its seasons far below.
    func testSpecialsLast() {
        app.launchArguments = ["-debugSearch", "forensic"]
        app.launch()
        sleep(4)
        let tab = app.tabBars.buttons["Search"].firstMatch
        (tab.exists ? tab : app.buttons["Search"].firstMatch).tap()
        sleep(3)
        let show = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Forensic Files'")).firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 8), "no search result")
        show.tap()
        sleep(3)
        shot("show")
        let seasons = app.buttons.matching(NSPredicate(format: "label == 'Specials' OR label BEGINSWITH 'Season '")).allElementsBoundByIndex
            .sorted { $0.frame.minX < $1.frame.minX }.map(\.label)
        XCTAssertGreaterThan(seasons.count, 1, "no season tabs: \(seasons)")
        XCTAssertEqual(seasons.last, "Specials", "Specials isn't last: \(seasons)")
    }

    /// A show's episodes are all the same height, Up Next's too.
    /// Regression: its "UP NEXT" line made it 2 points taller, so the list
    /// moved when Up Next did.
    func testEpisodeRowsSameHeight() {
        openForensicFiles()
        for _ in 0..<3 { app.swipeUp(); sleep(1) }
        shot("episodes")
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Case '")).allElementsBoundByIndex
            .filter { $0.frame.height > 40 }
        let heights = Set(rows.map { Int(($0.frame.height * 2).rounded()) })
        XCTAssertGreaterThan(rows.count, 3, "no episode rows")
        XCTAssertEqual(heights.count, 1, "episode rows differ in height: \(rows.map { "\($0.label.prefix(20)) \($0.frame.height)" })")
    }

    /// The main button keeps its width while the episode starts (a slow
    /// server). Regression: its label turned into "Starting…", narrower.
    func testMainButtonKeepsWidthWhileStarting() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        openForensicFiles()
        let main = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Continue'")).firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 5), "no Continue button")
        let before = main.frame.width
        configure(server, ["latency": "3"])
        defer { configure(server, ["reset": "1"]) }
        main.tap()
        let during = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Continue'")).firstMatch
        XCTAssertTrue(during.exists, "the button's label changed while starting")
        XCTAssertEqual(during.frame.width, before, accuracy: 0.5, "the button changed width while starting")
        shot("starting")
    }

    /// Forensic Files' page, from Search.
    private func openForensicFiles() {
        app.launchArguments = ["-debugSearch", "forensic"]
        app.launch()
        sleep(4)
        let tab = app.tabBars.buttons["Search"].firstMatch
        (tab.exists ? tab : app.buttons["Search"].firstMatch).tap()
        sleep(3)
        let show = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Forensic Files'")).firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 8), "no search result")
        show.tap()
        sleep(3)
    }

    /// Antonio Banderas's page, from The Mask of Zorro's Cast & Crew.
    private func openPerson() {
        app.launchArguments = ["-debugSearch", "zorro"]
        app.launch()
        sleep(4)
        app.tabBars.buttons["Search"].firstMatch.tap()
        sleep(3)
        let film = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'The Mask of Zorro'")).firstMatch
        XCTAssertTrue(film.waitForExistence(timeout: 8), "no search result")
        film.tap()
        sleep(2)
        let actor = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Antonio Banderas'")).firstMatch
        for _ in 0..<4 where !actor.isHittable { app.swipeUp() }
        XCTAssertTrue(actor.waitForExistence(timeout: 5), "no cast member")
        shot("film-cast")
        actor.tap()
        sleep(3)
        shot("page")
        XCTAssertTrue(app.staticTexts["Antonio Banderas"].exists, "no person page")
    }

    private func testServer() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["DEBUG_EMBY"],
              let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let address = json["serverURL"] as? String else { return nil }
        return URL(string: address)
    }

    /// Sets how the test server behaves (see CONTROL in mock_server.py).
    private func configure(_ server: URL, _ settings: [String: String]) {
        let url = server.appending(path: "mock/set").appending(queryItems: settings.map { URLQueryItem(name: $0.key, value: $0.value) })
        let done = expectation(description: "configure")
        URLSession.shared.dataTask(with: url) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
    }
}

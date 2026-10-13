import XCTest

/// iPhone: Search doesn't jump. The server's part of a search (cast
/// checks, people named, episodes) comes late here
/// (OPENREEL_DEBUG_SEARCH_DELAY), so the page can be read before and after
/// it: nothing listed may move or go, and "No Results" may not show before
/// the search has finished. The header (the title and the filters) stays
/// put while the results scroll. Run with `xcodebuild test -scheme
/// OpenIPTV` on an iPhone simulator signed in to the test server
/// (scripts/mock_server.py) through TEST_RUNNER_DEBUG_EMBY; screenshots go
/// to /tmp/openiptv/uitest-agent.
final class SearchStabilityTests: XCTestCase {
    private let app = XCUIApplication()
    private let shots = URL(fileURLWithPath: "/tmp/openiptv/uitest-agent")
    private var step = 0

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        if let account = ProcessInfo.processInfo.environment["DEBUG_EMBY"] {
            app.launchEnvironment["OPENREEL_DEBUG_EMBY"] = account
        }
        app.launchEnvironment["OPENREEL_DEBUG_SEARCH_DELAY"] = "4"
        XCUIDevice.shared.orientation = .portrait
    }

    /// "zorro antonio": the titles named Zorro wait for a cast check (the
    /// server's), so the device lists none of them first; when the server
    /// answers, the two with Antonio Banderas come. Then one more letter:
    /// they stay where they are while that search runs.
    func testResultsStayPutWhenServerAnswers() {
        openSearch("zorro antonio")
        sleep(1)
        let local = results()
        shot("search local")
        XCTAssertFalse(noResultsShown(), "No Results before the server answered")
        // Regression: nothing at all showed while the server worked.
        XCTAssertTrue(searchingShown(), "nothing said the search was still running")
        sleep(6)
        let answered = results()
        XCTAssertFalse(searchingShown(), "Searching… stayed after the server answered")
        shot("search answered")
        XCTAssertEqual(differences(local, answered).filter { !$0.hasPrefix("new ") }, [],
                       "results listed before the server answered moved or went")
        XCTAssertNotNil(answered["More for The Mask of Zorro"], "the server's cast match didn't come")

        // One more letter: the last results stay put until it's answered.
        let field = app.searchFields.firstMatch
        field.tap()
        field.typeText(" b")
        sleep(1)
        let typing = results()
        shot("search next letter")
        XCTAssertFalse(noResultsShown(), "No Results while the next letter's search ran")
        XCTAssertEqual(differences(answered, typing), [], "results moved or went while the next letter's search ran")
        sleep(6)
        shot("search next letter answered")
        XCTAssertFalse(results().isEmpty, "nothing for “zorro antonio b”")
    }

    /// One bar at the bottom while searching, as in the Apple TV app: the
    /// search field in the tab bar (with a Home button), not a field of our
    /// own stacked over the whole tab bar.
    func testOneBarAtTheBottom() {
        openSearch("zorro")
        sleep(3)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.exists, "no search field")
        XCTAssertGreaterThan(field.frame.minY, app.frame.height * 0.8, "the search field isn't at the bottom: \(field.frame)")
        XCTAssertFalse(app.tabBars.buttons["Live TV"].firstMatch.isHittable, "the whole tab bar shows under the search field")
    }

    /// The header (title and filters) stays exactly where it is while the
    /// results scroll up and down, pull past the top, and when the query is
    /// cleared.
    func testHeaderStaysFixed() {
        openSearch("movie")
        sleep(6)
        let start = header()
        let firstResult = results()["More for Movie 0"]
        shot("header start")
        XCTAssertEqual(start.count, 5, "header parts missing: \(start.keys.sorted())")
        XCTAssertNotNil(firstResult, "no results for “movie”")
        drag(from: 0.7, to: 0.3)
        sleep(1)
        shot("header scrolled")
        XCTAssertNotEqual(results()["More for Movie 0"], firstResult, "the results didn't scroll")
        XCTAssertEqual(differences(start, header()), [], "the header moved as the results scrolled")
        drag(from: 0.3, to: 0.7)
        drag(from: 0.3, to: 0.7)
        sleep(1)
        XCTAssertEqual(differences(start, header()), [], "the header moved as the results scrolled back")
        // Past the top and held a moment, then let go.
        drag(from: 0.35, to: 0.8, hold: 1)
        shot("header after pull")
        XCTAssertEqual(differences(start, header()), [], "the header moved with the pull")
        sleep(1)
        XCTAssertEqual(differences(start, header()), [], "the header moved after the pull")
        XCTAssertEqual(results()["More for Movie 0"], firstResult, "the results didn't come back to the top")
        app.searchFields.firstMatch.buttons.firstMatch.tap()
        sleep(1)
        shot("header cleared")
        XCTAssertEqual(differences(start, header()), [], "the header changed when the query was cleared")
    }

    /// A finger drag down the middle of the screen, between heights given
    /// as fractions of it.
    private func drag(from: Double, to: Double, hold: TimeInterval = 0) {
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)),
                   withVelocity: .default, thenHoldForDuration: hold)
    }

    // MARK: Helpers

    private func openSearch(_ text: String) {
        app.launchArguments = ["-debugSearch", text]
        app.launch()
        sleep(3)
        app.tabBars.buttons["Search"].firstMatch.tap()
    }

    /// The results listed (each one's picture button), with their frames.
    /// Each result row by its "More for <title>" button (the row's own
    /// button is labelled with the title alone, like other buttons).
    private func results() -> [String: CGRect] {
        frames { $0.elementType == .button && $0.label.hasPrefix("More for ") }
    }

    /// The header's parts: the title, the filters, and the whole.
    private func header() -> [String: CGRect] {
        frames { ["search-title", "search-header", "scope-All", "scope-Movies", "scope-Live TV"].contains($0.identifier) }
    }

    /// "Searching…" on the page.
    private func searchingShown() -> Bool {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Searching…'")).firstMatch.exists
    }

    private func noResultsShown() -> Bool {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'No Results'")).firstMatch.exists
    }

    /// Elements matching `wanted` (by id, else label) with their frames,
    /// read in one go.
    private func frames(_ wanted: (XCUIElementSnapshot) -> Bool) -> [String: CGRect] {
        guard let root = try? app.snapshot() else { return [:] }
        var found: [String: CGRect] = [:]
        func walk(_ element: XCUIElementSnapshot) {
            if wanted(element), !element.frame.isEmpty {
                let name = element.identifier.isEmpty ? element.label : element.identifier
                if found[name] == nil { found[name] = element.frame }
            }
            element.children.forEach(walk)
        }
        walk(root)
        return found
    }

    /// What appeared, went or moved between two readings.
    private func differences(_ a: [String: CGRect], _ b: [String: CGRect]) -> [String] {
        Set(a.keys).union(b.keys).sorted().compactMap { key in
            switch (a[key], b[key]) {
            case let (x?, y?) where abs(x.minX - y.minX) > 0.5 || abs(x.minY - y.minY) > 0.5
                || abs(x.width - y.width) > 0.5 || abs(x.height - y.height) > 0.5:
                "moved \(key): \(x) → \(y)"
            case (_?, nil): "gone \(key)"
            case (nil, _?): "new \(key)"
            default: nil
            }
        }
    }

    private func shot(_ note: String) {
        step += 1
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let name = String(format: "ios-%02d-%@.png", step, note.replacingOccurrences(of: " ", with: "-"))
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: name))
        print("SHOT \(note) → \(name)")
    }
}

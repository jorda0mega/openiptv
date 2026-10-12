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
        sleep(6)
        let answered = results()
        shot("search answered")
        XCTAssertEqual(differences(local, answered).filter { !$0.hasPrefix("new ") }, [],
                       "results listed before the server answered moved or went")
        XCTAssertNotNil(answered["Play The Mask of Zorro"], "the server's cast match didn't come")

        // One more letter: the last results stay put until it's answered.
        let field = app.textFields.firstMatch
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

    /// The header (title and filters) stays exactly where it is while the
    /// results scroll up and down, pull past the top, and when the query is
    /// cleared.
    func testHeaderStaysFixed() {
        openSearch("movie")
        sleep(6)
        let list = app.collectionViews.firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5), "no results list")
        let start = header()
        shot("header start")
        XCTAssertEqual(start.count, 5, "header parts missing: \(start.keys.sorted())")
        list.swipeUp()
        sleep(1)
        shot("header scrolled")
        XCTAssertEqual(differences(start, header()), [], "the header moved as the results scrolled")
        list.swipeDown()
        sleep(1)
        // Past the top and held a moment, then let go.
        let top = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        top.press(forDuration: 0.05, thenDragTo: list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8)),
                  withVelocity: .slow, thenHoldForDuration: 0.5)
        shot("header after pull")
        XCTAssertEqual(differences(start, header()), [], "the header moved with the pull")
        sleep(1)
        XCTAssertEqual(differences(start, header()), [], "the header moved after the pull")
        app.buttons["Clear search"].firstMatch.tap()
        sleep(1)
        shot("header cleared")
        XCTAssertEqual(differences(start, header()), [], "the header changed when the query was cleared")
    }

    // MARK: Helpers

    private func openSearch(_ text: String) {
        app.launchArguments = ["-debugSearch", text]
        app.launch()
        sleep(3)
        app.tabBars.buttons["Search"].firstMatch.tap()
    }

    /// The results listed (each one's picture button), with their frames.
    private func results() -> [String: CGRect] {
        frames { $0.elementType == .button && $0.label.hasPrefix("Play ") }
    }

    /// The header's parts: the title, the filters, and the whole.
    private func header() -> [String: CGRect] {
        frames { ["search-title", "search-header", "scope-All", "scope-Movies", "scope-Live TV"].contains($0.identifier) }
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

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

    /// Nothing typed: the library's genres as tiles, three across, as in
    /// the Apple TV app; a tile opens its genre's titles.
    func testGenreTiles() {
        openSearch("")
        sleep(3)
        let tiles = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'genre-'")).allElementsBoundByIndex
            .sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
        shot("genre tiles")
        XCTAssertGreaterThanOrEqual(tiles.count, 6, "no genre tiles")
        // A different title on each tile. Regression: a title in two
        // genres (Drama and Crime, say) was on both tiles.
        let posters = tiles.compactMap { $0.value as? String }
        XCTAssertEqual(Set(posters).count, posters.count, "a title is on two tiles: \(zip(tiles.map(\.label), posters).map { "\($0)=\($1)" })")
        guard tiles.count >= 3 else { return }
        XCTAssertEqual(tiles[0].frame.minY, tiles[2].frame.minY, accuracy: 1, "not three across")
        XCTAssertEqual(tiles[0].frame.height / tiles[0].frame.width, 1.5, accuracy: 0.05, "not poster-shaped")
        let name = tiles[0].label
        tiles[0].tap()
        sleep(2)
        shot("genre page")
        XCTAssertTrue(app.navigationBars[name].exists || app.staticTexts[name].exists, "no \(name) page")
        // The test library's most common genre is Adventure (the Zorro films).
        let titles = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Zorro'"))
        XCTAssertGreaterThanOrEqual(titles.count, 2, "the \(name) page doesn't list its titles")
        // The tiles and the page came from the genres worked out in the
        // background: no scan of the whole catalog on the main thread.
        // Regression: each drawing of a genre page scanned and sorted every
        // title there (129,000 on the user's server).
        let scans = app.staticTexts["debug-genre-scans"].firstMatch
        XCTAssertTrue(scans.waitForExistence(timeout: 3), "no genre scan count")
        XCTAssertEqual(scans.label, "0", "the genres were worked out on the main thread \(scans.label) times")
    }

    /// The chosen scope (All, Movies, …) in a white pill with black words,
    /// as everywhere else in the app. Regression: a blue pill.
    func testScopePillIsWhite() {
        openSearch("zorro")
        sleep(3)
        let all = app.buttons["scope-All"].firstMatch
        XCTAssertTrue(all.exists, "no scope bar")
        shot("scope pill")
        // Inside the pill, left of its word.
        let point = CGPoint(x: all.frame.minX + 6, y: all.frame.midY)
        let shot = XCUIScreen.main.screenshot().image
        guard let image = shot.cgImage, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            return XCTFail("no screenshot")
        }
        let scale = CGFloat(image.width) / shot.size.width
        let i = Int(point.y * scale) * image.bytesPerRow + Int(point.x * scale) * (image.bitsPerPixel / 8)
        let (a, b, c) = (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
        XCTAssertGreaterThan(min(a, b, c), 200, "the chosen scope's pill isn't white: \(a), \(b), \(c)")
    }

    /// A filter tap moves the pill first: it starts sliding in the tap's own
    /// frame, without dropping frames, and the results change after it
    /// starts. Regression: the results changed first and the pill waited 2–3
    /// frames for them, then skipped 5–8 of its frames. A UI test only sees
    /// where the pill ends, so run this under scripts/frame-audit/record.sh:
    /// it writes where the pills and the results are for
    /// scripts/frame-audit/filter_pill.py, which checks the film frame by
    /// frame (it fails on the old pill).
    func testFilterPillMovesFirst() throws {
        openSearch("movie")
        sleep(4)
        let all = app.buttons["scope-All"].firstMatch
        let header = app.otherElements["search-header"].firstMatch
        XCTAssertTrue(all.exists, "no scope bar")
        XCTAssertNotNil(results()["More for Movie 0"], "no results for “movie”")
        let geometry: [String: Any] = [
            "width": app.frame.width, "height": app.frame.height,
            "pills": [all.frame.minY, all.frame.maxY], "results": header.frame.maxY,
        ]
        try FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: geometry).write(to: shots.appending(path: "filter-geometry.json"))
        let listed = ["All": "Movies & Shows", "Movies": "Movies", "Shows": "No shows or episodes", "Live TV": "No channels"]
        for name in ["Movies", "Shows", "Live TV", "All", "Movies", "All"] {
            let filter = app.buttons["scope-\(name)"].firstMatch
            filter.tap()
            sleep(1)
            XCTAssertTrue(filter.isSelected, "\(name) isn't the chosen filter after its tap")
            XCTAssertTrue(app.staticTexts[listed[name]!].exists, "the list didn't follow the tap on \(name): no “\(listed[name]!)”")
        }
    }

    /// VoiceOver finds the chosen filter, not the pill behind it.
    /// Regression: the pill was an element of its own, with no name, where
    /// the chosen filter is.
    func testPillIsHiddenFromVoiceOver() {
        openSearch("movie")
        sleep(3)
        let chosen = app.buttons["scope-All"].firstMatch.frame
        let parts = app.otherElements["search-header"].firstMatch.descendants(matching: .any).allElementsBoundByIndex
        let pill = parts.filter { part in
            part.identifier.isEmpty && part.label.isEmpty
                && abs(part.frame.minX - chosen.minX) < 1 && abs(part.frame.width - chosen.width) < 1
        }
        XCTAssertTrue(app.buttons["scope-All"].exists, "no filters")
        XCTAssertEqual(pill.map(\.frame), [], "the pill behind “All” is an element of its own")
    }

    /// What's on TV doesn't hold up the rest, and doesn't push it down: with
    /// the guide's answer late, the channels for "channel 1" are listed at
    /// once; when the answer comes with the list scrolled down, the rows
    /// being read stay put, and "On TV" (above the channels) is listed once
    /// the list is back at the top. Regression: the results waited up to
    /// 100 ms for the guide, and a late answer pushed the rows down.
    func testGuideNeitherHoldsUpNorPushesResults() throws {
        addTestChannels(try XCTUnwrap(testServer(), "no test server"))
        app.launchEnvironment["OPENREEL_DEBUG_GUIDE_DELAY"] = "8"
        openSearch("channel")
        sleep(2)
        let field = app.searchFields.firstMatch
        field.tap()
        field.typeText(" 1\n")
        let timing = app.staticTexts["debug-search-local-ms"].firstMatch
        let timed = expectation(for: NSPredicate(format: "label BEGINSWITH 'channel 1|'"), evaluatedWith: timing)
        XCTAssertEqual(XCTWaiter().wait(for: [timed], timeout: 3), .completed, "no time for “channel 1”: \(timing.label)")
        let took = Int(timing.label.split(separator: "|").last ?? "") ?? .max
        XCTAssertLessThan(took, 90, "the results took \(took) ms: they waited for the guide")
        XCTAssertGreaterThanOrEqual(channelRows().count, 5, "the channels waited for the guide")
        XCTAssertFalse(app.staticTexts["On TV"].exists, "On TV before the guide answered")
        let top = channelRows()
        drag(from: 0.7, to: 0.4)
        sleep(1)
        let scrolled = channelRows()
        shot("guide scrolled")
        XCTAssertFalse(scrolled.isEmpty, "no channels on screen after scrolling")
        XCTAssertNotEqual(scrolled, top, "the list didn't scroll")
        XCTAssertFalse(app.staticTexts["On TV"].exists, "On TV before the guide answered")
        sleep(6)
        shot("guide answered")
        XCTAssertEqual(differences(scrolled, channelRows()), [], "the guide's answer moved the rows being read")
        drag(from: 0.3, to: 0.8)
        sleep(1)
        shot("guide at top")
        XCTAssertTrue(app.staticTexts["On TV"].exists, "On TV isn't listed back at the top")
    }

    /// The library growing while the results are scrolled (a big library's
    /// pages still arriving after launch) doesn't move the rows being read;
    /// the titles it adds are listed once the list is back at the top.
    /// Regression: each batch of pages ran the search again and put the new
    /// titles above the rows on screen, pushing them down.
    func testLibraryGrowingLeavesAScrolledListAlone() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["library_hold": "1"])
        addTeardownBlock { [self] in configure(server, ["library_hold": "0"]) }
        addTestChannels(server)
        openSearch("13", arguments: ["-freshLibrary", "YES"])
        sleep(6)
        XCTAssertTrue(libraryTitles().isEmpty, "the library's titles were in before its pages")
        // A little way down: the server's "Movie 13" at the top, the guide's
        // rows under it.
        drag(from: 0.6, to: 0.53, hold: 0.5, velocity: .slow)
        sleep(1)
        let scrolled = rows()
        shot("library scrolled")
        XCTAssertFalse(scrolled.isEmpty, "nothing on screen for “13”")
        configure(server, ["library_hold": "0"])
        sleep(6)
        shot("library grown")
        XCTAssertEqual(differences(scrolled, rows()), [], "the library's new pages moved the rows being read")
        for _ in 0..<3 { drag(from: 0.3, to: 0.8) }
        sleep(1)
        shot("library at top")
        XCTAssertFalse(libraryTitles().isEmpty, "the library's titles aren't listed back at the top")
    }

    /// Titles only the library index has (the test server's search finds
    /// "Movie 13", not these).
    private func libraryTitles() -> [String: CGRect] {
        results().filter { $0.key.hasPrefix("More for Library Title") }
    }

    /// Opening Search with nothing typed brings up the keyboard at once, in
    /// the search field. Regression: no keyboard until the next touch (6 s
    /// and more).
    func testKeyboardComesUpWhenSearchOpens() {
        openSearch("")
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 1), "no keyboard 1 s after Search opened")
        XCTAssertEqual(app.searchFields.firstMatch.value(forKey: "hasKeyboardFocus") as? Bool, true,
                       "the search field doesn't have the keyboard")
        shot("search opened")
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
    private func drag(from: Double, to: Double, hold: TimeInterval = 0, velocity: XCUIGestureVelocity = .default) {
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)),
                   withVelocity: velocity, thenHoldForDuration: hold)
    }

    // MARK: Helpers

    private func openSearch(_ text: String, arguments: [String] = []) {
        app.launchArguments = ["-debugSearch", text] + arguments
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

    /// The channel rows listed, by channel, with their frames: "CH, Show
    /// 17-4, 10m left · Channel 17" (the guide's rows say when, not what's
    /// left).
    private func channelRows() -> [String: CGRect] {
        rows { $0.contains(" left · Channel ") }
    }

    /// Every row of the list on screen, named by the words in it, with its
    /// frame. What changes by itself is left out (a channel's "12m left", a
    /// programme's progress); rows with the same words are kept apart
    /// ("words #2").
    private func rows(where wanted: (String) -> Bool = { _ in true }) -> [String: CGRect] {
        guard let root = try? app.snapshot() else { return [:] }
        var found: [String: CGRect] = [:]
        func words(_ element: XCUIElementSnapshot) -> [String] {
            let own = [.staticText, .button].contains(element.elementType) ? [element.label] : []
            return (own + element.children.flatMap(words)).filter { !$0.isEmpty }
        }
        func walk(_ element: XCUIElementSnapshot) {
            guard element.elementType != .cell else {
                let all = words(element).joined(separator: " | ")
                let name = all.replacingOccurrences(of: #"(\d+h )?\d+m left|\d+%"#, with: "", options: .regularExpression)
                guard !all.isEmpty, wanted(all), !element.frame.isEmpty else { return }
                var key = name
                var copy = 1
                while found[key] != nil { copy += 1; key = "\(name) #\(copy)" }
                found[key] = element.frame
                return
            }
            element.children.forEach(walk)
        }
        walk(root)
        return found
    }

    /// The test server's channels and guide too (its test login, for this run).
    private func addTestChannels(_ server: URL) {
        app.launchEnvironment["OPENREEL_DEBUG_IPTV"] = #"{"id":"6F9A1E52-0000-4000-8000-000000000001","name":"Test","kind":"#
            + #"{"xtream":{"server":"\#(server.absoluteString)","username":"u","password":"p"}}}"#
    }

    /// Sets how the test server behaves (see CONTROL in mock_server.py).
    private func configure(_ server: URL, _ settings: [String: String]) {
        let url = server.appending(path: "mock/set").appending(queryItems: settings.map { URLQueryItem(name: $0.key, value: $0.value) })
        let done = expectation(description: "configure")
        URLSession.shared.dataTask(with: url) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
    }

    private func testServer() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["DEBUG_EMBY"],
              let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let address = json["serverURL"] as? String else { return nil }
        return URL(string: address)
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

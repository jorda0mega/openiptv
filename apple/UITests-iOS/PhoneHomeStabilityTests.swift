import XCTest

/// iPhone: Home doesn't change while you look at it, like Netflix's. The
/// app runs with OPENREEL_DEBUG_HOME_VARY: each Home built comes with its
/// cards in another order and its number after each row's name, so a build
/// put on the page under your eyes would move things. The test server then
/// says the library changed and something was watched: the rows must stay
/// exactly as they were until Home is chosen again in the tab bar, or
/// pulled down to refresh. Run with `xcodebuild test -scheme OpenIPTV` on
/// an iPhone simulator signed in to the test server (scripts/mock_server.py)
/// through TEST_RUNNER_DEBUG_EMBY; screenshots go to /tmp/openiptv/uitest-agent.
final class PhoneHomeStabilityTests: XCTestCase {
    private let app = XCUIApplication()
    private let shots = URL(fileURLWithPath: "/tmp/openiptv/uitest-agent")
    private var step = 0

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        if let account = ProcessInfo.processInfo.environment["DEBUG_EMBY"] {
            app.launchEnvironment["OPENREEL_DEBUG_EMBY"] = account
        }
        app.launchEnvironment["OPENREEL_DEBUG_HOME_VARY"] = "1"
        XCUIDevice.shared.orientation = .portrait
    }

    func testHomeStaysPutUntilChosenAgainOrPulled() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        app.launch()
        // Past the first seconds after a launch, when a build may still go
        // straight on the page.
        sleep(10)
        // Down to the rows, so they're all on screen together.
        drag(from: 0.75, to: 0.35)
        sleep(2)
        let before = rows()
        shot("home before")
        let numbers = rowNumbers(before)
        XCTAssertFalse(numbers.isEmpty, "no numbered rows on Home: \(before.keys.sorted())")

        // Regression: the show's card moving to its next episode (watched
        // elsewhere) replaced the card on screen; it must wait too.
        configure(server, ["resume_episode": "4"])
        defer { configure(server, ["reset": "1"]) }
        push(server, "library")
        push(server, "watched")
        sleep(18)
        let after = rows()
        shot("home after changes")
        let moved = differences(before, after)
        XCTAssertEqual(moved, [], "Home changed while on screen:\n" + moved.joined(separator: "\n"))

        // Home chosen again in the tab bar (back at the top, where it's
        // full size): the Home built meanwhile goes on.
        for _ in 0..<3 { drag(from: 0.3, to: 0.8) }
        sleep(1)
        // Still small after the scroll: a tap on it opens it out.
        if !app.tabBars.buttons["Live TV"].exists {
            app.tabBars.buttons.firstMatch.tap()
            sleep(1)
        }
        shot("tab bar")
        app.tabBars.buttons["Live TV"].firstMatch.tap()
        sleep(2)
        app.tabBars.buttons["Home"].firstMatch.tap()
        sleep(2)
        let again = rowNumbers(rows())
        shot("home chosen again")
        XCTAssertNotEqual(again, numbers, "the Home built meanwhile didn't go on when Home was chosen again")
        let nextEpisode = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Case 4'")).firstMatch
        XCTAssertTrue(nextEpisode.exists, "the show's next episode didn't go on when Home was chosen again: \(app.buttons.allElementsBoundByIndex.map(\.label).filter { $0.contains("Case") })")

        // Back to the top, then pulled down: built afresh and shown.
        for _ in 0..<4 { drag(from: 0.3, to: 0.8) }
        drag(from: 0.3, to: 0.9, hold: 1)
        sleep(8)
        drag(from: 0.75, to: 0.35)
        sleep(2)
        shot("home after pull")
        XCTAssertNotEqual(rowNumbers(rows()), again, "pulling down didn't refresh Home")
    }

    /// A launch is a moment Home may change: the first Home built goes on
    /// the page, however long the server takes, if it hasn't been touched.
    /// Regression: a build taking more than five seconds waited, unseen,
    /// until another tab was chosen.
    func testSlowFirstBuildStillShows() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        app.launch()
        sleep(10)
        app.terminate()
        // Saved Home old (every row built again), and the server slow.
        configure(server, ["home_delay": "9"])
        defer { configure(server, ["reset": "1"]) }
        app.launchEnvironment["OPENREEL_DEBUG_HOME_STALE"] = "1"
        app.launch()
        sleep(2)
        let saved = pageNumbers()
        shot("slow launch saved")
        XCTAssertFalse(saved.isEmpty, "no numbered rows on the saved Home")
        sleep(20)
        let later = pageNumbers()
        shot("slow launch built")
        XCTAssertFalse(later.isEmpty, "no numbered rows after the build")
        XCTAssertNotEqual(later, saved, "the slow first build never went on the page")
    }

    /// Coming back after a long time away is a moment Home may change (the
    /// Home built meanwhile goes on); a short trip away isn't. Here "long"
    /// is 8 seconds (OPENREEL_DEBUG_LONG_AWAY).
    func testHomeChangesOnlyAfterLongAway() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        app.launchEnvironment["OPENREEL_DEBUG_LONG_AWAY"] = "8"
        app.launch()
        sleep(10)
        let before = pageNumbers()
        XCTAssertFalse(before.isEmpty, "no numbered rows on Home")
        // The library changes: a new Home is built and waits.
        push(server, "library")
        sleep(8)
        XCTAssertEqual(pageNumbers(), before, "Home changed while on screen")
        // A short trip away: still the same Home.
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        sleep(3)
        XCTAssertEqual(pageNumbers(), before, "Home changed after a short time away")
        // A long time away: the Home built meanwhile goes on.
        XCUIDevice.shared.press(.home)
        sleep(10)
        app.activate()
        sleep(4)
        shot("back after long away")
        XCTAssertNotEqual(pageNumbers(), before, "Home didn't change after a long time away")
    }

    /// Signed out while Home is being built: the old account's Home doesn't
    /// come back when the build ends. Regression: it did (rows and pictures
    /// of the account just signed out of).
    func testSignOutWhileHomeLoads() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["home_delay": "10"])
        defer { configure(server, ["reset": "1"]) }
        app.launchEnvironment["OPENREEL_DEBUG_HOME_STALE"] = "1"
        app.launch()
        sleep(2)
        app.buttons["Settings"].firstMatch.tap()
        let emby = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Emby'")).firstMatch
        XCTAssertTrue(emby.waitForExistence(timeout: 3), "no Emby in Settings")
        emby.tap()
        let signOut = app.buttons["Sign out"].firstMatch
        XCTAssertTrue(signOut.waitForExistence(timeout: 3), "no Sign out")
        signOut.tap()
        sleep(1)
        // Back to Settings' first page, then closed.
        let back = app.navigationBars.buttons["Settings"].firstMatch
        if back.exists { back.tap(); sleep(1) }
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 2) { done.tap() } else { app.swipeDown(velocity: .fast) }
        sleep(1)
        shot("signed out")
        XCTAssertFalse(app.staticTexts["Continue Watching"].exists, "Home kept the old account's rows")
        // The build for the old account ends meanwhile.
        sleep(16)
        shot("signed out later")
        XCTAssertFalse(app.staticTexts["Continue Watching"].exists, "the old account's Home came back after signing out")
        XCTAssertTrue(pageNumbers().isEmpty, "the old account's rows came back after signing out")
    }

    /// Home's cards as in the Apple TV app: Continue Watching 240 × 170
    /// (the title and progress inside it), posters 100 × 150, 12 apart.
    func testHomeCardSizes() {
        app.launch()
        sleep(8)
        let heading = app.staticTexts["Continue Watching"].firstMatch
        XCTAssertTrue(heading.exists, "no Continue Watching")
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-'")).firstMatch
        let card: XCUIElement? = first.waitForExistence(timeout: 3) ? first : nil
        XCTAssertNotNil(card, "no Continue Watching card")
        if let card {
            // Its height can't be read (its picture, cut to the card, counts
            // at full size): its words sit inside the card's 170 points,
            // along the bottom.
            XCTAssertEqual(card.frame.width, 240, accuracy: 1, "Continue Watching card: \(card.frame)")
            // Episodes written as in the Apple TV app ("S2, E3").
            let show = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-' AND label CONTAINS 'Case 3'")).firstMatch
            XCTAssertTrue(show.label.contains("S2, E3"), "not \"S2, E3\": \(show.label)")
            // The card starts 12 points under the row's name.
            let top = heading.frame.maxY + 12
            let words = card.staticTexts.allElementsBoundByIndex.map(\.frame)
            XCTAssertFalse(words.isEmpty, "no title or episode on the card")
            for frame in words {
                XCTAssertGreaterThan(frame.minY, top + 110, "the card's words aren't along its bottom: \(frame)")
                XCTAssertLessThan(frame.maxY, top + 170, "the card's words are below the card: \(frame)")
            }
        }
        // The hero's buttons as in the Apple TV app: Play 160 × 48, then a
        // 48-point round button.
        // (Measured on the screen: a button's frame here is its words'.)
        let label = app.buttons["Play"].firstMatch
        XCTAssertTrue(label.exists, "no Play in the hero")
        let capsule = whiteRun(XCUIScreen.main.screenshot(), through: CGPoint(x: label.frame.midX, y: label.frame.midY))
        XCTAssertEqual(capsule.width, 160, accuracy: 3, "hero Play isn't 160 wide: \(capsule)")
        XCTAssertEqual(capsule.height, 48, accuracy: 3, "hero Play isn't 48 tall: \(capsule)")
        drag(from: 0.75, to: 0.35)
        sleep(1)
        let posters = app.buttons.allElementsBoundByIndex.filter { abs($0.frame.width - Layout100.width) < 1 && abs($0.frame.height - Layout100.height) < 1 }
            .sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
        shot("card sizes")
        XCTAssertGreaterThanOrEqual(posters.count, 2, "no 100 × 150 posters")
        if posters.count >= 2, posters[0].frame.minY == posters[1].frame.minY {
            XCTAssertEqual(posters[1].frame.minX - posters[0].frame.maxX, 12, accuracy: 1, "posters aren't 12 apart")
        }
    }

    /// The white area around a point of the screen (in points): how far
    /// white runs across and up and down from it.
    private func whiteRun(_ shot: XCUIScreenshot, through point: CGPoint) -> CGSize {
        guard let image = shot.image.cgImage,
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return .zero }
        let scale = CGFloat(image.width) / app.frame.width
        let perRow = image.bytesPerRow, perPixel = image.bitsPerPixel / 8
        func white(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < image.width, y < image.height else { return false }
            let i = y * perRow + x * perPixel
            return bytes[i] > 235 && bytes[i + 1] > 235 && bytes[i + 2] > 235
        }
        let cx = Int(point.x * scale), cy = Int(point.y * scale)
        // From the middle, past the words (dark), to the capsule's edges.
        var left = cx, right = cx, top = cy, bottom = cy
        while left > 0, (white(left - 1, cy) || left > cx - Int(60 * scale)) { left -= 1; if !white(left, cy) && left < cx - Int(60 * scale) { break } }
        while right < image.width - 1, (white(right + 1, cy) || right < cx + Int(60 * scale)) { right += 1; if !white(right, cy) && right > cx + Int(60 * scale) { break } }
        // Inside the straight part (past the rounded end), before the words.
        let edgeX = left + Int(30 * scale)
        while top > 0, white(edgeX, top - 1) { top -= 1 }
        while bottom < image.height - 1, white(edgeX, bottom + 1) { bottom += 1 }
        return CGSize(width: CGFloat(right - left) / scale, height: CGFloat(bottom - top + 1) / scale)
    }

    /// The bottom of Home's hero is in its picture's colours, as in the
    /// Apple TV app (it faded to black).
    func testHeroArtBand() {
        app.launch()
        sleep(8)
        let width = app.frame.width
        // 10 points above the hero's bottom, at the left (away from the
        // title and buttons).
        let point = CGPoint(x: 16, y: heroBottom() - 10)
        let picture = XCUIScreen.main.screenshot()
        guard let image = picture.image.cgImage, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            return XCTFail("no screenshot")
        }
        let scale = CGFloat(image.width) / width
        let i = Int(point.y * scale) * image.bytesPerRow + Int(point.x * scale) * (image.bitsPerPixel / 8)
        let brightest = max(bytes[i], bytes[i + 1], bytes[i + 2])
        shot("hero band")
        XCTAssertGreaterThan(brightest, 20, "the bottom of the hero is black, not its picture's colours")
    }

    /// Home's hero is about four fifths of the screen, as in the Apple TV
    /// app, with the first row's name in view under it (it was 1.3 times
    /// the width: 60% of an iPhone 17 Pro, half the rows' space lost).
    func testHeroHeight() {
        app.launch()
        sleep(8)
        let screen = app.frame.height
        let hero = heroBottom()
        let heading = app.staticTexts["Continue Watching"].firstMatch
        shot("hero height")
        XCTAssertEqual(hero / screen, 0.78, accuracy: 0.03, "the hero is \(hero) of \(screen) points")
        // Above the tab bar.
        XCTAssertLessThan(heading.frame.maxY, screen - 90, "Continue Watching's name isn't in view under the hero")
    }

    /// Where Home's hero ends: the rows start 30 points under it.
    private func heroBottom() -> CGFloat {
        let heading = app.staticTexts["Continue Watching"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 20), "no Continue Watching")
        return heading.frame.minY - 30
    }

    private enum Layout100 {
        static let width: CGFloat = 100
        static let height: CGFloat = 150
    }

    // MARK: Helpers

    /// Sets how the test server behaves (see CONTROL in mock_server.py).
    private func configure(_ server: URL, _ settings: [String: String]) {
        let url = server.appending(path: "mock/set").appending(queryItems: settings.map { URLQueryItem(name: $0.key, value: $0.value) })
        let done = expectation(description: "configure")
        URLSession.shared.dataTask(with: url) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
    }

    /// The build numbers of the rows on the page, on screen or not
    /// ("Trending now ·12"), without scrolling (which counts as browsing).
    private func pageNumbers() -> Set<String> {
        // In one snapshot: element by element, a heading could go between
        // listing and reading it (Home changing is what's being watched).
        guard let root = try? app.snapshot() else { return [] }
        var headings: [String] = []
        func walk(_ element: XCUIElementSnapshot) {
            if element.elementType == .staticText, element.label.contains("·") { headings.append(element.label) }
            element.children.forEach(walk)
        }
        walk(root)
        return rowNumbers(Dictionary(headings.map { ("text:" + $0, CGRect.zero) }, uniquingKeysWith: { a, _ in a }))
    }

    private func testServer() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["DEBUG_EMBY"],
              let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let address = json["serverURL"] as? String else { return nil }
        return URL(string: address)
    }

    /// Asks the test server to announce a change to connected apps.
    private func push(_ server: URL, _ type: String) {
        let url = server.appending(path: "mock/push").appending(queryItems: [URLQueryItem(name: "type", value: type)])
        let done = expectation(description: "push \(type)")
        URLSession.shared.dataTask(with: url) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
    }

    /// The rows' buttons and texts (from Continue Watching's heading down,
    /// not the hero, which turns by itself) with their frames, read in one go.
    private func rows() -> [String: CGRect] {
        guard let root = try? app.snapshot() else { return [:] }
        var top = CGFloat.infinity
        func findTop(_ element: XCUIElementSnapshot) {
            if element.elementType == .staticText, element.label == "Continue Watching" { top = min(top, element.frame.minY) }
            element.children.forEach(findTop)
        }
        findTop(root)
        var found: [String: CGRect] = [:]
        func walk(_ element: XCUIElementSnapshot) {
            let kind: String? = switch element.elementType {
            case .button: "button"
            case .staticText: "text"
            default: nil
            }
            if let kind, !element.frame.isEmpty, element.frame.minY >= top - 1, element.frame.maxY < app.frame.maxY - 100 {
                let name = element.identifier.isEmpty ? element.label : element.identifier
                if !name.isEmpty, found["\(kind):\(name)"] == nil { found["\(kind):\(name)"] = element.frame }
            }
            element.children.forEach(walk)
        }
        walk(root)
        return found
    }

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

    /// The build numbers after the rows' names ("Trending now ·12").
    private func rowNumbers(_ layout: [String: CGRect]) -> Set<String> {
        Set(layout.keys.compactMap { key -> String? in
            guard key.hasPrefix("text:"), let dot = key.lastIndex(of: "·") else { return nil }
            let number = key[key.index(after: dot)...]
            return !number.isEmpty && number.allSatisfy(\.isNumber) ? String(number) : nil
        })
    }

    /// A finger drag down the middle of the screen, between heights given
    /// as fractions of it.
    private func drag(from: Double, to: Double, hold: TimeInterval = 0) {
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)),
                   withVelocity: .default, thenHoldForDuration: hold)
    }

    private func shot(_ note: String) {
        step += 1
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let name = String(format: "ios-home-%02d-%@.png", step, note.replacingOccurrences(of: " ", with: "-"))
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: name))
        print("SHOT \(note) → \(name)")
    }
}

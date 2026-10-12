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

        // Back to the top, then pulled down: built afresh and shown.
        for _ in 0..<4 { drag(from: 0.3, to: 0.8) }
        drag(from: 0.3, to: 0.9, hold: 1)
        sleep(8)
        drag(from: 0.75, to: 0.35)
        sleep(2)
        shot("home after pull")
        XCTAssertNotEqual(rowNumbers(rows()), again, "pulling down didn't refresh Home")
    }

    // MARK: Helpers

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

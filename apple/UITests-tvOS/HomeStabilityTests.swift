import XCTest

final class HomeStabilityTests: XCTestCase {
    private let app = XCUIApplication()
    private let remote = XCUIRemote.shared
    private let shots = URL(fileURLWithPath: "/tmp/openiptv/uitest-agent")
    private var step = 0

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        if let account = ProcessInfo.processInfo.environment["DEBUG_EMBY"] {
            app.launchEnvironment["OPENREEL_DEBUG_EMBY"] = account
        }
        app.launchEnvironment["OPENREEL_DEBUG_HOME_VARY"] = "1"
    }

    func testHomeStaysPutUntilChosenAgain() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        app.launchArguments = ["-tvTab", "home"]
        app.launch()
        // Past the first seconds after a launch, when a build may still go
        // straight on the page.
        wait(seconds: 10)
        remote.press(.home)
        configure(server, ["added": "z9"])
        sleep(3)
        app.activate()
        wait(seconds: 6)
        // Resting on the hero's Play, as after a launch (it doesn't turn
        // to another title meanwhile).
        for _ in 0..<2 where focusedIsTab() { remote.press(.down); sleep(1) }
        let before = layout()
        shot("home before")
        XCTAssertTrue(before.keys.contains { $0.hasPrefix("button:continue-") }, "no Continue Watching on Home")
        let numbers = rowNumbers(before)
        print("HOME rows \(numbers) cards \(before.count)")
        wait(seconds: 18)
        let after = layout()
        shot("home after changes")
        let moved = differences(before, after)
        XCTAssertEqual(moved, [], "Home changed while on screen:\n" + moved.joined(separator: "\n"))

        // Home chosen again in the tab bar: the Home built meanwhile goes on.
        for _ in 0..<3 where !focusedIsTab() { remote.press(.up); sleep(1) }
        remote.press(.right)
        sleep(3)
        remote.press(.left)
        sleep(3)
        let again = layout()
        shot("home chosen again")
        XCTAssertTrue(again.keys.contains("button:More Info"), "no featured title after coming back")
        if !numbers.isEmpty {
            XCTAssertNotEqual(rowNumbers(again), numbers, "the Home built meanwhile didn't go on when Home was chosen again")
        }
    }

    /// Moving along a row moves only that row: the page doesn't scroll up
    /// or down (the row's heading stays where it is).
    func testMovingAlongARowKeepsThePageStill() {
        app.launchArguments = ["-tvTab", "home"]
        app.launch()
        sleep(8)
        // From the tab bar: down to the hero, to Continue Watching, then
        // to the first row of posters.
        for _ in 0..<4 where !focusedIsTab() { remote.press(.up); sleep(1) }
        for _ in 0..<3 {
            remote.press(.down)
            sleep(1)
            print("FOCUS \(focusedLabel())")
        }
        shot("on posters")
        let heading = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Top picks' OR label BEGINSWITH 'Trending' OR label BEGINSWITH 'New &'")).firstMatch
        XCTAssertTrue(heading.exists, "no row of posters")
        let start = heading.frame
        var seen = [start.minY]
        for step in 1...4 {
            remote.press(.right)
            sleep(1)
            seen.append(heading.frame.minY)
            print("FOCUS \(focusedLabel())")
            shot("right \(step)")
        }
        print("HEADING y \(seen)")
        XCTAssertTrue(seen.allSatisfy { abs($0 - start.minY) < 1 }, "the page scrolled as focus moved along the row: \(seen)")
    }

    func testFailedHomeRecoversByItself() throws {
        let server = try launchWithHomeFailing()
        defer { configure(server, ["reset": "1"]) }
        wait(seconds: 4)
        shot("home error while the server fails")
        configure(server, ["reset": "1"])
        let recovered = secondsUntilContinueWatching(since: Date(), within: 40, "server back")
        shot("home after the server is back")
        let seconds = try XCTUnwrap(recovered, "Home stayed on its error after the server was back")
        XCTAssertLessThan(seconds, 10, "Continue Watching came \(seconds) s after the server was back")
    }

    func testFailedHomeRecoversAtOnceWhenTheAppIsBack() throws {
        let server = try launchWithHomeFailing()
        defer { configure(server, ["reset": "1"]) }
        wait(seconds: 9)
        configure(server, ["reset": "1"])
        remote.press(.home)
        wait(seconds: 2)
        app.activate()
        let recovered = secondsUntilContinueWatching(since: Date(), within: 30, "app back")
        shot("home after the app is back")
        let seconds = try XCTUnwrap(recovered, "Home stayed on its error after the app came back")
        XCTAssertLessThan(seconds, 5, "Continue Watching came \(seconds) s after the app came back")
    }

    // MARK: Helpers

    private func launchWithHomeFailing() throws -> URL {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        configure(server, ["home_status": "502"])
        app.launchEnvironment["OPENREEL_DEBUG_NO_SAVED_HOME"] = "1"
        app.launchArguments = ["-tvTab", "home"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Couldn't load Emby"].waitForExistence(timeout: 30), "Home didn't show its error while the server failed")
        return server
    }

    private func secondsUntilContinueWatching(since start: Date, within timeout: TimeInterval, _ note: String) -> Double? {
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-'")).firstMatch
        guard card.waitForExistence(timeout: timeout) else {
            print("HOMERETRY \(note): no Continue Watching within \(Int(timeout)) s")
            return nil
        }
        let seconds = Date().timeIntervalSince(start)
        print(String(format: "HOMERETRY %@: Continue Watching after %.1f s", note, seconds))
        return seconds
    }

    /// The test server's address, from the account passed in.
    private func testServer() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["DEBUG_EMBY"],
              let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let address = json["serverURL"] as? String else { return nil }
        return URL(string: address)
    }

    private func configure(_ server: URL, _ settings: [String: String]) {
        let url = server.appending(path: "mock/set").appending(queryItems: settings.map { URLQueryItem(name: $0.key, value: $0.value) })
        let done = expectation(description: "configure")
        URLSession.shared.dataTask(with: url) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
    }

    /// Every button and text on screen (by its id, else its label) with
    /// its frame: the page's layout, read in one go. Not the hero's own
    /// texts (above its buttons): it turns to its next title by design
    /// while focus is elsewhere.
    private func layout() -> [String: CGRect] {
        guard let root = try? app.snapshot() else { return [:] }
        var found: [String: CGRect] = [:]
        var heroBottom = -CGFloat.infinity
        func findHero(_ element: XCUIElementSnapshot) {
            if element.elementType == .button, element.label == "More Info" { heroBottom = element.frame.maxY }
            element.children.forEach(findHero)
        }
        findHero(root)
        func walk(_ element: XCUIElementSnapshot) {
            if element.elementType == .staticText, element.frame.maxY <= heroBottom {
                return element.children.forEach(walk)
            }
            let kind: String? = switch element.elementType {
            case .button: "button"
            case .staticText: "text"
            default: nil
            }
            if let kind, !element.frame.isEmpty {
                let name = element.identifier.isEmpty ? element.label : element.identifier
                if !name.isEmpty, found["\(kind):\(name)"] == nil { found["\(kind):\(name)"] = element.frame }
            }
            element.children.forEach(walk)
        }
        walk(root)
        return found
    }

    /// What appeared, went or moved between two layouts.
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

    private func focusedLabel() -> String {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        return element.exists ? element.label : "nothing"
    }

    private func focusedIsTab() -> Bool {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        return element.exists && ["Search", "Home", "Live TV", "Settings"].contains(element.label)
    }

    private func shot(_ note: String) {
        step += 1
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let name = String(format: "tv-%02d-%@.png", step, note.replacingOccurrences(of: " ", with: "-"))
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: name))
        print("SHOT \(note) → \(name)")
    }
}

extension XCTestCase {
    /// Waits while the test runner goes on answering the system. tvOS
    /// stops an app that leaves its screen unanswered for 10 s (0x8BADF00D,
    /// "scene-update watchdog"), and a sleep() of 10 s or more did that to
    /// the runner whenever the system asked it something meanwhile.
    func wait(seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }
}

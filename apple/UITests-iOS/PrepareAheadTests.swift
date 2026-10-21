import XCTest

/// iPhone on the test server (scripts/mock_server.py, signed in through
/// TEST_RUNNER_DEBUG_EMBY): what a title on screen gets ready before a tap,
/// and how soon its subtitles show. Needs the ten-minute two-language film
/// with an English SDH file beside it (TEST_RUNNER_SUBS_TIMING=1).
final class PrepareAheadTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SUBS_TIMING"] != nil, "needs the subtitle timing film")
        if let account = ProcessInfo.processInfo.environment["DEBUG_EMBY"] {
            app.launchEnvironment["OPENREEL_DEBUG_EMBY"] = account
        }
        XCUIDevice.shared.orientation = .portrait
    }

    /// Where a first subtitle pick spends its time, for each kind of track:
    /// the film's own (the server's copy slow to come), the server's copy of
    /// it, and a file beside the film. Prints the player's stopwatch.
    func testSubtitlePickTimes() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        for copyDelay in ["90", "0"] {
            configure(server, ["reset": "1"])
            configure(server, ["reference_delay": copyDelay])
            app.launchArguments = ["-debugSearch", "Oppenheimer", "-forgetTrackChoices", "YES", "-forgetServerSubtitles", "YES",
                                   "-noStreamAhead", "YES"]
            app.launch()
            playFilm("Oppenheimer")
            sleep(8)
            for pick in ["English", "Off", "English SDH", "Spanish"] {
                print("PREP subs copies \(copyDelay) s slow, pick \(pick): " + timePick(pick))
            }
            print("PREP subs copies \(copyDelay) s slow, all: " + app.staticTexts["debug-subs-timing"].firstMatch.label)
            app.terminate()
        }
        configure(server, ["reset": "1"])
    }

    private func playFilm(_ film: String) {
        let tab = app.tabBars.buttons["Search"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "no Search tab")
        tab.tap()
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", film)).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30), "no \(film) in the results")
        result.tap()
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Resume' OR label BEGINSWITH 'Continue'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 20), "the film's page has no Play")
        play.tap()
        XCTAssertTrue(app.staticTexts["debug-position"].firstMatch.waitForExistence(timeout: 30), "the film didn't open")
    }

    /// One pick in the menu: its switch, its first line (up to 20 s) and any
    /// stall after it, from the player's stopwatch.
    private func timePick(_ label: String) -> String {
        let before = events("switch").count
        let menu = subtitleMenu()
        guard let entry = menu.first(where: { $0.label == label }) else { return "not in the menu (\(menu.map(\.label)))" }
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: entry.frame.midX, dy: entry.frame.midY)).tap()
        var picked: String?
        for _ in 0..<20 where picked == nil {
            usleep(250_000)
            picked = events("switch").dropFirst(before).last
        }
        guard let picked, let n = field("n", in: picked) else { return "no switch" }
        var shown: String?
        for _ in 0..<80 where shown == nil && label != "Off" {
            usleep(250_000)
            shown = events("shown").first { field("n", in: $0) == n }
        }
        sleep(2)
        let stalls = events("rebuffer").filter { field("n", in: $0) == n }
        return ([picked, label == "Off" ? "off" : shown ?? "no line in 20 s"] + (stalls.isEmpty ? ["no rebuffer"] : stalls))
            .joined(separator: " ; ")
    }

    private func events(_ name: String) -> [String] {
        app.staticTexts["debug-subs-timing"].firstMatch.label.components(separatedBy: " | ").filter { $0.hasPrefix(name + " ") }
    }

    private func field(_ key: String, in line: String) -> String? {
        line.split(separator: " ").first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
    }

    /// The Audio and Subtitles menu, opened: Off, then each subtitle track
    /// under it, read from one snapshot (the menu is built again when a
    /// track arrives).
    private func subtitleMenu() -> [(label: String, frame: CGRect)] {
        let button = app.buttons["Audio and Subtitles"].firstMatch
        for _ in 0..<3 {
            let entries = subtitleMenuEntries()
            if !entries.isEmpty { return entries }
            showControls()
            if button.waitForExistence(timeout: 2) { button.tap() }
            _ = app.buttons["Off"].firstMatch.waitForExistence(timeout: 3)
        }
        return subtitleMenuEntries()
    }

    private func subtitleMenuEntries() -> [(label: String, frame: CGRect)] {
        guard let screen = try? app.snapshot() else { return [] }
        var buttons: [XCUIElementSnapshot] = []
        func collect(_ element: XCUIElementSnapshot) {
            if element.elementType == .button { buttons.append(element) }
            element.children.forEach(collect)
        }
        collect(screen)
        guard let off = buttons.first(where: { $0.label == "Off" || $0.identifier == "Off" })?.frame else { return [] }
        let entries = buttons.filter { $0.frame.minY > off.minY && abs($0.frame.minX - off.minX) < 1 && abs($0.frame.width - off.width) < 1 }
            .sorted { $0.frame.minY < $1.frame.minY }
        return [("Off", off)] + entries.map { ($0.label, $0.frame) }
    }

    private func showControls() {
        guard !app.buttons["Close player"].firstMatch.isHittable else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        _ = app.buttons["Close player"].firstMatch.waitForExistence(timeout: 3)
    }

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
}

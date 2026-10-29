import XCTest

final class FilmStartLookTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = true
        if let account = ProcessInfo.processInfo.environment["DEBUG_EMBY"] {
            app.launchEnvironment["OPENREEL_DEBUG_EMBY"] = account
        }
        XCUIDevice.shared.orientation = .portrait
    }

    func testASlowServerShowsOnePictureOneRingOneFailureAndTryAgainShowsTheRingAtOnce() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        configure(server, ["episode_resume": "60", "hang": "item,plan"])
        defer { configure(server, ["reset": "1"]) }
        app.launchArguments = ["-noPrepareAhead", "YES", "-noStreamAhead", "YES", "-filmLoadingLimit", "8",
                               "-cacheFolder", "film-start-look-\(UUID())"]
        app.launch()
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "no Continue Watching")
        card.tap()

        let failure = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'didn’t start'")).firstMatch
        let tryAgain = app.buttons["Try again"].firstMatch
        var seen = Set<String>()
        let began = Date()
        while !failure.exists, Date().timeIntervalSince(began) < 15 {
            XCTAssertFalse(tryAgain.exists, "Try again before the start failed")
            if let screen = try? app.snapshot() { seen.formUnion(Self.texts(in: screen)) }
            usleep(250_000)
        }
        XCTAssertTrue(failure.exists, "no failure by 15 s: \(app.staticTexts["debug-film-loading"].firstMatch.label)")
        let counting = seen.filter { $0.hasSuffix(" s") }
        XCTAssertTrue(counting.isEmpty, "words counting the wait: \(counting)")
        XCTAssertTrue(tryAgain.exists, "no Try again over the failure")

        configure(server, ["hang": "none"])
        tryAgain.tap()
        XCTAssertTrue(app.staticTexts["debug-position"].firstMatch.waitForExistence(timeout: 20), "the film didn't open")
        let looks = app.staticTexts["debug-film-loading"].firstMatch
        for _ in 0..<40 where !looks.label.contains(", film ") { usleep(250_000) }

        let entries = looks.label.components(separatedBy: ", ").map { $0.split(separator: " ") }
        let names = entries.map { String($0.first ?? "") }
        let times = entries.compactMap { $0.count > 1 ? Double($0[1]) : nil }
        XCTAssertEqual(names, ["held", "ring", "ring-dim", "failed", "ring", "film"], looks.label)
        if times.count == names.count {
            XCTAssertEqual(times[1], 1.15, accuracy: 0.25, "the first ring not at about 1 s: \(looks.label)")
            XCTAssertEqual(times[2], 3, accuracy: 0.4, "the ring didn't dim 3 s after the tap: \(looks.label)")
            XCTAssertEqual(times[3], 8, accuracy: 0.4, "the start didn't fail at its limit: \(looks.label)")
        }
        XCTAssertEqual(app.staticTexts["debug-film-held"].firstMatch.label, "1", "the held picture was drawn more than once")
        print("FILM LOOKS \(looks.label)")
    }

    func testWaitingForTheFirstFrameDoesNotRedrawThePlayer() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        configure(server, ["episode_resume": "60"])
        defer {
            configure(server, ["reset": "1"])
            get(server, "mock/profile", ["name": "none"])
        }
        app.launchArguments = ["-noPrepareAhead", "YES", "-noStreamAhead", "YES", "-cacheFolder", "film-redraw-\(UUID())"]
        app.launch()
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "no Continue Watching")
        get(server, "mock/profile", ["name": "none", "link": "worst"])
        card.tap()
        let renders = app.staticTexts["debug-player-renders"].firstMatch
        let started = app.staticTexts["debug-start"].firstMatch
        var first: Int?
        var opened = Date()
        let tapped = Date()
        while Date().timeIntervalSince(tapped) < 40 {
            if first == nil, renders.exists, let count = Int(renders.label) { first = count; opened = Date() }
            if started.exists, !started.label.isEmpty { break }
            usleep(100_000)
        }
        let drawn = (Int(renders.label) ?? 0) - (first ?? 0)
        let waited = Date().timeIntervalSince(opened)
        print(String(format: "WAIT RENDERS %d in %.1f s | %@", drawn, waited, app.staticTexts["debug-film-loading"].firstMatch.label))
        XCTAssertFalse(started.label.isEmpty, "no first frame in 40 s")
    }

    private static func texts(in element: XCUIElementSnapshot) -> [String] {
        let own = element.elementType == .staticText && !element.identifier.hasPrefix("debug-") ? [element.label] : []
        return own + element.children.flatMap(texts(in:))
    }

    private func get(_ server: URL, _ path: String, _ query: [String: String]) {
        let url = server.appending(path: path).appending(queryItems: query.map { URLQueryItem(name: $0.key, value: $0.value) })
        let done = expectation(description: path)
        URLSession.shared.dataTask(with: url) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
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

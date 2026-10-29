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
        try failsAtTheLimitThenPlays(limit: 8)
    }

    func testTheReleaseLimitStopsAHungStartAt30SecondsAndTryAgainPlaysIt() throws {
        try failsAtTheLimitThenPlays(limit: nil)
    }

    private func failsAtTheLimitThenPlays(limit: Double?) throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        configure(server, ["episode_resume": "60", "hang": "item,plan"])
        defer { configure(server, ["reset": "1"]) }
        let failsAt = limit ?? 30
        app.launchArguments = ["-noPrepareAhead", "YES", "-noStreamAhead", "YES", "-cacheFolder", "film-start-look-\(UUID())"]
            + (limit.map { ["-filmLoadingLimit", String($0)] } ?? [])
        app.launch()
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "no Continue Watching")
        card.tap()

        let failure = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'didn’t start'")).firstMatch
        let tryAgain = app.buttons["Try again"].firstMatch
        let counting = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH ' s' AND NOT (identifier BEGINSWITH 'debug-')")).firstMatch
        let began = Date()
        while !failure.exists, Date().timeIntervalSince(began) < failsAt + 7 {
            XCTAssertFalse(tryAgain.exists, "Try again before the start failed")
            XCTAssertFalse(counting.exists, "words counting the wait")
            usleep(250_000)
        }
        XCTAssertTrue(failure.exists, "no failure by \(failsAt + 7) s: \(app.staticTexts["debug-film-loading"].firstMatch.label)")
        XCTAssertTrue(tryAgain.exists, "no Try again over the failure")
        XCTAssertTrue(app.buttons["Close player"].exists, "no Close player over the failure")

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
            XCTAssertEqual(times[3], failsAt, accuracy: 0.4, "the start didn't fail at its limit: \(looks.label)")
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

    func testAPreparedCardStartsAndATapShowsItsControls() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        configure(server, ["episode_resume": "60"])
        defer { configure(server, ["reset": "1"]) }
        app.launchArguments = ["-cacheFolder", "film-prepared-\(UUID())"]
        app.launch()
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "no Continue Watching")
        let ahead = app.staticTexts["debug-ahead"].firstMatch
        let began = Date()
        while Date().timeIntervalSince(began) < 30, !Self.prepared(ahead.label) { sleep(1) }
        XCTAssertTrue(Self.prepared(ahead.label), "the card's plan and start weren't fetched ahead in 30 s: \(ahead.label)")
        card.tap()
        playsAndShowsControls("the prepared start")
    }

    func testAFilmClosedAndOpenedAgainCarriesOnAndShowsItsControls() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        configure(server, ["episode_resume": "60"])
        defer { configure(server, ["reset": "1"]) }
        app.launchArguments = ["-noPrepareAhead", "YES", "-noStreamAhead", "YES", "-cacheFolder", "film-kept-\(UUID())"]
        app.launch()
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "no Continue Watching")
        let id = card.identifier
        card.tap()
        playsAndShowsControls("the first start")
        sleep(3)
        app.buttons[id].firstMatch.tap()
        playsAndShowsControls("the kept player")
    }

    private func playsAndShowsControls(_ start: String) {
        let looks = app.staticTexts["debug-film-loading"].firstMatch
        let tapped = Date()
        while Date().timeIntervalSince(tapped) < 20, !looks.label.contains("film ") { usleep(250_000) }
        XCTAssertTrue(looks.label.contains("film "), "\(start) never showed the film: \(looks.label)")
        sleep(5)
        let forward = app.buttons["Forward 10 seconds"].firstMatch
        if !forward.isHittable { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap() }
        XCTAssertTrue(forward.waitForExistence(timeout: 3), "a tap on \(start)'s film didn't show its controls: \(looks.label)")
        app.buttons["Close player"].firstMatch.tap()
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "Close player didn't close \(start)")
    }

    private static func prepared(_ ahead: String) -> Bool {
        let words = ahead.split(separator: " ")
        func count(_ name: String) -> Int { words.firstIndex(of: Substring(name)).flatMap { Int(words[$0 + 1]) } ?? 0 }
        return count("plans") > 0 && count("starts") > 0
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

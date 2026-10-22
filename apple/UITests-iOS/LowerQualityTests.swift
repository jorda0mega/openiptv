import XCTest

/// A lower quality: the server's converted version, listed from the
/// segment the film was at (the test server converts as Emby does), so the
/// player's clock starts there.
extension PlayerLookTests {
    private func openLowered(_ server: URL, _ settings: [String: String] = [:]) {
        configure(server, ["emby_convert": "1", "convert_delay": "2"].merging(settings) { $1 })
        app.launchEnvironment["OPENREEL_DEBUG_LOWER_AFTER"] = "15"
        openFilm()
    }

    private func waitForTheLowerQuality() {
        let buffering = app.staticTexts["debug-buffering"].firstMatch
        for _ in 0..<60 where !buffering.label.contains("converted ") { usleep(500_000) }
        XCTAssertTrue(buffering.label.contains("converted "), "the lower quality didn't start: \(buffering.label)")
    }

    func testJumpBackPastALowerQualitysStartPlaysFromThere() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        openLowered(server)
        waitForTheLowerQuality()
        let from = try XCTUnwrap(position(), "no position")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        let back = app.buttons["Back 10 seconds"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5), "no Back 10 seconds")
        back.tap()
        sleep(8)
        let film = try XCTUnwrap(position(), "no position")
        let stream = Double(app.staticTexts["debug-stream-time"].firstMatch.label) ?? -1
        print("JUMP BACK from \(from) s: the film at \(film) s, the stream's own second \(stream)")
        XCTAssertLessThan(film, from - 2, "the jump back stopped at the lower quality's start")
        XCTAssertEqual(stream, film, accuracy: 2, "the pictures aren't where the bar says")
    }

    func testAJumpWhileALowerQualityOpensHolds() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        openLowered(server, ["hls_delay": "8"])
        let quality = app.staticTexts["debug-quality"].firstMatch
        for _ in 0..<60 where !(quality.exists && quality.label.hasPrefix("converted")) { usleep(500_000) }
        XCTAssertTrue(quality.exists && quality.label.hasPrefix("converted"), "the quality wasn't lowered")
        let asked = try XCTUnwrap(position(), "no position")
        for _ in 0..<3 {
            controlsUp()
            app.buttons["Forward 10 seconds"].firstMatch.tap()
            usleep(400_000)
        }
        waitForTheLowerQuality()
        sleep(3)
        let film = try XCTUnwrap(position(), "no position")
        print("JUMP WHILE LOWERING asked at \(asked) s, then 30 s on: the film at \(film) s")
        XCTAssertGreaterThan(film, asked + 20, "the jump made while the lower quality opened was undone")
    }

    func testALowerQualityClosedAndChosenAgainOpensAfreshWhereItStopped() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        openLowered(server, ["ignore_reports": "1"])
        waitForTheLowerQuality()
        sleep(3)
        controlsUp()
        let closed = try XCTUnwrap(position(), "no position")
        app.buttons["Close player"].firstMatch.tap()
        sleep(2)
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Resume' OR label BEGINSWITH 'Continue'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5), "no play button")
        play.tap()
        let start = app.staticTexts["debug-start"].firstMatch
        let began = Date()
        while Date().timeIntervalSince(began) < 10, !start.label.contains(" at ") { usleep(200_000) }
        let readout = start.label
        sleep(4)
        let later = try XCTUnwrap(position(), "no position")
        print("REOPEN LOWERED closed at \(closed) s, started \(readout), 4 s later at \(later) s")
        XCTAssertTrue(readout.hasPrefix("cold "), "the lower quality was kept: \(readout)")
        XCTAssertEqual(later, closed + 4, accuracy: 3, "it didn't open where it stopped")
    }

    func testPictureInPictureWhileALowerQualityOpensKeepsTheBarWithThePictures() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone, "no Picture in Picture in iPhone simulators")
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        app.launchEnvironment["OPENREEL_DEBUG_PIP_HOLD"] = "3.5"
        openLowered(server, ["hls_delay": "2"])
        let quality = app.staticTexts["debug-quality"].firstMatch
        for _ in 0..<120 where !(quality.exists && quality.label.hasPrefix("converted")) { usleep(250_000) }
        XCTAssertTrue(quality.exists && quality.label.hasPrefix("converted"), "the quality wasn't lowered")
        controlsUp()
        let pip = app.buttons["Picture in Picture"].firstMatch
        XCTAssertTrue(pip.waitForExistence(timeout: 3), "no Picture in Picture button")
        pip.tap()
        let asked = Date()
        while Date().timeIntervalSince(asked) < 8, pipState() == nil { usleep(200_000) }
        XCTAssertNotNil(pipState(), "Picture in Picture didn't start")
        sleep(3)
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        board.otherElements["Video"].firstMatch.tap()
        let restore = board.buttons["Restore fullscreen"].firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 3), "no Restore fullscreen in the window")
        restore.tap()
        sleep(4)
        let film = try XCTUnwrap(position(), "no position")
        let stream = Double(app.staticTexts["debug-stream-time"].firstMatch.label) ?? -1
        print("PIP WHILE LOWERING the film at \(film) s, the stream's own second \(stream)")
        XCTAssertEqual(stream, film, accuracy: 2, "the pictures aren't where the bar says")
    }

    func testASkipBackInTheWindowPastALowerQualitysStartGoesThereAtOnce() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone, "no Picture in Picture in iPhone simulators")
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        openLowered(server)
        waitForTheLowerQuality()
        controlsUp()
        let pip = app.buttons["Picture in Picture"].firstMatch
        XCTAssertTrue(pip.waitForExistence(timeout: 3), "no Picture in Picture button")
        pip.tap()
        let asked = Date()
        while Date().timeIntervalSince(asked) < 8, pipState() == nil { usleep(200_000) }
        let before = try XCTUnwrap(pipState()?.seconds, "Picture in Picture didn't start")
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        board.otherElements["Video"].firstMatch.tap()
        let back = board.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'back'")).firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 3), "no skip back in the window")
        back.tap()
        var seen: [Int] = []
        let tapped = Date()
        while Date().timeIntervalSince(tapped) < 2 {
            if let seconds = pipState()?.seconds { seen.append(Int(seconds)) }
            usleep(100_000)
        }
        print("PIP SKIP BACK from \(Int(before)) s: the window's clock \(seen)")
        XCTAssertFalse(seen.isEmpty, "no window clock after the skip")
        XCTAssertTrue(seen.allSatisfy { Double($0) < before - 5 }, "the window's clock wasn't where it skipped to: \(seen)")
    }

    func testAJumpBackAfterPictureInPicturePlaysFromThere() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone, "no Picture in Picture in iPhone simulators")
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        openLowered(server)
        waitForTheLowerQuality()
        // Paused, so the jump back after the window still crosses the
        // version's start.
        controlsUp()
        app.buttons["Pause"].firstMatch.tap()
        controlsUp()
        let pip = app.buttons["Picture in Picture"].firstMatch
        XCTAssertTrue(pip.waitForExistence(timeout: 3), "no Picture in Picture button")
        pip.tap()
        let asked = Date()
        while Date().timeIntervalSince(asked) < 8, pipState() == nil { usleep(200_000) }
        XCTAssertNotNil(pipState(), "Picture in Picture didn't start")
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let window = board.otherElements["Video"].firstMatch
        window.tap()
        // The window's middle is its play button.
        if pipState()?.playing == true { window.tap() }
        let restore = board.buttons["Restore fullscreen"].firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 3), "no Restore fullscreen in the window")
        restore.tap()
        sleep(4)
        // Paused about 8 s past the version's start: 20 s back is well before it.
        let from = try XCTUnwrap(position(), "no position")
        controlsUp()
        app.buttons["Back 10 seconds"].firstMatch.tap()
        app.buttons["Back 10 seconds"].firstMatch.tap()
        sleep(6)
        controlsUp()
        app.buttons["Play"].firstMatch.tap()
        sleep(3)
        let film = try XCTUnwrap(position(), "no position")
        let stream = Double(app.staticTexts["debug-stream-time"].firstMatch.label) ?? -1
        print("JUMP BACK AFTER PIP from \(from) s: 3 s after playing on, the film at \(film) s, the stream's own second \(stream)")
        XCTAssertLessThan(film, from - 10, "the jump back stopped at the lower quality's start")
        XCTAssertEqual(stream, film, accuracy: 2, "the pictures aren't where the bar says")
    }

    /// The film's requests and a lower quality's first segments
    /// (-debugRedirectCounts) the server answered with a redirect, and
    /// those to another server, for the real server's runner. localhost is
    /// another server to the app: the film, asked there without the key,
    /// doesn't open.
    func testRedirectsAreCounted() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        configure(server, ["emby_convert": "1", "convert_delay": "2", "redirect_film": "same", "redirect_segment": "elsewhere"])
        app.launchEnvironment["OPENREEL_DEBUG_LOWER_AFTER"] = "15"
        openFilm(["-debugRedirectCounts", "YES"])
        waitForTheLowerQuality()
        sleep(3)
        let lowered = redirects()
        app.terminate()
        configure(server, ["redirect_film": "elsewhere", "redirect_segment": ""])
        app.launchEnvironment["OPENREEL_DEBUG_LOWER_AFTER"] = nil
        openFilm(["-debugRedirectCounts", "YES"])
        let elsewhere = redirects()
        print("REDIRECTS the film here, segments elsewhere: \(lowered); the film elsewhere: \(elsewhere)")
        XCTAssertGreaterThan(lowered.film, 0, "no film redirect counted")
        XCTAssertEqual(lowered.filmElsewhere, 0, "a redirect on this server counted elsewhere")
        XCTAssertEqual(lowered.asked, 3, "not the lower quality's first 3 segments")
        XCTAssertEqual(lowered.converted, 3, "segments redirected")
        XCTAssertEqual(lowered.convertedElsewhere, 3, "segments redirected elsewhere")
        XCTAssertGreaterThan(elsewhere.film, 0, "no film redirect counted")
        XCTAssertEqual(elsewhere.filmElsewhere, elsewhere.film, "a redirect elsewhere counted on this server")
    }

    /// "film 2 (0 elsewhere) | converted 3 (3 elsewhere) of 3 asked"
    private func redirects() -> (film: Int, filmElsewhere: Int, converted: Int, convertedElsewhere: Int, asked: Int) {
        let numbers = app.staticTexts["debug-redirects"].firstMatch.label.split { !$0.isNumber }.compactMap { Int($0) }
        guard numbers.count == 5 else { return (-1, -1, -1, -1, -1) }
        return (numbers[0], numbers[1], numbers[2], numbers[3], numbers[4])
    }
}

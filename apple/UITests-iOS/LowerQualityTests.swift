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

    /// Kept, it came back with the quality chooser taking it for the original,
    /// which then never went back up.
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
        board.otherElements["Video"].firstMatch.tap()
        let restore = board.buttons["Restore fullscreen"].firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 3), "no Restore fullscreen in the window")
        restore.tap()
        sleep(4)
        controlsUp()
        app.buttons["Play"].firstMatch.tap()
        let from = try XCTUnwrap(position(), "no position")
        controlsUp()
        app.buttons["Back 10 seconds"].firstMatch.tap()
        sleep(8)
        let film = try XCTUnwrap(position(), "no position")
        let stream = Double(app.staticTexts["debug-stream-time"].firstMatch.label) ?? -1
        print("JUMP BACK AFTER PIP from \(from) s: the film at \(film) s, the stream's own second \(stream)")
        XCTAssertLessThan(film, from - 2, "the jump back stopped at the lower quality's start")
        XCTAssertEqual(stream, film, accuracy: 2, "the pictures aren't where the bar says")
    }
}

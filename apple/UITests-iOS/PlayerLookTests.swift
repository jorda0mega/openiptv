import XCTest

/// iPhone: the app as a person uses it, with a screenshot at each step
/// (written to /tmp/openiptv/uitest-ios on the Mac). Run with
/// `xcodebuild test -scheme OpenIPTV` on an iPhone simulator, signed in to
/// the test server (scripts/mock_server.py) through TEST_RUNNER_DEBUG_EMBY.
final class PlayerLookTests: XCTestCase {
    private let app = XCUIApplication()
    private let shots = URL(fileURLWithPath: "/tmp/openiptv/uitest-ios")
    private var step = 0

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        if let account = ProcessInfo.processInfo.environment["DEBUG_EMBY"] {
            app.launchEnvironment["OPENREEL_DEBUG_EMBY"] = account
        }
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    private func shot(_ note: String) {
        step += 1
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let name = String(format: "%02d-%@.png", step, note.replacingOccurrences(of: " ", with: "-"))
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: name))
        print("SHOT \(note) → \(name)")
    }

    /// The film "Animals" from Search, playing.
    private func openFilm(_ arguments: [String] = []) {
        app.launchArguments = ["-debugSearch", "animals"] + arguments
        app.launch()
        sleep(4)
        // iPhone: the tab bar at the bottom; iPad: the one at the top.
        let tab = app.tabBars.buttons["Search"].firstMatch
        (tab.exists ? tab : app.buttons["Search"].firstMatch).tap()
        sleep(3)
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Animals'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 8), "no search result")
        result.tap()
        sleep(2)
        shot("film page")
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Resume' OR label BEGINSWITH 'Continue'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 8), "no play button")
        play.tap()
        sleep(6)
        // Upright to begin with (a previous run may have left it sideways).
        app.tap()
        usleep(600_000)
        let upright = app.buttons["Rotate to portrait"].firstMatch
        if upright.exists {
            upright.tap()
            sleep(3)
        }
    }

    /// Picture in Picture: the film goes on in the floating window and the
    /// player closes (back on the film's page).
    func testPictureInPicture() throws {
        // iPhone simulators have no Picture in Picture (iPads and iPhones do).
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone, "no Picture in Picture in iPhone simulators")
        openFilm()
        app.tap()
        usleep(600_000)
        // A minute in, so a wrong clock shows (0:00, or twice the start).
        for _ in 0..<6 { app.buttons["Forward 10 seconds"].firstMatch.tap(); usleep(400_000) }
        sleep(2)
        let before = position()
        print("PIP before \(before ?? -1)")
        let pip = app.buttons["Picture in Picture"].firstMatch
        XCTAssertTrue(pip.waitForExistence(timeout: 3), "no Picture in Picture button")
        pip.tap()
        let asked = Date()
        var up: Date?
        while Date().timeIntervalSince(asked) < 8 {
            if up == nil, pipState() != nil { up = Date() }
            usleep(200_000)
        }
        shot("pip started")
        XCTAssertFalse(app.buttons["Close player"].exists, "the player didn't close for Picture in Picture")
        let first = pipState()
        sleep(8)
        let later = pipState()
        print("PIP state \(String(describing: first)) then \(String(describing: later))")
        guard let first, let later, let before, let up else { return XCTFail("no Picture in Picture state") }
        // Regression: the window grew out of a picture hidden behind the
        // app, and started late; it stuttered on the way.
        XCTAssertEqual(first.from, "screen", "Picture in Picture didn't grow out of the picture on screen")
        XCTAssertLessThan(first.startMs, 3000, "Picture in Picture took \(first.startMs) ms to start")
        XCTAssertLessThan(up.timeIntervalSince(asked), 4, "Picture in Picture took \(up.timeIntervalSince(asked)) s to show")
        // Regressions: it paused after the handoff; it showed the film from
        // 0:00 while it reported the start plus that clock (episodes got
        // marked watched, "skipped"). The test server's converted stream is
        // the whole film from 0:00, as Emby's, so its clock is the film's.
        XCTAssertTrue(later.playing, "Picture in Picture paused")
        XCTAssertGreaterThanOrEqual(later.seconds - first.seconds, 5, "Picture in Picture isn't moving on")
        XCTAssertLessThan(abs(first.clock - before), 20, "Picture in Picture shows \(first.clock) s, not near \(before) s")
        XCTAssertLessThan(abs(first.seconds - first.clock), 3, "Picture in Picture reports \(first.seconds) s but shows \(first.clock) s")

        // Back to the app: its player from where the window got to, playing.
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        board.otherElements["Video"].firstMatch.tap()
        let restore = board.buttons["Restore fullscreen"].firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 3), "no Restore fullscreen in the window")
        restore.tap()
        sleep(5)
        app.tap()
        usleep(600_000)
        let back = position()
        sleep(4)
        app.tap()
        usleep(600_000)
        let after = position()
        shot("pip restored")
        print("PIP restored at \(back ?? -1) then \(after ?? -1)")
        guard let back, let after else { return XCTFail("the app's player didn't come back") }
        XCTAssertLessThan(abs(back - later.seconds), 20, "came back at \(back) s, not near \(later.seconds) s")
        XCTAssertGreaterThanOrEqual(after - back, 2, "the app's player came back paused")
    }

    /// The bar's position in seconds ("Playback position" "00:01:12").
    private func position() -> Double? {
        let bar = app.otherElements["Playback position"].firstMatch
        let value = (bar.exists ? bar : app.descendants(matching: .any)["Playback position"].firstMatch).value as? String
        return value.map { $0.split(separator: ":").compactMap { Double($0) }.reduce(0) { $0 * 60 + $1 } }
    }

    /// The app's debug readout: "pip active=true playing=true seconds=72
    /// clock=72 start=640 from=screen" (seconds: the film's second it
    /// reports; clock: the window's stream; start: milliseconds to come up;
    /// from: whether it grew out of the picture on screen).
    private func pipState() -> (playing: Bool, seconds: Double, clock: Double, startMs: Int, from: String)? {
        let text = app.staticTexts["debug-pip"].firstMatch.label
        guard text.hasPrefix("pip") else { return nil }
        let fields = Dictionary(uniqueKeysWithValues: text.split(separator: " ").dropFirst().compactMap { part -> (String, String)? in
            let pair = part.split(separator: "=", maxSplits: 1)
            return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
        })
        guard let seconds = fields["seconds"].flatMap(Double.init),
              let clock = fields["clock"].flatMap(Double.init) else { return nil }
        return (fields["playing"] == "true", seconds, clock, fields["start"].flatMap(Int.init) ?? .max, fields["from"] ?? "")
    }

    /// Subtitles picked in the player stay for that film, even in the
    /// audio's own language (English over English). Needs the test server
    /// with the multi-track file (OPENIPTV_MOCK_VIDEO=multi.mkv, a US film).
    func testPickedSubtitlesStay() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MULTI_TRACK"] != nil, "needs the multi-track test file")
        openFilm(["-forgetTrackChoices", "YES"])
        // Regression: a US film whose file says Spanish first started in
        // Spanish with Spanish subtitles.
        XCTAssertEqual(tracksPlaying(), "audio=eng subtitles=off")
        app.tap()
        usleep(600_000)
        app.buttons["Audio and Subtitles"].firstMatch.tap()
        sleep(1)
        shot("menu open")
        // Audio first, then Subtitles from Off: the English under Off.
        let off = app.buttons["Off"].firstMatch
        XCTAssertTrue(off.waitForExistence(timeout: 3), "no Subtitles in the menu")
        let english = app.buttons.matching(NSPredicate(format: "label CONTAINS 'English'")).allElementsBoundByIndex
        XCTAssertLessThan(english.first?.frame.minY ?? 0, off.frame.minY, "Audio isn't above Subtitles")
        guard let subtitles = english.first(where: { $0.frame.minY > off.frame.minY }) else {
            return XCTFail("no English subtitles in the menu")
        }
        subtitles.tap()
        sleep(2)
        shot("subtitles picked")
        XCTAssertEqual(tracksPlaying(), "audio=eng subtitles=eng", "English subtitles didn't come on")
        app.tap()
        usleep(600_000)
        app.buttons["Close player"].firstMatch.tap()
        sleep(2)
        shot("film page again")
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Resume' OR label BEGINSWITH 'Continue'")).firstMatch
        play.tap()
        sleep(6)
        app.tap()
        usleep(600_000)
        app.buttons["Audio and Subtitles"].firstMatch.tap()
        sleep(1)
        shot("subtitles reopened")
        // Regression: English subtitles picked over English audio came back off.
        XCTAssertEqual(tracksPlaying(), "audio=eng subtitles=eng")
    }

    /// The app's debug readout of the tracks playing ("audio=eng subtitles=off").
    private func tracksPlaying() -> String {
        let readout = app.staticTexts["debug-tracks"].firstMatch
        _ = readout.waitForExistence(timeout: 5)
        for _ in 0..<10 where readout.label.isEmpty { sleep(1) }
        return readout.label
    }

    /// The player in portrait and landscape: playing (controls up, then
    /// gone), paused (controls up). The picture must keep its size in each.
    func testPlayerLook() {
        openFilm()
        shot("portrait playing controls")
        sleep(5)
        shot("portrait playing hidden")
        app.tap()
        usleep(600_000)
        shot("portrait controls again")
        app.buttons["Pause"].firstMatch.tap()
        sleep(1)
        shot("portrait paused")
        app.buttons["Audio and Subtitles"].firstMatch.tap()
        sleep(1)
        shot("portrait track menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        sleep(1)
        app.buttons["Info"].firstMatch.tap()
        sleep(1)
        shot("portrait info panel")
        app.buttons["Info"].firstMatch.tap()
        sleep(1)
        app.buttons["Play"].firstMatch.tap()
        sleep(5)
        // Turned with the player's own button (the simulator ignores a
        // turned device here).
        app.tap()
        usleep(600_000)
        app.buttons["Rotate to landscape"].firstMatch.tap()
        sleep(3)
        shot("landscape after turn")
        sleep(5)
        shot("landscape hidden")
        app.tap()
        usleep(600_000)
        shot("landscape controls")
        app.buttons["Pause"].firstMatch.tap()
        sleep(1)
        shot("landscape paused")
        sleep(5)
        shot("landscape paused later")
        // Info in landscape: everything stays on the screen.
        app.buttons["Info"].firstMatch.tap()
        sleep(1)
        shot("landscape info")
        let screen = app.windows.firstMatch.frame
        let closeButton = app.buttons["Close player"].firstMatch.frame
        let fromStart = app.buttons["From Beginning"].firstMatch
        XCTAssertTrue(screen.contains(closeButton), "Close went off the screen: \(closeButton) in \(screen)")
        XCTAssertTrue(fromStart.exists && screen.contains(fromStart.frame), "From Beginning went off the screen")
        app.buttons["Info"].firstMatch.tap()
        sleep(1)
        app.buttons["Play"].firstMatch.tap()
        sleep(1)
        shot("landscape resumed")
        // Closing turns the app upright again.
        app.buttons["Close player"].firstMatch.tap()
        sleep(2)
        shot("closed")
    }
}

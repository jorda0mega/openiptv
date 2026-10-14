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
        if let hold = ProcessInfo.processInfo.environment["PIP_HOLD"] {
            app.launchEnvironment["OPENREEL_DEBUG_PIP_HOLD"] = hold
        }
        if let options = ProcessInfo.processInfo.environment["MPV_EXTRA"] {
            app.launchEnvironment["OPENREEL_DEBUG_MPV"] = options
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
        // The film, not the show "Animals." (first on a fresh simulator,
        // before IMDb's ratings have come to rank them).
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Animals' AND NOT label BEGINSWITH 'Animals.'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 8), "no search result")
        result.tap()
        sleep(2)
        shot("film page")
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Resume' OR label BEGINSWITH 'Continue'")).firstMatch
        // A fresh simulator can still be filling the results in as the
        // first tap lands: once more if the page didn't open.
        if !play.waitForExistence(timeout: 8), result.exists {
            result.tap()
            sleep(2)
        }
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
        controlsUp()
        // A minute in, so a wrong clock shows (0:00, or twice the start).
        for _ in 0..<6 {
            controlsUp()
            app.tapControl("Forward 10 seconds")
            usleep(400_000)
        }
        sleep(2)
        controlsUp()
        let before = position()
        print("PIP before \(before ?? -1)")
        // The server takes 6 s to start a converted stream: the window
        // must not wait for one (it plays the same playback).
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["hls_delay": "6"])
        defer { configure(server, ["reset": "1"]) }
        controlsUp()
        let pip = app.buttons["Picture in Picture"].firstMatch
        XCTAssertTrue(pip.waitForExistence(timeout: 3), "no Picture in Picture button")
        pip.tap()
        let asked = Date()
        usleep(1_000_000)
        shot("pip starting")
        var up: Date?
        while Date().timeIntervalSince(asked) < 11 {
            if up == nil, pipState() != nil { up = Date() }
            usleep(200_000)
        }
        shot("pip started")
        XCTAssertFalse(app.buttons["Close player"].exists, "the player didn't close for Picture in Picture")
        let first = pipState()
        let sinceTap = Date().timeIntervalSince(asked)
        sleep(8)
        let later = pipState()
        print("PIP state \(String(describing: first)) then \(String(describing: later))")
        guard let first, let later, let before, let up else { return XCTFail("no Picture in Picture state") }
        // Regression: the window grew out of a picture hidden behind the
        // app, and started late; it stuttered on the way.
        XCTAssertEqual(first.from, "screen", "Picture in Picture didn't grow out of the picture on screen")
        // Regression: the film paused while the window's stream got ready;
        // it plays on, and the window takes over where it has got to.
        XCTAssertGreaterThan(first.seconds, before + sinceTap - 2.5,
                             "the film paused while Picture in Picture got ready: \(first.seconds) s, \(sinceTap) s after \(before) s")
        // Regression: it took 5 s on a real server (a second stream had to
        // start); the same playback moves into the window at once.
        XCTAssertLessThan(first.startMs, 2500, "Picture in Picture took \(first.startMs) ms to start")
        XCTAssertLessThan(up.timeIntervalSince(asked), 3, "Picture in Picture took \(up.timeIntervalSince(asked)) s to show")
        // Regressions: it paused after the handoff; it showed the film from
        // 0:00 while it reported the start plus that clock (episodes got
        // marked watched, "skipped"). The test server's converted stream is
        // the whole film from 0:00, as Emby's, so its clock is the film's.
        XCTAssertTrue(later.playing, "Picture in Picture paused")
        // The film shows in the window (the test film's colour bars), not
        // black. Simulators draw this window black for any app's frames, so
        // only a device can check it.
        let window = XCUIApplication(bundleIdentifier: "com.apple.springboard").otherElements["Video"].firstMatch
        XCTAssertTrue(window.exists, "no Picture in Picture window")
        #if !targetEnvironment(simulator)
        XCTAssertGreaterThan(brightestPixel(in: window.frame), 120, "the Picture in Picture window is black")
        #endif
        XCTAssertGreaterThanOrEqual(later.seconds - first.seconds, 5, "Picture in Picture isn't moving on")
        XCTAssertLessThan(abs(first.clock - before), 25, "Picture in Picture shows \(first.clock) s, not near \(before) s")
        XCTAssertLessThan(abs(first.seconds - first.clock), 3, "Picture in Picture reports \(first.seconds) s but shows \(first.clock) s")

        // Back to the app: its player from where the window got to, playing.
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        board.otherElements["Video"].firstMatch.tap()
        let restore = board.buttons["Restore fullscreen"].firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 3), "no Restore fullscreen in the window")
        let leaving = pipState()
        let leftAt = Date()
        restore.tap()
        sleep(5)
        let back = position()
        let backAt = Date()
        sleep(4)
        let after = position()
        shot("pip restored")
        print("PIP left at \(leaving?.seconds ?? -1), restored at \(back ?? -1) then \(after ?? -1)")
        guard let back, let after, let leaving else { return XCTFail("the app's player didn't come back") }
        // Regression: it came back at an older second (a player opened
        // meanwhile at the server's resume point, "the same frame again").
        let expected = leaving.seconds + backAt.timeIntervalSince(leftAt)
        XCTAssertLessThan(abs(back - expected), 3, "came back at \(back) s, not \(expected) s (left the window at \(leaving.seconds) s)")
        XCTAssertGreaterThanOrEqual(after - back, 3, "the app's player came back paused")
    }

    /// Closed and chosen again, a film carries on at once where it stopped,
    /// without waiting for the server, even when the server didn't keep
    /// the stop. Regression: the next tap waited for the server and a new
    /// stream, and started where the server last heard ("the same frame").
    func testReopenCarriesOnAtOnce() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["ignore_reports": "1"])
        defer { configure(server, ["reset": "1"]) }
        openFilm()
        for _ in 0..<6 {
            controlsUp()
            app.tapControl("Forward 10 seconds")
            usleep(400_000)
        }
        sleep(3)
        controlsUp()
        let closed = try XCTUnwrap(position(), "no position")
        app.tapControl("Close player") { !self.app.staticTexts["debug-position"].exists }
        sleep(2)
        // A slow server from here on: any question to it shows.
        configure(server, ["latency": "2.5"])
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Resume' OR label BEGINSWITH 'Continue'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 5), "no play button")
        play.tap()
        let start = app.staticTexts["debug-start"].firstMatch
        let began = Date()
        while Date().timeIntervalSince(began) < 10, !start.label.contains(" at ") { usleep(200_000) }
        shot("reopened")
        let readout = start.label
        print("REOPEN closed at \(closed), started \(readout)")
        let parts = readout.split(separator: " ")
        guard parts.count == 4, let seconds = Double(parts[1]), let at = Double(parts[3]) else {
            return XCTFail("no start readout: \(readout)")
        }
        XCTAssertEqual(parts[0], "warm", "it opened again from scratch: \(readout)")
        XCTAssertLessThan(seconds, 1.5, "it took \(seconds) s to start again")
        XCTAssertLessThan(abs(at - closed), 3, "it started at \(at) s, not where it stopped (\(closed) s)")
    }

    /// The brightest colour channel inside `area` of the screen (0-255).
    private func brightestPixel(in area: CGRect) -> UInt8 {
        guard let image = XCUIScreen.main.screenshot().image.cgImage,
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
        let scale = CGFloat(image.width) / XCUIScreen.main.screenshot().image.size.width
        let perPixel = image.bitsPerPixel / 8
        var best: UInt8 = 0
        // Inside the rounded corners (the page behind shows there).
        let inset = Int(24 * scale)
        for y in stride(from: Int(area.minY * scale) + inset, to: Int(area.maxY * scale) - inset, by: 6) {
            for x in stride(from: Int(area.minX * scale) + inset, to: Int(area.maxX * scale) - inset, by: 6)
            where x >= 0 && y >= 0 && x < image.width && y < image.height {
                let i = y * image.bytesPerRow + x * perPixel
                best = max(best, bytes[i], bytes[i + 1], bytes[i + 2])
            }
        }
        return best
    }

    /// The player's controls on screen (a tap on the picture shows them,
    /// and hides them when they're up).
    /// The player's play/pause button, to this state.
    private func tapPlayPause(playing: Bool, file: StaticString = #filePath, line: UInt = #line) {
        // Its label turns at once (the readout waits for the next tick,
        // which a paused player doesn't send).
        let button = app.buttons["player.playPause"].firstMatch
        app.tapControl(button, until: { button.exists && button.label == (playing ? "Pause" : "Play") }, file: file, line: line)
    }

    private func controlsUp() {
        if !app.buttons["Close player"].firstMatch.isHittable {
            // Above the middle: the middle is the play/pause button.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
            usleep(700_000)
        }
    }

    /// The player's second: from the app's debug readout (there whether
    /// or not the controls are up), else the bar ("Playback position"
    /// "00:01:12").
    private func position() -> Double? {
        if let state = playerState() { return state.seconds.rounded() }
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
    /// with the multi-track file as a US film (OPENIPTV_MOCK_VIDEO=multi.mkv,
    /// OPENIPTV_MOCK_COUNTRIES="United States of America"; with no country,
    /// its Spanish first track counts as the original); TEST_RUNNER_MULTI_TRACK=1.
    func testPickedSubtitlesStay() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MULTI_TRACK"] != nil, "needs the multi-track test file")
        openFilm(["-forgetTrackChoices", "YES"])
        // Regression: a US film whose file says Spanish first started in
        // Spanish with Spanish subtitles.
        XCTAssertEqual(tracksPlaying(), "audio=eng subtitles=off")
        app.tap()
        usleep(600_000)
        app.tapControl("Audio and Subtitles") { self.app.buttons["Off"].exists }
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
        app.tapControl("Close player") { !self.app.staticTexts["debug-position"].exists }
        sleep(2)
        shot("film page again")
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Resume' OR label BEGINSWITH 'Continue'")).firstMatch
        play.tap()
        sleep(6)
        app.tap()
        usleep(600_000)
        app.tapControl("Audio and Subtitles") { self.app.buttons["Off"].exists }
        sleep(1)
        shot("subtitles reopened")
        // Regression: English subtitles picked over English audio came back off.
        XCTAssertEqual(tracksPlaying(), "audio=eng subtitles=eng")
    }

    /// Subtitles on the picture in portrait, at the picture's scale, as in
    /// the Apple TV app. Regression: sized by the (tall) window, they were
    /// huge and drawn under the picture, off the bottom of the screen.
    /// Needs the multi-track test server as for testPickedSubtitlesStay.
    func testSubtitlesOnPictureInPortrait() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MULTI_TRACK"] != nil, "needs the multi-track test file")
        openFilm(["-forgetTrackChoices", "YES"])
        app.tap()
        usleep(600_000)
        app.tapControl("Audio and Subtitles") { self.app.buttons["Off"].exists }
        let off = app.buttons["Off"].firstMatch
        XCTAssertTrue(off.waitForExistence(timeout: 3), "no Subtitles in the menu")
        let english = app.buttons.matching(NSPredicate(format: "label CONTAINS 'English'")).allElementsBoundByIndex
            .first { $0.frame.minY > off.frame.minY }
        XCTAssertNotNil(english, "no English subtitles")
        english?.tap()
        sleep(1)
        // Playing, the controls gone: only the picture and its subtitles show.
        if playerState()?.playing == false {
            controlsUp()
            tapPlayPause(playing: true)
        }
        sleep(7)
        shot("subtitles in portrait")
        XCTAssertFalse(app.buttons["Close player"].exists, "the controls are still up")
        let screen = app.frame
        let pictureBottom = screen.midY + screen.width * 9 / 32
        let below = CGRect(x: 0, y: pictureBottom + 8, width: screen.width, height: screen.maxY - pictureBottom - 8)
        XCTAssertLessThan(brightestPixel(in: below), 60, "subtitles drawn under the picture")
    }

    /// Of two English subtitle tracks, the one picked (SDH) comes back,
    /// not just its language. Needs the test server with a file holding
    /// English and English SDH subtitles (OPENIPTV_MOCK_VIDEO=multi-sdh.mkv,
    /// OPENIPTV_MOCK_COUNTRIES="United States of America"; run with
    /// TEST_RUNNER_SDH_TRACKS=1). Regression: only the language
    /// was kept, so the plain English track came back.
    func testPickedSDHSubtitlesStay() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SDH_TRACKS"] != nil, "needs the SDH test file")
        openFilm(["-forgetTrackChoices", "YES"])
        app.tap()
        usleep(600_000)
        app.tapControl("Audio and Subtitles") { self.app.buttons["Off"].exists }
        sleep(1)
        let sdh = app.buttons.matching(NSPredicate(format: "label CONTAINS 'SDH'")).firstMatch
        XCTAssertTrue(sdh.waitForExistence(timeout: 3), "no SDH subtitles in the menu")
        sdh.tap()
        sleep(2)
        XCTAssertEqual(tracksPlaying(), "audio=eng subtitles=eng+sdh", "the SDH subtitles didn't come on")
        app.tap()
        usleep(600_000)
        app.tapControl("Close player") { !self.app.staticTexts["debug-position"].exists }
        sleep(2)
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Resume' OR label BEGINSWITH 'Continue'")).firstMatch
        play.tap()
        sleep(6)
        shot("sdh reopened")
        XCTAssertEqual(tracksPlaying(), "audio=eng subtitles=eng+sdh")
    }

    /// Closing the player: the film's page shows "Continue" from its first
    /// frame. Regression: it showed "Play", then faded into "Continue" (the
    /// stop reached the page only after the page was back on screen).
    func testPageReadyWhenPlayerCloses() {
        openFilm()
        sleep(4)
        app.tap()
        usleep(600_000)
        app.tapControl("Close player") { !self.app.staticTexts["debug-position"].exists }
        let stop = app.staticTexts["debug-stop"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 3), "no stop readout")
        XCTAssertEqual(stop.label, "stop noted player=up", "the stop reached the page after the player had closed")
        let main = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Continue' OR label BEGINSWITH 'Resume'")).firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 3), "no play button on the page")
        shot("page after close")
        XCTAssertFalse(main.label.hasPrefix("Play"), "the page still says \(main.label)")
    }

    /// A quality change mid-film: a small note at the top, the controls
    /// stay hidden. Regression: every control came up for four seconds.
    func testQualityNoteKeepsControlsHidden() {
        app.launchEnvironment["OPENREEL_DEBUG_NOTE_AFTER"] = "12"
        openFilm()
        // Watched from the start (it shows for 4 s, 12 s in).
        let note = app.descendants(matching: .any)["player-note"].firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 20), "no note")
        shot("quality note")
        // Regression: the note brought every control up (they had hidden
        // again after the start).
        XCTAssertFalse(app.buttons["Close player"].isHittable, "the note brought up the controls")
    }

    /// The sound button at the top right, as in the Apple TV app: Mute, then
    /// Unmute.
    func testMuteButton() {
        openFilm()
        controlsUp()
        let mute = app.buttons["Mute"].firstMatch
        XCTAssertTrue(mute.waitForExistence(timeout: 3), "no Mute button")
        XCTAssertGreaterThan(mute.frame.minX, app.frame.width * 0.7, "Mute isn't at the right: \(mute.frame)")
        XCTAssertLessThan(mute.frame.minY, 120, "Mute isn't at the top: \(mute.frame)")
        app.tapControl(mute) { self.app.buttons["Unmute"].exists }
    }

    /// A film made in a Spanish-speaking country starts in Spanish, with no
    /// subtitles. Needs the test server with the multi-track file and
    /// OPENIPTV_MOCK_COUNTRIES=Mexico (run with TEST_RUNNER_SPANISH_FILM=1).
    func testSpanishFilmStartsInSpanish() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SPANISH_FILM"] != nil, "needs a Spanish-made test film")
        openFilm(["-forgetTrackChoices", "YES"])
        XCTAssertEqual(tracksPlaying(), "audio=spa subtitles=off")
    }

    /// Subtitles switched while the server is slow to answer: the film
    /// plays on, at full quality. Regressions: the player read the file
    /// again from the server for the new track and stopped for seconds; and
    /// that wait counted as a slow connection, which dropped the quality (a
    /// note, and the picture jumped). Needs the multi-track test server as
    /// for testPickedSubtitlesStay (TEST_RUNNER_MULTI_TRACK=1).
    func testSubtitleSwitchKeepsPlaying() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MULTI_TRACK"] != nil, "needs the multi-track test file")
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        openFilm(["-forgetTrackChoices", "YES"])
        sleep(5)
        configure(server, ["video_delay": "3"])
        defer { configure(server, ["reset": "1"]) }
        if playerState()?.playing == false {
            controlsUp()
            tapPlayPause(playing: true)
            usleep(600_000)
        }
        let off = app.buttons["Off"].firstMatch
        // Regression: while the film played, a tap on "…" also counted as
        // a tap on the picture, which hid the controls and the menu.
        controlsUp()
        app.tapControl("Audio and Subtitles") { self.app.buttons["Off"].exists }
        XCTAssertTrue(off.waitForExistence(timeout: 3), "the menu didn't open while the film played")
        shot("menu for the switch")
        let spanish = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Spanish'")).allElementsBoundByIndex
            .first { $0.frame.minY > off.frame.minY }
        XCTAssertNotNil(spanish, "no Spanish subtitles")
        spanish?.tap()
        var states: [(Double, Bool)] = []
        var qualities: [String] = []
        for _ in 0..<8 {
            sleep(1)
            if let state = playerState() { states.append((state.seconds, state.playing)) }
            qualities.append(app.staticTexts["debug-quality"].firstMatch.label)
        }
        print("SWITCH \(states) \(qualities)")
        guard let first = states.first, let last = states.last else { return XCTFail("no player state") }
        XCTAssertTrue(states.allSatisfy(\.1), "the film paused")
        XCTAssertGreaterThanOrEqual(last.0 - first.0, 6.5, "the film stopped after switching subtitles: \(states)")
        XCTAssertEqual(Set(qualities), ["original"], "the quality dropped after switching subtitles: \(qualities)")
        XCTAssertEqual(tracksPlaying(), "audio=eng subtitles=spa")
    }

    /// The app's debug readout of the player: its second, and whether it plays.
    private func playerState() -> (seconds: Double, playing: Bool)? {
        let parts = app.staticTexts["debug-position"].firstMatch.label.split(separator: " ")
        guard parts.count == 2, let seconds = Double(parts[0]) else { return nil }
        return (seconds, parts[1] == "playing")
    }

    private func testServer() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["DEBUG_EMBY"],
              let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let address = json["serverURL"] as? String else { return nil }
        return URL(string: address)
    }

    /// Sets how the test server behaves (see CONTROL in mock_server.py).
    private func configure(_ server: URL, _ settings: [String: String]) {
        let url = server.appending(path: "mock/set").appending(queryItems: settings.map { URLQueryItem(name: $0.key, value: $0.value) })
        let done = expectation(description: "configure")
        URLSession.shared.dataTask(with: url) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
    }

    /// The app's debug readout of the tracks playing ("audio=eng subtitles=off").
    private func tracksPlaying() -> String {
        let readout = app.staticTexts["debug-tracks"].firstMatch
        _ = readout.waitForExistence(timeout: 5)
        for _ in 0..<10 where readout.label.isEmpty { sleep(1) }
        return readout.label
    }

    /// Playback speed, as in the Apple TV app: a button beside subtitles;
    /// 2× plays twice as fast, and the button says so.
    func testPlaybackSpeed() {
        openFilm()
        controlsUp()
        let button = app.buttons["Playback Speed"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 3), "no Playback Speed button")
        button.tap()
        // Regression: the controls went while the menu was open (5 s on).
        sleep(5)
        shot("speed menu")
        XCTAssertTrue(app.buttons["Close player"].firstMatch.exists, "the controls went with the menu open")
        app.buttons["2×"].firstMatch.tap()
        sleep(1)
        guard let first = playerState() else { return XCTFail("no position readout") }
        let from = Date()
        sleep(4)
        guard let later = playerState() else { return XCTFail("no position readout") }
        let rate = (later.seconds - first.seconds) / Date().timeIntervalSince(from)
        XCTAssertGreaterThan(rate, 1.6, "2× played at \(rate)×")
        controlsUp()
        XCTAssertEqual(app.buttons["Playback Speed"].firstMatch.value as? String, "2×")
    }

    /// An episode's Info, as in the Apple TV app: From Beginning and Go to
    /// Show side by side; Go to Show closes the player on the show's page.
    func testGoToShow() throws {
        // The episode a minute in (its usual resume point is the test
        // film's end).
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        configure(server, ["episode_resume": "60"])
        defer { configure(server, ["reset": "1"]) }
        app.launch()
        let episode = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-' AND label CONTAINS 'Case 3'")).firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 20), "no episode in Continue Watching")
        episode.tap()
        XCTAssertTrue(app.buttons["Close player"].waitForExistence(timeout: 10), "the episode didn't play")
        // Playing, the controls gone: brought up for the Info pill.
        sleep(6)
        controlsUp()
        app.tapPill("Info")
        sleep(1)
        shot("episode info")
        let fromStart = app.buttons["From Beginning"].firstMatch
        let goToShow = app.buttons["Go to Show"].firstMatch
        XCTAssertTrue(goToShow.exists, "no Go to Show")
        XCTAssertEqual(fromStart.frame.midY, goToShow.frame.midY, accuracy: 2, "not side by side")
        goToShow.tap()
        sleep(2)
        shot("show page")
        XCTAssertFalse(app.buttons["Close player"].exists, "the player is still up")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Season'")).firstMatch.waitForExistence(timeout: 5),
                      "not on the show's page")
    }

    /// Continue Watching in the player, as in the Apple TV app: the other
    /// titles under a pill; one tapped plays in the same player screen (the
    /// page behind never shows).
    func testContinueWatchingInPlayer() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        configure(server, ["episode_resume": "60"])
        defer { configure(server, ["reset": "1"]) }
        openFilm()
        controlsUp()
        app.tapPill("Continue Watching")
        sleep(1)
        shot("continue watching")
        let episode = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Show' AND label CONTAINS 'Case 3'")).firstMatch
        XCTAssertTrue(episode.exists, "no episode in the player's Continue Watching")
        // As in the Apple TV app: "Continue · S2, E3" and "•••" on the row.
        XCTAssertTrue(episode.label.contains("Continue · S2, E3"), "not \"Continue · S2, E3\": \(episode.label)")
        XCTAssertTrue(app.buttons["More"].firstMatch.exists, "no \"•••\" on the rows")
        episode.tap()
        // The player's readout is there the whole time: the screen stayed.
        var gone = 0
        for _ in 0..<15 {
            if !app.staticTexts["debug-position"].exists { gone += 1 }
            usleep(200_000)
        }
        XCTAssertEqual(gone, 0, "the player screen went while the title changed")
        sleep(2)
        shot("episode playing")
        let state = playerState()
        XCTAssertEqual(state?.seconds ?? 0, 63, accuracy: 6, "not the episode from its resume point: \(String(describing: state))")
        XCTAssertEqual(state?.playing, true, "the episode isn't playing")
    }

    /// The player's buttons at the Apple TV app's sizes (measured from its
    /// iOS 26 player, 440-point screen). Regression: the system glass style
    /// added its own padding, and every button came out too big.
    func testPlayerButtonSizes() {
        openFilm()
        controlsUp()
        tapPlayPause(playing: false)
        sleep(1)
        shot("button sizes")
        func size(_ label: String) -> CGSize { app.buttons[label].firstMatch.frame.size }
        let expected: [(String, CGFloat, CGFloat)] = [
            ("Close player", 44, 44), ("Mute", 44, 44), ("Back 10 seconds", 63, 63), ("Play", 92, 92),
            ("Forward 10 seconds", 63, 63), ("Audio and Subtitles", 44, 44), ("Playback Speed", 44, 44),
        ]
        for (label, width, height) in expected {
            let found = size(label)
            XCTAssertEqual(found.width, width, accuracy: 1, "\(label): \(found)")
            XCTAssertEqual(found.height, height, accuracy: 1, "\(label): \(found)")
        }
        XCTAssertEqual(app.buttons["Info"].firstMatch.frame.height, 40, accuracy: 1, "the Info pill")
        // Centres 117 points apart, as in the Apple TV app.
        let back = app.buttons["Back 10 seconds"].firstMatch.frame, play = app.buttons["Play"].firstMatch.frame
        XCTAssertEqual(play.midX - back.midX, 117, accuracy: 1, "back 10 and play/pause apart")
    }

    /// The next episode at the end, as the Apple TV app's "Play Next
    /// Episode" does: it plays in the same player screen (the player used
    /// to close).
    func testNextEpisodeAtEnd() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        configure(server, ["episode_resume": "580"])
        defer { configure(server, ["reset": "1"]) }
        app.launch()
        let episode = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-' AND label CONTAINS 'Case 3'")).firstMatch
        XCTAssertTrue(episode.waitForExistence(timeout: 20), "no episode in Continue Watching")
        episode.tap()
        let item = app.staticTexts["debug-item"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "the episode didn't play")
        let first = item.label
        var gone = 0
        var now = first
        for _ in 0..<80 where now == first {
            usleep(500_000)
            if !item.exists { gone += 1 } else { now = item.label }
        }
        XCTAssertEqual(gone, 0, "the player closed at the end")
        XCTAssertNotEqual(now, first, "the next episode didn't play")
        sleep(2)
        shot("next episode playing")
        XCTAssertEqual(playerState()?.playing, true, "the next episode isn't playing")
    }

    /// Sideways, as in the Apple TV app: with Continue Watching open the
    /// play controls go, and the titles are pictures along the bottom.
    func testContinueWatchingInLandscape() throws {
        // iPhone: an iPad keeps its full layout when turned.
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone's sideways layout")
        openFilm()
        controlsUp()
        app.tapControl("Rotate to landscape") { self.app.buttons["Rotate to portrait"].exists }
        sleep(3)
        controlsUp()
        app.tapPill("Continue Watching")
        sleep(1)
        shot("continue watching landscape")
        XCTAssertGreaterThan(app.frame.width, app.frame.height, "not sideways")
        // ("Play" would also find the film page's, under the player.)
        XCTAssertFalse(app.buttons["Back 10 seconds"].firstMatch.exists, "the play controls stayed with the panel open")
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Case 3'")).firstMatch
        XCTAssertTrue(card.exists, "no titles in Continue Watching")
        XCTAssertEqual(card.frame.width, 202, accuracy: 1, "not Apple's picture card: \(card.frame)")
        app.tapControl("Rotate to portrait") { self.app.buttons["Rotate to landscape"].exists }
    }

    /// Sideways with Info open, everything stays on the screen. Regression
    /// (delegated audit): Close was pushed 66 points above the top.
    func testInfoInLandscapeKeepsClose() throws {
        // iPhone: an iPad keeps its full layout when turned.
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone's sideways layout")
        openFilm()
        controlsUp()
        tapPlayPause(playing: false)
        app.tapControl("Rotate to landscape") { self.app.buttons["Rotate to portrait"].exists }
        sleep(3)
        controlsUp()
        app.tapPill("Info")
        sleep(1)
        shot("info landscape")
        let screen = app.frame
        let close = app.buttons["Close player"].firstMatch.frame
        let start = app.buttons["From Beginning"].firstMatch.frame
        XCTAssertGreaterThanOrEqual(close.minY, 0, "Close is off the top: \(close) on \(screen)")
        XCTAssertLessThanOrEqual(start.maxY, screen.maxY, "From Beginning is off the bottom: \(start) on \(screen)")
        app.tapControl("Rotate to portrait") { self.app.buttons["Rotate to landscape"].exists }
    }

    /// Regression: with the film playing, the subtitles menu stayed open
    /// while the controls hid under it, and the player closed with them.
    func testSubtitlesMenuKeepsControls() {
        openFilm()
        controlsUp()
        app.tapControl("Audio and Subtitles") { self.app.buttons["Off"].exists }
        sleep(5)
        shot("subtitles menu after 5 s")
        XCTAssertTrue(app.buttons["Off"].firstMatch.exists, "the menu closed")
        XCTAssertTrue(app.buttons["Close player"].firstMatch.exists, "the controls went with the menu open")
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
        tapPlayPause(playing: false)
        sleep(1)
        // Regression: the tests' readouts over the button sent the tap to
        // its corner, which hid the controls instead.
        XCTAssertEqual(playerState()?.playing, false, "Pause didn't pause")
        shot("portrait paused")
        app.tapControl("Audio and Subtitles") { self.app.buttons["Off"].exists }
        sleep(1)
        shot("portrait track menu")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        sleep(1)
        app.tapPill("Info")
        sleep(1)
        shot("portrait info panel")
        app.tapPill("Info")
        sleep(1)
        tapPlayPause(playing: true)
        sleep(5)
        // Turned with the player's own button (the simulator ignores a
        // turned device here).
        app.tap()
        usleep(600_000)
        app.tapControl("Rotate to landscape") { self.app.buttons["Rotate to portrait"].exists }
        sleep(3)
        shot("landscape after turn")
        sleep(5)
        shot("landscape hidden")
        app.tap()
        usleep(600_000)
        shot("landscape controls")
        tapPlayPause(playing: false)
        sleep(1)
        shot("landscape paused")
        sleep(5)
        shot("landscape paused later")
        // Info in landscape: everything stays on the screen.
        app.tapPill("Info")
        sleep(1)
        shot("landscape info")
        let screen = app.windows.firstMatch.frame
        let closeButton = app.buttons["Close player"].firstMatch.frame
        let fromStart = app.buttons["From Beginning"].firstMatch
        XCTAssertTrue(screen.contains(closeButton), "Close went off the screen: \(closeButton) in \(screen)")
        XCTAssertTrue(fromStart.exists && screen.contains(fromStart.frame), "From Beginning went off the screen")
        app.tapPill("Info")
        sleep(1)
        tapPlayPause(playing: true)
        sleep(1)
        shot("landscape resumed")
        // Closing turns the app upright again.
        app.tapControl("Close player") { !self.app.staticTexts["debug-position"].exists }
        sleep(2)
        shot("closed")
    }
}

extension XCUIApplication {
    /// Taps a player control as a viewer would: the controls brought up
    /// first if they're away, the tap at the control's point, and tried
    /// again if they went before it landed (on a slow machine, such as the
    /// CI's, a query can take longer than the controls stay up). `until`:
    /// what the tap must bring about.
    @discardableResult
    func tapControl(_ control: XCUIElement, until done: (() -> Bool)? = nil,
                    file: StaticString = #filePath, line: UInt = #line) -> Bool {
        for _ in 0..<3 {
            if !control.isHittable {
                coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
                _ = control.waitForExistence(timeout: 3)
                guard control.isHittable else { continue }
            }
            // The control itself (a point worked out from its frame missed
            // sideways); gone before the tap landed, that's tried again.
            let options = XCTExpectedFailure.Options()
            options.isStrict = false
            XCTExpectFailure("the controls hid before the tap", options: options) { control.tap() }
            guard let done else { return true }
            for _ in 0..<10 {
                if done() { return true }
                usleep(300_000)
            }
        }
        XCTFail("tapping \(control) didn't work", file: file, line: line)
        return false
    }

    @discardableResult
    func tapControl(_ label: String, until done: (() -> Bool)? = nil,
                    file: StaticString = #filePath, line: UInt = #line) -> Bool {
        tapControl(buttons[label].firstMatch, until: done, file: file, line: line)
    }

    /// A pill ("Info", "Continue Watching"): opened or closed.
    @discardableResult
    func tapPill(_ label: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let pill = buttons[label].firstMatch
        let wasOpen = pill.exists && pill.isSelected
        return tapControl(pill, until: { pill.exists && pill.isSelected != wasOpen }, file: file, line: line)
    }
}

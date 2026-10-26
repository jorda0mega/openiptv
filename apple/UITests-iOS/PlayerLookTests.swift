import XCTest

/// iPhone: the app as a person uses it, with a screenshot at each step
/// (written to /tmp/openiptv/uitest-ios on the Mac). Run with
/// `xcodebuild test -scheme OpenIPTV` on an iPhone simulator, signed in to
/// the test server (scripts/mock_server.py) through TEST_RUNNER_DEBUG_EMBY.
final class PlayerLookTests: XCTestCase {
    let app = XCUIApplication()
    private let shots = URL(fileURLWithPath: "/tmp/openiptv/uitest-ios")
    private var step = 0

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        if let account = ProcessInfo.processInfo.environment["DEBUG_EMBY"] {
            app.launchEnvironment["OPENREEL_DEBUG_EMBY"] = account
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

    func openFilm(_ arguments: [String] = [], titled title: String? = nil) {
        app.launchArguments = ["-debugSearch", title?.lowercased() ?? "animals"] + arguments
        app.launch()
        sleep(4)
        // iPhone: the tab bar at the bottom; iPad: the one at the top.
        let tab = app.tabBars.buttons["Search"].firstMatch
        (tab.exists ? tab : app.buttons["Search"].firstMatch).tap()
        sleep(3)
        // The film, not the show "Animals." (first on a fresh simulator,
        // before IMDb's ratings have come to rank them).
        let result = app.buttons.matching(title.map { NSPredicate(format: "label BEGINSWITH %@", $0) }
            ?? NSPredicate(format: "label BEGINSWITH 'Animals' AND NOT label BEGINSWITH 'Animals.'")).firstMatch
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
            app.buttons["Forward 10 seconds"].firstMatch.tap()
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
        let raw = app.staticTexts["debug-pip"].firstMatch.label
        print("PIP state \(String(describing: first)) then \(String(describing: later)) raw \(raw)")
        guard let first, let later, let before, let up else { return XCTFail("no Picture in Picture state") }
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
        assertNothingStopped()
    }

    func testSwipingHomeCarriesOnInPictureInPicture() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone, "no Picture in Picture in iPhone simulators")
        openFilm()
        sleep(4)
        XCUIDevice.shared.press(.home)
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let window = board.otherElements["Video"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "swiping home didn't start Picture in Picture")
        shot("swiped home")
        sleep(6)
        window.tap()
        let restore = board.buttons["Restore fullscreen"].firstMatch
        XCTAssertTrue(restore.waitForExistence(timeout: 3), "no Restore fullscreen in the window")
        restore.tap()
        sleep(6)
        shot("brought back")
        assertNothingStopped()
        XCTAssertEqual(playerState()?.playing, true, "not playing after coming back")
        controlsUp()
        XCTAssertTrue(app.buttons["Close player"].exists, "the player isn't up after coming back")
    }

    func testOpeningTheAppBringsTheFilmBackInline() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .phone, "no Picture in Picture in iPhone simulators")
        openFilm()
        sleep(4)
        XCUIDevice.shared.press(.home)
        let board = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let window = board.otherElements["Video"].firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5), "swiping home didn't start Picture in Picture")
        sleep(6)
        app.activate()
        sleep(6)
        shot("opened again")
        XCTAssertFalse(window.exists, "the floating window stayed up over the app")
        assertNothingStopped()
        XCTAssertEqual(playerState()?.playing, true, "not playing after coming back")
        controlsUp()
        XCTAssertTrue(app.buttons["Close player"].exists, "the player isn't up after coming back")
    }

    private func assertNothingStopped(file: StaticString = #filePath, line: UInt = #line) {
        let readout = app.staticTexts["debug-pip-gap"].firstMatch.label
        print("PIP gap \(readout)")
        for kind in ["start", "return"] {
            guard let part = readout.split(separator: "|").first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix(kind) }) else {
                XCTFail("no \(kind) in the gap readout: \(readout)", file: file, line: line)
                continue
            }
            let fields = gapNumbers(in: part)
            XCTAssertEqual(fields["seeks"], 0, "\(kind): libmpv jumped back to decode again: \(part)", file: file, line: line)
            XCTAssertEqual(fields["restarts"], 0, "\(kind): libmpv restarted playback: \(part)", file: file, line: line)
            XCTAssertEqual(fields["paused"], 0, "\(kind): the film paused: \(part)", file: file, line: line)
            for (field, what) in [("time", "the film"), ("audio", "the sound"), ("frames", "the picture")] {
                XCTAssertLessThan(fields[field] ?? .max, 150, "\(kind): \(what) stopped for \(fields[field] ?? -1) ms: \(part)", file: file, line: line)
            }
        }
    }

    private func gapNumbers(in part: Substring) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: part.split(separator: " ").compactMap { word -> (String, Int)? in
            let pair = word.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, let value = Int(pair[1]) else { return nil }
            return (String(pair[0]), value)
        })
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
            app.buttons["Forward 10 seconds"].firstMatch.tap()
            usleep(400_000)
        }
        sleep(3)
        controlsUp()
        let closed = try XCTUnwrap(position(), "no position")
        app.buttons["Close player"].firstMatch.tap()
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

    /// Leaving the app while a film plays (another app, the Home Screen) and
    /// coming back: the film plays on with its picture moving. Regression:
    /// the picture stayed frozen after coming back.
    /// The screen stays on while a film plays, and may sleep again when
    /// it's paused, as with Apple's player (which tells the system by
    /// itself; libmpv doesn't). Regression: the phone locked, and the
    /// Apple TV slept, in the middle of a film.
    func testScreenStaysOnWhilePlaying() {
        openFilm()
        sleep(3)
        let awake = app.staticTexts["debug-awake"].firstMatch
        XCTAssertTrue(awake.waitForExistence(timeout: 5), "no awake readout")
        XCTAssertEqual(awake.label, "awake", "the screen may sleep while the film plays")
        controlsUp()
        app.buttons["Pause"].firstMatch.tap()
        sleep(1)
        XCTAssertEqual(awake.label, "idle", "the screen is kept on while paused")
        controlsUp()
        app.buttons["Play"].firstMatch.tap()
        sleep(1)
        XCTAssertEqual(awake.label, "awake", "the screen may sleep after playing again")
    }

    func testPictureMovesAfterLeavingApp() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "the film goes on in Picture in Picture")
        openFilm()
        sleep(5)
        XCTAssertTrue(pictureMoves(), "the picture doesn't move before leaving")
        XCUIDevice.shared.press(.home)
        sleep(6)
        app.activate()
        sleep(3)
        shot("back in the app")
        // The picture went off while away and came back through a fresh
        // video output (the simulator lets an app draw in the background,
        // so only this shows the fix there; a device froze without it).
        XCTAssertEqual(app.staticTexts["debug-away"].firstMatch.label, "1", "the picture didn't go off while away")
        // A loaded simulator can take a few seconds to draw again; a frozen
        // picture never moves.
        var moving = false
        for _ in 0..<5 where !moving { moving = pictureMoves() }
        XCTAssertTrue(moving, "the picture is frozen after coming back")
        XCTAssertEqual(playerState()?.playing, true, "not playing after coming back")
    }

    /// Whether the picture in the middle of the screen changes within a
    /// second (the test film always moves).
    private func pictureMoves() -> Bool {
        let area = CGRect(x: app.frame.width * 0.15, y: app.frame.midY - 50, width: app.frame.width * 0.7, height: 100)
        let before = samples(in: area)
        usleep(1_200_000)
        let after = samples(in: area)
        let changed = zip(before, after).filter { abs(Int($0) - Int($1)) > 24 }.count
        return !before.isEmpty && changed > before.count / 50
    }

    /// Colour channels sampled every 6 pixels inside `area` of the screen.
    private func samples(in area: CGRect) -> [UInt8] {
        let shot = XCUIScreen.main.screenshot().image
        guard let image = shot.cgImage, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return [] }
        let scale = CGFloat(image.width) / shot.size.width
        let perPixel = image.bitsPerPixel / 8
        var out: [UInt8] = []
        for y in stride(from: Int(area.minY * scale), to: Int(area.maxY * scale), by: 6) {
            for x in stride(from: Int(area.minX * scale), to: Int(area.maxX * scale), by: 6)
            where x >= 0 && y >= 0 && x < image.width && y < image.height {
                let i = y * image.bytesPerRow + x * perPixel
                out += [bytes[i], bytes[i + 1], bytes[i + 2]]
            }
        }
        return out
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
    func controlsUp() {
        let close = app.buttons["Close player"].firstMatch
        // Above the middle: the middle is the play/pause button.
        let picture = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        if close.isHittable {
            // Up, but maybe about to hide (3 s after showing, while it
            // plays): hidden first, so they come up afresh. Regression:
            // they went as the test reached for a button on them. (If they
            // hid by themselves just before, this tap brings them back,
            // fresh: then that's that.)
            picture.tap()
            usleep(400_000)
        }
        if !close.isHittable {
            picture.tap()
            for _ in 0..<10 where !close.isHittable { usleep(200_000) }
        }
    }

    /// The player's second: from the app's debug readout (there whether
    /// or not the controls are up), else the bar ("Playback position"
    /// "00:01:12").
    func position() -> Double? {
        if let state = playerState() { return state.seconds.rounded() }
        let bar = app.otherElements["Playback position"].firstMatch
        let value = (bar.exists ? bar : app.descendants(matching: .any)["Playback position"].firstMatch).value as? String
        return value.map { $0.split(separator: ":").compactMap { Double($0) }.reduce(0) { $0 * 60 + $1 } }
    }

    func pipState() -> (playing: Bool, seconds: Double, clock: Double, startMs: Int)? {
        let text = app.staticTexts["debug-pip"].firstMatch.label
        guard text.hasPrefix("pip") else { return nil }
        let fields = Dictionary(uniqueKeysWithValues: text.split(separator: " ").dropFirst().compactMap { part -> (String, String)? in
            let pair = part.split(separator: "=", maxSplits: 1)
            return pair.count == 2 ? (String(pair[0]), String(pair[1])) : nil
        })
        guard let seconds = fields["seconds"].flatMap(Double.init),
              let clock = fields["clock"].flatMap(Double.init) else { return nil }
        return (fields["playing"] == "true", seconds, clock, fields["start"].flatMap(Int.init) ?? .max)
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

    /// Subtitles on the picture in portrait, at the picture's scale, as in
    /// the Apple TV app. Regression: sized by the (tall) window, they were
    /// huge and drawn under the picture, off the bottom of the screen.
    /// Needs the multi-track test server as for testPickedSubtitlesStay.
    func testSubtitlesOnPictureInPortrait() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MULTI_TRACK"] != nil, "needs the multi-track test file")
        openFilm(["-forgetTrackChoices", "YES"])
        app.tap()
        usleep(600_000)
        app.buttons["Audio and Subtitles"].firstMatch.tap()
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
            app.buttons["Play"].firstMatch.tap()
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
        app.buttons["Audio and Subtitles"].firstMatch.tap()
        sleep(1)
        let sdh = app.buttons.matching(NSPredicate(format: "label CONTAINS 'SDH'")).firstMatch
        XCTAssertTrue(sdh.waitForExistence(timeout: 3), "no SDH subtitles in the menu")
        sdh.tap()
        sleep(2)
        XCTAssertEqual(tracksPlaying(), "audio=eng subtitles=eng+sdh", "the SDH subtitles didn't come on")
        app.tap()
        usleep(600_000)
        app.buttons["Close player"].firstMatch.tap()
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
        app.buttons["Close player"].firstMatch.tap()
        let stop = app.staticTexts["debug-stop"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 3), "no stop readout")
        XCTAssertEqual(stop.label, "stop noted player=up", "the stop reached the page after the player had closed")
        let main = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Continue' OR label BEGINSWITH 'Resume'")).firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 3), "no play button on the page")
        shot("page after close")
        XCTAssertFalse(main.label.hasPrefix("Play"), "the page still says \(main.label)")
    }

    func testQualityDropsWithoutANote() {
        app.launchEnvironment["OPENREEL_DEBUG_LOWER_AFTER"] = "15"
        openFilm()
        let quality = app.staticTexts["debug-quality"].firstMatch
        let note = app.descendants(matching: .any)["player-note"].firstMatch
        var lowered = false, noted: String?
        for _ in 0..<80 where !lowered {
            usleep(500_000)
            if note.exists { noted = note.label }
            lowered = quality.exists && quality.label.hasPrefix("converted")
        }
        XCTAssertTrue(lowered, "the quality wasn't lowered: \(quality.exists ? quality.label : "no readout")")
        for _ in 0..<12 where noted == nil {
            usleep(500_000)
            if note.exists { noted = note.label }
        }
        print("NOTE \(noted ?? "none")")
        XCTAssertNil(noted, "a note showed when the quality dropped")
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
        mute.tap()
        XCTAssertTrue(app.buttons["Unmute"].waitForExistence(timeout: 2), "Mute didn't turn into Unmute")
    }

    func testSwipesTurnThePlayer() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom != .phone, "the swipes are iPhone only")
        openFilm()
        swipePicture(from: 0.35, to: 0.1)
        controlsUp()
        XCTAssertTrue(app.buttons["Rotate to portrait"].waitForExistence(timeout: 4), "a swipe up didn't turn it sideways")
        shot("swiped up")
        swipePicture(from: 0.2, to: 0.6)
        controlsUp()
        XCTAssertTrue(app.buttons["Rotate to landscape"].waitForExistence(timeout: 4), "a swipe down didn't turn it upright")
        shot("swiped down")
    }

    private func swipePicture(from start: CGFloat, to end: CGFloat) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: start))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: end)))
        sleep(2)
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
        sleep(4)
        if playerState()?.playing == false {
            controlsUp()
            app.buttons["Play"].firstMatch.tap()
            usleep(600_000)
        }
        let off = app.buttons["Off"].firstMatch
        // Regression: while the film played, a tap on "…" also counted as
        // a tap on the picture, which hid the controls and the menu.
        // Up before the server slows down (every second under a 3 s server
        // runs the buffer down).
        controlsUp()
        configure(server, ["video_delay": "3"])
        defer { configure(server, ["reset": "1"]) }
        app.buttons["Audio and Subtitles"].firstMatch.tap()
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

    /// A lower quality on a slow connection plays on from the same second:
    /// the server's converted version is the whole film (its playlist from
    /// the start, as Emby makes it, whatever second it's asked from), so
    /// it's played from where the film was. Regression: it was played from
    /// its start (the user: "it stops loading and then starts playing from
    /// the beginning"); the stream's own second, by its timestamps, tells.
    func testLowerQualityPlaysOnFromTheSameSecond() throws {
        app.launchEnvironment["OPENREEL_DEBUG_LOWER_AFTER"] = "15"
        openFilm()
        let quality = app.staticTexts["debug-quality"].firstMatch
        var lowered = false
        for _ in 0..<40 where !lowered {
            sleep(1)
            lowered = quality.exists && quality.label.hasPrefix("converted")
        }
        XCTAssertTrue(lowered, "the quality wasn't lowered: \(quality.exists ? quality.label : "no readout")")
        sleep(4)
        let stream = Double(app.staticTexts["debug-stream-time"].firstMatch.label) ?? -1
        let film = position() ?? -1
        XCTAssertGreaterThan(stream, 12, "the converted version plays from the film's start: its clock at \(stream) s, the film at \(film) s")
        XCTAssertEqual(stream, film, accuracy: 2, "the stream and the film's place differ")
    }

    /// A lower quality forty minutes into a film plays on. The test server
    /// converts as Emby does: the whole film listed, converted from where
    /// it's asked, a slow first segment, and the conversion started again
    /// wherever the player asks for a part it hasn't reached. Needs the
    /// two-hour test film (OPENIPTV_MOCK_VIDEO=…/long.mkv; TEST_RUNNER_LONG_FILM=1).
    func testLowerQualityDeepInAFilmPlaysOn() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LONG_FILM"] != nil, "needs the two-hour test film")
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        configure(server, ["emby_convert": "1", "convert_delay": "8"])
        try setResumePosition(server, "a9", at: 2400)
        app.launchEnvironment["OPENREEL_DEBUG_LOWER_AFTER"] = "15"
        openFilm(titled: "Oppenheimer")
        let opened = try XCTUnwrap(openedAt(), "the film didn't open")
        XCTAssertTrue((2370...2402).contains(opened), "the film opened at \(Int(opened)) s, not forty minutes in")
        let quality = app.staticTexts["debug-quality"].firstMatch
        var lowered = false
        for _ in 0..<40 where !lowered {
            sleep(1)
            lowered = quality.exists && quality.label.hasPrefix("converted")
        }
        XCTAssertTrue(lowered, "the quality wasn't lowered: \(quality.exists ? quality.label : "no readout")")
        let from = try XCTUnwrap(position(), "no position")
        var seen: [Double] = []
        for _ in 0..<40 {
            sleep(1)
            seen.append(position() ?? -1)
        }
        print("DEEP lowered at \(from): \(seen.map { Int($0) })")
        XCTAssertGreaterThan(seen.last ?? -1, from + 15, "the film stopped after the quality dropped: \(seen.map { Int($0) })")
    }

    /// Subtitles showing stay, in time, when a slow connection lowers the
    /// film to the server's converted version (a new stream, with none of
    /// them, its clock from 0 where it starts), and its audio is said in
    /// the language it had. Regression: the converted version played on
    /// with no subtitles ("audio=und subtitles=off"). Needs the French
    /// film with a file of a line a second (OPENIPTV_MOCK_VIDEO=…/foreign.mkv,
    /// OPENIPTV_MOCK_SUBTITLE_FILES="eng||…/seconds.srt", OPENIPTV_MOCK_RUNTIME=120;
    /// TEST_RUNNER_LOWER_QUALITY=1).
    func testSubtitlesStayAtLowerQuality() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LOWER_QUALITY"] != nil, "needs the French film with a line a second")
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        app.launchEnvironment["OPENREEL_DEBUG_LOWER_AFTER"] = "15"
        openFilm(["-forgetTrackChoices", "YES", "-forgetSubtitleTimings", "YES"])
        let line = app.staticTexts["debug-subtext"].firstMatch
        let quality = app.staticTexts["debug-quality"].firstMatch
        var lowered = false
        for _ in 0..<40 where !lowered {
            sleep(1)
            lowered = quality.exists && quality.label.hasPrefix("converted")
        }
        XCTAssertTrue(lowered, "the quality wasn't lowered: \(quality.exists ? quality.label : "no readout")")
        sleep(4)
        // The line for the second the film is at, each second for five.
        var seen: [String] = []
        for _ in 0..<5 {
            let at = position() ?? -1
            let shown = line.label
            seen.append("\(at): \(shown)")
            let second = Double(shown.replacingOccurrences(of: "SECOND ", with: ""))
            XCTAssertNotNil(second, "no subtitles at the lower quality: \(seen)")
            if let second { XCTAssertEqual(second, at, accuracy: 1.5, "the subtitles are out of time at the lower quality: \(seen)") }
            sleep(1)
        }
        shot("subtitles at the lower quality")
        XCTAssertEqual(tracksPlaying(), "audio=fre subtitles=eng")
    }

    /// The first subtitles picked show without stopping the picture, even
    /// from a slow server. Regression: the picture stopped for a moment the
    /// first time subtitles were picked (later switches were instant).
    /// Needs the multi-track test server as for testPickedSubtitlesStay.
    /// The first subtitles picked show from the server's copy of the film's
    /// own track, already on the device: the player doesn't go back into
    /// the film to read the line on screen. Regression: it did (mpv's
    /// "refresh seek", ten seconds back), and on a real film, tens of
    /// megabytes in those ten seconds, the picture stopped on the first
    /// pick. The test film is too small for the pause to show, so the
    /// relay counts the reads back.
    func testFirstSubtitlesReadNothingBack() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MULTI_TRACK"] != nil, "needs the multi-track test file")
        openFilm(["-forgetTrackChoices", "YES"])
        // The copies come meanwhile.
        sleep(8)
        let readout = app.staticTexts["debug-reads-back"].firstMatch
        XCTAssertTrue(readout.waitForExistence(timeout: 5), "no reads-back readout")
        let before = Int(readout.label) ?? -1
        controlsUp()
        app.buttons["Audio and Subtitles"].firstMatch.tap()
        let off = app.buttons["Off"].firstMatch
        XCTAssertTrue(off.waitForExistence(timeout: 3), "no subtitles menu")
        let english = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'English'")).allElementsBoundByIndex
            .first { $0.frame.minY > off.frame.minY }
        try XCTUnwrap(english, "no English subtitles").tap()
        sleep(3)
        XCTAssertEqual(tracksPlaying(), "audio=eng subtitles=eng")
        let after = Int(readout.label) ?? -1
        XCTAssertEqual(after, before, "picking subtitles went back into the film to read it again")
    }

    /// Spanish subtitles inside the film, picked late in it, before the
    /// server has sent its copy: the line for the second on screen shows
    /// at once, the film plays on, and nothing comes from the server a
    /// second time. mpv reads the file again from ten seconds back for a
    /// track it hasn't been reading, and the relay is to have those bytes.
    /// Regression: full (1 GB on a real film, 200 MB here), the relay let
    /// everything behind go and began again at the newest bytes, so for a
    /// while those came from the server: 3.9 s stopped. Needs the film from
    /// scripts/make_big_film.sh (OPENIPTV_MOCK_VIDEO=…/big.mkv,
    /// OPENIPTV_MOCK_RUNTIME=240; TEST_RUNNER_BIG_FILM=1).
    func testSubtitlesPickedLateInAFilmReadNothingAgain() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BIG_FILM"] != nil, "needs the 16 Mbps film with a line a second")
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        configure(server, ["reference_delay": "900"])
        defer { configure(server, ["reset": "1"]) }
        app.launchEnvironment["OPENREEL_DEBUG_RELAY_KEEP_MB"] = "200"
        app.launchEnvironment["OPENREEL_DEBUG_READAHEAD"] = "60"
        openFilm(["-forgetTrackChoices", "YES", "-forgetServerSubtitles", "YES"])
        for _ in 0..<90 where (position() ?? 0) < 98 { sleep(1) }
        XCTAssertGreaterThanOrEqual(position() ?? 0, 98, "the film didn't reach a minute and a half")
        let timing = app.staticTexts["debug-subs-timing"].firstMatch
        let events = { timing.label.components(separatedBy: " | ") }
        func pick(_ language: String) -> (switched: String?, shown: String?, stalls: [String], line: String, at: Double, again: Int) {
            let before = events().filter { $0.hasPrefix("switch ") }.count
            let sentBefore = videoBytes(server).again
            controlsUp()
            app.buttons["Audio and Subtitles"].firstMatch.tap()
            let off = app.buttons["Off"].firstMatch
            XCTAssertTrue(off.waitForExistence(timeout: 3), "no subtitles menu")
            let track = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", language)).allElementsBoundByIndex
                .first { $0.frame.minY > off.frame.minY }
            XCTAssertNotNil(track, "no \(language) subtitles")
            track?.tap()
            var switched: String?, shown: String?
            for _ in 0..<80 where shown == nil {
                usleep(250_000)
                switched = events().filter { $0.hasPrefix("switch ") }.dropFirst(before).first
                let n = switched?.split(separator: " ").first { $0.hasPrefix("n=") }
                shown = n.flatMap { n in events().first { $0.hasPrefix("shown ") && $0.split(separator: " ").contains(n) } }
            }
            let readout = app.staticTexts["debug-subtext"].firstMatch
            for _ in 0..<8 where shown != nil && readout.label.isEmpty { usleep(250_000) }
            let line = readout.label, at = position() ?? -1
            sleep(8)
            let n = switched?.split(separator: " ").first { $0.hasPrefix("n=") }
            let stalls = events().filter { $0.hasPrefix("rebuffer ") && n.map($0.split(separator: " ").contains) == true }
            return (switched, shown, stalls, line, at, videoBytes(server).again - sentBefore)
        }
        let english = pick("English"), spanish = pick("Spanish")
        for (name, result) in [("English", english), ("Spanish", spanish)] {
            print("LATE \(name): \(result.switched ?? "no switch") ; \(result.shown ?? "no line in 20 s") ; "
                  + "\(result.stalls.isEmpty ? "no stall" : result.stalls.joined(separator: ", ")) ; line \(result.line) at \(result.at) s ; "
                  + String(format: "%.1f MB sent again", Double(result.again) / 1e6))
        }
        XCTAssertNotNil(spanish.shown, "no Spanish line in 20 s")
        // mpv reads the ten seconds back again even from the device: a
        // moment's wait at most (0.1 s on the simulator).
        let stopped = spanish.stalls.compactMap { $0.split(separator: " ").first { $0.hasPrefix("ms=") }.flatMap { Int($0.dropFirst(3)) } }
        XCTAssertLessThanOrEqual(stopped.reduce(0, +), 300, "the film stopped when Spanish was picked: \(spanish.stalls)")
        XCTAssertEqual(Double(spanish.line.replacingOccurrences(of: "ES ", with: "")) ?? -1, spanish.at, accuracy: 2,
                       "not the line for the second on screen")
        XCTAssertLessThan(spanish.again, 1 << 20, "picking Spanish read the film again from the server")
        XCTAssertEqual(tracksPlaying(), "audio=eng subtitles=spa")
    }

    private func videoBytes(_ server: URL) -> (sent: Int, again: Int) {
        var counts: [String: Int] = [:]
        let done = expectation(description: "video bytes")
        URLSession.shared.dataTask(with: server.appending(path: "mock/video_bytes")) { data, _, _ in
            counts = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Int] }) ?? [:]
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return (counts["sent"] ?? -1, counts["again"] ?? -1)
    }

    private func readsBackPickingEnglish() throws -> Int {
        let readout = app.staticTexts["debug-reads-back"].firstMatch
        XCTAssertTrue(readout.waitForExistence(timeout: 5), "no reads-back readout")
        let before = Int(readout.label) ?? -1
        controlsUp()
        app.buttons["Audio and Subtitles"].firstMatch.tap()
        let off = app.buttons["Off"].firstMatch
        XCTAssertTrue(off.waitForExistence(timeout: 3), "no subtitles menu")
        let below = app.buttons.allElementsBoundByIndex.filter { $0.frame.minY > off.frame.minY }
        shot("subtitles menu")
        let english = below.first { $0.label == "English" }
        try XCTUnwrap(english, "no English subtitles").tap()
        sleep(3)
        XCTAssertEqual(tracksPlaying(), "audio=eng subtitles=eng")
        return (Int(readout.label) ?? -1) - before
    }

    func testCopyOfTheFilmsTrackWaitsForASlowServer() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MULTI_TRACK"] != nil, "needs the multi-track test file")
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        configure(server, ["reference_delay": "25"])
        defer { configure(server, ["reset": "1"]) }
        openFilm(["-forgetTrackChoices", "YES", "-forgetServerSubtitles", "YES"])
        sleep(55)
        XCTAssertEqual(try readsBackPickingEnglish(), 0, "picking English read back into the film: its copy never came")
    }

    func testCopyOfTheFilmsTrackIsAskedAgainAfterAFailure() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MULTI_TRACK"] != nil, "needs the multi-track test file")
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        configure(server, ["subtitle_fail": "1"])
        defer { configure(server, ["reset": "1"]) }
        openFilm(["-forgetTrackChoices", "YES", "-forgetServerSubtitles", "YES", "-quickSubtitleRetries", "YES"])
        sleep(5)
        let english = subtitleRequests(server).filter { $0 == "\(app.staticTexts["debug-item"].firstMatch.label):4" }
        XCTAssertEqual(english.count, 2, "the English copy wasn't asked for again: \(subtitleRequests(server))")
        XCTAssertEqual(try readsBackPickingEnglish(), 0, "picking English read back into the film: its copy never came")
    }

    func testEachSubtitleTrackIsAskedForOnce() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SUBTITLE_FILES"] != nil
                          && ProcessInfo.processInfo.environment["MULTI_TRACK"] != nil, "needs the multi-track film with a file beside it")
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        openFilm(["-forgetTrackChoices", "YES", "-forgetServerSubtitles", "YES"])
        sleep(5)
        let asked = subtitleRequests(server)
        XCTAssertFalse(asked.isEmpty, "no subtitles were asked for")
        XCTAssertEqual(asked.count, Set(asked).count, "a track was asked for more than once: \(asked.sorted())")
    }

    func testSubtitleRequestsKeepTheKeyOutOfTheirAddress() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SUBTITLE_FILES"] != nil
                          && ProcessInfo.processInfo.environment["MULTI_TRACK"] != nil, "needs the multi-track film with a file beside it")
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        configure(server, ["subtitle_redirect": "1"])
        defer { configure(server, ["reset": "1"]) }
        openFilm(["-forgetTrackChoices", "YES", "-forgetServerSubtitles", "YES"])
        sleep(5)
        XCTAssertFalse(subtitleRequests(server).isEmpty, "no subtitles were asked for")
        XCTAssertEqual(subtitleRequests(server, "keyed"), [], "subtitles were asked for with the key in the address")
        XCTAssertEqual(subtitleRequests(server, "headerless"), [], "subtitles were asked for without the key in a header")
    }

    func testFilmRequestsKeepTheKeyOutOfTheirAddress() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        configure(server, ["video_delay": "2"])
        defer { configure(server, ["reset": "1"]) }
        openFilm()
        controlsUp()
        app.buttons["Close player"].firstMatch.tap()
        sleep(3)
        XCTAssertTrue(keyChecks(server, "items").contains { $0.hasPrefix("stream:") }, "no film was streamed")
        XCTAssertFalse(keyChecks(server, "items").contains("websocket"), "the app opened Emby's websocket")
        XCTAssertTrue(keyChecks(server, "cancelled").contains { $0.hasPrefix("stream:") }, "no stream was cut off")
        XCTAssertEqual(keyChecks(server, "keyed"), [], "asked with the key in the address")
        XCTAssertEqual(keyChecks(server, "headerless"), [], "asked without the key in a header")
    }

    func testSpeedCheckKeepsTheKeyOutOfItsAddress() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        app.launchEnvironment["OPENREEL_DEBUG_LOWER_AFTER"] = "5"
        openFilm()
        let quality = app.staticTexts["debug-quality"].firstMatch
        var lowered = false
        for _ in 0..<40 where !lowered {
            sleep(1)
            lowered = quality.exists && quality.label.hasPrefix("converted")
        }
        XCTAssertTrue(lowered, "the quality wasn't lowered: \(quality.exists ? quality.label : "no readout")")
        for _ in 0..<40 where !keyChecks(server, "items").contains(where: { $0.hasPrefix("speed:") }) { sleep(1) }
        XCTAssertTrue(keyChecks(server, "items").contains { $0.hasPrefix("speed:") }, "the connection wasn't tested")
        XCTAssertTrue(keyChecks(server, "items").contains { $0.hasPrefix("hls:") }, "no converted version was asked for")
        XCTAssertEqual(keyChecks(server, "keyed"), [], "asked with the key in the address")
        XCTAssertEqual(keyChecks(server, "headerless"), [], "asked without the key in a header")
    }

    /// A film's page got its likeliest subtitles ready (the server's copy of
    /// its own track, the whole film read for it): left, the copy stops.
    func testPagesLeftStopTheirSubtitleCopies() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MULTI_TRACK"] != nil, "needs the multi-track test file")
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        configure(server, ["reference_delay": "10"])
        defer { configure(server, ["reset": "1"]) }
        app.launchArguments = ["-debugSearch", "animals", "-forgetServerSubtitles", "YES"]
        app.launch()
        sleep(4)
        let tab = app.tabBars.buttons["Search"].firstMatch
        (tab.exists ? tab : app.buttons["Search"].firstMatch).tap()
        let films = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Animals' AND NOT label BEGINSWITH 'Animals.'"))
        XCTAssertTrue(films.firstMatch.waitForExistence(timeout: 8), "no search result")
        for n in 0..<2 {
            films.element(boundBy: n).tap()
            sleep(3)
            shot("film page \(n + 1)")
            app.navigationBars.buttons.firstMatch.tap()
            sleep(1)
        }
        sleep(12)
        XCTAssertFalse(subtitleRequests(server, "cut").isEmpty, "a page left behind kept asking for its subtitles: \(subtitleRequests(server))")
    }

    func testPlaybackAddressesHoldNoKey() throws {
        openFilm()
        let keyed = app.staticTexts["debug-keyed"].firstMatch
        XCTAssertTrue(keyed.waitForExistence(timeout: 5), "no keyed-addresses readout")
        XCTAssertEqual(keyed.label, "0", "addresses of the playback carry the key")
    }

    func testConvertedVersionSendsTheKeyOnlyInAHeader() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        app.launchEnvironment["OPENREEL_DEBUG_LOWER_AFTER"] = "5"
        openFilm()
        let quality = app.staticTexts["debug-quality"].firstMatch
        var lowered = false
        for _ in 0..<40 where !lowered {
            sleep(1)
            lowered = quality.exists && quality.label.hasPrefix("converted")
        }
        XCTAssertTrue(lowered, "the quality wasn't lowered: \(quality.exists ? quality.label : "no readout")")
        sleep(3)
        let from = position() ?? 0
        sleep(6)
        XCTAssertGreaterThan(position() ?? 0, from + 3, "the converted version doesn't play")
        let asked = keyChecks(server, "items")
        for kind in ["hls:", "playlist:", "segment:"] {
            XCTAssertTrue(asked.contains { $0.hasPrefix(kind) }, "no \(kind) request: \(Set(asked.map { $0.split(separator: ":").first ?? "" }))")
        }
        XCTAssertEqual(keyChecks(server, "keyed"), [], "asked with the key in the address")
        XCTAssertEqual(keyChecks(server, "headerless"), [], "asked without the key in a header")
        // The player follows a redirect anywhere with the key it is given.
        let player = keyChecks(server, "player")
        XCTAssertEqual(player, [], "the player asked the server itself: \(Set(player.map { $0.split(separator: ":").first ?? "" }))")
    }

    func testSecondPlayAsksForNoSubtitles() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SUBTITLE_FILES"] != nil
                          && ProcessInfo.processInfo.environment["MULTI_TRACK"] != nil, "needs the multi-track film with a file beside it")
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        let uniquelyNamedFilm = "Oppenheimer"
        openFilm(["-forgetTrackChoices", "YES", "-forgetServerSubtitles", "YES"], titled: uniquelyNamedFilm)
        sleep(5)
        let film = app.staticTexts["debug-item"].firstMatch.label
        XCTAssertFalse(subtitleRequests(server).filter { $0.hasPrefix("\(film):") }.isEmpty, "the first play asked for no subtitles")
        app.terminate()
        let mark = markTime(server)
        openFilm(["-forgetTrackChoices", "YES"], titled: uniquelyNamedFilm)
        sleep(5)
        XCTAssertEqual(app.staticTexts["debug-item"].firstMatch.label, film, "the second play is another film")
        XCTAssertEqual(subtitleRequests(server, since: mark).filter { $0.hasPrefix("\(film):") }, [], "the second play asked for subtitles again")
        XCTAssertEqual(try readsBackPickingEnglish(), 0, "picking English read back into the film: the kept copy wasn't added")
        controlsUp()
        app.buttons["Audio and Subtitles"].firstMatch.tap()
        let sdh = app.buttons["English SDH"].firstMatch
        XCTAssertTrue(sdh.waitForExistence(timeout: 3), "the kept file isn't in the menu")
        sdh.tap()
        sleep(2)
        XCTAssertEqual(tracksPlaying(), "audio=eng subtitles=eng+sdh")
    }

    /// A film in two copies, one French-only and one in English: the
    /// English one plays, sharper or not (an iPhone otherwise takes the
    /// 1080p copy). Regression: the copy was chosen by picture alone, and a
    /// French-only copy left no English or Spanish to pick (the user:
    /// Asterix only played in French). Needs the multi-track test film.
    func testCopyInTheLanguagePlays() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MULTI_TRACK"] != nil, "needs the multi-track test file")
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        configure(server, ["copy_audio": "a8:fre"])
        app.launchArguments = ["-debugSearch", "dune", "-forgetTrackChoices", "YES"]
        app.launch()
        sleep(4)
        let tab = app.tabBars.buttons["Search"].firstMatch
        (tab.exists ? tab : app.buttons["Search"].firstMatch).tap()
        sleep(3)
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Dune: Part Two'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 8), "no Dune: Part Two")
        result.tap()
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Resume' OR label BEGINSWITH 'Continue'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 8), "no Play")
        play.tap()
        let item = app.staticTexts["debug-item"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 15), "no player")
        sleep(3)
        XCTAssertEqual(item.label, "k8", "the French-only copy played")
        XCTAssertTrue(tracksPlaying().hasPrefix("audio=eng"), "not in English: \(tracksPlaying())")
    }

    /// Dune: Part Two in two copies, made where nobody knows (no
    /// production country on the server, as Dragon Ball Z on the user's):
    /// one copy's sound is a Spanish dub first, then Japanese; the other
    /// has English. The English copy plays, subtitles off. Regression: the
    /// dub, first in its copy, was taken for the original language, so the
    /// title counted as Spanish-made and played in Spanish (with Spanish
    /// subtitles) while another copy had English. Needs the multi-track
    /// test film with no country (TEST_RUNNER_MULTI_TRACK=1).
    func testUnknownOriginPlaysTheEnglishCopy() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MULTI_TRACK"] != nil, "needs the multi-track test file")
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        configure(server, ["copy_audio": "a8:spa+spa+jpn"])
        playDune(["-forgetTrackChoices", "YES"])
        let item = app.staticTexts["debug-item"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 15), "no player")
        sleep(3)
        XCTAssertEqual(item.label, "k8", "the copy with the Spanish dub played")
        XCTAssertEqual(tracksPlaying(), "audio=eng subtitles=off")
    }

    /// A film stopped 20 seconds in (under 5% of it, where Emby keeps no
    /// place, so its own Continue Watching leaves it out) is in Continue
    /// Watching the next time the app opens, Home built again from the
    /// server, and plays on from where it stopped. Regression: the user
    /// watched CSI under 2 minutes, and on reopening the app it wasn't in
    /// Continue Watching.
    func testShortWatchStaysInContinueWatching() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        configure(server, ["min_resume_pct": "5"])
        openFilm()
        let item = app.staticTexts["debug-item"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 15), "no player")
        let film = item.label
        sleep(20)
        let stopped = position() ?? 0
        XCTAssertGreaterThan(stopped, 10, "it didn't play")
        controlsUp()
        app.buttons["Close player"].firstMatch.tap()
        sleep(3)
        app.terminate()

        app.launchEnvironment["OPENREEL_DEBUG_HOME_STALE"] = "1"
        app.launchArguments = []
        app.launch()
        let home = app.tabBars.buttons["Home"].firstMatch
        if home.waitForExistence(timeout: 10) { home.tap() }
        let card = app.buttons["continue-\(film)"].firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "the film watched 20 s isn't in Continue Watching")
        card.tap()
        let resume = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Resume' OR label BEGINSWITH 'Continue'")).firstMatch
        let readout = app.staticTexts["debug-position"].firstMatch
        let deadline = Date().addingTimeInterval(15)
        while !readout.exists, Date() < deadline {
            if resume.exists, resume.isHittable { resume.tap(); break }
            usleep(250_000)
        }
        XCTAssertTrue(item.waitForExistence(timeout: 15), "it didn't play")
        sleep(2)
        XCTAssertEqual(position() ?? 0, stopped, accuracy: 8, "it didn't go on from where it stopped")
    }

    /// Two copies of a film whose server lists them with different IMDb ids
    /// but the same TMDb id (one copy's metadata is wrong) are one title:
    /// the English copy plays. Regression: copies were grouped by IMDb id
    /// first, so the user's two Dragon Ball Z shows (tt0214341, tt0121220;
    /// both TMDb 12971) were two titles, and the Spanish one couldn't give
    /// way to the English one, nor offer its sound. A fresh cache folder:
    /// the library is read with the ids as listed now. Needs
    /// TEST_RUNNER_MULTI_TRACK=1.
    func testCopiesWithDifferentIMDbAreOneTitle() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MULTI_TRACK"] != nil, "needs the multi-track test file")
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        configure(server, ["copy_audio": "a8:spa+spa+jpn", "imdb": "k8:tt0000001"])
        playDune(["-forgetTrackChoices", "YES", "-cacheFolder", "imdb-\(UUID().uuidString.prefix(8))"])
        let item = app.staticTexts["debug-item"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 15), "no player")
        sleep(3)
        XCTAssertEqual(item.label, "k8", "the copy with the Spanish dub played")
        XCTAssertEqual(tracksPlaying(), "audio=eng subtitles=off")
    }

    /// Spanish only another copy of the film has (Dune's two copies listed
    /// one in English, one in Spanish): the audio menu offers it after the
    /// file's own, and picked, that copy takes over from the same moment with
    /// no picture loading (the user: "I don't want the picture to load while
    /// the audio is switching"), and plays first next time. Regression: the
    /// menu listed only the playing file's tracks, so Dragon Ball Z's other
    /// copy (the user's Spanish one) couldn't be picked.
    func testAudioFromAnotherCopy() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        configure(server, ["copy_audio": "a8:spa,k8:eng"])
        playDune(["-forgetTrackChoices", "YES"])
        let item = app.staticTexts["debug-item"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 15), "no player")
        sleep(8)
        XCTAssertEqual(item.label, "k8", "not the copy in English")
        controlsUp()
        app.buttons["Audio and Subtitles"].firstMatch.tap()
        let spanish = app.buttons["Spanish"].firstMatch
        XCTAssertTrue(spanish.waitForExistence(timeout: 5), "no Spanish in the menu: \(app.buttons.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty })")
        // The film plays on meanwhile: where it is now, and when.
        let before = position() ?? 0
        let tapped = Date()
        spanish.tap()
        let loading = app.descendants(matching: .any)["Loading"]
        var loaded = false
        let deadline = Date().addingTimeInterval(30)
        while item.label != "a8", Date() < deadline {
            if loading.exists { loaded = true }
            usleep(100_000)
        }
        XCTAssertEqual(item.label, "a8", "the Spanish copy didn't play")
        XCTAssertFalse(loaded, "the picture loaded while the audio switched")
        let start = app.staticTexts["debug-start"].firstMatch.label
        XCTAssertTrue(start.hasPrefix("warm"), "the other copy wasn't ready when it took over: \(start)")
        sleep(3)
        // No jump back or ahead: as far on as the time since the tap.
        XCTAssertEqual(position() ?? 0, before + Date().timeIntervalSince(tapped), accuracy: 4,
                       "it didn't go on from the same moment")
        shot("spanish copy")

        // Next time: the copy with the language picked.
        controlsUp()
        app.buttons["Close player"].firstMatch.tap()
        sleep(2)
        app.terminate()
        playDune([])
        XCTAssertTrue(item.waitForExistence(timeout: 15), "no player the second time")
        sleep(3)
        XCTAssertEqual(item.label, "a8", "the language picked wasn't kept")
    }

    /// Dune: Part Two from Search, playing.
    private func playDune(_ arguments: [String]) {
        app.launchArguments = ["-debugSearch", "dune"] + arguments
        app.launch()
        sleep(4)
        let tab = app.tabBars.buttons["Search"].firstMatch
        (tab.exists ? tab : app.buttons["Search"].firstMatch).tap()
        sleep(3)
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Dune: Part Two'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 8), "no Dune: Part Two")
        result.tap()
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Resume' OR label BEGINSWITH 'Continue'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 8), "no Play")
        play.tap()
    }

    func testFirstSubtitlesKeepPictureMoving() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MULTI_TRACK"] != nil, "needs the multi-track test file")
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        // A real film's end (where its index is) isn't downloaded early;
        // the test film is small, so the read-ahead is kept short.
        app.launchEnvironment["OPENREEL_DEBUG_READAHEAD"] = "5"
        openFilm(["-forgetTrackChoices", "YES"])
        sleep(4)
        // Up before the server slows down: with 5 s read ahead, every second
        // under a 3 s server runs the buffer down (and the player turns to
        // the server's converted stream).
        controlsUp()
        // A server 3 s away from now on: the index must already be here.
        configure(server, ["video_delay": "3"])
        defer { configure(server, ["reset": "1"]) }
        app.buttons["Audio and Subtitles"].firstMatch.tap()
        let off = app.buttons["Off"].firstMatch
        XCTAssertTrue(off.waitForExistence(timeout: 3), "no subtitles menu")
        let english = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'English'")).allElementsBoundByIndex
            .first { $0.frame.minY > off.frame.minY }
        XCTAssertNotNil(english, "no English subtitles")
        english?.tap()
        // The longest the picture stood still in the next 3 seconds.
        let area = CGRect(x: app.frame.width * 0.15, y: app.frame.midY - 50, width: app.frame.width * 0.7, height: 100)
        var last = samples(in: area), lastChange = Date(), longest = 0.0
        let end = Date().addingTimeInterval(3)
        var log: [String] = []
        let start = Date()
        while Date() < end {
            let now = samples(in: area)
            // The test film's moving parts are thin: a few samples differ.
            let changed = zip(last, now).filter { abs(Int($0) - Int($1)) > 40 }.count >= 3
            log.append(String(format: "%.2f%@", Date().timeIntervalSince(start), changed ? "*" : ""))
            if ProcessInfo.processInfo.environment["SHOTS"] != nil { shot(String(format: "sub %.2f", Date().timeIntervalSince(start))) }
            if changed { longest = max(longest, Date().timeIntervalSince(lastChange)); lastChange = Date(); last = now }
        }
        print("SUBTITLE SAMPLES \(log.joined(separator: " "))")
        longest = max(longest, Date().timeIntervalSince(lastChange))
        print("SUBTITLE STILL \(longest)")
        XCTAssertLessThan(longest, 0.5, "the picture stood still \(longest) s when the first subtitles were picked")
        XCTAssertEqual(tracksPlaying(), "audio=eng subtitles=eng")
    }

    /// A title in Continue Watching other than the first (a player opens
    /// that one ahead) starts from the device: the start of its file, its
    /// index and the part where it resumes were fetched ahead, so a slow
    /// server doesn't hold it up. Regression: a resumed title waited for
    /// the server three times before its first frame (the user: "the
    /// video takes a while to load"), where one from the beginning played
    /// at once.
    func testContinueWatchingStartsFromDevice() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        stopped(server, item: "m5", seconds: 300)
        app.launch()
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-' AND label CONTAINS 'Movie 5'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "Movie 5 isn't in Continue Watching")
        let hero = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
        hero.press(forDuration: 0.1, thenDragTo: hero.withOffset(CGVector(dx: 0, dy: -300)))
        sleep(1)
        let row = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 300, dy: card.frame.midY))
        row.press(forDuration: 0.1, thenDragTo: row.withOffset(CGVector(dx: -150, dy: 0)))
        sleep(8)
        configure(server, ["video_delay": "1.5"])
        card.tap()
        let readout = app.staticTexts["debug-start"].firstMatch
        var parts: [Substring] = []
        for _ in 0..<40 where parts.count < 4 {
            usleep(250_000)
            parts = readout.exists ? readout.label.split(separator: " ") : []
        }
        shot("continue watching started")
        // "cold 0.6 at 300": how it started, seconds from the tap, where.
        guard parts.count == 4, let took = Double(parts[1]), let at = Double(parts[3]) else {
            return XCTFail("no start readout: \(parts)")
        }
        XCTAssertEqual(at, 300, accuracy: 8, "it didn't resume where it was stopped")
        XCTAssertLessThan(took, 1.2, "a resumed title took \(took) s to start from a slow server")
    }

    func testResumeMovedElsewhereWhileAwayPlaysFromThere() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        stopped(server, item: "m5", seconds: 30)
        app.launch()
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-' AND label CONTAINS 'Movie 5'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "Movie 5 isn't in Continue Watching")
        sleep(6)
        XCUIDevice.shared.press(.home)
        stopped(server, item: "m5", seconds: 80)
        sleep(2)
        app.activate()
        sleep(4)
        card.tap()
        let readout = app.staticTexts["debug-start"].firstMatch
        var parts: [Substring] = []
        for _ in 0..<60 where parts.count < 4 {
            usleep(250_000)
            parts = readout.exists ? readout.label.split(separator: " ") : []
        }
        guard parts.count == 4, let at = Double(parts[3]) else { return XCTFail("no start readout: \(parts)") }
        XCTAssertEqual(at, 80, accuracy: 8, "it didn't start where the other device left it")
    }

    /// An episode whose intro the server has marked (Emby's intro detection:
    /// chapters marked "IntroStart" and "IntroEnd"): "Skip Intro" shows
    /// during it, with the controls hidden too, and jumps to its end; then
    /// it's gone. The user asked for it (14 October).
    func testSkipIntro() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        configure(server, ["intro": "4,90", "episode_resume": "0"])
        app.launch()
        // Continue Watching's first card: the show, at its episode.
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "no Continue Watching")
        card.tap()
        let skip = app.buttons["Skip Intro"].firstMatch
        XCTAssertTrue(skip.waitForExistence(timeout: 20), "no Skip Intro during the intro")
        shot("skip intro")
        XCTAssertLessThan(position() ?? 999, 90, "Skip Intro came after the intro")
        skip.tap()
        sleep(2)
        XCTAssertGreaterThanOrEqual(position() ?? 0, 89, "Skip Intro didn't jump to the intro's end")
        XCTAssertFalse(skip.exists, "Skip Intro stayed after the intro")
    }

    /// An episode: "Episodes" beside Info lists its season (as on the
    /// show's page), the one playing marked; a tap on another plays it in
    /// the same player. The user asked for it (14 October).
    func testEpisodesInPlayer() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        // From its start (the test film is 10 min: resumed at 10:00 it ends,
        // and the next episode plays).
        configure(server, ["episode_resume": "0"])
        app.launch()
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "no Continue Watching")
        card.tap()
        let item = app.staticTexts["debug-item"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 15), "no player")
        XCTAssertEqual(item.label, "e203", "not the show's episode")
        sleep(3)
        controlsUp()
        let pill = app.buttons["Episodes"].firstMatch
        XCTAssertTrue(pill.waitForExistence(timeout: 5), "no Episodes beside Info")
        pill.tap()
        sleep(1)
        shot("episodes")
        // Season 2's eight, in order, the one playing marked.
        let rows = app.buttons.matching(NSPredicate(format: "label MATCHES '^[0-9]+\\. Case [0-9]+.*'")).allElementsBoundByIndex
            .sorted { $0.frame.minY < $1.frame.minY }
        XCTAssertEqual(rows.map { String($0.label.prefix(while: { $0 != "," })) },
                       (1...8).map { "\($0). Case \($0)" }, "not season 2's episodes in order")
        XCTAssertTrue(rows.first { $0.label.hasPrefix("3. Case 3") }?.label.contains("Playing") ?? false,
                      "the episode playing isn't marked: \(rows.map(\.label))")
        let fifth = try XCTUnwrap(rows.first { $0.label.hasPrefix("5. Case 5") })
        fifth.tap()
        for _ in 0..<40 where item.label != "e205" { usleep(250_000) }
        XCTAssertEqual(item.label, "e205", "the chosen episode didn't play")
        shot("episode 5 playing")
    }

    func testFailedWarmPlayerIsNotHandedOver() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        configure(server, ["video_fail": "1"])
        app.launch()
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "no Continue Watching")
        sleep(8)
        configure(server, ["video_fail": "0"])
        card.tap()
        let readout = app.staticTexts["debug-start"].firstMatch
        var parts: [Substring] = []
        for _ in 0..<60 where parts.count < 4 {
            usleep(250_000)
            parts = readout.exists ? readout.label.split(separator: " ") : []
        }
        shot("after a failed warm player")
        // "cold 0.6 at 1260": it opened afresh.
        guard parts.count == 4 else { return XCTFail("it never started (no start readout): \(parts)") }
        XCTAssertEqual(parts[0], "cold", "the failed player was handed over")
    }

    /// Tells the test server a title was stopped at `seconds` (its resume point).
    private func stopped(_ server: URL, item: String, seconds: Double) {
        var request = URLRequest(url: server.appending(path: "emby/Sessions/Playing/Stopped"))
        request.httpMethod = "POST"
        request.setValue("tok", forHTTPHeaderField: "X-Emby-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["ItemId": item, "PositionTicks": Int(seconds * 10_000_000)])
        let done = expectation(description: "stopped")
        URLSession.shared.dataTask(with: request) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
    }

    /// The audio and subtitles menu lists each language and kind once, in
    /// English and Spanish (and the film's own language), the best track of
    /// each; Spanish is the variant for where the film was made (a US film:
    /// Latin American). Regression: every track of the file showed, the
    /// same language several times ("English", "English", "French",
    /// "Spanish (Castellano)", "Spanish (Latino)"). Needs the test server
    /// with the duplicate-track film as a US film (OPENIPTV_MOCK_VIDEO=
    /// dupes.mkv, OPENIPTV_MOCK_COUNTRIES="United States of America";
    /// TEST_RUNNER_DUPES=1).
    func testTrackMenuHasNoDuplicates() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DUPES"] != nil, "needs the duplicate-track test film")
        openFilm(["-forgetTrackChoices", "YES"])
        controlsUp()
        app.buttons["Audio and Subtitles"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Off"].firstMatch.waitForExistence(timeout: 3), "no subtitles menu")
        shot("track menu")
        let words = ["English", "Spanish", "French", "Off", "Unknown", "Director", "Castellano", "Latino"]
        let items = app.buttons.allElementsBoundByIndex
            .filter { button in words.contains { button.label.hasPrefix($0) } && button.frame.height < 80 }
            .sorted { $0.frame.minY < $1.frame.minY }
            .map(\.label)
        XCTAssertEqual(items, ["English", "Spanish", "English (Commentary)", "Off", "English", "English SDH", "Spanish"])
        // English audio with its forced subtitles (signs, foreign lines),
        // which show by themselves and aren't in the menu.
        XCTAssertEqual(tracksPlaying(), "audio=eng subtitles=eng+forced")
        let spanish = app.buttons.matching(NSPredicate(format: "label == 'Spanish'")).allElementsBoundByIndex
            .max { $0.frame.minY < $1.frame.minY }
        spanish?.tap()
        sleep(2)
        XCTAssertEqual(tracksPlaying(), "audio=eng subtitles=spa~latinAmerica")
    }

    /// A film made in Spain starts in Spain's Spanish when the file also
    /// has Latin American Spanish (the user's rule: by where it was made).
    /// Needs the duplicate-track film as a Spanish film (OPENIPTV_MOCK_
    /// COUNTRIES=Spain; TEST_RUNNER_DUPES_SPAIN=1).
    func testSpainFilmStartsInSpainsSpanish() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DUPES_SPAIN"] != nil, "needs the duplicate-track film made in Spain")
        openFilm(["-forgetTrackChoices", "YES"])
        XCTAssertEqual(tracksPlaying(), "audio=spa~spain subtitles=off")
    }

    /// Subtitles kept in a file beside the film on the server show in the
    /// menu with the film's own and play when picked. Regression: only the
    /// film's own tracks showed; the server's files (downloaded subtitles,
    /// say) never did. Needs the multi-track US film with an English SDH
    /// file beside it (OPENIPTV_MOCK_SUBTITLE_FILES="eng|SDH|…/en-sdh.srt";
    /// TEST_RUNNER_SUBTITLE_FILES=1).
    func testServerSubtitleFilesShow() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SUBTITLE_FILES"] != nil, "needs a subtitle file beside the film")
        openFilm(["-forgetTrackChoices", "YES"])
        sleep(3)
        controlsUp()
        app.buttons["Audio and Subtitles"].firstMatch.tap()
        let sdh = app.buttons["English SDH"].firstMatch
        XCTAssertTrue(sdh.waitForExistence(timeout: 3), "the server's English SDH file isn't in the menu")
        shot("menu with the server's file")
        sdh.tap()
        sleep(2)
        XCTAssertEqual(tracksPlaying(), "audio=eng subtitles=eng+sdh")
    }

    /// A subtitle file from the server that runs late shows in time by
    /// itself: its lines are matched against the film's own subtitle track
    /// and shifted (here 2.5 s earlier), with nothing for the viewer to
    /// adjust. Needs the sync test film with its late file beside it
    /// (OPENIPTV_MOCK_VIDEO=sync.mkv, OPENIPTV_MOCK_SUBTITLE_FILES=
    /// "eng|SDH|…/late.srt"; TEST_RUNNER_SUBTITLE_SYNC=1).
    func testServerSubtitleFileInTime() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SUBTITLE_SYNC"] != nil, "needs the sync test film")
        openFilm(["-forgetTrackChoices", "YES"])
        sleep(4)
        controlsUp()
        app.buttons["Audio and Subtitles"].firstMatch.tap()
        let sdh = app.buttons["English SDH"].firstMatch
        if !sdh.waitForExistence(timeout: 3) {
            shot("menu without the server's file")
            print("MENU \(app.buttons.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty })")
        }
        XCTAssertTrue(sdh.exists, "the server's file isn't in the menu")
        sdh.tap()
        let readout = app.staticTexts["debug-subshift"].firstMatch
        var parts: [Double] = []
        for _ in 0..<20 where parts.first.map({ abs($0) < 0.01 }) ?? true {
            sleep(1)
            parts = readout.label.split(separator: " ").compactMap { Double($0) }
        }
        shot("late file in time")
        XCTAssertEqual(parts.first ?? 0, -2.5, accuracy: 0.1, "the late file wasn't shifted into time: \(readout.label)")
        XCTAssertEqual(parts.last ?? 0, 1, accuracy: 0.0001, "the file was stretched: \(readout.label)")
        // The film's own English track is in time already: no shift.
        controlsUp()
        app.buttons["Audio and Subtitles"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Off"].firstMatch.waitForExistence(timeout: 3), "the menu didn't open again")
        let english = app.buttons.matching(NSPredicate(format: "label == 'English'")).allElementsBoundByIndex
            .max { $0.frame.minY < $1.frame.minY }
        XCTAssertNotNil(english, "no English in the menu")
        english?.tap()
        sleep(2)
        XCTAssertEqual(readout.label, "0.00 1.0000", "the film's own track was shifted")
    }

    /// The same late file, when the server takes 30 s to give the film's
    /// own track (a real one reads the whole film to take it out; Asterix
    /// the Gaul took over a minute): still put in time once it comes.
    /// Regression: the app gave up on the track after 20 s, and the file
    /// stayed 32 s late. Same needs as testServerSubtitleFileInTime.
    func testServerSubtitleFileInTimeWhenTheTrackIsSlow() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SUBTITLE_SYNC"] != nil, "needs the sync test film")
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reference_delay": "30"])
        defer { configure(server, ["reset": "1"]) }
        openFilm(["-forgetTrackChoices", "YES"])
        sleep(4)
        controlsUp()
        app.buttons["Audio and Subtitles"].firstMatch.tap()
        let sdh = app.buttons["English SDH"].firstMatch
        XCTAssertTrue(sdh.waitForExistence(timeout: 5), "the server's file isn't in the menu")
        sdh.tap()
        let readout = app.staticTexts["debug-subshift"].firstMatch
        var parts: [Double] = []
        for _ in 0..<60 where parts.first.map({ abs($0) < 0.01 }) ?? true {
            sleep(1)
            parts = readout.label.split(separator: " ").compactMap { Double($0) }
        }
        shot("late file in time after a slow track")
        XCTAssertEqual(parts.first ?? 0, -2.5, accuracy: 0.1, "the late file wasn't shifted into time: \(readout.label)")
    }

    /// A subtitle file for a film with no subtitle track of its own shows
    /// in time by itself: the speech heard in stretches of the film's sound
    /// (the server converts each to audio alone; Apple's sound classifier
    /// hears it) tells how far off it is. Here every line is 6.5 s early,
    /// like Asterix and Cleopatra's English file. Regression: such a file
    /// played as it came. Needs the speech test film
    /// (scripts/make_speech_film.sh; OPENIPTV_MOCK_VIDEO=…/speech.mkv,
    /// OPENIPTV_MOCK_RUNTIME=480, OPENIPTV_MOCK_SUBTITLE_FILES="eng||…/early.srt";
    /// TEST_RUNNER_SUBTITLE_SPEECH=1).
    func testSubtitleFileInTimeBySpeech() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SUBTITLE_SPEECH"] != nil, "needs the speech test film")
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        openFilm(["-forgetTrackChoices", "YES", "-forgetSubtitleTimings", "YES"])
        sleep(4)
        // Watched without subtitles, nothing of its sound is asked for
        // (sixteen conversions on the server). Regression: asked for every
        // film played or got ready, subtitles or not.
        sleep(10)
        XCTAssertEqual(audioRequests(server), 0, "the film's sound was asked for with no subtitles showing")
        controlsUp()
        // The file is in the menu once fetched (the menu lists what's known
        // as it opens): opened again until it is.
        let file = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'English'"))
        for _ in 0..<4 {
            app.buttons["Audio and Subtitles"].firstMatch.tap()
            XCTAssertTrue(app.buttons["Off"].firstMatch.waitForExistence(timeout: 5), "the menu didn't open")
            if file.firstMatch.waitForExistence(timeout: 2) { break }
            app.buttons["Off"].firstMatch.tap()
            sleep(3)
            controlsUp()
        }
        let english = file.allElementsBoundByIndex.max { $0.frame.minY < $1.frame.minY }
        guard let english else {
            return XCTFail("the server's file isn't in the menu: \(app.buttons.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty })")
        }
        english.tap()
        let readout = app.staticTexts["debug-subshift"].firstMatch
        var parts: [Double] = []
        for _ in 0..<150 where parts.first.map({ abs($0) < 0.01 }) ?? true {
            sleep(1)
            parts = readout.label.split(separator: " ").compactMap { Double($0) }
        }
        shot("early file in time by speech")
        XCTAssertEqual(parts.first ?? 0, 6.5, accuracy: 0.2, "the early file wasn't shifted into time: \(readout.label)")
        XCTAssertEqual(parts.last ?? 0, 1, accuracy: 0.0001, "the file was stretched: \(readout.label)")
        // Each stretch is stopped once a minute is read, and the system
        // logs a stopped request's address: the key goes in a header.
        // Regression: the Emby session's key was in the simulator's system
        // log 104 times after one real-feed round.
        XCTAssertEqual(audioRequests(server, keyed: true), 0, "stretches asked for with the key in their address")
        // Stretches across the film (a file for another cut is off
        // differently in each part): 15 of the 16 fit in this 8-minute film
        // (the last would run past its end), each asked for once; the file
        // is put in time at half of them, the rest still coming.
        var asked = audioRequests(server)
        for _ in 0..<60 where asked < 15 {
            sleep(1)
            asked = audioRequests(server)
        }
        sleep(3)
        XCTAssertEqual(audioRequests(server), 15, "not fifteen stretches of its sound, once")
    }

    /// How many stretches of a film's sound the test server was asked for.
    /// `keyed`: only those with the key in their address.
    private func audioRequests(_ server: URL, keyed: Bool = false) -> Int {
        var count = -1
        let done = expectation(description: "audio requests")
        URLSession.shared.dataTask(with: server.appending(path: "mock/audio_requests")) { data, _, _ in
            count = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Int] })?[keyed ? "keyed" : "count"] ?? -1
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return count
    }

    /// The language rules on titles of the user's server (a survey of 550
    /// found each case): `env` names the test film each needs.
    private func startingTracks(_ env: String) throws -> String {
        try XCTSkipUnless(ProcessInfo.processInfo.environment[env] != nil, "needs its test film (\(env))")
        openFilm(["-forgetTrackChoices", "YES"])
        sleep(6)
        var playing = tracksPlaying()
        for _ in 0..<10 where playing.hasSuffix("subtitles=off") {
            sleep(1)
            playing = tracksPlaying()
        }
        shot("tracks \(env)")
        return playing
    }

    /// Sound with no language on it, in a film made in France: heard as
    /// French, so English subtitles. Regression: none showed (War 2, The
    /// Crime of Monsieur Lange: a fifth of the server's titles have
    /// unlabelled sound). Speech test film, OPENIPTV_MOCK_COUNTRIES=France,
    /// OPENIPTV_MOCK_SUBTITLE_FILES="eng||…/in-time.srt"; TEST_RUNNER_RULE_UNLABELLED=1.
    func testUnlabelledSoundFromAbroadShowsSubtitles() throws {
        // Outside the assertion: a skip inside one counted as a failure.
        let playing = try startingTracks("RULE_UNLABELLED")
        XCTAssertTrue(playing.hasSuffix("subtitles=eng"), "no English subtitles: \(playing)")
    }

    /// French sound with a Spanish file listed before an English one:
    /// English. Regression: the first file listed won (Yakuza Graveyard,
    /// The Jade Tiger), and Spanish text beat English drawn subtitles
    /// (Either Way). foreign.mkv, OPENIPTV_MOCK_COUNTRIES=France,
    /// OPENIPTV_MOCK_SUBTITLE_FILES="spa||…;eng||…"; TEST_RUNNER_RULE_ORDER=1.
    func testEnglishSubtitlesBeforeSpanish() throws {
        // Outside the assertion: a skip inside one counted as a failure.
        let playing = try startingTracks("RULE_ORDER")
        XCTAssertTrue(playing.hasSuffix("subtitles=eng"), "not English subtitles: \(playing)")
    }

    /// Sound marked "English" (the word, not "eng") in an American film:
    /// English, no subtitles. Regression: the word wasn't read as English,
    /// so the film counted as foreign and showed subtitles. Speech film
    /// tagged "English", OPENIPTV_MOCK_COUNTRIES="United States of America",
    /// OPENIPTV_MOCK_SUBTITLE_FILES="eng||…/in-time.srt"; TEST_RUNNER_RULE_NAME=1.
    func testLanguageWrittenAsAWord() throws {
        let playing = try startingTracks("RULE_NAME")
        XCTAssertTrue(playing.hasSuffix("subtitles=off"), "subtitles over English sound: \(playing)")
    }

    /// A film heard in neither English nor Spanish, with no subtitles in
    /// either, gets English ones by itself: the server's subtitle providers
    /// are asked, the file downloaded is added and shown. Regression: such
    /// a film played with no subtitles at all. Needs the French-only test
    /// film and a provider's subtitles (OPENIPTV_MOCK_VIDEO=foreign.mkv,
    /// OPENIPTV_MOCK_REMOTE_SUBTITLE=…/inside.srt; TEST_RUNNER_REMOTE_SUBTITLES=1).
    func testMissingSubtitlesComeFromTheServer() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["REMOTE_SUBTITLES"] != nil, "needs the French-only test film")
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        openFilm(["-forgetTrackChoices", "YES", "-forgetSubtitleSearches", "YES"])
        var playing = ""
        for _ in 0..<15 where !playing.contains("subtitles=eng") {
            sleep(1)
            playing = tracksPlaying()
        }
        shot("subtitles from the server")
        XCTAssertTrue(playing.hasSuffix("subtitles=eng"), "no English subtitles came: \(playing)")
    }

    /// The same on an account that may not manage subtitles on the server
    /// (Emby refuses it the download): the providers' file is read through
    /// the server instead, kept on the device, and shown. Regression: the
    /// server was asked to download it, refused, and the film had none (the
    /// user's account: "a lot of titles have no subtitles whatsoever").
    func testFoundSubtitlesWithoutTheRightToSave() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["REMOTE_SUBTITLES"] != nil, "needs the French-only test film")
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        configure(server, ["subtitle_rights": "none"])
        openFilm(["-forgetTrackChoices", "YES", "-forgetSubtitleSearches", "YES"])
        var playing = ""
        for _ in 0..<15 where !playing.contains("subtitles=eng") {
            sleep(1)
            playing = tracksPlaying()
        }
        shot("found subtitles without the right to save")
        XCTAssertTrue(playing.hasSuffix("subtitles=eng"), "no English subtitles came: \(playing)")
    }

    /// Of the files the providers find, the one that fits the film shows,
    /// in time, and only it: the most downloaded is another film's, the
    /// next this film's, 6.5 s early. The first shows at once; once the
    /// speech is heard, the second takes its place, 6.5 s later. Needs the
    /// speech test film from France with no subtitles
    /// (OPENIPTV_MOCK_VIDEO=…/speech.mkv, OPENIPTV_MOCK_COUNTRIES=France,
    /// OPENIPTV_MOCK_RUNTIME=480, OPENIPTV_MOCK_REMOTE_SUBTITLE="…/other.srt;…/early.srt";
    /// TEST_RUNNER_FOUND_SUBTITLES=1). Regression: the most downloaded was
    /// taken, whatever film it was for.
    func testFoundSubtitlesThatFitShow() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FOUND_SUBTITLES"] != nil, "needs the speech test film")
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        configure(server, ["subtitle_rights": "none"])
        openFilm(["-forgetTrackChoices", "YES", "-forgetSubtitleSearches", "YES", "-forgetSubtitleTimings", "YES"])
        let readout = app.staticTexts["debug-subshift"].firstMatch
        var parts: [Double] = []
        for _ in 0..<150 where parts.first.map({ abs($0 - 6.5) > 0.2 }) ?? true {
            sleep(1)
            parts = readout.label.split(separator: " ").compactMap { Double($0) }
        }
        shot("found subtitles that fit")
        XCTAssertEqual(parts.first ?? 0, 6.5, accuracy: 0.2, "the file that fits isn't showing in time: \(readout.label)")
        XCTAssertTrue(tracksPlaying().hasSuffix("subtitles=eng"), "no English subtitles: \(tracksPlaying())")
        // One English file in the menu: the other went.
        controlsUp()
        app.buttons["Audio and Subtitles"].firstMatch.tap()
        let off = app.buttons["Off"].firstMatch
        XCTAssertTrue(off.waitForExistence(timeout: 5), "the menu didn't open")
        let english = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'English'")).allElementsBoundByIndex
            .filter { $0.frame.minY > off.frame.minY }
        XCTAssertEqual(english.count, 1, "not one English file: \(english.map(\.label))")
    }

    /// Playing with the controls up, the player screen isn't drawn again
    /// for every tick of the clock (about four a second): only the bar and
    /// what shows the time are. Regression: the whole player was, with every
    /// view in it, four times a second. Counted by the app (DEBUG).
    func testPlayerIsNotRedrawnEveryTick() {
        openFilm()
        sleep(3)
        controlsUp()
        let readout = app.staticTexts["debug-player-renders"].firstMatch
        XCTAssertTrue(readout.waitForExistence(timeout: 5), "no render count")
        sleep(1)
        let before = Int(readout.label) ?? 0
        sleep(5)
        let after = Int(readout.label) ?? 0
        let position = app.staticTexts["debug-position"].firstMatch.label
        XCTAssertTrue(position.hasSuffix("playing"), "not playing: \(position)")
        // The controls hiding by themselves (one change) and a network note
        // or two may draw it; the clock alone would be about twenty.
        XCTAssertLessThanOrEqual(after - before, 6, "the player was drawn \(after - before) times in 5 s of playing")
    }

    /// Pressing play stops what was fetched ahead for the other titles
    /// (Continue Watching's files: their start, their index, where they
    /// resume): the film playing has the connection to itself. Regression:
    /// those fetches went on, each step after the last, competing with it.
    /// A slow server (6 s before each answer, four steps each) keeps them
    /// going long enough.
    func testFetchingAheadStopsWhenAFilmPlays() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        // From its start (resumed at the end of the 10-minute test film, the
        // next episode would follow at once).
        configure(server, ["video_delay": "6", "episode_resume": "0"])
        app.launch()
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 20), "no Continue Watching")
        // The fetches ahead under way (their first step).
        sleep(3)
        card.tap()
        let item = app.staticTexts["debug-item"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 20), "the player didn't open")
        // From a moment after the player opened (a request sent just before
        // can still arrive): each further step of a fetch ahead would come.
        sleep(1)
        let mark = markTime(server)
        let playing = item.label
        sleep(20)
        let others = videoRequests(server, since: mark).filter { $0 != playing }
        XCTAssertEqual(others, [], "other titles' files were still fetched after \(playing) started")
    }

    private func markTime(_ server: URL) -> Double {
        var t = 0.0
        let done = expectation(description: "mark")
        URLSession.shared.dataTask(with: server.appending(path: "mock/mark")) { data, _, _ in
            t = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Double] })?["t"] ?? 0
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return t
    }

    private func videoRequests(_ server: URL, since: Double) -> [String] {
        listed(server, "mock/video_requests", since: since)
    }

    private func subtitleRequests(_ server: URL, since: Double = 0, _ field: String = "items") -> [String] {
        listed(server, "mock/subtitle_requests", since: since, field)
    }

    func keyChecks(_ server: URL, _ field: String) -> [String] {
        listed(server, "mock/key_checks", since: 0, field)
    }

    private func listed(_ server: URL, _ path: String, since: Double, _ field: String = "items") -> [String] {
        var items: [String] = []
        let done = expectation(description: path)
        let url = server.appending(path: path).appending(queryItems: [.init(name: "since", value: String(since))])
        URLSession.shared.dataTask(with: url) { data, _, _ in
            items = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: [String]] })?[field] ?? []
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return items
    }

    private func openedAt() -> Double? {
        let readout = app.staticTexts["debug-start"].firstMatch
        for _ in 0..<20 {
            if readout.exists, let at = readout.label.components(separatedBy: " at ").last.flatMap(Double.init) { return at }
            usleep(500_000)
        }
        return nil
    }

    /// The app's debug readout of the player: its second, and whether it plays.
    private func playerState() -> (seconds: Double, playing: Bool)? {
        let parts = app.staticTexts["debug-position"].firstMatch.label.split(separator: " ")
        guard parts.count == 2, let seconds = Double(parts[0]) else { return nil }
        return (seconds, parts[1] == "playing")
    }

    func testServer() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["DEBUG_EMBY"],
              let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let address = json["serverURL"] as? String else { return nil }
        return URL(string: address)
    }

    private func setResumePosition(_ server: URL, _ item: String, at seconds: Double) throws {
        let raw = try XCTUnwrap(ProcessInfo.processInfo.environment["DEBUG_EMBY"])
        let account = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        var request = URLRequest(url: server.appending(path: "emby/Sessions/Playing/Stopped"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(account["accessToken"] as? String, forHTTPHeaderField: "X-Emby-Token")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["ItemId": item, "PositionTicks": Int64(seconds * 10_000_000)])
        let done = expectation(description: "resume")
        URLSession.shared.dataTask(with: request) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
    }

    /// Sets how the test server behaves (see CONTROL in mock_server.py).
    func configure(_ server: URL, _ settings: [String: String]) {
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
        app.buttons["Info"].firstMatch.tap()
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
        app.buttons["Continue Watching"].firstMatch.tap()
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
        app.buttons["Pause"].firstMatch.tap()
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
        app.buttons["Rotate to landscape"].firstMatch.tap()
        sleep(3)
        controlsUp()
        app.buttons["Continue Watching"].firstMatch.tap()
        sleep(1)
        shot("continue watching landscape")
        XCTAssertGreaterThan(app.frame.width, app.frame.height, "not sideways")
        // ("Play" would also find the film page's, under the player.)
        XCTAssertFalse(app.buttons["Back 10 seconds"].firstMatch.exists, "the play controls stayed with the panel open")
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Case 3'")).firstMatch
        XCTAssertTrue(card.exists, "no titles in Continue Watching")
        XCTAssertEqual(card.frame.width, 202, accuracy: 1, "not Apple's picture card: \(card.frame)")
        app.buttons["Rotate to portrait"].firstMatch.tap()
    }

    /// Sideways with Info open, everything stays on the screen. Regression
    /// (delegated audit): Close was pushed 66 points above the top.
    func testInfoInLandscapeKeepsClose() throws {
        // iPhone: an iPad keeps its full layout when turned.
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone's sideways layout")
        openFilm()
        controlsUp()
        app.buttons["Pause"].firstMatch.tap()
        app.buttons["Rotate to landscape"].firstMatch.tap()
        sleep(3)
        controlsUp()
        app.buttons["Info"].firstMatch.tap()
        sleep(1)
        shot("info landscape")
        let screen = app.frame
        let close = app.buttons["Close player"].firstMatch.frame
        let start = app.buttons["From Beginning"].firstMatch.frame
        XCTAssertGreaterThanOrEqual(close.minY, 0, "Close is off the top: \(close) on \(screen)")
        XCTAssertLessThanOrEqual(start.maxY, screen.maxY, "From Beginning is off the bottom: \(start) on \(screen)")
        app.buttons["Rotate to portrait"].firstMatch.tap()
    }

    /// The Info panel as in the Apple TV app (measured at 3x from it).
    /// Upright: the title 17 pt (one line about 22 high), buttons 44 high.
    /// Sideways: a 180 × 101 still under the pills, the text beside it, and
    /// From Beginning 200 × 44 at the right, level with the still.
    /// Regression: sideways had no still and a full-width button under the
    /// text; the title was 20 pt and the buttons 48 high.
    /// Info opening upright: the pills travel up from the bottom, and the
    /// panel's text shows once they're there. Regression: the text was
    /// drawn first, and the pills crossed it on their way ("Info" over the
    /// title for about 170 ms; found filming testGoToShow). A UI test only
    /// sees the end of an animation, so this one opens Info stretched 15
    /// times (4.5 s) under scripts/frame-audit/record.sh, and writes where
    /// things end up for scripts/frame-audit/info_open.py, which checks the
    /// film frame by frame (it fails on the old opening).
    func testInfoTextWaitsForThePills() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone's layout")
        app.launchEnvironment["OPENREEL_DEBUG_ANIMATION_SCALE"] = "15"
        openFilm()
        controlsUp()
        app.buttons["Pause"].firstMatch.tap()
        app.buttons["Info"].firstMatch.tap()
        let start = app.buttons["From Beginning"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 8), "no From Beginning")
        sleep(2)
        shot("info opened")
        let pills = app.buttons.allElementsBoundByIndex.filter { ["Info", "Continue Watching"].contains($0.label) }.map(\.frame)
        let info = app.buttons["Info"].firstMatch.frame
        let title = app.staticTexts.matching(NSPredicate(format: "label == 'Animals'")).firstMatch.frame
        XCTAssertGreaterThan(title.minY, info.maxY, "the title isn't under the pills: \(title), \(info)")
        let geometry: [String: Any] = [
            "width": app.frame.width, "height": app.frame.height,
            "info": [info.minX, info.minY, info.width, info.height],
            "pillsEnd": pills.map(\.maxX).max() ?? info.maxX,
            "title": [title.minX, title.minY, title.width, title.height],
            "start": [start.frame.minX, start.frame.minY, start.frame.width, start.frame.height],
        ]
        let data = try JSONSerialization.data(withJSONObject: geometry)
        try data.write(to: shots.appending(path: "info-geometry.json"))
    }

    func testInfoAsInAppleTV() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone's layouts")
        openFilm()
        controlsUp()
        app.buttons["Pause"].firstMatch.tap()
        app.buttons["Info"].firstMatch.tap()
        sleep(1)
        shot("info upright")
        let start = app.buttons["From Beginning"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 3), "no From Beginning")
        XCTAssertEqual(start.frame.height, 44, accuracy: 1, "upright button: \(start.frame)")
        let title = app.staticTexts.matching(NSPredicate(format: "label == 'Animals'")).firstMatch
        XCTAssertLessThan(title.frame.height, 24, "the title isn't 17 pt: \(title.frame)")

        app.buttons["Info"].firstMatch.tap()
        app.buttons["Rotate to landscape"].firstMatch.tap()
        sleep(3)
        controlsUp()
        app.buttons["Info"].firstMatch.tap()
        sleep(1)
        shot("info sideways")
        let still = app.otherElements["player.info.still"].firstMatch
        XCTAssertTrue(still.waitForExistence(timeout: 3), "no still sideways")
        let pill = app.buttons["Info"].firstMatch.frame
        XCTAssertEqual(still.frame.width, 180, accuracy: 1, "still: \(still.frame)")
        XCTAssertEqual(still.frame.height, 101, accuracy: 1, "still: \(still.frame)")
        XCTAssertGreaterThan(still.frame.minY, pill.maxY, "the still isn't under the pills")
        let button = start.frame
        XCTAssertEqual(button.width, 200, accuracy: 1, "sideways button: \(button)")
        XCTAssertEqual(button.height, 44, accuracy: 1, "sideways button: \(button)")
        XCTAssertGreaterThan(button.minX, still.frame.maxX + 150, "the button isn't at the right: \(button)")
        XCTAssertEqual(button.minY, still.frame.minY, accuracy: 6, "the button isn't level with the still")
        XCTAssertLessThanOrEqual(button.maxX, app.frame.maxX, "the button is off the screen: \(button)")
        // Info closes the panel. Regression: the still's uncut picture lay
        // over the pill and took the tap: the film played on, Info stayed.
        app.buttons["Info"].firstMatch.tap()
        sleep(1)
        XCTAssertFalse(start.exists, "Info didn't close the panel")
        XCTAssertEqual(playerState()?.playing, false, "the tap on Info played the film")
        app.buttons["Rotate to portrait"].firstMatch.tap()
    }

    /// Regression: with the film playing, the subtitles menu stayed open
    /// while the controls hid under it, and the player closed with them.
    func testSubtitlesMenuKeepsControls() {
        openFilm()
        controlsUp()
        app.buttons["Audio and Subtitles"].firstMatch.tap()
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
        app.buttons["Pause"].firstMatch.tap()
        sleep(1)
        // Regression: the tests' readouts over the button sent the tap to
        // its corner, which hid the controls instead.
        XCTAssertEqual(playerState()?.playing, false, "Pause didn't pause")
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
        shot("landscape info closed")
        app.buttons["Play"].firstMatch.tap()
        sleep(1)
        shot("landscape resumed")
        // Closing turns the app upright again.
        app.buttons["Close player"].firstMatch.tap()
        sleep(2)
        shot("closed")
    }
}

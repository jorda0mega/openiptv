import XCTest

/// Apple TV: drives the app with the Siri Remote, as a person would, and
/// prints which element has focus after each press (the simulator's own
/// remote window can't be scripted). Run with
/// `xcodebuild test -scheme "OpenIPTV TV UITests"` on an Apple TV simulator
/// signed in to the test server (scripts/mock_server.py).
final class RemoteFocusTests: XCTestCase {
    private let app = XCUIApplication()
    private let remote = XCUIRemote.shared

    override func setUp() {
        super.setUp()
        // A spare simulator not signed in: the test server's account, passed
        // in by xcodebuild (TEST_RUNNER_DEBUG_EMBY), debug builds only.
        if let account = ProcessInfo.processInfo.environment["DEBUG_EMBY"] {
            app.launchEnvironment["OPENREEL_DEBUG_EMBY"] = account
        }
        // Player options to compare (debug builds).
        if let options = ProcessInfo.processInfo.environment["MPV_EXTRA"] {
            app.launchEnvironment["OPENREEL_DEBUG_MPV"] = options
        }
    }

    private func focused() -> String {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        guard element.exists else { return "nothing" }
        return "\(element.elementType) label='\(element.label)' id='\(element.identifier)'"
    }

    /// Screenshots after each press go here (the simulator writes to the Mac).
    private let shots = URL(fileURLWithPath: "/tmp/openiptv/uitest")
    private var step = 0

    private func press(_ button: XCUIRemote.Button, _ note: String) {
        remote.press(button)
        sleep(1)
        step += 1
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let name = String(format: "%02d-%@.png", step, note.replacingOccurrences(of: " ", with: "-"))
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: name))
        print("FOCUS \(note): \(focused()) → \(name)")
    }

    /// Search: down from the keyboard into the results, along them, and
    /// back up to the keyboard.
    func testSearchFocus() {
        app.launchArguments = ["-tvTab", "search", "-debugSearch", "animals"]
        app.launch()
        sleep(6)
        print("FOCUS start: \(focused())")
        // From the tab bar to the keyboard, then into the results.
        press(.down, "to keyboard")
        press(.down, "down")
        press(.right, "right")
        press(.down, "down to channels")
        press(.up, "up to posters")
        press(.up, "up to keyboard")
        press(.up, "up again (tab bar)")
    }

    /// The player's remote: open a film from Search, play it, click right
    /// (forward 10 s), click the centre (pause), hold right (fast-forward),
    /// then Menu twice.
    func testPlayerRemote() {
        app.launchArguments = ["-tvTab", "search", "-debugSearch", "animals"]
        app.launch()
        sleep(6)
        press(.down, "to keyboard")
        press(.down, "to first film")
        press(.select, "open film")
        sleep(2)
        press(.select, "play")
        sleep(6)
        shot("playing")
        press(.right, "click right")
        sleep(1)
        shot("after skip")
        press(.select, "pause")
        remote.press(.right, forDuration: 2.5)
        shot("held right")
        sleep(2)
        shot("after hold")
        press(.select, "commit or play")
        press(.menu, "menu 1")
        press(.menu, "menu 2")
    }

    /// Skips: click right four times and left twice, two seconds apart, with
    /// a screenshot straight after the first (the bar should already be
    /// there). Debug builds log each jump's time ("PERF seek").
    func testSkipTiming() {
        app.launchArguments = ["-tvTab", "search", "-debugSearch", "animals"]
        app.launch()
        sleep(6)
        press(.down, "to keyboard")
        press(.down, "to first film")
        press(.select, "open film")
        sleep(2)
        press(.select, "play")
        sleep(8)
        remote.press(.right)
        shot("right at once")
        sleep(2)
        for _ in 0..<3 { remote.press(.right); sleep(2) }
        shot("after four rights")
        for _ in 0..<2 { remote.press(.left); sleep(2) }
        shot("after two lefts")
        // Swipe-free choose: hold right, release, and it plays from there.
        remote.press(.right, forDuration: 2)
        shot("released")
        sleep(1)
        shot("a second later")
    }

    /// The player's look in each state, to set beside Apple's own player:
    /// paused (title, bar, time with its pause sign, Info tab, audio
    /// button), a jump while paused (the bar alone), playing, up to the
    /// audio button and its menu, and down to the Info panel.
    func testPlayerLook() {
        app.launchArguments = ["-tvTab", "search", "-debugSearch", "animals"]
        app.launch()
        sleep(6)
        press(.down, "to keyboard")
        press(.down, "to first film")
        press(.select, "open film")
        sleep(2)
        press(.select, "play")
        sleep(8)
        shot("look playing")
        remote.press(.playPause)
        usleep(1_300_000)
        shot("look paused")
        remote.press(.right)
        usleep(500_000)
        shot("look paused jump")
        remote.press(.playPause)
        usleep(1_300_000)
        shot("look resumed")
        sleep(6)
        shot("look hidden")
        remote.press(.up)
        usleep(800_000)
        shot("look up")
        remote.press(.select)
        usleep(1_000_000)
        shot("look audio menu")
        remote.press(.menu)
        usleep(800_000)
        shot("look menu closed")
        remote.press(.down)
        usleep(800_000)
        remote.press(.down)
        usleep(1_000_000)
        shot("look info")
        remote.press(.menu)
        usleep(800_000)
        shot("look info closed")
    }

    /// A film just stopped stays first in Continue Watching though the
    /// server doesn't list it yet (the test server never does): a refresh
    /// used to take it away again 86 ms after it appeared.
    func testStopStaysInContinueWatching() {
        app.launchArguments = ["-tvTab", "search", "-debugSearch", "animals"]
        app.launch()
        sleep(6)
        press(.down, "to keyboard")
        press(.down, "to first film")
        press(.select, "open film")
        sleep(2)
        press(.select, "play")
        sleep(8)
        press(.menu, "menu 1")
        press(.menu, "menu 2 leaves the player")
        // Back to the tab bar (never Menu on it: that leaves the app).
        for _ in 0..<5 where !focused().contains("id='magnifyingglass'") { press(.menu, "back") }
        press(.right, "to Home")
        sleep(5)
        shot("home after stop")
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-' AND label BEGINSWITH 'Animals'")).firstMatch
        XCTAssertTrue(card.exists, "the film just stopped isn't in Continue Watching")
    }

    /// Home: Down from the tab bar lands on the hero's Play, and Up and
    /// Down reach every row from any card. Regression: Down went past the
    /// hero into Continue Watching; Down from the end of a row with nothing
    /// straight below went nowhere; Up from there skipped Continue Watching.
    func testHomeRowsReachable() {
        app.launch()
        sleep(6)
        press(.down, "into the page")
        XCTAssertTrue(focused().contains("label='Play'"), "Down from the tab bar didn't land on Play: \(focused())")
        press(.down, "to Continue Watching")
        XCTAssertTrue(focused().contains("id='continue-"), "not on Continue Watching: \(focused())")
        press(.down, "to the next row")
        for _ in 0..<6 { press(.right, "along the row") }
        let end = focused()
        press(.down, "down from the row's end")
        XCTAssertNotEqual(focused(), end, "Down from the end of a row went nowhere")
        press(.up, "back up")
        press(.up, "up again")
        XCTAssertTrue(focused().contains("id='continue-"), "Up skipped Continue Watching: \(focused())")
    }

    /// A show's page: Down from its main button lands on the season shown,
    /// then on the episode you're up to. Regression: on the first chip
    /// (Specials), then on Episode 1.
    func testShowPageFocus() {
        app.launchArguments = ["-tvTab", "search", "-debugSearch", "forensic"]
        app.launch()
        sleep(6)
        press(.down, "to keyboard")
        press(.down, "to the results")
        for _ in 0..<6 where !focused().contains("label='Forensic Files") { press(.right, "along the results") }
        press(.select, "open the show")
        sleep(3)
        let main = focused()
        XCTAssertTrue(main.contains("Continue"), "not on the show's Continue button: \(main)")
        press(.down, "to the seasons")
        XCTAssertTrue(focused().contains("label='Season 2'"), "Down didn't land on the season shown: \(focused())")
        // Specials after the last season, as in the TV app.
        let seasons = app.buttons.matching(NSPredicate(format: "label == 'Specials' OR label BEGINSWITH 'Season '")).allElementsBoundByIndex
            .sorted { $0.frame.minX < $1.frame.minX }.map(\.label)
        XCTAssertEqual(seasons.last, "Specials", "Specials isn't last: \(seasons)")
        press(.down, "to the episodes")
        XCTAssertTrue(focused().contains("Case 3"), "Down didn't land on the episode you're up to: \(focused())")
    }

    /// Down opens the Info panel on its tab, as in Apple's player: a click
    /// there does nothing, so a click meant for the film can't start it
    /// over; "From Beginning" is one more press down. Regression: the panel
    /// opened on "From Beginning", so a stray swipe down (the finger
    /// rolling in a click) and the next click restarted the film.
    func testInfoOpensOnItsTab() {
        app.launchArguments = ["-tvTab", "search", "-debugSearch", "animals"]
        app.launch()
        sleep(6)
        press(.down, "to keyboard")
        press(.down, "to first film")
        press(.select, "open film")
        sleep(2)
        press(.select, "play")
        sleep(10)
        remote.press(.down)
        usleep(800_000)
        shot("info opened")
        XCTAssertTrue(app.descendants(matching: .any)["player.info.tab"].firstMatch.isSelected, "the Info panel didn't open on its tab")
        remote.press(.select)
        sleep(2)
        let after = playerSecond() ?? 0
        XCTAssertGreaterThan(after, 6, "a click on the Info panel's tab started the film over (at \(after) s)")
        remote.press(.down)
        usleep(800_000)
        XCTAssertTrue(app.descendants(matching: .any)["player.info.fromBeginning"].firstMatch.isSelected, "down didn't reach From Beginning")
        remote.press(.select)
        sleep(2)
        XCTAssertLessThan(playerSecond() ?? 99, 5, "From Beginning didn't start the film over")
    }

    /// An episode: down, then right, the Episodes tab beside Info, its
    /// season in a row; down onto the one playing, right along the row, and
    /// a click plays that one in the same player. The user asked for it
    /// (14 October).
    func testEpisodesTab() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        // From its start (the test film is 10 min: resumed at 10:00 it ends).
        configure(server, ["episode_resume": "0"])
        app.launch()
        sleep(6)
        // Continue Watching's first card: the show, at its episode.
        for _ in 0..<5 where !focused().contains("id='continue-") { press(.down, "down to Continue Watching") }
        press(.select, "play")
        let item = app.staticTexts["debug-item"].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 15), "no player")
        XCTAssertEqual(item.label, "e203", "not the show's episode")
        sleep(6)
        remote.press(.down)
        usleep(800_000)
        remote.press(.right)
        usleep(800_000)
        XCTAssertTrue(app.descendants(matching: .any)["player.episodes.tab"].firstMatch.isSelected, "no Episodes tab beside Info")
        remote.press(.down)
        usleep(800_000)
        shot("episodes row")
        XCTAssertTrue(app.descendants(matching: .any)["player.episode.e203"].firstMatch.isSelected, "the row didn't open on the one playing")
        remote.press(.right)
        usleep(500_000)
        remote.press(.right)
        usleep(800_000)
        XCTAssertTrue(app.descendants(matching: .any)["player.episode.e205"].firstMatch.isSelected, "right didn't move along the row")
        remote.press(.select)
        for _ in 0..<40 where item.label != "e205" { usleep(250_000) }
        XCTAssertEqual(item.label, "e205", "the chosen episode didn't play")
    }

    /// The Apple TV stays awake while a film plays (no screensaver, no
    /// sleep), and may sleep when it's paused. Regression: it slept in the
    /// middle of a film (Apple's player tells the system; libmpv doesn't).
    func testStaysAwakeWhilePlaying() {
        app.launchArguments = ["-tvTab", "search", "-debugSearch", "animals"]
        app.launch()
        sleep(6)
        press(.down, "to keyboard")
        press(.down, "to first film")
        press(.select, "open film")
        sleep(2)
        press(.select, "play")
        sleep(6)
        let awake = app.staticTexts["debug-awake"].firstMatch
        XCTAssertTrue(awake.waitForExistence(timeout: 5), "no awake readout")
        XCTAssertEqual(awake.label, "awake", "the Apple TV may sleep while the film plays")
        remote.press(.playPause)
        sleep(1)
        XCTAssertEqual(awake.label, "idle", "kept awake while paused")
    }

    func testPausesWhileAway() {
        app.launchArguments = ["-tvTab", "search", "-debugSearch", "animals"]
        app.launch()
        sleep(6)
        press(.down, "to keyboard")
        press(.down, "to first film")
        press(.select, "open film")
        sleep(2)
        press(.select, "play")
        sleep(6)
        let left = playerSecond() ?? 0
        XCUIRemote.shared.press(.home)
        sleep(6)
        app.activate()
        sleep(4)
        shot("back from home")
        XCTAssertEqual(app.staticTexts["debug-away"].firstMatch.label, "1", "the picture didn't go off while away")
        let back = playerSecond() ?? 0
        XCTAssertEqual(back, left, accuracy: 3, "the film played on while away (\(left) → \(back))")
        XCTAssertTrue(app.staticTexts["debug-position"].firstMatch.label.hasSuffix("paused"), "not paused on return")
        XCTAssertEqual(app.staticTexts["debug-awake"].firstMatch.label, "idle", "kept awake while paused on return")
        remote.press(.playPause)
        sleep(4)
        let later = playerSecond() ?? 0
        XCTAssertGreaterThan(later - back, 2, "not playing on from where it paused (\(back) → \(later))")
    }

    /// tvOS sleeps after its "Sleep After" time unless Now Playing says
    /// something plays: the idle timer holds back the screen saver alone.
    func testTellsNowPlaying() {
        app.launchArguments = ["-tvTab", "search", "-debugSearch", "animals"]
        app.launch()
        sleep(6)
        press(.down, "to keyboard")
        press(.down, "to first film")
        press(.select, "open film")
        sleep(2)
        press(.select, "play")
        sleep(6)
        XCTAssertTrue(nowPlaying("playing"), "Now Playing doesn't hear the film play: the Apple TV sleeps mid-film")
        XCTAssertTrue(awake(true), "the Apple TV may sleep while the film plays")
        press(.right, "jump")
        sleep(2)
        XCTAssertTrue(nowPlaying("playing"), "Now Playing doesn't hear the film play after a jump")
        XCTAssertTrue(awake(true), "may sleep after a jump")
        remote.press(.playPause)
        XCTAssertTrue(nowPlaying("paused"), "Now Playing hears the paused film play: the Apple TV never sleeps")
        XCTAssertTrue(awake(false), "kept awake while paused (\(position()))")
        remote.press(.playPause)
        XCTAssertTrue(nowPlaying("playing"), "Now Playing doesn't hear the film play again")
        XCTAssertTrue(awake(true), "may sleep after play again")
    }

    func testTellsNowPlayingFromAKeptPlayer() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["reset": "1"])
        configure(server, ["watched_elsewhere": "m7"])
        addTeardownBlock { [self] in configure(server, ["reset": "1"]) }
        app.launchEnvironment["OPENREEL_DEBUG_NO_SAVED_HOME"] = "1"
        app.launchArguments = ["-tvTab", "home"]
        app.launch()
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-'")).firstMatch
        XCTAssertTrue(cards.waitForExistence(timeout: 20), "no Continue Watching")
        for _ in 0..<5 where !focused().contains("id='continue-") { press(.down, "down to Continue Watching") }
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        let id = card.identifier
        XCTAssertTrue(id.hasPrefix("continue-"), "not on a Continue Watching card: \(focused())")
        press(.select, "play")
        sleep(8)
        XCTAssertTrue(nowPlaying("playing"), "Now Playing doesn't hear the film from Continue Watching")
        XCTAssertTrue(awake(true), "may sleep from Continue Watching")
        let played = app.buttons[id]
        for _ in 0..<3 where !played.exists || !played.isHittable {
            remote.press(.menu)
            usleep(300_000)
        }
        XCTAssertTrue(played.waitForExistence(timeout: 5), "Home didn't come back")
        sleep(2)
        press(.select, "play the kept player")
        sleep(4)
        XCTAssertTrue(nowPlaying("playing"), "Now Playing doesn't hear the kept player (\(position()))")
        XCTAssertTrue(awake(true), "may sleep from the kept player (\(position()))")
    }

    func testTellsNowPlayingAfterTryAgain() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["reset": "1"])
        addTeardownBlock { [self] in configure(server, ["reset": "1"]) }
        configure(server, ["hang": "item,plan"])
        app.launchArguments = ["-tvTab", "search", "-debugSearch", "animals"]
        app.launch()
        sleep(6)
        press(.down, "to keyboard")
        press(.down, "to first film")
        press(.select, "open film")
        sleep(2)
        press(.select, "play")
        let failure = app.staticTexts["debug-start-error"].firstMatch
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !failure.exists || failure.label.isEmpty { sleep(1) }
        XCTAssertFalse(failure.label.isEmpty, "the start didn't fail")
        configure(server, ["reset": "1"])
        press(.down, "onto Try again")
        press(.select, "try again")
        sleep(10)
        XCTAssertTrue(nowPlaying("playing"), "Now Playing doesn't hear the film after Try again (\(position()))")
        XCTAssertTrue(awake(true), "may sleep after Try again (\(position()))")
    }

    func testAPauseFromOutsideKeepsLiveBehind() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["reset": "1"])
        addTeardownBlock { [self] in configure(server, ["reset": "1"]) }
        app.launchEnvironment["OPENREEL_DEBUG_IPTV"] = #"{"id":"6F9A1E52-0000-4000-8000-000000000001","name":"Test","kind":"#
            + #"{"xtream":{"server":"\#(server.absoluteString)","username":"u","password":"p"}}}"#
        app.launchEnvironment["OPENREEL_DEBUG_NOW_PLAYING_ASKS"] = "pause@12,play@20"
        app.launchArguments = ["-tvTab", "live", "-freshLineup", "YES"]
        app.launch()
        sleep(8)
        press(.down, "into the page")
        press(.select, "play channel")
        XCTAssertTrue(started(), "the channel didn't play: \(liveCopy())")
        sleep(18)
        let behind = Double(app.staticTexts["debug-live-behind"].firstMatch.label) ?? 0
        XCTAssertGreaterThanOrEqual(behind, 4, "paused from outside the app for 8 s, then played, but shown at live")
    }

    func testAPauseFromOutsideShowsTheFilmBar() {
        app.launchEnvironment["OPENREEL_DEBUG_NOW_PLAYING_ASKS"] = "pause@8"
        app.launchArguments = ["-tvTab", "search", "-debugSearch", "animals"]
        app.launch()
        sleep(6)
        press(.down, "to keyboard")
        press(.down, "to first film")
        press(.select, "open film")
        sleep(2)
        press(.select, "play")
        sleep(10)
        XCTAssertTrue(position().hasSuffix("paused"), "the pause from outside the app didn't pause (\(position()))")
        let bar = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Paused'")).firstMatch
        XCTAssertTrue(bar.exists, "paused from outside the app with no bar")
    }

    func testPausesWhenLeftWhileStarting() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["reset": "1"])
        addTeardownBlock { [self] in configure(server, ["reset": "1"]) }
        app.launchArguments = ["-tvTab", "search", "-debugSearch", "animals"]
        app.launch()
        sleep(6)
        press(.down, "to keyboard")
        press(.down, "to first film")
        press(.select, "open film")
        sleep(2)
        configure(server, ["latency": "4"])
        press(.select, "play")
        XCUIRemote.shared.press(.home)
        sleep(2)
        configure(server, ["reset": "1"])
        sleep(14)
        app.activate()
        sleep(4)
        let back = playerSecond() ?? 0
        sleep(3)
        let later = playerSecond() ?? 0
        XCTAssertTrue(position().hasSuffix("paused"), "a film left while it started played on (\(position()))")
        XCTAssertLessThan(later - back, 0.5, "a film left while it started is playing on return (\(back) → \(later))")
    }

    private func nowPlaying(_ wanted: String) -> Bool {
        let readout = app.staticTexts["debug-now-playing"].firstMatch
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if readout.exists, readout.label == wanted { return true }
            usleep(250_000)
        }
        return false
    }

    private func position() -> String {
        let readout = app.staticTexts["debug-position"].firstMatch
        return readout.exists ? readout.label : "no player"
    }

    private func awake(_ wanted: Bool) -> Bool {
        let readout = app.staticTexts["debug-awake"].firstMatch
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if readout.exists, readout.label == (wanted ? "awake" : "idle") { return true }
            usleep(250_000)
        }
        return false
    }

    /// A film's Info panel is headed by its name, and no bare year shows.
    /// Regression: the heading (and the line over the title) was "2026".
    func testFilmInfoHeading() {
        app.launchArguments = ["-tvTab", "search", "-debugSearch", "animals"]
        app.launch()
        sleep(6)
        press(.down, "to keyboard")
        press(.down, "to first film")
        press(.select, "open film")
        sleep(2)
        press(.select, "play")
        sleep(6)
        remote.press(.playPause)
        usleep(1_300_000)
        remote.press(.down)
        usleep(800_000)
        remote.press(.down)
        usleep(1_000_000)
        shot("film info")
        // The film's own year alone (pages behind the player list others).
        XCTAssertFalse(app.staticTexts["2026"].exists, "the film's year shows on its own, as a heading")
        XCTAssertTrue(app.staticTexts["Animals"].exists, "the film's name isn't shown")
    }

    /// Home's hero turns to the next title without dimming halfway.
    /// Regression: both pictures faded at once, 10-13% darker mid-change;
    /// then the first turn after launch still dimmed (the next picture's
    /// black base showed before the picture was drawn).
    func testHeroTurnsWithoutDimming() {
        app.launch()
        sleep(4)
        let area = CGRect(x: 0, y: 140, width: app.frame.width, height: 360)
        var samples: [Double] = []
        var pictures: [XCUIScreenshot] = []
        let start = Date()
        while Date().timeIntervalSince(start) < 20 {
            let picture = XCUIScreen.main.screenshot()
            pictures.append(picture)
            samples.append(luminance(picture, in: area))
        }
        print("HERO luminance \(samples.map { Int($0) })")
        XCTAssertGreaterThan(samples.count, 20, "too few samples")
        // A dip: a sample darker than the plateaus on both sides by > 6%.
        var dips: [String] = []
        for i in 3..<(max(3, samples.count - 3)) {
            let before = samples[(i - 3)..<i].max() ?? 0, after = samples[(i + 1)...(i + 3)].max() ?? 0
            let floor = min(before, after)
            if samples[i] < floor * 0.94, samples[i] < samples[i - 1], samples[i] <= samples[i + 1] {
                dips.append("\(i): \(Int(samples[i])) under \(Int(floor))")
                for j in (i - 1)...(i + 1) {
                    try? pictures[j].pngRepresentation.write(to: shots.appending(path: "hero-dip-\(j).png"))
                }
            }
        }
        // The first turn after launch too: each picture's first frame on
        // screen drew its black base before the picture.
        XCTAssertEqual(dips, [], "the hero dimmed while turning")
    }

    /// Home's hero shows its title, story and buttons over its picture.
    /// Regression: the picture was drawn over them (Play could be focused,
    /// but not seen).
    func testHeroTextShows() {
        app.launch()
        sleep(6)
        let play = app.buttons["Play"].firstMatch
        XCTAssertTrue(play.exists, "no Play in the hero")
        let picture = XCUIScreen.main.screenshot()
        let light = brightest(picture, in: play.frame)
        print("HERO play brightest \(Int(light))")
        XCTAssertGreaterThan(light, 200, "Play's label can't be seen (brightest \(Int(light)))")
    }

    /// Brightest pixel (0-255) of an area of a screenshot, in points.
    private func brightest(_ shot: XCUIScreenshot, in rect: CGRect) -> Double {
        guard let image = shot.image.cgImage else { return 0 }
        let scale = CGFloat(image.width) / app.frame.width
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
        guard let crop = image.cropping(to: pixels) else { return 0 }
        let width = crop.width, height = crop.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        var best = 0.0
        for i in stride(from: 0, to: data.count, by: 4) {
            best = max(best, 0.2126 * Double(data[i]) + 0.7152 * Double(data[i + 1]) + 0.0722 * Double(data[i + 2]))
        }
        return best
    }

    /// Mean brightness (0-255) of an area of a screenshot, in points.
    private func luminance(_ shot: XCUIScreenshot, in rect: CGRect) -> Double {
        guard let image = shot.image.cgImage else { return 0 }
        let scale = CGFloat(image.width) / app.frame.width
        let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
        guard let crop = image.cropping(to: pixels) else { return 0 }
        let side = 16
        var data = [UInt8](repeating: 0, count: side * side * 4)
        guard let context = CGContext(data: &data, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        context.interpolationQuality = .medium
        context.draw(crop, in: CGRect(x: 0, y: 0, width: side, height: side))
        var total = 0.0
        for i in stride(from: 0, to: data.count, by: 4) {
            total += 0.2126 * Double(data[i]) + 0.7152 * Double(data[i + 1]) + 0.0722 * Double(data[i + 2])
        }
        return total / Double(side * side)
    }

    /// "+" beside Play puts a film on My List, as in the TV app, and Home
    /// has a My List row with it (kept on the server: there after a relaunch).
    func testMyList() throws {
        let raw = try XCTUnwrap(ProcessInfo.processInfo.environment["DEBUG_EMBY"], "no test server account")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let server = try XCTUnwrap((json["serverURL"] as? String).flatMap(URL.init(string:)))
        func reset() {
            let done = expectation(description: "reset")
            URLSession.shared.dataTask(with: server.appending(path: "mock/set").appending(queryItems: [.init(name: "reset", value: "1")])) { _, _, _ in
                done.fulfill()
            }.resume()
            wait(for: [done], timeout: 10)
        }
        reset()
        defer { reset() }
        app.launchArguments = ["-tvTab", "search", "-debugSearch", "animals"]
        app.launch()
        sleep(6)
        press(.down, "to keyboard")
        press(.down, "to first film")
        press(.select, "open film")
        sleep(2)
        press(.right, "to +")
        XCTAssertTrue(focused().contains("Add to My List"), "+ isn't next to Play: \(focused())")
        press(.select, "add to My List")
        XCTAssertTrue(app.buttons["Remove from My List"].exists, "+ didn't turn into a tick")
        app.terminate()
        app.launchArguments = []
        app.launch()
        sleep(6)
        // Down past the hero and Continue Watching: the next row is My List.
        press(.down, "to Play")
        press(.down, "to Continue Watching")
        press(.down, "to My List")
        shot("my list on home")
        XCTAssertTrue(app.staticTexts["My List"].exists, "no My List row on Home")
        XCTAssertTrue(focused().contains("Animals"), "My List doesn't start with the film: \(focused())")
    }

    /// Search: Select opens the result that has focus (its page shows the
    /// same year). Regression: focus was on "Animals" 2019, and the 2009
    /// one opened.
    func testSearchOpensFocusedResult() {
        app.launchArguments = ["-tvTab", "search", "-debugSearch", "animals"]
        app.launch()
        sleep(6)
        press(.down, "to keyboard")
        press(.down, "to first film")
        let card = focused()
        let year = card.range(of: #"\b(19|20)\d\d\b"#, options: .regularExpression).map { String(card[$0]) }
        XCTAssertNotNil(year, "no year on the focused result: \(card)")
        press(.select, "open it")
        sleep(2)
        shot("search opened")
        let details = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", year ?? "?")).firstMatch
        XCTAssertTrue(details.exists, "focused \(card), but the page that opened isn't from \(year ?? "?")")
    }

    /// Closing the player over Home: Continue Watching is in its new order
    /// when Home shows, and stays so. Regression: the cards swapped places
    /// about 200 ms after Home came back (the stop reached Home only after
    /// the player had closed).
    /// An episode whose intro the server has marked (Emby's intro
    /// detection): "Skip Intro" shows while it plays, and a click skips to
    /// the intro's end, as in the Apple TV app; then it's gone. The user
    /// asked for it (14 October).
    func testSkipIntro() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        configure(server, ["intro": "4,90", "episode_resume": "0"])
        app.launch()
        sleep(6)
        // Continue Watching's first card: the show, at its episode.
        for _ in 0..<5 where !focused().contains("id='continue-") { press(.down, "down to Continue Watching") }
        press(.select, "play")
        let skip = app.staticTexts["Skip Intro"].firstMatch
        XCTAssertTrue(skip.waitForExistence(timeout: 20), "no Skip Intro during the intro")
        XCTAssertLessThan(playerSecond() ?? 999, 90, "Skip Intro came after the intro")
        press(.select, "skip intro")
        sleep(2)
        XCTAssertGreaterThanOrEqual(playerSecond() ?? 0, 89, "the click didn't skip to the intro's end")
        XCTAssertFalse(skip.exists, "Skip Intro stayed after the intro")
    }

    func testContinueWatchingStillAfterClose() {
        app.launch()
        sleep(6)
        for _ in 0..<5 where !focused().contains("id='continue-") { press(.down, "down to Continue Watching") }
        press(.right, "second card")
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        let id = card.identifier
        XCTAssertTrue(id.hasPrefix("continue-"), "not on a Continue Watching card: \(focused())")
        press(.select, "play")
        wait(seconds: 10)
        press(.right, "skip")
        press(.right, "skip")
        // Menu until the player has gone (the first may only hide its bar).
        let played = app.buttons[id]
        for _ in 0..<3 where !played.exists || !played.isHittable {
            remote.press(.menu)
            usleep(300_000)
        }
        let stop = app.staticTexts["debug-stop"].firstMatch
        XCTAssertEqual(stop.label, "stop noted player=up", "the stop reached Home after the player had closed")
        let first = played.frame
        var moves: [String] = []
        for step in 0..<10 {
            usleep(200_000)
            let now = played.frame
            if abs(now.minX - first.minX) > 1 || abs(now.minY - first.minY) > 1 { moves.append("\(step): \(first) → \(now)") }
        }
        shot("home after close")
        XCTAssertEqual(moves, [], "the card moved after Home came back")
    }

    /// Paused, up to the audio button, then Play/Pause: playing again with
    /// the remote back on the bar, so a click right still skips (it used to
    /// stay on the hidden button and do nothing).
    func testSkipAfterResumeFromButtons() {
        app.launchArguments = ["-tvTab", "search", "-debugSearch", "animals"]
        app.launch()
        sleep(6)
        press(.down, "to keyboard")
        press(.down, "to first film")
        press(.select, "open film")
        sleep(2)
        press(.select, "play")
        sleep(8)
        remote.press(.playPause)
        sleep(1)
        remote.press(.up)
        usleep(800_000)
        remote.press(.playPause)
        usleep(1_500_000)
        let before = barSeconds()
        remote.press(.right)
        usleep(700_000)
        let after = barSeconds()
        shot("after resume and skip")
        print("BAR before \(before ?? -1) after \(after ?? -1)")
        XCTAssertNotNil(before, "no transport bar")
        XCTAssertGreaterThanOrEqual((after ?? 0) - (before ?? 0), 8, "the click right didn't skip")
    }

    /// Playback speed, as in the Apple TV app: up to the round buttons,
    /// right to Playback Speed, its menu on 1×, down to 2×: the film plays
    /// twice as fast.
    func testPlaybackSpeed() {
        app.launchArguments = ["-tvTab", "search", "-debugSearch", "animals"]
        app.launch()
        sleep(6)
        press(.down, "to keyboard")
        press(.down, "to first film")
        press(.select, "open film")
        sleep(2)
        press(.select, "play")
        sleep(8)
        press(.up, "to the round buttons")
        press(.right, "to speed")
        press(.select, "speed menu")
        for _ in 0..<3 { press(.down, "down the speeds") }
        press(.select, "pick 2x")
        press(.down, "back to the bar")
        guard let first = playerSecond() else { return XCTFail("no position readout") }
        let from = Date()
        sleep(4)
        guard let later = playerSecond() else { return XCTFail("no position readout") }
        let rate = (later - first) / Date().timeIntervalSince(from)
        XCTAssertGreaterThan(rate, 1.6, "2× played at \(rate)×")
    }

    /// The subtitle menu's rows pick what they say: "English" shows the
    /// English subtitles. Regression: a row picked the file's track at that
    /// place among all of them, and the test film lists Spanish first, so
    /// "English" showed Spanish (the menu lists English first). Needs the
    /// multi-track test film (TEST_RUNNER_MULTI_TRACK=1).
    func testSubtitleRowPicksItsLanguage() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MULTI_TRACK"] != nil, "needs the multi-track test file")
        app.launchArguments = ["-tvTab", "search", "-debugSearch", "animals", "-forgetTrackChoices", "YES"]
        app.launch()
        sleep(6)
        press(.down, "to keyboard")
        press(.down, "to first film")
        press(.select, "open film")
        sleep(2)
        press(.select, "play")
        sleep(8)
        // Up lands on Audio (the player's own focus, not the system's);
        // Subtitles is to its left.
        press(.up, "to the round buttons")
        press(.left, "to subtitles")
        press(.select, "subtitles menu")
        press(.down, "to English")
        press(.select, "pick English")
        sleep(2)
        let tracks = app.staticTexts["debug-tracks"].firstMatch.label
        XCTAssertTrue(tracks.hasSuffix("subtitles=eng"), "English picked, but: \(tracks)")
    }

    /// At an episode's end the next one plays in the same player, as the
    /// Apple TV app's Auto-Play does. Regression: on Apple TV the player
    /// closed there (the iPhone already played on).
    func testNextEpisodeAtEnd() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        configure(server, ["episode_resume": "580"])
        defer { configure(server, ["reset": "1"]) }
        app.launchArguments = ["-tvTab", "search", "-debugSearch", "forensic"]
        app.launch()
        sleep(6)
        press(.down, "to keyboard")
        press(.down, "to the results")
        for _ in 0..<6 where !focused().contains("label='Forensic Files") { press(.right, "along the results") }
        press(.select, "open the show")
        sleep(3)
        XCTAssertTrue(focused().contains("Continue"), "not on the show's Continue button: \(focused())")
        press(.select, "play the episode near its end")
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
        press(.down, "next episode playing")
    }

    func testFocusMovedOnStopsTheCardsSubtitles() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        configure(server, ["reference_delay": "10"])
        defer { configure(server, ["reset": "1"]) }
        app.launchArguments = ["-forgetServerSubtitles", "YES"]
        app.launch()
        sleep(6)
        for _ in 0..<5 where !focused().contains("id='continue-") { press(.down, "down to Continue Watching") }
        sleep(2)
        press(.right, "second card")
        sleep(2)
        press(.right, "third card")
        sleep(12)
        XCTAssertFalse(subtitleCuts(server).isEmpty, "a card's player left behind kept asking for its subtitles")
    }

    private func subtitleCuts(_ server: URL) -> [String] {
        var cut: [String] = []
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: server.appending(path: "mock/subtitle_requests")) { data, _, _ in
            cut = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: [String]] })?["cut"] ?? []
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 10)
        return cut
    }

    func testFirstPlayPauseAfterAStartFromItsPagePauses() throws {
        for start in 1...2 {
            try startFromItsPage()
            firstPlayPausePauses("start \(start)")
            app.terminate()
        }
    }

    func testFirstSelectOnAStartTheServerNeverAnsweredTriesAgain() throws {
        try firstSelectTriesAgain(hang: "item,plan")
    }

    func testFirstSelectOnAFilmThatNeverArrivedTriesAgain() throws {
        try firstSelectTriesAgain(hang: "open")
    }

    func testFirstMenuWhileTheServerIsAskedClosesThePlayer() throws {
        try firstMenuCloses(hang: "item,plan")
    }

    func testFirstMenuWhileTheFilmIsAwaitedClosesThePlayer() throws {
        try firstMenuCloses(hang: "open")
    }

    private func firstPlayPausePauses(_ when: String) {
        XCTAssertTrue(readout("debug-film-loading", within: 30) { $0.contains("film") }, "\(when): the film didn't move")
        remote.press(.playPause)
        XCTAssertTrue(readout("debug-position", within: 3) { $0.hasSuffix("paused") },
                      "\(when): the first Play/Pause didn't pause; focus: \(focused())")
    }

    private func firstSelectTriesAgain(hang: String) throws {
        let server = try startFromItsPage(hang: hang, ["-filmLoadingLimit", "8"])
        XCTAssertTrue(readout("debug-film-loading", within: 20) { $0.contains("failed") }, "the start didn't fail")
        configure(server, ["hang": "none"])
        remote.press(.select)
        XCTAssertTrue(readout("debug-film-loading", within: 3) { $0.components(separatedBy: "failed").last?.contains("ring") == true },
                      "the first Select on the failure didn't try again; focus: \(focused())")
        firstPlayPausePauses("after Try again")
    }

    private func firstMenuCloses(hang: String) throws {
        try startFromItsPage(hang: hang)
        XCTAssertTrue(readout("debug-film-loading", within: 10) { $0.contains("ring") }, "no ring while waiting")
        remote.press(.menu)
        XCTAssertTrue(app.staticTexts["debug-film-loading"].firstMatch.waitForNonExistence(timeout: 3),
                      "the first Menu while waiting didn't close the player; focus: \(focused())")
    }

    @discardableResult
    private func startFromItsPage(hang: String = "none", _ arguments: [String] = []) throws -> URL {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        configure(server, ["hang": hang])
        addTeardownBlock { self.configure(server, ["reset": "1"]) }
        app.launchArguments = ["-tvTab", "search", "-debugSearch", "animals"] + arguments
        app.launch()
        sleep(6)
        press(.down, "to keyboard")
        press(.down, "to first film")
        press(.select, "open film")
        sleep(2)
        remote.press(.select)
        return server
    }

    private func readout(_ id: String, within seconds: Double, _ test: (String) -> Bool) -> Bool {
        let element = app.staticTexts[id].firstMatch
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if element.exists, test(element.label) { return true }
            usleep(250_000)
        } while Date() < deadline
        return false
    }

    /// The test server's address, from the account passed in.
    private func testServer() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["DEBUG_EMBY"],
              let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let address = json["serverURL"] as? String else { return nil }
        return URL(string: address)
    }

    /// Sets the test server's behaviour (scripts/mock_server.py, /mock/set).
    private func configure(_ server: URL, _ settings: [String: String]) {
        let url = server.appending(path: "mock/set").appending(queryItems: settings.map { URLQueryItem(name: $0.key, value: $0.value) })
        // A semaphore, not an expectation: it runs in tear-down too.
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 10)
    }

    /// The player's second, from its debug readout ("72.4 playing").
    private func playerSecond() -> Double? {
        app.staticTexts["debug-position"].firstMatch.label.split(separator: " ").first.flatMap { Double($0) }
    }

    /// The transport bar's time, in seconds ("02:12, -07:48" → 132).
    private func barSeconds() -> Double? {
        let bar = app.descendants(matching: .any).matching(NSPredicate(format: "label == 'Playing' OR label == 'Paused'")).firstMatch
        guard bar.exists, let value = bar.value as? String, let time = value.split(separator: ",").first else { return nil }
        return time.split(separator: ":").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }.reduce(0) { $0 * 60 + $1 }
    }

    /// Home's focus motion, for a screen recording: down into the rows,
    /// along one, open a title, and back.
    func testHomeMotion() {
        app.launchArguments = ["-tvTab", "home"]
        app.launch()
        sleep(6)
        for _ in 0..<2 { remote.press(.down); sleep(1) }
        for _ in 0..<4 { remote.press(.right); usleep(700_000) }
        remote.press(.down); sleep(1)
        for _ in 0..<3 { remote.press(.right); usleep(700_000) }
        remote.press(.select)
        sleep(3)
        remote.press(.down); sleep(1)
        remote.press(.menu)
        sleep(2)
    }

    /// Preview stills: play a film long enough for its thumbnails to load
    /// (debug builds log "PERF thumbnails <count>"), then hold right; the
    /// still shows while the player catches up.
    func testScrubStills() {
        app.launchArguments = ["-tvTab", "search", "-debugSearch", "animals"]
        app.launch()
        sleep(6)
        press(.down, "to keyboard")
        press(.down, "to first film")
        press(.select, "open film")
        sleep(2)
        press(.select, "play")
        sleep(9)
        remote.press(.right, forDuration: 1.2)
        shot("after hold")
        sleep(2)
        shot("playing on")
    }

    /// Signed in through the Keychain: the account saved as signing in
    /// does, then a launch reading it back (one Keychain read for all).
    func testKeychainSignIn() throws {
        guard let account = ProcessInfo.processInfo.environment["STORE_EMBY"] else { throw XCTSkip("no account") }
        app.launchEnvironment["OPENREEL_DEBUG_EMBY"] = nil
        app.launchEnvironment["OPENREEL_DEBUG_STORE_EMBY"] = account
        app.launchArguments = ["-tvTab", "home"]
        app.launch()
        sleep(3)
        app.terminate()
        app.launchEnvironment["OPENREEL_DEBUG_STORE_EMBY"] = nil
        app.launch()
        sleep(8)
        shot("signed in from keychain")
        XCTAssertTrue(app.buttons["More Info"].exists, "not signed in")
    }

    /// A film's page opens complete: its poster focused a moment (the page
    /// is fetched ahead), then 0.4 s after Select the story is there.
    func testPageOpensComplete() {
        app.launchArguments = ["-tvTab", "search", "-debugSearch", "animals"]
        app.launch()
        sleep(6)
        press(.down, "to keyboard")
        press(.down, "to first film")
        press(.right, "next film")
        sleep(1)
        remote.press(.select)
        usleep(400_000)
        shot("page at 0.4 s")
        let story = app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'a title from the test library'"))
        XCTAssertTrue(story.firstMatch.exists, "the page wasn't complete 0.4 s after Select")
    }

    /// A cold launch shows Home with its featured title within a second.
    func testColdLaunchHome() {
        app.launchArguments = ["-tvTab", "home"]
        app.launch()
        app.terminate()
        app.launch()
        sleep(1)
        shot("home at 1 s")
        XCTAssertTrue(app.buttons["More Info"].exists, "Home wasn't drawn 1 s after launch")
    }

    /// The live player's bar: playing, then paused (Play/Pause).
    func testLivePlayerBar() {
        app.launchArguments = ["-tvTab", "live"]
        app.launch()
        sleep(8)
        press(.down, "into the page")
        press(.select, "play channel")
        sleep(6)
        press(.select, "controls")
        shot("live playing")
        remote.press(.playPause)
        sleep(2)
        shot("live paused")
        press(.menu, "leave")
    }

    private func shot(_ note: String) {
        step += 1
        let name = String(format: "%02d-%@.png", step, note.replacingOccurrences(of: " ", with: "-"))
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: name))
        print("SHOT \(note) → \(name)")
    }

    /// Resume: a show partway through an episode (the test server's
    /// "Animals." is 8:48 into S2 E3) continues there, not from the start.
    func testResume() {
        app.launchArguments = ["-tvTab", "search", "-debugSearch", "animals"]
        app.launch()
        sleep(6)
        press(.down, "to keyboard")
        press(.down, "to the posters")
        for _ in 0..<8 where !focused().contains(", Show") { press(.right, "looking for the show") }
        press(.select, "open show")
        sleep(3)
        shot("show page")
        press(.select, "continue")
        sleep(6)
        press(.select, "pause to see time")
        press(.menu, "menu 1")
        press(.menu, "menu 2")
    }

    /// A show's seasons: the chosen one, one under focus, and the chosen
    /// one again with focus down in the episodes.
    func testSeasonChips() {
        app.launchArguments = ["-tvTab", "search", "-debugSearch", "office"]
        app.launch()
        sleep(6)
        press(.down, "to keyboard")
        press(.down, "to the posters")
        for _ in 0..<8 where !focused().contains(", Show") { press(.right, "looking for the show") }
        press(.select, "open show")
        sleep(3)
        press(.down, "to seasons")
        press(.right, "next season")
        press(.down, "to episodes")
    }

    /// Live TV: into the page, Left opens the slide-out list on the chosen
    /// shelf, down to another shelf, Select picks it and closes the list;
    /// then Left and Right (close without changing), and Left and Menu.
    func testLiveList() {
        // No -tvLiveTab: a launch argument would pin the shelf.
        app.launchArguments = ["-tvTab", "live"]
        app.launch()
        sleep(6)
        press(.down, "into the page")
        // Left until focus leaves the cards: the list opens on the shelf.
        for _ in 0..<5 { press(.left, "left") }
        shot("list open")
        press(.down, "down in list")
        press(.select, "pick")
        shot("after pick")
        for _ in 0..<5 { press(.left, "left again") }
        press(.right, "right closes")
        for _ in 0..<5 { press(.left, "left once more") }
        press(.menu, "menu closes")
        press(.menu, "menu to tab bar")
    }

    /// Live TV with no channels (the lineup failed, or hasn't loaded): Left
    /// opens no empty list, and Menu goes to the tab bar instead of quitting.
    /// Run with the test server stopped, no saved lineup and LIVE_EMPTY=1
    /// (TEST_RUNNER_LIVE_EMPTY): with channels, Left opens the list.
    func testLiveEmpty() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["LIVE_EMPTY"] != nil, "needs the test server stopped")
        app.launchArguments = ["-tvTab", "live"]
        app.launch()
        sleep(8)
        press(.down, "into the page")
        for _ in 0..<3 { press(.left, "left") }
        shot("empty")
        press(.menu, "menu to tab bar")
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertTrue(focused().contains("label='Live TV'"), focused())
    }

    /// Home, left before it finished loading and opened again: the featured
    /// title and the rows are there (a cut-off load used to leave only
    /// Continue Watching, for hours).
    func testHomeAfterLeaving() {
        app.launchArguments = ["-tvTab", "home"]
        app.launch()
        sleep(1)
        press(.up, "to tab bar")
        press(.right, "to Live TV")
        sleep(6)
        press(.left, "back to Home")
        sleep(2)
        shot("home")
        XCTAssertTrue(app.buttons["More Info"].exists, "no featured title")
    }

    /// A game on several channels (the test server's `sports=1`): it plays
    /// on the best one; with the controls up Select opens Watch On, the
    /// remote moves along it, Select plays the one it's on, and that one
    /// plays first for the league's games after.
    func testWatchOnRemote() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1", "dead_live": "none"])
        addTeardownBlock { [self] in configure(server, ["sports": "0"]) }
        // The test server's channels (its test login, for this run).
        app.launchEnvironment["OPENREEL_DEBUG_IPTV"] = #"{"id":"6F9A1E52-0000-4000-8000-000000000001","name":"Test","kind":"#
            + #"{"xtream":{"server":"\#(server.absoluteString)","username":"u","password":"p"}}}"#
        app.launchArguments = ["-tvTab", "live", "-tvLiveTab", "shelf:sports", "-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        sleep(8)
        toGame()
        XCTAssertTrue(focused().contains("Jaguars"), "the game isn't in Sports: \(focused())")
        press(.select, "play the game")
        XCTAssertTrue(playing("NFL 01"), "the game didn't start on the best channel: \(liveCopy())")
        let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'player.watchon.' AND identifier != 'player.watchon.tab'"))
        // Controls up, then Watch On (Select shows them if they'd gone).
        for _ in 0..<2 where !cards.firstMatch.exists { press(.select, "watch on") }
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 3), "Select didn't open Watch On")
        XCTAssertEqual(cards.count, 5, "not every channel showing the game")
        shot("watch on")
        let spanish = cards.matching(NSPredicate(format: "label CONTAINS 'Spanish'")).firstMatch
        for _ in 0..<5 where !spanish.isSelected { press(.right, "along") }
        XCTAssertTrue(spanish.isSelected, "the remote didn't reach the Spanish feed")
        press(.select, "pick")
        XCTAssertTrue(playing("ESPN UNLTD 016"), "the channel picked didn't open: \(liveCopy())")
        XCTAssertTrue(started(), "the channel picked didn't play")
        press(.menu, "leave")
        toGame()
        press(.select, "the game again")
        XCTAssertTrue(playing("ESPN UNLTD 016"), "the league's pick didn't play first: \(liveCopy())")
    }

    /// Many accounts allow one stream at a time: live TV paused when the
    /// Apple TV goes to the Home screen lets it go, and opens live again on
    /// return.
    func testAppleTVPausedAwayFreesTheAccount() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["reset": "1"])
        configure(server, ["live_max_connections": "1", "live_linger": "0"])
        addTeardownBlock { [self] in configure(server, ["reset": "1"]) }
        app.launchEnvironment["OPENREEL_DEBUG_IPTV"] = #"{"id":"6F9A1E52-0000-4000-8000-000000000001","name":"Test","kind":"#
            + #"{"xtream":{"server":"\#(server.absoluteString)","username":"u","password":"p"}}}"#
        app.launchArguments = ["-tvTab", "live", "-freshLineup", "YES"]
        app.launch()
        sleep(8)
        press(.down, "into the page")
        press(.select, "play channel")
        XCTAssertTrue(started(), "the channel didn't play: \(liveCopy())")
        remote.press(.playPause)
        sleep(2)
        XCTAssertEqual(activeConnections(server), "1", "the paused stream isn't open")
        remote.press(.home)
        XCTAssertTrue(activeConnections(server, become: "0", within: 8), "live TV paused at the Home screen still holds the connection")
        app.activate()
        XCTAssertTrue(activeConnections(server, become: "1", within: 15), "live TV didn't open again on return")
        XCTAssertTrue(started(), "live TV didn't play on return")
    }

    func testAppleTVLiveLetsGoWhenLeaving() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["reset": "1"])
        configure(server, ["live_max_connections": "1", "live_linger": "0"])
        addTeardownBlock { [self] in configure(server, ["reset": "1"]) }
        app.launchEnvironment["OPENREEL_DEBUG_IPTV"] = #"{"id":"6F9A1E52-0000-4000-8000-000000000001","name":"Test","kind":"#
            + #"{"xtream":{"server":"\#(server.absoluteString)","username":"u","password":"p"}}}"#
        app.launchArguments = ["-tvTab", "live", "-freshLineup", "YES"]
        app.launch()
        sleep(8)
        press(.down, "into the page")
        press(.select, "play channel")
        XCTAssertTrue(started(), "the channel didn't play: \(liveCopy())")
        XCTAssertTrue(nowPlaying("playing"), "Now Playing doesn't hear the channel play: the Apple TV sleeps mid-channel")
        remote.press(.home)
        XCTAssertTrue(activeConnections(server, become: "0", within: 8), "live TV played on at the Home screen")
        app.activate()
        XCTAssertTrue(activeConnections(server, become: "1", within: 15), "live TV didn't open again on return")
        XCTAssertTrue(started(), "live TV didn't play on return")
    }

    private func activeConnections(_ server: URL) -> String? {
        let url = server.appending(path: "player_api.php").appending(queryItems: [.init(name: "username", value: "u"), .init(name: "password", value: "p")])
        var data: Data?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { body, _, _ in
            data = body
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 10)
        let account = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        return (account?["user_info"] as? [String: Any])?["active_cons"] as? String
    }

    private func activeConnections(_ server: URL, become wanted: String, within seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if activeConnections(server) == wanted { return true }
            usleep(500_000)
        }
        return false
    }

    /// Down from the tab bar to the game's card: the Live TV list opens
    /// on Sports, its NFL opens the league's games.
    private func toGame() {
        for _ in 0..<6 where !focused().contains("Jaguars") {
            if focused().contains("label='NFL") { press(.select, "nfl") } else { press(.down, "down to the game") }
        }
    }

    /// The live player shows a picture within 15 s.
    private func started() -> Bool {
        let readout = app.staticTexts["debug-live-state"].firstMatch
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if readout.exists, readout.label == "playing" { return true }
            usleep(250_000)
        }
        return false
    }

    /// Press-and-hold Select on a game's card lists the channels showing it
    /// (Watch On, as in the player); the one picked plays.
    func testWatchOnFromGameCard() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1", "dead_live": "none"])
        addTeardownBlock { [self] in configure(server, ["sports": "0"]) }
        app.launchEnvironment["OPENREEL_DEBUG_IPTV"] = #"{"id":"6F9A1E52-0000-4000-8000-000000000001","name":"Test","kind":"#
            + #"{"xtream":{"server":"\#(server.absoluteString)","username":"u","password":"p"}}}"#
        app.launchArguments = ["-tvTab", "live", "-tvLiveTab", "shelf:sports", "-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        sleep(8)
        toGame()
        XCTAssertTrue(focused().contains("Jaguars"), "the game isn't in Sports: \(focused())")
        remote.press(.select, forDuration: 1.5)
        sleep(1)
        shot("game card menu")
        // In the order they'd play: NFL, ESPN Unlimited and DAZN CA in
        // English, then ESPN Unlimited in Spanish (the 4th) and DAZN CA in
        // French (the language is each item's second line).
        // The menu's items show no words to the test, its heading does; the
        // 4th item playing the Spanish feed shows the order.
        XCTAssertTrue(app.staticTexts["Watch On · 5 channels"].firstMatch.waitForExistence(timeout: 5),
                      "no Watch On menu on press-and-hold")
        for _ in 0..<3 { press(.down, "down the channels") }
        press(.select, "pick")
        XCTAssertTrue(playing("ESPN UNLTD 016"), "the channel picked didn't play: \(liveCopy())")
    }

    func testAppleTVSaysWhichChannelDidntPlay() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1", "dead_live": "2001", "slow_live": "2002"])
        addTeardownBlock { [self] in configure(server, ["sports": "0", "dead_live": "none", "slow_live": "none"]) }
        app.launchEnvironment["OPENREEL_DEBUG_IPTV"] = #"{"id":"6F9A1E52-0000-4000-8000-000000000001","name":"Test","kind":"#
            + #"{"xtream":{"server":"\#(server.absoluteString)","username":"u","password":"p"}}}"#
        app.launchEnvironment["OPENREEL_DEBUG_LIVE_START_LIMIT"] = "8"
        app.launchEnvironment["OPENREEL_DEBUG_SWITCH_CUE_SECONDS"] = "10"
        app.launchArguments = ["-tvTab", "live", "-tvLiveTab", "shelf:sports", "-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        sleep(8)
        toGame()
        XCTAssertTrue(focused().contains("Jaguars"), "the game isn't in Sports: \(focused())")
        press(.select, "play the game")
        XCTAssertTrue(playing("NFL 01"), "the game didn't open on the best channel: \(liveCopy())")
        let cue = app.descendants(matching: .any)["live.switch-cue"].firstMatch
        func says(_ words: String...) -> Bool {
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if cue.exists, words.allSatisfy(cue.label.contains) { return true }
                usleep(200_000)
            }
            return false
        }
        XCTAssertTrue(says("NFL didn’t play", "Switching"), "no word while the player moves on: \(cue.exists ? cue.label : "no cue")")
        shot("switching")
        XCTAssertTrue(says("Now on ESPN Unlimited"), "the cue doesn't say where the player went: \(cue.exists ? cue.label : "no cue")")
        XCTAssertTrue(started(), "the next channel didn't play: \(liveCopy())")
        shot("now on")
        XCTAssertLessThan(cue.frame.maxY, app.frame.height * 0.3, "the cue isn't at the top: \(cue.frame)")

        let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'player.watchon.' AND identifier != 'player.watchon.tab'"))
        for _ in 0..<2 where !cards.firstMatch.exists { press(.select, "watch on") }
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 3), "Select didn't open Watch On")
        let nfl = cards.matching(NSPredicate(format: "identifier ENDSWITH '|2001'")).firstMatch
        let espn = cards.matching(NSPredicate(format: "identifier ENDSWITH '|2002'")).firstMatch
        XCTAssertTrue(nfl.label.contains("Didn’t play"), "the card of the channel that didn't play: \(nfl.label)")
        XCTAssertTrue(espn.label.contains("Playing") && !espn.label.contains("Didn’t"), "the card playing: \(espn.label)")
        sleep(1)
        let picture = XCUIScreen.main.screenshot()
        let pictureWidth: CGFloat = 320
        let corner = badgeCorner(right: nfl.frame.minX + pictureWidth, top: nfl.frame.minY)
        XCTAssertGreaterThan(brightest(picture, in: corner), 200, "no mark on the picture of the card that didn't play")
    }

    func testAppleTVGameNotPlayingMarksEveryCard() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1", "dead_live": "2001,2002,2003,2004,2005"])
        addTeardownBlock { [self] in configure(server, ["sports": "0", "dead_live": "none"]) }
        app.launchEnvironment["OPENREEL_DEBUG_IPTV"] = #"{"id":"6F9A1E52-0000-4000-8000-000000000001","name":"Test","kind":"#
            + #"{"xtream":{"server":"\#(server.absoluteString)","username":"u","password":"p"}}}"#
        app.launchEnvironment["OPENREEL_DEBUG_LIVE_START_LIMIT"] = "3"
        app.launchArguments = ["-tvTab", "live", "-tvLiveTab", "shelf:sports", "-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        sleep(8)
        toGame()
        XCTAssertTrue(focused().contains("Jaguars"), "the game isn't in Sports: \(focused())")
        press(.select, "play the game")
        let state = app.staticTexts["debug-live-state"].firstMatch
        let deadline = Date().addingTimeInterval(40)
        while state.label != "failed", Date() < deadline { usleep(250_000) }
        XCTAssertEqual(state.label, "failed", "still trying after every channel: \(liveCopy())")
        let cards = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH 'player.watchon.' AND identifier != 'player.watchon.tab'"))
        for _ in 0..<2 where !cards.firstMatch.exists { press(.select, "watch on") }
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 3), "Select didn't open Watch On")
        XCTAssertEqual(cards.count, 5, "not every channel showing the game")
        for card in cards.allElementsBoundByIndex {
            XCTAssertTrue(card.label.contains("Didn’t play") && !card.label.contains("Playing"), "a card of a game that played nowhere: \(card.label)")
        }
    }

    func testAppleTVGameCardShowsChannelCount() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1", "dead_live": "none"])
        addTeardownBlock { [self] in configure(server, ["sports": "0"]) }
        app.launchEnvironment["OPENREEL_DEBUG_IPTV"] = #"{"id":"6F9A1E52-0000-4000-8000-000000000001","name":"Test","kind":"#
            + #"{"xtream":{"server":"\#(server.absoluteString)","username":"u","password":"p"}}}"#
        app.launchArguments = ["-tvTab", "live", "-tvLiveTab", "shelf:sports", "-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        sleep(8)
        toGame()
        XCTAssertTrue(focused().contains("Jaguars") && focused().contains("5 channels"), "the game's card: \(focused())")
        // Focus off the card: its focus sheen is bright too.
        press(.up, "off the card")
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Jaguars'")).firstMatch
        XCTAssertTrue(card.exists, "the game's card went")
        let picture = XCUIScreen.main.screenshot()
        let corner = badgeCorner(right: card.frame.maxX, top: card.frame.minY, width: 30)
        XCTAssertGreaterThan(brightest(picture, in: corner), 200, "no count badge on the game's card")
        XCTAssertGreaterThan(luminance(picture, in: corner), 120, "no count badge on the game's card")
        XCTAssertGreaterThan(luminance(picture, in: leftOfDisc(corner)), 120,
                             "the count badge isn't wider than the crossed-out TV (mean \(Int(luminance(picture, in: leftOfDisc(corner)))))")
    }

    func testAppleTVCountLeavesOutAFeedThatDidntPlay() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["reset": "1"])
        configure(server, ["sports": "1", "dead_live": "2001"])
        addTeardownBlock { [self] in configure(server, ["reset": "1"]) }
        app.launchEnvironment["OPENREEL_DEBUG_IPTV"] = #"{"id":"6F9A1E52-0000-4000-8000-000000000001","name":"Test","kind":"#
            + #"{"xtream":{"server":"\#(server.absoluteString)","username":"u","password":"p"}}}"#
        app.launchEnvironment["OPENREEL_DEBUG_LIVE_START_LIMIT"] = "3"
        app.launchArguments = ["-tvTab", "live", "-tvLiveTab", "shelf:sports", "-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        sleep(8)
        toGame()
        XCTAssertTrue(focused().contains("Jaguars"), "the game isn't in Sports: \(focused())")
        press(.select, "play the game")
        XCTAssertTrue(playing("NFL 01"), "the game didn't open on the best channel: \(liveCopy())")
        let readout = app.staticTexts["debug-live-copy"].firstMatch
        let deadline = Date().addingTimeInterval(20)
        while readout.label.hasPrefix("NFL 01"), Date() < deadline { usleep(250_000) }
        XCTAssertTrue(started(), "the next channel didn't play: \(liveCopy())")
        press(.menu, "leave")
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Jaguars'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the game's card went")
        XCTAssertTrue(card.label.contains("4 channels"), "the count still has the feed that didn't play: \(card.label)")
    }

    func testAppleTVNoFeedPlayedCrossesOutTheCard() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["reset": "1"])
        configure(server, ["sports": "1", "dead_live": "2001,2002,2003,2004,2005"])
        addTeardownBlock { [self] in configure(server, ["reset": "1"]) }
        app.launchEnvironment["OPENREEL_DEBUG_IPTV"] = #"{"id":"6F9A1E52-0000-4000-8000-000000000001","name":"Test","kind":"#
            + #"{"xtream":{"server":"\#(server.absoluteString)","username":"u","password":"p"}}}"#
        app.launchEnvironment["OPENREEL_DEBUG_LIVE_START_LIMIT"] = "3"
        app.launchArguments = ["-tvTab", "live", "-tvLiveTab", "shelf:sports", "-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        sleep(8)
        toGame()
        XCTAssertTrue(focused().contains("Jaguars"), "the game isn't in Sports: \(focused())")
        press(.select, "play the game")
        let state = app.staticTexts["debug-live-state"].firstMatch
        let deadline = Date().addingTimeInterval(40)
        while state.label != "failed", Date() < deadline { usleep(250_000) }
        XCTAssertEqual(state.label, "failed", "still trying after every channel: \(liveCopy())")
        press(.menu, "leave")
        let card = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Jaguars'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "the game's card went")
        XCTAssertTrue(card.label.contains("Not playing"), "no word that nothing played: \(card.label)")
        XCTAssertFalse(card.label.contains("channels"), "a channel count on a game that played nowhere: \(card.label)")
        press(.up, "off the card")
        let picture = XCUIScreen.main.screenshot()
        let disc = badgeCorner(right: card.frame.maxX, top: card.frame.minY, width: 30)
        XCTAssertGreaterThan(brightest(picture, in: disc), 200, "no crossed-out TV on the game's card")
        XCTAssertLessThan(luminance(picture, in: leftOfDisc(disc)), 90,
                          "a channel count on the card of a game that played nowhere (mean \(Int(luminance(picture, in: leftOfDisc(disc)))))")
    }

    func testAppleTVChannelThatDidntPlayIsMarked() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["dead_live": "none"])
        addTeardownBlock { [self] in configure(server, ["dead_live": "none"]) }
        app.launchEnvironment["OPENREEL_DEBUG_IPTV"] = #"{"id":"6F9A1E52-0000-4000-8000-000000000001","name":"Test","kind":"#
            + #"{"xtream":{"server":"\#(server.absoluteString)","username":"u","password":"p"}}}"#
        app.launchEnvironment["OPENREEL_DEBUG_LIVE_START_LIMIT"] = "3"
        app.launchArguments = ["-tvTab", "live", "-freshLineup", "YES"]
        app.launch()
        sleep(8)
        press(.down, "into the page")
        let label = focused()
        let number = try XCTUnwrap(label.firstMatch(of: #/Channel (\d+)/#)?.1, "not on a channel's card: \(label)")
        configure(server, ["dead_live": String(number)])
        press(.select, "play the channel")
        let state = app.staticTexts["debug-live-state"].firstMatch
        let deadline = Date().addingTimeInterval(20)
        while state.label != "failed", Date() < deadline { usleep(250_000) }
        XCTAssertEqual(state.label, "failed", "the channel that sends nothing didn't fail")
        press(.menu, "back to the channels")
        XCTAssertTrue(focused().contains("Didn’t play"), "the card doesn't say it didn't play: \(focused())")
        let card = app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", "Channel \(number)", "Channel \(number),")).firstMatch
        XCTAssertTrue(card.exists, "the channel's card went")
        press(.right, "off the card")
        let picture = XCUIScreen.main.screenshot()
        let corner = badgeCorner(right: card.frame.maxX, top: card.frame.minY)
        XCTAssertGreaterThan(brightest(picture, in: corner), 200, "no mark on the card of the channel that didn't play")
    }

    /// The provider refusing (429, too many requests) at a relaunch: Sports
    /// says it couldn't update the games and how old its list is, instead
    /// of "Nothing on right now"; once the provider answers again it asks
    /// again (the wait shortened to 5 s) and the game's card shows.
    /// Regression: a refused check was silent and counted as done.
    func testAppleTVSportsSaysWhenItCouldNotUpdate() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1", "sports_started": "300"])
        addTeardownBlock { [self] in configure(server, ["sports": "0", "sports_started": "20", "xtream_status": "0"]) }
        app.launchEnvironment["OPENREEL_DEBUG_IPTV"] = #"{"id":"6F9A1E52-0000-4000-8000-000000000001","name":"Test","kind":"#
            + #"{"xtream":{"server":"\#(server.absoluteString)","username":"u","password":"p"}}}"#
        app.launchEnvironment["OPENREEL_DEBUG_GAMES_MAX_AGE"] = "5"
        app.launchArguments = ["-tvTab", "live", "-tvLiveTab", "shelf:sports", "-cacheFolder", "live-\(UUID().uuidString.prefix(8))"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Nothing on right now"].firstMatch.waitForExistence(timeout: 20), "a game five hours in is still listed")
        app.terminate()

        configure(server, ["xtream_status": "429", "sports_started": "20"])
        sleep(6)
        app.launch()
        let notice = app.staticTexts["Couldn't update the games"].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 20), "no word that the games couldn't be updated")
        let detail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Last updated' AND label CONTAINS 'too many requests'")).firstMatch
        XCTAssertTrue(detail.exists, "the notice doesn't say how old the list is and why")
        XCTAssertFalse(app.staticTexts["Nothing on right now"].firstMatch.exists, "\"Nothing on right now\" with the check refused")
        shot("could not update")

        configure(server, ["xtream_status": "0"])
        let game = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS 'Jaguars'")).firstMatch
        XCTAssertTrue(game.waitForExistence(timeout: 15), "the game didn't show once the provider answered again")
        XCTAssertFalse(notice.exists, "the notice stayed after a good check")
    }

    private func leftOfDisc(_ disc: CGRect) -> CGRect {
        CGRect(x: disc.minX - 12, y: disc.minY, width: 10, height: disc.height)
    }

    private func badgeCorner(right: CGFloat, top: CGFloat, width: CGFloat = 22) -> CGRect {
        let cardInset: CGFloat = 8, height: CGFloat = 22
        return CGRect(x: right - cardInset - width, y: top + cardInset, width: width, height: height)
    }

    private func liveCopy() -> String {
        app.staticTexts["debug-live-copy"].firstMatch.label
    }

    /// The live player's channel starts with `name`, within 10 s.
    private func playing(_ name: String) -> Bool {
        let readout = app.staticTexts["debug-live-copy"].firstMatch
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if readout.exists, readout.label.hasPrefix(name) { return true }
            usleep(250_000)
        }
        return false
    }

    /// Sports in the list: Select opens its leagues (with live counts), and
    /// a league opens its games.
    func testLiveListSports() {
        app.launchArguments = ["-tvTab", "live"]
        app.launch()
        sleep(8)
        press(.down, "into the page")
        for _ in 0..<5 { press(.left, "left") }
        for _ in 0..<12 where !focused().contains("Sports") { press(.up, "up to Sports") }
        press(.select, "open Sports")
        press(.down, "first league choice")
        press(.down, "second")
        shot("sports list")
        press(.select, "pick league")
        shot("league page")
    }
}

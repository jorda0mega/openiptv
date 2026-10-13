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

    /// Closing the player over Home: Continue Watching is in its new order
    /// when Home shows, and stays so. Regression: the cards swapped places
    /// about 200 ms after Home came back (the stop reached Home only after
    /// the player had closed).
    func testContinueWatchingStillAfterClose() {
        app.launch()
        sleep(6)
        for _ in 0..<5 where !focused().contains("id='continue-") { press(.down, "down to Continue Watching") }
        press(.right, "second card")
        let card = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        let id = card.identifier
        XCTAssertTrue(id.hasPrefix("continue-"), "not on a Continue Watching card: \(focused())")
        press(.select, "play")
        sleep(10)
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
    /// Run with the test server stopped and no saved lineup.
    func testLiveEmpty() {
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

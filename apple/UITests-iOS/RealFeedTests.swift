import XCTest

/// iPhone on the real feeds: the Emby server and IPTV lineup the app is
/// for, not the test server. The logins come from a helper on this Mac
/// that holds them in memory (TEST_RUNNER_REAL_FEED, its address); skipped
/// without it. Screenshots go to /tmp/openiptv/uitest-real.
final class RealFeedTests: XCTestCase {
    private let app = XCUIApplication()
    private let shots = URL(fileURLWithPath: "/tmp/openiptv/uitest-real")
    private var step = 0

    override func setUpWithError() throws {
        continueAfterFailure = false
        let feed = ProcessInfo.processInfo.environment["REAL_FEED"].flatMap(URL.init(string:))
        try XCTSkipIf(feed == nil, "needs the real feeds (TEST_RUNNER_REAL_FEED)")
        // The helper's addresses, not the logins: the simulator's system
        // log records the launch environment. The app fetches them.
        app.launchEnvironment["OPENREEL_DEBUG_EMBY_URL"] = feed!.appending(path: "emby").absoluteString
        app.launchEnvironment["OPENREEL_DEBUG_IPTV_URL"] = feed!.appending(path: "iptv").absoluteString
        // The viewer's own account: playing reports nothing to the server,
        // so where they are in a title stays as it was.
        app.launchArguments = ["-readOnlyServer", "YES", "-cacheFolder", ProcessInfo.processInfo.environment["REAL_FEED_CACHE"] ?? "real"]
        XCUIDevice.shared.orientation = .portrait
    }

    /// Asterix and Cleopatra (1968): French sound, and an English subtitle
    /// file made for another cut: 0.7 s early for its first 9 minutes, 6.5 s
    /// until the fortieth, 7.3 s after (measured against the film's speech
    /// and its Hebrew file, which is in time). Regression: one shift for the
    /// whole film (6.45 s) put the opening 6 s late. The player shows it
    /// rewritten in three sections, within five minutes (sixteen stretches
    /// of speech from this server, then four more over its first scene).
    func testSubtitleFileInTimeBySpeech() throws {
        app.launchEnvironment["OPENREEL_DEBUG_IPTV_URL"] = nil
        app.launchArguments += ["-debugSearch", "Asterix and Cleopatra", "-forgetSubtitleTimings", "YES"]
        app.launch()
        let tab = app.tabBars.buttons["Search"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "no Search tab")
        tab.tap()
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Asterix and Cleopatra'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30), "no Asterix and Cleopatra in the results")
        result.tap()
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Resume' OR label BEGINSWITH 'Continue'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 20), "the film's page has no Play")
        play.tap()
        XCTAssertNotNil(waitForPosition(timeout: 45), "the film didn't open")
        let shift = app.staticTexts["debug-subshift"].firstMatch
        let tracks = app.staticTexts["debug-tracks"].firstMatch
        let opened = Date()
        // The speech heard first, then more of it where parts were at odds
        // (the first scene): three sections in the end.
        func sections() -> Int { shift.exists && shift.label.hasPrefix("sections") ? shift.label.split(separator: " ").count - 1 : 0 }
        while Date().timeIntervalSince(opened) < 300, sections() < 3 { sleep(2) }
        say("REAL tracks: \(tracks.exists ? tracks.label : "none") | shift \(shift.exists ? shift.label : "none") after \(Int(Date().timeIntervalSince(opened))) s")
        shot("asterix subtitles")
        // "sections 0:+0.70 538:+6.50 2390:+7.30" (from, in the file's seconds: shift).
        let label = shift.label
        XCTAssertTrue(label.hasPrefix("sections"), "the English file wasn't put in time part by part in 5 minutes: \(label)")
        let delays = label.split(separator: " ").dropFirst().compactMap { $0.split(separator: ":").last.flatMap { Double($0) } }
        XCTAssertEqual(delays.count, 3, "not three sections: \(label)")
        guard delays.count == 3 else { return }
        for (found, expected) in zip(delays, [0.7, 6.5, 7.3]) { XCTAssertEqual(found, expected, accuracy: 0.4, label) }
    }

    /// Asterix and Cleopatra as a viewer plays it, with whatever timing
    /// this device kept from an earlier play (no "forget" flag): three
    /// sections within 150 s. Regression: a device that had played it on
    /// an earlier build kept that build's two sections (its first scene 6 s
    /// late) for good; reproduced by putting such a timing back on the test
    /// iPhone before the run.
    func testAsterixAsPlayedBefore() throws {
        app.launchEnvironment["OPENREEL_DEBUG_IPTV_URL"] = nil
        app.launchArguments += ["-debugSearch", "Asterix and Cleopatra"]
        app.launch()
        let tab = app.tabBars.buttons["Search"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "no Search tab")
        tab.tap()
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Asterix and Cleopatra'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30), "no Asterix and Cleopatra in the results")
        result.tap()
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Resume' OR label BEGINSWITH 'Continue'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 20), "the film's page has no Play")
        play.tap()
        XCTAssertNotNil(waitForPosition(timeout: 45), "the film didn't open")
        let shift = app.staticTexts["debug-subshift"].firstMatch
        let opened = Date()
        while Date().timeIntervalSince(opened) < 150, !(shift.exists && shift.label.split(separator: " ").count >= 4) { sleep(2) }
        say("REAL as played before: \(shift.exists ? shift.label : "none")")
        XCTAssertEqual(shift.label.split(separator: " ").count - 1, 3, "not three sections: \(shift.label)")
    }

    /// Asterix and Cleopatra lowered to the server's converted version
    /// after 25 s (as on a slow connection) plays on from the same second.
    /// Regression: Emby's converted version is the whole film, and it was
    /// played from its start, after a pause.
    func testLowerQualityPlaysOnFromTheSameSecond() throws {
        app.launchEnvironment["OPENREEL_DEBUG_IPTV_URL"] = nil
        app.launchEnvironment["OPENREEL_DEBUG_LOWER_AFTER"] = "25"
        app.launchArguments += ["-debugSearch", "Asterix and Cleopatra"]
        app.launch()
        let tab = app.tabBars.buttons["Search"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "no Search tab")
        tab.tap()
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Asterix and Cleopatra'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30), "no Asterix and Cleopatra in the results")
        result.tap()
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Resume' OR label BEGINSWITH 'Continue'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 20), "the film's page has no Play")
        play.tap()
        let opened = try XCTUnwrap(waitForPosition(timeout: 45), "the film didn't open")
        let quality = app.staticTexts["debug-quality"].firstMatch
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline, !(quality.exists && quality.label.hasPrefix("converted")) { sleep(1) }
        XCTAssertTrue(quality.label.hasPrefix("converted"), "the quality wasn't lowered: \(quality.label)")
        // The server converting from that second: a few seconds to start.
        let lowered = Date()
        var stream = -1.0, film = -1.0
        while Date().timeIntervalSince(lowered) < 45 {
            sleep(2)
            stream = Double(app.staticTexts["debug-stream-time"].firstMatch.label) ?? -1
            film = position() ?? -1
            if stream > opened + 20 { break }
        }
        say("REAL lowered: opened at \(opened) s, now the film at \(film) s, the stream's clock at \(stream) s")
        XCTAssertGreaterThan(stream, opened + 20, "the converted version plays from the film's start")
        XCTAssertEqual(stream, film, accuracy: 3, "the stream and the film's place differ")
    }

    func testLowerQualityDeepInAFilmPlaysOn() throws {
        let film = ProcessInfo.processInfo.environment["REAL_FEED_FILM"] ?? "Asterix and Cleopatra"
        let start = 2400.0
        app.launchEnvironment["OPENREEL_DEBUG_IPTV_URL"] = nil
        app.launchEnvironment["OPENREEL_DEBUG_START_AT"] = String(Int(start))
        app.launchEnvironment["OPENREEL_DEBUG_LOWER_AFTER"] = "15"
        app.launchArguments += ["-debugSearch", film]
        app.launch()
        let tab = app.tabBars.buttons["Search"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "no Search tab")
        tab.tap()
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", film)).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30), "the film isn't in the results")
        result.tap()
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Resume' OR label BEGINSWITH 'Continue'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 20), "the film's page has no Play")
        play.tap()
        let opened = try XCTUnwrap(openedAt(timeout: 45), "the film didn't open")
        let deep = (start - 30...start + 2).contains(opened)
        print("REAL deep: opened at \(Int(opened)) s | forty minutes in \(deep ? "yes" : "no")")
        XCTAssertTrue(deep, "the film opened at \(Int(opened)) s, not forty minutes in")
        let quality = app.staticTexts["debug-quality"].firstMatch
        let note = app.descendants(matching: .any)["player-note"].firstMatch
        var noted = false
        let shown = Date()
        while Date().timeIntervalSince(shown) < 60, !(quality.exists && quality.label.hasPrefix("converted")) {
            noted = noted || note.exists
            usleep(500_000)
        }
        let lowered = quality.exists && quality.label.hasPrefix("converted")
        let dropped = Date()
        let positionBeforeFirstFrame = position() ?? 0
        var firstFrame: TimeInterval?
        var at20: Double?
        var playsAt20: Bool?
        while Date().timeIntervalSince(dropped) < 60, playsAt20 == nil || firstFrame == nil {
            let elapsed = Date().timeIntervalSince(dropped)
            let now = position() ?? positionBeforeFirstFrame
            noted = noted || note.exists
            if firstFrame == nil, abs(now - positionBeforeFirstFrame) > 0.5 { firstFrame = elapsed }
            if elapsed >= 20, at20 == nil { at20 = now }
            if let at20, elapsed >= 22.5, playsAt20 == nil { playsAt20 = now > at20 + 1 }
            usleep(500_000)
        }
        print("REAL deep: lowered \(lowered ? "yes" : "no")"
              + " | playing 20 s after the drop \(playsAt20 == true ? "yes" : "no")"
              + " | first new frame after \(firstFrame.map { String(format: "%.0f s", $0) } ?? "none in 60 s")"
              + " | note shown \(noted ? "yes" : "no")")
        XCTAssertTrue(lowered, "the film wasn't lowered to the converted version")
        XCTAssertNotNil(firstFrame, "the film stopped after the quality dropped")
        XCTAssertFalse(noted, "a note showed when the quality dropped")
    }

    /// Sentimental Destinies: French sound, and on the server only French
    /// subtitles (Junun, tried first, has Spanish ones now). The server's
    /// provider is asked, its likeliest files read through the server
    /// (nothing saved: the viewer's account may not), and English shows.
    /// Regression: the server was asked to download one and refused, and
    /// the film had none.
    func testFoundSubtitlesOnARealFilm() throws {
        app.launchEnvironment["OPENREEL_DEBUG_IPTV_URL"] = nil
        app.launchArguments += ["-debugSearch", "Sentimental Destinies", "-forgetSubtitleSearches", "YES", "-forgetTrackChoices", "YES"]
        app.launch()
        let tab = app.tabBars.buttons["Search"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "no Search tab")
        tab.tap()
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Sentimental Destinies'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30), "no Sentimental Destinies in the results")
        result.tap()
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Resume' OR label BEGINSWITH 'Continue'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 20), "the film's page has no Play")
        play.tap()
        XCTAssertNotNil(waitForPosition(timeout: 45), "the film didn't open")
        let tracks = app.staticTexts["debug-tracks"].firstMatch
        let opened = Date()
        while Date().timeIntervalSince(opened) < 90, !(tracks.exists && tracks.label.hasSuffix("subtitles=eng")) { sleep(2) }
        say("REAL found subtitles: \(tracks.exists ? tracks.label : "none") after \(Int(Date().timeIntervalSince(opened))) s")
        shot("found subtitles")
        XCTAssertTrue(tracks.label.hasSuffix("subtitles=eng"), "no English subtitles found: \(tracks.label)")
    }

    /// Home fills in from the server, and a title from it plays.
    func testHomePlaysATitle() throws {
        // Emby only: no IPTV requests the test doesn't need.
        app.launchEnvironment["OPENREEL_DEBUG_IPTV_URL"] = nil
        app.launch()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'row-'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 45), "Home has no rows")
        shot("home")
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 10), "no Continue Watching card to play")
        say("REAL playing: \(card.label)")
        card.tap()
        // The title's page (or the player at once): Play.
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Resume' OR label BEGINSWITH 'Continue'")).firstMatch
        let readout = app.staticTexts["debug-position"].firstMatch
        let deadline = Date().addingTimeInterval(20)
        while !readout.exists, Date() < deadline {
            if play.exists, play.isHittable { play.tap(); break }
            usleep(250_000)
        }
        // Started: the position moves on from where it opened.
        let first = try XCTUnwrap(waitForPosition(timeout: 20), "the player didn't open")
        let opened = Date()
        var moving: Date?
        while moving == nil, Date().timeIntervalSince(opened) < 60 {
            if let now = position(), now > first + 0.5 { moving = Date() }
            usleep(500_000)
        }
        let start = try XCTUnwrap(moving, "the title didn't start in 60 s").timeIntervalSince(opened)
        say("REAL title started \(String(format: "%.1f", start)) s after the player opened")
        let at = position() ?? 0
        sleep(6)
        let later = position() ?? 0
        shot("playing")
        XCTAssertGreaterThan(later, at + 3, "the title doesn't play on (\(at) → \(later))")
    }

    func testPrepareAheadAsSeenNow() throws {
        app.launchEnvironment["OPENREEL_DEBUG_IPTV_URL"] = nil
        let shipped = app.launchArguments + ["-forgetTrackChoices", "YES"]
        let runs: [(name: String, arguments: [String])] = [
            ("as shipped", []),
            ("as before", ["-noPrepareAhead", "YES", "-noHiddenSubtitles", "YES"]),
        ]
        var played: String?
        for run in runs {
            app.launchArguments = shipped + run.arguments
            app.launch()
            let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-'")).firstMatch
            XCTAssertTrue(card.waitForExistence(timeout: 45), "no Continue Watching card")
            if let played { XCTAssertEqual(card.identifier, played, "another card came first") }
            played = card.identifier
            sleep(4)
            let counts = app.staticTexts["debug-ahead"].firstMatch
            print("REAL \(run.name), ahead before the tap: \(counts.exists ? counts.label : "no readout")")
            card.tap()
            let start = app.staticTexts["debug-start"].firstMatch
            var parts: [Substring] = []
            for _ in 0..<240 where parts.count < 4 {
                usleep(250_000)
                parts = start.exists ? start.label.split(separator: " ") : []
            }
            print("REAL \(run.name), tap to first frame: \(parts.count == 4 ? "\(parts[1]) s (\(parts[0]))" : "no start in 60 s")")
            let split = app.staticTexts["debug-start-parts"].firstMatch
            print("REAL \(run.name), its parts: \(split.exists ? split.label : "none")")
            XCTAssertEqual(parts.count, 4, "the title didn't start")
            sleep(6)
            print("REAL \(run.name), subtitle tap to first line: " + (try timeEnglishSubtitles()))
            shot("subtitles on \(run.name)")
            app.terminate()
        }
    }

    private func timeEnglishSubtitles() throws -> String {
        let timing = app.staticTexts["debug-subs-timing"].firstMatch
        let events = { timing.exists ? timing.label.components(separatedBy: " | ") : [] }
        let before = events().filter { $0.hasPrefix("switch ") }.count
        let menu = app.buttons["Audio and Subtitles"].firstMatch
        let off = app.buttons["Off"].firstMatch
        for _ in 0..<3 where !off.exists {
            if !menu.isHittable {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
                _ = menu.waitForExistence(timeout: 2)
            }
            if menu.isHittable { menu.tap() }
            _ = off.waitForExistence(timeout: 3)
        }
        if !off.exists { shot("no subtitles menu") }
        XCTAssertTrue(off.exists, "no subtitles menu")
        let english = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'English'")).allElementsBoundByIndex
            .first { $0.frame.minY > off.frame.minY }
        try XCTUnwrap(english, "no English subtitles").tap()
        var shown: String?
        for _ in 0..<80 where shown == nil {
            usleep(250_000)
            let switched = events().filter { $0.hasPrefix("switch ") }.dropFirst(before).first
            let n = switched?.split(separator: " ").first { $0.hasPrefix("n=") }
            shown = n.flatMap { n in events().first { $0.hasPrefix("shown ") && $0.split(separator: " ").contains(n) } }
        }
        let after = shown?.split(separator: " ").first { $0.hasPrefix("after=") }.flatMap { Double($0.dropFirst(6)) }
        let switched = events().filter { $0.hasPrefix("switch ") }.dropFirst(before).first ?? "no switch"
        let stall = events().filter { $0.hasPrefix("rebuffer ") }.last ?? "no stall"
        return "\(after.map { String(format: "%.2f s", $0 / 1000) } ?? "no line in 20 s") | \(switched) | \(stall)"
    }

    /// Sports as the viewer sees it now (diagnostic): every game row, then
    /// the first ten live ones tried in turn, playing or not.
    func testSportsAsSeenNow() throws {
        let listOnly = ProcessInfo.processInfo.environment["REAL_FEED_LIST_ONLY"] == "1"
        app.launchArguments += ["-forgetWatchOnPicks", "YES", "-freshLineup", "YES"]
        if listOnly { app.launchArguments += ["-freshGuide", "YES", "-noStreamAhead", "YES"] }
        app.launch()
        let tab = app.tabBars.buttons["Live TV"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "no Live TV tab")
        tab.tap()
        let sports = app.buttons["Sports"].firstMatch
        XCTAssertTrue(sports.waitForExistence(timeout: 90), "the lineup has no Sports")
        sports.tap()
        let games = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Started' OR label CONTAINS 'Not playing' OR label CONTAINS 'LIVE'"))
        _ = games.firstMatch.waitForExistence(timeout: 60)
        sleep(3)
        shot("sports now")
        let labels = games.allElementsBoundByIndex.map(\.label)
        if listOnly {
            say("REAL rows: \(labels.count) live or started")
            say("REAL lineup: \(lineupCounts())")
            return
        }
        say("REAL rows: \(labels.count) live or started, \(labels.filter { $0.contains("channels") }.count) with N channels, \(labels.filter { $0.contains("Not playing") }.count) not playing")
        for label in labels.prefix(40) { say("REAL row: \(label)") }
        for index in 0..<min(games.count, 10) {
            let game = games.element(boundBy: index)
            guard game.isHittable else { continue }
            let label = game.label
            game.tap()
            _ = waitForCopy(timeout: 10)
            let state = waitForState(timeout: 25)
            showControls()
            let offered = app.buttons["Watch On"].firstMatch.waitForExistence(timeout: 2)
            say("REAL tried \(label): \(state), copy \(liveCopy()), \(offered ? "Watch On" : "no Watch On")")
            app.buttons["Close player"].firstMatch.tap()
            sleep(2)
        }
        shot("sports after")
        say("REAL rows after: " + games.allElementsBoundByIndex.prefix(12).map(\.label).joined(separator: " | "))
        // Games named in REAL_FEED_GAMES ("LSU,Boston College"), found by
        // scrolling, then tried.
        for name in (ProcessInfo.processInfo.environment["REAL_FEED_GAMES"] ?? "").split(separator: ",").map(String.init) {
            let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
            for _ in 0..<12 where !(row.exists && row.isHittable) { app.swipeUp() }
            guard row.exists, row.isHittable else { say("REAL \(name): no row"); continue }
            let label = row.label
            row.tap()
            _ = waitForCopy(timeout: 10)
            let state = waitForState(timeout: 25)
            showControls()
            let offered = app.buttons["Watch On"].firstMatch.waitForExistence(timeout: 2)
            say("REAL tried \(label): \(state), copy \(liveCopy()), \(offered ? "Watch On" : "no Watch On")")
            app.buttons["Close player"].firstMatch.tap()
            sleep(2)
        }
    }

    /// Search as the viewer sees it now (diagnostic). Plays nothing and opens
    /// nothing ahead: "the", then "man" (or REAL_FEED_WORDS, "the,man"),
    /// typed; what each section holds;
    /// every filter twice, each followed by the list; three screens down
    /// while the library may still be growing, the row at the top of the
    /// screen watched; back at the top. Prints counts and yes or no only,
    /// no titles or channels.
    func testSearchAsSeenNow() throws {
        app.launchArguments += ["-noStreamAhead", "YES"]
        app.launch()
        let tab = app.tabBars.buttons["Search"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "no Search tab")
        tab.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "no search field")
        let counts = app.staticTexts["debug-search-counts"].firstMatch
        for word in (ProcessInfo.processInfo.environment["REAL_FEED_WORDS"] ?? "the,man").split(separator: ",").map(String.init) {
            field.tap()
            let clear = field.buttons["Clear text"].firstMatch
            if clear.exists { clear.tap() }
            field.typeText(word + "\n")
            let listed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label BEGINSWITH %@", word + "|"), object: counts)
            guard XCTWaiter().wait(for: [listed], timeout: 60) == .completed else {
                say("REAL search \(word): no results in 60 s")
                continue
            }
            sleep(5)
            say("REAL search \(word): \(sections(counts))")

            var chosen = 0, followed = 0
            let taps = ["Movies", "Shows", "Live TV", "All"] + ["Movies", "Shows", "Live TV", "All"]
            for name in taps {
                let filter = app.buttons["scope-\(name)"].firstMatch
                filter.tap()
                sleep(1)
                if filter.isSelected { chosen += 1 }
                if listFollows(name) { followed += 1 }
            }
            say("REAL search \(word) filters: \(taps.count) taps, chosen \(chosen), list followed \(followed); "
                + "the frame-by-frame pill check needs a screen recording, not made on the real feeds")

            var moved = 0, stayed = 0
            for _ in 1...3 {
                let above = topRow()
                drag(from: 0.85, to: 0.2, hold: 0.3, velocity: .slow)
                sleep(1)
                let top = topRow()
                if top != above { moved += 1 }
                sleep(4)
                if top != nil, topRow() == top { stayed += 1 }
            }
            say("REAL search \(word) 3 screens down: the list moved \(moved) of 3, the top row then stayed put "
                + "\(stayed == 3 ? "yes" : "no") (\(stayed) of 3); " + sections(counts))
            for _ in 0..<8 { drag(from: 0.25, to: 0.9) }
            sleep(2)
            say("REAL search \(word) back at the top: \(sections(counts))")
        }
    }

    private func lineupCounts() -> String {
        let readout = app.staticTexts["debug-live-lineup"].firstMatch
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline, !(readout.exists && (readout.label.contains("guide=fresh") || readout.label.contains("guide=failed"))) {
            _ = XCTWaiter.wait(for: [XCTestExpectation(description: "the guide loads")], timeout: 5)
        }
        let pairs = (readout.exists ? readout.label : "").split(separator: " ").map { $0.split(separator: "=", maxSplits: 1).map(String.init) }
        let fields = Dictionary(pairs.filter { $0.count == 2 }.map { ($0[0], $0[1]) }, uniquingKeysWith: { first, _ in first })
        let guide = fields["guide"] ?? "no readout"
        let entries = guide == "fresh" ? fields["entries"] ?? "?" : "0 (guide \(guide))"
        return "channels \(fields["channels"] ?? "?") | guide entries \(entries)"
    }

    private func say(_ line: String) {
        print(line.replacing(#/tok=\w+/#, with: "tok=#"))
    }

    /// The counts readout without the text it's for.
    private func sections(_ counts: XCUIElement) -> String {
        counts.label.split(separator: "|", maxSplits: 1).last.map(String.init) ?? "none"
    }

    /// The list shows what the filter is for: its section, or its "No …".
    private func listFollows(_ filter: String) -> Bool {
        let shown = { (texts: [String]) in texts.contains { self.app.staticTexts[$0].exists } }
        switch filter {
        case "Movies": return shown(["Movies", "No movies"]) && !shown(["Movies & Shows", "Shows"])
        case "Shows": return shown(["Shows", "No shows or episodes"]) && !shown(["Movies & Shows", "Movies"])
        case "Live TV": return shown(["On TV", "Channels", "No channels"]) && !shown(["Movies & Shows", "Movies", "Shows"])
        default: return shown(["Movies & Shows", "On TV", "Channels", "Episodes"]) && !shown(["Movies", "Shows"])
        }
    }

    /// The row at the top of the list on screen, by the words in it and where
    /// it is (never printed).
    private func topRow() -> String? {
        let below = app.otherElements["search-header"].firstMatch.frame.maxY + 2
        guard let root = try? app.snapshot() else { return nil }
        var cells: [XCUIElementSnapshot] = []
        func walk(_ element: XCUIElementSnapshot) {
            if element.elementType == .cell, element.frame.maxY > below { cells.append(element) } else { element.children.forEach(walk) }
        }
        walk(root)
        func words(_ element: XCUIElementSnapshot) -> [String] {
            ([.staticText, .button].contains(element.elementType) ? [element.label] : []) + element.children.flatMap(words)
        }
        guard let top = cells.min(by: { $0.frame.minY < $1.frame.minY }) else { return nil }
        let name = words(top).joined(separator: "|").replacingOccurrences(of: #"(\d+h )?\d+m left|\d+%"#, with: "", options: .regularExpression)
        return "\(name)@\(Int(top.frame.minY.rounded()))"
    }

    private func drag(from: Double, to: Double, hold: TimeInterval = 0, velocity: XCUIGestureVelocity = .default) {
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)),
                   withVelocity: velocity, thenHoldForDuration: hold)
    }

    /// A live game on several channels: it starts on one, Watch On lists
    /// them all, another picked plays, and it plays first the next time.
    func testLiveGameWatchOn() throws {
        app.launchArguments += ["-forgetWatchOnPicks", "YES", "-freshLineup", "YES"]
        app.launch()
        let tab = app.tabBars.buttons["Live TV"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "no Live TV tab")
        tab.tap()
        let sports = app.buttons["Sports"].firstMatch
        XCTAssertTrue(sports.waitForExistence(timeout: 90), "the lineup has no Sports")
        sports.tap()
        let games = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Started'"))
        XCTAssertTrue(games.firstMatch.waitForExistence(timeout: 60), "no game on now")
        shot("sports")

        // The first live game that plays and is shown on more than one
        // channel (a game long started can be over: none of its play).
        let several = games.matching(NSPredicate(format: "label MATCHES %@", "(?s).*\\b\\d+ channels\\b.*"))
        guard several.count > 0 else {
            say("REAL no game on 2+ channels")
            throw XCTSkip("no game on 2+ channels")
        }
        var title: String?
        var started = ""
        for index in 0..<min(several.count, 12) {
            let game = several.element(boundBy: index)
            guard game.isHittable else { continue }
            let label = game.label
            game.tap()
            _ = waitForCopy(timeout: 10)
            let state = waitForState(timeout: 25)
            showControls()
            let offered = app.buttons["Watch On"].firstMatch.waitForExistence(timeout: 2)
            say("REAL tried \(label): \(state), \(offered ? "Watch On" : "one channel")")
            if state == "playing", offered {
                title = label
                started = liveCopy()
                break
            }
            app.buttons["Close player"].firstMatch.tap()
            sleep(1)
        }
        let game = try XCTUnwrap(title, "no live game on 2+ channels played")
        say("REAL game: \(game)")
        say("REAL first channel: \(started)")

        showControls()
        app.buttons["Watch On"].firstMatch.tap()
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'player.card.'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5), "Watch On listed nothing")
        XCTAssertGreaterThanOrEqual(cards.count, 2, "Watch On has one channel")
        for card in cards.allElementsBoundByIndex { say("REAL choice: \(card.label)") }
        shot("watch on")
        // Each feed once (a provider lists one feed in two slots; the user
        // saw "Football · Soccer, OneSoccer Feed" twice).
        let named = cards.allElementsBoundByIndex.map { $0.label.replacingOccurrences(of: "Playing · ", with: "").replacingOccurrences(of: ", Playing", with: "") }
        XCTAssertEqual(Set(named).count, named.count, "a feed listed twice: \(named)")
        // The others in turn until one plays (an event's feed can be over).
        let others = cards.allElementsBoundByIndex.map(\.label).filter { !$0.contains("Playing") }
        var picked: String?
        for label in others {
            showControls()
            if !cards.firstMatch.exists { app.buttons["Watch On"].firstMatch.tap() }
            let card = cards.matching(NSPredicate(format: "label == %@", label)).firstMatch
            guard card.waitForExistence(timeout: 5) else { continue }
            let before = liveCopy()
            card.tap()
            let deadline = Date().addingTimeInterval(10)
            while liveCopy() == before, Date() < deadline { usleep(250_000) }
            XCTAssertTrue(liveCopy() != before, "picking \(label) didn't switch")
            let state = waitForState(timeout: 20)
            say("REAL picked \(label): \(state) (\(liveCopy()))")
            if state == "playing" {
                picked = liveCopy()
                break
            }
        }
        let pick = try XCTUnwrap(picked, "no other channel played")
        shot("picked")
        // Every other one over or failing: the app fell back to the first.
        guard pick != started else {
            say("REAL no other channel played; the app fell back to \(pick)")
            return
        }

        showControls()
        app.buttons["Close player"].firstMatch.tap()
        let again = app.buttons.matching(NSPredicate(format: "label == %@", game)).firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 10), "the game left the list")
        again.tap()
        XCTAssertTrue(waitForCopy(timeout: 10) == pick, "the league's pick didn't play first")
        XCTAssertEqual(waitForState(timeout: 30), "playing", "the pick didn't start the second time")
        shot("pick first")
    }

    /// Dragon Ball Z: two copies on the server (720p with English sound;
    /// 1080p with a Spanish dub first, then Japanese) and no country. It
    /// plays the English copy; the audio menu offers Spanish from the other
    /// one, and Spanish picked takes over with no picture loading.
    func testDragonBallZInEnglish() throws {
        app.launchEnvironment["OPENREEL_DEBUG_IPTV_URL"] = nil
        app.launchArguments += ["-debugSearch", "Dragon Ball Z", "-forgetTrackChoices", "YES"]
        app.launch()
        let tab = app.tabBars.buttons["Search"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "no Search tab")
        tab.tap()
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Dragon Ball Z,' OR label == 'Dragon Ball Z'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30), "no Dragon Ball Z in the results")
        result.tap()
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Resume' OR label BEGINSWITH 'Continue'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 20), "the show's page has no Play")
        play.tap()
        XCTAssertNotNil(waitForPosition(timeout: 45), "the episode didn't open")
        sleep(4)
        let item = app.staticTexts["debug-item"].firstMatch
        let tracks = app.staticTexts["debug-tracks"].firstMatch
        // A real server lists the tracks a few seconds after the picture.
        let listed = Date().addingTimeInterval(20)
        while tracks.label.isEmpty, Date() < listed { usleep(250_000) }
        say("REAL Dragon Ball Z: item \(item.label), \(tracks.label)")
        XCTAssertEqual(item.label, "6327691", "not the copy with English sound")
        XCTAssertTrue(tracks.label.hasPrefix("audio=eng"), "not in English: \(tracks.label)")

        // The controls hide on their own: up again until the menu opens.
        let menu = app.buttons["Audio and Subtitles"].firstMatch
        let spanish = app.buttons["Spanish"].firstMatch
        for _ in 0..<3 where !spanish.exists {
            showControls()
            if menu.waitForExistence(timeout: 2) { menu.tap() }
            _ = spanish.waitForExistence(timeout: 3)
        }
        XCTAssertTrue(spanish.exists, "no Spanish in the menu: \(app.buttons.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }.prefix(25))")
        shot("dragon ball z audio menu")
        spanish.tap()
        let loading = app.descendants(matching: .any)["Loading"]
        var loaded = false
        let deadline = Date().addingTimeInterval(45)
        while item.label == "6327691", Date() < deadline {
            if loading.exists { loaded = true }
            usleep(100_000)
        }
        say("REAL switched to \(item.label), start \(app.staticTexts["debug-start"].firstMatch.label)")
        XCTAssertEqual(item.label, "7085005", "the Spanish copy didn't take over")
        XCTAssertFalse(loaded, "the picture loaded while the audio switched")
        shot("dragon ball z spanish")
    }

    // MARK: Helpers

    private func liveCopy() -> String {
        let readout = app.staticTexts["debug-live-copy"].firstMatch
        return readout.exists ? readout.label : ""
    }

    private func waitForCopy(timeout: TimeInterval) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while liveCopy().isEmpty, Date() < deadline { usleep(250_000) }
        return liveCopy()
    }

    /// "playing", "failed", or "starting" when it hadn't by then.
    private func waitForState(timeout: TimeInterval) -> String {
        let readout = app.staticTexts["debug-live-state"].firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if readout.exists, readout.label != "starting" { return readout.label }
            usleep(500_000)
        }
        return readout.exists ? readout.label : "no player"
    }

    /// The film player's second, from its debug readout ("72.4 playing").
    private func position() -> Double? {
        let readout = app.staticTexts["debug-position"].firstMatch
        guard readout.exists else { return nil }
        return readout.label.split(separator: " ").first.flatMap { Double($0) }
    }

    func testFilmAuthAsSeenNow() throws {
        let film = ProcessInfo.processInfo.environment["REAL_FEED_FILM"] ?? "Asterix and Cleopatra"
        app.launchEnvironment["OPENREEL_DEBUG_IPTV_URL"] = nil
        app.launchEnvironment["OPENREEL_DEBUG_LOWER_AFTER"] = "10"
        app.launchArguments += ["-debugSearch", film, "-debugHLSCounts", "YES"]
        app.launch()
        let tab = app.tabBars.buttons["Search"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "no Search tab")
        tab.tap()
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", film)).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30), "the film isn't in the results")
        result.tap()
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Resume' OR label BEGINSWITH 'Continue'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 20), "the film's page has no Play")
        play.tap()
        XCTAssertNotNil(waitForPosition(timeout: 45), "the film didn't open")
        let quality = app.staticTexts["debug-quality"].firstMatch
        let lowered = Date()
        while Date().timeIntervalSince(lowered) < 60, !(quality.exists && quality.label.hasPrefix("converted")) { sleep(1) }
        let converted = quality.exists && quality.label.hasPrefix("converted")
        sleep(5)
        let from = position() ?? 0
        sleep(10)
        let plays = converted && (position() ?? 0) > from + 5
        let keys = app.staticTexts["debug-hls-keys"].firstMatch
        shot("film auth")
        let counted = keys.exists && keys.label.hasPrefix("master") ? keys.label : "not counted"
        say("REAL auth: converted version plays \(plays ? "yes" : "no") | playlist addresses with the key: \(counted)")
        XCTAssertTrue(converted, "the film wasn't lowered to the converted version")
        XCTAssertTrue(counted.hasPrefix("master"), "the converted version's playlists weren't counted")
    }

    func testFilmBufferingAsSeenNow() throws {
        app.launchEnvironment["OPENREEL_DEBUG_IPTV_URL"] = nil
        let shipped = app.launchArguments + ["-forgetTrackChoices", "YES"]
        let playFor = ProcessInfo.processInfo.environment["FILM_BUFFERING_SECONDS"].flatMap(Double.init) ?? 240
        app.launchArguments = shipped
        app.launch()
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 45), "no Continue Watching")
        let ids = cards.allElementsBoundByIndex.prefix(3).map(\.identifier)
        say("REAL Continue Watching: \(ids.count) cards to start")
        shot("home at launch")
        app.terminate()

        let starts = [("cold", ["-noPrepareAhead", "YES"]), ("ready (old way)", ["-oldReadyStart", "YES"]), ("ready", [])]
        for (n, id) in ids.enumerated() {
            for (name, arguments) in n % 2 == 0 ? starts : starts.reversed() {
                app.launchArguments = shipped + arguments
                app.launch()
                try bringOnScreen(id, at: n)
                if name != "cold" { sleep(3) }
                app.buttons[id].tap()
                say("REAL start card \(n + 1) \(name): " + startParts())
                app.terminate()
            }
        }

        for old in [true, false] {
            try playAndSwitch(ids[0], launch: shipped + (old ? ["-oldRelayCache", "YES"] : []), for: playFor, way: old ? " (old way)" : "")
        }

        app.launchArguments = shipped + ["-debugPlayCopyFilm", "YES"]
        app.launch()
        let found = app.staticTexts["debug-copy-film"].firstMatch
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline, !(found.exists && !found.label.isEmpty) { sleep(1) }
        say("REAL other copy: \(found.exists ? found.label : "not searched")")
        if found.label.hasSuffix("found yes"), waitForPosition(timeout: 45) != nil {
            sleep(5)
            let other = app.buttons.matching(identifier: "audio-other-copy").firstMatch
            if openTrackMenu(), other.exists {
                other.tap()
                let switched = app.staticTexts["debug-copy-switch"].firstMatch
                for _ in 0..<60 where !(switched.exists && !switched.label.isEmpty) { usleep(500_000) }
                say("REAL other copy's language: \(switched.exists && !switched.label.isEmpty ? switched.label : "no switch in 30 s")")
            } else {
                say("REAL other copy's language: not in the menu")
            }
        }
        app.terminate()

        for old in [true, false] { try sayConvertedStart(ids[0], launch: shipped, old: old) }
    }

    private func playAndSwitch(_ id: String, launch arguments: [String], for seconds: Double, way: String) throws {
        app.launchEnvironment["OPENREEL_DEBUG_JUMPS_AFTER"] = String(Int(seconds) + 15)
        app.launchArguments = arguments
        app.launch()
        try bringOnScreen(id, at: 0)
        sleep(3)
        app.buttons[id].tap()
        say("REAL playback\(way) start: " + startParts())
        app.launchEnvironment["OPENREEL_DEBUG_JUMPS_AFTER"] = nil
        let buffering = app.staticTexts["debug-buffering"].firstMatch
        let relay = app.staticTexts["debug-relay"].firstMatch
        let quality = app.staticTexts["debug-quality"].firstMatch
        let began = Date(), fromServer = serverMB()
        while Date().timeIntervalSince(began) < seconds {
            sleep(30)
            say(String(format: "REAL playback\(way) at %.0f s: %@ | %@ | %@", Date().timeIntervalSince(began), buffering.label,
                       quality.label, relay.label))
        }
        let played = Date().timeIntervalSince(began), read = serverMB() - fromServer
        say(String(format: "REAL playback\(way) after %.0f s: %.1f MB from the server, %.2f MB/s on average", played, read, read / played))

        for _ in 0..<90 where field("jumps", in: buffering.label).count < 2 { usleep(500_000) }
        for (jump, name) in zip(field("jumps", in: buffering.label) + ["none", "none"], ["+5 min", "-30 s"]) {
            say("REAL jump\(way) \(name): \(jump) to the next frame (MB from the server)")
        }

        let readsBack = app.staticTexts["debug-reads-back"].firstMatch
        if !openTrackMenu() {
            say("REAL audio\(way), another track in the file: not measured, the menu didn't open")
        } else if let other = app.buttons.matching(identifier: "audio-track").allElementsBoundByIndex.first {
            let back = Int(readsBack.label) ?? 0, rebuffers = count("rebuffers", in: buffering.label)
            other.tap()
            for _ in 0..<40 where !buffering.label.contains("audio:") { usleep(250_000) }
            sleep(3)
            say("REAL audio\(way), another track in the file: \(last("audio", in: buffering.label)) to its sound, "
                + "rebuffers \(count("rebuffers", in: buffering.label) - rebuffers), reads back \((Int(readsBack.label) ?? 0) - back)")
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
            say("REAL audio\(way), another track in the file: none")
        }

        var kinds: [String: String] = [:]
        for entry in 1...6 {
            guard let line = pickSubtitles(entry), !line.hasPrefix("not measured") else { break }
            let kind = line.split(separator: " ").first { $0.hasPrefix("to=") }.map(String.init) ?? "to=?"
            let hidden = line.contains("hidden=yes") ? " hidden" : ""
            if kinds[kind + hidden] == nil { kinds[kind + hidden] = line }
        }
        for (kind, line) in kinds.sorted(by: { $0.key < $1.key }) { say("REAL subtitles\(way) \(kind): \(line)") }
        app.terminate()
    }

    /// Shell: TEST_RUNNER_CONVERTED_RUNS (pairs, 1 unless set) and
    /// TEST_RUNNER_CONVERTED_AT (the film's second). The test sees them
    /// without the TEST_RUNNER_ prefix.
    func testConvertedStartAsSeenNow() throws {
        app.launchEnvironment["OPENREEL_DEBUG_IPTV_URL"] = nil
        app.launchEnvironment["OPENREEL_DEBUG_START_AT"] = ProcessInfo.processInfo.environment["CONVERTED_AT"]
        let shipped = app.launchArguments + ["-forgetTrackChoices", "YES"]
        app.launchArguments = shipped
        app.launch()
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 45), "no Continue Watching")
        let id = card.identifier
        app.terminate()
        let runs = ProcessInfo.processInfo.environment["CONVERTED_RUNS"].flatMap(Int.init) ?? 1
        for _ in 0..<runs {
            for old in [true, false] { try sayConvertedStart(id, launch: shipped, old: old) }
        }
    }

    private func sayConvertedStart(_ id: String, launch arguments: [String], old: Bool) throws {
        app.launchEnvironment["OPENREEL_DEBUG_LOWER_AFTER"] = "10"
        app.launchArguments = arguments + (old ? ["-oldConvertedStart", "YES"] : [])
        app.launch()
        try bringOnScreen(id, at: 0)
        app.buttons[id].tap()
        _ = startParts()
        let buffering = app.staticTexts["debug-buffering"].firstMatch
        for _ in 0..<60 where !buffering.label.contains("converted ") { sleep(1) }
        sleep(3)
        say("REAL converted start\(old ? " (old way)" : ""): \(last("opens", in: buffering.label)) | \(app.staticTexts["debug-quality"].firstMatch.label)")
        app.terminate()
        app.launchEnvironment["OPENREEL_DEBUG_LOWER_AFTER"] = nil
    }

    /// Home draws in parts, so a card still moving is left alone. How much
    /// of a card counts as on screen is the app's own rule (PreparesAhead).
    private func bringOnScreen(_ id: String, at index: Int) throws {
        let card = app.buttons[id]
        XCTAssertTrue(card.waitForExistence(timeout: 45), "no Continue Watching card")
        let screen = app.windows.firstMatch.frame
        let tabBar = app.tabBars.firstMatch
        func visible() -> CGRect {
            let bottom = tabBar.exists ? tabBar.frame.minY : screen.maxY
            return CGRect(x: screen.minX, y: screen.minY + 100, width: screen.width, height: bottom - screen.minY - 100)
        }
        func seen() -> Bool {
            guard card.exists else { return false }
            let frame = card.frame, shown = frame.intersection(visible())
            return !shown.isNull && shown.width * shown.height >= 0.6 * frame.width * frame.height
        }
        func drag(from point: CGPoint, by offset: CGVector) {
            let start = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y))
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(offset), withVelocity: .slow, thenHoldForDuration: 0.3)
        }
        let deadline = Date().addingTimeInterval(30)
        var before = CGRect.null
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-'")).firstMatch
        while Date() < deadline, !seen() {
            let target = card.exists ? card : row
            guard target.exists else { sleep(1); continue }
            let frame = target.frame, area = visible()
            if frame != before {
                before = frame
                sleep(1)
                continue
            }
            if frame.minY < area.minY || frame.maxY > area.maxY {
                drag(from: CGPoint(x: area.midX, y: area.midY), by: CGVector(dx: 0, dy: max(-400, min(400, area.midY - frame.midY))))
            } else {
                let left = !card.exists || frame.midX > area.midX
                drag(from: CGPoint(x: area.midX, y: frame.midY), by: CGVector(dx: left ? -150 : 150, dy: 0))
            }
            before = .null
        }
        if !seen() { shot("card \(index + 1) not on screen") }
        let frame = card.exists ? card.frame : .null, area = visible()
        XCTAssertTrue(seen(), String(format: "card %d didn't come on screen in 30 s (card %.0f-%.0f down, %.0f-%.0f across; screen %.0f-%.0f down)",
                                     index + 1, frame.minY, frame.maxY, frame.minX, frame.maxX, area.minY, area.maxY))
    }

    private func startParts() -> String {
        let start = app.staticTexts["debug-start"].firstMatch
        var parts: [Substring] = []
        for _ in 0..<240 where parts.count < 4 {
            usleep(250_000)
            parts = start.exists ? start.label.split(separator: " ") : []
        }
        guard parts.count == 4 else { return "no start in 60 s" }
        let split = app.staticTexts["debug-start-parts"].firstMatch
        let player = parts[0] == "warm" ? "a kept player" : "a new player"
        return "tap to first frame \(parts[1]) s (\(player)) | \(split.exists ? split.label : "no parts")"
    }

    private func relayMB(_ part: String) -> Double {
        let relay = app.staticTexts["debug-relay"].firstMatch
        guard relay.exists, let range = relay.label.range(of: part + #" ([0-9.]+) MB"#, options: .regularExpression) else { return 0 }
        return Double(relay.label[range].split(separator: " ").dropLast().last ?? "") ?? 0
    }

    private func serverMB() -> Double {
        let relay = app.staticTexts["debug-relay"].firstMatch
        guard relay.exists, let range = relay.label.range(of: #"from the server \d+ reads ([0-9.]+) MB"#, options: .regularExpression)
        else { return 0 }
        return Double(relay.label[range].split(separator: " ").dropLast().last ?? "") ?? 0
    }

    private func count(_ part: String, in readout: String) -> Int {
        let field = readout.components(separatedBy: " | ").first { $0.hasPrefix(part) } ?? ""
        return Int(field.split(separator: " ").dropFirst().first?.trimmingCharacters(in: [":", ","]) ?? "") ?? 0
    }

    private func field(_ part: String, in readout: String) -> [String] {
        guard let field = readout.components(separatedBy: " | ").first(where: { $0.hasPrefix(part + ":") }) else { return [] }
        return field.dropFirst(part.count + 2).components(separatedBy: ", ")
    }

    private func last(_ part: String, in readout: String) -> String {
        let field = readout.components(separatedBy: " | ").first { $0.hasPrefix(part) } ?? ""
        if part == "opens" { return field.components(separatedBy: ", ").last ?? "none" }
        return field.split(separator: " ").dropLast().last.map { "\($0) ms" } ?? "none"
    }

    /// Tapped where it is. The controls are brought up again when they hid.
    private func openTrackMenu() -> Bool {
        let menu = app.buttons["Audio and Subtitles"].firstMatch
        let off = app.buttons["Off"].firstMatch
        for _ in 0..<4 where !off.exists {
            if !(menu.exists && menu.isHittable) {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
                _ = menu.waitForExistence(timeout: 2)
            }
            if menu.exists, menu.isHittable {
                let frame = menu.frame
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
            }
            _ = off.waitForExistence(timeout: 3)
        }
        return off.exists
    }

    /// The menu is read from one snapshot and tapped where its entry was:
    /// it's built again when a track arrives.
    private func pickSubtitles(_ entry: Int) -> String? {
        let timing = app.staticTexts["debug-subs-timing"].firstMatch
        let events = { timing.exists ? timing.label.components(separatedBy: " | ") : [] }
        let before = events().filter { $0.hasPrefix("switch ") }.count
        guard openTrackMenu() else { return "not measured, the menu didn't open" }
        var buttons: [XCUIElementSnapshot] = []
        func collect(_ element: XCUIElementSnapshot) {
            if element.elementType == .button { buttons.append(element) }
            element.children.forEach(collect)
        }
        if let screen = try? app.snapshot() { collect(screen) }
        guard let off = buttons.first(where: { $0.label == "Off" || $0.identifier == "Off" })?.frame else { return nil }
        let below = buttons.filter { $0.frame.minY > off.minY && abs($0.frame.minX - off.minX) < 1 && abs($0.frame.width - off.width) < 1 }
            .map(\.frame).sorted { $0.minY < $1.minY }
        guard entry <= below.count else {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
            return nil
        }
        let place = below[entry - 1]
        let readsBack = app.staticTexts["debug-reads-back"].firstMatch
        let (device, server, back) = (relayMB("from the device"), serverMB(), Int(readsBack.label) ?? 0)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: place.midX, dy: place.midY)).tap()
        var switched: String?, shown: String?
        for _ in 0..<80 where shown == nil {
            usleep(250_000)
            switched = events().filter { $0.hasPrefix("switch ") }.dropFirst(before).first
            let n = switched?.split(separator: " ").first { $0.hasPrefix("n=") }
            shown = n.flatMap { n in events().first { $0.hasPrefix("shown ") && $0.split(separator: " ").contains(n) } }
        }
        sleep(2)
        let n = switched?.split(separator: " ").first { $0.hasPrefix("n=") }
        let stalls = events().filter { $0.hasPrefix("rebuffer ") && n.map($0.split(separator: " ").contains) == true }
        let after = shown?.split(separator: " ").first { $0.hasPrefix("after=") }.map(String.init) ?? "no line in 20 s"
        let read = String(format: "read %.1f MB from the device, %.1f MB from the server, %d reads back", relayMB("from the device") - device,
                          serverMB() - server, (Int(readsBack.label) ?? 0) - back)
        return ([switched ?? "no switch", after] + (stalls.isEmpty ? ["no stall"] : stalls) + [read]).joined(separator: " ; ")
    }

    private func openedAt(timeout: TimeInterval) -> Double? {
        let readout = app.staticTexts["debug-start"].firstMatch
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if readout.exists, let at = readout.label.components(separatedBy: " at ").last.flatMap(Double.init) { return at }
            usleep(500_000)
        }
        return nil
    }

    private func waitForPosition(timeout: TimeInterval) -> Double? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let seconds = position(), seconds > 0 { return seconds }
            usleep(500_000)
        }
        return nil
    }

    private func showControls() {
        guard !app.buttons["Close player"].firstMatch.exists else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        _ = app.buttons["Close player"].firstMatch.waitForExistence(timeout: 3)
    }

    private func shot(_ note: String) {
        step += 1
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let test = name.split(separator: " ").last.map { String($0.dropLast()) } ?? "test"
        let file = "\(test)-" + String(format: "%02d", step) + "-\(note.replacingOccurrences(of: " ", with: "-")).png"
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: file))
    }
}

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
        print("REAL tracks: \(tracks.exists ? tracks.label : "none") | shift \(shift.exists ? shift.label : "none") after \(Int(Date().timeIntervalSince(opened))) s")
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
        print("REAL as played before: \(shift.exists ? shift.label : "none")")
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
        print("REAL lowered: opened at \(opened) s, now the film at \(film) s, the stream's clock at \(stream) s")
        XCTAssertGreaterThan(stream, opened + 20, "the converted version plays from the film's start")
        XCTAssertEqual(stream, film, accuracy: 3, "the stream and the film's place differ")
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
        print("REAL found subtitles: \(tracks.exists ? tracks.label : "none") after \(Int(Date().timeIntervalSince(opened))) s")
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
        print("REAL playing: \(card.label)")
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
        print("REAL title started \(String(format: "%.1f", start)) s after the player opened")
        let at = position() ?? 0
        sleep(6)
        let later = position() ?? 0
        shot("playing")
        XCTAssertGreaterThan(later, at + 3, "the title doesn't play on (\(at) → \(later))")
    }

    /// Sports as the viewer sees it now (diagnostic): every game row, then
    /// the first ten live ones tried in turn, playing or not.
    func testSportsAsSeenNow() throws {
        app.launchArguments += ["-forgetWatchOnPicks", "YES", "-freshLineup", "YES"]
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
        print("REAL rows: \(labels.count) live or started, \(labels.filter { $0.contains("channels") }.count) with N channels, \(labels.filter { $0.contains("Not playing") }.count) not playing")
        for label in labels.prefix(40) { print("REAL row: \(label)") }
        for index in 0..<min(games.count, 10) {
            let game = games.element(boundBy: index)
            guard game.isHittable else { continue }
            let label = game.label
            game.tap()
            _ = waitForCopy(timeout: 10)
            let state = waitForState(timeout: 25)
            showControls()
            let offered = app.buttons["Watch On"].firstMatch.waitForExistence(timeout: 2)
            print("REAL tried \(label): \(state), copy \(liveCopy()), \(offered ? "Watch On" : "no Watch On")")
            app.buttons["Close player"].firstMatch.tap()
            sleep(2)
        }
        shot("sports after")
        print("REAL rows after: " + games.allElementsBoundByIndex.prefix(12).map(\.label).joined(separator: " | "))
        // Games named in REAL_FEED_GAMES ("LSU,Boston College"), found by
        // scrolling, then tried.
        for name in (ProcessInfo.processInfo.environment["REAL_FEED_GAMES"] ?? "").split(separator: ",").map(String.init) {
            let row = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch
            for _ in 0..<12 where !(row.exists && row.isHittable) { app.swipeUp() }
            guard row.exists, row.isHittable else { print("REAL \(name): no row"); continue }
            let label = row.label
            row.tap()
            _ = waitForCopy(timeout: 10)
            let state = waitForState(timeout: 25)
            showControls()
            let offered = app.buttons["Watch On"].firstMatch.waitForExistence(timeout: 2)
            print("REAL tried \(label): \(state), copy \(liveCopy()), \(offered ? "Watch On" : "no Watch On")")
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
                print("REAL search \(word): no results in 60 s")
                continue
            }
            sleep(5)
            print("REAL search \(word): \(sections(counts))")

            var chosen = 0, followed = 0
            let taps = ["Movies", "Shows", "Live TV", "All"] + ["Movies", "Shows", "Live TV", "All"]
            for name in taps {
                let filter = app.buttons["scope-\(name)"].firstMatch
                filter.tap()
                sleep(1)
                if filter.isSelected { chosen += 1 }
                if listFollows(name) { followed += 1 }
            }
            print("REAL search \(word) filters: \(taps.count) taps, chosen \(chosen), list followed \(followed); "
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
            print("REAL search \(word) 3 screens down: the list moved \(moved) of 3, the top row then stayed put "
                + "\(stayed == 3 ? "yes" : "no") (\(stayed) of 3); " + sections(counts))
            for _ in 0..<8 { drag(from: 0.25, to: 0.9) }
            sleep(2)
            print("REAL search \(word) back at the top: \(sections(counts))")
        }
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
        var title: String?
        var started = ""
        for index in 0..<min(games.count, 12) {
            let game = games.element(boundBy: index)
            guard game.isHittable else { continue }
            let label = game.label
            game.tap()
            _ = waitForCopy(timeout: 10)
            let state = waitForState(timeout: 25)
            showControls()
            let offered = app.buttons["Watch On"].firstMatch.waitForExistence(timeout: 2)
            print("REAL tried \(label): \(state), \(offered ? "Watch On" : "one channel")")
            if state == "playing", offered {
                title = label
                started = liveCopy()
                break
            }
            app.buttons["Close player"].firstMatch.tap()
            sleep(1)
        }
        let game = try XCTUnwrap(title, "no live game that plays on more than one channel")
        print("REAL game: \(game)")
        print("REAL first channel: \(started)")

        showControls()
        app.buttons["Watch On"].firstMatch.tap()
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'player.card.'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5), "Watch On listed nothing")
        XCTAssertGreaterThanOrEqual(cards.count, 2, "Watch On has one channel")
        for card in cards.allElementsBoundByIndex { print("REAL choice: \(card.label)") }
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
            XCTAssertNotEqual(liveCopy(), before, "picking \(label) didn't switch")
            let state = waitForState(timeout: 20)
            print("REAL picked \(label): \(state) (\(liveCopy()))")
            if state == "playing" {
                picked = liveCopy()
                break
            }
        }
        let pick = try XCTUnwrap(picked, "no other channel played")
        shot("picked")
        // Every other one over or failing: the app fell back to the first.
        guard pick != started else {
            print("REAL no other channel played; the app fell back to \(pick)")
            return
        }

        showControls()
        app.buttons["Close player"].firstMatch.tap()
        let again = app.buttons.matching(NSPredicate(format: "label == %@", game)).firstMatch
        XCTAssertTrue(again.waitForExistence(timeout: 10), "the game left the list")
        again.tap()
        XCTAssertEqual(waitForCopy(timeout: 10), pick, "the league's pick didn't play first")
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
        print("REAL Dragon Ball Z: item \(item.label), \(tracks.label)")
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
        print("REAL switched to \(item.label), start \(app.staticTexts["debug-start"].firstMatch.label)")
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

    /// How the server takes the Emby key in a header alone, as counts and
    /// words only (never an address or the key): (a) a film lowered to the
    /// converted version plays; (b) how many addresses in that version's
    /// playlists carry the key; (c) for each way of sending the key to the
    /// websocket (X-Emby-Token, X-Emby-Authorization, Authorization, the key
    /// in the query), whether it is refused, opens but misses a watched
    /// change made meanwhile (a film neither watched nor started, marked
    /// watched, then not), or hears it. The film: TEST_RUNNER_REAL_FEED_FILM,
    /// else Asterix and Cleopatra.
    func testFilmAuthAsSeenNow() throws {
        let film = ProcessInfo.processInfo.environment["REAL_FEED_FILM"] ?? "Asterix and Cleopatra"
        app.launchEnvironment["OPENREEL_DEBUG_IPTV_URL"] = nil
        app.launchEnvironment["OPENREEL_DEBUG_LOWER_AFTER"] = "10"
        app.launchArguments += ["-debugSearch", film, "-debugHLSCounts", "YES", "-debugWebsocketProbe", "YES"]
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
        let probe = app.staticTexts["debug-websocket"].firstMatch
        let probed = Date()
        func ended() -> Bool { probe.exists && (probe.label.hasPrefix("done") || probe.label == "skipped") }
        while Date().timeIntervalSince(probed) < 150, !ended() { sleep(2) }
        shot("film auth")
        let counted = keys.exists && keys.label.hasPrefix("master") ? keys.label : "not counted"
        let sockets = probe.exists ? probe.label.replacingOccurrences(of: "done ", with: "") : "no readout"
        print("REAL auth: converted version plays \(plays ? "yes" : "no") | playlist addresses with the key: \(counted) | websocket: \(sockets)")
        XCTAssertTrue(converted, "the film wasn't lowered to the converted version")
        XCTAssertTrue(counted.hasPrefix("master"), "the converted version's playlists weren't counted")
        XCTAssertTrue(ended(), "the websocket check didn't end")
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

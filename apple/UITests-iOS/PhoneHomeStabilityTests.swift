import XCTest

final class PhoneHomeStabilityTests: XCTestCase {
    private let app = XCUIApplication()
    private let shots = URL(fileURLWithPath: "/tmp/openiptv/uitest-agent")
    private var step = 0

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        if let account = ProcessInfo.processInfo.environment["DEBUG_EMBY"] {
            app.launchEnvironment["OPENREEL_DEBUG_EMBY"] = account
        }
        app.launchEnvironment["OPENREEL_DEBUG_HOME_VARY"] = "1"
        XCUIDevice.shared.orientation = .portrait
    }

    func testHomeStaysPutUntilChosenAgain() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        app.launch()
        // Past the first seconds after a launch, when a build may still go
        // straight on the page.
        sleep(10)
        // Down to the rows, so they're all on screen together.
        drag(from: 0.75, to: 0.35)
        sleep(2)
        XCUIDevice.shared.press(.home)
        configure(server, ["resume_episode": "4", "added": "z9"])
        sleep(3)
        app.activate()
        sleep(8)
        let before = rows()
        shot("home before")
        let numbers = rowNumbers(before)
        XCTAssertFalse(numbers.isEmpty, "no numbered rows on Home: \(before.keys.sorted())")
        sleep(18)
        let after = rows()
        shot("home after changes")
        let moved = differences(before, after)
        XCTAssertEqual(moved, [], "Home changed while on screen:\n" + moved.joined(separator: "\n"))

        // Scrolling isn't a moment either (the user: "scrolling shouldn't
        // change the recommendation list"): down the page and back, the
        // same Home.
        drag(from: 0.8, to: 0.3)
        sleep(2)
        let further = rowNumbers(rows())
        XCTAssertFalse(further.isEmpty, "no numbered rows further down")
        XCTAssertEqual(further, numbers, "scrolling down put the Home built meanwhile on the page")
        drag(from: 0.3, to: 0.8)
        sleep(1)
        drag(from: 0.75, to: 0.35)
        sleep(2)
        let back = rowNumbers(rows())
        XCTAssertFalse(back.isEmpty, "no numbered rows after scrolling back")
        XCTAssertEqual(back, numbers, "scrolling back put the Home built meanwhile on the page")

        // Home chosen again in the tab bar (back at the top, where it's
        // full size): the Home built meanwhile goes on.
        for _ in 0..<3 { drag(from: 0.3, to: 0.8) }
        sleep(1)
        // Still small after the scroll: a tap on it opens it out.
        if !app.tabBars.buttons["Live TV"].exists {
            app.tabBars.buttons.firstMatch.tap()
            sleep(1)
        }
        shot("tab bar")
        app.tabBars.buttons["Live TV"].firstMatch.tap()
        sleep(2)
        app.tabBars.buttons["Home"].firstMatch.tap()
        sleep(2)
        let again = rowNumbers(rows())
        shot("home chosen again")
        XCTAssertNotEqual(again, numbers, "the Home built meanwhile didn't go on when Home was chosen again")
        let nextEpisode = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Case 4'")).firstMatch
        XCTAssertTrue(nextEpisode.exists, "the show's next episode didn't go on when Home was chosen again: \(app.buttons.allElementsBoundByIndex.map(\.label).filter { $0.contains("Case") })")

        // Back to the top, then pulled down: nothing changes (no pull to
        // refresh, as in the Apple TV app and Netflix). Regression: a pull,
        // by mistake too, put a new Home with other rows on the page.
        drag(from: 0.75, to: 0.35)
        sleep(2)
        let shown = rowNumbers(rows())
        XCTAssertFalse(shown.isEmpty, "no numbered rows after Home was chosen again")
        for _ in 0..<4 { drag(from: 0.3, to: 0.8) }
        drag(from: 0.3, to: 0.9, hold: 1)
        sleep(8)
        drag(from: 0.75, to: 0.35)
        sleep(2)
        shot("home after pull")
        XCTAssertEqual(rowNumbers(rows()), shown, "pulling down changed Home")
    }

    /// A launch is a moment Home may change: the first Home built goes on
    /// the page, however long the server takes, if it hasn't been touched.
    /// Regression: a build taking more than five seconds waited, unseen,
    /// until another tab was chosen.
    func testSlowFirstBuildStillShows() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        app.launch()
        sleep(10)
        app.terminate()
        // Saved Home old (every row built again), and the server slow.
        configure(server, ["home_delay": "9"])
        defer { configure(server, ["reset": "1"]) }
        app.launchEnvironment["OPENREEL_DEBUG_HOME_STALE"] = "1"
        app.launch()
        sleep(2)
        let saved = pageNumbers()
        shot("slow launch saved")
        XCTAssertFalse(saved.isEmpty, "no numbered rows on the saved Home")
        sleep(20)
        let later = pageNumbers()
        shot("slow launch built")
        XCTAssertFalse(later.isEmpty, "no numbered rows after the build")
        XCTAssertNotEqual(later, saved, "the slow first build never went on the page")
    }

    /// Coming back after a long time away is a moment Home may change (the
    /// Home built meanwhile goes on); a short trip away isn't. Here "long"
    /// is 8 seconds (OPENREEL_DEBUG_LONG_AWAY).
    func testHomeChangesOnlyAfterLongAway() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        app.launchEnvironment["OPENREEL_DEBUG_LONG_AWAY"] = "8"
        app.launch()
        sleep(10)
        let before = pageNumbers()
        XCTAssertFalse(before.isEmpty, "no numbered rows on Home")
        XCUIDevice.shared.press(.home)
        configure(server, ["added": "z9"])
        sleep(2)
        app.activate()
        sleep(10)
        XCTAssertEqual(pageNumbers(), before, "Home changed after a short time away")
        // A long time away: the Home built meanwhile goes on.
        XCUIDevice.shared.press(.home)
        sleep(10)
        app.activate()
        sleep(4)
        shot("back after long away")
        XCTAssertNotEqual(pageNumbers(), before, "Home didn't change after a long time away")
    }

    /// Signed out while Home is being built: the old account's Home doesn't
    /// come back when the build ends. Regression: it did (rows and pictures
    /// of the account just signed out of).
    func testSignOutWhileHomeLoads() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["home_delay": "10"])
        defer { configure(server, ["reset": "1"]) }
        app.launchEnvironment["OPENREEL_DEBUG_HOME_STALE"] = "1"
        app.launch()
        sleep(2)
        app.buttons["Settings"].firstMatch.tap()
        let emby = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Emby'")).firstMatch
        XCTAssertTrue(emby.waitForExistence(timeout: 3), "no Emby in Settings")
        emby.tap()
        let signOut = app.buttons["Sign out"].firstMatch
        XCTAssertTrue(signOut.waitForExistence(timeout: 3), "no Sign out")
        signOut.tap()
        sleep(1)
        // Back to Settings' first page, then closed.
        let back = app.navigationBars.buttons["Settings"].firstMatch
        if back.exists { back.tap(); sleep(1) }
        let done = app.buttons["Done"].firstMatch
        if done.waitForExistence(timeout: 2) { done.tap() } else { app.swipeDown(velocity: .fast) }
        sleep(1)
        shot("signed out")
        XCTAssertFalse(app.staticTexts["Continue Watching"].exists, "Home kept the old account's rows")
        // The build for the old account ends meanwhile.
        sleep(16)
        shot("signed out later")
        XCTAssertFalse(app.staticTexts["Continue Watching"].exists, "the old account's Home came back after signing out")
        XCTAssertTrue(pageNumbers().isEmpty, "the old account's rows came back after signing out")
    }

    /// Home's cards as in the Apple TV app: Continue Watching 240 × 170
    /// (the title and progress inside it), posters 100 × 150, 12 apart.
    /// A row's name with "›" opens the whole row, as in the Apple TV app
    /// (measured at 3x from it): the name, 12 points under it three posters
    /// across, 12 apart and 20 from the edges, lines 18 apart. A poster
    /// opens its title. Regression: row names opened nothing.
    func testRowNameOpensWholeRow() throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "iPhone's three across")
        // A test before may have left titles on My List (then its row,
        // with three, came first).
        if let server = testServer() { configure(server, ["reset": "1"]) }
        app.launch()
        sleep(8)
        drag(from: 0.75, to: 0.35)
        sleep(1)
        let name = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'row-'")).firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 3), "no row name that opens its row")
        let title = name.label
        name.tap()
        sleep(2)
        shot("whole row")
        let screen = app.frame
        let width = (screen.width - 40 - 24) / 3
        let posters = app.buttons.allElementsBoundByIndex
            .filter { abs($0.frame.width - width) < 1 && abs($0.frame.height - width * 1.5) < 1 }
            .sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
        XCTAssertGreaterThanOrEqual(posters.count, 4, "not three \(width)-wide posters across: \(posters.map(\.frame))")
        guard posters.count >= 4 else { return }
        XCTAssertEqual(posters[0].frame.minX, 20, accuracy: 1, "the first poster isn't 20 from the edge")
        XCTAssertEqual(posters[1].frame.minX - posters[0].frame.maxX, 12, accuracy: 1, "posters aren't 12 apart")
        XCTAssertEqual(posters[3].frame.minY - posters[0].frame.maxY, 18, accuracy: 1, "lines aren't 18 apart")
        let heading = app.staticTexts[title].firstMatch
        XCTAssertTrue(heading.exists, "no \"\(title)\" over the row")
        XCTAssertEqual(posters[0].frame.minY - heading.frame.maxY, 12, accuracy: 2, "the posters aren't 12 under the name")
        posters[0].tap()
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Resume' OR label BEGINSWITH 'Continue'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 8), "the poster didn't open its title")
    }

    /// The chosen tab (iPhone: in the bar at the bottom; iPad: at the top)
    /// is white, as every other highlight in the app, not the system's
    /// blue (the user: "a weird blue tint when a nav is selected"). On Live
    /// TV, whose page is dark behind the bar, the tab's bright pixels are
    /// grey to white, not blue.
    func testChosenTabIsWhite() {
        app.launch()
        sleep(5)
        let bar = app.tabBars.buttons["Live TV"].firstMatch
        let live = bar.exists ? bar : app.buttons["Live TV"].firstMatch
        XCTAssertTrue(live.waitForExistence(timeout: 5), "no Live TV tab")
        live.tap()
        sleep(2)
        shot("live tv tab chosen")
        let frame = live.frame
        let shot = XCUIScreen.main.screenshot().image
        guard let image = shot.cgImage, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            return XCTFail("no screenshot")
        }
        let scale = CGFloat(image.width) / shot.size.width
        let perPixel = image.bitsPerPixel / 8
        var bright = 0, coloured = 0
        for y in stride(from: Int(frame.minY * scale), to: Int(frame.maxY * scale), by: 2) {
            for x in stride(from: Int(frame.minX * scale), to: Int(frame.maxX * scale), by: 2)
            where x >= 0 && y >= 0 && x < image.width && y < image.height {
                let i = y * image.bytesPerRow + x * perPixel
                let channels = [Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2])]
                guard channels.max()! > 180 else { continue }
                bright += 1
                // The system's blue: one channel high, another near nothing.
                if channels.max()! - channels.min()! > 90 { coloured += 1 }
            }
        }
        XCTAssertGreaterThan(bright, 20, "nothing bright in the chosen tab (\(frame))")
        XCTAssertLessThan(Double(coloured), Double(bright) * 0.1, "the chosen tab is coloured, not white: \(coloured) of \(bright) bright pixels")
    }

    /// Watched on another device (the Apple TV) while the app was in the
    /// background: back in the app, it's in Continue Watching. Regression:
    /// it waited for the next "moment" (a tab, a pull, half an hour away),
    /// as recommendations do, and looked like it hadn't synced.
    func testWatchedElsewhereShowsOnReturn() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        app.launch()
        sleep(8)
        let elsewhere = app.buttons["continue-m7"].firstMatch
        XCTAssertFalse(elsewhere.exists, "Movie 7 was in Continue Watching from the start")
        XCUIDevice.shared.press(.home)
        configure(server, ["watched_elsewhere": "m7"])
        sleep(3)
        app.activate()
        XCTAssertTrue(elsewhere.waitForExistence(timeout: 8), "what was watched elsewhere isn't in Continue Watching")
        shot("continue watching after return")
    }

    func testFilmAddedElsewhereShowsAfterReturn() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        app.launch()
        sleep(12)
        XCUIDevice.shared.press(.home)
        configure(server, ["added": "z9"])
        sleep(3)
        app.activate()
        sleep(6)
        app.tabBars.buttons["Search"].firstMatch.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5), "no search field")
        field.tap()
        field.typeText("Zorro Returns")
        let found = app.buttons["More for Zorro Returns"].firstMatch
        let shown = found.waitForExistence(timeout: 10)
        shot("search after return")
        XCTAssertTrue(shown, "the film added elsewhere isn't found")
    }

    /// Put on My List on another device while the app was in the
    /// background: back in the app, it's on My List. Regression: My List
    /// was read only when Home first opened.
    func testMyListFromElsewhereShowsOnReturn() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        app.launch()
        sleep(8)
        XCTAssertFalse(app.buttons["row-My List"].exists, "My List wasn't empty at the start")
        XCUIDevice.shared.press(.home)
        favorite(server, "a4")
        sleep(3)
        app.activate()
        XCTAssertTrue(app.buttons["row-My List"].firstMatch.waitForExistence(timeout: 8), "what was put on My List elsewhere isn't there")
    }

    /// Put on My List on another device while Home was open: there when
    /// Home is chosen again in the tab bar (the moment that replaced pull to
    /// refresh).
    func testMyListFromElsewhereShowsWhenHomeIsChosenAgain() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        app.launch()
        sleep(8)
        XCTAssertFalse(app.buttons["row-My List"].exists, "My List wasn't empty at the start")
        favorite(server, "a4")
        app.tabBars.buttons["Live TV"].firstMatch.tap()
        sleep(2)
        app.tabBars.buttons["Home"].firstMatch.tap()
        XCTAssertTrue(app.buttons["row-My List"].firstMatch.waitForExistence(timeout: 10), "what was put on My List elsewhere isn't there")
    }

    /// Put on My List on another device: first on the row here, as on
    /// Netflix, though the server lists My List by name. Regression: Dragon
    /// Ball Z, put on it on the Apple TV, sat eleventh, out of sight.
    func testMyListFromElsewhereComesFirst() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        favorite(server, "a2")
        app.launchArguments += ["-forgetMyListOrder", "YES"]
        app.launch()
        sleep(8)
        XCUIDevice.shared.press(.home)
        favorite(server, "a11")
        sleep(3)
        app.activate()
        let cards = myListCards()
        shot("my list after another device")
        XCTAssertEqual(cards.first?.hasPrefix("Weapons"), true, "not first: \(cards)")
        // Dated in the app's record on the server, for the other devices.
        XCTAssertNotNil(myListRecord(server)["a11"], "not in the record on the server: \(myListRecord(server))")
    }

    /// When each title was put on My List travels with it: every device
    /// keeps the dates in the app's own record on the server, so titles
    /// added on the Apple TV come first on the iPhone, newest first, even on
    /// an iPhone that never saw the list before. Regression: each device
    /// knew only its own dates, and the server lists My List by name.
    func testMyListOrderSharedAcrossDevices() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        for id in ["a2", "a5", "a11"] { favorite(server, id) }
        // Another device's record: Weapons newest, then American Animals,
        // Animal House first.
        saveMyListRecord(server, ["a11": "1792090000", "a5": "1792080000", "a2": "1792070000"])
        app.launchArguments += ["-forgetMyListOrder", "YES"]
        app.launch()
        sleep(8)
        let cards = myListCards()
        shot("my list in the other device's order")
        XCTAssertEqual(cards.prefix(3).map { $0.components(separatedBy: ",")[0] }, ["Weapons", "American Animals", "Animal House"], "\(cards)")
    }

    /// Titles stamped all in one second, later than one put on My List by
    /// itself, don't come before it: a device that took a whole list as
    /// just added stamped them, not the viewer. And the stamps leave the
    /// record. Regression: 46 of the user's 52 titles, stamped together by
    /// a device that had only seen the test server's list, came first, by
    /// name, before what they had just put on it.
    func testMassStampedTitlesDontComeFirst() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        for id in ["a2", "a3", "a5", "a9", "a11"] { favorite(server, id) }
        saveMyListRecord(server, ["a11": "1792090000", "a2": "1792095000", "a3": "1792095000", "a5": "1792095000", "a9": "1792095000"])
        app.launchArguments += ["-forgetMyListOrder", "YES"]
        app.launch()
        sleep(8)
        let cards = myListCards()
        shot("my list with a mass stamp")
        XCTAssertEqual(cards.first?.hasPrefix("Weapons"), true, "the mass-stamped titles came first: \(cards)")
        let record = myListRecord(server)
        XCTAssertNil(record["a2"], "the mass stamp is still in the record: \(record)")
        XCTAssertEqual(record["a11"], "1792090000", "the real date left the record: \(record)")
    }

    /// My List's cards, left to right (labels), read in one snapshot (read
    /// one by one, a card could go between listing and reading it).
    private func myListCards() -> [String] {
        let heading = app.buttons["row-My List"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 8), "no My List row")
        sleep(3)
        for _ in 0..<4 where !heading.isHittable { app.swipeUp(); sleep(1) }
        guard let root = try? app.snapshot() else { return [] }
        var buttons: [(frame: CGRect, label: String, id: String)] = []
        func walk(_ node: XCUIElementSnapshot) {
            if node.elementType == .button { buttons.append((node.frame, node.label, node.identifier)) }
            node.children.forEach(walk)
        }
        walk(root)
        guard let top = buttons.first(where: { $0.id == "row-My List" })?.frame.maxY else { return [] }
        return buttons
            .filter { $0.frame.minY > top && $0.frame.minY < top + 40 && !$0.id.hasPrefix("row-") }
            .sorted { $0.frame.minX < $1.frame.minX }
            .map(\.label)
    }

    /// The app's record on the test server: when each title was put on My List.
    private func myListRecord(_ server: URL) -> [String: String] {
        var record: [String: String] = [:]
        let url = server.appending(path: "emby/DisplayPreferences/zapline-mylist").appending(queryItems: [.init(name: "client", value: "zapline")])
        var request = URLRequest(url: url)
        request.setValue("tok", forHTTPHeaderField: "X-Emby-Token")
        let done = expectation(description: "record")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            record = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })?["CustomPrefs"] as? [String: String] ?? [:]
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return record
    }

    /// Writes that record as another device would.
    private func saveMyListRecord(_ server: URL, _ record: [String: String]) {
        let url = server.appending(path: "emby/DisplayPreferences/zapline-mylist").appending(queryItems: [.init(name: "client", value: "zapline")])
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("tok", forHTTPHeaderField: "X-Emby-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["Id": "zapline-mylist", "CustomPrefs": record])
        let done = expectation(description: "save record")
        URLSession.shared.dataTask(with: request) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
    }

    /// Settings shows the build beside the version, as TestFlight lists
    /// it ("0.2.0 (202610151425)"). Regression: every upload read "0.2.0",
    /// and the user couldn't tell which was the latest.
    func testSettingsShowsTheBuild() {
        app.launch()
        sleep(3)
        app.buttons["Settings"].firstMatch.tap()
        let about = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'About'")).firstMatch
        XCTAssertTrue(about.waitForExistence(timeout: 3), "no About in Settings")
        shot("settings about")
        XCTAssertNotNil(about.label.range(of: #"\d+\.\d+\.\d+ \(\d+\)"#, options: .regularExpression), "no build beside the version: \(about.label)")
    }

    /// Puts a title on the test user's My List on the server (as another
    /// device would).
    private func favorite(_ server: URL, _ id: String) {
        var request = URLRequest(url: server.appending(path: "emby/Users/U1/FavoriteItems/\(id)"))
        request.httpMethod = "POST"
        request.setValue("tok", forHTTPHeaderField: "X-Emby-Token")
        let done = expectation(description: "favorite \(id)")
        URLSession.shared.dataTask(with: request) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
    }

    func testHomeCardSizes() {
        app.launch()
        sleep(8)
        let heading = app.staticTexts["Continue Watching"].firstMatch
        XCTAssertTrue(heading.exists, "no Continue Watching")
        let first = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-'")).firstMatch
        let card: XCUIElement? = first.waitForExistence(timeout: 3) ? first : nil
        XCTAssertNotNil(card, "no Continue Watching card")
        if let card {
            XCTAssertEqual(card.frame.size.width, 240, accuracy: 1, "Continue Watching card: \(card.frame)")
            XCTAssertEqual(card.frame.size.height, 170, accuracy: 1, "Continue Watching card: \(card.frame)")
            // Episodes written as in the Apple TV app ("S2, E3").
            let show = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-' AND label CONTAINS 'Case 3'")).firstMatch
            XCTAssertTrue(show.label.contains("S2, E3"), "not \"S2, E3\": \(show.label)")
            // The card starts 12 points under the row's name.
            let top = heading.frame.maxY + 12
            let words = card.staticTexts.allElementsBoundByIndex.map(\.frame)
            XCTAssertFalse(words.isEmpty, "no title or episode on the card")
            for frame in words {
                XCTAssertGreaterThan(frame.minY, top + 110, "the card's words aren't along its bottom: \(frame)")
                XCTAssertLessThan(frame.maxY, top + 170, "the card's words are below the card: \(frame)")
            }
        }
        // The hero's buttons as in the Apple TV app: Play 160 × 48, then a
        // 48-point round button.
        // (Measured on the screen: a button's frame here is its words'.)
        let label = app.buttons["Play"].firstMatch
        XCTAssertTrue(label.exists, "no Play in the hero")
        let capsule = whiteRun(XCUIScreen.main.screenshot(), through: CGPoint(x: label.frame.midX, y: label.frame.midY))
        XCTAssertEqual(capsule.width, 160, accuracy: 3, "hero Play isn't 160 wide: \(capsule)")
        XCTAssertEqual(capsule.height, 48, accuracy: 3, "hero Play isn't 48 tall: \(capsule)")
        drag(from: 0.75, to: 0.35)
        sleep(1)
        let posters = app.buttons.allElementsBoundByIndex.filter { abs($0.frame.width - Layout100.width) < 1 && abs($0.frame.height - Layout100.height) < 1 }
            .sorted { ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX) }
        shot("card sizes")
        XCTAssertGreaterThanOrEqual(posters.count, 2, "no 100 × 150 posters")
        if posters.count >= 2, posters[0].frame.minY == posters[1].frame.minY {
            XCTAssertEqual(posters[1].frame.minX - posters[0].frame.maxX, 12, accuracy: 1, "posters aren't 12 apart")
        }
    }

    /// A real server's Continue Watching pictures are 16:9: cut to the card,
    /// one still made the card's element 302 points wide, 31 past each side
    /// and over the next card (VoiceOver's box, and what it reads at a touch).
    func testContinueCardWithAWidePictureIsTheCardsSize() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        configure(server, ["wide_pictures": "1"])
        defer { configure(server, ["reset": "1"]) }
        app.launch()
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 15), "no Continue Watching card")
        sleep(3)
        shot("wide pictures")
        for card in cards.allElementsBoundByIndex {
            XCTAssertEqual(card.frame.size.width, 240, accuracy: 1, "Continue Watching card \(card.identifier): \(card.frame)")
            XCTAssertEqual(card.frame.size.height, 170, accuracy: 1, "Continue Watching card \(card.identifier): \(card.frame)")
        }
    }

    /// The white area around a point of the screen (in points): how far
    /// white runs across and up and down from it.
    private func whiteRun(_ shot: XCUIScreenshot, through point: CGPoint) -> CGSize {
        guard let image = shot.image.cgImage,
              let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return .zero }
        let scale = CGFloat(image.width) / app.frame.width
        let perRow = image.bytesPerRow, perPixel = image.bitsPerPixel / 8
        func white(_ x: Int, _ y: Int) -> Bool {
            guard x >= 0, y >= 0, x < image.width, y < image.height else { return false }
            let i = y * perRow + x * perPixel
            return bytes[i] > 235 && bytes[i + 1] > 235 && bytes[i + 2] > 235
        }
        let cx = Int(point.x * scale), cy = Int(point.y * scale)
        // From the middle, past the words (dark), to the capsule's edges.
        var left = cx, right = cx, top = cy, bottom = cy
        while left > 0, (white(left - 1, cy) || left > cx - Int(60 * scale)) { left -= 1; if !white(left, cy) && left < cx - Int(60 * scale) { break } }
        while right < image.width - 1, (white(right + 1, cy) || right < cx + Int(60 * scale)) { right += 1; if !white(right, cy) && right > cx + Int(60 * scale) { break } }
        // Inside the straight part (past the rounded end), before the words.
        let edgeX = left + Int(30 * scale)
        while top > 0, white(edgeX, top - 1) { top -= 1 }
        while bottom < image.height - 1, white(edgeX, bottom + 1) { bottom += 1 }
        return CGSize(width: CGFloat(right - left) / scale, height: CGFloat(bottom - top + 1) / scale)
    }

    /// The bottom of Home's hero is in its picture's colours, as in the
    /// Apple TV app (it faded to black).
    func testHeroArtBand() {
        app.launch()
        sleep(8)
        let width = app.frame.width
        // 10 points above the hero's bottom, at the left (away from the
        // title and buttons).
        let point = CGPoint(x: 16, y: heroBottom() - 10)
        let picture = XCUIScreen.main.screenshot()
        guard let image = picture.image.cgImage, let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else {
            return XCTFail("no screenshot")
        }
        let scale = CGFloat(image.width) / width
        let i = Int(point.y * scale) * image.bytesPerRow + Int(point.x * scale) * (image.bitsPerPixel / 8)
        let brightest = max(bytes[i], bytes[i + 1], bytes[i + 2])
        shot("hero band")
        XCTAssertGreaterThan(brightest, 20, "the bottom of the hero is black, not its picture's colours")
    }

    /// Home's hero is about four fifths of the screen, as in the Apple TV
    /// app, with the first row's name in view under it (it was 1.3 times
    /// the width: 60% of an iPhone 17 Pro, half the rows' space lost).
    func testHeroHeight() {
        app.launch()
        sleep(8)
        let screen = app.frame.height
        let hero = heroBottom()
        let heading = app.staticTexts["Continue Watching"].firstMatch
        shot("hero height")
        XCTAssertEqual(hero / screen, 0.78, accuracy: 0.03, "the hero is \(hero) of \(screen) points")
        // Above the tab bar.
        XCTAssertLessThan(heading.frame.maxY, screen - 90, "Continue Watching's name isn't in view under the hero")
    }

    /// Where Home's hero ends: the rows start 30 points under it.
    private func heroBottom() -> CGFloat {
        let heading = app.staticTexts["Continue Watching"].firstMatch
        XCTAssertTrue(heading.waitForExistence(timeout: 20), "no Continue Watching")
        return heading.frame.minY - 30
    }

    private enum Layout100 {
        static let width: CGFloat = 100
        static let height: CGFloat = 150
    }

    // MARK: Helpers

    /// Sets how the test server behaves (see CONTROL in mock_server.py).
    private func configure(_ server: URL, _ settings: [String: String]) {
        let url = server.appending(path: "mock/set").appending(queryItems: settings.map { URLQueryItem(name: $0.key, value: $0.value) })
        let done = expectation(description: "configure")
        URLSession.shared.dataTask(with: url) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
    }

    /// The build numbers of the rows on the page, on screen or not
    /// ("Trending now ·12"), without scrolling (which counts as browsing).
    private func pageNumbers() -> Set<String> {
        // In one snapshot: element by element, a heading could go between
        // listing and reading it (Home changing is what's being watched).
        guard let root = try? app.snapshot() else { return [] }
        var headings: [String] = []
        func walk(_ element: XCUIElementSnapshot) {
            if element.elementType == .staticText, element.label.contains("·") { headings.append(element.label) }
            element.children.forEach(walk)
        }
        walk(root)
        return rowNumbers(Dictionary(headings.map { ("text:" + $0, CGRect.zero) }, uniquingKeysWith: { a, _ in a }))
    }

    private func testServer() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["DEBUG_EMBY"],
              let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let address = json["serverURL"] as? String else { return nil }
        return URL(string: address)
    }

    /// The rows' buttons and texts (from Continue Watching's heading down,
    /// not the hero, which turns by itself) with their frames, read in one go.
    private func rows() -> [String: CGRect] {
        guard let root = try? app.snapshot() else { return [:] }
        var top = CGFloat.infinity
        func findTop(_ element: XCUIElementSnapshot) {
            if element.elementType == .staticText, element.label == "Continue Watching" { top = min(top, element.frame.minY) }
            element.children.forEach(findTop)
        }
        findTop(root)
        var found: [String: CGRect] = [:]
        func walk(_ element: XCUIElementSnapshot) {
            let kind: String? = switch element.elementType {
            case .button: "button"
            case .staticText: "text"
            default: nil
            }
            if let kind, !element.frame.isEmpty, element.frame.minY >= top - 1, element.frame.maxY < app.frame.maxY - 100 {
                let name = element.identifier.isEmpty ? element.label : element.identifier
                if !name.isEmpty, found["\(kind):\(name)"] == nil { found["\(kind):\(name)"] = element.frame }
            }
            element.children.forEach(walk)
        }
        walk(root)
        return found
    }

    private func differences(_ a: [String: CGRect], _ b: [String: CGRect]) -> [String] {
        Set(a.keys).union(b.keys).sorted().compactMap { key in
            switch (a[key], b[key]) {
            case let (x?, y?) where abs(x.minX - y.minX) > 0.5 || abs(x.minY - y.minY) > 0.5
                || abs(x.width - y.width) > 0.5 || abs(x.height - y.height) > 0.5:
                "moved \(key): \(x) → \(y)"
            case (_?, nil): "gone \(key)"
            case (nil, _?): "new \(key)"
            default: nil
            }
        }
    }

    /// The build numbers after the rows' names ("Trending now ·12").
    private func rowNumbers(_ layout: [String: CGRect]) -> Set<String> {
        Set(layout.keys.compactMap { key -> String? in
            // Row names open the whole row: buttons (rows without: text).
            guard key.hasPrefix("text:") || key.hasPrefix("button:row-"), let dot = key.lastIndex(of: "·") else { return nil }
            let number = key[key.index(after: dot)...]
            return !number.isEmpty && number.allSatisfy(\.isNumber) ? String(number) : nil
        })
    }

    /// A finger drag down the middle of the screen, between heights given
    /// as fractions of it.
    private func drag(from: Double, to: Double, hold: TimeInterval = 0) {
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: from))
            .press(forDuration: 0.05, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: to)),
                   withVelocity: .default, thenHoldForDuration: hold)
    }

    private func shot(_ note: String) {
        step += 1
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let name = String(format: "ios-home-%02d-%@.png", step, note.replacingOccurrences(of: " ", with: "-"))
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: name))
        print("SHOT \(note) → \(name)")
    }
}

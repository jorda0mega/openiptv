import XCTest

/// iPhone: a film's Cast & Crew opens a person's page with their titles.
final class PersonPageTests: XCTestCase {
    private let app = XCUIApplication()
    private let shots = URL(fileURLWithPath: "/tmp/openiptv/uitest-ios")

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        if let account = ProcessInfo.processInfo.environment["DEBUG_EMBY"] {
            app.launchEnvironment["OPENREEL_DEBUG_EMBY"] = account
        }
    }

    private func shot(_ name: String) {
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: "person-\(name).png"))
    }

    func testCastOpensPersonPage() {
        openPerson()
        let titles = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Zorro'"))
        XCTAssertGreaterThanOrEqual(titles.count, 2, "their films aren't listed")
    }

    /// The server failing: the page says so and offers Try Again, which
    /// lists the titles. Regression: it said "Nothing with … in your
    /// library", as if there were none.
    func testCastPageRetries() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["fail": "persons"])
        defer { configure(server, ["reset": "1"]) }
        openPerson()
        shot("failed")
        let retry = app.buttons["Try Again"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 5), "no Try Again when the server failed")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Nothing with'")).firstMatch.exists,
                       "said there was nothing in the library")
        configure(server, ["reset": "1"])
        retry.tap()
        sleep(3)
        shot("retried")
        let titles = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Zorro'"))
        XCTAssertGreaterThanOrEqual(titles.count, 2, "Try Again didn't list their films")
    }

    /// A film opened from Home: a More Like This film opens its page.
    /// Regression: the tap did nothing (Home's stack had no film route).
    func testMoreLikeThisFromHome() {
        app.launch()
        sleep(6)
        let dune = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Dune: Part Two'")).firstMatch
        for _ in 0..<5 where !dune.isHittable { app.swipeUp(); sleep(1) }
        XCTAssertTrue(dune.isHittable, "no Dune: Part Two on Home")
        dune.tap()
        sleep(3)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '2024'")).firstMatch.exists, "Dune's page didn't open")
        let similar = app.buttons["Inception"].firstMatch
        for _ in 0..<5 where !similar.isHittable { app.swipeUp(); sleep(1) }
        XCTAssertTrue(similar.isHittable, "no Inception in More Like This")
        similar.tap()
        sleep(3)
        shot("more-like-this")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '2010'")).firstMatch.exists,
                      "Inception's page didn't open from More Like This")
    }

    /// A show's page lists Specials after its seasons, as in the Apple TV
    /// app. Regression: it opened on Specials, its seasons far below.
    func testSpecialsLast() {
        app.launchArguments = ["-debugSearch", "forensic"]
        app.launch()
        sleep(4)
        let tab = app.tabBars.buttons["Search"].firstMatch
        (tab.exists ? tab : app.buttons["Search"].firstMatch).tap()
        sleep(3)
        let show = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Forensic Files'")).firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 8), "no search result")
        show.tap()
        sleep(3)
        shot("show")
        let seasons = app.buttons.matching(NSPredicate(format: "label == 'Specials' OR label BEGINSWITH 'Season '")).allElementsBoundByIndex
            .sorted { $0.frame.minX < $1.frame.minX }.map(\.label)
        XCTAssertGreaterThan(seasons.count, 1, "no season tabs: \(seasons)")
        XCTAssertEqual(seasons.last, "Specials", "Specials isn't last: \(seasons)")
    }

    /// A show's episodes are all the same height, Up Next's too.
    /// Regression: its "UP NEXT" line made it 2 points taller, so the list
    /// moved when Up Next did.
    func testEpisodeRowsSameHeight() {
        openForensicFiles()
        for _ in 0..<3 { app.swipeUp(); sleep(1) }
        shot("episodes")
        let rows = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Case '")).allElementsBoundByIndex
            .filter { $0.frame.height > 40 }
        let heights = Set(rows.map { Int(($0.frame.height * 2).rounded()) })
        XCTAssertGreaterThan(rows.count, 3, "no episode rows")
        XCTAssertEqual(heights.count, 1, "episode rows differ in height: \(rows.map { "\($0.label.prefix(20)) \($0.frame.height)" })")
    }

    /// The main button keeps its width while the episode starts (a slow
    /// server). Regression: its label turned into "Starting…", narrower.
    func testMainButtonKeepsWidthWhileStarting() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        openForensicFiles()
        // "Continue S2 E3" (not the player's Continue Watching pill).
        let main = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Continue S'")).firstMatch
        XCTAssertTrue(main.waitForExistence(timeout: 5), "no Continue button")
        let before = main.frame.width
        configure(server, ["latency": "3"])
        defer { configure(server, ["reset": "1"]) }
        main.tap()
        let during = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Continue S'")).firstMatch
        XCTAssertTrue(during.exists, "the button's label changed while starting")
        XCTAssertEqual(during.frame.width, before, accuracy: 0.5, "the button changed width while starting")
        shot("starting")
    }

    /// A show's page: its picture runs up under the top bar, as on a film's
    /// page and in the Apple TV app, with no name in a bar over it; scrolled
    /// down, the season tabs stay just under the back button. Regression: a
    /// black bar with the show's name sat over the top of the picture.
    func testShowArtAtTop() {
        openForensicFiles()
        let top = luminance(XCUIScreen.main.screenshot(), in: CGRect(x: 120, y: 70, width: 160, height: 40))
        shot("show-top")
        XCTAssertGreaterThan(top, 25, "the top of the show's page is a black bar, not its picture (\(Int(top)))")
        XCTAssertFalse(app.navigationBars.staticTexts["Forensic Files"].exists, "the show's name sits in a bar over its picture")
        for _ in 0..<3 { app.swipeUp(); sleep(1) }
        let tab = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Season '")).firstMatch
        XCTAssertTrue(tab.exists, "no season tabs")
        shot("show-scrolled")
        XCTAssertGreaterThan(tab.frame.minY, 50, "the season tabs went up under the status bar: \(tab.frame)")
        XCTAssertLessThan(tab.frame.minY, 160, "the season tabs didn't stay at the top: \(tab.frame)")
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
        context.draw(crop, in: CGRect(x: 0, y: 0, width: side, height: side))
        var total = 0.0
        for i in stride(from: 0, to: data.count, by: 4) {
            total += 0.2126 * Double(data[i]) + 0.7152 * Double(data[i + 1]) + 0.0722 * Double(data[i + 2])
        }
        return total / Double(side * side)
    }

    /// Forensic Files' page, from Search.
    private func openForensicFiles() {
        app.launchArguments = ["-debugSearch", "forensic"]
        app.launch()
        sleep(4)
        let tab = app.tabBars.buttons["Search"].firstMatch
        (tab.exists ? tab : app.buttons["Search"].firstMatch).tap()
        sleep(3)
        let show = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Forensic Files'")).firstMatch
        XCTAssertTrue(show.waitForExistence(timeout: 8), "no search result")
        show.tap()
        sleep(3)
    }

    /// "+" beside Play puts a film on My List, as in the Apple TV app: the
    /// button turns into a tick, and Home has a My List row with the film
    /// (kept on the server: there after a relaunch).
    func testMyList() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        app.launchArguments = ["-debugSearch", "animals"]
        app.launch()
        sleep(4)
        let tab = app.tabBars.buttons["Search"].firstMatch
        (tab.exists ? tab : app.buttons["Search"].firstMatch).tap()
        sleep(3)
        let film = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Animals'")).firstMatch
        XCTAssertTrue(film.waitForExistence(timeout: 8), "no search result")
        film.tap()
        sleep(2)
        let add = app.buttons["Add to My List"].firstMatch
        if !add.waitForExistence(timeout: 5) {
            shot("no-plus")
            print("BUTTONS \(app.buttons.allElementsBoundByIndex.prefix(14).map { "\($0.label)|\(Int($0.frame.minY))" })")
        }
        XCTAssertTrue(add.exists, "no + on the film's page")
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Continue'")).firstMatch
        XCTAssertEqual(add.frame.height, 48, accuracy: 1, "+ isn't as tall as Play (48, as in the Apple TV app)")
        XCTAssertEqual(add.frame.midY, play.frame.midY, accuracy: 1, "+ isn't level with Play")
        add.tap()
        XCTAssertTrue(app.buttons["Remove from My List"].waitForExistence(timeout: 3), "+ didn't turn into a tick")
        shot("my-list-added")
        app.terminate()
        app.launchArguments = []
        app.launch()
        sleep(6)
        // The row's name opens the whole row: a button.
        let heading = app.buttons["row-My List"].firstMatch
        for _ in 0..<4 where !heading.isHittable { app.swipeUp(); sleep(1) }
        shot("my-list-row")
        XCTAssertTrue(heading.exists, "no My List row on Home")
        let inRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Animals'")).allElementsBoundByIndex
            .filter { $0.frame.minY > heading.frame.maxY && $0.frame.minY < heading.frame.maxY + 300 }
        XCTAssertFalse(inRow.isEmpty, "the film isn't in My List")
    }

    /// A film's story: two lines and MORE, as in the Apple TV app; MORE
    /// shows the rest.
    func testStoryMore() {
        app.launchArguments = ["-debugSearch", "dune"]
        app.launch()
        sleep(4)
        let tab = app.tabBars.buttons["Search"].firstMatch
        (tab.exists ? tab : app.buttons["Search"].firstMatch).tap()
        sleep(3)
        let film = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Dune: Part Two'")).firstMatch
        XCTAssertTrue(film.waitForExistence(timeout: 8), "no search result")
        film.tap()
        sleep(2)
        shot("story")
        let more = app.buttons["More of the story"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), "no MORE under a long story")
        // The story opens out when tapped, so it counts as a button.
        let story = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH 'Paul Atreides'")).firstMatch
        let cut = story.frame.height
        more.tap()
        sleep(1)
        XCTAssertFalse(app.buttons["More of the story"].exists, "MORE stayed")
        XCTAssertGreaterThan(story.frame.height, cut + 10, "the story didn't open out")
    }

    /// Antonio Banderas's page, from The Mask of Zorro's Cast & Crew.
    private func openPerson() {
        app.launchArguments = ["-debugSearch", "zorro"]
        app.launch()
        sleep(4)
        app.tabBars.buttons["Search"].firstMatch.tap()
        sleep(3)
        let film = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'The Mask of Zorro'")).firstMatch
        XCTAssertTrue(film.waitForExistence(timeout: 8), "no search result")
        film.tap()
        sleep(2)
        let actor = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Antonio Banderas'")).firstMatch
        for _ in 0..<4 where !actor.isHittable { app.swipeUp() }
        XCTAssertTrue(actor.waitForExistence(timeout: 5), "no cast member")
        shot("film-cast")
        actor.tap()
        sleep(3)
        shot("page")
        XCTAssertTrue(app.staticTexts["Antonio Banderas"].exists, "no person page")
    }

    /// Two copies of a film on the server's My List (HD and 4K: the same
    /// IMDb id) are one title on Home's My List row, as everywhere else in
    /// the app; taking it off takes both off. Regression: the row showed
    /// the film twice, once per copy.
    func testMyListOneCardPerTitle() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        defer { configure(server, ["reset": "1"]) }
        for id in ["a8", "k8"] { favorite(server, id) }
        app.launchArguments = []
        app.launch()
        sleep(6)
        let heading = app.buttons["row-My List"].firstMatch
        for _ in 0..<4 where !heading.isHittable { app.swipeUp(); sleep(1) }
        shot("my-list-copies")
        XCTAssertTrue(heading.exists, "no My List row on Home")
        let top = heading.frame.maxY + 12
        let cards = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Dune: Part Two'")).allElementsBoundByIndex
            .filter { abs($0.frame.minY - top) < 4 }
        XCTAssertEqual(cards.count, 1, "My List shows the film once per copy: \(cards.map(\.frame))")
        guard let card = cards.first else { return }
        card.tap()
        let remove = app.buttons["Remove from My List"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 6), "the film's page doesn't show it on My List")
        remove.tap()
        sleep(2)
        XCTAssertEqual(favorites(server), [], "a copy stayed on the server's My List")
    }

    /// Puts a title on the test user's My List on the server.
    private func favorite(_ server: URL, _ id: String) {
        var request = URLRequest(url: server.appending(path: "emby/Users/U1/FavoriteItems/\(id)"))
        request.httpMethod = "POST"
        request.setValue("tok", forHTTPHeaderField: "X-Emby-Token")
        let done = expectation(description: "favorite \(id)")
        URLSession.shared.dataTask(with: request) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
    }

    /// The ids on the test user's My List on the server.
    private func favorites(_ server: URL) -> [String] {
        var request = URLRequest(url: server.appending(path: "emby/Users/U1/Items")
            .appending(queryItems: [URLQueryItem(name: "Filters", value: "IsFavorite")]))
        request.setValue("tok", forHTTPHeaderField: "X-Emby-Token")
        var ids: [String] = []
        let done = expectation(description: "favorites")
        URLSession.shared.dataTask(with: request) { data, _, _ in
            let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            ids = (json?["Items"] as? [[String: Any]])?.compactMap { $0["Id"] as? String } ?? ["(no answer)"]
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return ids
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
}

import XCTest

/// Apple TV: the film runner's baseline (FilmLink) on the feeds the helper
/// at TEST_RUNNER_REAL_FEED hands out (the real ones, or the test server's),
/// driven by the remote. A card gets ready while it has focus (Ahead's 150
/// and 400 ms steps), Select plays it, and the player's own focus works its
/// track menus.
final class RealFeedFilmTests: XCTestCase, FilmLink {
    let app = XCUIApplication()
    private let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = false
        let environment = ProcessInfo.processInfo.environment
        let feed = environment["REAL_FEED"].flatMap(URL.init(string:))
        try XCTSkipIf(feed == nil, "needs the feeds' helper (TEST_RUNNER_REAL_FEED)")
        // The helper's address, not the logins: the simulator's system log
        // records the launch environment. The app fetches them.
        app.launchEnvironment["OPENREEL_DEBUG_EMBY_URL"] = feed!.appending(path: "emby").absoluteString
        app.launchEnvironment["OPENREEL_DEBUG_PROXY"] = environment["PROXY"]
        app.launchEnvironment["OPENREEL_DEBUG_PROXY_PLAIN"] = environment["PROXY_PLAIN"]
        app.launchArguments = ["-readOnlyServer", "YES", "-cacheFolder", environment["REAL_FEED_CACHE"] ?? "real", "-tvTab", "home"]
        if environment["LOW_DISK"] == "1" { app.launchArguments += ["-lowDisk", "YES"] }
        // Launch arguments for every launch ("-oldPlanWait YES"): one run the way before.
        app.launchArguments += (environment["APP_ARGUMENTS"] ?? "").split(separator: " ").map(String.init)
    }

    func testFilmOnThisLink() throws {
        try filmOnThisLink()
    }

    func say(_ line: String) {
        print(line.replacing(#/tok=\w+/#, with: "tok=#"))
    }

    func readout(_ id: String) -> String? {
        (try? app.staticTexts[id].firstMatch.snapshot())?.label
    }

    private var continueCards: XCUIElementQuery { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-'")) }

    func firstCard() throws -> String {
        XCTAssertTrue(continueCards.firstMatch.waitForExistence(timeout: 90), "no Continue Watching")
        return try XCTUnwrap(cardsInOrder().first, "no Continue Watching")
    }

    /// Down to Continue Watching, then along it to the card.
    func bring(_ id: String) throws {
        XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 90), "no Continue Watching card")
        for _ in 0..<8 where !focusedId().hasPrefix("continue-") { press(.down) }
        for _ in 0..<12 where focusedId() != id {
            let cards = cardsInOrder()
            guard let at = cards.firstIndex(of: focusedId()), let to = cards.firstIndex(of: id) else { break }
            press(to > at ? .right : .left)
        }
        XCTAssertEqual(focusedId(), id, "the card didn't get focus")
    }

    func play(_ id: String) {
        remote.press(.select)
    }

    func audioPick() -> TrackPick {
        guard openMenu("Audio") else { return .noMenu }
        let rows = menuRows()
        guard let other = rows.firstIndex(where: { $0.identifier == "audio-track" }) else { return closeMenu() }
        move(from: rows.firstIndex { $0.identifier == "audio-playing" } ?? 0, to: other)
        return .ready { self.pickAndGoBack() }
    }

    func subtitlePick(_ entry: Int) -> TrackPick {
        press(.up)
        guard button("Audio").waitForExistence(timeout: 3) else { return .noMenu }
        guard button("Subtitles").exists else {
            press(.down)
            return .nothing
        }
        guard openMenu("Subtitles") else { return .noMenu }
        let rows = menuRows()
        guard entry < rows.count else { return closeMenu() }
        move(from: rows.firstIndex { $0.isSelected } ?? 0, to: entry)
        return .ready { self.pickAndGoBack() }
    }

    private func press(_ button: XCUIRemote.Button) {
        remote.press(button)
        usleep(300_000)
    }

    private func focusedId() -> String {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        return element.exists ? element.identifier : ""
    }

    private func cardsInOrder() -> [String] {
        guard let home = try? app.snapshot() else { return [] }
        var cards: [XCUIElementSnapshot] = []
        func collect(_ element: XCUIElementSnapshot) {
            if element.elementType == .button, element.identifier.hasPrefix("continue-") { cards.append(element) }
            element.children.forEach(collect)
        }
        collect(home)
        return cards.sorted { $0.frame.minX < $1.frame.minX }.map(\.identifier)
    }

    private func button(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    /// Up to the round buttons, along to this one, and its menu open (it
    /// opens on the row playing).
    private func openMenu(_ label: String) -> Bool {
        let order = ["Subtitles", "Audio", "Playback Speed"]
        press(.up)
        guard let goal = order.firstIndex(of: label), button(label).waitForExistence(timeout: 3) else { return false }
        for _ in 0..<3 where !button(label).isSelected {
            let on = order.firstIndex { button($0).isSelected } ?? 1
            press(on < goal ? .right : .left)
        }
        guard button(label).isSelected else { return false }
        press(.select)
        let rows = app.descendants(matching: .any).matching(NSPredicate(format: "identifier IN %@", ["audio-playing", "audio-track", "subtitle-row"]))
        return rows.firstMatch.waitForExistence(timeout: 5)
    }

    private func menuRows() -> [XCUIElementSnapshot] {
        guard let screen = try? app.snapshot() else { return [] }
        var rows: [XCUIElementSnapshot] = []
        func collect(_ element: XCUIElementSnapshot) {
            if ["audio-playing", "audio-track", "audio-other-copy", "subtitle-row"].contains(element.identifier) { rows.append(element) }
            element.children.forEach(collect)
        }
        collect(screen)
        return rows.sorted { $0.frame.minY < $1.frame.minY }
    }

    private func move(from: Int, to: Int) {
        for _ in 0..<abs(to - from) { press(to > from ? .down : .up) }
    }

    private func pickAndGoBack() {
        remote.press(.select)
        press(.down)
    }

    private func closeMenu() -> TrackPick {
        press(.menu)
        press(.down)
        return .nothing
    }
}

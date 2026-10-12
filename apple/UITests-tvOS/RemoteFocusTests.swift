import XCTest

/// Apple TV: drives the app with the Siri Remote, as a person would, and
/// prints which element has focus after each press (the simulator's own
/// remote window can't be scripted). Run with
/// `xcodebuild test -scheme "OpenIPTV TV UITests"` on an Apple TV simulator
/// signed in to the test server (scripts/mock_server.py).
final class RemoteFocusTests: XCTestCase {
    private let app = XCUIApplication()
    private let remote = XCUIRemote.shared

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

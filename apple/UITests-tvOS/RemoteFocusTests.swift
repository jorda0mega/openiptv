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

    /// Live TV: from the tab bar to the shelf row, pick another shelf, down
    /// into its channels, and back up to the row.
    func testLiveShelves() {
        // No -tvLiveTab: a launch argument would pin the shelf.
        app.launchArguments = ["-tvTab", "live"]
        app.launch()
        sleep(6)
        press(.down, "to shelf row")
        press(.right, "next shelf")
        press(.select, "choose it")
        press(.down, "into channels")
        press(.down, "further down")
        press(.up, "up")
        press(.up, "up to row")
    }
}

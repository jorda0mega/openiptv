import XCTest

/// Settings → Playback → Phone network, as the user signed it off: below
/// the player, above the languages, "Get films ready" on "150 MB a day",
/// each choice with its line, and today's use in the footer.
final class PhoneNetworkSettingTests: XCTestCase {
    private let app = XCUIApplication()
    private let shots = URL(fileURLWithPath: "/tmp/openiptv/uitest-agent")

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        if let account = ProcessInfo.processInfo.environment["DEBUG_EMBY"] {
            app.launchEnvironment["OPENREEL_DEBUG_EMBY"] = account
        }
        XCUIDevice.shared.orientation = .portrait
    }

    func testThePhoneNetworkSectionAsDrawn() {
        app.launch()
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 30), "no Settings on Home")
        settings.tap()
        let playback = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Playback'")).firstMatch
        XCTAssertTrue(playback.waitForExistence(timeout: 5), "no Playback in Settings")
        playback.tap()

        let picker = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Get films ready'")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5), "no Get films ready")
        let header = text("Phone network"), footer = text("Used today:"), player = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Player'")).firstMatch, languages = text("Languages")
        XCTAssertTrue(header.exists, "no Phone network header")
        XCTAssertEqual(footer.label, "Gets the start of the film you rest on ready, about 10 MB each, so it plays at once when you tap it. "
                       + "Used today: 0 MB. Low Data Mode turns this off.")
        XCTAssertTrue("\(picker.label) \(picker.value as? String ?? "")".contains("150 MB a day"),
                      "not on 150 MB a day: \(picker.label) \(picker.value ?? "")")
        XCTAssertLessThanOrEqual(player.frame.maxY, header.frame.minY, "the section isn't below the player")
        XCTAssertLessThanOrEqual(header.frame.maxY, picker.frame.minY)
        XCTAssertLessThanOrEqual(picker.frame.maxY, footer.frame.minY)
        XCTAssertLessThanOrEqual(footer.frame.maxY, languages.frame.minY, "the section isn't above the languages")
        shot("playback page")

        picker.tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'None'")).firstMatch.waitForExistence(timeout: 5),
                      "the menu didn't open")
        // The line under each choice is drawn (the screenshot) but not given to UI tests as any element's text.
        shot("choices open")
        for title in ["None", "150 MB a day", "As on Wi-Fi"] {
            XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch.exists, "no \(title) in the menu")
        }
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH '150 MB a day'")).firstMatch.tap()
    }

    private func text(_ start: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH[c] %@ OR label CONTAINS %@", start, start)).firstMatch
    }

    private func shot(_ note: String) {
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        let file = shots.appending(path: "phone-network-\(note.replacingOccurrences(of: " ", with: "-")).png")
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: file)
    }
}

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
        let choices = [("None", "Films load when you tap them. Uses the least data."),
                       ("150 MB a day", "The film you rest on, about 10 MB each."),
                       ("As on Wi-Fi", "Up to 3 films, 10–30 MB each, no daily limit.")]
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'None'")).firstMatch.waitForExistence(timeout: 5),
                      "the menu didn't open")
        shot("choices open")
        for (title, line) in choices {
            let choice = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
            XCTAssertTrue(choice.exists, "no \(title) in the menu")
            let anywhere = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", line)).firstMatch
            XCTAssertTrue(choice.label.contains(line) || (choice.value as? String)?.contains(line) == true || anywhere.exists,
                          "no line under \(title): \(choice.label)")
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

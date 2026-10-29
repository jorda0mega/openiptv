import XCTest

final class ForgetEverythingTests: XCTestCase {
    private let app = XCUIApplication()
    private let remote = XCUIRemote.shared

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        if let account = ProcessInfo.processInfo.environment["DEBUG_EMBY"] {
            app.launchEnvironment["OPENREEL_DEBUG_EMBY"] = account
        }
    }

    func testForgetEverythingAsksThenForgets() {
        app.launchArguments = ["-tvTab", "settings"]
        app.launch()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Advanced'")).firstMatch.waitForExistence(timeout: 30),
                      "no Advanced in Settings")
        XCTAssertTrue(focus({ $0.hasPrefix("Advanced") }, pressing: .down), "focus didn't reach Advanced: \(focusedLabel())")
        remote.press(.select)
        XCTAssertTrue(focus({ $0 == "Forget everything on this device" }, pressing: .down),
                      "focus didn't reach Forget everything: \(focusedLabel())")
        remote.press(.select)

        XCTAssertTrue(app.buttons["Forget everything"].waitForExistence(timeout: 5), "the confirm box didn't open")
        XCTAssertTrue(focus({ $0 == "Forget everything" }, pressing: .up), "focus isn't on the box's button: \(focusedLabel())")
        remote.press(.select)
        XCTAssertTrue(app.staticTexts["Your Emby library and live TV in one fast app."].waitForExistence(timeout: 10),
                      "still signed in after Forget everything")
    }

    private func focusedLabel() -> String {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        return element.exists ? element.label : ""
    }

    private func focus(_ wanted: (String) -> Bool, pressing button: XCUIRemote.Button) -> Bool {
        for _ in 0..<8 {
            if wanted(focusedLabel()) { return true }
            remote.press(button)
            sleep(1)
        }
        return wanted(focusedLabel())
    }
}

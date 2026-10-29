import XCTest

final class ForgetEverythingTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        if let account = ProcessInfo.processInfo.environment["DEBUG_EMBY"] {
            app.launchEnvironment["OPENREEL_DEBUG_EMBY"] = account
        }
        XCUIDevice.shared.orientation = .portrait
    }

    func testForgetEverythingAsksThenForgets() {
        app.launch()
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 30), "no Settings on Home")
        settings.tap()
        let advanced = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Advanced'")).firstMatch
        XCTAssertTrue(advanced.waitForExistence(timeout: 5), "no Advanced in Settings")
        advanced.tap()
        let forget = app.buttons["Forget everything on this device"]
        XCTAssertTrue(forget.waitForExistence(timeout: 5), "no Forget everything on the Advanced page")
        forget.tap()

        let confirm = app.buttons["Forget everything"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "the confirm box didn't open")
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Your Emby library and live TV in one fast app."].waitForExistence(timeout: 10),
                      "still signed in after Forget everything")
    }
}

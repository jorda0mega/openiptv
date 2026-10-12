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
        let titles = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Zorro'"))
        XCTAssertGreaterThanOrEqual(titles.count, 2, "their films aren't listed")
    }
}

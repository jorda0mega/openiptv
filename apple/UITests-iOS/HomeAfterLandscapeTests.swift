import XCTest

/// iPhone: Home looks the same after a film played in landscape (the page
/// laid out sideways underneath must come back to its upright size).
final class HomeAfterLandscapeTests: XCTestCase {
    private let app = XCUIApplication()
    private let shots = URL(fileURLWithPath: "/tmp/openiptv/uitest-ios")

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        if let account = ProcessInfo.processInfo.environment["DEBUG_EMBY"] {
            app.launchEnvironment["OPENREEL_DEBUG_EMBY"] = account
        }
    }

    private func shot(_ name: String) {
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: "home-\(name).png"))
    }

    /// The hero's Play button's frame: where the hero ends.
    /// The shown hero page's Play (the hero turns every eight seconds:
    /// the other pages' Play buttons sit off the screen beside it).
    private func heroPlay() -> CGRect? {
        app.buttons.matching(NSPredicate(format: "label == 'Play'")).allElementsBoundByIndex
            .map(\.frame).first { $0.minX >= 0 && $0.maxX <= app.frame.width }
    }

    func testHeroSizeAfterLandscapePlayback() throws {
        try XCTSkipIf(onCI, "sideways runs locally only (see onCI in PlayerLookTests)")
        app.launch()
        // Home's first build (a fresh simulator has nothing saved).
        var before = heroPlay()
        for _ in 0..<40 where before == nil {
            usleep(500_000)
            before = heroPlay()
        }
        shot("before")
        XCTAssertNotNil(before, "no hero Play button")
        app.buttons.matching(NSPredicate(format: "label == 'Play'")).firstMatch.tap()
        sleep(6)
        app.tapControl("Rotate to landscape") { self.app.buttons["Rotate to portrait"].exists }
        sleep(3)
        shot("player-landscape")
        app.tapControl("Close player") { !self.app.buttons["Rotate to portrait"].exists }
        sleep(4)
        shot("after")
        let after = heroPlay()
        print("HERO before \(String(describing: before)) after \(String(describing: after))")
        XCTAssertEqual(after, before, "the hero changed size after landscape playback")
    }
}

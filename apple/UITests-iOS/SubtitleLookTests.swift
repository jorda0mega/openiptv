import XCTest

/// iPhone: the film's own English subtitles over its picture, upright and
/// sideways, as perf/subtitle_look.py reads them: a screenshot each way
/// (LOOK_SHOTS, a folder on the Mac) and the player's frame readout
/// (debug-frame-look, where the build has it). Test server only
/// (TEST_RUNNER_DEBUG_EMBY), with one of perf/make_look_films.sh's films.
final class SubtitleLookTests: XCTestCase {
    let app = XCUIApplication()

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        if let account = ProcessInfo.processInfo.environment["DEBUG_EMBY"] {
            app.launchEnvironment["OPENREEL_DEBUG_EMBY"] = account
        }
        XCUIDevice.shared.orientation = .portrait
    }

    func testSubtitleLook() throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LOOK_SHOTS"] ?? "/tmp/openiptv/subtitle-look")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        app.launchArguments = ["-debugSearch", "animals", "-forgetTrackChoices", "YES"]
        app.launch()
        sleep(4)
        app.tabBars.buttons["Search"].firstMatch.tap()
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Animals' AND NOT label BEGINSWITH 'Animals.'")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 20), "no search result")
        result.tap()
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Resume' OR label BEGINSWITH 'Continue'")).firstMatch
        if !play.waitForExistence(timeout: 10), result.exists { result.tap() }
        XCTAssertTrue(play.waitForExistence(timeout: 10), "no play button")
        play.tap()
        let start = app.staticTexts["debug-start"].firstMatch
        let tapped = Date()
        while Date().timeIntervalSince(tapped) < 180, (start.exists ? start.label.split(separator: " ").count : 0) < 4 { sleep(1) }
        sleep(3)

        let menu = app.buttons["Audio and Subtitles"].firstMatch, off = app.buttons["Off"].firstMatch
        for _ in 0..<3 where !off.exists {
            if !menu.isHittable {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
                _ = menu.waitForExistence(timeout: 2)
            }
            if menu.isHittable { menu.tap() }
            _ = off.waitForExistence(timeout: 3)
        }
        let english = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'English'")).allElementsBoundByIndex
            .first { $0.frame.minY > off.frame.minY }
        try XCTUnwrap(english, "no English subtitles").tap()
        sleep(6)

        for way in ["upright", "sideways"] {
            if way == "sideways" {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
                let rotate = app.buttons["Rotate to landscape"].firstMatch
                if rotate.waitForExistence(timeout: 3) { rotate.tap() }
                sleep(6)
            }
            // The controls hide 3 s after showing, and the picture stays.
            let look = app.staticTexts["debug-frame-look"].firstMatch
            let readout = look.exists ? look.label : "none"
            let shot = folder.appending(path: "\(way).png")
            try XCUIScreen.main.screenshot().pngRepresentation.write(to: shot)
            let line = app.staticTexts["debug-subtext"].firstMatch
            print("LOOK \(way) frame=\(readout.replacingOccurrences(of: " ", with: "_")) subtitle=\(line.exists && !line.label.isEmpty ? "shown" : "none") shot=\(shot.path)")
        }
    }
}

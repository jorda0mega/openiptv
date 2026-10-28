import XCTest

/// iPhone: the film's own English subtitles over its picture, upright and
/// sideways, as perf/subtitle_look.py reads them: a screenshot each way
/// (LOOK_SHOTS, a folder on the Mac) and the player's frame readout
/// (debug-frame-look, where the build has it). Test server only
/// (TEST_RUNNER_DEBUG_EMBY), with one of perf/make_look_films.sh's films.
final class SubtitleLookTests: TimingCase {
    func testSubtitleLook() throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["LOOK_SHOTS"] ?? "/tmp/openiptv/subtitle-look")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard openFilm(["-forgetTrackChoices", "YES"]) != nil else { return XCTFail("no first frame in 180 s") }
        sleep(3)

        let menu = app.buttons["Audio and Subtitles"].firstMatch, off = app.buttons["Off"].firstMatch
        for _ in 0..<5 where !off.exists {
            if !menu.isHittable {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
                _ = menu.waitForExistence(timeout: 2)
            }
            // By its place: the controls can hide between finding the button and tapping it.
            if menu.isHittable {
                let frame = menu.frame
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
            }
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
                guard rotate.waitForExistence(timeout: 3) else { return XCTFail("no Rotate to landscape: no sideways shot") }
                rotate.tap()
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

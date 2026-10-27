import XCTest

/// iPhone: the ±10 s buttons as a viewer taps them, ten times each way.
/// Each tap prints a JUMP line: when it was tapped (the Mac's clock), the
/// player's own seek time and MB from the server, and whether a loading
/// view showed. perf/jumps.py times each tap to the next moving frame from
/// the screen recording perf/jump_runs.sh makes while JUMPS BEGIN is up.
/// Test server only (TEST_RUNNER_DEBUG_EMBY), with perf/make_jump_film.sh's film.
final class JumpTimingTests: XCTestCase {
    let app = XCUIApplication()

    override func setUp() {
        super.setUp()
        continueAfterFailure = true
        if let account = ProcessInfo.processInfo.environment["DEBUG_EMBY"] {
            app.launchEnvironment["OPENREEL_DEBUG_EMBY"] = account
        }
        if let options = ProcessInfo.processInfo.environment["MPV_EXTRA"] {
            app.launchEnvironment["OPENREEL_DEBUG_MPV"] = options
        }
        XCUIDevice.shared.orientation = .portrait
    }

    func testTenSecondJumps() throws {
        app.launchArguments = ["-debugSearch", "animals"]
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
        let tapped = Date()
        let start = app.staticTexts["debug-start"].firstMatch
        while Date().timeIntervalSince(tapped) < 180, (start.exists ? start.label.split(separator: " ").count : 0) < 4 { sleep(1) }
        guard start.exists, start.label.split(separator: " ").count == 4 else { return XCTFail("no first frame in 180 s") }
        print(String(format: "JUMP start %.1f s after the tap", Date().timeIntervalSince(tapped)))
        sleep(20)

        print("JUMPS BEGIN")
        sleep(4)
        for (label, sign) in [("Forward 10 seconds", "+"), ("Back 10 seconds", "-")] {
            for n in 1...10 {
                controlsUp()
                let before = jumps().count, from = playerState()?.seconds ?? -1
                let at = Date()
                app.buttons[label].firstMatch.tap()
                var loading = false
                while Date().timeIntervalSince(at) < 7 {
                    if app.descendants(matching: .any)["load-progress"].firstMatch.exists { loading = true }
                    usleep(250_000)
                }
                let seek = jumps().dropFirst(before).first ?? "none"
                print(String(format: "JUMP %@10 n=%d tap=%.3f from=%.1f to=%.1f seek=%@ loading=%@", sign, n, at.timeIntervalSince1970, from,
                             playerState()?.seconds ?? -1, seek.replacingOccurrences(of: " ", with: "_"), loading ? "yes" : "no"))
            }
        }
        print("JUMPS END")
        sleep(2)
    }

    /// The controls fresh on screen: hidden first if up (they hide 3 s after showing).
    private func controlsUp() {
        let close = app.buttons["Close player"].firstMatch
        let picture = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        if close.isHittable {
            picture.tap()
            usleep(400_000)
        }
        if !close.isHittable {
            picture.tap()
            for _ in 0..<10 where !close.isHittable { usleep(200_000) }
        }
    }

    private func playerState() -> (seconds: Double, playing: Bool)? {
        let parts = app.staticTexts["debug-position"].firstMatch.label.split(separator: " ")
        guard parts.count == 2, let seconds = Double(parts[0]) else { return nil }
        return (seconds, parts[1] == "playing")
    }

    /// The player's seeks so far: "412 ms 0.3 MB" each, from the seek to libmpv's restart.
    private func jumps() -> [String] {
        let readout = app.staticTexts["debug-buffering"].firstMatch.label
        guard let field = readout.components(separatedBy: " | ").first(where: { $0.hasPrefix("jumps: ") }) else { return [] }
        return field.dropFirst(7).components(separatedBy: ", ")
    }
}

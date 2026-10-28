import XCTest

/// Apple TV: the remote's clicks right and left (10 s each) as a viewer
/// clicks them, ten each way, then the player's own jump of 5 minutes in a
/// launch of its own, on the feeds the helper at TEST_RUNNER_REAL_FEED hands
/// out (the real ones, or the test server's). The same JUMP lines as the
/// iPhone's, for perf/jumps.py (and the screen recording perf/sim_runs.sh
/// makes while JUMPS BEGIN is up, on the test server's perf/make_jump_film.sh film).
final class JumpTimingTests: XCTestCase {
    let app = XCUIApplication()
    private let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = true
        let environment = ProcessInfo.processInfo.environment
        let feed = environment["REAL_FEED"].flatMap(URL.init(string:))
        try XCTSkipIf(feed == nil, "needs the feeds' helper (TEST_RUNNER_REAL_FEED)")
        // The helper's address, not the logins: the simulator's system log records the launch environment.
        app.launchEnvironment["OPENREEL_DEBUG_EMBY_URL"] = feed!.appending(path: "emby").absoluteString
        app.launchArguments = ["-readOnlyServer", "YES", "-cacheFolder", environment["REAL_FEED_CACHE"] ?? "real", "-tvTab", "home"]
    }

    func testTenSecondJumps() throws {
        // The first start after an install can fail (the app gives up at 30 s): say so, then try once more.
        var started = openFilm()
        if started == nil {
            print("JUMP first start failed: launching again")
            app.terminate()
            started = openFilm()
        }
        guard let started else { return XCTFail("no first frame in 180 s, twice") }
        print(String(format: "JUMP start %.1f s after the tap", started))
        sleep(20)

        print("JUMPS BEGIN")
        // The runner starts its recording on this file: xcodebuild can hold the line above back.
        if let folder = ProcessInfo.processInfo.environment["LOOK_SHOTS"] {
            FileManager.default.createFile(atPath: folder + "/jumps-begin", contents: nil)
        }
        sleep(4)
        for (button, sign) in [(XCUIRemote.Button.right, "+"), (.left, "-")] {
            for n in 1...10 {
                let before = jumps().count, from = position()
                let at = Date()
                remote.press(button)
                var loading = false
                while Date().timeIntervalSince(at) < 7 {
                    if app.descendants(matching: .any)["load-progress"].firstMatch.exists { loading = true }
                    usleep(250_000)
                }
                let seek = jumps().dropFirst(before).first ?? "none"
                print(String(format: "JUMP %@10 n=%d tap=%.3f from=%.1f to=%.1f seek=%@ loading=%@", sign, n, at.timeIntervalSince1970, from,
                             position(), seek.replacingOccurrences(of: " ", with: "_"), loading ? "yes" : "no"))
            }
        }
        print("JUMPS END")
        sleep(2)
        app.terminate()

        app.launchEnvironment["OPENREEL_DEBUG_JUMPS_AFTER"] = "20"
        defer { app.launchEnvironment["OPENREEL_DEBUG_JUMPS_AFTER"] = nil }
        guard openFilm() != nil else { return XCTFail("no first frame in 180 s, second launch") }
        let began = Date()
        while Date().timeIntervalSince(began) < 90, jumps().isEmpty { sleep(1) }
        if let first = jumps().first, let ms = Double(first.split(separator: " ").first ?? "") {
            print(String(format: "METRIC film.jump.forward_5min %.0f ms", ms))
        } else {
            print("JUMP +5min: none in 90 s")
        }
        app.terminate()
    }

    /// Continue Watching's first card, focused and played. Seconds from Select to the first frame, nil when none in 180 s.
    private func openFilm() -> Double? {
        app.launch()
        let card = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'continue-'")).firstMatch
        XCTAssertTrue(card.waitForExistence(timeout: 90), "no Continue Watching card")
        for _ in 0..<8 where !focused().hasPrefix("continue-") {
            remote.press(.down)
            usleep(300_000)
        }
        sleep(3)
        remote.press(.select)
        let pressed = Date()
        let start = app.staticTexts["debug-start"].firstMatch, failed = app.staticTexts["debug-start-error"].firstMatch
        var cause = "none"
        while Date().timeIntervalSince(pressed) < 180, (start.exists ? start.label.split(separator: " ").count : 0) < 4,
              !(failed.exists && !failed.label.isEmpty) {
            cause = slowCause() ?? cause
            sleep(1)
        }
        guard start.exists, start.label.split(separator: " ").count == 4 else {
            // What the app shows instead: its own message (fixed words) and whether the loading view is up.
            let message = failed.exists && !failed.label.isEmpty ? String(failed.label.prefix(80)).replacingOccurrences(of: "://", with: " ") : "none"
            let loading = app.descendants(matching: .any)["load-progress"].firstMatch.exists
            print(String(format: "START none after %.0f s, slow line seen: %@: ", Date().timeIntervalSince(pressed), cause)
                  + "player \(app.staticTexts["debug-item"].firstMatch.exists ? "open" : "not open") | error \(message) | loading \(loading ? "shown" : "none")")
            return nil
        }
        return Date().timeIntervalSince(pressed)
    }

    /// The loading view's slow line, as one of its fixed phrases (its other words can name the film).
    private func slowCause() -> String? {
        let view = app.descendants(matching: .any)["load-progress"].firstMatch
        guard view.exists else { return nil }
        let words = view.label + " " + view.descendants(matching: .staticText).allElementsBoundByIndex.map(\.label).joined(separator: " ")
        for phrase in ["slow to answer", "slow to send the film", "connection is slow", "No internet connection"] where words.contains(phrase) {
            return phrase.replacingOccurrences(of: " ", with: "_")
        }
        return nil
    }

    private func focused() -> String {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        return element.exists ? element.identifier : ""
    }

    private func position() -> Double {
        let readout = app.staticTexts["debug-position"].firstMatch
        return readout.exists ? readout.label.split(separator: " ").first.flatMap { Double($0) } ?? -1 : -1
    }

    private func jumps() -> [String] {
        let readout = app.staticTexts["debug-buffering"].firstMatch
        guard readout.exists, let field = readout.label.components(separatedBy: " | ").first(where: { $0.hasPrefix("jumps: ") }) else { return [] }
        return field.dropFirst(7).components(separatedBy: ", ")
    }
}

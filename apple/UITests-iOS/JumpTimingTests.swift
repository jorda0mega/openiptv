import XCTest

/// iPhone: the ±10 s buttons as a viewer taps them, ten times each way,
/// then one jump of 5 minutes in a launch of its own. Each tap prints a
/// JUMP line: when it was tapped (the Mac's clock), the player's own seek
/// time and MB from the server, and whether a loading view showed.
/// perf/jumps.py times each tap to the next moving frame from the app's log
/// and the screen recording perf/sim_runs.sh makes while JUMPS BEGIN is up
/// (on the test server, with perf/make_jump_film.sh's film).
final class JumpTimingTests: TimingCase {
    func testTenSecondJumps() throws {
        // The first tap after an install can fail (the app gives up at 30 s): say so, then try once more.
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
        app.terminate()

        // The player's own jump of 5 minutes (then back 30 s), 20 s after it starts.
        app.launchEnvironment["OPENREEL_DEBUG_JUMPS_AFTER"] = "20"
        defer { app.launchEnvironment["OPENREEL_DEBUG_JUMPS_AFTER"] = nil }
        guard openFilm() != nil else { return XCTFail("no first frame in 180 s, second launch") }
        let began = Date()
        while Date().timeIntervalSince(began) < 90, jumps().isEmpty { sleep(1) }
        if let first = jumps().first, let ms = Double(first.split(separator: " ").first ?? "") {
            print(String(format: "METRIC film.jump.forward_5min %.0f ms", ms))
            print("JUMP +5min seek=\(first.replacingOccurrences(of: " ", with: "_"))")
        } else {
            print("JUMP +5min: none in 90 s")
            sayWhyNoStart()
        }
        app.terminate()
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
        let readout = app.staticTexts["debug-position"].firstMatch
        guard readout.exists else { return nil }
        let parts = readout.label.split(separator: " ")
        guard parts.count == 2, let seconds = Double(parts[0]) else { return nil }
        return (seconds, parts[1] == "playing")
    }

    /// The player's seeks so far: "412 ms 0.3 MB" each, from the seek to libmpv's restart.
    private func jumps() -> [String] {
        let readout = app.staticTexts["debug-buffering"].firstMatch
        guard readout.exists, let field = readout.label.components(separatedBy: " | ").first(where: { $0.hasPrefix("jumps: ") })
        else { return [] }
        return field.dropFirst(7).components(separatedBy: ", ")
    }
}

import XCTest

/// iPhone: a live channel opened from Live TV, then five switches to the next
/// channel with a swipe up on the player, each waited to playing. The app's
/// "PERF live open" lines time each one (perf/perf.py live). Test server
/// only: a real lineup lists the Account Info channels, which spell out a login.
final class LiveTimingTests: XCTestCase {
    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = true
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipIf(environment["REAL_FEED"] != nil, "live timing runs on the test server only")
        guard let raw = environment["DEBUG_EMBY"],
              let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let server = json["serverURL"] as? String else { throw XCTSkip("no test server (TEST_RUNNER_DEBUG_EMBY)") }
        app.launchEnvironment["OPENREEL_DEBUG_EMBY"] = raw
        app.launchEnvironment["OPENREEL_DEBUG_IPTV"] = #"{"id":"6F9A1E52-0000-4000-8000-000000000001","name":"Test","kind":"#
            + #"{"xtream":{"server":"\#(server)","username":"u","password":"p"}}}"#
        XCUIDevice.shared.orientation = .portrait
    }

    func testLiveStartAndSwitch() throws {
        app.launchArguments = ["-freshLineup", "YES"]
        app.launch()
        let tab = app.tabBars.buttons["Live TV"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 30), "no Live TV tab")
        tab.tap()
        let row = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "Channel 1")).firstMatch
        for _ in 0..<3 where !row.waitForExistence(timeout: 10) { app.swipeUp() }
        XCTAssertTrue(row.exists, "no Channel 1 in the list")
        row.tap()
        print("LIVE start: \(playing(within: 60) ? "playing" : "not playing in 60 s")")
        sleep(5)
        for n in 1...5 {
            app.swipeUp()
            sleep(1)
            print("LIVE switch \(n): \(playing(within: 60) ? "playing" : "not playing in 60 s")")
            sleep(5)
        }
        app.terminate()
    }

    private func playing(within seconds: Double) -> Bool {
        let readout = app.staticTexts["debug-live-state"].firstMatch
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if readout.exists, readout.label == "playing" { return true }
            usleep(250_000)
        }
        return false
    }
}

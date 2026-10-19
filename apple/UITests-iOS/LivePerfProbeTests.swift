import XCTest

/// Phase 0 of the Live TV measurement (.audit/live-perf/fable-plan.md
/// §4.3): each test-server switch with a known answer, played on a channel
/// of its own, so the `tok` of the app's `PERF live` lines names the row.
/// The lines are checked on the Mac, from its log, by
/// scripts/live_app_phase0.py; these tests drive the app and check what it
/// shows. Needs the test film (OPENIPTV_MOCK_VIDEO) on the test server.
final class LivePerfProbeTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        if let account = ProcessInfo.processInfo.environment["DEBUG_EMBY"] {
            app.launchEnvironment["OPENREEL_DEBUG_EMBY"] = account
        }
        if let server = testServer() {
            app.launchEnvironment["OPENREEL_DEBUG_IPTV"] = #"{"id":"6F9A1E52-0000-4000-8000-000000000001","name":"Test","kind":"#
                + #"{"xtream":{"server":"\#(server.absoluteString)","username":"u","password":"p"}}}"#
        }
        XCUIDevice.shared.orientation = .portrait
    }

    func testFloor() throws {
        launch([:])
        for _ in 1...10 {
            open(channel: 1)
            XCTAssertTrue(state("playing", within: 15), "channel 1 didn't play")
            sleep(2)
            close()
        }
    }

    func testDelay() throws {
        launch(["live_delay": "3"])
        open(channel: 2)
        XCTAssertTrue(state("playing", within: 15), "the slow channel didn't play")
        sleep(2)
        close()
    }

    func testStatus403() throws {
        launch(["live_status": "403"])
        open(channel: 3)
        XCTAssertTrue(state("failed", within: 15), "a refused channel didn't fail")
        XCTAssertEqual(failure(), "http_403")
        close()
    }

    func testStatus404() throws {
        launch(["live_status": "404"])
        open(channel: 4)
        XCTAssertTrue(state("failed", within: 15), "a missing channel didn't fail")
        XCTAssertEqual(failure(), "http_404")
        close()
    }

    func testStall() throws {
        launch(["live_stall": "20:5"])
        open(channel: 5)
        XCTAssertTrue(state("playing", within: 15), "channel 5 didn't play")
        sleep(32)
        close()
    }

    func testRate() throws {
        launch(["live_rate": "1500"])
        open(channel: 6)
        XCTAssertTrue(state("playing", within: 15), "the slow stream didn't play")
        sleep(17)
        close()
    }

    func testCut() throws {
        launch(["live_cut": "20"])
        open(channel: 7)
        XCTAssertTrue(state("playing", within: 15), "channel 7 didn't play")
        sleep(26)
        close()
    }

    func testReset() throws {
        launch(["live_chunked": "1", "live_cut": "5", "live_cut_reset": "1"])
        open(channel: 8)
        XCTAssertTrue(state("playing", within: 15), "channel 8 didn't play")
        let deadline = Date().addingTimeInterval(20)
        while failure() == "none", Date() < deadline { usleep(250_000) }
        XCTAssertEqual(failure(), "reset")
        close()
    }

    func testDeadLive() throws {
        app.launchEnvironment["OPENREEL_DEBUG_LIVE_START_LIMIT"] = "3"
        launch(["dead_live": "9"])
        open(channel: 9)
        XCTAssertTrue(state("failed", within: 15), "a channel that sends nothing didn't fail")
        XCTAssertEqual(failure(), "no_data")
        close()
    }

    private func launch(_ switches: [String: String]) {
        guard let server = testServer() else { return XCTFail("no test server") }
        configure(server, ["reset": "1"])
        if !switches.isEmpty { configure(server, switches) }
        app.launchArguments = ["-freshLineup", "YES"]
        app.launch()
        let tab = app.tabBars.buttons["Live TV"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 15), "no Live TV tab")
        tab.tap()
    }

    private func open(channel number: Int) {
        let row = app.buttons.matching(NSPredicate(format: "label ENDSWITH %@", "Channel \(number)")).firstMatch
        for _ in 0..<3 where !row.waitForExistence(timeout: 10) { app.swipeUp() }
        XCTAssertTrue(row.exists, "no Channel \(number) in the list")
        row.tap()
        let readout = app.staticTexts["debug-live-copy"].firstMatch
        XCTAssertTrue(readout.waitForExistence(timeout: 10), "the player didn't open")
        XCTAssertTrue(readout.label.hasSuffix("tok=\(number)"), "the copy readout has no token: \(readout.label)")
    }

    private func close() {
        if !app.buttons["Close player"].firstMatch.exists {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        }
        let button = app.buttons["Close player"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "no Close player")
        button.tap()
    }

    private func state(_ wanted: String, within seconds: Double) -> Bool {
        let readout = app.staticTexts["debug-live-state"].firstMatch
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if readout.exists, readout.label == wanted { return true }
            usleep(250_000)
        }
        return false
    }

    private func failure() -> String {
        app.staticTexts["debug-live-fail"].firstMatch.label
    }

    private func testServer() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["DEBUG_EMBY"],
              let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let address = json["serverURL"] as? String else { return nil }
        return URL(string: address)
    }

    private func configure(_ server: URL, _ settings: [String: String]) {
        let url = server.appending(path: "mock/set").appending(queryItems: settings.map { URLQueryItem(name: $0.key, value: $0.value) })
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 10)
    }
}

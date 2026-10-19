import XCTest

/// Live TV when a stream starts slowly, is cut, refused or dead, and when
/// the app leaves with live TV paused (.audit/live-perf/fix-plan.md). Needs
/// the test film (OPENIPTV_MOCK_VIDEO) on the test server.
final class LiveRecoveryTests: XCTestCase {
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
            addTeardownBlock { [self] in configure(server, ["reset": "1"]) }
        }
        XCUIDevice.shared.orientation = .portrait
    }

    func testSlowGameStartPlays() throws {
        try launch(["sports": "1", "live_delay": "17"])
        openGame("Jaguars")
        XCTAssertTrue(liveCopy().hasPrefix("NFL 01"), "the game didn't open on its best channel: \(liveCopy())")
        let deadline = Date().addingTimeInterval(26)
        while state() != "playing", Date() < deadline {
            XCTAssertNotEqual(state(), "failed", "gave up on a game channel that takes 17 s to start")
            XCTAssertTrue(liveCopy().hasPrefix("NFL 01"), "left a game channel that takes 17 s to start: \(liveCopy())")
            usleep(250_000)
        }
        XCTAssertEqual(state(), "playing", "a game channel that takes 17 s to start didn't play")
    }

    func testDeadGameGivesUp() throws {
        try launch(["pick": "1", "dead_live": "3021"])
        openGame("Rangers")
        XCTAssertTrue(liveCopy().hasSuffix("tok=3021"), "the game didn't open on its channel: \(liveCopy())")
        XCTAssertTrue(waitForState("failed", within: 28), "a game channel that sends nothing never gave up")
    }

    func testCutReconnectsInPlace() throws {
        let server = try launch(["live_cut": "12"])
        openChannel(7)
        XCTAssertTrue(waitForState("playing", within: 15), "channel 7 didn't play")
        XCTAssertTrue(app.buttons["Close player"].firstMatch.waitForNonExistence(timeout: 8), "the controls didn't hide")
        let since = try markTime(server)
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            XCTAssertEqual(state(), "playing", "the stream started over after a cut")
            XCTAssertFalse(app.buttons["Close player"].firstMatch.exists, "the controls came up after a cut")
            usleep(250_000)
        }
        let opens = try liveRequests(server, since: since).filter { $0.id == "7" }.count
        XCTAssertGreaterThanOrEqual(opens, 2, "the stream wasn't cut and opened again: \(opens) opens")
    }

    func testCutsAreCapped() throws {
        let server = try launch(["hd_copy": "1", "live_chunked": "1", "live_cut": "3", "live_cut_reset": "1", "live_cut_ids": "951"])
        let since = try markTime(server)
        openChannel(1)
        XCTAssertTrue(liveCopy().hasSuffix("tok=951"), "Channel 1 didn't open on its HD copy: \(liveCopy())")
        let deadline = Date().addingTimeInterval(60)
        while !liveCopy().hasSuffix("tok=1"), Date() < deadline { usleep(250_000) }
        XCTAssertTrue(liveCopy().hasSuffix("tok=1"), "still on the copy that keeps cutting after 60 s: \(liveCopy())")
        let cut = try liveRequests(server, since: since).filter { $0.id == "951" }.count
        XCTAssertGreaterThanOrEqual(cut, 3, "the copy that cuts wasn't opened again: \(cut) opens")
        XCTAssertLessThanOrEqual(cut, 5, "the copy that keeps cutting was opened \(cut) times")
        XCTAssertTrue(waitForState("playing", within: 15), "the next copy didn't play")
    }

    func testDeadCopyRemembered() throws {
        app.launchEnvironment["OPENREEL_DEBUG_LIVE_START_LIMIT"] = "3"
        let server = try launch(["hd_copy": "1", "dead_live": "951"])
        openChannel(1)
        XCTAssertTrue(liveCopy().hasSuffix("tok=951"), "Channel 1 didn't open on its HD copy: \(liveCopy())")
        XCTAssertTrue(waitForState("playing", within: 15), "the next copy didn't play")
        XCTAssertTrue(liveCopy().hasSuffix("tok=1"), "played on \(liveCopy())")
        close()

        let since = try markTime(server)
        openChannel(1)
        XCTAssertTrue(liveCopy().hasSuffix("tok=1"), "the copy that didn't play was tried first again: \(liveCopy())")
        XCTAssertTrue(waitForState("playing", within: 10), "Channel 1 didn't play")
        let dead = try liveRequests(server, since: since).filter { $0.id == "951" }.count
        XCTAssertEqual(dead, 0, "the copy that didn't play was asked for again")
    }

    func testLive404MovesOnAtOnce() throws {
        try launch(["hd_copy": "1", "live_status": "404", "live_status_ids": "951"])
        let tapped = openChannel(1)
        XCTAssertTrue(waitForState("playing", within: 15), "the next copy didn't play")
        XCTAssertTrue(liveCopy().hasSuffix("tok=1"), "played on \(liveCopy())")
        XCTAssertLessThan(Date().timeIntervalSince(tapped), 4, "the next copy waited after a 404")
    }

    func testLive503RetriesSameCopy() throws {
        let server = try launch(["hd_copy": "1", "live_status": "503", "live_status_ids": "951"])
        let since = try markTime(server)
        openChannel(1)
        XCTAssertTrue(waitForState("playing", within: 15), "no copy played")
        XCTAssertTrue(liveCopy().hasSuffix("tok=1"), "played on \(liveCopy())")
        let requests = try liveRequests(server, since: since)
        let refused = requests.filter { $0.id == "951" }
        XCTAssertEqual(refused.count, 2, "the copy that answered 503 wasn't asked once more: \(refused.count) requests")
        let gap = refused[1].t - refused[0].t
        XCTAssertTrue((0.7...3).contains(gap), "asked again \(gap) s after the 503")
        let next = try XCTUnwrap(requests.first { $0.id == "1" }, "the next copy wasn't asked for")
        XCTAssertGreaterThan(next.t, refused[1].t, "the next copy was asked for before the second try")
    }

    func testLive429Stops() throws {
        let server = try launch(["hd_copy": "1", "live_status": "429"])
        let since = try markTime(server)
        openChannel(1)
        XCTAssertTrue(waitForState("failed", within: 15), "a refusal for too many requests didn't stop")
        sleep(2)
        let ids = try liveRequests(server, since: since).map(\.id)
        XCTAssertEqual(ids, ["951"], "asked again after a 429")
        close()
        let row = channelRow(1)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the list went")
        XCTAssertFalse(row.label.contains("Didn’t play"), "a 429 marked the channel: \(row.label)")
    }

    func testNoConnectionIsNotMarked() throws {
        let server = try launch(["hd_copy": "1", "live_refuse": "1"])
        let since = try markTime(server)
        openChannel(1)
        XCTAssertTrue(waitForState("failed", within: 15), "a refused connection didn't stop")
        sleep(2)
        let ids = try liveRequests(server, since: since).map(\.id)
        XCTAssertEqual(ids, ["951"], "another copy was tried with no connection")
        close()
        let row = channelRow(1)
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the list went")
        XCTAssertFalse(row.label.contains("Didn’t play"), "no connection marked the channel: \(row.label)")
    }

    func testRefusedRightAfterZap() throws {
        try launch(["live_max_connections": "1", "live_linger": "1"])
        openChannel(2)
        XCTAssertTrue(waitForState("playing", within: 15), "channel 2 didn't play")
        showControls()
        app.buttons["More"].firstMatch.tap()
        let next = app.buttons["Next Channel"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5), "no Next Channel in the menu")
        next.tap()
        let changed = Date().addingTimeInterval(5)
        while liveCopy().hasSuffix("tok=2"), Date() < changed { usleep(250_000) }
        XCTAssertFalse(liveCopy().hasSuffix("tok=2"), "the channel didn't change")
        let deadline = Date().addingTimeInterval(15)
        while state() != "playing", Date() < deadline {
            XCTAssertNotEqual(state(), "failed", "a channel refused right after the switch gave up: \(liveCopy())")
            usleep(250_000)
        }
        XCTAssertEqual(state(), "playing", "the next channel didn't play: \(liveCopy())")
    }

    func testPausedInBackgroundFreesTheAccount() throws {
        let server = try launch(["live_max_connections": "1", "live_linger": "0"])
        openChannel(4)
        XCTAssertTrue(waitForState("playing", within: 15), "channel 4 didn't play")
        showControls()
        app.buttons["Pause"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Play"].firstMatch.waitForExistence(timeout: 3), "live TV didn't pause")
        XCTAssertEqual(try activeConnections(server), "1", "the paused stream isn't open")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(activeConnections(server, become: "0", within: 8), "live TV paused in the background still holds the connection")
        app.activate()
        XCTAssertTrue(waitForState("playing", within: 20), "live TV didn't open again on return")
        XCTAssertTrue(liveCopy().hasSuffix("tok=4"), "came back on \(liveCopy())")
    }

    func testPlayingInBackgroundKeepsTheStream() throws {
        let server = try launch(["live_max_connections": "1", "live_linger": "0"])
        openChannel(4)
        XCTAssertTrue(waitForState("playing", within: 15), "channel 4 didn't play")
        XCUIDevice.shared.press(.home)
        sleep(6)
        XCTAssertEqual(try activeConnections(server), "1", "live TV playing in the background lost its stream")
        app.activate()
        XCTAssertEqual(state(), "playing", "live TV stopped in the background")
    }

    // MARK: Helpers

    @discardableResult
    private func launch(_ switches: [String: String]) throws -> URL {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["reset": "1"])
        configure(server, switches)
        app.launchArguments = ["-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        let tab = app.tabBars.buttons["Live TV"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 15), "no Live TV tab")
        tab.tap()
        return server
    }

    private func channelRow(_ number: Int) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label MATCHES %@", "(?s).*Channel \(number)\\b.*")).firstMatch
    }

    @discardableResult
    private func openChannel(_ number: Int) -> Date {
        let row = channelRow(number)
        for _ in 0..<3 where !row.waitForExistence(timeout: 10) { app.swipeUp() }
        XCTAssertTrue(row.exists, "no Channel \(number) in the list")
        let tapped = Date()
        row.tap()
        XCTAssertTrue(app.staticTexts["debug-live-copy"].firstMatch.waitForExistence(timeout: 10), "the player didn't open")
        return tapped
    }

    /// Live TV → Sports → the game.
    private func openGame(_ team: String) {
        let sports = app.buttons["Sports"].firstMatch
        if sports.waitForExistence(timeout: 10) { sports.tap() }
        let game = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", team)).firstMatch
        XCTAssertTrue(game.waitForExistence(timeout: 15), "the game isn't in Sports")
        game.tap()
        XCTAssertTrue(app.staticTexts["debug-live-copy"].firstMatch.waitForExistence(timeout: 10), "the player didn't open")
    }

    /// By the button's place: the controls can hide between finding it and
    /// tapping it.
    private func close() {
        let button = app.buttons["Close player"].firstMatch
        let player = app.staticTexts["debug-live-state"].firstMatch
        for _ in 0..<4 where player.exists {
            if !button.exists { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap() }
            if button.waitForExistence(timeout: 2) {
                let frame = button.frame
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
            }
            _ = player.waitForNonExistence(timeout: 3)
        }
        XCTAssertFalse(player.exists, "the player didn't close")
    }

    private func showControls() {
        guard !app.buttons["Close player"].firstMatch.exists else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        _ = app.buttons["Close player"].firstMatch.waitForExistence(timeout: 3)
    }

    private func state() -> String {
        app.staticTexts["debug-live-state"].firstMatch.label
    }

    private func liveCopy() -> String {
        app.staticTexts["debug-live-copy"].firstMatch.label
    }

    private func waitForState(_ wanted: String, within seconds: Double) -> Bool {
        let readout = app.staticTexts["debug-live-state"].firstMatch
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if readout.exists, readout.label == wanted { return true }
            usleep(250_000)
        }
        return false
    }

    private func testServer() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["DEBUG_EMBY"],
              let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let address = json["serverURL"] as? String else { return nil }
        return URL(string: address)
    }

    private func markTime(_ server: URL) throws -> Double {
        let clock: [String: Double] = try answer(server.appending(path: "mock/mark"))
        return try XCTUnwrap(clock["t"], "the test server's clock has no time")
    }

    /// The live streams asked for since `since`, in order: the channel's
    /// stream id and the test server's time.
    private func liveRequests(_ server: URL, since: Double) throws -> [(id: String, t: Double)] {
        let url = server.appending(path: "mock/live_requests").appending(queryItems: [.init(name: "since", value: String(since))])
        let requests: [String: [[String: Any]]] = try answer(url)
        let items = try XCTUnwrap(requests["items"], "the test server's request list has no items")
        return try items.map { (try XCTUnwrap($0["id"] as? String), try XCTUnwrap($0["t"] as? Double)) }
    }

    /// The account's streams open now, as the test server's account answer
    /// counts them.
    private func activeConnections(_ server: URL) throws -> String {
        let url = server.appending(path: "player_api.php").appending(queryItems: [.init(name: "username", value: "u"), .init(name: "password", value: "p")])
        let account: [String: Any] = try answer(url)
        let user = try XCTUnwrap(account["user_info"] as? [String: Any], "the account answer has no user_info")
        return try XCTUnwrap(user["active_cons"] as? String, "the account answer has no active_cons")
    }

    private func activeConnections(_ server: URL, become wanted: String, within seconds: Double) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if (try? activeConnections(server)) == wanted { return true }
            usleep(500_000)
        }
        return false
    }

    private func answer<Answer>(_ url: URL) throws -> Answer {
        var data: Data?
        var status: Int?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { body, response, _ in
            data = body
            status = (response as? HTTPURLResponse)?.statusCode
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 10)
        let body = try XCTUnwrap(status == 200 ? data : nil, "the test server's answer to \(url.path): status \(status.map(String.init) ?? "none")")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? Answer, "the test server's answer to \(url.path) isn't the JSON expected")
    }

    private func configure(_ server: URL, _ settings: [String: String]) {
        let url = server.appending(path: "mock/set").appending(queryItems: settings.map { URLQueryItem(name: $0.key, value: $0.value) })
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 10)
    }
}

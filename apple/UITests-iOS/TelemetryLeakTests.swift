import XCTest

final class TelemetryLeakTests: XCTestCase {
    private let app = XCUIApplication()
    private var server: URL!
    private let metrics = ["film.start.first_tap", "film.jump.forward_10s", "film.jump.back_10s", "live.start", "live.switch"]
    private let problems = ["live_did_not_start"]
    private let sendable: Set<String> = ["event", "trace_metric", "session", "client_report"]

    override func setUpWithError() throws {
        continueAfterFailure = true
        server = try XCTUnwrap(testServer(), "no test server")
        app.launchEnvironment["OPENREEL_DEBUG_EMBY"] = ProcessInfo.processInfo.environment["DEBUG_EMBY"]
        configure(["reset": "1"])
        XCTAssertEqual(control("mock/iptv_login", ["fresh": "1"])["set"] as? Bool, true, "the test server made up no login")
        app.launchEnvironment["OPENREEL_DEBUG_IPTV_URL"] = server.appending(path: "mock/iptv_source").absoluteString
        app.launchEnvironment["OPENREEL_DEBUG_LIVE_START_LIMIT"] = "8"
        app.launchEnvironment["OPENREEL_DEBUG_SENTRY_DSN"] = dsn
        app.launchArguments = ["-freshLineup", "YES", "-forgetWatchOnPicks", "YES", "-debugSearch", "Oppenheimer"]
        addTeardownBlock { [self] in configure(["reset": "1"]) }
        XCUIDevice.shared.orientation = .portrait
    }

    func testPlayingJumpingAndSwitchingSendTimingsWithNothingOfTheLoginServerOrTitles() {
        let since = control("mock/mark")["t"] as? Double ?? 0
        app.launch()
        playFilm("Oppenheimer")
        sleep(4)
        tap("Forward 10 seconds")
        sleep(4)
        tap("Back 10 seconds")
        sleep(4)
        closeFilm()
        openLiveTab()
        openChannel(2)
        sleep(8)
        nextChannel()
        sleep(8)
        closeChannel()
        configure(["live_status": "404", "live_status_ids": "3"])
        openChannel(3)
        sleep(10)
        closeChannel()
        configure(["live_status": "0"])
        XCUIDevice.shared.press(.home)
        let seen = waitForSeen(since) { seen in
            self.metrics.allSatisfy { (seen.metrics[$0] ?? 0) > 0 } && self.problems.allSatisfy { (seen.problems[$0] ?? 0) > 0 }
        }
        for name in metrics { XCTAssertGreaterThan(seen.metrics[name] ?? 0, 0, "no \(name) timing arrived") }
        for kind in problems { XCTAssertGreaterThan(seen.problems[kind] ?? 0, 0, "no \(kind) problem arrived") }
        assertNothingLeaked(seen)
    }

    func testACrashReportCarriesNothingOfTheServer() throws {
        let since = control("mock/mark")["t"] as? Double ?? 0
        let place = server.appending(path: "live/one/two/3.ts").appending(queryItems: [URLQueryItem(name: "probe", value: "1")])
        app.launchEnvironment["OPENREEL_DEBUG_TELEMETRY_CRASH"] = place.absoluteString
        app.launch()
        sleep(8)
        app.launchEnvironment["OPENREEL_DEBUG_TELEMETRY_CRASH"] = nil
        app.launch()
        let seen = waitForSeen(since) { $0.crashes > 0 }
        XCTAssertGreaterThan(seen.crashes, 0, "no crash report arrived")
        assertNothingLeaked(seen)
    }

    private struct Seen {
        var envelopes = 0
        var items: [String: Int] = [:]
        var crashes = 0
        var metrics: [String: Int] = [:]
        var problems: [String: Int] = [:]
        var leaks: [String: Int] = [:]
    }

    private func waitForSeen(_ since: Double, until done: (Seen) -> Bool) -> Seen {
        var seen = Seen()
        for _ in 0..<12 {
            sleep(5)
            seen = sentrySeen(since)
            if done(seen) { break }
        }
        print("SENTRY envelopes=\(seen.envelopes) crashes=\(seen.crashes) items=\(seen.items.sorted { $0.key < $1.key }) "
            + "metrics=\(seen.metrics.sorted { $0.key < $1.key }) problems=\(seen.problems) leaks=\(seen.leaks.sorted { $0.key < $1.key })")
        return seen
    }

    private func assertNothingLeaked(_ seen: Seen) {
        XCTAssertGreaterThan(seen.envelopes, 0, "nothing reached the capture")
        XCTAssertEqual(seen.leaks.filter { $0.value != 0 }.map(\.key).sorted(), [], "words that must never go out went out")
        XCTAssertGreaterThan(seen.leaks.count, 8, "the capture didn't count every leak word")
        XCTAssertEqual(Set(seen.items.keys).subtracting(sendable).sorted(), [], "items that must never go out went out")
    }

    private func sentrySeen(_ since: Double) -> Seen {
        let found = control("mock/sentry_seen", ["since": String(since), "metrics": metrics.joined(separator: ","),
                                                 "problems": problems.joined(separator: ",")])
        return Seen(envelopes: found["envelopes"] as? Int ?? 0, items: found["items"] as? [String: Int] ?? [:],
                    crashes: found["crashes"] as? Int ?? 0,
                    metrics: found["metrics"] as? [String: Int] ?? [:], problems: found["problems"] as? [String: Int] ?? [:],
                    leaks: found["leaks"] as? [String: Int] ?? [:])
    }

    private var dsn: String {
        var parts = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        parts.user = "openreeltest"
        parts.path = "/1"
        return parts.url!.absoluteString
    }

    private func playFilm(_ film: String) {
        let tab = app.tabBars.buttons["Search"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "no Search tab")
        tab.tap()
        let result = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", film)).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 30), "no film in the results")
        result.tap()
        let play = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Play' OR label BEGINSWITH 'Resume' OR label BEGINSWITH 'Continue'")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 20), "the film's page has no Play")
        play.tap()
        XCTAssertTrue(app.staticTexts["debug-position"].firstMatch.waitForExistence(timeout: 30), "the film didn't open")
    }

    private func tap(_ label: String) {
        showControls()
        let button = app.buttons[label].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "no \(label)")
        button.tap()
    }

    private func closeFilm() {
        let player = app.staticTexts["debug-position"].firstMatch
        let close = app.buttons["Close player"].firstMatch
        for _ in 0..<3 where player.exists {
            showControls()
            if close.isHittable { close.tap() }
            _ = player.waitForNonExistence(timeout: 3)
        }
        XCTAssertFalse(player.exists, "the film didn't close")
    }

    private func openLiveTab() {
        let tab = app.tabBars.buttons["Live TV"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 15), "no Live TV tab")
        tab.tap()
        XCTAssertTrue(channelRow(2).waitForExistence(timeout: 30), "the lineup didn't load")
    }

    private func channelRow(_ number: Int) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label MATCHES %@", "(?s).*Channel \(number)\\b.*")).firstMatch
    }

    private func openChannel(_ number: Int) {
        let row = channelRow(number)
        for _ in 0..<4 where !row.waitForExistence(timeout: 5) { app.swipeUp() }
        XCTAssertTrue(row.exists, "no channel row")
        row.tap()
        XCTAssertTrue(app.staticTexts["debug-live-copy"].firstMatch.waitForExistence(timeout: 10), "the live player didn't open")
    }

    private func nextChannel() {
        tap("More")
        let next = app.buttons["Next Channel"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5), "no Next Channel in the menu")
        next.tap()
    }

    private func closeChannel() {
        let player = app.staticTexts["debug-live-copy"].firstMatch
        let close = app.buttons["Close player"].firstMatch
        for _ in 0..<4 where player.exists {
            showControls()
            if close.waitForExistence(timeout: 2) {
                let frame = close.frame
                app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: frame.midX, dy: frame.midY)).tap()
            }
            _ = player.waitForNonExistence(timeout: 3)
        }
        XCTAssertFalse(player.exists, "the live player didn't close")
    }

    private func showControls() {
        guard !app.buttons["Close player"].firstMatch.isHittable else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        _ = app.buttons["Close player"].firstMatch.waitForExistence(timeout: 3)
    }

    private func configure(_ settings: [String: String]) {
        _ = control("mock/set", settings)
    }

    private func control(_ path: String, _ settings: [String: String] = [:]) -> [String: Any] {
        let url = server.appending(path: path).appending(queryItems: settings.map { URLQueryItem(name: $0.key, value: $0.value) })
        var data: Data?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { body, _, _ in
            data = body
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 60)
        return data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    private func testServer() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["DEBUG_EMBY"],
              let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let address = json["serverURL"] as? String else { return nil }
        return URL(string: address)
    }
}

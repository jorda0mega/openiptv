import XCTest

final class IPTVLoginLeakTests: XCTestCase {
    private let app = XCUIApplication()
    private var server: URL!
    private var results: [(step: String, counts: [Int])] = []

    override func setUpWithError() throws {
        continueAfterFailure = true
        server = try XCTUnwrap(testServer(), "no test server")
        if let account = ProcessInfo.processInfo.environment["DEBUG_EMBY"] {
            app.launchEnvironment["OPENREEL_DEBUG_EMBY"] = account
        }
        configure(["reset": "1"])
        XCTAssertEqual(control("mock/iptv_login", ["fresh": "1"])["set"] as? Bool, true, "the test server made up no login")
        app.launchEnvironment["OPENREEL_DEBUG_IPTV_URL"] = server.appending(path: "mock/iptv_source").absoluteString
        app.launchEnvironment["OPENREEL_DEBUG_LIVE_START_LIMIT"] = "8"
        app.launchArguments = ["-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        addTeardownBlock { [self] in configure(["reset": "1"]) }
        XCUIDevice.shared.orientation = .portrait
    }

    func testNoIPTVLoginInTheLogOrAnAPIAddress() {
        step("launch and lineup") {
            app.launch()
            let tab = app.tabBars.buttons["Live TV"].firstMatch
            XCTAssertTrue(tab.waitForExistence(timeout: 15), "no Live TV tab")
            tab.tap()
            XCTAssertTrue(channelRow(2).waitForExistence(timeout: 30), "the lineup didn't load")
            sleep(5)
        }
        configure(["xtream_latency": "3"])
        for (status, channel) in [("404", 3), ("403", 4), ("503", 5), ("429", 6)] {
            step("channel answers \(status)") {
                configure(["live_status": status, "live_status_ids": String(channel)])
                openChannel(channel)
                sleep(10)
                close()
                configure(["live_status": "0"])
            }
        }
        step("slow start") {
            configure(["live_delay": "6"])
            openChannel(7)
            sleep(12)
            close()
            configure(["live_delay": "0"])
        }
        step("cut") {
            configure(["live_cut": "5"])
            openChannel(8)
            sleep(16)
            close()
            configure(["live_cut": "0"])
        }
        step("zap away mid-start") {
            configure(["live_delay": "8"])
            openChannel(9)
            sleep(2)
            nextChannel()
            sleep(2)
            nextChannel()
            sleep(3)
            close()
            configure(["live_delay": "0"])
        }
        step("background and back") {
            openChannel(12)
            sleep(8)
            XCUIDevice.shared.press(.home)
            sleep(5)
            app.activate()
            sleep(6)
            showControls()
            app.buttons["Pause"].firstMatch.tap()
            XCUIDevice.shared.press(.home)
            sleep(6)
            app.activate()
            sleep(8)
            close()
        }
        step("closing the player") {
            openChannel(13)
            sleep(1)
            close()
            openChannel(14)
            sleep(8)
            close()
        }
        step("provider API times out") {
            configure(["xtream_latency": "24"])
            openChannel(16)
            sleep(28)
            close()
            configure(["xtream_latency": "3"])
        }
        step("provider drops every connection") {
            openChannel(17)
            sleep(1)
            _ = control("mock/close_connections", ["abrupt": "1"])
            _ = control("mock/down", ["seconds": "10"])
            sleep(14)
            close()
        }
        let leaked = results.filter { $0.counts.contains { $0 != 0 } }.map(\.step)
        XCTAssertEqual(leaked, [], "the made-up IPTV login reached the log or an API address: \(results)")
    }

    private func step(_ name: String, _ body: () -> Void) {
        let since = mark()
        body()
        sleep(3)
        let found = control("mock/iptv_leaks", ["since": String(since)])
        XCTAssertEqual(found["log_read"] as? Bool, true, "the simulator's log wasn't read after \(name)")
        let counts = ["log_username", "log_password", "address_username", "address_password"].map { found[$0] as? Int ?? -1 }
        print("LEAK \(name): log username=\(counts[0]) password=\(counts[1]); "
            + "API addresses username=\(counts[2]) password=\(counts[3]) of \(found["requests"] as? Int ?? -1) requests")
        results.append((name, counts))
    }

    private func channelRow(_ number: Int) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label MATCHES %@", "(?s).*Channel \(number)\\b.*")).firstMatch
    }

    private func openChannel(_ number: Int) {
        let row = channelRow(number)
        for _ in 0..<4 where !row.waitForExistence(timeout: 5) { app.swipeUp() }
        XCTAssertTrue(row.exists, "no Channel \(number) in the list")
        row.tap()
        XCTAssertTrue(app.staticTexts["debug-live-copy"].firstMatch.waitForExistence(timeout: 10), "the player didn't open")
    }

    private func nextChannel() {
        showControls()
        app.buttons["More"].firstMatch.tap()
        let next = app.buttons["Next Channel"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5), "no Next Channel in the menu")
        next.tap()
    }

    private func showControls() {
        guard !app.buttons["Close player"].firstMatch.exists else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        _ = app.buttons["Close player"].firstMatch.waitForExistence(timeout: 3)
    }

    private func close() {
        let button = app.buttons["Close player"].firstMatch
        let player = app.staticTexts["debug-live-copy"].firstMatch
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

    private func mark() -> Double {
        control("mock/mark")["t"] as? Double ?? 0
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

import XCTest

final class IPTVLoginLeakTests: XCTestCase {
    private let app = XCUIApplication()
    private let remote = XCUIRemote.shared
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
        app.launchArguments = ["-tvTab", "live", "-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        addTeardownBlock { [self] in configure(["reset": "1"]) }
    }

    func testNoIPTVLoginInTheLogOrAnAPIAddress() {
        step("launch and lineup") {
            app.launch()
            sleep(12)
            remote.press(.down)
            sleep(2)
            XCTAssertTrue(focusedLabel().contains("Channel"), "no channel card in Live TV: \(focusedLabel())")
            openPlayer()
            sleep(6)
        }
        configure(["xtream_latency": "3"])
        for status in ["404", "403", "503", "429"] {
            step("channel answers \(status)") {
                configure(["live_status": status])
                zap()
                sleep(10)
                configure(["live_status": "0"])
            }
        }
        step("slow start") {
            configure(["live_delay": "6"])
            zap()
            sleep(12)
            configure(["live_delay": "0"])
        }
        step("cut") {
            configure(["live_cut": "5"])
            zap()
            sleep(16)
            configure(["live_cut": "0"])
        }
        step("zap away mid-start") {
            configure(["live_delay": "8"])
            zap()
            sleep(2)
            zap()
            sleep(2)
            zap()
            sleep(3)
            configure(["live_delay": "0"])
        }
        step("background and back") {
            zap()
            sleep(8)
            remote.press(.home)
            sleep(5)
            app.activate()
            sleep(6)
            remote.press(.playPause)
            sleep(1)
            remote.press(.home)
            sleep(6)
            app.activate()
            sleep(8)
        }
        step("closing the player") {
            leavePlayer()
            openPlayer()
            sleep(1)
            leavePlayer()
            openPlayer()
            sleep(8)
            leavePlayer()
            openPlayer()
        }
        step("provider API times out") {
            configure(["xtream_latency": "24"])
            zap()
            sleep(28)
            configure(["xtream_latency": "3"])
        }
        step("provider drops every connection") {
            zap()
            sleep(1)
            _ = control("mock/close_connections", ["abrupt": "1"])
            _ = control("mock/down", ["seconds": "10"])
            sleep(14)
            leavePlayer()
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

    private var player: XCUIElement {
        app.staticTexts["debug-live-copy"].firstMatch
    }

    private func focusedLabel() -> String {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        return element.exists ? element.label : ""
    }

    private func openPlayer() {
        remote.press(.select)
        XCTAssertTrue(player.waitForExistence(timeout: 10), "the player didn't open from \(focusedLabel())")
    }

    private func zap() {
        let before = player.label
        remote.press(.down)
        let deadline = Date().addingTimeInterval(5)
        while player.label == before, Date() < deadline { usleep(250_000) }
        XCTAssertNotEqual(player.label, before, "Down didn't move to the next channel")
    }

    private func leavePlayer() {
        for _ in 0..<3 where player.exists {
            remote.press(.menu)
            _ = player.waitForNonExistence(timeout: 3)
        }
        XCTAssertFalse(player.exists, "the player didn't close")
        sleep(1)
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

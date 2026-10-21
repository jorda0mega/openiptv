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
            XCTAssertNotNil(focusedChannel(), "no channel card in Live TV: \(focusedLabel())")
        }
        for status in ["404", "403", "503", "429"] {
            step("channel answers \(status)") {
                let channel = nextCard()
                configure(["live_status": status, "live_status_ids": channel])
                remote.press(.select)
                sleep(10)
                leavePlayer()
                configure(["live_status": "0"])
            }
        }
        step("slow start") {
            _ = nextCard()
            configure(["live_delay": "6"])
            remote.press(.select)
            sleep(12)
            leavePlayer()
            configure(["live_delay": "0"])
        }
        step("cut") {
            _ = nextCard()
            configure(["live_cut": "5"])
            remote.press(.select)
            sleep(16)
            leavePlayer()
            configure(["live_cut": "0"])
        }
        step("zap away mid-start") {
            _ = nextCard()
            configure(["live_delay": "8"])
            remote.press(.select)
            sleep(2)
            remote.press(.down)
            sleep(2)
            remote.press(.down)
            sleep(3)
            leavePlayer()
            configure(["live_delay": "0"])
        }
        step("background and back") {
            _ = nextCard()
            remote.press(.select)
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
            leavePlayer()
        }
        step("closing the player") {
            _ = nextCard()
            remote.press(.select)
            sleep(1)
            leavePlayer()
            _ = nextCard()
            remote.press(.select)
            sleep(8)
            leavePlayer()
        }
        step("provider drops every connection") {
            _ = nextCard()
            remote.press(.select)
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

    private func focusedLabel() -> String {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        return element.exists ? element.label : ""
    }

    private func focusedChannel() -> String? {
        focusedLabel().firstMatch(of: #/Channel (\d+)/#).map { String($0.1) }
    }

    private func nextCard() -> String {
        let before = focusedChannel()
        remote.press(.right)
        sleep(1)
        let channel = focusedChannel()
        XCTAssertNotNil(channel, "focus left the channel cards: \(focusedLabel())")
        XCTAssertNotEqual(channel, before, "the next card is the same channel")
        return channel ?? ""
    }

    private func leavePlayer() {
        let player = app.staticTexts["debug-live-copy"].firstMatch
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

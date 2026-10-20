import XCTest

/// iPhone: no connection the app opens carries the Emby key in its address
/// (the system logs the address of a request that fails or is stopped),
/// and the app opens no websocket to Emby (Emby takes the websocket's key
/// only in its address). Against the test server, with its own fake key.
final class KeyLeakTests: XCTestCase {
    private let app = XCUIApplication()

    private func get(_ url: URL) -> Data? {
        var data: Data?
        let done = expectation(description: url.path())
        URLSession.shared.dataTask(with: url) { answer, _, _ in
            data = answer
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 60)
        return data
    }

    private func control(_ server: URL, _ path: String, _ settings: [String: String] = [:]) -> [String: Any] {
        let url = server.appending(path: path).appending(queryItems: settings.map { URLQueryItem(name: $0.key, value: $0.value) })
        return get(url).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    /// The key is in no address in the simulator's log, whatever happens
    /// to the app's connections: just opened, closed by the server, dropped
    /// by a server gone down, closed as the app goes to the background and
    /// back, and at sign-out. Each count is the test server's own key (not
    /// a login) in the last five minutes of the log. The account comes from
    /// a helper's address (TEST_RUNNER_LEAK_FEED), not the launch
    /// environment, which the log records. Regression: the websocket
    /// carried the key in its address, and a server gone down wrote it to
    /// the log (4 lines).
    func testNoConnectionCarriesTheKeyInItsAddress() throws {
        let feed = try XCTUnwrap(ProcessInfo.processInfo.environment["LEAK_FEED"].flatMap(URL.init(string:)), "needs TEST_RUNNER_LEAK_FEED")
        let server = try XCTUnwrap(ProcessInfo.processInfo.environment["LEAK_SERVER"].flatMap(URL.init(string:)), "needs TEST_RUNNER_LEAK_SERVER")
        _ = control(server, "mock/set", ["reset": "1"])
        app.launchEnvironment["OPENREEL_DEBUG_EMBY_URL"] = feed.appending(path: "emby").absoluteString
        var counts: [(String, Int)] = []
        func count(_ step: String) {
            let found = control(server, "mock/log_matches")
            XCTAssertEqual(found["read"] as? Bool, true, "the log wasn't read after \(step)")
            let matches = found["count"] as? Int ?? -1
            counts.append((step, matches))
            print("LEAK \(step): \(matches)")
        }
        app.launch()
        sleep(10)
        count("opened")
        _ = control(server, "mock/close_connections")
        sleep(4)
        count("closed by the server")
        _ = control(server, "mock/close_connections", ["abrupt": "1"])
        _ = control(server, "mock/down", ["seconds": "12"])
        sleep(14)
        count("server down")
        XCUIDevice.shared.press(.home)
        sleep(5)
        app.activate()
        sleep(5)
        count("background and back")
        app.buttons["Settings"].firstMatch.tap()
        let emby = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Emby'")).firstMatch
        XCTAssertTrue(emby.waitForExistence(timeout: 5), "no Emby in Settings")
        emby.tap()
        let signOut = app.buttons["Sign out"].firstMatch
        XCTAssertTrue(signOut.waitForExistence(timeout: 5), "no Sign out")
        signOut.tap()
        sleep(5)
        count("signed out")
        let asked = (control(server, "mock/key_checks")["items"] as? [String]) ?? []
        XCTAssertFalse(asked.contains("websocket"), "the app opened Emby's websocket")
        XCTAssertEqual(counts.filter { $0.1 != 0 }.map(\.0), [], "the key reached the log: \(counts)")
    }
}

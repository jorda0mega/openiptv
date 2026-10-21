import XCTest

final class PrepareAheadTests: XCTestCase {
    private let app = XCUIApplication()
    private let remote = XCUIRemote.shared

    override func setUpWithError() throws {
        continueAfterFailure = false
        if let account = ProcessInfo.processInfo.environment["DEBUG_EMBY"] {
            app.launchEnvironment["OPENREEL_DEBUG_EMBY"] = account
        }
    }

    func testContinueWatchingFocusGetsTheFilmReady() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["reset": "1"])
        configure(server, ["reference_delay": "90"])
        defer { configure(server, ["reset": "1"]) }
        app.launchArguments = ["-tvTab", "home", "-forgetTrackChoices", "YES", "-forgetServerSubtitles", "YES",
                               "-cacheFolder", "prepare-ahead-\(UUID())"]
        app.launch()
        sleep(8)
        let item = "e203"
        let plannedBefore = playbackInfoRequests(server).filter { $0 == item }.count
        for _ in 0..<5 where !focused().contains("id='continue-") {
            remote.press(.down)
            sleep(1)
        }
        XCTAssertTrue(focused().contains("id='continue-s1'"), "not on Continue Watching's first card: \(focused())")
        sleep(2)
        let planned = playbackInfoRequests(server).filter { $0 == item }.count
        XCTAssertGreaterThan(planned, plannedBefore, "no plan: \(playbackInfoRequests(server))")
        XCTAssertTrue(videoRequests(server).contains(item), "its file start wasn't fetched: \(videoRequests(server))")
        XCTAssertEqual(subtitleRequests(server).filter { $0 == "\(item):4" }.count, 1, "its English track wasn't asked for: \(subtitleRequests(server))")

        remote.press(.select)
        XCTAssertTrue(app.staticTexts["debug-item"].firstMatch.waitForExistence(timeout: 20), "the player didn't open")
        sleep(4)
        XCTAssertEqual(playbackInfoRequests(server).filter { $0 == item }.count, planned, "Select asked again how to play it")
        XCTAssertEqual(subtitleRequests(server).filter { $0 == "\(item):4" }.count, 1, "Select asked again for the English track")
    }

    private func focused() -> String {
        let element = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        guard element.exists else { return "nothing" }
        return "\(element.elementType) label='\(element.label)' id='\(element.identifier)'"
    }

    private func playbackInfoRequests(_ server: URL) -> [String] { listed(server, "mock/playbackinfo_requests") }
    private func videoRequests(_ server: URL) -> [String] { listed(server, "mock/video_requests") }
    private func subtitleRequests(_ server: URL) -> [String] { listed(server, "mock/subtitle_requests") }

    private func listed(_ server: URL, _ path: String) -> [String] {
        var items: [String] = []
        let done = expectation(description: path)
        URLSession.shared.dataTask(with: server.appending(path: path)) { data, _, _ in
            items = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: [String]] })?["items"] ?? []
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 10)
        return items
    }

    private func testServer() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["DEBUG_EMBY"],
              let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let address = json["serverURL"] as? String else { return nil }
        return URL(string: address)
    }

    private func configure(_ server: URL, _ settings: [String: String]) {
        let url = server.appending(path: "mock/set").appending(queryItems: settings.map { URLQueryItem(name: $0.key, value: $0.value) })
        let done = expectation(description: "configure")
        URLSession.shared.dataTask(with: url) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
    }
}

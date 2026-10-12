import XCTest

/// iPhone: a film's Cast & Crew opens a person's page with their titles.
final class PersonPageTests: XCTestCase {
    private let app = XCUIApplication()
    private let shots = URL(fileURLWithPath: "/tmp/openiptv/uitest-ios")

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        if let account = ProcessInfo.processInfo.environment["DEBUG_EMBY"] {
            app.launchEnvironment["OPENREEL_DEBUG_EMBY"] = account
        }
    }

    private func shot(_ name: String) {
        try? FileManager.default.createDirectory(at: shots, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: shots.appending(path: "person-\(name).png"))
    }

    func testCastOpensPersonPage() {
        openPerson()
        let titles = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Zorro'"))
        XCTAssertGreaterThanOrEqual(titles.count, 2, "their films aren't listed")
    }

    /// The server failing: the page says so and offers Try Again, which
    /// lists the titles. Regression: it said "Nothing with … in your
    /// library", as if there were none.
    func testCastPageRetries() throws {
        let server = try XCTUnwrap(testServer(), "no test server account (TEST_RUNNER_DEBUG_EMBY)")
        configure(server, ["fail": "persons"])
        defer { configure(server, ["reset": "1"]) }
        openPerson()
        shot("failed")
        let retry = app.buttons["Try Again"].firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 5), "no Try Again when the server failed")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Nothing with'")).firstMatch.exists,
                       "said there was nothing in the library")
        configure(server, ["reset": "1"])
        retry.tap()
        sleep(3)
        shot("retried")
        let titles = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Zorro'"))
        XCTAssertGreaterThanOrEqual(titles.count, 2, "Try Again didn't list their films")
    }

    /// Antonio Banderas's page, from The Mask of Zorro's Cast & Crew.
    private func openPerson() {
        app.launchArguments = ["-debugSearch", "zorro"]
        app.launch()
        sleep(4)
        app.tabBars.buttons["Search"].firstMatch.tap()
        sleep(3)
        let film = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'The Mask of Zorro'")).firstMatch
        XCTAssertTrue(film.waitForExistence(timeout: 8), "no search result")
        film.tap()
        sleep(2)
        let actor = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Antonio Banderas'")).firstMatch
        for _ in 0..<4 where !actor.isHittable { app.swipeUp() }
        XCTAssertTrue(actor.waitForExistence(timeout: 5), "no cast member")
        shot("film-cast")
        actor.tap()
        sleep(3)
        shot("page")
        XCTAssertTrue(app.staticTexts["Antonio Banderas"].exists, "no person page")
    }

    private func testServer() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["DEBUG_EMBY"],
              let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let address = json["serverURL"] as? String else { return nil }
        return URL(string: address)
    }

    /// Sets how the test server behaves (see CONTROL in mock_server.py).
    private func configure(_ server: URL, _ settings: [String: String]) {
        let url = server.appending(path: "mock/set").appending(queryItems: settings.map { URLQueryItem(name: $0.key, value: $0.value) })
        let done = expectation(description: "configure")
        URLSession.shared.dataTask(with: url) { _, _, _ in done.fulfill() }.resume()
        wait(for: [done], timeout: 10)
    }
}

import XCTest

/// The relay's local addresses (RelayRoutes): the film playing keeps its
/// address however many others are made meanwhile.
final class RelayRoutesTests: XCTestCase {
    private func route(_ n: Int) -> RelayRoutes.Route {
        (URL(string: "https://server.example/Videos/\(n)/stream")!, [])
    }

    /// Regression: past 16 addresses, all were dropped, the playing film's
    /// too; its next read (a seek) got "not found" and connected again.
    func testThePlayingFilmKeepsItsAddress() {
        var routes = RelayRoutes()
        routes.add(route(0), token: "playing")
        for n in 1...40 {
            routes.add(route(n), token: "other-\(n)")
            // The player reads on (or seeks) now and then.
            if n % 5 == 0 { XCTAssertNotNil(routes.route("playing"), "lost the playing film after \(n) others") }
        }
        XCTAssertNotNil(routes.route("playing"))
        XCTAssertEqual(routes.route("playing")?.url, route(0).url)
    }

    /// The newest stay too (a warmed-up player about to be handed over).
    func testTheNewestStay() {
        var routes = RelayRoutes()
        for n in 0..<40 { routes.add(route(n), token: "t\(n)") }
        for n in 30..<40 { XCTAssertNotNil(routes.route("t\(n)"), "t\(n) dropped") }
    }

    /// Never more than its limit (a few dozen bytes each, but not without end).
    func testItStaysSmall() {
        var routes = RelayRoutes()
        for n in 0..<500 { routes.add(route(n), token: "t\(n)") }
        XCTAssertLessThanOrEqual(routes.count, routes.limit + 1)
    }
}

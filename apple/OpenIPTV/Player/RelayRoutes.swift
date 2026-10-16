import Foundation

/// The relay's local addresses: a token for each file opened (a warmed-up
/// player, the one playing, ones prepared ahead) → its real address and
/// headers. Kept to the `limit` most recently used: the one playing is
/// asked for on every read, so it stays. Regression: past 16 addresses all
/// were dropped, the playing film's too; its next read (a seek) got "not
/// found" and had to connect again.
struct RelayRoutes {
    typealias Route = (url: URL, headers: [(String, String)])

    let limit: Int
    private var routes: [String: Route] = [:]
    private var used: [String: UInt64] = [:]
    private var clock: UInt64 = 0

    init(limit: Int = 32) { self.limit = limit }

    var count: Int { routes.count }

    mutating func add(_ route: Route, token: String) {
        routes[token] = route
        touch(token)
        // The least recently used goes (a few dozen bytes each; a film
        // being read is used again on every read).
        while routes.count > limit, let oldest = used.min(by: { $0.value < $1.value })?.key {
            routes[oldest] = nil
            used[oldest] = nil
        }
    }

    /// The route for a request (and it's in use now).
    mutating func route(_ token: String) -> Route? {
        guard let route = routes[token] else { return nil }
        touch(token)
        return route
    }

    private mutating func touch(_ token: String) {
        clock += 1
        used[token] = clock
    }
}

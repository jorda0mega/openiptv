import XCTest
@testable import OpenIPTV

final class FetchAheadTests: XCTestCase {
    func testFetchedAheadRequestsReachTheServerFourAtATimeWhenItsConnectionsCapNothing() async throws {
        let arrived = Locked<[ContinuousClock.Instant]>([])
        let server = try LocalServer(wait: 0.3) { _ in
            arrived.mutate { $0.append(.now) }
            return (200, [:], "ok")
        }
        defer { server.stop() }
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 100
        let asOnHTTP2 = URLSession(configuration: config)
        for n in 0..<12 {
            Task(priority: .utility) {
                let url = URL(string: "http://127.0.0.1:\(server.port)/ahead/\(n)")!
                _ = try? await HTTP.data(URLRequest(url: url), aheadOn: asOnHTTP2)
            }
        }
        for _ in 0..<100 where arrived.value.count < 12 { try await Task.sleep(for: .milliseconds(50)) }
        let times = arrived.value.sorted()
        XCTAssertEqual(times.count, 12)
        let mostAtOnce = times.indices.map { i in times[i...].prefix { $0 - times[i] < .milliseconds(250) }.count }.max() ?? 0
        XCTAssertLessThanOrEqual(mostAtOnce, 4, "fetched ahead under way at once on the server")
    }
}

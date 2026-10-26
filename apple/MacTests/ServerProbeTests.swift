import XCTest
@testable import OpenIPTV

/// The server's own state beside each start (-debugServerProbe YES): a new
/// connection's cost apart from a tiny read's answer, the key only to the
/// given server.
final class ServerProbeTests: XCTestCase {
    private func account(_ server: URL) -> EmbyAccount {
        EmbyAccount(serverURL: server, serverName: "Test", userId: "U1", userName: "tester", accessToken: "tok")
    }

    func testANewConnectionsCostIsApartFromTheAnswer() async throws {
        let server = try LocalServer(firstWait: 0.4, wait: 0.1)
        defer { server.stop() }

        let measured = await ServerProbe.measure(account(URL(string: "http://127.0.0.1:\(server.port)")!))
        let reading = try XCTUnwrap(measured)

        XCTAssertEqual(reading.connect, 0.4, accuracy: 0.1)
        XCTAssertEqual(reading.firstByte, 0.1, accuracy: 0.08)
        XCTAssertEqual(server.asked.value.map(\.target), ["/emby/Users/U1", "/emby/Users/U1"])
        XCTAssertNotNil(reading.readout.range(of: #"^server: connect \d+\.\d\d s, first byte \d+\.\d\d s$"#, options: .regularExpression), reading.readout)
    }

    /// A disk woken by the first read of a film's file: the first slow, the next not.
    func testTheFilmsFileIsReadTwiceAfterTheTinyReads() async throws {
        let read = Locked(0)
        let server = try LocalServer(pause: { target in
            guard target.contains("/stream") else { return 0 }
            var first = false
            read.mutate { $0 += 1; first = $0 == 1 }
            return first ? 0.5 : 0
        })
        defer { server.stop() }

        let measured = await ServerProbe.measure(account(URL(string: "http://127.0.0.1:\(server.port)")!), film: "film-0001")
        let reading = try XCTUnwrap(measured)

        XCTAssertEqual(try XCTUnwrap(reading.file), 0.5, accuracy: 0.15)
        XCTAssertEqual(try XCTUnwrap(reading.fileAgain), 0, accuracy: 0.1)
        XCTAssertEqual(server.asked.value.map(\.target).dropFirst(2).map { $0.components(separatedBy: "?")[0] },
                       ["/emby/Videos/film-0001/stream", "/emby/Videos/film-0001/stream"])
        XCTAssertFalse(server.asked.value.contains { $0.target.contains("tok") })
        XCTAssertNotNil(reading.readout.range(of: #"^server file: first byte \d+\.\d\d s, again \d+\.\d\d s \| server: connect \d+\.\d\d s, first byte \d+\.\d\d s$"#,
                                              options: .regularExpression), reading.readout)
        XCTAssertFalse(reading.readout.contains("film-0001"))
    }

    func testTheKeyGoesOnlyToTheGivenServerInAHeader() async throws {
        let elsewhere = try LocalServer()
        defer { elsewhere.stop() }
        let given = try LocalServer { _ in (302, ["Location": "http://127.0.0.1:\(elsewhere.port)/emby/Users/U1"], "") }
        defer { given.stop() }

        _ = await ServerProbe.measure(account(URL(string: "http://127.0.0.1:\(given.port)")!))

        XCTAssertEqual(given.asked.value.map(\.key), ["tok", "tok"])
        XCTAssertFalse(given.asked.value.contains { $0.target.contains("tok") })
        XCTAssertEqual(elsewhere.asked.value, [])
    }

    /// The test server under "busy" (scripts/slow_link.py): half a second for each new connection.
    func testOnTheTestServerUnderBusy() async throws {
        guard let raw = ProcessInfo.processInfo.environment["DEBUG_EMBY"],
              let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let server = (json["serverURL"] as? String).flatMap(URL.init(string:)) else {
            throw XCTSkip(#"needs the test server: DEBUG_EMBY='{"serverURL": "http://127.0.0.1:<port>"}' swift test"#)
        }
        func profile(_ name: String) async throws {
            _ = try await URLSession.shared.data(from: server.appending(path: "mock/profile").appending(queryItems: [.init(name: "name", value: name)]))
        }
        try await profile("busy")
        let reading = await ServerProbe.measure(account(server))
        try await profile("none")

        XCTAssertEqual(try XCTUnwrap(reading).connect, 0.5, accuracy: 0.1)
    }
}

import XCTest
@testable import OpenIPTV

/// UI tests on a slow network: the app's server sessions go through the
/// throttling proxy named at launch, and straight to the server without one.
final class DebugProxyTests: XCTestCase {
    func testRequestsGoThroughTheProxyNamedAtLaunch() async throws {
        let proxy = try LocalServer { target in target.hasPrefix("http") ? (200, [:], "through") : (403, [:], "") }
        defer { proxy.stop() }
        let config = URLSessionConfiguration.ephemeral
        HTTP.throughDebugProxy(config, environment: ["OPENREEL_DEBUG_PROXY": "127.0.0.1:\(proxy.port)", "OPENREEL_DEBUG_PROXY_PLAIN": "1"])

        let (data, _) = try await URLSession(configuration: config).data(from: URL(string: "http://127.0.0.1:9/emby/System/Info/Public")!)
        _ = try? await URLSession(configuration: config).data(from: URL(string: "https://emby.invalid/emby/Users/U1/Views")!)

        XCTAssertEqual(String(decoding: data, as: UTF8.self), "through")
        XCTAssertEqual(Set(proxy.asked.value.map(\.target)), ["http://127.0.0.1:9/emby/System/Info/Public", "emby.invalid:443"])
    }

    /// Plain HTTP carries the key in clear: only the test server's goes
    /// through the proxy, and a real server's only as a TLS tunnel.
    func testPlainRequestsGoStraightUnlessTheServerIsTheTestServer() async throws {
        let proxy = try LocalServer { _ in (200, [:], "through") }
        defer { proxy.stop() }
        let server = try LocalServer { _ in (200, [:], "straight") }
        defer { server.stop() }
        let config = URLSessionConfiguration.ephemeral
        HTTP.throughDebugProxy(config, environment: ["OPENREEL_DEBUG_PROXY": "127.0.0.1:\(proxy.port)"])

        let (data, _) = try await URLSession(configuration: config).data(from: URL(string: "http://127.0.0.1:\(server.port)/emby/Users/U1/Views")!)
        _ = try? await URLSession(configuration: config).data(from: URL(string: "https://emby.invalid/emby/Users/U1/Views")!)

        XCTAssertEqual(String(decoding: data, as: UTF8.self), "straight", "a plain request went through the proxy")
        XCTAssertEqual(Set(proxy.asked.value.map(\.target)), ["emby.invalid:443"])
    }

    func testWithoutOneRequestsGoStraightToTheServer() async throws {
        let server = try LocalServer { _ in (200, [:], "straight") }
        defer { server.stop() }
        let config = URLSessionConfiguration.ephemeral
        HTTP.throughDebugProxy(config, environment: [:])

        let (data, _) = try await URLSession(configuration: config).data(from: URL(string: "http://127.0.0.1:\(server.port)/emby/System/Info/Public")!)

        XCTAssertEqual(String(decoding: data, as: UTF8.self), "straight")
        XCTAssertEqual(server.asked.value.map(\.target), ["/emby/System/Info/Public"])
    }
}

import XCTest

final class TelemetrySourceTests: XCTestCase {
    func testOnlyTheGateTalksToSentry() throws {
        let app = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "OpenIPTV")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        let importing = try files.filter { file in
            try String(contentsOf: file, encoding: .utf8).split(separator: "\n").contains { $0.hasPrefix("import Sentry") }
        }
        XCTAssertEqual(importing.map(\.lastPathComponent), ["SentryGate.swift"])
    }
}

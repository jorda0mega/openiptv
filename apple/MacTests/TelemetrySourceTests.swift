import XCTest

final class TelemetrySourceTests: XCTestCase {
    private func appFiles() throws -> [URL] {
        let app = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appending(path: "OpenIPTV")
        return try XCTUnwrap(FileManager.default.enumerator(at: app, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    func testOnlyTheGateTalksToSentry() throws {
        let importing = try appFiles().filter { file in
            try String(contentsOf: file, encoding: .utf8).split(separator: "\n").contains { $0.hasPrefix("import Sentry") }
        }
        XCTAssertEqual(importing.map(\.lastPathComponent), ["SentryGate.swift"])
    }

    func testNoCrashMessageCarriesAValue() throws {
        let interpolated = #/(fatalError|preconditionFailure|precondition|assertionFailure|assert|NSException|raise)\(.*\\\(/#
        let lines = try appFiles().flatMap { file in
            try String(contentsOf: file, encoding: .utf8).split(separator: "\n").filter { $0.contains(interpolated) }
                .map { "\(file.lastPathComponent): \($0.trimmingCharacters(in: .whitespaces))" }
        }
        XCTAssertEqual(lines, [#"Telemetry.swift: DispatchQueue.main.asyncAfter(deadline: .now() + 3) { fatalError("telemetry test crash at \(place)") }"#])
    }
}

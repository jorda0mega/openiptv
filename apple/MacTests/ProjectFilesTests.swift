import Foundation
import XCTest

final class ProjectFilesTests: XCTestCase {
    func testTheSavedXcodeProjectListsEverySourceFileOfTheApp() throws {
        let apple = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let project = try String(contentsOf: apple.appendingPathComponent("OpenIPTV.xcodeproj/project.pbxproj"), encoding: .utf8)
        let sources = try XCTUnwrap(FileManager.default.enumerator(at: apple.appendingPathComponent("OpenIPTV"), includingPropertiesForKeys: nil))
        let names = sources.compactMap { ($0 as? URL)?.lastPathComponent }.filter { $0.hasSuffix(".swift") }
        XCTAssertFalse(names.isEmpty)
        let missing = names.filter { !project.contains("path = \($0);") }.sorted()
        XCTAssertEqual(missing, [], "the release builds the saved project: run `xcodegen generate` in apple/ and commit it")
    }
}

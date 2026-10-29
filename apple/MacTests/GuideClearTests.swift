import XCTest
@testable import OpenIPTV

final class GuideClearTests: XCTestCase {
    private func stamp(_ seconds: Int64) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds))) + " +0000"
    }

    func testAGuideDownloadUnderWayWhenTheGuideIsForgottenKeepsNothing() async throws {
        let now = Int64(Date().timeIntervalSince1970)
        let body = """
        <?xml version="1.0" encoding="UTF-8"?><tv><channel id="c1"><display-name>One</display-name></channel>\
        <programme start="\(stamp(now - 600))" stop="\(stamp(now + 1200))" channel="c1"><title>News</title></programme></tv>
        """
        let server = try LocalServer(pause: { _ in 0.5 }) { _ in (200, ["Content-Type": "application/xml"], body) }
        let guide = GuideStore()
        let request = URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/guide.xml")!)
        let refresh = Task { await guide.refresh(from: [request], keep: ["c1"]) }
        try await Task.sleep(for: .milliseconds(150))
        await guide.clear()
        await refresh.value
        let state = await guide.state
        let onNow = await guide.nowNext("c1")
        XCTAssertEqual(state, .idle)
        XCTAssertNil(onNow, "the forgotten guide's programmes came back")
        await guide.clear()
    }

    func testAGuideSavedAsItIsForgottenIsNotKeptForTheNextLaunch() async throws {
        let now = Int64(Date().timeIntervalSince1970)
        let body = """
        <?xml version="1.0" encoding="UTF-8"?><tv><channel id="c1"><display-name>One</display-name></channel>\
        <programme start="\(stamp(now - 600))" stop="\(stamp(now + 1200))" channel="c1"><title>News</title></programme></tv>
        """
        let server = try LocalServer { _ in (200, ["Content-Type": "application/xml"], body) }
        let guide = GuideStore()
        await guide.refresh(from: [URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/guide.xml")!)], keep: ["c1"])
        await guide.clear()
        try await Task.sleep(for: .milliseconds(500))
        let saved = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "guide.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: saved.path()), "the forgotten guide was saved for the next launch")
        await guide.clear()
    }
}

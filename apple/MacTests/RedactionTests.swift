import XCTest
@testable import OpenIPTV

final class RedactionTests: XCTestCase {
    private let user = "lu5f0c2e9a17b3d4c8"
    private let password = "lp9e8d7c6b5a4f3e2d"
    private let token = "tk0123456789abcdef0123456789abcd"

    private func assertNothingOf(_ secrets: [String], in text: String, line: UInt = #line) {
        let cleaned = Redaction.clean(text)
        for secret in secrets {
            XCTAssertFalse(cleaned.localizedCaseInsensitiveContains(secret), "kept \(secrets.firstIndex(of: secret) ?? -1)", line: line)
        }
    }

    func testAStreamAddressLeavesNothingOfTheServerOrTheLogin() {
        assertNothingOf(["http", "203.0.113.9", "8080", user, password],
                        in: "Failed to open http://203.0.113.9:8080/live/\(user)/\(password)/123.ts: Server returned 404")
        assertNothingOf(["iptv.example.tv", "25461", user, password], in: "iptv.example.tv:25461/\(user)/\(password)/7")
        assertNothingOf([user, password], in: "live/\(user)/\(password)/123.ts")
        assertNothingOf([user, password], in: "(/movie/\(user)/\(password)/12.mkv)")
    }

    func testAQueryLeavesNothingOfItsValues() {
        assertNothingOf([user, password], in: "get.php?username=\(user)&password=\(password)&type=m3u_plus")
        assertNothingOf([token], in: "/emby/Videos/a1/stream.mkv?api_key=\(token)")
        assertNothingOf([token], in: "Static=true&api_key=\(token)")
    }

    func testATokenLeavesNothing() {
        assertNothingOf([token], in: "X-Emby-Token: \(token)")
        assertNothingOf([token], in: "the key \(token) was refused")
        assertNothingOf(["5F0C2E9A"], in: "item 5F0C2E9A-17B3-4D4C-8E9A-1B2C3D4E5F60 failed")
    }

    func testHostsAndAddressesLeaveNothing() {
        assertNothingOf(["emby.local"], in: "emby.local timed out.")
        assertNothingOf(["media.example.com", user], in: "\(user)@media.example.com")
        assertNothingOf(["fe80"], in: "connect to [fe80::1]:8096 failed")
        assertNothingOf(["10.0.0.5"], in: "host 10.0.0.5 is down")
        assertNothingOf(["localhost"], in: "localhost refused")
        assertNothingOf(["nas", "8096"], in: "nas:8096 refused")
        assertNothingOf(["example"], in: "see www.example.com")
        assertNothingOf(["host"], in: "http%3A%2F%2Fhost%2Flive")
        assertNothingOf(["xn--p1ai"], in: "server.xn--p1ai refused")
    }

    func testQuotedTextLeavesNothing() {
        assertNothingOf(["Long Film"], in: "Couldn't play “The Long Film” here")
        assertNothingOf(["Long Film"], in: "title \"The Long Film\" missing")
        assertNothingOf(["Long Film"], in: "Fatal error: Duplicate values for key: 'The Long Film'")
        assertNothingOf(["Lost Film"], in: "for key: 'A Director's Lost Film' here")
        assertNothingOf(["Long", "Film"], in: "for key: 'The Long\nFilm' here")
        assertNothingOf(["Lost Film"], in: "for key: ‘A Director’s Lost Film’ here")
        assertNothingOf(["Lost Film"], in: "key:'A Director's Lost Film' and ('The Lost Film')")
        XCTAssertEqual(Redaction.clean("Couldn't play the film's sound"), "Couldn't play the film's sound")
    }

    func testAValueAfterALoginWordLeavesNothing() {
        assertNothingOf(["hunter2x"], in: "password: hunter2x")
        assertNothingOf(["hunter2x"], in: "password = hunter2x")
        assertNothingOf(["hunter2x"], in: "user : hunter2x refused")
        XCTAssertEqual(Redaction.clean("the user cancelled"), "the user cancelled")
        assertNothingOf(["tester", "hunter2x"], in: "user:tester pass=hunter2x refused")
        assertNothingOf(["hunter2x"], in: "authorization: hunter2x")
        assertNothingOf(["hunter2x"], in: "Authorization hunter2x".replacingOccurrences(of: " ", with: ":"))
        assertNothingOf(["hunter2x"], in: "authorization = hunter2x")
        XCTAssertEqual(Redaction.clean("userInfo keyboard authored"), "userInfo keyboard authored")
    }

    func testCrashWordsStayReadable() {
        for text in ["Fatal error: Index out of range", "EXC_BAD_ACCESS", "KERN_INVALID_ADDRESS at 0x0000000000000010",
                     "App hanging for at least 2000 ms.", "NSInvalidArgumentException", "com.apple.main-thread",
                     "openiptv.film-frames", "version 0.2.0", "SIGABRT"] {
            XCTAssertEqual(Redaction.clean(text), text)
        }
    }

    func testASourcePathGoesAndTheReasonStays() {
        XCTAssertEqual(Redaction.clean("Swift/ContiguousArrayBuffer.swift:600: Fatal error: Index out of range"),
                       "[removed] Fatal error: Index out of range")
    }

    func testOurOwnWordsSurvive() {
        let words = Problem.kinds + StreamFailure.allCases.map { Problem(subject: .film, started: true, reason: $0).reasonWord }
            + Metric.Key.allCases.flatMap { [$0.rawValue] + $0.values }
        for word in words {
            XCTAssertEqual(Redaction.clean(word), word)
        }
    }

    func testLongTextIsCut() {
        XCTAssertLessThanOrEqual(Redaction.clean(String(repeating: "word ", count: 200)).count, Redaction.longest)
    }

    func testAnImagePathKeepsOnlyTheBinaryName() {
        XCTAssertEqual(Redaction.fileName("/private/var/containers/Bundle/Application/1F2E3D4C-0000-4000-8000-000000000001/Openreel.app/OpenIPTV"),
                       "OpenIPTV")
        XCTAssertEqual(Redaction.fileName("/usr/lib/libobjc.A.dylib"), "libobjc.A.dylib")
        XCTAssertEqual(Redaction.fileName("/Users/someone/Library/Developer/CoreSimulator/Devices/X/data/Containers/Bundle/OpenIPTV"),
                       "OpenIPTV")
        XCTAssertEqual(Redaction.fileName("OpenIPTV"), "OpenIPTV")
    }

    func testAFunctionNameIsKeptUnlessItHoldsAnAddress() {
        XCTAssertFalse(Redaction.holdsAddress("-[NSObject(NSObject) doesNotRecognizeSelector:]"))
        XCTAssertFalse(Redaction.holdsAddress("objc_msgSend"))
        XCTAssertFalse(Redaction.holdsAddress("$s8OpenIPTV10PlayerViewV6handleyyAA9MPVPlayerC5EventO_SitF"))
        XCTAssertTrue(Redaction.holdsAddress("http://203.0.113.9/live"))
    }
}

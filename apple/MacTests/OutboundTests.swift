import XCTest
@testable import OpenIPTV

final class OutboundTests: XCTestCase {
    private let real = "https://0123456789abcdef@o1.ingest.us.sentry.io/42"
    private let local = "http://openreeltest@127.0.0.1:8790/1"

    func testADebugBuildSendsOnlyToALocalDSNFromItsTest() {
        XCTAssertEqual(Outbound.dsn(.debug, environment: [Outbound.debugDSNKey: local], info: [:]), local)
        XCTAssertEqual(Outbound.dsn(.debug, environment: [Outbound.debugDSNKey: "http://k@localhost:9/1"], info: [:]),
                       "http://k@localhost:9/1")
        XCTAssertNil(Outbound.dsn(.debug, environment: [Outbound.debugDSNKey: real], info: [:]))
        XCTAssertNil(Outbound.dsn(.debug, environment: [:], info: [Outbound.plistDSNKey: real]))
    }

    func testAReleaseBuildSendsOnlyToTheDSNItWasArchivedWith() {
        XCTAssertEqual(Outbound.dsn(.release, environment: [:], info: [Outbound.plistDSNKey: real]), real)
        XCTAssertNil(Outbound.dsn(.release, environment: [Outbound.debugDSNKey: local], info: [:]))
        XCTAssertNil(Outbound.dsn(.release, environment: [Outbound.debugDSNKey: local], info: [Outbound.plistDSNKey: real]))
        XCTAssertNil(Outbound.dsn(.release, environment: [Outbound.debugDSNKey: real], info: [Outbound.plistDSNKey: ""]))
        XCTAssertNil(Outbound.dsn(.release, environment: [:], info: [Outbound.plistDSNKey: "$(SENTRY_DSN)"]))
        XCTAssertNil(Outbound.dsn(.release, environment: [:], info: [Outbound.plistDSNKey: local]))
    }

    private var sdkAttributes: [String: String] {
        ["sentry.release": "202610271425", "sentry.environment": "release", "sentry.sdk.name": "sentry.cocoa",
         "sentry.sdk.version": "9.31.0", "os.name": "iOS", "os.version": "26.1", "device.brand": "Apple",
         "device.model": "iPhone17,1", "device.family": "iOS", "user.id": "1F2E3D4C-0000-4000-8000-000000000001"]
    }

    func testAMetricKeepsOurStatesAndTheSDKsFixedFieldsOnly() {
        let ours = ["platform": "iphone", "network": "wifi", "picture": "software", "prepared": "yes", "loading_shown": "no"]
        let extra = ["user.name": "tester", "user.email": "a@b.c", "sentry.replay_id": "abc", "server": "Mock"]
        let kept = Outbound.metricAttributes(name: "film.start.prepared", ours.merging(sdkAttributes) { $1 }.merging(extra) { $1 })
        XCTAssertEqual(kept, ours.merging(sdkAttributes) { $1 })
    }

    func testAMetricOutsideOurNamesOrWordsIsDropped() {
        XCTAssertNil(Outbound.metricAttributes(name: "film.start.title", ["platform": "iphone"]))
        XCTAssertNil(Outbound.metricAttributes(name: "live.start", ["platform": "The Long Film"]))
        XCTAssertNil(Outbound.metricAttributes(name: "live.start", ["network": "203.0.113.9"]))
    }

    func testAnSDKFieldHoldingAnAddressOrANameIsDropped() {
        let kept = Outbound.metricAttributes(name: "live.switch", ["os.name": "http://203.0.113.9", "user.id": "tester"])
        XCTAssertEqual(kept, [:])
    }

    func testOnlyTextTheSDKOrTheSystemWroteStaysOnACrash() {
        XCTAssertEqual(Outbound.exceptionText("Exception 1, Code 1, Subcode 16", mechanism: "mach"), "Exception 1, Code 1, Subcode 16")
        XCTAssertEqual(Outbound.exceptionText("Signal 6, Code 0", mechanism: "signal"), "Signal 6, Code 0")
        XCTAssertEqual(Outbound.exceptionText("Fatal error: Index out of range", mechanism: "signal"), "Fatal error: Index out of range")
        XCTAssertEqual(Outbound.exceptionText("Swift/ContiguousArrayBuffer.swift:600: Fatal error: Index out of range", mechanism: "mach"),
                       "Fatal error: Index out of range")
        XCTAssertEqual(Outbound.exceptionText("Fatal error: Duplicate values for key: 'A Director's Lost Film'", mechanism: "mach"),
                       "Fatal error: Duplicate values for")
        XCTAssertEqual(Outbound.exceptionText("Fatal error: crash at http://203.0.113.9:8080/live/a/b/1.ts", mechanism: "mach"),
                       "Fatal error: crash at")
        XCTAssertEqual(Outbound.exceptionText("Fatal error: 'try!' expression unexpectedly raised an error", mechanism: "mach"),
                       "Fatal error:")
        XCTAssertNil(Outbound.exceptionText("The Long Film > lu5f0c2e9a", mechanism: "mach"))
        XCTAssertEqual(Outbound.exceptionText("Exception 1, Code 1, Subcode 16 >\nKERN_INVALID_ADDRESS at 0x10.", mechanism: "mach"),
                       "Exception 1, Code 1, Subcode 16 >\nKERN_INVALID_ADDRESS at 0x10.")
        XCTAssertEqual(Outbound.exceptionText("Signal 11, Code 0 >\nAttempted to dereference null pointer.", mechanism: "signal"),
                       "Signal 11, Code 0 >\nAttempted to dereference null pointer.")
        XCTAssertEqual(Outbound.exceptionText("Signal 11, Code 0 >\nPossible zombie in call: The Long Film", mechanism: "signal"),
                       "Signal 11, Code 0")
        XCTAssertNil(Outbound.exceptionText("Exception The Long Film, Code 1", mechanism: "mach"))
        XCTAssertNil(Outbound.exceptionText("BUG IN CLIENT: The Long Film", mechanism: "signal"))
        XCTAssertEqual(Outbound.exceptionText("App hanging for at least 2000 ms.", mechanism: "AppHang"), "App hanging for at least 2000 ms.")
        XCTAssertEqual(Outbound.exceptionText("MXHangDiagnostic hangDuration:3 sec", mechanism: "mx_hang_diagnostic"),
                       "MXHangDiagnostic hangDuration:3 sec")
        for mechanism in ["nsexception", "cpp_exception", "user", "NSError", "HTTPClientError", "new_one"] {
            XCTAssertNil(Outbound.exceptionText("Cannot play The Long Film", mechanism: mechanism))
        }
        XCTAssertNil(Outbound.exceptionText("Cannot play The Long Film", mechanism: nil))
    }

    func testOnlyTheInstallIDsShapeGoesOut() {
        XCTAssertEqual(Outbound.installID("1F2E3D4C-0000-4000-8000-000000000001"), "1F2E3D4C-0000-4000-8000-000000000001")
        XCTAssertNil(Outbound.installID("tester"))
        XCTAssertNil(Outbound.installID(nil))
    }

    func testContextsKeepTheDevicesShapeAndNotItsNameOrPlace() {
        let contexts: [String: [String: Any]] = [
            "device": ["name": "Someone's iPhone", "model": "iPhone17,1", "memory_size": 8_000_000_000, "simulator": false,
                       "locale": "en_US", "timezone": "America/New_York"],
            "os": ["name": "iOS", "version": "26.1", "kernel_version": "Darwin Kernel Version 25.0.0: root:xnu/RELEASE"],
            "app": ["app_build": "202610271425", "app_identifier": "com.jorda0mega.openiptv", "view_names": ["PlayerView"]],
            "culture": ["timezone": "America/New_York"],
            "trace": ["trace_id": "abc"],
        ]
        let kept = Outbound.contexts(contexts)
        XCTAssertEqual(Set(kept.keys), ["device", "os", "app"])
        XCTAssertEqual(keys(kept, "device"), ["model", "memory_size", "simulator"])
        XCTAssertEqual(keys(kept, "os"), ["name", "version"])
        XCTAssertEqual(keys(kept, "app"), ["app_build"])
        XCTAssertEqual(kept["device"]?["model"] as? String, "iPhone17,1")
    }

    private func keys(_ contexts: [String: [String: Any]], _ name: String) -> Set<String> {
        Set(contexts[name].map { Array($0.keys) } ?? [])
    }

    func testAContextStringHoldingAnAddressIsCleaned() {
        let kept = Outbound.contexts(["device": ["model": "http://203.0.113.9/x", "model_id": "emby.local", "arch": "arm64e"]])
        XCTAssertEqual(kept["device"]?["model"] as? String, Redaction.removed)
        XCTAssertEqual(kept["device"]?["model_id"] as? String, Redaction.removed)
        XCTAssertEqual(kept["device"]?["arch"] as? String, "arm64e")
    }

    func testTheLastLockFindsAnAddressAnywhereInASerializedEvent() {
        XCTAssertTrue(Outbound.stillHoldsAddress(#"{"a":{"b":["x http://h/y"]}}"#))
        XCTAssertTrue(Outbound.stillHoldsAddress(#"{"value":"at 203.0.113.9"}"#))
        XCTAssertTrue(Outbound.stillHoldsAddress(#"{"value":"api_key=abc"}"#))
        XCTAssertTrue(Outbound.stillHoldsAddress(#"{"value":"password: abc"}"#))
        let crash = #"{"threads":[{"name":"com.apple.main-thread"}],"debug_meta":{"images":[{"code_file":"libobjc.A.dylib"}]},"#
            + #""function":"std::__1::basic_string","app_version":"0.2.0","timestamp":1761579493.123}"#
        XCTAssertFalse(Outbound.stillHoldsAddress(crash))
    }
}

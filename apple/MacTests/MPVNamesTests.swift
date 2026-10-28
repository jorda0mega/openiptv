import XCTest
@testable import OpenIPTV

final class MPVNamesTests: XCTestCase {
    /// libmpv refuses an unknown name without a sign: "sw-fast" left every iPhone film on libswscale's slow path.
    func testEveryNameThePlayerGivesLibmpvIsOneItKnows() throws {
        let apple = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        try XCTSkipUnless(FileManager.default.fileExists(atPath: apple.appending(path: "Vendor/Libmpv.xcframework").path),
                          "MPVKit not fetched (scripts/fetch-mpvkit.sh)")
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        try XCTSkipUnless(path.split(separator: ":").contains { FileManager.default.isExecutableFile(atPath: "\($0)/ffmpeg") },
                          "no ffmpeg for the test film")

        let plans: [TrackPlan?] = [nil, TrackPlan(audio: ["eng"], subtitles: nil), TrackPlan(audio: ["eng"], subtitles: ["eng"])]
        let preroll = plans.flatMap { plan in [false, true].flatMap { TrackChoice.subtitlePreroll(plan, reopening: $0) } }
        let data = PlayerProfile.allCases.flatMap(\.mpvOptions).map { "option\t\($0.0)\t\($0.1)" }
            + preroll.map { "property\t\($0.name)\t\($0.value)" }

        let check = Process()
        check.executableURL = apple.appending(path: "Tools/mpv-names/run.sh")
        check.environment = ProcessInfo.processInfo.environment.merging(["PATH": path, "MPV_NAMES_PAIRS": "stdin", "MPV_NAMES_REQUIRE": "sws-fast"]) { $1 }
        let input = Pipe(), output = Pipe()
        check.standardInput = input
        check.standardOutput = output
        check.standardError = output
        let ended = DispatchSemaphore(value: 0)
        check.terminationHandler = { _ in ended.signal() }
        try check.run()
        input.fileHandleForWriting.write(Data((data.joined(separator: "\n") + "\n").utf8))
        try input.fileHandleForWriting.close()
        var text = ""
        let read = DispatchSemaphore(value: 0)
        Thread {
            text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            read.signal()
        }.start()
        if ended.wait(timeout: .now() + 60) == .timedOut {
            let children = Process()
            children.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
            children.arguments = ["-TERM", "-P", String(check.processIdentifier)]
            try? children.run()
            children.waitUntilExit()
            check.terminate()
            return XCTFail("the check did not end in 60 s")
        }
        _ = read.wait(timeout: .now() + 5)
        XCTAssertEqual(check.terminationStatus, 0, text.split(separator: "\n").filter { !$0.contains("warning:") }.joined(separator: "\n"))
    }
}

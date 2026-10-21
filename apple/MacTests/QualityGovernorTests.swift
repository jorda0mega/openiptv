import XCTest
@testable import OpenIPTV

/// The quality governor (original file or a server-converted version).
final class QualityGovernorTests: XCTestCase {
    /// An episode's last seconds: the buffer can be no longer than what's
    /// left, and nothing more downloads, so a short buffer then says
    /// nothing about the connection. Regression: the quality dropped to a
    /// converted stream in an episode's last seconds ("Lower quality to
    /// keep playing smoothly"), and the next episode never played.
    func testTheFilesEndIsNotASlowConnection() {
        var governor = QualityGovernor(original: 8_000_000)
        let start = Date()
        // A connection a little slower than the file (6.4 Mbps for 8).
        var decisions: [QualityGovernor.Decision?] = []
        for second in 0..<6 {
            let left = 5.5 - Double(second)
            decisions.append(governor.observe(buffer: max(left - 0.5, 0), bytesPerSecond: 800_000, stalled: false,
                                              left: left, now: start.addingTimeInterval(Double(second))))
        }
        XCTAssertEqual(decisions.compactMap(\.self), [], "the quality dropped at the file's end")
    }

    /// Mid-film, the same short buffer on that connection still lowers the
    /// quality (before the picture stops), as before.
    func testAShortBufferMidFilmStillLowersTheQuality() {
        var governor = QualityGovernor(original: 8_000_000)
        let start = Date()
        var decisions: [QualityGovernor.Decision?] = []
        for second in 0..<6 {
            decisions.append(governor.observe(buffer: 3, bytesPerSecond: 800_000, stalled: false,
                                              left: 1200, now: start.addingTimeInterval(Double(second))))
        }
        XCTAssertFalse(decisions.compactMap(\.self).isEmpty, "a short buffer mid-film didn't lower the quality")
    }

    func testAVersionWaitingForTheServerIsNotJudged() {
        var governor = QualityGovernor(original: 8_000_000)
        let start = Date()
        XCTAssertNotNil(governor.observe(buffer: 0, bytesPerSecond: 0, stalled: true, left: 4000, now: start), "the stall didn't lower the quality")
        var decisions: [QualityGovernor.Decision?] = []
        for second in 1...60 {
            let now = start.addingTimeInterval(Double(second))
            if second == 20 { governor.noteProbe(bitsPerSecond: 50_000_000) }
            decisions.append(governor.observe(buffer: 0, bytesPerSecond: second % 7 == 0 ? 40_000 : 0, stalled: second == 25,
                                              left: 4000, now: now))
        }
        XCTAssertEqual(decisions.compactMap(\.self), [], "the quality changed again before the converted version played")
    }

    func testAVersionIsJudgedAfterTenSecondsOfPlayback() {
        var governor = QualityGovernor(original: 8_000_000)
        let start = Date()
        XCTAssertEqual(governor.observe(buffer: 0, bytesPerSecond: 0, stalled: true, left: 4000, now: start), .converted(3_000_000))
        governor.notePlaying(now: start.addingTimeInterval(20))
        XCTAssertNil(governor.observe(buffer: 0, bytesPerSecond: 0, stalled: true, left: 4000, now: start.addingTimeInterval(25)),
                     "judged in its first seconds of playing")
        XCTAssertEqual(governor.observe(buffer: 0, bytesPerSecond: 0, stalled: true, left: 4000, now: start.addingTimeInterval(31)),
                       .converted(1_500_000), "a stall after it had played didn't lower it")
    }
}

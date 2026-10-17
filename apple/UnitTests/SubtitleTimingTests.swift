import XCTest

/// Where a subtitle file's lines go, remembered on the device (SubtitleTiming).
final class SubtitleTimingTests: XCTestCase {
    private let url = URL(string: "https://server.example/emby/Videos/7/ms7/Subtitles/100/Stream.srt?api_key=x")!
    private func match(_ delay: Double) -> SubtitleSync.Match {
        SubtitleSync.Match(sections: [.init(from: 0, delay: delay, speed: 1)], score: 2, evenness: 1)
    }

    /// Regression: kept by the file's address alone, so another file at the
    /// same address (the server replaced it; a test server served an early
    /// file where an in-time one had been) was shown at the old one's
    /// timing (+0.00 s instead of +6.5 s), and never put in time.
    func testAnotherFileAtTheSameAddressIsWorkedOutAgain() {
        SubtitleTiming.remember(match(0), for: url, text: "1\n00:00:01,000 --> 00:00:02,000\nin time\n")
        XCTAssertNil(SubtitleTiming.remembered(url, text: "1\n00:00:07,500 --> 00:00:08,500\nearly\n"))
        XCTAssertEqual(SubtitleTiming.remembered(url, text: "1\n00:00:01,000 --> 00:00:02,000\nin time\n")?.sections.first?.delay, 0)
    }

    /// A timing an earlier version of the sync worked out shows at once,
    /// but isn't the last word: the file is worked out again. Regression:
    /// Asterix and Cleopatra's English file kept an earlier build's timing
    /// (its first scene 6 s late) after a later build could put it in time.
    func testTimingFromAnEarlierSyncIsWorkedOutAgain() {
        let text = "1\n00:00:05,000 --> 00:00:06,000\nfirst scene\n"
        SubtitleTiming.remember(match(6.5), for: url, text: text, version: SubtitleSync.version - 1)
        XCTAssertEqual(SubtitleTiming.remembered(url, text: text)?.sections.first?.delay, 6.5, "not shown at once")
        XCTAssertFalse(SubtitleTiming.settles(url, text: text), "an earlier sync's timing kept for good")
        SubtitleTiming.remember(match(0.7), for: url, text: text)
        XCTAssertTrue(SubtitleTiming.settles(url, text: text), "this sync's timing worked out again")
    }

    /// The same file on another play (the address's key differs) is the same.
    func testTheSameFileIsRemembered() {
        let text = "1\n00:00:03,000 --> 00:00:04,000\nhello\n"
        SubtitleTiming.remember(match(6.5), for: url, text: text)
        let again = URL(string: "https://server.example/emby/Videos/7/ms7/Subtitles/100/Stream.srt?api_key=y")!
        XCTAssertEqual(SubtitleTiming.remembered(again, text: text)?.sections.first?.delay, 6.5)
    }
}

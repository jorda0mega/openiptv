import XCTest
@testable import OpenIPTV

final class TrackChoiceTests: XCTestCase {
    private func plan(subtitles: [String]?) -> TrackPlan {
        TrackPlan(audio: ["en", "eng"], subtitles: subtitles)
    }

    private func readsBefore(_ preroll: [(name: String, value: String)]) -> Bool {
        preroll.contains { $0.value != "0" }
    }

    func testAFilmStartingWithNoSubtitlesShownReadsNothingBeforeItsStart() {
        let preroll = TrackChoice.subtitlePreroll(plan(subtitles: nil), reopening: false)
        XCTAssertEqual(preroll.map(\.name), ["demuxer-mkv-subtitle-preroll-secs", "demuxer-mkv-subtitle-preroll-secs-index"])
        XCTAssertFalse(readsBefore(preroll), "the subtitles read along hidden made the player read before the start")
    }

    func testAFilmStartingWithSubtitlesShownReadsForTheLineAlreadyOn() {
        XCTAssertTrue(readsBefore(TrackChoice.subtitlePreroll(plan(subtitles: ["en", "eng"]), reopening: false)))
    }

    func testAnotherQualityOfTheSameFilmReadsAsMpvDoes() {
        XCTAssertTrue(readsBefore(TrackChoice.subtitlePreroll(plan(subtitles: nil), reopening: true)))
    }

    func testLiveTVReadsAsMpvDoes() {
        XCTAssertTrue(readsBefore(TrackChoice.subtitlePreroll(nil, reopening: false)))
    }
}

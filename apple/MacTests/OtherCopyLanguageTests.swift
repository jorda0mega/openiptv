import XCTest
@testable import OpenIPTV

final class OtherCopyLanguageTests: XCTestCase {
    private func film(heard: [String?], others: [[String]]) -> EmbyPlayback {
        var playback = EmbyPlayback(itemId: "a8", title: "Film", subtitle: nil, url: URL(string: "http://server/stream")!, durationSeconds: 7200)
        playback.tracks = TrackChoice.plan(audio: heard, countries: [], key: UUID().uuidString)
        playback.otherCopies = others.enumerated().map { .init(itemId: "k\($0.offset)", languages: $0.element) }
        return playback
    }

    func testEnglishOnlyInAnotherCopyIsFound() {
        XCTAssertEqual(film(heard: ["fre"], others: [["en", "fr"]]).languagesOnlyInOtherCopies, ["en"])
    }

    func testALanguageThisCopyHasIsNotOffered() {
        XCTAssertEqual(film(heard: ["eng", "spa"], others: [["en", "es"]]).languagesOnlyInOtherCopies, [])
    }

    func testOnlyEnglishAndSpanishAreOffered() {
        XCTAssertEqual(film(heard: ["eng"], others: [["ja"], ["es", "es"]]).languagesOnlyInOtherCopies, ["es"])
    }
}

import XCTest

/// Subtitle files found by the server's providers: one written in another
/// language than it's offered in is left out (the user: "deleting
/// subtitles that have no proper formatted language").
final class SubtitleLanguageTests: XCTestCase {
    private func srt(_ lines: [String]) -> String {
        lines.enumerated().map { n, line in
            "\(n + 1)\n00:00:\(String(format: "%02d", n * 2 % 60)),000 --> 00:00:\(String(format: "%02d", (n * 2 + 1) % 60)),500\n\(line)\n"
        }.joined(separator: "\n")
    }

    private let english = ["Look, the river is rising.", "That was not part of the plan.", "You should have seen his face.",
                           "I am not going back there.", "How far is the next village?", "We leave before the sun comes up."]
    private let spanish = ["Mira, el río está subiendo.", "Eso no era parte del plan.", "Tendrías que haber visto su cara.",
                           "No pienso volver allí.", "¿A qué distancia está el próximo pueblo?", "Nos vamos antes de que salga el sol."]

    func testSpanishOfferedAsEnglishIsLeftOut() {
        XCTAssertTrue(SubtitleLanguage.writtenInAnother("en", srt(spanish)))
        XCTAssertFalse(SubtitleLanguage.writtenInAnother("es", srt(spanish)))
    }

    func testEnglishOfferedAsEnglishIsKept() {
        XCTAssertFalse(SubtitleLanguage.writtenInAnother("en", srt(english)))
        // With its tags and an ASS file's fields.
        XCTAssertFalse(SubtitleLanguage.writtenInAnother("en", srt(english.map { "<i>\($0)</i>" })))
        let ass = "[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\n"
            + english.map { "Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,{\\an8}\($0)" }.joined(separator: "\n")
        XCTAssertFalse(SubtitleLanguage.writtenInAnother("en", ass))
        XCTAssertTrue(SubtitleLanguage.writtenInAnother("es", ass))
    }

    /// Lines too plain to tell are kept.
    func testLinesThatTellNothingAreKept() {
        XCTAssertFalse(SubtitleLanguage.writtenInAnother("en", srt((1...20).map { "LINE \($0)" })))
        XCTAssertFalse(SubtitleLanguage.writtenInAnother("es", srt((1...20).map { "LINE \($0)" })))
    }
}

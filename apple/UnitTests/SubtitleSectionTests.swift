import XCTest

/// Subtitle files put in time part by part (SubtitleSync.match): a file made
/// for another cut of the film is off by different amounts in different
/// parts. Regression: Asterix and Cleopatra's English file is 0.7 s early
/// for its first 8½ minutes, 6.5 s until the fortieth, 7.3 s after; the one
/// shift for the whole film (6.45 s) put its opening 6 s late ("the titles
/// appear after the sound").
final class SubtitleSectionTests: XCTestCase {
    /// A 72-minute film's spoken lines (fixed, varied lengths and gaps).
    private let spoken: [SubtitleSync.Cue] = {
        var random = Random(seed: 7)
        var cues: [SubtitleSync.Cue] = []
        var t = 2.0
        while t < 4300 {
            let length = 0.8 + random.next() * 3.7
            cues.append(.init(start: t, end: t + length))
            t += length + 0.2 + random.next() * 7.8
        }
        return cues
    }()

    /// How early the other cut's file is at each moment of the film.
    private func earlier(_ t: Double) -> Double { t < 520 ? 0.7 : t < 2390 ? 6.5 : 7.3 }

    /// The file made for the other cut: each line at the film's time less
    /// that.
    private var otherCut: [SubtitleSync.Cue] {
        spoken.map { .init(start: $0.start - earlier($0.start), end: $0.end - earlier($0.start)) }
    }

    /// Sixteen one-minute stretches across the film, as the app asks for:
    /// the classifier sure on most spoken lines, unsure on some, noise.
    private func heard(seed: UInt64 = 3) -> [SubtitleSync.Speech] {
        var random = Random(seed: seed)
        let step = SubtitleSync.speechStep
        return (0..<16).map { i in
            let start = (4340 * (0.02 + 0.06 * Double(i))).rounded()
            let confidence = (0..<Int(60 / step)).map { j -> Float in
                let t = start + Double(j) * step
                let speaking = spoken.contains { $0.start <= t && t < $0.end }
                let base = speaking ? (random.next() < 0.75 ? 0.8 : 0.15) : 0.1
                return Float(min(1, max(0, base + (random.next() - 0.5) * 0.3)))
            }
            return .init(start: start, confidence: confidence)
        }
    }

    /// Another language's file in time with the film: its lines start and
    /// end a little differently, and every seventh is joined to the one
    /// before (translations split lines their own way).
    private var otherLanguage: SubtitleSync.Reference {
        var random = Random(seed: 21)
        var cues: [SubtitleSync.Cue] = []
        for (i, line) in spoken.enumerated() {
            let start = line.start + (random.next() - 0.5) * 0.4, end = line.end + (random.next() - 0.5) * 0.4
            if i % 7 == 6, let last = cues.popLast() { cues.append(.init(start: last.start, end: end)) } else { cues.append(.init(start: start, end: end)) }
        }
        return .init(cues: cues, own: false)
    }

    private func srt(_ cues: [SubtitleSync.Cue]) -> String {
        func clock(_ s: Double) -> String {
            let ms = Int((s * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return cues.enumerated().map { "\($0.offset + 1)\n\(clock($0.element.start)) --> \(clock($0.element.end))\nWords \($0.offset).\n" }
            .joined(separator: "\n")
    }

    /// The share of the file's lines that end up within `tolerance` of the
    /// film's, once rewritten by `match`.
    private func inTime(_ match: SubtitleSync.Match, tolerance: Double = 0.3) -> Double {
        let moved = SubtitleSync.cues(SubtitleSync.retimed(srt(otherCut), by: match))
        let near = zip(moved, spoken).filter { abs($0.start - $1.start) <= tolerance }.count
        return Double(near) / Double(spoken.count)
    }

    /// The regression: by the speech and another language's file, three
    /// sections, every line in time. One shift for the whole film left the
    /// opening 5.8 s late.
    func testFileForAnotherCut() throws {
        let whole = try XCTUnwrap(SubtitleSync.fit(SubtitleSync.spokenCues(srt(otherCut)), toSpeech: heard()))
        XCTAssertGreaterThan(abs(whole.delay - 0.7), 5, "one shift would have suited the opening")

        let match = try XCTUnwrap(SubtitleSync.match(srt(otherCut), speech: heard(), references: [otherLanguage]))
        XCTAssertTrue(match.isGoodEnough)
        XCTAssertEqual(match.sections.count, 3, "\(match.sections)")
        guard match.sections.count == 3 else { return }
        for (section, delay) in zip(match.sections, [0.7, 6.5, 7.3]) {
            XCTAssertEqual(section.delay, delay, accuracy: 0.15)
            XCTAssertEqual(section.speed, 1)
        }
        // Each new section from a pause near the cut (the file's own times).
        XCTAssertEqual(match.sections[1].from, 520 - 0.7, accuracy: 40)
        XCTAssertEqual(match.sections[2].from, 2390 - 6.5, accuracy: 40)
        XCTAssertGreaterThan(inTime(match), 0.95)
    }

    /// The speech alone (no other file): the opening's section too.
    func testSpeechAloneFindsTheOpening() throws {
        let match = try XCTUnwrap(SubtitleSync.match(srt(otherCut), speech: heard(), references: []))
        XCTAssertGreaterThanOrEqual(match.sections.count, 2, "\(match.sections)")
        XCTAssertEqual(try XCTUnwrap(match.sections.first).delay, 0.7, accuracy: 0.3)
        XCTAssertGreaterThan(inTime(match, tolerance: 1), 0.9)
    }

    /// A file in time stays as it is: one section, no shift.
    func testInTimeFileIsOneSection() throws {
        let match = try XCTUnwrap(SubtitleSync.match(srt(spoken), speech: heard(), references: [otherLanguage]))
        XCTAssertEqual(match.sections.count, 1, "\(match.sections)")
        XCTAssertEqual(try XCTUnwrap(match.sections.first).delay, 0, accuracy: 0.1)
    }

    /// One part off on its own (twenty lines 3 s late, a slip in the
    /// file) doesn't make a section: films aren't cut for twenty lines.
    func testStrayPartIsNotASection() throws {
        let slipped = spoken.enumerated().map { i, line -> SubtitleSync.Cue in
            (300..<320).contains(i) ? .init(start: line.start + 3, end: line.end + 3) : line
        }
        let match = try XCTUnwrap(SubtitleSync.match(srt(slipped), speech: heard(), references: [otherLanguage]))
        XCTAssertEqual(match.sections.count, 1, "\(match.sections)")
    }

    /// A file for another release (a minute off, at another frame rate)
    /// isn't trusted as a reference: with nothing else, nothing to match.
    func testReferenceForAnotherReleaseIsNotTrusted() {
        let speed = 25 / 23.976
        let elsewhere = SubtitleSync.Reference(cues: spoken.map { .init(start: $0.start * speed - 58, end: $0.end * speed - 58) }, own: false)
        XCTAssertNil(SubtitleSync.match(srt(otherCut), speech: [], references: [elsewhere]))
    }

    /// The film's own track is trusted as it is.
    func testOwnTrackIsTrusted() throws {
        let match = try XCTUnwrap(SubtitleSync.match(srt(otherCut), speech: [], references: [.init(cues: spoken, own: true)]))
        XCTAssertEqual(match.sections.count, 3, "\(match.sections)")
        XCTAssertGreaterThan(inTime(match), 0.95)
    }

    /// Rewriting moves the times, section by section, and keeps the rest.
    func testRetimedKeepsTheText() {
        let match = SubtitleSync.Match(sections: [.init(from: 0, delay: 1, speed: 1), .init(from: 100, delay: -0.5, speed: 1)],
                                       score: 2, evenness: 1)
        let srt = "1\n00:00:10,000 --> 00:00:12,500\n<i>Barbares !</i>\n\n2\n00:02:00,000 --> 00:02:02,000\n- Hé, Bibi !\n"
        XCTAssertEqual(SubtitleSync.retimed(srt, by: match),
                       "1\n00:00:11,000 --> 00:00:13,500\n<i>Barbares !</i>\n\n2\n00:01:59,500 --> 00:02:01,500\n- Hé, Bibi !\n")
        let vtt = "WEBVTT\n\n00:00:10.000 --> 00:00:12.500 line:90%\nBonjour\n"
        XCTAssertEqual(SubtitleSync.retimed(vtt, by: match), "WEBVTT\n\n00:00:11.000 --> 00:00:13.500 line:90%\nBonjour\n")
        let ass = "[Events]\nFormat: Layer, Start, End, Style, Text\nDialogue: 0,0:00:10.00,0:00:12.50,Default,,0,0,0,,Bonjour, toi\n"
        XCTAssertEqual(SubtitleSync.retimed(ass, by: match),
                       "[Events]\nFormat: Layer, Start, End, Style, Text\nDialogue: 0,0:00:11.00,0:00:13.50,Default,,0,0,0,,Bonjour, toi\n")
    }

    /// A match good enough beats one that isn't, whatever its score.
    func testGoodEnoughComesFirst() {
        let sure = SubtitleSync.Match(sections: [.init(from: 0, delay: 0, speed: 1)], score: 1.2, evenness: 0.9)
        let uneven = SubtitleSync.Match(sections: [.init(from: 0, delay: 0, speed: 1)], score: 3, evenness: 0.5)
        XCTAssertTrue(sure.isGoodEnough)
        XCTAssertFalse(uneven.isGoodEnough)
        XCTAssertEqual([uneven, sure].max(), sure)
    }
}

private struct Random {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return Double((z ^ (z >> 31)) >> 11) / Double(1 << 53)
    }
}

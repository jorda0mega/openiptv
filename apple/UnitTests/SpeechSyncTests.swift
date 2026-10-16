import XCTest

/// Subtitle files put in time with the speech heard in the film, for films
/// with no subtitle track of their own (SubtitleSync.fit(_:toSpeech:)).
/// The speech is made from the film's true lines, as the sound classifier
/// hears it: sure on most spoken lines, unsure on some, music between.
final class SpeechSyncTests: XCTestCase {
    /// A 72-minute film's spoken lines (fixed, varied lengths and gaps).
    private let spoken: [SubtitleSync.Cue] = lines(seed: 7, gaps: 7.8)

    private static func lines(seed: UInt64, gaps: Double) -> [SubtitleSync.Cue] {
        var generator = Generator(seed: seed)
        var cues: [SubtitleSync.Cue] = []
        var t = 2.0
        while t < 4300 {
            let length = 0.8 + generator.next() * 3.7
            cues.append(.init(start: t, end: t + length))
            t += length + 0.2 + generator.next() * gaps
        }
        return cues
    }

    /// Eight one-minute stretches across the film, as the app asks for.
    private func heard(_ lines: [SubtitleSync.Cue], seed: UInt64 = 3) -> [SubtitleSync.Speech] {
        var generator = Generator(seed: seed)
        let step = SubtitleSync.speechStep
        return (0..<8).map { i in
            let start = (4340 * (0.06 + 0.11 * Double(i))).rounded()
            let confidence = (0..<Int(60 / step)).map { j -> Float in
                let t = start + Double(j) * step
                let speaking = lines.contains { $0.start <= t && t < $0.end }
                // Sure on most lines, missed on a quarter; noise everywhere.
                let base = speaking ? (generator.next() < 0.75 ? 0.8 : 0.15) : 0.1
                return Float(min(1, max(0, base + (generator.next() - 0.5) * 0.3)))
            }
            return .init(start: start, confidence: confidence)
        }
    }

    /// The file's times, made so that time × speed + delay = the film's.
    private func file(speed: Double = 1, delay: Double) -> [SubtitleSync.Cue] {
        spoken.map { .init(start: ($0.start - delay) / speed, end: ($0.end - delay) / speed) }
    }

    func testInTime() throws {
        let fit = try XCTUnwrap(SubtitleSync.fit(spoken, toSpeech: heard(spoken)))
        XCTAssertEqual(fit.delay, 0, accuracy: 0.1)
        XCTAssertEqual(fit.speed, 1)
    }

    /// Asterix and Cleopatra's English file: its lines 6.5 s early.
    func testEarlyFileIsShiftedLater() throws {
        let fit = try XCTUnwrap(SubtitleSync.fit(file(delay: 6.5), toSpeech: heard(spoken)))
        XCTAssertEqual(fit.delay, 6.5, accuracy: 0.1)
        XCTAssertEqual(fit.speed, 1)
    }

    /// Asterix the Gaul's English file: made for a release 4% slower, 6 s off.
    func testFileForAnotherRelease() throws {
        let fit = try XCTUnwrap(SubtitleSync.fit(file(speed: 23.976 / 25, delay: -6.05), toSpeech: heard(spoken)))
        XCTAssertEqual(fit.speed, 23.976 / 25, accuracy: 0.0001)
        XCTAssertEqual(fit.delay, -6.05, accuracy: 0.1)
    }

    /// Another film's lines match the speech nowhere in particular: left alone.
    func testAnotherFilmIsNotMatched() {
        for seed: UInt64 in [11, 12, 13] {
            XCTAssertNil(SubtitleSync.fit(Self.lines(seed: seed, gaps: 7.8), toSpeech: heard(spoken)), "seed \(seed)")
        }
    }

    /// Nothing heard (the server gave no sound): left alone.
    func testNothingHeard() {
        XCTAssertNil(SubtitleSync.fit(spoken, toSpeech: []))
    }

    /// Stretches are asked for so the first half already spans the film.
    func testStretchesSpreadAcrossTheFilm() {
        XCTAssertEqual(SubtitleSync.spread(Array(0..<16)), [0, 8, 4, 12, 2, 6, 10, 14, 1, 3, 5, 7, 9, 11, 13, 15])
        XCTAssertEqual(SubtitleSync.spread(Array(0..<5)), [0, 4, 2, 1, 3])
    }

    /// Lines that only describe a sound or music aren't speech.
    func testSoundDescriptionsAreNotSpoken() {
        let srt = """
        1
        00:10:01,100 --> 00:10:03,000
        Barbares !

        2
        00:10:15,800 --> 00:10:18,000
        (rires)

        3
        00:10:21,000 --> 00:10:23,200
        - [door slams]
        - <i>(musique)</i>

        4
        00:30:01,100 --> 00:30:03,200
        ♪ Je suis le marchand de chars ♪

        5
        00:30:05,100 --> 00:30:06,800
        - Hé, Bibi ! (Il rit.)
        """
        let cues = SubtitleSync.spokenCues(srt)
        XCTAssertEqual(cues.map(\.start), [601.1, 1805.1])
        XCTAssertEqual(SubtitleSync.cues(srt).count, 5)
    }
}

private struct Generator {
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

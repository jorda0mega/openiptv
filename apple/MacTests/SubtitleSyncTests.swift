import XCTest
@testable import OpenIPTV

/// Subtitle files put in time with the film by matching their lines against
/// the film's own subtitle track (SubtitleSync).
final class SubtitleSyncTests: XCTestCase {
    /// A 50-minute episode's lines (fixed, varied lengths and gaps).
    private let reference: [SubtitleSync.Cue] = {
        var generator = SplitMix(seed: 7)
        var cues: [SubtitleSync.Cue] = []
        var t = 2.0
        while t < 3000 {
            let length = 0.8 + generator.next() * 3.7
            cues.append(.init(start: t, end: t + length))
            t += length + 0.2 + generator.next() * 7.8
        }
        return cues
    }()

    /// The file's times, made so that time × speed + delay = the reference's.
    private func file(speed: Double = 1, delay: Double, dropEvery: Int = 0) -> [SubtitleSync.Cue] {
        reference.enumerated().filter { dropEvery == 0 || $0.offset % dropEvery != 0 }
            .map { .init(start: ($0.element.start - delay) / speed, end: ($0.element.end - delay) / speed) }
    }

    func testInTime() throws {
        let fit = try XCTUnwrap(SubtitleSync.fit(reference, to: reference))
        XCTAssertEqual(fit.delay, 0, accuracy: 0.05)
        XCTAssertEqual(fit.speed, 1)
    }

    func testLateFileIsShiftedEarlier() throws {
        let fit = try XCTUnwrap(SubtitleSync.fit(file(delay: -2.5), to: reference))
        XCTAssertEqual(fit.delay, -2.5, accuracy: 0.05)
        XCTAssertEqual(fit.speed, 1)
    }

    func testFarOffFile() throws {
        XCTAssertEqual(try XCTUnwrap(SubtitleSync.fit(file(delay: 40), to: reference)).delay, 40, accuracy: 0.05)
    }

    func testFileForAnotherFrameRate() throws {
        let fit = try XCTUnwrap(SubtitleSync.fit(file(speed: 25 / 23.976, delay: 1.2), to: reference))
        XCTAssertEqual(fit.speed, 25 / 23.976, accuracy: 0.0001)
        XCTAssertEqual(fit.delay, 1.2, accuracy: 0.05)
    }

    func testFileMissingLines() throws {
        XCTAssertEqual(try XCTUnwrap(SubtitleSync.fit(file(delay: -2.5, dropEvery: 4), to: reference)).delay, -2.5, accuracy: 0.05)
    }

    /// Another film's lines match nowhere in particular: left alone.
    func testAnotherFilmIsNotMatched() {
        for (seed, gaps) in [(11, 0.2), (12, 3.0), (13, 8.0)] {
            var generator = SplitMix(seed: UInt64(seed))
            var other: [SubtitleSync.Cue] = []
            var t = 2.0
            while t < 3000 {
                let length = 0.8 + generator.next() * 3.7
                other.append(.init(start: t, end: t + length))
                t += length + 0.2 + generator.next() * gaps
            }
            XCTAssertNil(SubtitleSync.fit(other, to: reference), "matched another film (gaps up to \(gaps) s)")
        }
    }

    func testReadsSRTAndASS() {
        let srt = "1\n00:00:01,500 --> 00:00:03,000\nHello\n\n2\n01:02:03,250 --> 01:02:04,000\nAgain\n"
        XCTAssertEqual(SubtitleSync.cues(srt), [.init(start: 1.5, end: 3), .init(start: 3723.25, end: 3724)])
        let ass = "[Events]\nFormat: Layer, Start, End, Style, Text\nDialogue: 0,0:00:01.50,0:00:03.00,Default,,0,0,0,,Hello\n"
        XCTAssertEqual(SubtitleSync.cues(ass), [.init(start: 1.5, end: 3)])
    }
}

/// A small fixed-seed random source (the same lines every run).
private struct SplitMix {
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

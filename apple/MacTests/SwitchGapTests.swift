import XCTest
@testable import OpenIPTV

final class SwitchGapTests: XCTestCase {
    func testSteadyPlaybackHasNoStall() {
        var gap = SwitchGap(.start, at: 0)
        for i in 0...100 {
            let wall = Double(i) / 100
            gap.sample(at: wall, time: 60 + Double(i / 4 * 4) / 100, audio: 60 + wall)
            if i % 4 == 0 { gap.frame(at: wall) }
        }
        XCTAssertEqual(gap.readout(until: 1), "start seeks=0 restarts=0 paused=0 time=30 audio=0 frames=40")
    }

    func testAFrozenClockIsAStall() {
        let readings = [(0.0, 10.0), (0.5, 10.5), (1.3, 10.5), (1.5, 10.7)]
        XCTAssertEqual(SwitchGap.longestStall(readings), 0.8, accuracy: 1e-9)
    }

    func testAClockReadLateButMovedOnIsNoStall() {
        let readings = [(0.0, 10.0), (0.01, 10.01), (0.9, 10.9), (0.91, 10.91)]
        XCTAssertEqual(SwitchGap.longestStall(readings), 0, accuracy: 1e-9)
    }

    func testAPauseIsCountedApartFromStalls() {
        var gap = SwitchGap(.start, at: 0)
        gap.sample(at: 0, time: 10, audio: 10)
        gap.sample(at: 0.1, time: 10.1, audio: 10.1)
        gap.sample(at: 0.2, time: 10.2, audio: 10.2, paused: true)
        gap.sample(at: 2.2, time: 10.2, audio: 10.2, paused: true)
        gap.sample(at: 2.3, time: 10.2, audio: 10.2)
        gap.sample(at: 2.4, time: 10.3, audio: 10.3)
        XCTAssertTrue(gap.readout(until: 2.4).hasPrefix("start seeks=0 restarts=0 paused=2100 time=0 audio=0 "), gap.readout(until: 2.4))
    }

    func testFramesWaitFromTheSwitchAndToItsEnd() {
        var gap = SwitchGap(.return, at: 10)
        gap.frame(at: 9.9)
        gap.frame(at: 10.7)
        gap.frame(at: 10.74)
        XCTAssertTrue(gap.readout(until: 11).hasSuffix("frames=700"), gap.readout(until: 11))
        XCTAssertTrue(gap.readout(until: 12).hasSuffix("frames=1260"), gap.readout(until: 12))
    }

    func testSeeksAndRestartsAreCounted() {
        var gap = SwitchGap(.start, at: 0)
        gap.seeked()
        gap.restarted()
        gap.restarted()
        XCTAssertTrue(gap.readout(until: 0).hasPrefix("start seeks=1 restarts=2 "), gap.readout(until: 0))
    }
}

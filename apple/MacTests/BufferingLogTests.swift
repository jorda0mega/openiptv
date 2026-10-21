import XCTest
@testable import OpenIPTV

final class BufferingLogTests: XCTestCase {
    func testAStallAfterTheFirstFrameIsARebuffer() {
        var log = BufferingLog()
        log.opening(converted: false)
        log.stalled(true, at: 1)
        log.stalled(false, at: 3)
        log.firstFrame(after: 2.5)
        log.stalled(true, at: 10)
        log.stalled(false, at: 10.75)
        XCTAssertEqual(log.rebuffers, [0.75], "the wait for the first frame counted as a rebuffer")
    }

    func testAStallStillOnIsSaid() {
        var log = BufferingLog()
        log.opening(converted: false)
        log.firstFrame(after: 0.5)
        log.stalled(true, at: 20)
        XCTAssertTrue(log.readout.contains("stalled now"), log.readout)
    }

    func testEachOpenIsTimedByWhatItOpened() {
        var log = BufferingLog()
        log.opening(converted: false)
        log.firstFrame(after: 0.62)
        log.opening(converted: true)
        log.firstFrame(after: 3.1)
        XCTAssertTrue(log.readout.contains("opens: original 0.62 s, converted 3.10 s"), log.readout)
    }

    func testAConvertedOpenIsSplitIntoTheServersWaitsAndTheRest() {
        var waits = ServerWaits()
        waits.asked(on: 1, at: 0.1)
        waits.answered(on: 1, at: 0.2)
        waits.segmentComing()
        waits.asked(on: 2, at: 0.3)
        waits.answered(on: 2, at: 6.3)
        waits.answered(on: 2, at: 6.31)
        waits.segmentComing()
        waits.asked(on: 2, at: 6.5)
        waits.answered(on: 2, at: 12.5)
        var log = BufferingLog()
        log.opening(converted: true)
        log.firstFrame(after: 13, waits: waits)
        XCTAssertTrue(log.readout.contains("opens: converted 13.00 s: server 12100 ms client 900 ms (p100 s6000 s6000)"), log.readout)
    }

    func testRequestsWaitingTogetherCountOnce() {
        var waits = ServerWaits()
        waits.fetched(.playlist, from: 0, to: 1)
        waits.segmentComing()
        waits.asked(on: 7, at: 2)
        waits.segmentComing()
        waits.asked(on: 8, at: 3)
        waits.answered(on: 8, at: 5)
        waits.answered(on: 7, at: 6)
        XCTAssertEqual(waits.server, 5, accuracy: 1e-9)
    }

    func testAnAudioSwitchIsTimedToItsSound() {
        var log = BufferingLog()
        log.opening(converted: false)
        log.firstFrame(after: 0.5)
        log.audioReconfigured(at: 5)
        log.audioAsked(at: 30)
        log.audioReconfigured(at: 30.5)
        XCTAssertEqual(log.audioSwitches, [0.5], "the audio set up at the start counted as a switch")
    }

    func testJumpsAndTheCacheAreSaid() {
        var log = BufferingLog()
        log.opening(converted: false)
        log.firstFrame(after: 0.5)
        log.seeked(after: 1.2, megabytes: 12.34)
        log.cacheSeconds = 34.4
        log.bytesPerSecond = 3_200_000
        let readout = log.readout
        XCTAssertTrue(readout.contains("rebuffers 0"), readout)
        XCTAssertTrue(readout.contains("cache 34 s"), readout)
        XCTAssertTrue(readout.contains("speed 3.2 MB/s"), readout)
        XCTAssertTrue(readout.contains("jumps: 1200 ms 12.3 MB"), readout)
    }
}

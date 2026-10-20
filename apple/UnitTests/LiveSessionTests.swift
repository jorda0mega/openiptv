import XCTest

final class LiveSessionTests: XCTestCase {
    private struct C: Identifiable, Equatable { let id: String }
    private typealias Session = LiveSession<C>

    private let a = C(id: "a"), b = C(id: "b"), c = C(id: "c")

    private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: 1000 + seconds) }

    private func opening(_ feeds: [[C]]? = nil, after: Double = 0) -> Session {
        var session = Session()
        _ = session.handle(.play(a, feeds: feeds ?? [[a, b], [c]], after: after, startLimit: 15), now: at(0))
        _ = session.handle(.opening(session.attempt), now: at(0.5))
        return session
    }

    private func playing(_ feeds: [[C]]? = nil) -> Session {
        var session = opening(feeds)
        _ = session.handle(.started(session.attempt), now: at(1))
        return session
    }

    func testTheDeadlineStartsAtTheRequest() {
        var session = Session()
        XCTAssertEqual(session.handle(.play(a, feeds: [[a]], after: 0.35, startLimit: 25), now: at(0)),
                       [.unpause, .clearTimeline, .load(a, 1, after: 0.35)], "a deadline before the stream was asked for")
        XCTAssertEqual(session.handle(.opening(1), now: at(2)), [.deadline(1, after: 25)])
        XCTAssertEqual(session.readout, "starting")
    }

    func testOlderAttemptsChangeNothing() {
        var session = opening()
        let first = session.attempt
        _ = session.handle(.play(b, feeds: [[a, b]], after: 0, startLimit: 15), now: at(2))
        let second = session.attempt
        XCTAssertNotEqual(first, second)
        for input: Session.Input in [.started(first), .opening(first), .failed(first, .no_data, shown: .notPlaying),
                                     .ended(first, .eof_before_frame)] {
            XCTAssertEqual(session.handle(input, now: at(3)), [], "an input from the copy zapped away from: \(input)")
            XCTAssertEqual(session.phase, .opening(b))
        }
        XCTAssertEqual(session.handle(.opening(second), now: at(3)), [.deadline(second, after: 15)], "the late start cancelled the deadline")
        XCTAssertEqual(session.handle(.timedOut(second, .no_data), now: at(18)).prefix(2), [.cancelDeadline, .markFailed(b)])
    }

    func testNothingReloadsAfterGivingUp() {
        var session = opening([[a]])
        let given = session.attempt
        XCTAssertEqual(session.handle(.timedOut(given, .no_data), now: at(15)), [.cancelDeadline, .markFailed(a), .markNotPlaying, .stop])
        XCTAssertEqual(session.phase, .failed(.notPlaying))
        XCTAssertEqual(session.handle(.failed(given, .timeout, shown: .message("late")), now: at(60)), [], "a late timeout reloaded")
        XCTAssertEqual(session.handle(.started(given), now: at(61)), [], "a late start cleared the marks")
        XCTAssertEqual(session.failure, .notPlaying)
    }

    func testARefusalRightAfterAReleaseIsTriedOnceMore() {
        var session = opening([[a]])
        let retry = session.handle(.failed(session.attempt, .http_403, shown: .message("403")), now: at(1))
        XCTAssertEqual(retry, [.cancelDeadline, .load(a, session.attempt, after: 2.5)])
        _ = session.handle(.opening(session.attempt), now: at(3.5))
        XCTAssertEqual(session.handle(.failed(session.attempt, .http_403, shown: .message("403")), now: at(3.75)), [.cancelDeadline, .stop],
                       "a second refusal didn't stop")
        XCTAssertEqual(session.failure, .message("403"))

        var late = opening([[a]])
        XCTAssertEqual(late.handle(.failed(late.attempt, .http_401, shown: .message("401")), now: at(5)), [.cancelDeadline, .stop],
                       "a refusal long after any release was tried again")
    }

    func testAFailedReopenMovesToTheNextCopy() {
        var session = playing()
        XCTAssertEqual(session.handle(.ended(session.attempt, .eof_before_frame), now: at(30)),
                       [.clearTimeline, .load(a, session.attempt, after: 0)], "an end after a picture isn't a cut")
        XCTAssertEqual(session.readout, "reopening")
        let actions = session.handle(.failed(session.attempt, .no_data, shown: .notPlaying), now: at(45))
        XCTAssertEqual(actions, [.markFailed(a), .switching(from: a), .clearTimeline, .load(b, session.attempt, after: 0)],
                       "a reopen that sent nothing was counted as another cut")
        XCTAssertEqual(session.phase, .opening(b))
    }

    func testAddressLookupFailuresFollowThePolicy() {
        var offline = opening()
        XCTAssertEqual(offline.handle(.failed(offline.attempt, .offline, shown: .message("No internet connection.")), now: at(1)),
                       [.cancelDeadline, .stop, .waitForNetwork])
        XCTAssertEqual(offline.readout, "waiting")
        XCTAssertEqual(offline.handle(.online, now: at(9)), [.clearTimeline, .load(a, offline.attempt, after: 0)])

        var busy = opening()
        XCTAssertEqual(busy.handle(.failed(busy.attempt, .http_429, shown: .message("busy")), now: at(1)), [.cancelDeadline, .stop])
        XCTAssertEqual(busy.failure, .message("busy"))

        var slow = opening()
        XCTAssertEqual(slow.handle(.failed(slow.attempt, .timeout, shown: .message("too long")), now: at(1)),
                       [.cancelDeadline, .load(a, slow.attempt, after: 1)], "a lookup that timed out wasn't tried once more")
        var refused = opening()
        XCTAssertEqual(refused.handle(.failed(refused.attempt, .refused, shown: .message("refused")), now: at(1)),
                       [.cancelDeadline, .stop], "a portal that refused the connection marked the channel")
    }

    func testAQuickReturnRetriesTheRefusal() {
        var session = playing([[a]])
        _ = session.handle(.paused(true), now: at(5))
        XCTAssertEqual(session.handle(.away(keepsStream: false), now: at(10)), [.stop])
        XCTAssertEqual(session.readout, "away")
        XCTAssertEqual(session.handle(.back, now: at(11)), [.unpause, .clearTimeline, .load(a, session.attempt, after: 0)])
        _ = session.handle(.opening(session.attempt), now: at(11.5))
        let retry = session.handle(.failed(session.attempt, .http_403, shown: .message("403")), now: at(12))
        XCTAssertEqual(retry, [.cancelDeadline, .load(a, session.attempt, after: 2.5)], "a quick return ended on the refusal")
    }

    func testACutWhilePausedWaitsForPlay() {
        var session = playing()
        _ = session.handle(.paused(true), now: at(5))
        XCTAssertEqual(session.handle(.ended(session.attempt, .eof_before_frame), now: at(20)), [], "a cut while paused reopened")
        XCTAssertEqual(session.phase, .cutWhilePaused(a))
        XCTAssertEqual(session.handle(.paused(false), now: at(40)), [.clearTimeline, .load(a, session.attempt, after: 0)])
        XCTAssertEqual(session.readout, "reopening")
    }

    func testAwayIgnoresTheClosedStream() {
        var session = playing()
        let closed = session.attempt
        _ = session.handle(.paused(true), now: at(5))
        XCTAssertEqual(session.handle(.away(keepsStream: false), now: at(6)), [.stop])
        for input: Session.Input in [.ended(closed, .eof_before_frame), .failed(closed, .reset, shown: .message("x")), .started(closed)] {
            XCTAssertEqual(session.handle(input, now: at(7)), [], "the closed stream acted while away: \(input)")
        }
        XCTAssertEqual(session.phase, .away(a))
    }

    func testAirPlayKeepsTheStreamOnIPhoneOnly() {
        XCTAssertTrue(Session.keepsStreamAway(airPlay: true, onTV: false))
        XCTAssertFalse(Session.keepsStreamAway(airPlay: true, onTV: true), "an Apple TV's AirPlay speakers kept the stream")
        XCTAssertFalse(Session.keepsStreamAway(airPlay: false, onTV: false))
        var session = playing()
        _ = session.handle(.paused(true), now: at(5))
        XCTAssertEqual(session.handle(.away(keepsStream: true), now: at(6)), [])
        XCTAssertEqual(session.phase, .playing(a))
    }

    func testGivingUpOnCutsMarksNothing() {
        var session = playing()
        for second in [10.0, 20, 30] {
            _ = session.handle(.ended(session.attempt, .eof_before_frame), now: at(second))
            _ = session.handle(.started(session.attempt), now: at(second + 1))
        }
        let actions = session.handle(.ended(session.attempt, .eof_before_frame), now: at(40))
        XCTAssertEqual(actions, [.switching(from: a), .clearTimeline, .load(b, session.attempt, after: 0)])
        XCTAssertFalse(actions.contains(.markFailed(a)), "a copy that played was marked as not playing")
    }

    func testPlayStartsTheCutsOver() {
        var session = playing()
        for second in [10.0, 20, 30] {
            _ = session.handle(.ended(session.attempt, .eof_before_frame), now: at(second))
            _ = session.handle(.started(session.attempt), now: at(second + 1))
        }
        _ = session.handle(.play(a, feeds: [[a, b]], after: 0, startLimit: 15), now: at(35))
        _ = session.handle(.opening(session.attempt), now: at(35))
        _ = session.handle(.started(session.attempt), now: at(36))
        XCTAssertEqual(session.handle(.ended(session.attempt, .eof_before_frame), now: at(40)),
                       [.clearTimeline, .load(a, session.attempt, after: 0)], "Retry kept the cuts from before")
    }

    func testOfflineAfterThePictureIsNotACut() {
        var session = playing()
        XCTAssertEqual(session.handle(.ended(session.attempt, .offline), now: at(10)), [.stop, .waitForNetwork])
        XCTAssertEqual(session.readout, "waiting")
        XCTAssertTrue(session.hasPicture)
        XCTAssertEqual(session.handle(.online, now: at(20)), [.clearTimeline, .load(a, session.attempt, after: 0)])
        XCTAssertEqual(session.readout, "reopening")
    }

    func testAFlakyCopyIsTriedOnceMore() {
        var session = opening()
        let retry = session.handle(.failed(session.attempt, .http_5xx, shown: .message("503")), now: at(1))
        XCTAssertEqual(retry, [.cancelDeadline, .load(a, session.attempt, after: 1)])
        XCTAssertEqual(session.handle(.failed(session.attempt, .http_5xx, shown: .message("503")), now: at(3)).prefix(2),
                       [.markFailed(a), .switching(from: a)])
    }

    func testTheNextCopyPlayingEndsTheCue() {
        var session = opening()
        _ = session.handle(.failed(session.attempt, .http_404, shown: .message("404")), now: at(1))
        _ = session.handle(.opening(session.attempt), now: at(1.5))
        XCTAssertEqual(session.handle(.started(session.attempt), now: at(2)), [.cancelDeadline, .picture, .played(b), .switched(from: a, to: b)])
        XCTAssertEqual(session.phase, .playing(b))
    }

    func testTheFirstPictureEndsTheDeadline() {
        var session = opening()
        let shown = session.attempt
        XCTAssertEqual(session.handle(.started(shown), now: at(1)), [.cancelDeadline, .picture, .played(a)])
        XCTAssertEqual(session.handle(.timedOut(shown, .no_data), now: at(15.5)), [], "the start limit cut a stream that plays")
        XCTAssertEqual(session.phase, .playing(a))
    }

    func testEveryWayOutOfTheOpenEndsTheDeadline() {
        var stopped = opening([[a]])
        XCTAssertEqual(stopped.handle(.failed(stopped.attempt, .http_429, shown: .message("busy")), now: at(1)).first, .cancelDeadline)
        var closed = opening()
        XCTAssertEqual(closed.handle(.closed, now: at(1)), [.cancelDeadline])
        var moved = opening()
        XCTAssertEqual(moved.handle(.play(b, feeds: [[b]], after: 0, startLimit: 15), now: at(1)).first, .cancelDeadline)
    }

    func testPausedWithNoNetworkWaitsForPlay() {
        var session = playing()
        _ = session.handle(.paused(true), now: at(5))
        XCTAssertEqual(session.handle(.ended(session.attempt, .offline), now: at(10)), [.stop, .waitForNetwork])
        XCTAssertEqual(session.handle(.online, now: at(20)), [], "the network coming back reopened paused live TV")
        XCTAssertEqual(session.phase, .cutWhilePaused(a))
        XCTAssertEqual(session.handle(.paused(false), now: at(30)), [.clearTimeline, .load(a, session.attempt, after: 0)])
    }

    func testAwayWithNoNetworkStaysClosed() {
        var session = playing()
        _ = session.handle(.paused(true), now: at(5))
        _ = session.handle(.ended(session.attempt, .offline), now: at(10))
        XCTAssertEqual(session.handle(.away(keepsStream: false), now: at(11)), [.stop])
        XCTAssertEqual(session.phase, .away(a))
        XCTAssertEqual(session.handle(.online, now: at(20)), [], "the network coming back reopened live TV in the background")
        XCTAssertEqual(session.handle(.back, now: at(30)), [.unpause, .clearTimeline, .load(a, session.attempt, after: 0)])
    }

    func testOfflineRecoveriesWhilePausedAreNotCuts() {
        var session = playing([[a, b]])
        var second = 10.0
        for _ in 0..<4 {
            _ = session.handle(.paused(true), now: at(second))
            _ = session.handle(.ended(session.attempt, .offline), now: at(second + 1))
            _ = session.handle(.online, now: at(second + 5))
            XCTAssertEqual(session.handle(.paused(false), now: at(second + 10)), [.clearTimeline, .load(a, session.attempt, after: 0)],
                           "a pause with no network was counted as a cut")
            _ = session.handle(.started(session.attempt), now: at(second + 11))
            second += 20
        }
        XCTAssertEqual(session.phase, .playing(a))
    }

    func testOnlyRealCutsCountTowardsGivingUp() {
        var session = playing([[a, b]])
        for second in [10.0, 20, 30] {
            _ = session.handle(.ended(session.attempt, .eof_before_frame), now: at(second))
            _ = session.handle(.started(session.attempt), now: at(second + 1))
        }
        _ = session.handle(.paused(true), now: at(35))
        _ = session.handle(.ended(session.attempt, .offline), now: at(36))
        _ = session.handle(.online, now: at(40))
        XCTAssertEqual(session.handle(.paused(false), now: at(42)), [.clearTimeline, .load(a, session.attempt, after: 0)],
                       "a pause with no network gave the copy up")
        _ = session.handle(.started(session.attempt), now: at(43))
        XCTAssertEqual(session.handle(.ended(session.attempt, .eof_before_frame), now: at(50)).prefix(1), [.switching(from: a)],
                       "the fourth real cut kept the copy")
    }

    func testAPauseAfterLeavingStillFreesTheStream() {
        var session = playing()
        XCTAssertEqual(session.handle(.away(keepsStream: false), now: at(5)), [], "playing live TV closed in the background")
        XCTAssertEqual(session.handle(.paused(true), now: at(5.5)), [.stop], "a pause that landed after leaving kept the stream")
        XCTAssertEqual(session.phase, .away(a))
        XCTAssertEqual(session.handle(.back, now: at(30)), [.unpause, .clearTimeline, .load(a, session.attempt, after: 0)])

        var airPlay = playing()
        _ = airPlay.handle(.away(keepsStream: true), now: at(5))
        XCTAssertEqual(airPlay.handle(.paused(true), now: at(5.5)), [], "AirPlay's stream was closed")
        var front = playing()
        _ = front.handle(.away(keepsStream: false), now: at(5))
        _ = front.handle(.back, now: at(6))
        XCTAssertEqual(front.handle(.paused(true), now: at(7)), [], "a pause back in the app closed the stream")
    }

    func testClosingDropsWhatComesAfter() {
        var session = playing()
        let last = session.attempt
        XCTAssertEqual(session.handle(.closed, now: at(5)), [])
        for input: Session.Input in [.started(last), .opening(last), .ended(last, .eof_before_frame), .online, .back,
                                     .failed(last, .reset, shown: .message("x"))] {
            XCTAssertEqual(session.handle(input, now: at(6)), [], "the closed screen acted: \(input)")
        }
        XCTAssertEqual(session.phase, .closed)
    }

    func testRecording() {
        var session = playing()
        XCTAssertEqual(session.handle(.recording, now: at(5)), [.clearTimeline, .unpause, .loadRecording(session.attempt)])
        XCTAssertEqual(session.handle(.opening(session.attempt), now: at(5.5)), [], "a recording got a start deadline")
        XCTAssertEqual(session.handle(.started(session.attempt), now: at(6)), [.picture])
        XCTAssertEqual(session.handle(.ended(session.attempt, .eof_before_frame), now: at(600)), [.goLive])
    }
}

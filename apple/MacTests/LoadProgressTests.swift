import XCTest
@testable import OpenIPTV

final class LoadProgressTests: XCTestCase {
    private let tap = Date(timeIntervalSinceReferenceDate: 1000)

    private func at(_ seconds: Double) -> Date { tap.addingTimeInterval(seconds) }

    private func film(_ stage: LoadProgress.Stage, cause: LoadProgress.Cause = .server) -> LoadProgress {
        LoadProgress(subject: .film("Heat"), stage: stage, cause: cause, began: tap)
    }

    private func channel(_ stage: LoadProgress.Stage, cause: LoadProgress.Cause = .channel,
                         wait: LoadProgress.Wait = .start) -> LoadProgress {
        LoadProgress(subject: .channel("PPV 1"), wait: wait, stage: stage, cause: cause, began: tap)
    }

    func testTheFirstSecondDrawsNothing() {
        for load in [film(.asking), film(.fetching), channel(.asking)] {
            XCTAssertEqual(load.shown(at: at(0.6)), LoadProgress.Shown(), "a quick start flashed something")
        }
    }

    func testFromOneSecondANormalStartIsTheRingAlone() {
        let starts = [film(.asking), film(.fetching), film(.starting), channel(.asking), channel(.fetching), channel(.starting)]
        let shown = starts.map { $0.shown(at: at(2)) }
        for one in shown {
            XCTAssertNotNil(one?.ring, "no ring at 2 s")
            XCTAssertNil(one?.line, "a step named: \(one?.line ?? "")")
            XCTAssertEqual(one?.details, [])
            XCTAssertEqual(one?.buttons, [])
        }
        XCTAssertEqual(Set(shown.map { $0?.ring }).count, 1, "the ring changed as the start went on")
        XCTAssertEqual(film(.asking).shown(at: at(2)), film(.asking).shown(at: at(7.9)), "the view changed before 8 s")
    }

    func testFromEightSecondsOneLineNamesWhatIsSlow() {
        let slow: [(LoadProgress, String)] = [
            (film(.asking), "Your server is slow to answer · 12 s"),
            (film(.fetching), "Your server is slow to answer · 12 s"),
            (film(.starting), "Your server is slow to send the film · 12 s"),
            (channel(.asking, cause: .server), "Your TV provider is slow to answer · 12 s"),
            (channel(.fetching), "The channel is slow to send · 12 s"),
            (film(.fetching, cause: .connection), "Your connection is slow · 12 s"),
            (channel(.asking, cause: .offline), "No internet connection · 12 s"),
        ]
        for (load, line) in slow {
            let shown = load.shown(at: at(12.4))
            XCTAssertNil(shown?.line, "\(line): a step line above it")
            XCTAssertEqual(shown?.details, [line])
            XCTAssertEqual(shown?.tryAgain, true, "\(line): no Try again")
            XCTAssertNotNil(shown?.ring, "\(line): the ring went")
        }
        XCTAssertEqual(film(.asking).shown(at: at(7.9))?.details, [], "slow before 8 s")
        XCTAssertEqual(film(.asking).shown(at: at(8))?.details, ["Your server is slow to answer · 8 s"])
    }

    func testAQuickStartHoldsTheRingHalfASecondOrNeverShowsIt() {
        var quick = film(.fetching)
        quick.endedAt = at(1.2)
        XCTAssertNotNil(quick.shown(at: at(1.3))?.ring, "the ring flashed off 0.2 s after it came")
        XCTAssertNil(quick.shown(at: at(1.5)))
        XCTAssertNil(quick.deadline, "a finished start still has a deadline")
        var quicker = film(.fetching)
        quicker.endedAt = at(0.8)
        XCTAssertNil(quicker.shown(at: at(0.9)), "a start done before 1 s showed something")
        XCTAssertNil(quicker.shown(at: at(1.2)), "the ring came after the picture")
        var slow = film(.fetching)
        slow.endedAt = at(4)
        XCTAssertNil(slow.shown(at: at(4.1)), "the ring stayed over the picture")
    }

    func testAFailureNamesTheChannelAndTheTries() {
        var load = channel(.asking)
        load.failure = .init(kind: .noPicture, tries: 4, seconds: 30.2, otherChannels: true)
        let shown = load.shown(at: at(31))
        XCTAssertNil(shown?.ring, "it still spins after giving up")
        XCTAssertEqual(shown?.line, "PPV 1 isn’t sending a picture")
        XCTAssertEqual(shown?.details, ["The app tried 4 times in 30 s."])
        XCTAssertEqual(shown?.tryAgain, true)
        XCTAssertEqual(shown?.otherChannels, true)
        XCTAssertEqual(shown?.buttons, [.tryAgain, .otherChannels], "the remote's first stop isn't Try again")
    }

    func testOtherChannelsOnlyWhenAnotherChannelHasTheEvent() {
        var load = channel(.asking)
        load.failure = .init(kind: .noPicture, tries: 1, seconds: 15)
        XCTAssertEqual(load.shown(at: at(15))?.otherChannels, false)
        var film = film(.fetching)
        film.failure = .init(kind: .noPicture, tries: 2, seconds: 30, otherChannels: true)
        XCTAssertEqual(film.shown(at: at(30))?.otherChannels, false, "a film has no other channels")
    }

    func testEachFailureSaysWhatHappened() {
        let failures: [(LoadProgress, LoadProgress.Failure.Kind, String, [String])] = [
            (channel(.fetching), .ended, "PPV 1 stopped before it started", ["The app tried once in 6 s."]),
            (channel(.asking), .refused("The provider allows one stream at a time."), "PPV 1 didn’t open",
             ["The provider allows one stream at a time.", "The app tried once in 6 s."]),
            (film(.fetching), .noPicture, "Your server isn’t sending Heat", ["The app tried once in 6 s."]),
            (film(.fetching), .refused("The server answered 404 to every way of opening it."), "Heat didn’t open",
             ["The server answered 404 to every way of opening it.", "The app tried once in 6 s."]),
        ]
        for (load, kind, line, details) in failures {
            var load = load
            load.failure = .init(kind: kind, tries: 1, seconds: 6)
            let shown = load.shown(at: at(6))
            XCTAssertEqual(shown?.line, line)
            XCTAssertEqual(shown?.details, details, line)
        }
    }

    func testAFilmCutOffMidPlaySaysTheServerStoppedSendingIt() {
        var load = film(.fetching)
        load.failure = .init(kind: .cutOff, tries: 1, seconds: 27)
        let shown = load.shown(at: at(27))
        XCTAssertEqual(shown?.line, "Your server stopped sending Heat")
        XCTAssertEqual(shown?.details, ["The app tried once in 27 s."])
        XCTAssertEqual(shown?.tryAgain, true)
        XCTAssertNil(shown?.ring)
    }

    func testATryInUnderASecondCountsAsOne() {
        var load = channel(.asking)
        load.failure = .init(kind: .refused("Your provider turned the stream away."), tries: 1, seconds: 0.2)
        XCTAssertEqual(load.shown(at: at(0.2))?.details.last, "The app tried once in 1 s.")
    }

    func testADropShowsNothingForThreeSecondsThenReconnecting() {
        let drop = channel(.asking, wait: .reconnect)
        XCTAssertNil(drop.shown(at: at(2.9)), "a short drop flashed the progress")
        let shown = drop.shown(at: at(3))
        XCTAssertEqual(shown?.line, "Reconnecting to PPV 1…")
        XCTAssertNotNil(shown?.ring)
        XCTAssertEqual(shown?.tryAgain, false)
        XCTAssertEqual(channel(.fetching, wait: .reconnect).shown(at: at(4))?.line, "Reconnecting to PPV 1…")
        let slow = drop.shown(at: at(9))
        XCTAssertEqual(slow?.details, ["The channel is slow to send · 9 s"])
        XCTAssertEqual(slow?.tryAgain, true)
    }

    func testAStallShowsTheRingAloneAfterThreeSeconds() {
        let stall = LoadProgress(subject: .film("Heat"), wait: .stall, stage: .fetching, cause: .server, began: tap)
        XCTAssertNil(stall.shown(at: at(2)))
        let shown = stall.shown(at: at(4))
        XCTAssertNotNil(shown?.ring)
        XCTAssertNil(shown?.line, "a stall named a step it isn't on")
        XCTAssertEqual(stall.shown(at: at(10))?.details, ["Your server is slow to send the film · 10 s"], "the server answered long ago")
        XCTAssertEqual(stall.shown(at: at(10))?.tryAgain, true)
    }

    func testEveryWaitEndsThirtySecondsAfterItBegan() {
        let trickle = film(.starting)
        XCTAssertEqual(trickle.deadline, at(30))
        XCTAssertFalse(trickle.overdue(at: at(29.9)))
        XCTAssertTrue(trickle.overdue(at: at(30)), "a film sending a few bytes now and then still spins at 30 s")
        XCTAssertTrue(channel(.asking, cause: .offline, wait: .reconnect).overdue(at: at(31)), "offline, it waits forever")
        let stall = LoadProgress(subject: .film("Heat"), wait: .stall, stage: .fetching, cause: .server, began: tap)
        XCTAssertTrue(stall.overdue(at: at(30)), "a stall during play spins forever")
        var failed = trickle
        failed.failure = .init(kind: .noPicture, tries: 1, seconds: 30)
        XCTAssertNil(failed.deadline, "a failure still has a deadline to fire")
        XCTAssertFalse(failed.overdue(at: at(600)))
    }

    func testAFailureAfterADropShowsAtOnce() {
        var drop = channel(.asking, wait: .reconnect)
        drop.failure = .init(kind: .noPicture, tries: 3, seconds: 1)
        XCTAssertEqual(drop.shown(at: at(1))?.line, "PPV 1 isn’t sending a picture")
    }
}

final class LoadTrackTests: XCTestCase {
    private let tap = Date(timeIntervalSinceReferenceDate: 1000)

    private func at(_ seconds: Double) -> Date { tap.addingTimeInterval(seconds) }

    func testAChannelConnectsThenGetsThePicture() {
        var track = LoadTrack(began: tap)
        track.asked(at: at(0))
        XCTAssertEqual(track.stage, .asking)
        XCTAssertFalse(track.addressed)
        track.gotAddress()
        XCTAssertTrue(track.addressed)
        track.opened()
        XCTAssertEqual(track.stage, .fetching)
    }

    func testAFilmOpensItsFileThenStarts() {
        var track = LoadTrack(began: tap, stage: .fetching)
        track.asked(.fetching, at: at(0.4))
        XCTAssertEqual(track.began, tap, "the clock restarted at the file instead of the tap")
        track.opened()
        XCTAssertEqual(track.stage, .starting)
    }

    func testEveryStreamAskedForIsATryAndStartsItsStepsAgain() {
        var track = LoadTrack(began: tap)
        track.asked(at: at(0))
        track.gotAddress()
        track.opened()
        track.asked(at: at(15))
        XCTAssertEqual(track.tries, 2)
        XCTAssertEqual(track.stage, .asking)
        XCTAssertFalse(track.addressed, "the next copy's address was taken as known")
        XCTAssertEqual(track.began, tap, "a retry restarted the clock")
    }

    func testAStreamAskedForAfterThePictureIsADrop() {
        var track = LoadTrack(began: tap)
        track.asked(at: at(0))
        track.pictured(at: tap)
        XCTAssertFalse(track.dropped)
        track.asked(at: at(60))
        XCTAssertTrue(track.dropped)
        XCTAssertEqual(track.began, at(60), "a drop counted from the tap")
        XCTAssertEqual(track.tries, 1)
        track.asked(at: at(62))
        XCTAssertEqual(track.began, at(60))
        XCTAssertEqual(track.tries, 2)
        track.pictured(at: tap)
        XCTAssertFalse(track.dropped, "back with a picture and still called a drop")
    }

    func testThePictureLostWithNoStreamAskedForCountsFromThen() {
        var track = LoadTrack(began: tap)
        track.asked(at: at(0))
        track.lost(at: at(5))
        XCTAssertFalse(track.dropped, "a start that never had a picture called a drop")
        XCTAssertEqual(track.began, tap)
        track.pictured(at: tap)
        track.lost(at: at(60))
        XCTAssertTrue(track.dropped)
        XCTAssertEqual(track.began, at(60), "offline during play counted from the tap")
        track.asked(at: at(65))
        XCTAssertEqual(track.began, at(60), "the stream asked for once back online restarted the clock")
        XCTAssertEqual(track.tries, 1)
    }

    func testAReconnectAfterAFrozenPictureSaysSoAtOnceAndCountsItsOwnWait() {
        var track = LoadTrack(began: tap)
        track.asked(at: at(0))
        track.pictured(at: at(1))
        track.stalled(at: at(50))
        track.asked(at: at(63))
        XCTAssertTrue(track.dropped)
        XCTAssertEqual(track.began, at(63), "slow and Try again count from the request")
        XCTAssertEqual(track.pictureLost, at(50))
        let reconnecting = LoadProgress(subject: .channel("PPV 1"), wait: .reconnect, stage: track.stage, cause: .channel,
                                        began: track.began, pictureLost: track.pictureLost)
        let shown = reconnecting.shown(at: at(63))
        XCTAssertEqual(shown?.line, "Reconnecting to PPV 1…", "3 s without a picture and the notice not shown")
        XCTAssertEqual(shown?.tryAgain, false, "Try again offered before the reopen had a chance")
        XCTAssertEqual(reconnecting.shown(at: at(71))?.tryAgain, true)
    }

    func testALossWithNoFreezeCountsTheNoticeFromTheRequest() {
        var track = LoadTrack(began: tap)
        track.asked(at: at(0))
        track.pictured(at: at(1))
        track.asked(at: at(60))
        XCTAssertEqual(track.pictureLost, at(60))
        let reconnecting = LoadProgress(subject: .channel("PPV 1"), wait: .reconnect, stage: track.stage, cause: .channel,
                                        began: track.began, pictureLost: track.pictureLost)
        XCTAssertNil(reconnecting.shown(at: at(61)))
    }

    func testAFailureCountsItsTriesAndSeconds() {
        var track = LoadTrack(began: tap)
        for second in [0.0, 15, 16, 22] { track.asked(at: at(second)) }
        track.failed(at: at(30.2))
        track.failed(at: at(40))
        let failure = track.failure(.noPicture, otherChannels: true)
        XCTAssertEqual(failure.tries, 4)
        XCTAssertEqual(failure.seconds, 30.2, accuracy: 0.001, "a later failure moved its time")
        XCTAssertTrue(failure.otherChannels)
    }

    func testAFailureBeforeAnyStreamWasAskedForIsOneTry() {
        var track = LoadTrack(began: tap)
        track.failed(at: at(2))
        XCTAssertEqual(track.failure(.refused("No such channel.")).tries, 1)
    }

    func testEachStreamAskedForHasItsOwnAttempt() {
        var track = LoadTrack(began: tap, stage: .fetching)
        let first = track.asked(.fetching, at: at(0))
        let fallback = track.asked(.fetching, at: at(15))
        XCTAssertNotEqual(first, fallback)
        XCTAssertFalse(track.isCurrent(first), "the replaced load's events still count")
        XCTAssertTrue(track.isCurrent(fallback))
    }

    func testTryAgainStartsTheWaitOverAndKeepsCountingAttempts() {
        var track = LoadTrack(began: tap, stage: .fetching)
        let failed = track.asked(.fetching, at: at(0))
        track.failed(at: at(30))
        track.restart(at: at(31))
        XCTAssertEqual(track.began, at(31))
        XCTAssertEqual(track.stage, .fetching)
        let again = track.asked(.fetching, at: at(31))
        XCTAssertNotEqual(again, failed, "Try again reused the failed load's attempt")
        XCTAssertFalse(track.isCurrent(failed), "the failed load's late events count after Try again")
        XCTAssertEqual(track.failure(.noPicture).tries, 1)
        XCTAssertEqual(track.failure(.noPicture).seconds, 0, "the earlier failure's time carried over")
    }

    func testAPlayerTakenOverKeepsItsAttempt() {
        XCTAssertTrue(LoadTrack(began: tap, stage: .fetching, attempt: 4).isCurrent(4), "a warm or Picture in Picture player's events were dropped")
    }

    func testAQualitySwitchDuringPlayIsANewAttemptButNotATry() {
        var track = LoadTrack(began: tap, stage: .fetching)
        let first = track.asked(.fetching, at: at(0))
        track.pictured(at: tap)
        let switched = track.nextAttempt()
        XCTAssertFalse(track.isCurrent(first))
        XCTAssertTrue(track.isCurrent(switched))
        XCTAssertEqual(track.tries, 1)
        XCTAssertFalse(track.dropped)
    }

    func testAFailuresExplanationOnlyCountsForThatFailure() {
        var track = LoadTrack(began: tap, stage: .fetching)
        let failed = track.asked(.fetching, at: at(0))
        XCTAssertFalse(track.stillFailed(failed), "an explanation for a load still opening")
        track.failed(at: at(3))
        XCTAssertTrue(track.stillFailed(failed))
        track.restart(at: at(5))
        let again = track.asked(.fetching, at: at(5))
        XCTAssertFalse(track.stillFailed(failed), "the first failure's explanation landed on Try again")
        XCTAssertFalse(track.stillFailed(again), "an explanation for a load that hasn't failed")
    }

    func testAStallThatBecomesAReopenCountsFromTheStall() {
        var track = LoadTrack(began: tap)
        track.asked(at: at(0))
        track.pictured(at: tap)
        track.stalled(at: at(50))
        track.asked(at: at(58))
        XCTAssertEqual(track.pictureLost, at(50), "the reconnect counted from the reopen, not from when the picture went")
        XCTAssertTrue(track.dropped)
    }

    func testALiveFreezeSaysReconnectingFromWhenThePictureWent() {
        var track = LoadTrack(began: tap)
        track.asked(at: at(0))
        track.pictured(at: tap)
        track.stalled(at: at(50))
        let frozen = LoadProgress.channel("PPV 1", track: track, loading: false, hasPicture: true, cause: .channel)
        XCTAssertEqual(frozen?.wait, .reconnect, "a frozen live picture shows a ring with no words")
        XCTAssertEqual(frozen?.began, at(50))
        XCTAssertNil(frozen?.shown(at: at(52.9)))
        XCTAssertEqual(frozen?.shown(at: at(53))?.line, "Reconnecting to PPV 1…")
        track.asked(at: at(58))
        let reopening = LoadProgress.channel("PPV 1", track: track, loading: true, hasPicture: true, cause: .channel)
        XCTAssertEqual(reopening?.wait, .reconnect)
        XCTAssertEqual(reopening?.pictureLost, at(50), "the reopen restarted the drop's clock")
        XCTAssertEqual(reopening?.deadline, at(80), "the drop's deadline counted from the reopen")
    }

    func testALiveStartAndAFailureAreWhatTheyWere() {
        var track = LoadTrack(began: tap)
        track.asked(at: at(0))
        XCTAssertEqual(LoadProgress.channel("PPV 1", track: track, loading: true, hasPicture: false, cause: .server)?.wait, .start)
        XCTAssertNil(LoadProgress.channel("PPV 1", track: track, loading: false, hasPicture: false, cause: .channel))
        track.pictured(at: at(4))
        XCTAssertNil(LoadProgress.channel("PPV 1", track: track, loading: false, hasPicture: true, cause: .channel)?.shown(at: at(4.1)),
                     "a progress over a moving picture")
        let failed = LoadProgress.channel("PPV 1", track: track, loading: false, hasPicture: false, cause: .channel,
                                          failure: .init(kind: .noPicture, tries: 2, seconds: 30))
        XCTAssertEqual(failed?.shown(at: at(31))?.line, "PPV 1 isn’t sending a picture")
    }

    func testThePictureEndsAStartButNotADrop() {
        var track = LoadTrack(began: tap)
        track.asked(at: at(0))
        track.pictured(at: at(1.2))
        XCTAssertEqual(track.startEndedAt, at(1.2))
        let held = LoadProgress.channel("PPV 1", track: track, loading: false, hasPicture: true, cause: .channel)
        XCTAssertNotNil(held?.shown(at: at(1.3))?.ring, "a quick live start flashed the ring off")
        XCTAssertNil(held?.shown(at: at(1.6)))
        track.lost(at: at(60))
        XCTAssertNil(track.startEndedAt)
        track.asked(at: at(61))
        track.pictured(at: at(62))
        XCTAssertNil(track.startEndedAt, "a reconnect's end held the ring")
    }

    func testAJumpThatHasntLandedIsAWaitFromTheJump() {
        var track = LoadTrack(began: tap, stage: .fetching)
        track.asked(.fetching, at: at(0))
        track.pictured(at: at(1))
        track.jumping(at: at(50))
        XCTAssertEqual(track.stalledSince, at(50), "a jump into a server that stopped answering showed nothing")
        let wait = LoadProgress(subject: .film("Heat"), wait: .stall, stage: track.stage, cause: .server, began: at(50))
        XCTAssertNil(wait.shown(at: at(52)), "a quick jump showed the ring")
        XCTAssertNotNil(wait.shown(at: at(53))?.ring)
        XCTAssertEqual(wait.shown(at: at(58))?.tryAgain, true)
        XCTAssertTrue(wait.overdue(at: at(80)), "a jump that never lands spins past 30 s")
        track.landed(at: at(60))
        XCTAssertNil(track.stalledSince, "a jump that landed still waits")
    }

    func testAStallAndAJumpWaitUntilBothEnd() {
        var track = LoadTrack(began: tap, stage: .fetching)
        track.asked(.fetching, at: at(0))
        track.pictured(at: at(1))
        track.stalled(at: at(40))
        track.jumping(at: at(45))
        XCTAssertEqual(track.stalledSince, at(40))
        track.flowing()
        XCTAssertEqual(track.stalledSince, at(45), "data coming again ended the wait for a jump still on its way")
        track.landed(at: at(46))
        XCTAssertNil(track.stalledSince)
        track.jumping(at: at(60))
        track.pictured(at: at(61))
        XCTAssertNil(track.stalledSince, "the picture back still waits")
    }

    func testAJumpBegunWhileChoosingAndNotLandedWhenChoosingEndsIsAWait() {
        var track = LoadTrack(began: tap, stage: .fetching)
        track.asked(.fetching, at: at(0))
        track.pictured(at: at(1))
        track.seeking(true, choosing: true, at: at(50))
        XCTAssertNil(track.stalledSince, "choosing where to jump showed a wait")
        track.choosingEnded(at: at(53))
        XCTAssertEqual(track.stalledSince, at(53), "a jump begun while choosing (Apple TV's held press, iPhone's drag) never waited once let go")
        track.seeking(false, choosing: false, at: at(60))
        XCTAssertEqual(track.stalledSince, at(53), "the player done seeking with no picture back ended the wait")
        track.landed(at: at(60))
        XCTAssertNil(track.stalledSince)
        track.seeking(true, choosing: true, at: at(70))
        track.seeking(false, choosing: true, at: at(71))
        track.landed(at: at(71))
        track.choosingEnded(at: at(72))
        XCTAssertNil(track.stalledSince, "a jump that landed while choosing waited after")
        track.seeking(true, choosing: false, at: at(80))
        XCTAssertEqual(track.stalledSince, at(80), "a jump outside choosing didn't wait")
    }

    func testAReadThatEndsAfterAJumpIsAFailureThatKeepsThePlace() {
        var track = LoadTrack(began: tap, stage: .fetching)
        track.asked(.fetching, at: at(0))
        track.pictured(at: at(1))
        track.seeking(true, choosing: false, at: at(10))
        track.seeking(false, choosing: false, at: at(37))
        track.landed(at: at(37))
        XCTAssertEqual(track.end(at: 186, of: 600), FilmEnd(cutOff: true, place: 186),
                       "a jump's read the server never answered closed the film and saved its place as the end")
        track.cutOff(at: at(37.2))
        XCTAssertEqual(track.failure(.cutOff).seconds, 27.2, accuracy: 0.01,
                       "the player calls a jump landed just before its read's end: counted from the jump")
    }

    func testAJumpThatLandedLongBeforeAnEndIsntItsWait() {
        var track = LoadTrack(began: tap, stage: .fetching)
        track.asked(.fetching, at: at(0))
        track.pictured(at: at(1))
        track.seeking(true, choosing: false, at: at(10))
        track.landed(at: at(11))
        track.cutOff(at: at(100))
        XCTAssertEqual(track.failure(.cutOff).seconds, 0, "an end long after a jump counted from the jump")
    }

    func testAReadThatEndsMidPlayIsAFailureThatKeepsThePlace() {
        var track = LoadTrack(began: tap, stage: .fetching)
        track.asked(.fetching, at: at(0))
        track.pictured(at: at(1))
        XCTAssertEqual(track.end(at: 186, of: 7200), FilmEnd(cutOff: true, place: 186), "an end two hours early closed the film")
        track.stalled(at: at(50))
        XCTAssertEqual(track.end(at: 7195, of: 7200), FilmEnd(cutOff: true, place: 7195), "an end during a stall closed the film")
    }

    func testARealEndStillGoesToUpNext() {
        var track = LoadTrack(began: tap, stage: .fetching)
        track.asked(.fetching, at: at(0))
        track.pictured(at: at(1))
        XCTAssertEqual(track.end(at: 7199, of: 7200), FilmEnd(cutOff: false, place: 7200), "the film's own end taken for a failure")
        XCTAssertFalse(track.end(at: 186, of: 0).cutOff, "a film of unknown length can't end early")
    }

    func testAStallCountsFromItsStart() {
        var track = LoadTrack(began: tap)
        track.asked(at: at(0))
        track.pictured(at: tap)
        track.stalled(at: at(50))
        track.stalled(at: at(51))
        XCTAssertEqual(track.stalledSince, at(50))
        track.flowing()
        XCTAssertNil(track.stalledSince)
    }
}

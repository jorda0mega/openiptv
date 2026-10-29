import XCTest
@testable import OpenIPTV

final class FilmLoadingTests: XCTestCase {
    private typealias Event = FilmLoading.Event
    private typealias Look = FilmLoading.Look

    private let tap = Date(timeIntervalSinceReferenceDate: 1000)

    private func at(_ seconds: Double) -> Date { tap.addingTimeInterval(seconds) }

    private struct Started {
        var loading: FilmLoading
        let ask: Int
        let attempt: Int
    }

    private func started(_ held: FirstPicture = .backdrop, patience: FilmLoading.Patience = .current) -> Started {
        var loading = FilmLoading(tappedAt: tap, held: held, patience: patience)
        let ask = loading.nextAsk()
        let attempt = loading.nextAttempt()
        return Started(loading: loading, ask: ask, attempt: attempt)
    }

    private func look(_ loading: FilmLoading, at seconds: Double) -> Look {
        var loading = loading
        loading.send(.clock, at: at(seconds))
        return loading.look
    }

    private func held(_ over: Look.Over, _ picture: FirstPicture = .backdrop) -> Look {
        Look(under: .held(picture), over: over)
    }

    private func film(_ over: Look.Over = .nothing) -> Look {
        Look(under: .film, over: over)
    }

    private func playing(movedAt seconds: Double = 0.5) -> Started {
        var start = started()
        start.loading.send(.player(.moving, attempt: start.attempt), at: at(seconds))
        return start
    }

    private func failedAtTheLimit() -> Started {
        var start = started()
        start.loading.send(.planAnswered(ask: start.ask), at: at(0.4))
        start.loading.send(.player(.opened, attempt: start.attempt), at: at(0.6))
        start.loading.send(.clock, at: at(30))
        return start
    }

    func testATapShowsTheHeldPictureAndCloseOnly() {
        let look = started().loading.look
        XCTAssertEqual(look, held(.nothing))
        XCTAssertTrue(look.closes, "no Close at the tap")
        XCTAssertFalse(look.controls, "the player's controls at the tap")
    }

    func testAStartDoneBeforeOneSecondNeverShowsTheRing() {
        var start = started()
        start.loading.send(.planAnswered(ask: start.ask), at: at(0.3))
        start.loading.send(.player(.opened, attempt: start.attempt), at: at(0.5))
        XCTAssertEqual(look(start.loading, at: 0.99), held(.nothing))
        start.loading.send(.player(.moving, attempt: start.attempt), at: at(0.99))
        XCTAssertEqual(start.loading.look, film())
        XCTAssertEqual(look(start.loading, at: 20), film(), "a ring after the film moved")
        XCTAssertNil(start.loading.nextChange)
    }

    func testFromOneSecondTheRingShowsLitOverTheSamePicture() {
        let start = started()
        XCTAssertEqual(start.loading.nextChange, at(1))
        XCTAssertEqual(look(start.loading, at: 0.999), held(.nothing))
        XCTAssertEqual(look(start.loading, at: 1), held(.ring(steps: 0, lit: true)))
    }

    func testTheRingTurnsOneStepForEachReadWithNewBytes() {
        var start = started()
        start.loading.send(.bytes(100), at: at(1))
        start.loading.send(.bytes(100), at: at(1.25))
        XCTAssertEqual(start.loading.look, held(.ring(steps: 0, lit: true)), "a read with no new bytes turned it")
        start.loading.send(.bytes(160), at: at(1.5))
        start.loading.send(.bytes(900), at: at(1.75))
        XCTAssertEqual(start.loading.look, held(.ring(steps: 2, lit: true)))
    }

    func testThePlanAnsweringAndTheFileOpeningEachTurnTheRingOnce() {
        var start = started()
        start.loading.send(.planAnswered(ask: start.ask), at: at(1.2))
        XCTAssertEqual(start.loading.look, held(.ring(steps: 1, lit: true)))
        start.loading.send(.player(.opened, attempt: start.attempt), at: at(1.4))
        XCTAssertEqual(start.loading.look, held(.ring(steps: 2, lit: true)))
    }

    func testTheRingStandsStillAndDimsAfterThreeSecondsWithNothingArriving() {
        var start = started()
        start.loading.send(.bytes(100), at: at(0.5))
        XCTAssertEqual(look(start.loading, at: 2.99), held(.ring(steps: 0, lit: true)))
        XCTAssertEqual(look(start.loading, at: 3), held(.ring(steps: 0, lit: false)))
        start.loading.send(.bytes(100), at: at(4))
        XCTAssertEqual(start.loading.look, held(.ring(steps: 0, lit: false)), "a read with nothing new lit it")
        XCTAssertEqual(look(start.loading, at: 12), held(.ring(steps: 0, lit: false)))
    }

    func testTheRingLightsAgainOnDataButNotBeforeItWasDimHalfASecond() {
        var start = started()
        start.loading.send(.bytes(100), at: at(0.5))
        start.loading.send(.bytes(200), at: at(3.2))
        XCTAssertEqual(start.loading.look, held(.ring(steps: 0, lit: false)), "dim for only 0.2 s, then lit")
        XCTAssertEqual(look(start.loading, at: 3.49), held(.ring(steps: 0, lit: false)))
        XCTAssertEqual(look(start.loading, at: 3.5), held(.ring(steps: 1, lit: true)))
        start.loading.send(.clock, at: at(6.5))
        XCTAssertEqual(start.loading.look, held(.ring(steps: 1, lit: false)), "dim again 3 s after the last bytes")
        start.loading.send(.bytes(300), at: at(7.1))
        XCTAssertEqual(start.loading.look, held(.ring(steps: 2, lit: true)), "dim 0.6 s: new bytes light it at once")
    }

    func testTheFirstFrameEndsTheStartAtOnceEvenJustAfterTheRingCame() {
        var start = started()
        start.loading.send(.clock, at: at(1))
        start.loading.send(.player(.moving, attempt: start.attempt), at: at(1.05))
        XCTAssertEqual(start.loading.look, film())
        XCTAssertTrue(start.loading.filmShown)
    }

    func testTheHeldPictureIsTheSameFromTheTapToTheFirstFrame() {
        for seed in 1...200 {
            let picture: FirstPicture = seed.isMultiple(of: 2) ? .backdrop : .still(at: 754.2)
            var random = Seeded(seed)
            var start = started(picture)
            for (_, look, _) in Self.walk(&start, &random, viewer: true) where look.under != .film {
                XCTAssertEqual(look.under, .held(picture), "seed \(seed): the picture changed before the film")
            }
        }
    }

    func testNoEventWithoutTheViewerMakesTheLookGoBack() {
        func rank(_ over: Look.Over) -> Int {
            switch over {
            case .nothing: 0
            case .ring: 1
            case .failure: 2
            }
        }
        for seed in 1...200 {
            var random = Seeded(seed)
            var start = started()
            var last = start.loading.look
            for (_, look, _) in Self.walk(&start, &random, viewer: false) {
                defer { last = look }
                XCTAssertFalse(last.under == .film && look.under != .film, "seed \(seed): back to the held picture")
                if last.failure != nil { XCTAssertEqual(look, last, "seed \(seed): a failure changed without the viewer") }
                if case .held = look.under, case .held = last.under {
                    XCTAssertGreaterThanOrEqual(rank(look.over), rank(last.over), "seed \(seed): the start went back")
                }
            }
        }
    }

    func testNoLookChangesSoonerThanHalfASecondUnlessTheFilmMoves() {
        for seed in 1...200 {
            var random = Seeded(seed)
            var start = started()
            var shown = (kind: start.loading.look.kind, since: 0.0)
            for (seconds, look, byViewer) in Self.walk(&start, &random, viewer: true) where look.kind != shown.kind {
                defer { shown = (look.kind, seconds) }
                guard !byViewer, look.kind != .film, shown.kind != .film else { continue }
                XCTAssertGreaterThanOrEqual(seconds - shown.since, 0.5 - 1e-9,
                                            "seed \(seed): \(shown.kind) for \(seconds - shown.since) s, then \(look.kind)")
            }
        }
    }

    func testAResumeFrameStartIsHeldLikeABackdropStart() {
        let frame = FirstPicture.still(at: 1834.5)
        var start = started(frame)
        XCTAssertEqual(start.loading.look, held(.nothing, frame))
        XCTAssertEqual(look(start.loading, at: 1), held(.ring(steps: 0, lit: true), frame))
        start.loading.send(.player(.moving, attempt: start.attempt), at: at(1.3))
        XCTAssertEqual(start.loading.look, film())
    }

    func testAFilmTakenBackFromPictureInPictureShowsNoStart() {
        let loading = FilmLoading.moving(at: tap)
        XCTAssertEqual(loading.look, film())
        XCTAssertFalse(loading.look.closes)
        XCTAssertTrue(loading.look.controls)
        XCTAssertTrue(loading.filmShown)
        XCTAssertFalse(loading.waiting)
        XCTAssertNil(loading.nextChange)
    }

    func testTheStartFailsThirtySecondsAfterTheTap() {
        var start = started()
        start.loading.send(.planAnswered(ask: start.ask), at: at(0.5))
        for read in 1...116 { start.loading.send(.bytes(Int64(read * 1000)), at: at(Double(read) * 0.25)) }
        XCTAssertEqual(look(start.loading, at: 29.99).kind, .ring)
        XCTAssertEqual(look(start.loading, at: 30), held(.failure(.tooSlow)))
    }

    func testUnderStillOnlyAStartThatKeepsArrivingGoesOnPastThirtySeconds() {
        var start = started(patience: FilmLoading.Patience(stillFor: 30, atMost: 120))
        start.loading.send(.planAnswered(ask: start.ask), at: at(0.5))
        for read in 1...12 { start.loading.send(.bytes(Int64(read)), at: at(Double(read) * 5)) }
        XCTAssertEqual(look(start.loading, at: 60).kind, .ring, "a start with bytes arriving stopped")
        for read in 13...23 { start.loading.send(.bytes(Int64(read)), at: at(Double(read) * 5)) }
        XCTAssertEqual(look(start.loading, at: 119.99).kind, .ringDim)
        XCTAssertEqual(look(start.loading, at: 120), held(.failure(.tooSlow)))
    }

    func testUnderStillOnlyThirtySecondsWithNothingArrivingFails() {
        var start = started(patience: FilmLoading.Patience(stillFor: 30, atMost: 120))
        start.loading.send(.planAnswered(ask: start.ask), at: at(5))
        XCTAssertEqual(look(start.loading, at: 34.99).kind, .ringDim)
        XCTAssertEqual(look(start.loading, at: 35), held(.failure(.tooSlow)))
    }

    func testARefusedPlanShowsTheFailureOnceThePictureWasUpHalfASecond() {
        var early = started()
        early.loading.send(.planRefused("Your server answered with an error.", ask: early.ask), at: at(0.2))
        XCTAssertEqual(early.loading.look, held(.nothing))
        XCTAssertEqual(early.loading.nextChange, at(0.5))
        XCTAssertEqual(look(early.loading, at: 0.49), held(.nothing))
        XCTAssertEqual(look(early.loading, at: 0.5), held(.failure(.refused("Your server answered with an error."))))
        var later = started()
        later.loading.send(.planRefused("No", ask: later.ask), at: at(0.8))
        XCTAssertEqual(later.loading.look, held(.failure(.refused("No"))), "the picture was up 0.8 s: at once")
    }

    func testAFailureDuringTheRingsFirstHalfSecondWaitsForIt() {
        var start = started()
        start.loading.send(.player(.refused("The file didn’t open."), attempt: start.attempt), at: at(1.2))
        XCTAssertEqual(start.loading.look, held(.ring(steps: 0, lit: true)))
        XCTAssertEqual(look(start.loading, at: 1.49).kind, .ring)
        XCTAssertEqual(look(start.loading, at: 1.5), held(.failure(.refused("The file didn’t open."))))
    }

    func testTheFailureSaysNoAnswerTooSlowOrOfflineFromWhatArrived() {
        XCTAssertEqual(look(started().loading, at: 30), held(.failure(.noAnswer)))
        XCTAssertEqual(failedAtTheLimit().loading.look, held(.failure(.tooSlow)))
        var offline = started()
        offline.loading.send(.online(false), at: at(4))
        XCTAssertEqual(look(offline.loading, at: 30), held(.failure(.offline)))
        var refusedOffline = started()
        refusedOffline.loading.send(.online(false), at: at(0.1))
        refusedOffline.loading.send(.planRefused("The request timed out.", ask: refusedOffline.ask), at: at(2))
        XCTAssertEqual(refusedOffline.loading.look, held(.failure(.offline)))
        XCTAssertEqual(Look.Over.failure(.noAnswer), .failure(.noAnswer))
        XCTAssertEqual(FilmLoading.Failure.noAnswer.cause, "Your server didn’t answer.")
        XCTAssertEqual(FilmLoading.Failure.tooSlow.cause, "Your server is too slow to send it.")
        XCTAssertEqual(FilmLoading.Failure.offline.cause, "No internet connection.")
        XCTAssertEqual(held(.failure(.tooSlow)).headline("Heat"), "Heat didn’t start")
        XCTAssertEqual(film(.failure(.cutOff)).headline("Heat"), "Heat stopped")
        XCTAssertNil(held(.ring(steps: 0, lit: true)).headline("Heat"))
    }

    func testTryAgainShowsTheRingAtOnceLitAtTheSameAngle() {
        var start = started()
        start.loading.send(.planAnswered(ask: start.ask), at: at(1.2))
        start.loading.send(.player(.opened, attempt: start.attempt), at: at(1.4))
        start.loading.send(.bytes(1), at: at(1.5))
        start.loading.send(.bytes(2), at: at(1.75))
        start.loading.send(.clock, at: at(30))
        XCTAssertEqual(start.loading.look, held(.failure(.tooSlow)))
        start.loading.send(.tryAgain, at: at(40))
        XCTAssertEqual(start.loading.look, held(.ring(steps: 3, lit: true)))
    }

    func testTryAgainStartsTheLimitAgain() {
        var start = failedAtTheLimit()
        start.loading.send(.tryAgain, at: at(35))
        _ = start.loading.nextAttempt()
        XCTAssertEqual(look(start.loading, at: 64.99).kind, .ringDim)
        XCTAssertEqual(look(start.loading, at: 65), held(.failure(.tooSlow)))
    }

    func testAFrameOrAPlanAfterTheFailureChangesNothing() {
        var start = failedAtTheLimit()
        let failed = start.loading.look
        start.loading.send(.player(.moving, attempt: start.attempt), at: at(31))
        start.loading.send(.planAnswered(ask: start.ask), at: at(31.5))
        start.loading.send(.bytes(99), at: at(32))
        start.loading.send(.bytes(999), at: at(32.25))
        XCTAssertEqual(start.loading.look, failed)
        XCTAssertNil(start.loading.nextChange)
        XCTAssertFalse(start.loading.waiting)
    }

    func testEventsOfAReplacedLoadOrAnOlderAskChangeNothing() {
        var start = started()
        let second = start.loading.nextAttempt()
        start.loading.send(.player(.moving, attempt: start.attempt), at: at(0.6))
        start.loading.send(.player(.refused("Old"), attempt: start.attempt), at: at(0.7))
        XCTAssertEqual(start.loading.look, held(.nothing), "an event of the replaced load counted")
        let newer = start.loading.nextAsk()
        start.loading.send(.planRefused("Old", ask: start.ask), at: at(0.8))
        start.loading.send(.planAnswered(ask: start.ask), at: at(1.1))
        XCTAssertEqual(start.loading.look, held(.ring(steps: 0, lit: true)), "an answer to the older ask counted")
        start.loading.send(.planAnswered(ask: newer), at: at(1.2))
        start.loading.send(.player(.moving, attempt: second), at: at(1.3))
        XCTAssertEqual(start.loading.look, film())
    }

    func testADiagnosisThatEndsAfterTryAgainDoesNotFailTheNewWait() {
        var start = failedAtTheLimit()
        start.loading.send(.tryAgain, at: at(31))
        _ = start.loading.nextAttempt()
        start.loading.send(.player(.refused("The server answered 404."), attempt: start.attempt), at: at(32))
        XCTAssertEqual(start.loading.look, held(.ring(steps: 2, lit: true)))
    }

    func testAParkedPlayersMadeUpStartIsNotTheFilmMoving() {
        let still = FirstPicture.still(at: 754.2)
        XCTAssertFalse(still.goesOn(at: 754.2), "the still itself counted as the film moving")
        XCTAssertFalse(still.goesOn(at: 0), "the made-up start at 0 counted as the film moving")
        XCTAssertTrue(still.goesOn(at: 754.25))
        XCTAssertTrue(FirstPicture.backdrop.goesOn(at: 0))
    }

    func testAnEndBeforeTheFirstPictureIsStoppedBeforeItBegan() {
        var start = started()
        start.loading.send(.player(.ended(position: 0, total: 0), attempt: start.attempt), at: at(0.7))
        XCTAssertEqual(start.loading.look, held(.failure(.endedEarly)))
        XCTAssertEqual(FilmLoading.Failure.endedEarly.cause, "It stopped before it began.")
    }

    func testCloseKeepsTheLookItHadAndEndsEveryWait() {
        var start = started()
        start.loading.send(.clock, at: at(2))
        let ring = start.loading.look
        start.loading.send(.close, at: at(2.1))
        XCTAssertEqual(start.loading.look, ring)
        XCTAssertNil(start.loading.nextChange)
        XCTAssertFalse(start.loading.waiting)
        start.loading.send(.player(.moving, attempt: start.attempt), at: at(2.2))
        XCTAssertEqual(look(start.loading, at: 60), ring)
    }

    func testAStallShowsNothingForThreeSecondsThenTheRing() {
        var quiet = playing()
        quiet.loading.send(.player(.dataStopped, attempt: quiet.attempt), at: at(10))
        XCTAssertEqual(quiet.loading.look, film())
        XCTAssertEqual(quiet.loading.nextChange, at(13))
        XCTAssertEqual(look(quiet.loading, at: 12.99), film())
        XCTAssertEqual(look(quiet.loading, at: 13), film(.ring(steps: 0, lit: false)), "nothing came for 3 s: lit")
        var trickle = playing()
        trickle.loading.send(.player(.dataStopped, attempt: trickle.attempt), at: at(10))
        trickle.loading.send(.bytes(5), at: at(10.25))
        trickle.loading.send(.bytes(6), at: at(12))
        XCTAssertEqual(look(trickle.loading, at: 13), film(.ring(steps: 1, lit: true)))
        trickle.loading.send(.player(.dataFlowing, attempt: trickle.attempt), at: at(14))
        XCTAssertEqual(trickle.loading.look, film())
    }

    func testTheFirstReadOfAWaitIsWhereItCountsFrom() {
        var start = started()
        start.loading.send(.bytes(100), at: at(0.3))
        start.loading.send(.player(.moving, attempt: start.attempt), at: at(0.5))
        start.loading.send(.player(.dataStopped, attempt: start.attempt), at: at(10))
        start.loading.send(.bytes(80_000_000), at: at(10.25))
        XCTAssertEqual(look(start.loading, at: 13), film(.ring(steps: 0, lit: false)), "the bytes of the film so far counted for the stall")
    }

    func testAJumpThatHasNotLandedWaitsLikeAStall() {
        var start = playing()
        start.loading.send(.seeking(true, choosing: false), at: at(10))
        XCTAssertEqual(look(start.loading, at: 12.9), film())
        XCTAssertTrue(look(start.loading, at: 13).ringShown)
        start.loading.send(.player(.landed, attempt: start.attempt), at: at(14))
        XCTAssertEqual(start.loading.look, film())
    }

    func testAStallAndAJumpWaitUntilBothEnd() {
        var start = playing()
        start.loading.send(.player(.dataStopped, attempt: start.attempt), at: at(10))
        start.loading.send(.seeking(true, choosing: false), at: at(11))
        start.loading.send(.player(.landed, attempt: start.attempt), at: at(12))
        XCTAssertTrue(look(start.loading, at: 13).ringShown, "the stall ended with the jump")
        start.loading.send(.player(.dataFlowing, attempt: start.attempt), at: at(14))
        XCTAssertEqual(start.loading.look, film())
    }

    func testChoosingWhereToJumpDoesNotWait() {
        var start = playing()
        start.loading.send(.seeking(true, choosing: true), at: at(10))
        XCTAssertEqual(look(start.loading, at: 20), film())
        XCTAssertNil(start.loading.nextChange)
    }

    func testAJumpStillOnItsWayWhenTheFingerLetsGoWaitsFromThen() {
        var start = playing()
        start.loading.send(.seeking(true, choosing: true), at: at(10))
        start.loading.send(.choosingEnded, at: at(12))
        XCTAssertEqual(look(start.loading, at: 14.99), film())
        XCTAssertTrue(look(start.loading, at: 15).ringShown)
        var landed = playing()
        landed.loading.send(.seeking(true, choosing: true), at: at(10))
        landed.loading.send(.seeking(false, choosing: true), at: at(11))
        landed.loading.send(.choosingEnded, at: at(12))
        XCTAssertEqual(look(landed.loading, at: 30), film(), "a jump done before the finger let go waited")
    }

    func testAnEndFarFromTheFilmsEndOrWhileFrozenIsStopped() {
        var cut = playing()
        XCTAssertFalse(cut.loading.isRealEnd(at: 100, of: 6000))
        cut.loading.send(.player(.ended(position: 100, total: 6000), attempt: cut.attempt), at: at(20))
        XCTAssertEqual(cut.loading.look, film(.failure(.cutOff)))
        XCTAssertTrue(cut.loading.look.closes)
        var real = playing()
        XCTAssertTrue(real.loading.isRealEnd(at: 5995, of: 6000))
        real.loading.send(.player(.ended(position: 5995, total: 6000), attempt: real.attempt), at: at(20))
        XCTAssertEqual(real.loading.look, film())
        var frozen = playing()
        frozen.loading.send(.player(.dataStopped, attempt: frozen.attempt), at: at(20))
        XCTAssertFalse(frozen.loading.isRealEnd(at: 5999, of: 6000))
        frozen.loading.send(.player(.ended(position: 5999, total: 6000), attempt: frozen.attempt), at: at(21))
        XCTAssertEqual(frozen.loading.look, film(.failure(.cutOff)))
    }

    func testTryAgainAfterTheFilmStoppedWaitsForItToMoveAgain() {
        var start = playing()
        start.loading.send(.player(.ended(position: 100, total: 6000), attempt: start.attempt), at: at(20))
        start.loading.send(.tryAgain, at: at(22))
        let next = start.loading.nextAttempt()
        XCTAssertEqual(start.loading.look, film(.ring(steps: 0, lit: true)))
        start.loading.send(.player(.dataFlowing, attempt: next), at: at(23))
        XCTAssertTrue(start.loading.look.ringShown, "data before the picture ended the wait")
        start.loading.send(.player(.moving, attempt: next), at: at(24))
        XCTAssertEqual(start.loading.look, film())
    }

    func testStallEventsBeforeTheFilmMovesChangeNothing() {
        var start = started()
        start.loading.send(.player(.dataStopped, attempt: start.attempt), at: at(0.1))
        start.loading.send(.seeking(true, choosing: false), at: at(0.2))
        start.loading.send(.player(.landed, attempt: start.attempt), at: at(0.3))
        start.loading.send(.player(.dataFlowing, attempt: start.attempt), at: at(0.4))
        start.loading.send(.choosingEnded, at: at(0.5))
        XCTAssertEqual(start.loading.look, held(.nothing))
        XCTAssertEqual(start.loading.nextChange, at(1))
    }

    func testNextChangeIsTheEarliestTimedChangeAndALateClockGivesTheSameLooks() {
        var start = started()
        start.loading.send(.planAnswered(ask: start.ask), at: at(0.4))
        XCTAssertEqual(start.loading.nextChange, at(1), "the ring")
        start.loading.send(.clock, at: at(1))
        XCTAssertEqual(start.loading.nextChange, at(3.4), "the dim")
        start.loading.send(.clock, at: at(3.4))
        XCTAssertEqual(start.loading.nextChange, at(30.4 - 0.4), "the limit")
        for seed in 1...100 {
            var random = Seeded(seed)
            var onTime = started()
            let walked = Self.walk(&onTime, &random, viewer: true)
            var random2 = Seeded(seed)
            var late = started()
            for (step, event) in Self.events(late, &random2, viewer: true).enumerated() {
                Self.send(event, to: &late.loading, at: at(event.seconds))
                XCTAssertEqual(late.loading.look, walked.last { $0.seconds <= event.seconds + 1e-9 }?.look,
                               "seed \(seed) step \(step): a late clock gave another look")
            }
        }
    }

    func testTheControlsNeverShowBeforeTheFilmMovesOrOverAFailure() {
        var start = started()
        XCTAssertFalse(start.loading.look.controls)
        XCTAssertFalse(look(start.loading, at: 2).controls)
        XCTAssertFalse(failedAtTheLimit().loading.look.controls)
        start.loading.send(.player(.moving, attempt: start.attempt), at: at(2))
        XCTAssertTrue(start.loading.look.controls)
        start.loading.send(.player(.dataStopped, attempt: start.attempt), at: at(5))
        XCTAssertTrue(look(start.loading, at: 9).controls, "no controls over the frozen film's ring")
        XCTAssertFalse(look(start.loading, at: 40).controls, "controls over the failure")
        XCTAssertEqual(look(start.loading, at: 40), film(.failure(.cutOff)))
    }

    private struct Timed {
        let seconds: Double
        let event: Event
        let byViewer: Bool
    }

    private static func events(_ start: Started, _ random: inout Seeded, viewer: Bool) -> [Timed] {
        var out: [Timed] = []
        var seconds = 0.0
        var bytes: Int64 = 0
        var attempt = start.attempt
        var ask = start.ask
        for _ in 0..<60 {
            seconds += [0.05, 0.25, 0.4, 0.5, 1, 2.5, 4][Int.random(in: 0..<7, using: &random)]
            let roll = Int.random(in: 0..<100, using: &random)
            let event: Event
            switch roll {
            case 0..<25:
                bytes += Int64.random(in: 0...2, using: &random) * 1000
                event = .bytes(bytes)
            case 25..<32: event = .planAnswered(ask: ask)
            case 32..<35: event = .planRefused("No", ask: ask)
            case 35..<42: event = .player(.opened, attempt: attempt)
            case 42..<47: event = .player(.moving, attempt: attempt)
            case 47..<49: event = .player(.refused("Refused"), attempt: attempt)
            case 49..<51: event = .player(.ended(position: Double.random(in: 0...6000, using: &random), total: 6000), attempt: attempt)
            case 51..<57: event = .player(.dataStopped, attempt: attempt)
            case 57..<63: event = .player(.dataFlowing, attempt: attempt)
            case 63..<67: event = .player(.landed, attempt: attempt)
            case 67..<72: event = .seeking(Bool.random(using: &random), choosing: Bool.random(using: &random))
            case 72..<75: event = .choosingEnded
            case 75..<78: event = .online(Bool.random(using: &random))
            case 78..<81: event = .player(.moving, attempt: attempt - 1)
            case 81..<88 where viewer:
                event = .tryAgain
                attempt += 1
                ask += 1
            case 88..<89 where viewer: event = .close
            default: event = .clock
            }
            out.append(Timed(seconds: seconds, event: event, byViewer: event == .tryAgain || event == .close))
        }
        return out
    }

    private static func walk(_ start: inout Started, _ random: inout Seeded,
                             viewer: Bool) -> [(seconds: Double, look: Look, byViewer: Bool)] {
        let tap = Date(timeIntervalSinceReferenceDate: 1000)
        var looks: [(seconds: Double, look: Look, byViewer: Bool)] = [(0, start.loading.look, false)]
        for timed in events(start, &random, viewer: viewer) {
            while let next = start.loading.nextChange, next.timeIntervalSince(tap) < timed.seconds {
                start.loading.send(.clock, at: next)
                looks.append((next.timeIntervalSince(tap), start.loading.look, false))
            }
            send(timed, to: &start.loading, at: tap.addingTimeInterval(timed.seconds))
            looks.append((timed.seconds, start.loading.look, timed.byViewer))
        }
        return looks
    }

    private static func send(_ timed: Timed, to loading: inout FilmLoading, at now: Date) {
        loading.send(timed.event, at: now)
        guard timed.event == .tryAgain else { return }
        _ = loading.nextAttempt()
        _ = loading.nextAsk()
    }
}

private struct Seeded: RandomNumberGenerator {
    private var state: UInt64

    init(_ seed: Int) { state = UInt64(seed) &* 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

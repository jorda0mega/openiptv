import XCTest
@testable import OpenIPTV

final class LoadProgressTests: XCTestCase {
    private let tap = Date(timeIntervalSinceReferenceDate: 1000)

    private func at(_ seconds: Double) -> Date { tap.addingTimeInterval(seconds) }

    private func film(_ stage: LoadProgress.Stage, cause: LoadProgress.Cause = .server) -> LoadProgress {
        LoadProgress(subject: .film("Heat"), stage: stage, cause: cause, began: tap)
    }

    private func channel(_ stage: LoadProgress.Stage, received: Double? = nil, cause: LoadProgress.Cause = .channel,
                         wait: LoadProgress.Wait = .start) -> LoadProgress {
        LoadProgress(subject: .channel("PPV 1"), wait: wait, stage: stage, received: received, cause: cause, began: tap)
    }

    func testTheFirstSecondIsTheRingAlone() {
        let shown = film(.asking).shown(at: at(0.6))
        XCTAssertNotNil(shown?.ring, "no ring in the first second")
        XCTAssertNil(shown?.line, "words in the first second: a quick start flashes them")
        XCTAssertNil(shown?.dashes)
        XCTAssertEqual(shown?.details, [])
    }

    func testFromOneSecondTheLineNamesTheStepAndTheDashesCountIt() {
        let lines: [(LoadProgress, String, Int)] = [
            (film(.asking), "Asking your server", 1),
            (film(.fetching), "Opening the film", 2),
            (film(.starting), "Starting", 3),
            (channel(.asking), "Connecting to PPV 1", 1),
            (channel(.fetching, received: 0.6), "Getting the picture · 60%", 2),
            (channel(.starting), "Starting", 3),
        ]
        for (load, line, dashes) in lines {
            let shown = load.shown(at: at(2))
            XCTAssertEqual(shown?.line, line)
            XCTAssertEqual(shown?.dashes, dashes, line)
            XCTAssertEqual(shown?.details, [], "\(line): a second line before 8 s")
            XCTAssertEqual(shown?.tryAgain, false, "\(line): Try again before 8 s")
        }
    }

    func testThePercentageNeverRoundsUpToDone() {
        XCTAssertEqual(channel(.fetching, received: 0.996).shown(at: at(2))?.line, "Getting the picture · 99%")
        XCTAssertEqual(channel(.fetching, received: 1.7).shown(at: at(2))?.line, "Getting the picture · 100%")
        XCTAssertEqual(channel(.fetching, received: -0.2).shown(at: at(2))?.line, "Getting the picture · 0%")
        XCTAssertEqual(channel(.fetching).shown(at: at(2))?.line, "Getting the picture", "a percentage with nothing measured")
    }

    func testTheRingFillsByStepAndByTheDataReceived() {
        let fills = [film(.asking), film(.fetching), film(.starting)].compactMap { $0.shown(at: at(2))?.ring }
        XCTAssertEqual(fills, fills.sorted(), "the ring went back as the start went on")
        XCTAssertEqual(Set(fills).count, 3, "a step that doesn't move the ring")
        let receiving = [0, 0.3, 0.6, 1].compactMap { channel(.fetching, received: $0).shown(at: at(2))?.ring }
        XCTAssertEqual(receiving, receiving.sorted())
        XCTAssertLessThan(receiving[0], receiving[3], "data arriving doesn't move the ring")
        let asked = channel(.asking).shown(at: at(2))?.ring ?? 1, starting = channel(.starting).shown(at: at(2))?.ring ?? 0
        XCTAssertLessThan(asked, receiving[0])
        XCTAssertLessThan(receiving[3], starting)
        XCTAssertGreaterThan(asked, 0, "an empty ring while asking")
        XCTAssertLessThan(starting, 1, "a full ring before the picture")
    }

    func testFromEightSecondsASecondLineNamesWhatIsSlowAndCountsTheSeconds() {
        let slow: [(LoadProgress, String)] = [
            (film(.asking), "Your server is slow to answer · 12 s"),
            (film(.fetching), "Your server is slow to answer · 12 s"),
            (film(.starting), "Your server is slow to send the film · 12 s"),
            (channel(.asking, cause: .server), "Your TV provider is slow to answer · 12 s"),
            (channel(.fetching, received: 0.2), "The channel is slow to send · 12 s"),
            (film(.fetching, cause: .connection), "Your connection is slow · 12 s"),
            (channel(.asking, cause: .offline), "No internet connection · 12 s"),
        ]
        for (load, line) in slow {
            let shown = load.shown(at: at(12.4))
            XCTAssertEqual(shown?.details, [line])
            XCTAssertEqual(shown?.tryAgain, true, "\(line): no Try again")
            XCTAssertNotNil(shown?.line, "\(line): the step went")
            XCTAssertNotNil(shown?.ring, "\(line): the ring went")
        }
        XCTAssertEqual(film(.asking).shown(at: at(7.9))?.details, [], "slow before 8 s")
        XCTAssertEqual(film(.asking).shown(at: at(8))?.details, ["Your server is slow to answer · 8 s"])
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
        XCTAssertNil(shown?.dashes)
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
        XCTAssertNil(shown?.dashes)
        XCTAssertEqual(shown?.tryAgain, false)
        XCTAssertEqual(channel(.fetching, received: 0.5, wait: .reconnect).shown(at: at(4))?.line, "Reconnecting to PPV 1…")
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

    func testAFailureAfterADropShowsAtOnce() {
        var drop = channel(.asking, wait: .reconnect)
        drop.failure = .init(kind: .noPicture, tries: 3, seconds: 1)
        XCTAssertEqual(drop.shown(at: at(1))?.line, "PPV 1 isn’t sending a picture")
    }
}

final class LoadTrackTests: XCTestCase {
    private let tap = Date(timeIntervalSinceReferenceDate: 1000)

    private func at(_ seconds: Double) -> Date { tap.addingTimeInterval(seconds) }

    func testAChannelConnectsThenGetsThePictureThenStarts() {
        var track = LoadTrack(began: tap)
        track.asked(at: at(0))
        XCTAssertEqual(track.stage, .asking)
        XCTAssertFalse(track.addressed)
        track.gotAddress()
        XCTAssertTrue(track.addressed)
        track.opened()
        XCTAssertEqual(track.stage, .fetching)
        XCTAssertEqual(track.received, 0)
        track.received(1, of: 2)
        XCTAssertEqual(track.received, 0.5)
        XCTAssertEqual(track.stage, .fetching)
        track.received(2.4, of: 2)
        XCTAssertEqual(track.stage, .starting, "all the start needs is in, and it still says it's getting the picture")
    }

    func testAFilmOpensItsFileThenStarts() {
        var track = LoadTrack(began: tap, stage: .fetching)
        track.asked(.fetching, at: at(0.4))
        XCTAssertEqual(track.began, tap, "the clock restarted at the file instead of the tap")
        track.opened()
        XCTAssertEqual(track.stage, .starting)
        track.received(5, of: 2)
        XCTAssertEqual(track.stage, .starting, "data counted past the picture's step")
    }

    func testEveryStreamAskedForIsATryAndStartsItsStepsAgain() {
        var track = LoadTrack(began: tap)
        track.asked(at: at(0))
        track.gotAddress()
        track.opened()
        track.received(1, of: 2)
        track.asked(at: at(15))
        XCTAssertEqual(track.tries, 2)
        XCTAssertEqual(track.stage, .asking)
        XCTAssertNil(track.received)
        XCTAssertFalse(track.addressed, "the next copy's address was taken as known")
        XCTAssertEqual(track.began, tap, "a retry restarted the clock")
    }

    func testAStreamAskedForAfterThePictureIsADrop() {
        var track = LoadTrack(began: tap)
        track.asked(at: at(0))
        track.pictured()
        XCTAssertFalse(track.dropped)
        track.asked(at: at(60))
        XCTAssertTrue(track.dropped)
        XCTAssertEqual(track.began, at(60), "a drop counted from the tap")
        XCTAssertEqual(track.tries, 1)
        track.asked(at: at(62))
        XCTAssertEqual(track.began, at(60))
        XCTAssertEqual(track.tries, 2)
        track.pictured()
        XCTAssertFalse(track.dropped, "back with a picture and still called a drop")
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

    func testAStallCountsFromItsStart() {
        var track = LoadTrack(began: tap)
        track.asked(at: at(0))
        track.pictured()
        track.stalled(at: at(50))
        track.stalled(at: at(51))
        XCTAssertEqual(track.stalledSince, at(50))
        track.flowing()
        XCTAssertNil(track.stalledSince)
    }
}

import XCTest
@testable import OpenIPTV

final class WindowFlowTests: XCTestCase {
    private func flow(_ events: [WindowFlow.Event]) -> (WindowFlow, [[WindowFlow.Effect]]) {
        var flow = WindowFlow()
        let effects = events.map { flow.on($0) }
        return (flow, effects)
    }

    func testSwipingHomeStartsTheWindowWithTheScreenKept() {
        let (flow, effects) = flow([.offered, .willStart, .didStart])
        XCTAssertEqual(effects, [[], [.measureStart, .framesToWindow], []])
        XCTAssertEqual(flow.phase, .windowed(docked: false))
        XCTAssertFalse(flow.keepsFilm)
    }

    func testRestoreWithTheScreenKeptFinishesAtOnce() {
        let (flow, effects) = flow([.offered, .willStart, .didStart, .restoreAsked, .didStop])
        XCTAssertEqual(effects[3], [.measureReturn, .framesToScreen, .finishRestore(true)])
        XCTAssertEqual(effects[4], [])
        XCTAssertEqual(flow.phase, .inline)
    }

    func testOpeningTheAppPutsTheFilmBackInlineWhicheverWayIOSAnswers() {
        let stopped = flow([.offered, .willStart, .didStart, .appOpened, .didStop])
        XCTAssertEqual(stopped.1[3], [.measureReturn, .framesToScreen, .stopWindow])
        XCTAssertEqual(stopped.0.phase, .inline)
        let restored = flow([.offered, .willStart, .didStart, .appOpened, .restoreAsked, .didStop])
        XCTAssertEqual(restored.1[4], [.finishRestore(true)])
        XCTAssertEqual(restored.0.phase, .inline)
    }

    func testClosingTheWindowOverTheScreenPausesTheFilm() {
        let (flow, effects) = flow([.offered, .willStart, .didStart, .didStop])
        XCTAssertEqual(effects[3], [.framesToScreen, .pausePlayer])
        XCTAssertEqual(flow.phase, .inline)
    }

    func testTheButtonDocksTheLayerAndClosesTheScreen() {
        let (flow, effects) = flow([.offered, .buttonTapped, .willStart, .didStart])
        XCTAssertEqual(effects[1], [.measureStart, .framesToWindow, .startWindow])
        XCTAssertEqual(effects[2], [])
        XCTAssertEqual(effects[3], [.dock, .closeScreen])
        XCTAssertTrue(flow.keepsFilm)
    }

    func testTheButtonFailingSaysSoAndKeepsTheFilmInline() {
        let (flow, effects) = flow([.offered, .buttonTapped, .failedToStart])
        XCTAssertEqual(effects[2], [.framesToScreen, .noteUnavailable])
        XCTAssertEqual(flow.phase, .inline)
    }

    func testRestoreAfterTheButtonWaitsForTheScreen() {
        let (flow, effects) = flow([.offered, .buttonTapped, .didStart, .restoreAsked, .screenHosts, .didStop])
        XCTAssertEqual(effects[3], [.measureReturn, .presentScreen, .armRestoreTimeout])
        XCTAssertEqual(effects[4], [.framesToScreen, .finishRestore(true)])
        XCTAssertEqual(flow.phase, .inline)
        XCTAssertFalse(flow.keepsFilm)
    }

    func testRestoreThatNeverFindsTheScreenStopsTheFilm() {
        let (flow, effects) = flow([.offered, .buttonTapped, .didStart, .restoreAsked, .restoreTimedOut])
        XCTAssertEqual(effects[4], [.finishRestore(false), .stopWindow, .stopFilm, .releaseController])
        XCTAssertEqual(flow.phase, .none)
    }

    func testChoosingTheFilmAgainBringsItBack() {
        let (flow, effects) = flow([.offered, .buttonTapped, .didStart, .chosenAgain, .didStop, .screenHosts])
        XCTAssertEqual(effects[3], [.measureReturn, .stopWindow])
        XCTAssertEqual(effects[5], [.framesToScreen])
        XCTAssertEqual(flow.phase, .inline)
    }

    func testChoosingTheFilmAgainWhileIOSRestoresFinishesOnceTheScreenHolds() {
        let (_, effects) = flow([.offered, .buttonTapped, .didStart, .chosenAgain, .restoreAsked, .screenHosts])
        XCTAssertEqual(effects[4], [.armRestoreTimeout])
        XCTAssertEqual(effects[5], [.framesToScreen, .finishRestore(true)])
    }

    func testClosingTheDockedWindowStopsTheFilm() {
        let (flow, effects) = flow([.offered, .buttonTapped, .didStart, .didStop])
        XCTAssertEqual(effects[3], [.stopFilm, .releaseController])
        XCTAssertEqual(flow.phase, .none)
    }

    func testTheDockedFilmEndingClosesTheWindow() {
        let (flow, effects) = flow([.offered, .buttonTapped, .didStart, .filmEnded, .didStop])
        XCTAssertEqual(effects[3], [.stopWindow])
        XCTAssertEqual(effects[4], [.stopFilm, .releaseController])
        XCTAssertEqual(flow.phase, .none)
    }

    func testAnotherTitleStopsTheDockedFilm() {
        let (flow, effects) = flow([.offered, .buttonTapped, .didStart, .otherTitle])
        XCTAssertEqual(effects[3], [.stopWindow, .stopFilm, .releaseController])
        XCTAssertEqual(flow.phase, .none)
    }

    func testTheScreenLettingGoReleasesTheWindow() {
        XCTAssertEqual(flow([.offered, .screenLetGo]).1[1], [.releaseController])
        XCTAssertEqual(flow([.offered, .willStart, .didStart, .screenLetGo]).1[3], [.stopWindow, .releaseController])
        XCTAssertEqual(flow([.offered, .buttonTapped, .didStart, .screenLetGo]).1[3], [], "the docked window keeps the film")
    }

    func testStrayAndRepeatedEventsDoNothing() {
        let (flow, effects) = flow([.didStart, .restoreAsked, .offered, .offered, .didStop, .screenHosts, .willStart, .willStart])
        XCTAssertEqual(effects, [[], [], [], [], [], [], [.measureStart, .framesToWindow], []])
        XCTAssertEqual(flow.phase, .starting(byButton: false))
    }
}

import XCTest
@testable import OpenIPTV

final class PlaybackPresenceTests: XCTestCase {
    private func run(_ presence: PlaybackPresence, _ events: [PlaybackPresence.Event]) -> (PlaybackPresence, [[PlaybackPresence.Effect]]) {
        var presence = presence
        let effects = events.map { presence.on($0) }
        return (presence, effects)
    }

    private let tv = PlaybackPresence(pausesWhenAway: true)
    private let phone = PlaybackPresence(pausesWhenAway: false)

    func testAwakeOnlyWhileThePictureMoves() {
        XCTAssertFalse(tv.keepsAwake)
        let (playing, _) = run(tv, [.moving(true)])
        XCTAssertTrue(playing.keepsAwake)
        let (paused, _) = run(tv, [.moving(true), .moving(false)])
        XCTAssertFalse(paused.keepsAwake)
        let (playingAgain, _) = run(tv, [.moving(true), .moving(false), .moving(true)])
        XCTAssertTrue(playingAgain.keepsAwake)
    }

    func testAppleTVLeavingWhilePlayingPauses() {
        let (_, effects) = run(tv, [.moving(true), .app(.inactive), .app(.background)])
        XCTAssertEqual(effects, [[], [], [.pause]])
    }

    func testAppleTVOverlayDoesNotPause() {
        let (presence, effects) = run(tv, [.moving(true), .app(.inactive), .app(.active)])
        XCTAssertEqual(effects, [[], [], []])
        XCTAssertTrue(presence.keepsAwake)
    }

    func testAppleTVComingBackStaysPaused() {
        let (presence, effects) = run(tv, [.moving(true), .app(.background), .moving(false), .app(.inactive), .app(.active)])
        XCTAssertEqual(effects, [[], [.pause], [], [], []])
        XCTAssertFalse(presence.keepsAwake)
    }

    func testAppleTVLeavingWhilePausedDoesNothing() {
        let (_, effects) = run(tv, [.moving(true), .moving(false), .app(.background)])
        XCTAssertEqual(effects, [[], [], []])
    }

    func testAppleTVStartingInTheBackgroundPauses() {
        let (_, effects) = run(tv, [.app(.background), .moving(true)])
        XCTAssertEqual(effects, [[], [.pause]])
    }

    func testPhoneLeavingKeepsPlaying() {
        let (presence, effects) = run(phone, [.moving(true), .app(.inactive), .app(.background)])
        XCTAssertEqual(effects, [[], [], []])
        XCTAssertTrue(presence.keepsAwake)
    }
}

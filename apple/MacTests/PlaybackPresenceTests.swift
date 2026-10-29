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
        let (starting, _) = run(tv, [.playback(.loading)])
        XCTAssertFalse(starting.keepsAwake)
        let (playing, _) = run(tv, [.playback(.playing)])
        XCTAssertTrue(playing.keepsAwake)
        let (paused, _) = run(tv, [.playback(.playing), .playback(.paused)])
        XCTAssertFalse(paused.keepsAwake)
        let (playingAgain, _) = run(tv, [.playback(.playing), .playback(.paused), .playback(.playing)])
        XCTAssertTrue(playingAgain.keepsAwake)
        let (failed, _) = run(tv, [.playback(.playing), .playback(.stopped)])
        XCTAssertFalse(failed.keepsAwake)
    }

    func testAppleTVLeavingWhilePlayingPauses() {
        let (_, effects) = run(tv, [.playback(.playing), .app(.inactive), .app(.background)])
        XCTAssertEqual(effects, [[], [], [.pause]])
    }

    func testAppleTVLeavingWhileStartingPauses() {
        let (_, effects) = run(tv, [.playback(.loading), .app(.background)])
        XCTAssertEqual(effects, [[], [.pause]])
    }

    func testAppleTVOverlayDoesNotPause() {
        let (presence, effects) = run(tv, [.playback(.playing), .app(.inactive), .app(.active)])
        XCTAssertEqual(effects, [[], [], []])
        XCTAssertTrue(presence.keepsAwake)
    }

    func testAppleTVComingBackStaysPaused() {
        let (presence, effects) = run(tv, [.playback(.playing), .app(.background), .playback(.paused), .app(.inactive), .app(.active)])
        XCTAssertEqual(effects, [[], [.pause], [], [], []])
        XCTAssertFalse(presence.keepsAwake)
    }

    func testAppleTVLeavingWhilePausedOrStoppedDoesNothing() {
        let (_, paused) = run(tv, [.playback(.playing), .playback(.paused), .app(.background)])
        XCTAssertEqual(paused, [[], [], []])
        let (_, stopped) = run(tv, [.playback(.stopped), .app(.background)])
        XCTAssertEqual(stopped, [[], []])
    }

    func testAppleTVStartingInTheBackgroundPauses() {
        let (_, effects) = run(tv, [.playback(.loading), .app(.background), .playback(.playing)])
        XCTAssertEqual(effects, [[], [.pause], [.pause]])
    }

    func testPhoneLeavingKeepsPlaying() {
        let (presence, effects) = run(phone, [.playback(.playing), .app(.inactive), .app(.background)])
        XCTAssertEqual(effects, [[], [], []])
        XCTAssertTrue(presence.keepsAwake)
    }

    func testAskedToPauseTogglesOnlyWhilePlaying() {
        let (_, playing) = run(tv, [.playback(.playing), .asked(pause: true)])
        XCTAssertEqual(playing[1], [.toggle])
        let (_, paused) = run(tv, [.playback(.paused), .asked(pause: true)])
        XCTAssertEqual(paused[1], [])
        let (_, starting) = run(tv, [.playback(.loading), .asked(pause: true)])
        XCTAssertEqual(starting[1], [])
    }

    func testAskedToPlayTogglesOnlyWhilePausedInTheApp() {
        let (_, paused) = run(tv, [.playback(.paused), .asked(pause: false)])
        XCTAssertEqual(paused[1], [.toggle])
        let (_, overControlCenter) = run(tv, [.playback(.paused), .app(.inactive), .asked(pause: false)])
        XCTAssertEqual(overControlCenter[2], [.toggle])
        let (_, playing) = run(tv, [.playback(.playing), .asked(pause: false)])
        XCTAssertEqual(playing[1], [])
        let (_, stopped) = run(tv, [.playback(.stopped), .asked(pause: false)])
        XCTAssertEqual(stopped[1], [])
    }

    func testAskedToPlayAwayDoesNothing() {
        let (presence, effects) = run(tv, [.playback(.playing), .app(.background), .playback(.paused), .asked(pause: false)])
        XCTAssertEqual(effects[3], [])
        XCTAssertFalse(presence.keepsAwake)
    }
}

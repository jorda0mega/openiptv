import XCTest

/// The Siri Remote's sideways swipes in the film player (Apple TV), as in
/// Apple's own player. Regression: a swipe while the film played, on the way
/// to the subtitles and audio buttons or across them, skipped the film.
final class RemoteSwipeTests: XCTestCase {
    func testPlayingSwipeOnTheBarOnlyShowsTheControls() {
        XCTAssertEqual(RemoteSwipe.action(at: .bar, paused: false, scrubbing: false, distance: 400), .showControls)
    }

    func testPausedSwipeOnTheBarMovesThroughTheFilm() {
        XCTAssertEqual(RemoteSwipe.action(at: .bar, paused: true, scrubbing: false, distance: 400), .scrub)
        // Already choosing a point (a click on the ring started it): on.
        XCTAssertEqual(RemoteSwipe.action(at: .bar, paused: false, scrubbing: true, distance: 400), .scrub)
    }

    func testSwipeOnTheButtonsMovesBetweenThem() {
        XCTAssertEqual(RemoteSwipe.action(at: .buttons, paused: false, scrubbing: false, distance: 100), .moveFocus(0))
        XCTAssertEqual(RemoteSwipe.action(at: .buttons, paused: false, scrubbing: false, distance: 320), .moveFocus(1))
        XCTAssertEqual(RemoteSwipe.action(at: .buttons, paused: false, scrubbing: false, distance: -320), .moveFocus(-1))
        // One button per stretch of the swipe, each once.
        XCTAssertEqual(RemoteSwipe.action(at: .buttons, paused: false, scrubbing: false, distance: 650, stepsTaken: 1), .moveFocus(1))
        XCTAssertEqual(RemoteSwipe.action(at: .buttons, paused: false, scrubbing: false, distance: 650, stepsTaken: 2), .moveFocus(0))
        // Never through the film from the buttons, paused or not.
        XCTAssertNotEqual(RemoteSwipe.action(at: .buttons, paused: true, scrubbing: false, distance: 900), .scrub)
    }

    /// Apple TV: paused, a swipe chooses a point; a click plays from it, as
    /// in Apple's player. Regression: the click kept the point but left the
    /// film paused there, and it took a second click to play.
    func testClickOnAChosenPointPlaysFromIt() {
        XCTAssertTrue(RemoteSwipe.playsAfterChoosing(byClick: true, wasPlaying: false))
        XCTAssertTrue(RemoteSwipe.playsAfterChoosing(byClick: true, wasPlaying: true))
    }

    /// Letting go (of a held button, or the finger on iPhone) carries on as
    /// it was: playing if it played, paused if it was paused.
    func testLettingGoKeepsHowItWas() {
        XCTAssertTrue(RemoteSwipe.playsAfterChoosing(byClick: false, wasPlaying: true))
        XCTAssertFalse(RemoteSwipe.playsAfterChoosing(byClick: false, wasPlaying: false))
    }

    /// Apple TV: up or down needs a swipe, not the finger rolling as it
    /// clicks. Regression: 24 points down during a click opened the Info
    /// panel (with "From Beginning" ready for the next click).
    func testAClickIsNotASwipeDown() {
        XCTAssertNil(RemoteSwipe.vertical(travel: 40, clicked: true))
        XCTAssertNil(RemoteSwipe.vertical(travel: 200, clicked: true))
        XCTAssertNil(RemoteSwipe.vertical(travel: 40, clicked: false))
    }

    func testASwipeUpOrDownIsAPressThatWay() {
        XCTAssertEqual(RemoteSwipe.vertical(travel: 200, clicked: false), .down)
        XCTAssertEqual(RemoteSwipe.vertical(travel: -200, clicked: false), .up)
    }
}

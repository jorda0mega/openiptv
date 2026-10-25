import XCTest
@testable import OpenIPTV

@MainActor
final class PlayerFacingTests: XCTestCase {
    private let gravity = FakeGravity()
    private var turns: [PlayerFacing.Turn] = []
    private lazy var facing = PlayerFacing(gravity: gravity) { [unowned self] in turns.append($0) }

    private static let heldLeft = PlayerFacing.Gravity(x: 0.95, y: -0.1, z: -0.2)
    private static let heldRight = PlayerFacing.Gravity(x: -0.95, y: -0.1, z: -0.2)
    private static let upright = PlayerFacing.Gravity(x: 0.05, y: -0.98, z: -0.15)

    private func filmOpen() {
        facing.playerAppeared(sensing: true)
    }

    private func feel(_ sample: PlayerFacing.Gravity, from start: TimeInterval, for seconds: TimeInterval) {
        for step in 0...Int(seconds * 10) {
            gravity.feel(sample, at: start + Double(step) / 10)
        }
    }

    func testSwipeUpWithNothingSensedTurnsToLandscapeRight() {
        filmOpen()
        facing.swiped(.up, from: .portrait)
        XCTAssertEqual(turns, [.hold(.landscapeRight)])
    }

    func testSwipeUpTurnsToTheSideThePhoneIsHeldToward() {
        filmOpen()
        gravity.feel(Self.heldLeft, at: 1)
        facing.swiped(.up, from: .portrait)
        XCTAssertEqual(turns.last, .hold(.landscapeLeft))

        facing.swiped(.down, from: .landscapeLeft)
        gravity.feel(Self.heldRight, at: 2)
        facing.swiped(.up, from: .portrait)
        XCTAssertEqual(turns.last, .hold(.landscapeRight))
    }

    func testAPhoneHeldUprightTurnsToLandscapeRight() {
        filmOpen()
        gravity.feel(Self.upright, at: 1)
        facing.swiped(.up, from: .portrait)
        XCTAssertEqual(turns, [.hold(.landscapeRight)])
    }

    func testSwipeDownWhenSidewaysTurnsUpright() {
        filmOpen()
        facing.swiped(.down, from: .landscapeLeft)
        facing.swiped(.down, from: .landscapeRight)
        XCTAssertEqual(turns, [.hold(.portrait), .hold(.portrait)])
    }

    func testSwipesTheOtherWayDoNothing() {
        filmOpen()
        facing.swiped(.down, from: .portrait)
        facing.swiped(.up, from: .landscapeRight)
        XCTAssertEqual(turns, [])
    }

    func testRotateButtonDoesWhatTheSwipesDo() {
        filmOpen()
        gravity.feel(Self.heldLeft, at: 1)
        facing.rotate(from: .portrait)
        facing.rotate(from: .landscapeLeft)
        XCTAssertEqual(turns, [.hold(.landscapeLeft), .hold(.portrait)])
    }

    func testTurningThePhoneOverTurnsThePictureOver() {
        filmOpen()
        facing.swiped(.up, from: .portrait)
        feel(Self.heldLeft, from: 1, for: 0.5)
        XCTAssertEqual(turns, [.hold(.landscapeRight), .hold(.landscapeLeft)])

        feel(Self.heldRight, from: 2, for: 0.5)
        XCTAssertEqual(turns.last, .hold(.landscapeRight))
        XCTAssertEqual(turns.count, 3, "one turn for each time the phone is turned over")
    }

    func testAPhoneReclinedOnItsSideStillTurnsOver() {
        filmOpen()
        facing.swiped(.up, from: .portrait)
        feel(PlayerFacing.Gravity(x: 0.45, y: -0.05, z: -0.89), from: 1, for: 0.5)
        XCTAssertEqual(turns.last, .hold(.landscapeLeft))
    }

    func testShakingDoesNotTurnThePictureOver() {
        filmOpen()
        facing.swiped(.up, from: .portrait)
        for step in 0..<20 {
            gravity.feel(step.isMultiple(of: 3) ? Self.heldLeft : Self.heldRight, at: 1 + Double(step) / 10)
        }
        feel(PlayerFacing.Gravity(x: 0.5, y: -0.85, z: -0.1), from: 3, for: 1)
        XCTAssertEqual(turns, [.hold(.landscapeRight)])
    }

    func testAPhoneLyingFlatDoesNotTurnThePictureOver() {
        filmOpen()
        facing.swiped(.up, from: .portrait)
        feel(PlayerFacing.Gravity(x: 0.3, y: 0, z: -0.95), from: 1, for: 1)
        feel(PlayerFacing.Gravity(x: 0.3, y: 0, z: 0.95), from: 3, for: 1)
        XCTAssertEqual(turns, [.hold(.landscapeRight)])
    }

    func testSidewaysTurningThePhoneUprightKeepsThePictureSideways() {
        filmOpen()
        facing.swiped(.up, from: .portrait)
        feel(Self.upright, from: 1, for: 1)
        XCTAssertEqual(turns, [.hold(.landscapeRight)])
    }

    func testUprightTurningThePhoneSidewaysKeepsThePictureUpright() {
        filmOpen()
        facing.swiped(.up, from: .portrait)
        facing.swiped(.down, from: .landscapeRight)
        feel(Self.heldLeft, from: 1, for: 1)
        XCTAssertEqual(turns, [.hold(.landscapeRight), .hold(.portrait)])
    }

    func testPhoneTurnedWithRotationLockOffFollowsThePhoneAsBefore() {
        filmOpen()
        facing.phoneTurned(to: .landscapeLeft)
        XCTAssertEqual(turns, [], "nothing held: iOS turns it by itself")

        facing.swiped(.up, from: .portrait)
        facing.phoneTurned(to: .landscapeRight)
        XCTAssertEqual(turns, [.hold(.landscapeRight)], "turned the way it already faces")

        facing.phoneTurned(to: .portrait)
        XCTAssertEqual(turns.last, .follow(.portrait))
        facing.phoneTurned(to: .landscapeLeft)
        XCTAssertEqual(turns.count, 2, "following the phone again, iOS turns it by itself")
    }

    func testOnlyTheFilmPlayerSensesGravity() {
        facing.playerAppeared(sensing: false)
        XCTAssertFalse(gravity.running)
        facing.rotate(from: .portrait)
        XCTAssertEqual(turns, [.hold(.landscapeRight)])
        facing.playerDisappeared()

        filmOpen()
        XCTAssertTrue(gravity.running)
    }

    func testSensorStopsWhenThePlayerCloses() {
        filmOpen()
        facing.playerDisappeared()
        XCTAssertFalse(gravity.running)
        facing.app(inForeground: false)
        facing.app(inForeground: true)
        XCTAssertFalse(gravity.running, "back from the background with no player open")
    }

    func testSensorStopsInTheBackgroundAndStartsAgainOnReturn() {
        filmOpen()
        facing.app(inForeground: false)
        XCTAssertFalse(gravity.running)
        facing.app(inForeground: true)
        facing.app(inForeground: true)
        XCTAssertTrue(gravity.running)
        XCTAssertEqual(gravity.starts, 2, "started once on opening and once on return")
    }

    func testAReadingFromBeforeTheBackgroundDoesNotChooseTheSide() {
        filmOpen()
        gravity.feel(Self.heldLeft, at: 1)
        facing.app(inForeground: false)
        facing.app(inForeground: true)
        facing.swiped(.up, from: .portrait)
        XCTAssertEqual(turns, [.hold(.landscapeRight)])
    }

    func testClosingThePlayerForgetsTheHeldWay() {
        filmOpen()
        facing.swiped(.up, from: .portrait)
        facing.playerDisappeared()
        filmOpen()
        facing.phoneTurned(to: .portrait)
        XCTAssertEqual(turns, [.hold(.landscapeRight)])
    }

    func testAVerticalDragIsASwipe() {
        XCTAssertEqual(PlayerFacing.swipe(dx: 12, dy: -140), .up)
        XCTAssertEqual(PlayerFacing.swipe(dx: -20, dy: 120), .down)
    }

    func testAShortOrSidewaysDragIsNotASwipe() {
        XCTAssertNil(PlayerFacing.swipe(dx: 0, dy: -30))
        XCTAssertNil(PlayerFacing.swipe(dx: 160, dy: -90))
    }
}

@MainActor
private final class FakeGravity: GravitySource {
    private(set) var starts = 0
    private var felt: ((PlayerFacing.Gravity, TimeInterval) -> Void)?
    var running: Bool { felt != nil }

    func start(_ felt: @escaping @MainActor (PlayerFacing.Gravity, TimeInterval) -> Void) {
        starts += 1
        self.felt = felt
    }

    func stop() {
        felt = nil
    }

    func feel(_ sample: PlayerFacing.Gravity, at time: TimeInterval) {
        felt?(sample, time)
    }
}

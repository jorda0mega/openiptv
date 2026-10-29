import XCTest
@testable import OpenIPTV

final class TimersTests: XCTestCase {
    private final class Clocks: @unchecked Sendable {
        var wall = 0.0
        var naps = 0
    }

    func testSleepingUntilADateWaitsForTheWallClockEvenWhenItLags() async throws {
        let clocks = Clocks()
        let due = Date(timeIntervalSinceReferenceDate: 10)
        try await Timers.sleep(until: due, now: { Date(timeIntervalSinceReferenceDate: clocks.wall) }) { seconds in
            clocks.naps += 1
            clocks.wall += seconds / 2
        }
        XCTAssertGreaterThanOrEqual(clocks.wall, 9.999, "woke with the wall clock \(clocks.wall) s short of the change")
        XCTAssertGreaterThan(clocks.naps, 1)
    }

    func testADateAlreadyPastDoesNotSleep() async throws {
        let clocks = Clocks()
        clocks.wall = 12
        try await Timers.sleep(until: Date(timeIntervalSinceReferenceDate: 10), now: { Date(timeIntervalSinceReferenceDate: clocks.wall) }) { _ in
            clocks.naps += 1
        }
        XCTAssertEqual(clocks.naps, 0)
    }

    func testCancellingTheWaiterCancelsTheTaskItWaitsFor() async throws {
        let stopped = expectation(description: "the task waited for was cancelled")
        let work = Task<Int, Error> {
            do { try await Task.sleep(for: .seconds(30)) } catch { stopped.fulfill(); throw error }
            return 1
        }
        let waiter = Task { try await Timers.value(of: work) }
        try await Task.sleep(for: .milliseconds(100))
        waiter.cancel()
        await fulfillment(of: [stopped], timeout: 2)
    }
}

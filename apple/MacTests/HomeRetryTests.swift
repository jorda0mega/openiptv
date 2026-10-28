import XCTest
@testable import OpenIPTV

@MainActor
final class HomeRetryTests: XCTestCase {
    private final class FakeSleep: @unchecked Sendable {
        private let lock = NSLock()
        private var waits: [Duration] = []
        private let waitsPass: Bool

        init(waitsPass: Bool) { self.waitsPass = waitsPass }

        var asked: [Duration] { lock.withLock { waits } }

        func sleep(_ wait: Duration) async throws {
            lock.withLock { waits.append(wait) }
            if waitsPass || wait == .zero { return try Task.checkCancellation() }
            try await Task.sleep(for: .seconds(3600))
        }
    }

    private func settle(until done: () -> Bool = { false }) async {
        for _ in 0..<200 where !done() { await Task.yield() }
    }

    func testAsksAgainAfter2Then5Then15ThenEvery30SecondsUntilHomeLoads() async {
        let sleeps = FakeSleep(waitsPass: true)
        var attempts = 0
        var retry: HomeRetry!
        retry = HomeRetry(sleep: sleeps.sleep) {
            attempts += 1
            if attempts < 6 { retry.askAgainLater() } else { retry.stop() }
        }
        retry.askAgainLater()
        await settle { attempts == 6 }
        await settle()
        XCTAssertEqual(attempts, 6)
        XCTAssertEqual(sleeps.asked, [2, 5, 15, 30, 30, 30].map { Duration.seconds($0) })
    }

    func testAFailureAfterHomeLoadedWaitsTheShortestAgain() async {
        let sleeps = FakeSleep(waitsPass: true)
        var attempts = 0
        var retry: HomeRetry!
        retry = HomeRetry(sleep: sleeps.sleep) {
            attempts += 1
            if attempts < 3 { retry.askAgainLater() } else { retry.stop() }
        }
        retry.askAgainLater()
        await settle { attempts == 3 }
        retry.askAgainLater()
        await settle { attempts == 4 }
        XCTAssertEqual(sleeps.asked, [2, 5, 15, 2].map { Duration.seconds($0) })
    }

    func testAFailureWhileARetryWaitsKeepsItsTime() async {
        let sleeps = FakeSleep(waitsPass: false)
        let retry = HomeRetry(sleep: sleeps.sleep) {}
        retry.askAgainLater()
        retry.askAgainLater()
        retry.askAgainLater()
        await settle()
        XCTAssertEqual(sleeps.asked, [.seconds(2)])
    }

    func testFailingFromAFailureUntilHomeLoads() {
        let retry = HomeRetry(sleep: FakeSleep(waitsPass: false).sleep) {}
        XCTAssertFalse(retry.failing)
        retry.askAgainLater()
        XCTAssertTrue(retry.failing)
        retry.stop()
        XCTAssertFalse(retry.failing)
    }

    func testAsksAtOnceWhenToldWhileWaiting() async {
        let sleeps = FakeSleep(waitsPass: false)
        var attempts = 0
        let retry = HomeRetry(sleep: sleeps.sleep) { attempts += 1 }
        retry.askAgainLater()
        await settle()
        XCTAssertEqual(attempts, 0)
        retry.askAgainNow()
        await settle { attempts == 1 }
        XCTAssertEqual(attempts, 1)
    }

    func testDoesNothingWhenToldWithNothingWaiting() async {
        let sleeps = FakeSleep(waitsPass: false)
        var attempts = 0
        let retry = HomeRetry(sleep: sleeps.sleep) { attempts += 1 }
        retry.askAgainNow()
        retry.askAgainLater()
        retry.stop()
        retry.askAgainNow()
        await settle()
        XCTAssertEqual(attempts, 0)
    }
}

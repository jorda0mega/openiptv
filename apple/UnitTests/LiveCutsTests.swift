import XCTest

final class LiveCutsTests: XCTestCase {
    private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    func testWaitGrowsThenGivesUp() {
        var cuts = LiveCuts()
        cuts.played("a", at: at(0))
        XCTAssertEqual(cuts.cut("a", at: at(5)), .reopen(after: 0))
        cuts.played("a", at: at(6))
        XCTAssertEqual(cuts.cut("a", at: at(10)), .reopen(after: 1))
        cuts.played("a", at: at(12))
        XCTAssertEqual(cuts.cut("a", at: at(20)), .reopen(after: 2))
        cuts.played("a", at: at(23))
        XCTAssertEqual(cuts.cut("a", at: at(30)), .giveUp, "a fourth cut within 3 min")
    }

    func testCleanPlayStartsTheWaitOver() {
        var cuts = LiveCuts()
        cuts.played("a", at: at(0))
        XCTAssertEqual(cuts.cut("a", at: at(10)), .reopen(after: 0))
        cuts.played("a", at: at(11))
        XCTAssertEqual(cuts.cut("a", at: at(20)), .reopen(after: 1))
        cuts.played("a", at: at(21))
        XCTAssertEqual(cuts.cut("a", at: at(90)), .reopen(after: 0), "69 s of clean play kept the longer wait")
    }

    func testOldCutsDontCount() {
        var cuts = LiveCuts()
        XCTAssertEqual(cuts.cut("a", at: at(0)), .reopen(after: 0))
        XCTAssertEqual(cuts.cut("a", at: at(100)), .reopen(after: 1))
        XCTAssertEqual(cuts.cut("a", at: at(200)), .reopen(after: 2))
        XCTAssertEqual(cuts.cut("a", at: at(300)), .reopen(after: 4), "cuts over 3 min ago counted")
        XCTAssertEqual(cuts.cut("a", at: at(400)), .reopen(after: 8))
        XCTAssertEqual(cuts.cut("a", at: at(500)), .reopen(after: 8), "the wait passed its longest")
    }

    func testAnotherCopyStartsFresh() {
        var cuts = LiveCuts()
        for second in [0.0, 1, 2] { _ = cuts.cut("a", at: at(second)) }
        XCTAssertEqual(cuts.cut("b", at: at(3)), .reopen(after: 0), "another copy's cuts counted")
        XCTAssertEqual(cuts.cut("a", at: at(4)), .reopen(after: 0))
    }
}

import XCTest
@testable import OpenIPTV

final class LoadEventsTests: XCTestCase {
    func testAReplacedFilesEventsDontHideTheNextPicture() {
        var loads = LoadEvents()
        loads.asked(1, entry: 10)
        loads.started(entry: 10)
        XCTAssertEqual(loads.restarted(), 1)
        loads.asked(2, entry: 11)
        XCTAssertNil(loads.restarted(), "a jump in the replaced file was taken for a first picture")
        loads.started(entry: 11)
        XCTAssertEqual(loads.restarted(), 2, "the new file's first picture was hidden")
        XCTAssertNil(loads.restarted(), "a jump was taken for a first picture")
    }

    func testAFirstPictureFromAFileZappedAwayFromIsItsOwn() {
        var loads = LoadEvents()
        loads.asked(1, entry: 10)
        loads.started(entry: 10)
        loads.asked(2, entry: 11)
        XCTAssertEqual(loads.restarted(), 1, "the old file's late picture was given to the new load")
        loads.started(entry: 11)
        XCTAssertEqual(loads.restarted(), 2)
    }

    func testEndsBelongToTheirOwnFile() {
        var loads = LoadEvents()
        loads.asked(1, entry: 10)
        loads.started(entry: 10)
        loads.asked(2, entry: 11)
        XCTAssertEqual(loads.ended(entry: 10), 1)
        loads.started(entry: 11)
        XCTAssertEqual(loads.current, 2)
        XCTAssertEqual(loads.ended(entry: 11), 2)
    }

    func testAWarningReadAfterTheNextFileStartsIsNobodys() {
        var loads = LoadEvents()
        loads.asked(1, entry: 10)
        loads.drainBegan()
        loads.started(entry: 10)
        loads.drainBegan()
        XCTAssertEqual(loads.logAttempt, 1)
        loads.asked(2, entry: 11)
        loads.drainBegan()
        XCTAssertEqual(loads.started(entry: 11), 2)
        XCTAssertNil(loads.logAttempt, "a warning from the file before was given to the file that started")
        loads.drainBegan()
        XCTAssertEqual(loads.logAttempt, 2)
    }

    func testWithoutAnEntryTheLoadIsCurrentAtOnce() {
        var loads = LoadEvents()
        loads.asked(3, entry: nil)
        XCTAssertEqual(loads.current, 3)
        XCTAssertEqual(loads.restarted(), 3)
    }
}

#if DEBUG
import XCTest
@testable import OpenIPTV

final class StartReadLogTests: XCTestCase {
    func testAReadOfTheLastStartCountsNothingForTheNext() {
        let relay = StreamRelay()
        relay.beginStartReads()
        let earlier = relay.noteStartRead("bytes=0-", cache: nil, device: 0)
        relay.beginStartReads()
        _ = relay.noteStartRead("bytes=0-", cache: nil, device: 0)
        relay.noteFetch(firstByteAfter: 0.5, for: earlier)
        relay.noteFetched(1_000_000, for: earlier)
        XCTAssertEqual(relay.serverBytes, 0, "the last start's read counted for this one")
        XCTAssertTrue(relay.startReadsReadout.hasPrefix("reads 1, from the device 0.0 MB, from the server 0 reads 0.0 MB first byte up to 0 ms"),
                      relay.startReadsReadout)
        XCTAssertTrue(relay.startReadsReadout.hasSuffix("server 0.00"), relay.startReadsReadout)
    }

    func testTheLogKeepsNoStoreLetGo() throws {
        let relay = StreamRelay()
        var cache = try XCTUnwrap(ByteCache(limit: 1 << 20)) as ByteCache?
        weak let held = cache
        _ = relay.noteStartRead("bytes=0-", cache: cache, device: 0)
        cache = nil
        XCTAssertNil(held, "the log kept the store of a file let go")
    }
}
#endif

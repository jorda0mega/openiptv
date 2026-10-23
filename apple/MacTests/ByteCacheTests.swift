import XCTest
@testable import OpenIPTV

/// mpv reads a file again from ten seconds back for a track it hasn't
/// been reading. Those bytes have to stay near the read, or the server
/// sends them again and the film stops.
final class ByteCacheTests: XCTestCase {
    private let megabyte = 1 << 20

    private func megabyte(_ n: Int) -> Data { Data(repeating: UInt8(n % 251), count: megabyte) }

    private func read(_ megabytes: ClosedRange<Int>, into cache: ByteCache) {
        for n in megabytes {
            let data = megabyte(n)
            for part in stride(from: 0, to: megabyte, by: 64 << 10) {
                cache.store(data.subdata(in: part..<part + (64 << 10)), at: Int64(n * megabyte + part))
            }
        }
    }

    /// Regression: past its limit (1 GB) it kept nothing new until the
    /// player had read 64 MB more, then let everything behind go and began
    /// again at the newest bytes. Until the film reached them, what it
    /// played and the ten seconds before came from the server again for
    /// subtitles picked then: 4 s stopped.
    func testAFilmReadPastTheLimitKeepsItsNewestBytes() throws {
        let cache = try XCTUnwrap(ByteCache(limit: Int64(8 * megabyte)))
        read(0...74, into: cache)
        let back = 75 - 7
        XCTAssertEqual(cache.available(from: Int64(back * megabyte)), Int64(7 * megabyte), "the 7 MB just read aren't all kept")
        let kept = try XCTUnwrap(cache.read(Int64(back * megabyte), 7 * megabyte), "the 7 MB just read don't read back")
        XCTAssertEqual(kept, (back..<75).reduce(into: Data()) { $0.append(megabyte($1)) }, "not the bytes that were read there")
        XCTAssertEqual(cache.available(from: 0), 0, "the first bytes are still kept, over the limit")
    }

    /// The store is in the app's temporary folder, which tvOS empties when
    /// it needs room. Emptied while a film plays, its open file still reads
    /// and takes more, and the next film's store is made again.
    func testAStoreEmptiedFromUnderAPlayingFilmStillReadsAndTheNextIsMade() throws {
        let cache = try XCTUnwrap(ByteCache(limit: Int64(8 * megabyte)))
        read(0...1, into: cache)
        ByteCache.removeLeftovers()
        let folder = FileManager.default.temporaryDirectory.appending(path: "relay-cache").path()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder), "the folder wasn't emptied")
        read(2...3, into: cache)
        XCTAssertEqual(cache.read(0, 4 * megabyte), (0...3).reduce(into: Data()) { $0.append(megabyte($1)) })
        let next = try XCTUnwrap(ByteCache(limit: Int64(8 * megabyte)), "no store for the next film")
        read(0...0, into: next)
        XCTAssertEqual(next.read(0, megabyte), megabyte(0))
    }

    func testTheIndexFetchedAheadIsKeptWhenTheFilmFillsTheStore() throws {
        let cache = try XCTUnwrap(ByteCache(limit: Int64(8 * megabyte)))
        let index = Data(repeating: 7, count: 256 << 10)
        let indexAt = Int64(500 * megabyte)
        cache.store(index, at: indexAt, evicting: false)
        read(0...11, into: cache)
        XCTAssertEqual(cache.read(indexAt, index.count), index, "the index fetched ahead was let go")
        XCTAssertEqual(cache.available(from: Int64(5 * megabyte)), Int64(7 * megabyte), "the 7 MB just read aren't all kept")
    }

    func testAnIndexThePlayerReadIsKeptOnceAskedForAhead() throws {
        let cache = try XCTUnwrap(ByteCache(limit: Int64(8 * megabyte)))
        let index = Data(repeating: 7, count: 256 << 10)
        let indexAt = Int64(500 * megabyte)
        cache.store(index, at: indexAt)
        cache.keep(indexAt..<indexAt + Int64(index.count))
        read(0...11, into: cache)
        XCTAssertEqual(cache.read(indexAt, index.count), index, "the index the player read was let go")
        XCTAssertEqual(cache.available(from: Int64(5 * megabyte)), Int64(7 * megabyte), "the 7 MB just read aren't all kept")
    }

    func testAJumpBackKeepsTheBytesReadThere() throws {
        let cache = try XCTUnwrap(ByteCache(limit: Int64(8 * megabyte)))
        read(50...55, into: cache)
        read(0...5, into: cache)
        XCTAssertEqual(cache.available(from: 0), Int64(6 * megabyte), "the bytes read after the jump aren't all kept")
        XCTAssertLessThanOrEqual(cache.available(from: Int64(50 * megabyte)), Int64(2 * megabyte), "more than the limit is kept")
    }

    func testAReadWaitsForTheSameBytesOnTheirWayAndGoesOnIfTheyDontCome() throws {
        let cache = try XCTUnwrap(ByteCache(limit: Int64(8 * megabyte)))
        let one = Int64(megabyte)
        XCTAssertFalse(cache.whenHere(0, needing: one, within: .seconds(5)) {}, "waited for bytes nobody asked for")
        let here = expectation(description: "the read goes on once they're here"), lost = expectation(description: "and when they don't come")
        cache.expect(0..<one)
        cache.expect(one..<2 * one)
        XCTAssertTrue(cache.whenHere(0, needing: one, within: .seconds(5)) { here.fulfill() })
        XCTAssertTrue(cache.whenHere(one, needing: one, within: .seconds(5)) { lost.fulfill() })
        cache.store(megabyte(0), at: 0)
        cache.arrived(0..<one)
        cache.arrived(one..<2 * one)
        wait(for: [here, lost], timeout: 1)
        XCTAssertEqual(cache.available(from: 0), one)
        XCTAssertFalse(cache.whenHere(0, needing: one, within: .seconds(5)) {}, "waited for bytes already here")
    }

    /// A read of the index's place that waited 2.5 s for the 64 KB asked
    /// there ahead still had to ask the server for the rest, 2.7 s more.
    func testAReadDoesntWaitForPartOfItsBytesNorForMore() throws {
        let cache = try XCTUnwrap(ByteCache(limit: Int64(8 * megabyte)))
        cache.expect(0..<(64 << 10))
        XCTAssertFalse(cache.whenHere(0, needing: 512 << 10, within: .seconds(5)) {}, "waited for part of what it asks")
        cache.expect(Int64(megabyte)..<Int64(9 * megabyte))
        XCTAssertFalse(cache.whenHere(Int64(megabyte), needing: 512 << 10, within: .seconds(5)) {}, "waited for 8 MB landing whole")
        XCTAssertFalse(cache.whenHere(Int64(2 * megabyte), needing: 512 << 10, within: .seconds(5)) {}, "waited from inside a read")
    }

    func testAReadWaitsNoLongerThanItsLimit() throws {
        let cache = try XCTUnwrap(ByteCache(limit: Int64(8 * megabyte)))
        let late = expectation(description: "the read goes on at its limit")
        late.assertForOverFulfill = true
        cache.expect(0..<Int64(megabyte))
        XCTAssertTrue(cache.whenHere(0, needing: Int64(megabyte), within: .milliseconds(100)) { late.fulfill() })
        wait(for: [late], timeout: 1)
        cache.arrived(0..<Int64(megabyte))
    }
}

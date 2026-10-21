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

    func testTheIndexFetchedAheadIsKeptWhenTheFilmFillsTheStore() throws {
        let cache = try XCTUnwrap(ByteCache(limit: Int64(8 * megabyte)))
        let index = Data(repeating: 7, count: 256 << 10)
        let indexAt = Int64(500 * megabyte)
        cache.store(index, at: indexAt, evicting: false)
        read(0...11, into: cache)
        XCTAssertEqual(cache.read(indexAt, index.count), index, "the index fetched ahead was let go")
        XCTAssertEqual(cache.available(from: Int64(5 * megabyte)), Int64(7 * megabyte), "the 7 MB just read aren't all kept")
    }

    /// A film opened with nothing fetched ahead: the player reads its index
    /// itself, with the rest, and the relay then finds it already here.
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
}

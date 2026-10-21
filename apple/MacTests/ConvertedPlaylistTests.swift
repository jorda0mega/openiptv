import XCTest
@testable import OpenIPTV

final class ConvertedPlaylistTests: XCTestCase {
    private let master = URL(string: "https://emby.example/emby/Videos/m1/master.m3u8?MediaSourceId=m1&StartTimeTicks=3015000000")!
    private let variant = URL(string: "https://emby.example/emby/Videos/m1/main.m3u8?MediaSourceId=m1&PlaySessionId=p1")!

    /// Emby's: the whole film from 0:00 in 3 s segments, whatever second it
    /// was asked from.
    private func emby(segments: Int) -> [String] {
        ["#EXTM3U", "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:3", "#EXT-X-MEDIA-SEQUENCE:0"]
            + (0..<segments).flatMap { ["#EXTINF:3.000000, nodesc", "hls1/main/\($0).ts?PlaySessionId=p1"] } + ["#EXT-X-ENDLIST"]
    }

    private func segments(_ text: String) -> [String] {
        text.split(separator: "\n").filter { !$0.hasPrefix("#") }.map(String.init)
    }

    func testTheVariantIsWhereTheMasterSays() {
        let found = ConvertedPlaylist.variant(of: ["#EXTM3U", "#EXT-X-STREAM-INF:BANDWIDTH=2000000", "main.m3u8?MediaSourceId=m1&PlaySessionId=p1"],
                                              at: master)
        XCTAssertEqual(found, variant)
    }

    /// Regression: given the whole film, the player read its first segment
    /// and then jumped to 5:01, and Emby converted twice (the film's start,
    /// then 5:00), each a wait for its slow first segment.
    func testAConvertedVersionIsListedFromTheSegmentHoldingTheSecond() throws {
        let list = try XCTUnwrap(ConvertedPlaylist(emby(segments: 200), at: variant))
        let (text, start) = list.from(301.5)
        XCTAssertEqual(start, 300, "the player's clock 0 isn't where its first segment starts")
        let listed = segments(text)
        XCTAssertEqual(listed.first, "https://emby.example/emby/Videos/m1/hls1/main/100.ts?PlaySessionId=p1")
        XCTAssertEqual(listed.count, 100)
        XCTAssertTrue(text.contains("#EXT-X-MEDIA-SEQUENCE:100\n"), text)
        XCTAssertTrue(text.hasSuffix("#EXT-X-ENDLIST\n"))
    }

    func testFromTheStartItIsTheWholeFilm() throws {
        let list = try XCTUnwrap(ConvertedPlaylist(emby(segments: 200), at: variant))
        let (text, start) = list.from(0)
        XCTAssertEqual(start, 0)
        XCTAssertEqual(segments(text).count, 200)
    }

    func testPastTheEndItIsTheLastSegment() throws {
        let list = try XCTUnwrap(ConvertedPlaylist(emby(segments: 200), at: variant))
        let (text, start) = list.from(10_000)
        XCTAssertEqual(start, 597)
        XCTAssertEqual(segments(text).first, "https://emby.example/emby/Videos/m1/hls1/main/199.ts?PlaySessionId=p1")
        XCTAssertEqual(segments(text).count, 1)
    }

    func testAPlaylistStillGrowingOrWithKeysIsLeftAsItIs() {
        XCTAssertNil(ConvertedPlaylist(Array(emby(segments: 3).dropLast()), at: variant), "still growing")
        var keyed = emby(segments: 3)
        keyed.insert("#EXT-X-KEY:METHOD=AES-128,URI=\"key\"", at: 5)
        XCTAssertNil(ConvertedPlaylist(keyed, at: variant), "a key at another address")
    }
}

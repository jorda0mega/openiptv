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
        let (text, start) = list.listed(from:301.5)
        XCTAssertEqual(start, 300, "the player's clock 0 isn't where its first segment starts")
        let listed = segments(text)
        XCTAssertEqual(listed.first, "https://emby.example/emby/Videos/m1/hls1/main/100.ts?PlaySessionId=p1")
        XCTAssertEqual(listed.count, 100)
        XCTAssertTrue(text.contains("#EXT-X-MEDIA-SEQUENCE:100\n"), text)
        XCTAssertTrue(text.hasSuffix("#EXT-X-ENDLIST\n"))
    }

    func testFromTheStartItIsTheWholeFilm() throws {
        let list = try XCTUnwrap(ConvertedPlaylist(emby(segments: 200), at: variant))
        let (text, start) = list.listed(from:0)
        XCTAssertEqual(start, 0)
        XCTAssertEqual(segments(text).count, 200)
    }

    func testPastTheEndItIsTheLastSegment() throws {
        let list = try XCTUnwrap(ConvertedPlaylist(emby(segments: 200), at: variant))
        let (text, start) = list.listed(from:10_000)
        XCTAssertEqual(start, 597)
        XCTAssertEqual(segments(text).first, "https://emby.example/emby/Videos/m1/hls1/main/199.ts?PlaySessionId=p1")
        XCTAssertEqual(segments(text).count, 1)
    }

    /// The loader against a made-up server: how the version opens, and
    /// each request it sent, where to and with which key.
    private func loaded(listing listed: String = "main.m3u8?MediaSourceId=m1", masterAt: URL? = nil,
                        master: URL = URL(string: "https://emby.example/emby/Videos/m1/master.m3u8?MediaSourceId=m1&api_key=test-key")!,
                        variant: [String]? = nil) async -> (opening: ConvertedPlaylist.Opening, sent: [(url: URL, key: String?)]) {
        var sent: [(url: URL, key: String?)] = []
        let masterAt = masterAt ?? master
        let opening = await ConvertedPlaylist.load(master, headers: ["X-Emby-Token: test-key"]) { request in
            guard let url = request.url else { return nil }
            sent.append((url, request.value(forHTTPHeaderField: "X-Emby-Token")))
            return url.lastPathComponent == "master.m3u8"
                ? (["#EXTM3U", "#EXT-X-STREAM-INF:BANDWIDTH=2000000", listed], masterAt) : (variant ?? emby(segments: 3), url)
        }
        return (opening, sent)
    }

    private func requests(listing listed: String, master: URL) async -> [(url: URL, key: String?)] {
        await loaded(listing: listed, master: master).sent
    }

    func testTheAccountsKeyGoesToTheServerItWasGivenFor() async {
        let sent = await loaded().sent
        XCTAssertEqual(sent.map(\.url.host), ["emby.example", "emby.example"])
        XCTAssertEqual(sent.map(\.key), ["test-key", "test-key"])
    }

    /// The player sends the key it is given with every request it makes for
    /// the version: the master, its redirect, the variant, each segment and
    /// key. One with any of them elsewhere doesn't open.
    func testAVersionWithAnAddressElsewhereDoesNotOpen() async {
        let segmentElsewhere = emby(segments: 3).map { $0.hasPrefix("hls1/main/1.ts") ? "https://cdn.example/hls1/main/1.ts" : $0 }
        var keyElsewhere = emby(segments: 3)
        keyElsewhere.insert("#EXT-X-KEY:METHOD=AES-128,URI=\"https://cdn.example/key\"", at: 5)
        let cases = [
            ("redirected", await loaded(listing: "main.m3u8?MediaSourceId=m1&api_key=test-key",
                                        masterAt: URL(string: "https://cdn.example/emby/Videos/m1/master.m3u8")!)),
            ("listed elsewhere", await loaded(listing: "https://other.example:8443/Videos/m1/main.m3u8?api_key=test-key")),
            ("a segment elsewhere", await loaded(variant: segmentElsewhere)),
            ("a key elsewhere", await loaded(variant: keyElsewhere)),
        ]
        for (name, (opening, sent)) in cases {
            if case .refused = opening {} else { XCTFail("\(name): it opens, and the player sends the key there") }
            for request in sent where request.url.host() != "emby.example" {
                XCTAssertNil(request.key, "\(name): the key in its header")
                XCTAssertFalse(request.url.absoluteString.contains("test-key"), "\(name): the key in its address")
            }
        }
    }

    func testAVersionAllOnTheGivenServerOpens() async {
        guard case let .listed(list) = await loaded().opening else { return XCTFail("not listed") }
        let hosts = segments(list.listed(from: 4).playlist).map { URL(string: $0)?.host() }
        XCTAssertEqual(hosts, [String?](repeating: "emby.example", count: 2))
        var keyed = emby(segments: 3)
        keyed.insert("#EXT-X-KEY:METHOD=AES-128,URI=\"key\"", at: 5)
        for (name, variant) in [("a key on the server", keyed), ("still growing", Array(emby(segments: 3).dropLast()))] {
            if case .whole = await loaded(variant: variant).opening {} else { XCTFail("\(name): not the server's own playlist") }
        }
    }

    /// An address with no port is on the scheme's own: 443 for https, 80 for http.
    func testAPortWrittenOutIsTheSameServer() async {
        let bare = URL(string: "https://emby.example/emby/Videos/m1/master.m3u8?MediaSourceId=m1")!
        let written = URL(string: "https://emby.example:443/emby/Videos/m1/master.m3u8?MediaSourceId=m1")!
        for (master, variant) in [(bare, "https://emby.example:443/emby/Videos/m1/main.m3u8"), (written, "https://emby.example/emby/Videos/m1/main.m3u8")] {
            let sent = await requests(listing: variant, master: master)
            XCTAssertEqual(sent.map(\.key), ["test-key", "test-key"], "\(master.port ?? 0) then \(variant)")
        }
        let plain = URL(string: "http://emby.example/x")!, plainWritten = URL(string: "http://emby.example:80/x")!
        XCTAssertTrue(HTTP.sameServer(plain, plainWritten))
        XCTAssertTrue(HTTP.sameServer(plainWritten, plain))
        for other in ["https://emby.example:8443/x", "http://emby.example:443/x", "https://emby.example/x", "http://other.example/x"] {
            XCTAssertFalse(HTTP.sameServer(plain, URL(string: other)!), other)
            XCTAssertFalse(HTTP.sameServer(URL(string: other)!, plain), other)
        }
    }

    /// The address a server redirects to is its choice, and Emby reads its
    /// query's names in any case.
    func testARedirectElsewhereCarriesTheKeyUnderNoSpelling() {
        var request = URLRequest(url: URL(string: "https://cdn.example/main.m3u8?API_KEY=test-key&Api_Key=test-key&api_key=test-key&b=1")!)
        request.setValue("test-key", forHTTPHeaderField: "x-emby-token")
        let sent = HTTP.redirected(request, from: URL(string: "https://emby.example/emby/Videos/m1/master.m3u8")!)
        XCTAssertFalse(sent.url?.absoluteString.contains("test-key") ?? true, "the key in its address")
        XCTAssertEqual(sent.url?.query(), "b=1")
        XCTAssertNil(sent.value(forHTTPHeaderField: "X-Emby-Token"), "the key in its header")
    }

    func testTheDebugCountAsksNoOtherServerWithTheKey() async {
        let master = URL(string: "https://emby.example/emby/Videos/m1/master.m3u8?MediaSourceId=m1")!
        var asked: [(host: String?, keyed: Bool)] = []
        _ = await PlaylistKeys.count(master, headers: ["X-Emby-Token: test-key"]) { url, headers in
            asked.append((url.host(), headers.contains { $0.contains("test-key") }))
            return url.lastPathComponent == "master.m3u8"
                ? "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\nmain.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=2\nhttps://cdn.example/other.m3u8\n"
                : emby(segments: 3).joined(separator: "\n")
        }
        XCTAssertEqual(asked.filter(\.keyed).map(\.host), ["emby.example", "emby.example"])
    }

    func testAPlaylistStillGrowingOrWithKeysIsLeftAsItIs() {
        XCTAssertNil(ConvertedPlaylist(Array(emby(segments: 3).dropLast()), at: variant), "still growing")
        var keyed = emby(segments: 3)
        keyed.insert("#EXT-X-KEY:METHOD=AES-128,URI=\"key\"", at: 5)
        XCTAssertNil(ConvertedPlaylist(keyed, at: variant), "a key at another address")
    }
}

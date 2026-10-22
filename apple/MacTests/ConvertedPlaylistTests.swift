import XCTest
@testable import OpenIPTV

final class ConvertedPlaylistTests: XCTestCase {
    private let master = URL(string: "https://emby.example/emby/Videos/m1/master.m3u8?MediaSourceId=m1&StartTimeTicks=3015000000")!
    private let variant = URL(string: "https://emby.example/emby/Videos/m1/main.m3u8?MediaSourceId=m1&PlaySessionId=p1")!
    private let key = ["X-Emby-Token: test-key"]

    /// Emby's: the whole film from 0:00 in 3 s segments, whatever second it
    /// was asked from.
    private func emby(segments: Int) -> [String] {
        ["#EXTM3U", "#EXT-X-PLAYLIST-TYPE:VOD", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:3", "#EXT-X-MEDIA-SEQUENCE:0"]
            + (0..<segments).flatMap { ["#EXTINF:3.000000, nodesc", "hls1/main/\($0).ts?PlaySessionId=p1"] } + ["#EXT-X-ENDLIST"]
    }

    private func listed(_ lines: [String]) throws -> ConvertedPlaylist {
        let list: ConvertedPlaylist? = if case let .listed(list) = ConvertedPlaylist.listing(lines, at: variant) { list } else { nil }
        return try XCTUnwrap(list, "not listed")
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
        let listed = try listed(emby(segments: 200)).listed(from: 301.5)
        XCTAssertEqual(listed.clockStart, 300, "the player's clock 0 isn't where its first segment starts")
        XCTAssertEqual(listed.segments.first?.absoluteString, "https://emby.example/emby/Videos/m1/hls1/main/100.ts?PlaySessionId=p1")
        XCTAssertEqual(listed.segments.count, 100)
        XCTAssertEqual(segments(listed.playlist).count, 100)
        XCTAssertTrue(listed.playlist.contains("#EXT-X-MEDIA-SEQUENCE:100\n"), listed.playlist)
        XCTAssertTrue(listed.playlist.hasSuffix("#EXT-X-ENDLIST\n"))
    }

    func testFromTheStartItIsTheWholeFilm() throws {
        let listed = try listed(emby(segments: 200)).listed(from: 0)
        XCTAssertEqual(listed.clockStart, 0)
        XCTAssertEqual(listed.segments.count, 200)
    }

    func testPastTheEndItIsTheLastSegment() throws {
        let listed = try listed(emby(segments: 200)).listed(from: 10_000)
        XCTAssertEqual(listed.clockStart, 597)
        XCTAssertEqual(listed.segments.map(\.absoluteString), ["https://emby.example/emby/Videos/m1/hls1/main/199.ts?PlaySessionId=p1"])
    }

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
        XCTAssertEqual(list.listed(from: 4).segments.map { $0.host() }, [String?](repeating: "emby.example", count: 2))
    }

    /// One the app can't list again was opened as the server's own master,
    /// and ffmpeg read addresses the app never checked: later segments and
    /// keys of a list still growing, or the last URI= of a tag, unescaped.
    func testAVersionThatCannotBeListedAgainDoesNotOpen() async {
        func tagged(_ tag: String) -> [String] {
            var list = emby(segments: 3)
            list.insert(tag, at: 5)
            return list
        }
        var unread = emby(segments: 3)
        unread[7] = "#EXTINF:three, nodesc"
        let cases = [
            ("still growing", Array(emby(segments: 3).dropLast())),
            ("a key on the server", tagged("#EXT-X-KEY:METHOD=AES-128,URI=\"key\"")),
            ("an X-URI before the URI", tagged("#EXT-X-KEY:METHOD=AES-128,X-URI=\"key\",URI=\"https://cdn.example/key\"")),
            ("an escaped address", tagged("#EXT-X-KEY:METHOD=AES-128,URI=\"\\/\\/cdn.example/key\"")),
            ("two URI=", tagged("#EXT-X-KEY:METHOD=AES-128,URI=\"key\",URI=\"https://cdn.example/key\"")),
            ("a segment unread", unread),
        ]
        for (name, variant) in cases {
            if case .refused = await loaded(variant: variant).opening {} else { XCTFail("\(name): it opens") }
        }
    }

    /// A master's tag in the variant made the list given to the player a
    /// master again, and ffmpeg read the child it names, never checked here.
    func testAVariantWithAMastersTagDoesNotOpen() async {
        func tagged(_ tags: [String]) -> [String] {
            var list = emby(segments: 3)
            list.insert(contentsOf: tags, at: 5)
            return list
        }
        let cases = [
            ("a child playlist", tagged(["#EXT-X-STREAM-INF:BANDWIDTH=2000000", "#EXTINF:3.000000, nodesc", "child.m3u8"])),
            ("a stream's tag", tagged(["#EXT-X-STREAM-INF:BANDWIDTH=2000000"])),
            ("a rendition", tagged(["#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"en\""])),
            ("session data", tagged(["#EXT-X-SESSION-DATA:DATA-ID=\"a\",VALUE=\"b\""])),
        ]
        for (name, variant) in cases {
            if case .refused = await loaded(variant: variant).opening {} else { XCTFail("\(name): it opens") }
        }
        if case .refused = await loaded().opening { XCTFail("Emby's own variant refused") }
    }

    /// The same server written in other capitals, or with the root's dot.
    func testTheSameHostInOtherCapitalsIsTheSameServer() async {
        let given = URL(string: "https://emby.example/x")!
        for same in ["https://Emby.Example/y", "HTTPS://EMBY.EXAMPLE:443/y", "https://emby.example./y"] {
            XCTAssertTrue(HTTP.sameServer(URL(string: same)!, given), same)
            XCTAssertTrue(HTTP.sameServer(given, URL(string: same)!), same)
        }
        XCTAssertFalse(HTTP.sameServer(URL(string: "https://Other.Example/y")!, given))
        let capitals = URL(string: "https://Emby.Example/emby/Videos/m1/master.m3u8?MediaSourceId=m1")!
        let (opening, sent) = await loaded(listing: "https://emby.example/emby/Videos/m1/main.m3u8", master: capitals)
        if case .refused = opening { XCTFail("refused on its own server") }
        XCTAssertEqual(sent.map(\.key), ["test-key", "test-key"])
    }

    /// With the relay not running, the version opened as the server lists it.
    func testAVersionTheRelayCannotServeDoesNotOpen() throws {
        let list = try listed(emby(segments: 200))
        XCTAssertNil(FilmStream.converted(master, list, at: 301.5, headers: key) { _, _, _ in nil }, "the server's own master")
    }

    /// Kept on closing, or back from Picture in Picture, a converted version
    /// taken for the original got a quality chooser that never went back up.
    func testAConvertedVersionIsNeverTheOriginal() throws {
        XCTAssertTrue(FilmStream.whole.isOriginal)
        let list = try listed(emby(segments: 200))
        for (second, old) in [(0.0, false), (301.5, false), (301.5, true)] {
            let opened = try XCTUnwrap(FilmStream.converted(master, list, at: second, headers: key, old: old) { _, _, _ in URL(string: "http://127.0.0.1:8/list.m3u8") })
            XCTAssertFalse(opened.stream.isOriginal, "from \(second)\(old ? ", the old way" : "")")
        }
    }

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

    /// -oldConvertedStart: the player reads the film's first segment, then
    /// jumps to the second, as it did with Emby's own master. It opened
    /// that master, and the player sent the key wherever it led.
    func testTheOldWayListsTheWholeFilmFromHere() throws {
        let list = try listed(emby(segments: 200))
        let local = URL(string: "http://127.0.0.1:8/list.m3u8")!
        var served: [ConvertedPlaylist.Listed] = []
        let opened = try XCTUnwrap(FilmStream.converted(master, list, at: 301.5, headers: key, old: true) { listed, _, _ in served.append(listed); return local })
        XCTAssertEqual(opened.address, local, "not served from here")
        XCTAssertEqual(opened.start, 301.5)
        XCTAssertEqual(opened.stream.clockStart, 0)
        XCTAssertEqual(served.map { $0.segments.first?.absoluteString }, ["https://emby.example/emby/Videos/m1/hls1/main/0.ts?PlaySessionId=p1"])
        XCTAssertEqual(served.map(\.segments.count), [200])
    }

    /// On the server it was given for too, the key leaves the address under
    /// any spelling: the system logs the address of a request that fails.
    func testTheKeyMovesToTheHeaderUnderAnySpelling() {
        for name in ["api_key", "API_KEY", "Api_Key"] {
            let given = URL(string: "https://emby.example/emby/Videos/m1/master.m3u8?\(name)=test-key&b=1")!
            let moved = HTTP.keyInHeader(URLRequest(url: given))
            XCTAssertEqual(moved.url?.query(), "b=1", name)
            XCTAssertEqual(moved.value(forHTTPHeaderField: "X-Emby-Token"), "test-key", name)
            let redirect = URLRequest(url: URL(string: "https://emby.example/emby/Videos/m1/main.m3u8?\(name)=test-key")!)
            let followed = HTTP.redirected(redirect, from: given)
            XCTAssertNil(followed.url?.query(), name)
            XCTAssertEqual(followed.value(forHTTPHeaderField: "X-Emby-Token"), "test-key", name)
        }
    }

    /// A name with no value first: the key under the same name after it
    /// stayed in the address.
    func testEveryKeyNameLeavesTheAddress() {
        for query in ["API_KEY&api_key=test-key&b=1", "api_key=&Api_Key=test-key&b=1", "b=1&API_KEY"] {
            let moved = HTTP.keyInHeader(URLRequest(url: URL(string: "https://emby.example/emby/Videos/m1/master.m3u8?\(query)")!))
            XCTAssertEqual(moved.url?.query(), "b=1", query)
            XCTAssertEqual(moved.value(forHTTPHeaderField: "X-Emby-Token"), query.contains("test-key") ? "test-key" : nil, query)
        }
    }

    /// Debug builds count the film's redirects, and those to another
    /// server, for the real server's runner.
    func testTheRelayCountsTheFilmsRedirects() {
        let task = URLSession.shared.dataTask(with: URL(string: "https://emby.example/emby/Videos/m1/stream.mkv?static=true")!)
        var same = URLRequest(url: URL(string: "https://emby.example/emby/Videos/m1/stream.mkv?static=true&again=1")!)
        same.setValue("test-key", forHTTPHeaderField: "X-Emby-Token")
        var away = URLRequest(url: URL(string: "https://cdn.example/m1.mkv")!)
        away.setValue("test-key", forHTTPHeaderField: "X-Emby-Token")
        let before = StreamRelay.redirects.value
        XCTAssertEqual(StreamRelay.redirected(same, for: task).value(forHTTPHeaderField: "X-Emby-Token"), "test-key")
        XCTAssertNil(StreamRelay.redirected(away, for: task).value(forHTTPHeaderField: "X-Emby-Token"))
        let after = StreamRelay.redirects.value
        XCTAssertEqual(after.redirected - before.redirected, 2, "redirected")
        XCTAssertEqual(after.elsewhere - before.elsewhere, 1, "elsewhere")
    }

    /// The player follows a segment's redirect with the key: the count asks
    /// the segments it asks first, and follows none.
    func testTheConvertedCountAsksTheFirstSegmentsListed() async throws {
        let list = try listed(emby(segments: 200))
        let answers: [String: (status: Int, location: String?)] = [
            "100.ts": (302, "https://emby.example/emby/Videos/m1/hls1/main/100.ts?again=1"),
            "101.ts": (302, "https://cdn.example/101.ts"),
            "102.ts": (200, nil),
        ]
        var asked: [URL] = []
        let found = await ConvertedPlaylist.countRedirects(list, from: 301.5, headers: ["X-Emby-Token: test-key"], given: master) { request in
            guard let url = request.url, let answer = answers[url.lastPathComponent] else { return nil }
            asked.append(url)
            return HTTPURLResponse(url: url, statusCode: answer.status, httpVersion: "HTTP/1.1", headerFields: answer.location.map { ["Location": $0] })
        }
        XCTAssertEqual(asked.map(\.lastPathComponent), ["100.ts", "101.ts", "102.ts"], "not the segments the player asks first")
        XCTAssertEqual(found.asked, 3)
        XCTAssertEqual(found.count.redirected, 2, "redirected")
        XCTAssertEqual(found.count.elsewhere, 1, "elsewhere")
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
}

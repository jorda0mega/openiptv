import XCTest

/// The server's subtitle files kept on the device (ServerSubtitles): known
/// by the track, never by the key, with one owner of the folder that a
/// sign-out or launch pruning cannot race.
final class ServerSubtitlesTests: XCTestCase {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "server-subtitles-\(UUID().uuidString)")
    private let perPlay = FileManager.default.temporaryDirectory.appending(path: "subtitles-\(UUID().uuidString)")
    private let launched = Date(timeIntervalSince1970: 1_800_000_000)

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: perPlay)
        super.tearDown()
    }

    private func track(key: String = "secretkey", host: String = "emby.example", version: String = "800|mkv|subrip",
                       format: String = "srt") -> ServerSubtitle {
        ServerSubtitle(address: URL(string: "http://\(host):8096/emby/Videos/i1/ms-i1/Subtitles/3/Stream.\(format)")!, token: key,
                       kind: .inFile, version: version)
    }

    private func write(_ file: URL, bytes: Int = 10, made: Date, used: Date? = nil) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 65, count: bytes).write(to: file)
        try FileManager.default.setAttributes([.creationDate: made, .modificationDate: used ?? made], ofItemAtPath: file.path)
    }

    private func exists(_ file: URL) -> Bool { FileManager.default.fileExists(atPath: file.path) }

    private var store: SubtitleStore { SubtitleStore(folder: folder, perPlay: perPlay) }

    func testTheSameTrackAskedWithAnotherKeyIsTheSame() {
        XCTAssertEqual(track(key: "one"), track(key: "two"))
        XCTAssertEqual(track(key: "one").hashValue, track(key: "two").hashValue)
        XCTAssertNotEqual(track(), track(version: "900|mkv|subrip"))
        XCTAssertNotEqual(track(), track(host: "other.example"))
    }

    func testOneTrackAskedInTwoFormatsIsOneTrack() {
        XCTAssertEqual(track(format: "ass"), track(format: "srt"))
        XCTAssertEqual(track(format: "ass").hashValue, track(format: "srt").hashValue)
    }

    func testRequestSendsTheKeyOnlyInAHeader() throws {
        let request = ServerSubtitles.request(for: track())
        let address = try XCTUnwrap(request.url)
        XCTAssertFalse(address.absoluteString.contains("secretkey"))
        XCTAssertNil(URLComponents(url: address, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Emby-Token"), "secretkey")
    }

    func testARedirectKeepsTheKeyOutOfTheAddress() {
        var redirect = URLRequest(url: URL(string: "http://emby.example/emby/Videos/i1/ms-i1/Subtitles/3/Stream.srt?redirected=1&api_key=secretkey")!)
        redirect.setValue("bytes=0-", forHTTPHeaderField: "Range")
        let moved = HTTP.keyInHeader(redirect)
        XCTAssertEqual(moved.url?.absoluteString, "http://emby.example/emby/Videos/i1/ms-i1/Subtitles/3/Stream.srt?redirected=1")
        XCTAssertEqual(moved.value(forHTTPHeaderField: "X-Emby-Token"), "secretkey")
        XCTAssertEqual(moved.value(forHTTPHeaderField: "Range"), "bytes=0-")
    }

    func testARedirectToAnotherServerGetsNoKey() async throws {
        let original = URL(string: "http://emby.example:8096/emby/Videos/i1/ms-i1/Subtitles/3/Stream.srt")!
        var redirect = URLRequest(url: URL(string: "https://elsewhere.example/Stream.srt?api_key=secretkey&a=1")!)
        redirect.setValue("secretkey", forHTTPHeaderField: "X-Emby-Token")
        let task = URLSession.shared.dataTask(with: original)
        let response = HTTPURLResponse(url: original, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil)!
        let followed = await HTTP.keyOutOfRedirects.urlSession(URLSession.shared, task: task, willPerformHTTPRedirection: response,
                                                                newRequest: redirect)
        XCTAssertNil(followed?.value(forHTTPHeaderField: "X-Emby-Token"))
        XCTAssertEqual(followed?.url?.absoluteString, "https://elsewhere.example/Stream.srt?a=1")
    }

    func testATrackIsNeverPrintedWithItsKey() {
        var dumped = ""
        dump(track(), to: &dumped)
        for printed in ["\(track())", String(reflecting: track()), dumped] {
            XCTAssertFalse(printed.contains("secretkey"), "printed with its key")
        }
    }

    func testFileNameHoldsNoAddressOrKey() {
        let file = ServerSubtitles.file(for: track(), in: folder)
        XCTAssertEqual(file.pathExtension, "srt")
        for part in ["secretkey", "api_key", "emby.example", "Videos", "Subtitles", "ms-i1"] {
            XCTAssertFalse(file.lastPathComponent.contains(part), "the file name holds \(part)")
        }
        XCTAssertEqual(ServerSubtitles.file(for: track(key: "other"), in: folder), file)
        XCTAssertNotEqual(ServerSubtitles.file(for: track(version: "900|mkv|subrip"), in: folder), file)
    }

    func testADownloadThatEndsAfterASignOutLeavesNoFile() async throws {
        let store = store, file = ServerSubtitles.file(for: track(), in: folder)
        let began = await store.generation
        await store.removeAll()
        let published = try await store.publish(Data("1\n00:00:01,000 --> 00:00:02,000\nHi\n".utf8), as: file, since: began)
        XCTAssertFalse(published)
        XCTAssertFalse(exists(file))
        XCTAssertFalse(exists(folder.appending(path: "staging")))
    }

    func testADownloadIsPublishedWhole() async throws {
        let store = store, file = ServerSubtitles.file(for: track(), in: folder)
        let published = try await store.publish(Data("subtitles".utf8), as: file, since: await store.generation)
        XCTAssertTrue(published)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "subtitles")
    }

    func testSignOutRemovesThePlayersOwnFilesToo() async throws {
        try write(perPlay.appending(path: "rewritten.srt"), made: launched)
        try write(folder.appending(path: "in-file/a.srt"), made: launched)
        await store.removeAll()
        XCTAssertFalse(exists(perPlay.appending(path: "rewritten.srt")))
        XCTAssertFalse(exists(folder))
    }

    func testRewritingFindsItsFolderEvenWhenItIsGone() throws {
        try? FileManager.default.removeItem(at: perPlay)
        let file = ServerSubtitles.perPlayFile("srt", in: perPlay)
        XCTAssertNoThrow(try Data("1".utf8).write(to: file))
    }

    func testLaunchRemovesFilesPastTheirLifetime() async throws {
        let besideNew = folder.appending(path: "beside/a.srt"), besideOld = folder.appending(path: "beside/b.srt")
        let copyNew = folder.appending(path: "in-file/c.srt"), copyOld = folder.appending(path: "in-file/d.srt")
        try write(besideNew, made: launched - 30 * 60)
        try write(besideOld, made: launched - 2 * 3600, used: launched - 60)
        try write(copyNew, made: launched - 10 * 86_400)
        try write(copyOld, made: launched - 31 * 86_400)
        await store.prune(launchedAt: launched)
        XCTAssertTrue(exists(besideNew))
        XCTAssertFalse(exists(besideOld))
        XCTAssertTrue(exists(copyNew))
        XCTAssertFalse(exists(copyOld))
    }

    func testLaunchKeepsTheLastUsedUnderTheCap() async throws {
        let usedLately = folder.appending(path: "in-file/a.srt"), unused = folder.appending(path: "beside/b.srt")
        let newest = folder.appending(path: "in-file/c.srt")
        let now = Date()
        try write(usedLately, bytes: 400, made: now - 3000)
        try write(unused, bytes: 400, made: now - 2000)
        try write(newest, bytes: 400, made: now - 1000)
        let store = store
        await store.touch(usedLately)
        await store.prune(launchedAt: now + 1, cap: 1000)
        XCTAssertTrue(exists(usedLately))
        XCTAssertFalse(exists(unused))
        XCTAssertTrue(exists(newest))
    }

    func testLaunchRemovesThePerPlayFilesOfEarlierLaunches() async throws {
        let earlier = perPlay.appending(path: "\(UUID().uuidString).srt"), now = perPlay.appending(path: "\(UUID().uuidString).srt")
        try write(earlier, made: launched - 86_400)
        try write(now, made: launched + 1)
        await store.prune(launchedAt: launched)
        XCTAssertFalse(exists(earlier))
        XCTAssertTrue(exists(now))
    }

    func testAPlaylistIsFetchedWithoutTheKeyInItsAddress() throws {
        let variant = try XCTUnwrap(PlaylistKeys.keyless(URL(string: "http://emby.example/emby/videos/i1/main.m3u8?DeviceId=d&api_key=secretkey&API_KEY=other")!))
        XCTAssertEqual(variant.absoluteString, "http://emby.example/emby/videos/i1/main.m3u8?DeviceId=d")
    }

    func testRetriesOnlyWhatIsWorthAnotherTry() {
        XCTAssertTrue(ServerSubtitles.worthRetrying(SourceError.http(503)))
        XCTAssertTrue(ServerSubtitles.worthRetrying(SourceError.network("The server took too long to answer.")))
        XCTAssertFalse(ServerSubtitles.worthRetrying(SourceError.http(404)))
        XCTAssertFalse(ServerSubtitles.worthRetrying(SourceError.rejected))
        XCTAssertFalse(ServerSubtitles.worthRetrying(CancellationError()))
    }
}

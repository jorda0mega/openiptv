import XCTest

/// The server's subtitle files kept on the device (ServerSubtitles): known
/// by where they live on the server, never by their address (it carries the
/// key), and cleaned up at launch.
final class ServerSubtitlesTests: XCTestCase {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "server-subtitles-\(UUID().uuidString)")
    private let perPlay = FileManager.default.temporaryDirectory.appending(path: "subtitles-\(UUID().uuidString)")
    private let launched = Date(timeIntervalSince1970: 1_800_000_000)

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: perPlay)
        super.tearDown()
    }

    private func track(key: String = "secretkey", host: String = "emby.example", version: String = "800|mkv|subrip") -> ServerSubtitle {
        ServerSubtitle(address: URL(string: "http://\(host):8096/emby/Videos/i1/ms-i1/Subtitles/3/Stream.srt")!, token: key,
                       kind: .inFile, version: version)
    }

    private func write(_ file: URL, bytes: Int = 10, at date: Date) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 65, count: bytes).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
    }

    private func exists(_ file: URL) -> Bool { FileManager.default.fileExists(atPath: file.path) }

    func testTheSameTrackAskedWithAnotherKeyIsTheSame() {
        XCTAssertEqual(track(key: "one"), track(key: "two"))
        XCTAssertEqual(track(key: "one").hashValue, track(key: "two").hashValue)
        XCTAssertNotEqual(track(), track(version: "900|mkv|subrip"))
        XCTAssertNotEqual(track(), track(host: "other.example"))
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

    func testLaunchRemovesFilesPastTheirLifetime() throws {
        let besideNew = folder.appending(path: "beside/a.srt"), besideOld = folder.appending(path: "beside/b.srt")
        let copyNew = folder.appending(path: "in-file/c.srt"), copyOld = folder.appending(path: "in-file/d.srt")
        try write(besideNew, at: launched - 30 * 60)
        try write(besideOld, at: launched - 2 * 3600)
        try write(copyNew, at: launched - 10 * 86_400)
        try write(copyOld, at: launched - 31 * 86_400)
        ServerSubtitles.prune(folder, perPlay: perPlay, launchedAt: launched)
        XCTAssertTrue(exists(besideNew))
        XCTAssertFalse(exists(besideOld))
        XCTAssertTrue(exists(copyNew))
        XCTAssertFalse(exists(copyOld))
    }

    func testLaunchKeepsTheNewestUnderTheCap() throws {
        let oldest = folder.appending(path: "in-file/a.srt"), older = folder.appending(path: "beside/b.srt")
        let newest = folder.appending(path: "in-file/c.srt")
        try write(oldest, bytes: 400, at: launched - 3000)
        try write(older, bytes: 400, at: launched - 2000)
        try write(newest, bytes: 400, at: launched - 1000)
        ServerSubtitles.prune(folder, perPlay: perPlay, launchedAt: launched, cap: 1000)
        XCTAssertFalse(exists(oldest))
        XCTAssertTrue(exists(older))
        XCTAssertTrue(exists(newest))
    }

    func testLaunchRemovesThePerPlayFilesOfEarlierLaunches() throws {
        let earlier = perPlay.appending(path: "\(UUID().uuidString).srt"), now = perPlay.appending(path: "\(UUID().uuidString).srt")
        try write(earlier, at: launched - 86_400)
        try write(now, at: launched + 1)
        ServerSubtitles.prune(folder, perPlay: perPlay, launchedAt: launched)
        XCTAssertFalse(exists(earlier))
        XCTAssertTrue(exists(now))
    }
}

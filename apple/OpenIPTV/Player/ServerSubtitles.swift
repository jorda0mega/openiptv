import CryptoKit
import Foundation

/// A subtitle track the server serves, known by where it lives on the
/// server and its version, never by its address: the address carries the
/// key, so it is never logged, hashed into a name or kept.
struct ServerSubtitle: Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        /// The server may replace it at the same address.
        case beside
        /// Emby reads the whole film to take it out (over a minute for Asterix the Gaul).
        case inFile

        var lifetime: Duration { self == .beside ? .seconds(3600) : .seconds(30 * 86_400) }

        fileprivate var folder: String { self == .beside ? "beside" : "in-file" }
    }

    let address: URL
    let kind: Kind
    let version: String

    fileprivate var place: String { "\(address.host() ?? ""):\(address.port ?? 0)\(address.path())#\(version)" }

    static func == (a: ServerSubtitle, b: ServerSubtitle) -> Bool { a.place == b.place }
    func hash(into hasher: inout Hasher) { hasher.combine(place) }
}

extension Lane {
    static let embyFiles = Lane(.files, atOnce: 2, conditions: Conditions.current)
    static let embyExtraction = Lane(.heavy, atOnce: 1, bucket: Bucket(size: 6, refillEvery: .seconds(600), reserve: 0),
                                     conditions: Conditions.current)
}

@MainActor
enum ServerSubtitles {
    nonisolated static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "server-subtitles")
    nonisolated static let perPlay = FileManager.default.temporaryDirectory.appending(path: "subtitles")

    static let beside = Shelf(.init(lane: .embyFiles, lifetime: ServerSubtitle.Kind.beside.lifetime), disk: disk(.beside)) {
        try await download($0, on: HTTP.session)
    }

    static let inFile = Shelf(.init(lane: .embyExtraction, lifetime: ServerSubtitle.Kind.inFile.lifetime, onLeave: .cancel,
                                    retries: retryWaits, failureKept: .seconds(600)), disk: disk(.inFile)) {
        try await download($0, on: HTTP.patient)
    }

    private static var retryWaits: [Duration] {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "quickSubtitleRetries") { return [.seconds(1), .seconds(2)] }
        #endif
        return [.seconds(15), .seconds(60)]
    }

    static func local(_ subtitle: ServerSubtitle) async -> URL? {
        try? await (subtitle.kind == .beside ? beside : inFile).value(for: subtitle)
    }

    static func forgetAll() {
        beside.forgetAll()
        inFile.forgetAll()
    }

    nonisolated static func atLaunch() {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "forgetServerSubtitles") { try? FileManager.default.removeItem(at: folder) }
        #endif
        let launched = Date()
        Task.detached(priority: .background) { prune(launchedAt: launched) }
    }

    nonisolated static func file(for subtitle: ServerSubtitle, in folder: URL = folder) -> URL {
        let name = SHA256.hash(data: Data(subtitle.place.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let format = subtitle.address.pathExtension.isEmpty ? "srt" : subtitle.address.pathExtension
        return folder.appending(path: subtitle.kind.folder).appending(path: "\(name).\(format)")
    }

    nonisolated static func prune(_ folder: URL = folder, perPlay: URL = perPlay, launchedAt: Date, cap: Int = 64 << 20) {
        let manager = FileManager.default
        func files(in folder: URL) -> [(url: URL, at: Date, size: Int)] {
            let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
            return ((try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []).map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return (url, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0)
            }
        }
        for file in files(in: perPlay) where file.at < launchedAt { try? manager.removeItem(at: file.url) }
        var kept: [(url: URL, at: Date, size: Int)] = []
        for kind in [ServerSubtitle.Kind.beside, .inFile] {
            for file in files(in: folder.appending(path: kind.folder)) {
                if launchedAt.timeIntervalSince(file.at) > kind.lifetime / .seconds(1) {
                    try? manager.removeItem(at: file.url)
                } else {
                    kept.append(file)
                }
            }
        }
        var total = kept.reduce(0) { $0 + $1.size }
        for file in kept.sorted(by: { $0.at < $1.at }) where total > cap {
            try? manager.removeItem(at: file.url)
            total -= file.size
        }
    }

    private nonisolated static func disk(_ kind: ServerSubtitle.Kind) -> Shelf<ServerSubtitle, URL>.Disk {
        Shelf.Disk(find: { subtitle in
            let file = file(for: subtitle)
            return (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate.map { (file, $0) }
        }, removeAll: {
            try? FileManager.default.removeItem(at: folder.appending(path: kind.folder))
        })
    }

    private nonisolated static func download(_ subtitle: ServerSubtitle, on session: URLSession) async throws -> URL {
        do {
            let (data, response) = try await session.data(for: HTTP.keyInHeader(subtitle.address))
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw SourceError.http(code) }
            guard !data.isEmpty else { throw SourceError.unexpected("The server's answer was empty.") }
            let file = file(for: subtitle)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            throw SourceError.wrap(error)
        }
    }
}

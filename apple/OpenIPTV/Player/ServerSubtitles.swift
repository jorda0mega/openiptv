import CryptoKit
import Foundation

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
    let token: String
    let kind: Kind
    let version: String

    var id: String {
        "\(address.host() ?? ""):\(address.port ?? 0)\(address.deletingPathExtension().path())#\(version)"
    }

    static func == (a: ServerSubtitle, b: ServerSubtitle) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension ServerSubtitle: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    var description: String { "server subtitle" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["kind": kind]) }
}

extension Lane {
    static let embyFiles = Lane(.files, atOnce: 2, conditions: Conditions.current)
    static let embyExtraction = Lane(.heavy, atOnce: 1, bucket: Bucket(size: 6, refillEvery: .seconds(600), reserve: 0),
                                     conditions: Conditions.current)
}

actor SubtitleStore {
    let folder: URL
    let perPlay: URL
    private(set) var generation = 0

    init(folder: URL, perPlay: URL) {
        self.folder = folder
        self.perPlay = perPlay
    }

    func publish(_ data: Data, as file: URL, since generation: Int) throws -> Bool {
        guard generation == self.generation else { return false }
        let manager = FileManager.default
        let staging = folder.appending(path: "staging")
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        let written = staging.appending(path: UUID().uuidString)
        try data.write(to: written)
        try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? manager.removeItem(at: file)
        try manager.moveItem(at: written, to: file)
        return true
    }

    func touch(_ file: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
    }

    func removeAll() {
        generation += 1
        try? FileManager.default.removeItem(at: folder)
        for file in (try? FileManager.default.contentsOfDirectory(at: perPlay, includingPropertiesForKeys: nil)) ?? [] {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func prune(launchedAt: Date, cap: Int = 64 << 20) {
        let manager = FileManager.default
        func files(in folder: URL) -> [(url: URL, downloadedAt: Date, lastUsedAt: Date, size: Int)] {
            let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .fileSizeKey]
            return ((try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []).map { url in
                let values = try? url.resourceValues(forKeys: Set(keys))
                let lastUsedAt = values?.contentModificationDate ?? .distantPast
                return (url, values?.creationDate ?? lastUsedAt, lastUsedAt, values?.fileSize ?? 0)
            }
        }
        for file in files(in: perPlay) where file.lastUsedAt < launchedAt { try? manager.removeItem(at: file.url) }
        try? manager.removeItem(at: folder.appending(path: "staging"))
        var kept: [(url: URL, downloadedAt: Date, lastUsedAt: Date, size: Int)] = []
        for kind in [ServerSubtitle.Kind.beside, .inFile] {
            for file in files(in: folder.appending(path: kind.folder)) {
                if launchedAt.timeIntervalSince(file.downloadedAt) > kind.lifetime / .seconds(1) {
                    try? manager.removeItem(at: file.url)
                } else {
                    kept.append(file)
                }
            }
        }
        var total = kept.reduce(0) { $0 + $1.size }
        for file in kept.sorted(by: { $0.lastUsedAt < $1.lastUsedAt }) where total > cap {
            try? manager.removeItem(at: file.url)
            total -= file.size
        }
    }
}

@MainActor
enum ServerSubtitles {
    nonisolated static let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appending(path: "server-subtitles")
    nonisolated static let perPlay = FileManager.default.temporaryDirectory.appending(path: "subtitles")
    nonisolated static let store = SubtitleStore(folder: folder, perPlay: perPlay)

    static let beside = Shelf(.init(lane: .embyFiles, lifetime: ServerSubtitle.Kind.beside.lifetime, failureKept: .seconds(60),
                                    stillThere: present), disk: disk) {
        try await download($0, on: HTTP.session)
    }

    static let inFile = Shelf(.init(lane: .embyExtraction, lifetime: ServerSubtitle.Kind.inFile.lifetime, whenUnused: .cancel,
                                    retries: retryWaits, retryable: worthRetrying, failureKept: .seconds(600), stillThere: present),
                              disk: disk) {
        try await download($0, on: HTTP.extraction)
    }

    private static var retryWaits: [Duration] {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "quickSubtitleRetries") { return [.seconds(1), .seconds(2)] }
        #endif
        return [.seconds(15), .seconds(60)]
    }

    static func local(_ subtitle: ServerSubtitle) async -> URL? {
        guard let file = try? await shelf(subtitle.kind).value(for: subtitle) else { return nil }
        Task.detached { await store.touch(file) }
        return file
    }

    static func warm(_ subtitle: ServerSubtitle, for interest: Interest) async {
        _ = await shelf(subtitle.kind).warm(subtitle, for: interest)
    }

    static func forgetAll() async {
        beside.forgetAll()
        inFile.forgetAll()
        await store.removeAll()
    }

    private static func shelf(_ kind: ServerSubtitle.Kind) -> Shelf<ServerSubtitle, URL> {
        kind == .beside ? beside : inFile
    }

    nonisolated static func atLaunch() {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "forgetServerSubtitles") { try? FileManager.default.removeItem(at: folder) }
        #endif
        let launched = Date()
        Task.detached(priority: .background) { await store.prune(launchedAt: launched) }
    }

    nonisolated static func request(for subtitle: ServerSubtitle) -> URLRequest {
        var request = URLRequest(url: subtitle.address)
        request.setValue(subtitle.token, forHTTPHeaderField: "X-Emby-Token")
        return request
    }

    nonisolated static func file(for subtitle: ServerSubtitle, in folder: URL = folder) -> URL {
        let name = SHA256.hash(data: Data(subtitle.id.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        let format = subtitle.address.pathExtension.isEmpty ? "srt" : subtitle.address.pathExtension
        return folder.appending(path: subtitle.kind.folder).appending(path: "\(name).\(format)")
    }

    nonisolated static func perPlayFile(_ format: String, in folder: URL = perPlay) -> URL {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appending(path: "\(UUID().uuidString).\(format)")
    }

    nonisolated static func worthRetrying(_ error: Error) -> Bool {
        switch error as? SourceError {
        case let .http(code)?: code >= 500
        case .network?: true
        default: false
        }
    }

    private static func present(_ file: URL) -> Bool {
        FileManager.default.fileExists(atPath: file.path)
    }

    private nonisolated static let disk: Shelf<ServerSubtitle, URL>.Disk = { subtitle in
        let file = file(for: subtitle)
        return (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate.map { (file, $0) }
    }

    private nonisolated static func download(_ subtitle: ServerSubtitle, on session: URLSession) async throws -> URL {
        let generation = await store.generation
        do {
            let (data, response) = try await session.data(for: request(for: subtitle), delegate: HTTP.keyOutOfRedirects)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else { throw SourceError.http(code) }
            guard !data.isEmpty else { throw SourceError.unexpected("The server's answer was empty.") }
            let file = file(for: subtitle)
            guard try await store.publish(data, as: file, since: generation) else { throw CancellationError() }
            return file
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw SourceError.wrap(error)
        }
    }
}

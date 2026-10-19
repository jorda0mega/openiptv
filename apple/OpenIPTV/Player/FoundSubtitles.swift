import Foundation

/// The subtitle files found for a film by the server's providers
/// (AppModel.findMissingSubtitles), kept on this device: each file, the
/// provider's id for it, and the one that fitted the film best once the
/// player had matched them.
struct FoundSubtitles: Codable {
    struct File: Codable {
        /// Its name in the film's folder ("0.srt": likeliest first).
        let name: String
        let id: String
        /// "eng" or "spa".
        let language: String
    }

    var files: [File]
    var picked: String?

    /// The most read through the server for one film: each counts against
    /// the daily downloads of the server's account with the provider.
    static let tried = 3

    static func folder(_ itemId: String) -> URL {
        AppCache.directory.appending(path: "found-subtitles").appending(path: itemId.replacingOccurrences(of: "/", with: "_"))
    }

    static func read(_ folder: URL) -> FoundSubtitles? {
        guard let data = try? Data(contentsOf: folder.appending(path: "found.json")),
              let found = try? JSONDecoder().decode(FoundSubtitles.self, from: data), !found.files.isEmpty else { return nil }
        return found
    }

    func write(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) { try? data.write(to: folder.appending(path: "found.json"), options: .atomic) }
    }

    /// For the player: the one picked, else all, likeliest first.
    func subtitleFiles(in folder: URL) -> [EmbyPlayback.SubtitleFile] {
        files.filter { picked == nil || $0.name == picked }
            .filter { FileManager.default.fileExists(atPath: folder.appending(path: $0.name).path) }
            .map { .init(source: .device(folder.appending(path: $0.name)), language: $0.language, title: "") }
    }
}

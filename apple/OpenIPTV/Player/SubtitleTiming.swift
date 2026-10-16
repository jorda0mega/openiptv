import Foundation

/// Where each subtitle file's lines go (SubtitleSync.Match), remembered on
/// this device by the file's address on the server (its path: no key), so
/// a film played again shows them in time from the first line instead of
/// once its speech has been heard again.
enum SubtitleTiming {
    private static let storeKey = "subtitleTimings"
    /// The most files remembered; the oldest go first.
    private static let kept = 300

    private struct Saved: Codable {
        let match: SubtitleSync.Match
        let at: Date
    }

    static func remembered(_ file: URL) -> SubtitleSync.Match? {
        #if DEBUG
        // UI tests: `-forgetSubtitleTimings YES` works each file out again.
        if UserDefaults.standard.bool(forKey: "forgetSubtitleTimings") { return nil }
        #endif
        return saved()[name(file)]?.match
    }

    static func remember(_ match: SubtitleSync.Match, for file: URL) {
        var all = saved()
        all[name(file)] = Saved(match: match, at: Date())
        if all.count > kept {
            for (old, _) in all.sorted(by: { $0.value.at < $1.value.at }).prefix(all.count - kept) { all[old] = nil }
        }
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: storeKey) }
    }

    private static func saved() -> [String: Saved] {
        UserDefaults.standard.data(forKey: storeKey).flatMap { try? JSONDecoder().decode([String: Saved].self, from: $0) } ?? [:]
    }

    /// "server/emby/Videos/1/ms/Subtitles/4/Stream.srt": the same file on
    /// every play, without the key in the address's query.
    private static func name(_ file: URL) -> String {
        (file.host() ?? "") + file.path()
    }
}

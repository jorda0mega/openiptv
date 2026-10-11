import Foundation
import Observation

/// Instant on-device search, fast enough to run on every keystroke.
///
/// Names are folded once (case, accents and punctuation removed) into byte
/// strings. A query matches when each of its words starts a word in the name
/// ("for fil" finds "Forensic Files"); a looser pass ignores spaces so
/// "spiderman" still finds "Spider-Man". Typing more letters re-checks only
/// the previous matches.
struct SearchCorpus<Item>: @unchecked Sendable {
    let items: [Item]
    /// " word word": a leading space so a word start is " " + prefix.
    private let keys: [[UInt8]]
    /// The same without spaces, for the loose pass.
    private let compact: [[UInt8]]

    init(_ items: [Item] = [], name: (Item) -> String) {
        self.items = items
        keys = items.map { Self.fold(name($0)) }
        compact = keys.map { $0.filter { $0 != 32 } }
    }

    struct Match {
        /// Query this match set answers, folded.
        let query: [UInt8]
        /// Every matching index, best first.
        let ranked: [Int]
        /// Size of the corpus it came from (a rebuilt corpus can't be refined).
        let size: Int
    }

    /// Ranked matches for `query`. Pass the previous match when the user has
    /// only typed more letters, so just those items are re-checked.
    func search(_ query: String, refining previous: Match? = nil) -> Match {
        let q = Self.fold(query)
        guard q.count > 1 else { return Match(query: q, ranked: [], size: items.count) }
        let words = q.split(separator: 32, omittingEmptySubsequences: true).map { [32] + Array($0) }
        let loose = q.filter { $0 != 32 }

        let candidates: [Int]
        if let previous, previous.size == items.count, previous.query.count > 1, q.starts(with: previous.query) {
            candidates = previous.ranked
        } else {
            candidates = Array(items.indices)
        }

        var scored: [(index: Int, score: Int)] = []
        scored.reserveCapacity(min(candidates.count, 4096))
        for index in candidates {
            let key = keys[index]
            var score: Int
            if words.allSatisfy({ Self.contains(key, $0) }) {
                score = 1000
                if key.starts(with: q) { score += key.count == q.count ? 3000 : 2000 }
            } else if Self.contains(compact[index], loose) {
                score = 200
            } else {
                continue
            }
            // Closer matches (shorter names) first.
            score -= min(key.count, 120)
            scored.append((index, score))
        }
        // Stable: equal scores keep the corpus order (sorted by name).
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return Match(query: q, ranked: scored.map(\.index), size: items.count)
    }

    /// Lowercase, accent-free words separated by single spaces, with a
    /// leading space. Apostrophes join ("Grey's" → "greys").
    static func fold(_ text: String) -> [UInt8] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var out: [UInt8] = [32]
        out.reserveCapacity(folded.utf8.count + 1)
        var pendingSpace = false
        for scalar in folded.unicodeScalars {
            if scalar == "'" || scalar == "\u{2019}" { continue }
            if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                if pendingSpace, out.count > 1 { out.append(32) }
                pendingSpace = false
                out.append(contentsOf: String(scalar).utf8)
            } else {
                pendingSpace = true
            }
        }
        return out
    }

    @inline(__always)
    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        let n = needle.count, h = haystack.count
        guard n > 0, n <= h else { return n == 0 }
        return haystack.withUnsafeBufferPointer { hay in
            needle.withUnsafeBufferPointer { nee in
                let first = nee[0]
                var i = 0
                while i <= h - n {
                    if hay[i] == first {
                        var j = 1
                        while j < n, hay[i + j] == nee[j] { j += 1 }
                        if j == n { return true }
                    }
                    i += 1
                }
                return false
            }
        }
    }
}

/// One movie or show in the on-device index. Display data only.
struct LibraryEntry: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String
    let kind: String
    let year: Int?
    let imageTag: String?
    let aspect: Double?
}

/// Every movie and show on the Emby server, cached on the device so search
/// doesn't wait for the network. Refreshed in the background.
@Observable
@MainActor
final class LibraryIndex {
    private(set) var corpus = SearchCorpus<LibraryEntry>(name: \.name)
    private(set) var indexing = false
    private var fetchedAt: Date?
    private var server: String?

    private struct Cache: Codable {
        let server: String
        let fetchedAt: Date
        let entries: [LibraryEntry]
    }

    private nonisolated static let file = "library-index.json"
    private nonisolated static let maxAge: TimeInterval = 6 * 3600

    var count: Int { corpus.items.count }

    /// Loads the cached index for this server (if any), then refreshes it
    /// in the background when it's missing or old.
    func prepare(_ emby: EmbyClient) async {
        let server = emby.account.serverURL.absoluteString + "|" + emby.account.userId
        if self.server != server {
            self.server = server
            if let cache = await Self.readCache(), cache.server == server {
                corpus = await Self.build(cache.entries)
                fetchedAt = cache.fetchedAt
            } else {
                corpus = SearchCorpus(name: \.name)
                fetchedAt = nil
            }
        }
        guard !indexing, fetchedAt.map({ Date().timeIntervalSince($0) > Self.maxAge }) ?? true else { return }
        indexing = true
        defer { indexing = false }
        guard let entries = try? await emby.libraryIndex(), self.server == server else { return }
        corpus = await Self.build(entries)
        fetchedAt = Date()
        let cache = Cache(server: server, fetchedAt: fetchedAt!, entries: entries)
        Task.detached(priority: .utility) { AppCache.write(Self.file, cache) }
    }

    func clear() {
        corpus = SearchCorpus(name: \.name)
        fetchedAt = nil
        server = nil
        AppCache.remove(Self.file)
    }

    private nonisolated static func build(_ entries: [LibraryEntry]) async -> SearchCorpus<LibraryEntry> {
        await Task.detached(priority: .userInitiated) { SearchCorpus(entries, name: \.name) }.value
    }

    private nonisolated static func readCache() async -> Cache? {
        await Task.detached(priority: .userInitiated) { AppCache.read(file) as Cache? }.value
    }
}

/// Small JSON files in Caches: display data only, never logins or stream URLs.
enum AppCache {
    static let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]

    static func read<T: Decodable>(_ name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appending(path: name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func write<T: Encodable>(_ name: String, _ value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: directory.appending(path: name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func remove(_ name: String) {
        try? FileManager.default.removeItem(at: directory.appending(path: name))
    }
}

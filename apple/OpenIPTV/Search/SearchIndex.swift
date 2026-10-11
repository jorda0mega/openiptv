import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Instant on-device search, fast enough to run on every keystroke.
///
/// Names are folded once (case, accents and punctuation removed) into byte
/// strings. A query matches when each of its words starts a word in the name
/// ("for fil" finds "Forensic Files"); a looser pass ignores spaces so
/// "spiderman" still finds "Spider-Man". Typing more letters re-checks only
/// the previous matches. When exact matches are few, `fuzzy` tolerates typos
/// ("forensinc" finds "Forensic") using a word index built up front.
struct SearchCorpus<Item>: @unchecked Sendable {
    let items: [Item]
    /// " word word": a leading space so a word start is " " + prefix.
    private let keys: [[UInt8]]
    /// The same without spaces, for the loose pass.
    private let compact: [[UInt8]]
    /// Every distinct word, the items containing it, and words grouped by
    /// first letter (typos rarely hit the first letter).
    private let vocabulary: [[UInt8]]
    private let postings: [[Int32]]
    private let byFirst: [UInt8: [Int32]]

    init(_ items: [Item] = [], name: (Item) -> String) {
        self.items = items
        keys = items.map { Self.fold(name($0)) }
        compact = keys.map { $0.filter { $0 != 32 } }
        var ids: [[UInt8]: Int32] = [:]
        var vocabulary: [[UInt8]] = []
        var postings: [[Int32]] = []
        for (index, key) in keys.enumerated() {
            for word in key.split(separator: 32) where word.count >= 2 {
                let w = Array(word)
                let id: Int32
                if let known = ids[w] { id = known } else {
                    id = Int32(vocabulary.count)
                    ids[w] = id
                    vocabulary.append(w)
                    postings.append([])
                }
                if postings[Int(id)].last != Int32(index) { postings[Int(id)].append(Int32(index)) }
            }
        }
        var byFirst: [UInt8: [Int32]] = [:]
        for (id, word) in vocabulary.enumerated() { byFirst[word[0], default: []].append(Int32(id)) }
        self.vocabulary = vocabulary
        self.postings = postings
        self.byFirst = byFirst
    }

    /// Typo-tolerant matches, best first: every query word within an edit or
    /// two of a word in the name (the last word may still be being typed,
    /// so it matches the start of a word). Words under four letters must
    /// match exactly.
    func fuzzy(_ query: String, limit: Int = 60) -> [Int] {
        let words = Self.fold(query).split(separator: 32).map(Array.init)
        guard !words.isEmpty, words.contains(where: { $0.count >= 4 }) else { return [] }
        var combined: [Int32: Int]?
        for (position, word) in words.enumerated() {
            let last = position == words.count - 1
            let allowed = word.count >= 8 ? 2 : word.count >= 4 ? 1 : 0
            var found: [Int32: Int] = [:]
            for id in byFirst[word[0]] ?? [] {
                let candidate = vocabulary[Int(id)]
                guard let distance = last
                        ? Self.prefixDistance(word, candidate, max: allowed)
                        : Self.distance(word, candidate, max: allowed)
                else { continue }
                for item in postings[Int(id)] where distance < found[item] ?? .max { found[item] = distance }
            }
            if let previous = combined {
                var next: [Int32: Int] = [:]
                for (item, d) in found { if let p = previous[item] { next[item] = p + d } }
                combined = next
            } else {
                combined = found
            }
            if combined?.isEmpty ?? true { return [] }
        }
        return (combined ?? [:])
            .sorted { $0.value != $1.value ? $0.value < $1.value : keys[Int($0.key)].count < keys[Int($1.key)].count }
            .prefix(limit).map { Int($0.key) }
    }

    /// Edit distance (insert, delete, substitute, swap neighbours) if it's
    /// at most `max`.
    private static func distance(_ a: [UInt8], _ b: [UInt8], max limit: Int) -> Int? {
        guard abs(a.count - b.count) <= limit else { return nil }
        return editRow(a, b, limit: limit).flatMap { row in row[b.count] <= limit ? row[b.count] : nil }
    }

    /// Smallest edit distance between `a` and any start of `b` within
    /// `max` of `a`'s length ("forensi" vs "forensic…").
    private static func prefixDistance(_ a: [UInt8], _ b: [UInt8], max limit: Int) -> Int? {
        let upto = min(b.count, a.count + limit)
        guard upto >= a.count - limit else { return nil }
        guard let row = editRow(a, Array(b.prefix(upto)), limit: limit) else { return nil }
        let best = row[Swift.max(0, a.count - limit)...upto].min() ?? .max
        return best <= limit ? best : nil
    }

    /// Last row of the edit-distance table of `a` against `b`, or nil as
    /// soon as every cell exceeds `limit`.
    private static func editRow(_ a: [UInt8], _ b: [UInt8], limit: Int) -> [Int]? {
        let n = b.count
        var previous2 = [Int](repeating: 0, count: n + 1)
        var previous = Array(0...n)
        var current = [Int](repeating: 0, count: n + 1)
        for i in 1...Swift.max(a.count, 1) where !a.isEmpty {
            current[0] = i
            var rowMin = current[0]
            for j in stride(from: 1, through: n, by: 1) {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                var value = Swift.min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    value = Swift.min(value, previous2[j - 2] + 1)
                }
                current[j] = value
                rowMin = Swift.min(rowMin, value)
            }
            if rowMin > limit { return nil }
            (previous2, previous, current) = (previous, current, previous2)
        }
        return previous
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
/// never waits for the network. Loaded once (four pages at a time, each
/// page retried, search usable as pages arrive, resumed after an
/// interruption), then kept current with only what changed since the last
/// sync, plus a weekly full pass to drop deleted items. Runs in the
/// background from app launch.
@Observable
@MainActor
final class LibraryIndex {
    private(set) var corpus = SearchCorpus<LibraryEntry>(name: \.name)
    private(set) var indexing = false
    /// Titles loaded so far and the total, while the full catalog loads.
    private(set) var progress: (loaded: Int, total: Int)?
    /// Pages of the catalog by start index (complete when none are missing).
    private var pages: [Int: [LibraryEntry]] = [:]
    private var total: Int?
    private var syncedAt: Date?
    private var fullSyncAt: Date?
    private var server: String?

    private struct Cache: Codable {
        let server: String
        let syncedAt: Date?
        let fullSyncAt: Date?
        let total: Int?
        let pages: [Int: [LibraryEntry]]
    }

    private nonisolated static let file = "library-index.json"
    private nonisolated static let pageSize = 5000
    private nonisolated static let parallel = 4
    private nonisolated static let changesEvery: TimeInterval = 10 * 60
    private nonisolated static let fullEvery: TimeInterval = 7 * 24 * 3600

    var count: Int { corpus.items.count }

    private var complete: Bool {
        guard let total, fullSyncAt != nil else { return false }
        return stride(from: 0, to: total, by: Self.pageSize).allSatisfy { pages[$0] != nil }
    }

    func prepare(_ emby: EmbyClient) async {
        let server = emby.account.serverURL.absoluteString + "|" + emby.account.userId
        if self.server != server {
            self.server = server
            pages = [:]
            total = nil
            syncedAt = nil
            fullSyncAt = nil
            corpus = SearchCorpus(name: \.name)
            if let cache = await Self.readCache(), cache.server == server {
                pages = cache.pages
                total = cache.total
                syncedAt = cache.syncedAt
                fullSyncAt = cache.fullSyncAt
                corpus = await Self.build(ordered())
            }
        }
        guard !indexing else { return }
        let now = Date()
        let needsFull = !complete || fullSyncAt.map { now.timeIntervalSince($0) > Self.fullEvery } ?? true
        let needsChanges = syncedAt.map { now.timeIntervalSince($0) > Self.changesEvery } ?? true
        guard needsFull || needsChanges else { return }
        indexing = true
        #if canImport(UIKit)
        // Keep going for a while if the app is switched away mid-load.
        let background = UIApplication.shared.beginBackgroundTask(withName: "Library index")
        defer { UIApplication.shared.endBackgroundTask(background) }
        #endif
        defer { indexing = false; progress = nil }
        if needsFull {
            await loadAll(emby, server: server)
        } else if let since = syncedAt {
            // A little overlap so nothing saved during the last sync is missed.
            guard let changed = try? await emby.libraryIndex(changedSince: since.addingTimeInterval(-300)) else { return }
            syncedAt = now
            if !changed.isEmpty {
                let all = await Self.merge(ordered(), changed)
                pages = Self.paged(all)
                total = all.count
                corpus = await Self.build(all)
            }
            save()
        }
    }

    /// The whole catalog, resuming from whatever pages are already here.
    private func loadAll(_ emby: EmbyClient, server: String) async {
        let fresh = fullSyncAt.map { Date().timeIntervalSince($0) > Self.fullEvery } ?? false
        if fresh || total == nil {
            // A new full pass (or the first): learn the size from page one.
            guard let first = try? await Self.retrying({ try await emby.libraryPage(start: 0, limit: Self.pageSize, withTotal: true) })
            else { return }
            if fresh { pages = [:] }
            pages[0] = first.entries
            total = first.total ?? first.entries.count
        }
        guard let total else { return }
        let starts = stride(from: 0, to: total, by: Self.pageSize).filter { pages[$0] == nil }
        progress = (loadedCount, total)
        var sincePublish = 0
        await withTaskGroup(of: (Int, [LibraryEntry]?).self) { group in
            var queue = starts[...]
            for _ in 0..<Self.parallel {
                guard let start = queue.popFirst() else { break }
                group.addTask { (start, try? await Self.retrying { try await emby.libraryPage(start: start, limit: Self.pageSize).entries }) }
            }
            for await (start, entries) in group {
                guard self.server == server else { group.cancelAll(); return }
                if let entries { pages[start] = entries }
                progress = (loadedCount, total)
                sincePublish += 1
                // Search covers what's loaded so far.
                if sincePublish >= Self.parallel {
                    sincePublish = 0
                    corpus = await Self.build(ordered())
                    save()
                }
                if let next = queue.popFirst() {
                    group.addTask { (next, try? await Self.retrying { try await emby.libraryPage(start: next, limit: Self.pageSize).entries }) }
                }
            }
        }
        guard self.server == server else { return }
        if stride(from: 0, to: total, by: Self.pageSize).allSatisfy({ pages[$0] != nil }) {
            fullSyncAt = Date()
            syncedAt = fullSyncAt
        }
        corpus = await Self.build(ordered())
        save()
    }

    private var loadedCount: Int { pages.values.reduce(0) { $0 + $1.count } }

    private func ordered() -> [LibraryEntry] {
        pages.keys.sorted().flatMap { pages[$0] ?? [] }
    }

    func clear() {
        corpus = SearchCorpus(name: \.name)
        pages = [:]
        total = nil
        syncedAt = nil
        fullSyncAt = nil
        server = nil
        progress = nil
        AppCache.remove(Self.file)
    }

    private func save() {
        guard let server else { return }
        let cache = Cache(server: server, syncedAt: syncedAt, fullSyncAt: fullSyncAt, total: total, pages: pages)
        Task.detached(priority: .utility) { AppCache.write(Self.file, cache) }
    }

    /// Three tries with a short pause, so one slow page doesn't sink the load.
    private nonisolated static func retrying<T: Sendable>(_ work: @Sendable () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 0..<3 {
            do { return try await work() } catch {
                lastError = error
                try? await Task.sleep(for: .seconds(Double(attempt + 1)))
            }
        }
        throw lastError ?? SourceError.unexpected("Library page failed")
    }

    private nonisolated static func paged(_ all: [LibraryEntry]) -> [Int: [LibraryEntry]] {
        var out: [Int: [LibraryEntry]] = [:]
        for start in stride(from: 0, to: all.count, by: pageSize) {
            out[start] = Array(all[start..<min(start + pageSize, all.count)])
        }
        return out
    }

    private nonisolated static func merge(_ old: [LibraryEntry], _ changed: [LibraryEntry]) async -> [LibraryEntry] {
        await Task.detached(priority: .utility) {
            var byId = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for entry in changed { byId[entry.id] = entry }
            return byId.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }.value
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

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
///
/// Results go by how well the name matches (the whole title, its start, a
/// word in it, then the loose pass), and within that by `boost`, such as
/// popularity, so the title people mean comes first.
struct SearchCorpus<Item>: @unchecked Sendable {
    let items: [Item]
    /// " word word": a leading space so a word start is " " + prefix.
    private let keys: [[UInt8]]
    /// Key length without a trailing "(US)" / "(2005)", so typing the title
    /// alone counts as the whole title.
    private let bare: [Int]
    /// Extra score per item (0–650), or empty.
    private var boost: [Int] = []
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
        bare = zip(items, keys).map { item, key in
            let name = name(item)
            guard name.hasSuffix(")"), let open = name.range(of: " (", options: .backwards) else { return key.count }
            return Self.fold(String(name[..<open.lowerBound])).count
        }
        compact = keys.map { $0.filter { $0 != 32 } }
        // Words looked up as small Strings (stored inline, no allocation
        // up to 15 bytes): about a third of the time byte-array keys took.
        var ids: [String: Int32] = [:]
        ids.reserveCapacity(keys.count)
        var vocabulary: [[UInt8]] = []
        var postings: [[Int32]] = []
        for (index, key) in keys.enumerated() {
            key.withUnsafeBufferPointer { buffer in
                var start = 1
                while start < buffer.count {
                    var end = start
                    while end < buffer.count, buffer[end] != 32 { end += 1 }
                    if end - start >= 2 {
                        let word = UnsafeBufferPointer(rebasing: buffer[start..<end])
                        let text = String(decoding: word, as: UTF8.self)
                        let id: Int32
                        if let known = ids[text] { id = known } else {
                            id = Int32(vocabulary.count)
                            ids[text] = id
                            vocabulary.append(Array(word))
                            postings.append([])
                        }
                        if postings[Int(id)].last != Int32(index) { postings[Int(id)].append(Int32(index)) }
                    }
                    start = end + 1
                }
            }
        }
        var byFirst: [UInt8: [Int32]] = [:]
        for (id, word) in vocabulary.enumerated() { byFirst[word[0], default: []].append(Int32(id)) }
        self.vocabulary = vocabulary
        self.postings = postings
        self.byFirst = byFirst
    }

    /// The same corpus ranking with `boost` (one score per item, 0–650).
    func boosted(_ boost: [Int]) -> SearchCorpus {
        var copy = self
        copy.boost = boost.count == items.count ? boost : []
        return copy
    }

    private func boost(_ index: Int) -> Int { boost.isEmpty ? 0 : boost[index] }

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
            for (n, id) in (byFirst[word[0]] ?? []).enumerated() {
                // A newer letter was typed: stop (the caller drops this).
                if n & 1023 == 0, Task.isCancelled { return [] }
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
            .sorted {
                if $0.value != $1.value { return $0.value < $1.value }
                let a = boost(Int($0.key)), b = boost(Int($1.key))
                return a != b ? a > b : keys[Int($0.key)].count < keys[Int($1.key)].count
            }
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
        for (n, index) in candidates.enumerated() {
            // A newer letter was typed: stop (the caller drops this result,
            // so it never becomes the next search's starting point).
            if n & 2047 == 0, Task.isCancelled { return Match(query: q, ranked: [], size: items.count) }
            let key = keys[index]
            var score: Int
            if words.allSatisfy({ Self.contains(key, $0) }) {
                score = 1000
                if key.starts(with: q) { score += bare[index] == q.count || key.count == q.count ? 3000 : 2000 }
            } else if Self.contains(compact[index], loose) {
                score = 200
            } else {
                continue
            }
            // Within a kind of match: the more popular, then the closer
            // (shorter) name, first.
            score += boost(index)
            score -= min(key.count, 120)
            scored.append((index, score))
        }
        // Stable: equal scores keep the corpus order (sorted by name).
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
        return Match(query: q, ranked: scored.map(\.index), size: items.count)
    }

    /// Items whose name contains some of these words (each as the start of
    /// a word in the name), most words first, then most popular. `matched`
    /// has bit i set when word i is in the name.
    func partial(_ words: [String], limit: Int = 300) -> [(index: Int, matched: UInt64)] {
        let needles = words.prefix(64).map(Self.fold).filter { $0.count > 1 }
        guard !needles.isEmpty else { return [] }
        var found: [(index: Int, matched: UInt64, score: Int)] = []
        for index in items.indices {
            if index & 2047 == 0, Task.isCancelled { return [] }
            var mask: UInt64 = 0
            for (i, needle) in needles.enumerated() where Self.contains(keys[index], needle) { mask |= 1 << UInt64(i) }
            guard mask != 0 else { continue }
            found.append((index, mask, mask.nonzeroBitCount * 1000 + boost(index) - min(keys[index].count, 120)))
        }
        return found.sorted { $0.score > $1.score }.prefix(limit).map { ($0.index, $0.matched) }
    }

    /// Popularity score of an item (0 without one).
    func popularity(_ index: Int) -> Int { boost(index) }

    /// Lowercase, accent-free words separated by single spaces, with a
    /// leading space. Apostrophes join ("Grey's" → "greys").
    static func fold(_ text: String) -> [UInt8] {
        if let plain = foldASCII(text) { return plain }
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var out: [UInt8] = [32]
        out.reserveCapacity(folded.utf8.count + 1)
        var pendingSpace = false
        for scalar in folded.unicodeScalars {
            if scalar == "'" || scalar == "\u{2019}" { continue }
            if scalar.properties.isAlphabetic || scalar.properties.numericType != nil {
                if pendingSpace, out.count > 1 { out.append(32) }
                pendingSpace = false
                UTF8.encode(scalar) { out.append($0) }
            } else {
                pendingSpace = true
            }
        }
        return out
    }

    /// `fold` for plain ASCII (most titles), byte by byte: the same result
    /// without Foundation's folding, about ten times faster. Nil for any
    /// other text.
    private static func foldASCII(_ text: String) -> [UInt8]? {
        var text = text
        return text.withUTF8 { bytes -> [UInt8]? in
            var out: [UInt8] = [32]
            out.reserveCapacity(bytes.count + 1)
            var pendingSpace = false
            for byte in bytes {
                if byte >= 128 { return nil }
                if byte == 39 { continue }
                let lower = byte >= 65 && byte <= 90 ? byte + 32 : byte
                if (lower >= 97 && lower <= 122) || (byte >= 48 && byte <= 57) {
                    if pendingSpace, out.count > 1 { out.append(32) }
                    pendingSpace = false
                    out.append(lower)
                } else {
                    pendingSpace = true
                }
            }
            return out
        }
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
    /// IMDb title id ("tt0076759"), when the server knows it.
    var imdb: String? = nil
    /// TMDb id, when the server knows it.
    var tmdb: Int? = nil
    /// "Comedy", "Adventure", … for matching a query's words beyond the name.
    var genres: [String]? = nil

    /// The same for every copy of a title in different libraries (an HD and
    /// a 4K film, say): its IMDb or TMDb id, else its name and year.
    var titleKey: String { Self.titleKey(kind: kind, name: name, year: year, imdb: imdb, tmdb: tmdb) }

    static func titleKey(kind: String, name: String, year: Int?, imdb: String?, tmdb: Int?) -> String {
        if let imdb { return "i:" + imdb }
        let k = kind == "Series" ? "s" : "m"
        if let tmdb { return "t:\(k):\(tmdb)" }
        return "n:\(k):\(year ?? 0):" + String(decoding: SearchCorpus<String>.fold(name), as: UTF8.self)
    }
}

/// Every movie and show on the Emby server, cached on the device so search
/// never waits for the network. Loaded once (four pages at a time, each
/// page retried, search usable as pages arrive, resumed after an
/// interruption), then kept current with only what changed since the last
/// sync, plus a weekly full pass to drop deleted items (search keeps the
/// old pages until each is replaced). Runs in the background from app
/// launch. Each title is listed once however many libraries hold a copy
/// (the copies are its versions). What everyone else watches and rates
/// ranks search and makes every recommendation, from whichever public
/// data does each job best: TMDb's daily popularity and IMDb's votes gained
/// a day for Trending now, IMDb's ratings for New & notable, IMDb's genres
/// and makers for titles alike. Each source is one signal among others.
@Observable
@MainActor
final class LibraryIndex {
    private(set) var corpus = SearchCorpus<LibraryEntry>(name: \.name)
    /// Every copy's id → all copies of that title (only titles with more
    /// than one), the one listed first.
    private(set) var versions: [String: [String]] = [:]
    /// The titles on the server most in demand right now, most first.
    private(set) var trending: [LibraryEntry] = []
    /// This year's and last year's titles that IMDb voters rate well, most
    /// voted first: New & notable.
    private(set) var notable: [LibraryEntry] = []
    private(set) var indexing = false
    /// Titles loaded so far and the total, while the full catalog loads.
    private(set) var progress: (loaded: Int, total: Int)?
    /// Pages of the catalog by start index (complete when none are missing).
    private var pages: [Int: [LibraryEntry]] = [:]
    private var total: Int?
    private var syncedAt: Date?
    private var fullSyncAt: Date?
    private var server: String?
    /// The cached pages predate a field the index now keeps (IMDb ids):
    /// fetch them all again, searching the old ones meanwhile.
    private var outdated = false
    private(set) var ratings: IMDbRatings?
    private(set) var popularity: TMDbPopularity?
    /// IMDb's genres and makers for the library's titles, and titles alike
    /// by them.
    private(set) var catalog: IMDbCatalog?
    private var similarity: IMDbSimilarity?
    private var votes = IMDbVoteHistory()
    /// Every copy's id → its title (the copy listed in search).
    private var entryById: [String: LibraryEntry] = [:]
    private var chartsTask: Task<Void, Never>?
    private var catalogTask: Task<Void, Never>?
    /// Bumped whenever the entries change, so a ranking made from older
    /// entries (the index loaded meanwhile) is redone, not kept.
    private var generation = 0

    private struct Cache: Codable {
        var version: Int?
        let server: String
        let syncedAt: Date?
        let fullSyncAt: Date?
        let total: Int?
        let pages: [Int: [LibraryEntry]]
    }

    /// 2: entries carry IMDb ids. 3: and TMDb ids. 4: and genres.
    private nonisolated static let version = 4
    private nonisolated static let file = "library-index.bin"
    /// The JSON copy earlier builds saved: read once, then replaced.
    private nonisolated static let legacyFile = "library-index.json"
    private nonisolated static let pageSize = 5000
    private nonisolated static let parallel = 4
    private nonisolated static let changesEvery: TimeInterval = 10 * 60
    private nonisolated static let fullEvery: TimeInterval = 7 * 24 * 3600

    var count: Int { corpus.items.count }

    private var complete: Bool {
        guard let total, fullSyncAt != nil else { return false }
        return stride(from: 0, to: total, by: Self.pageSize).allSatisfy { pages[$0] != nil }
    }

    /// When the catalog last changed (titles added, edited or gone), as
    /// seen by this app; Home rebuilds its other rows after it.
    private(set) var changedAt: Date?

    /// `now`: the server said something changed; check at once rather than
    /// on the ten-minute schedule.
    func prepare(_ emby: EmbyClient, now urgent: Bool = false) async {
        await open(emby)
        guard let server else { return }
        guard !indexing else { return }
        let now = Date()
        let needsFull = !complete || outdated || fullSyncAt.map { now.timeIntervalSince($0) > Self.fullEvery } ?? true
        let needsChanges = urgent || syncedAt.map { now.timeIntervalSince($0) > Self.changesEvery } ?? true
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
                await publish(all)
                changedAt = now
            }
            save()
        }
    }

    /// The index saved on the device for this server, ready to search
    /// (without syncing).
    func open(_ emby: EmbyClient) async {
        let server = emby.account.serverURL.absoluteString + "|" + emby.account.userId
        if self.server != server {
            self.server = server
            pages = [:]
            total = nil
            syncedAt = nil
            fullSyncAt = nil
            outdated = false
            corpus = SearchCorpus(name: \.name)
            generation += 1
            if let (cache, legacy) = await Self.readCache(), cache.server == server {
                pages = cache.pages
                total = cache.total
                syncedAt = cache.syncedAt
                fullSyncAt = cache.fullSyncAt
                outdated = (cache.version ?? 1) < Self.version
                // Saved by an earlier build as JSON: in the quicker form now.
                if legacy { save() }
                await publish(ordered())
            }
        }
    }

    /// Loads IMDb's ratings and TMDb's popularity from the device, and
    /// downloads today's when a copy is a day old (on Wi-Fi; on any
    /// connection after a month, or if there's none yet): each ratings
    /// download adds to the vote history. Search re-ranks and the lists
    /// update as they arrive.
    func refreshCharts(unmetered: Bool) async {
        if let running = chartsTask { return await running.value }
        func due(_ age: TimeInterval?) -> Bool {
            age.map { $0 > 20 * 3600 && (unmetered || $0 > 30 * 24 * 3600) } ?? true
        }
        let task = Task {
            await loadCachedCharts()
            let ratingsDue = due(IMDbRatings.age()), popularityDue = due(TMDbPopularity.age())
            async let ratings: IMDbRatings? = ratingsDue
                ? try? await Task.detached(priority: .utility, operation: { try await IMDbRatings.download() }).value : nil
            async let popularity: TMDbPopularity? = popularityDue
                ? try? await Task.detached(priority: .utility, operation: { try await TMDbPopularity.download() }).value : nil
            let newPopularity = await popularity
            if let newPopularity { self.popularity = newPopularity }
            if let fresh = await ratings {
                await apply(fresh, downloaded: true)
            } else if newPopularity != nil {
                await rank()
            }
        }
        chartsTask = task
        await task.value
        chartsTask = nil
    }

    /// IMDb's genres and makers for the library's titles: on Wi-Fi only
    /// (about 300 MB to read), monthly, or after three days when over a
    /// twentieth of the library's titles aren't in it yet. Call once the
    /// library has loaded.
    func refreshCatalog(unmetered: Bool) async {
        if let running = catalogTask { return await running.value }
        let wanted = Set(corpus.items.compactMap { $0.imdb.flatMap(IMDbRatings.number) })
        // Not while something plays: the stream gets the connection.
        guard unmetered, !PlaybackActivity.isPlaying, !wanted.isEmpty else { return }
        let task = Task {
            if catalog == nil { catalog = await Task.detached(priority: .utility) { IMDbCatalog.cached() }.value }
            let age = catalog.map { Date().timeIntervalSince($0.builtAt) }
            let missing = catalog.map { $0.coverage(of: wanted) < 0.95 } ?? true
            guard age.map({ $0 > 30 * 24 * 3600 || (missing && $0 > 3 * 24 * 3600) }) ?? true else { return await rank() }
            // Cancelling this cancels the work (a detached task doesn't
            // inherit it).
            let work = Task.detached(priority: .background) { try await IMDbCatalog.build(for: wanted) }
            let fresh = try? await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            guard let fresh, !Task.isCancelled else { return }
            catalog = fresh
            await rank()
        }
        catalogTask = task
        await task.value
        if catalogTask == task { catalogTask = nil }
    }

    /// Stops a catalog download or build under way (signing out).
    func cancelCatalog() {
        catalogTask?.cancel()
        catalogTask = nil
    }

    /// Ratings, popularity, vote history and IMDb's catalog saved on the
    /// device, if not loaded yet.
    func loadCachedCharts() async {
        var loaded = false
        if popularity == nil, let cached = await Task.detached(priority: .utility, operation: { TMDbPopularity.cached() }).value {
            popularity = cached
            loaded = true
        }
        if votes.snapshots.isEmpty { votes = await Task.detached(priority: .utility) { IMDbVoteHistory.cached() }.value }
        if catalog == nil { catalog = await Task.detached(priority: .utility) { IMDbCatalog.cached() }.value }
        if ratings == nil, let cached = await Task.detached(priority: .utility, operation: { IMDbRatings.cached() }).value {
            await apply(cached, downloaded: false)
        } else if loaded {
            await rank()
        }
    }

    private func apply(_ ratings: IMDbRatings, downloaded: Bool) async {
        self.ratings = ratings
        if downloaded {
            let titles = Set(corpus.items.compactMap { $0.imdb.flatMap(IMDbRatings.number) })
            let history = votes
            if !titles.isEmpty, let updated = await Task.detached(priority: .utility, operation: { () -> IMDbVoteHistory? in
                var next = history
                return next.record(ratings, for: titles) ? next : nil
            }).value {
                votes = updated
            }
        }
        let start = generation
        let boosted = await Self.boost(corpus, ratings)
        guard generation == start else { return await apply(ratings, downloaded: false) }
        corpus = boosted
        await rank()
    }

    /// Every list made from the public data, again (new entries, ratings,
    /// popularity, votes or catalog), off the main thread.
    /// One at a time: asked again while one runs, it runs once more after
    /// with the inputs as they are then, so the newest inputs always
    /// publish last (an older run can't finish after a newer one).
    private func rank() async {
        if let running = rankTask {
            rankAgain = true
            return await running.value
        }
        let task = Task {
            repeat {
                rankAgain = false
                await rankOnce()
            } while rankAgain
            rankTask = nil
        }
        rankTask = task
        await task.value
    }

    private var rankTask: Task<Void, Never>?
    private var rankAgain = false

    private func rankOnce() async {
        guard ratings != nil || popularity != nil else { return }
        let start = generation
        let entries = corpus.items, history = votes, catalog = catalog
        let ratings = ratings, popularity = popularity
        let gain = await Task.detached(priority: .utility) { history.dailyGain() }.value
        async let notable = Self.notable(entries, ratings)
        async let trending = Self.trending(entries, ratings: ratings, popularity: popularity, gain: gain)
        async let similarity = Task.detached(priority: .utility) {
            catalog.map { IMDbSimilarity(entries: entries, catalog: $0, ratings: ratings) }
        }.value
        let (n, t, s) = await (notable, trending, similarity)
        // The entries changed meanwhile: once more with the new ones.
        guard generation == start else {
            rankAgain = true
            return
        }
        self.notable = n
        self.trending = t
        self.similarity = s
    }

    /// Search and the lists from these entries, each title once.
    private func publish(_ entries: [LibraryEntry]) async {
        let (corpus, versions, byId) = await Self.build(entries, ratings)
        generation += 1
        self.corpus = corpus
        self.versions = versions
        entryById = byId
        await rank()
    }

    /// The library's titles most like this one (by any copy's id) by IMDb's
    /// data, best first; empty when IMDb's data doesn't cover it.
    func imdbSimilar(to id: String, limit: Int = 20) async -> [LibraryEntry] {
        guard let similarity,
              let entry = entryById[id] ?? versions[id]?.lazy.compactMap({ self.entryById[$0] }).first,
              let imdb = entry.imdb else { return [] }
        return await Task.detached(priority: .userInitiated) { similarity.similar(toIMDb: imdb, limit: limit) }.value
    }

    /// The same for several titles at once: scanned side by side in one
    /// pass off the main thread (Home's Top picks has five).
    func imdbSimilar(to ids: [String], limit: Int = 20) async -> [[LibraryEntry]] {
        guard let similarity else { return ids.map { _ in [] } }
        let imdbs = ids.map { id in (entryById[id] ?? versions[id]?.lazy.compactMap({ self.entryById[$0] }).first)?.imdb }
        return await Task.detached(priority: .userInitiated) {
            var results = [[LibraryEntry]](repeating: [], count: imdbs.count)
            results.withUnsafeMutableBufferPointer { out in
                DispatchQueue.concurrentPerform(iterations: imdbs.count) { i in
                    out[i] = imdbs[i].map { similarity.similar(toIMDb: $0, limit: limit) } ?? []
                }
            }
            return results
        }.value
    }

    /// Every copy of the title with this id (just the id when there's one).
    func versions(of id: String) -> [String] {
        versions[id] ?? [id]
    }

    /// IMDb's score and votes for a title, once ratings are loaded.
    func rating(_ entry: LibraryEntry) -> IMDbRatings.Rating? {
        ratings?.rating(entry.imdb)
    }

    /// The whole catalog, resuming from whatever pages are already here. A
    /// fresh pass (weekly, or when the cache is outdated) fetches every page
    /// again, replacing the old ones as the new arrive.
    private func loadAll(_ emby: EmbyClient, server: String) async {
        let fresh = outdated || fullSyncAt.map { Date().timeIntervalSince($0) > Self.fullEvery } ?? false
        if fresh || total == nil {
            // A new full pass (or the first): learn the size from page one.
            guard let first = try? await Self.retrying({ try await emby.libraryPage(start: 0, limit: Self.pageSize, withTotal: true) })
            else { return }
            pages[0] = first.entries
            total = first.total ?? first.entries.count
            if let total, fresh { pages = pages.filter { $0.key < total } }
        }
        guard let total else { return }
        let starts = stride(from: 0, to: total, by: Self.pageSize).filter { fresh ? $0 > 0 : pages[$0] == nil }
        // A refresh of a complete index runs unseen; search covers it all.
        if !fresh { progress = (loadedCount, total) }
        var sincePublish = 0
        var failed = false
        await withTaskGroup(of: (Int, [LibraryEntry]?).self) { group in
            var queue = starts[...]
            for _ in 0..<Self.parallel {
                guard let start = queue.popFirst() else { break }
                group.addTask { (start, try? await Self.retrying { try await emby.libraryPage(start: start, limit: Self.pageSize).entries }) }
            }
            for await (start, entries) in group {
                guard self.server == server else { group.cancelAll(); return }
                if let entries { pages[start] = entries } else { failed = true }
                if !fresh { progress = (loadedCount, total) }
                sincePublish += 1
                // Search covers what's loaded so far.
                if sincePublish >= Self.parallel {
                    sincePublish = 0
                    await publish(ordered())
                    save()
                }
                if let next = queue.popFirst() {
                    group.addTask { (next, try? await Self.retrying { try await emby.libraryPage(start: next, limit: Self.pageSize).entries }) }
                }
            }
        }
        guard self.server == server else { return }
        if !failed, stride(from: 0, to: total, by: Self.pageSize).allSatisfy({ pages[$0] != nil }) {
            fullSyncAt = Date()
            syncedAt = fullSyncAt
            outdated = false
        }
        await publish(ordered())
        save()
    }

    private var loadedCount: Int { pages.values.reduce(0) { $0 + $1.count } }

    private func ordered() -> [LibraryEntry] {
        pages.keys.sorted().flatMap { pages[$0] ?? [] }
    }

    func clear() {
        cancelCatalog()
        corpus = SearchCorpus(name: \.name)
        generation += 1
        versions = [:]
        entryById = [:]
        similarity = nil
        trending = []
        notable = []
        pages = [:]
        total = nil
        syncedAt = nil
        fullSyncAt = nil
        server = nil
        outdated = false
        progress = nil
        AppCache.remove(Self.file)
        AppCache.remove(Self.legacyFile)
    }

    private func save() {
        guard let server else { return }
        // Outdated pages are saved as such, so an interrupted fresh pass resumes.
        let snapshot = pages
        let header = LibraryIndexFile.Header(version: outdated ? 1 : Self.version, server: server, syncedAt: syncedAt,
                                             fullSyncAt: fullSyncAt, total: total,
                                             pages: snapshot.keys.sorted().map { [$0, snapshot[$0]?.count ?? 0] })
        AppCache.saveData(Self.file) { LibraryIndexFile.encode(header, pages: snapshot) }
        AppCache.remove(Self.legacyFile)
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

    /// The search corpus with each title once (copies in other libraries,
    /// and pages overlapping mid-refresh, folded in), ranked by IMDb
    /// popularity when ratings are loaded, and the copies of each title.
    /// The corpus, each copy's id → all copies, and each title by id: off
    /// the main thread (a large library is 100,000 titles and more).
    private nonisolated static func build(_ entries: [LibraryEntry], _ ratings: IMDbRatings?) async
        -> (SearchCorpus<LibraryEntry>, [String: [String]], [String: LibraryEntry]) {
        await Task.detached(priority: .userInitiated) {
            #if DEBUG
            let started = CFAbsoluteTimeGetCurrent()
            defer { NSLog("%@", String(format: "PERF index build %.0f ms (%d titles)", (CFAbsoluteTimeGetCurrent() - started) * 1000, entries.count)) }
            #endif
            var seenIds = Set<String>()
            seenIds.reserveCapacity(entries.count)
            var groupOf: [String: Int] = [:]
            groupOf.reserveCapacity(entries.count)
            var titles: [LibraryEntry] = []
            var copies: [[String]] = []
            for entry in entries where seenIds.insert(entry.id).inserted {
                let key = entry.titleKey
                if let group = groupOf[key] {
                    copies[group].append(entry.id)
                } else {
                    groupOf[key] = titles.count
                    titles.append(entry)
                    copies.append([entry.id])
                }
            }
            var versions: [String: [String]] = [:]
            for ids in copies where ids.count > 1 {
                for id in ids { versions[id] = ids }
            }
            let corpus = SearchCorpus(titles, name: \.name)
            let byId = Dictionary(titles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            return (ratings.map { boosted(corpus, $0) } ?? corpus, versions, byId)
        }.value
    }

    /// The 300 titles most in demand right now, by every crowd signal at
    /// hand: TMDb's daily popularity (what people view, look up and add to
    /// watchlists) and votes gained a day on IMDb (what people just
    /// watched). Each signal ranks the library on its own and a title's
    /// place is the average of its ranks, so no one source decides and
    /// another plugs in the same way. With neither yet: the last three
    /// years' titles by IMDb votes a year since they came out.
    private nonisolated static func trending(_ entries: [LibraryEntry], ratings: IMDbRatings?, popularity: TMDbPopularity?,
                                             gain: [UInt32: Double]?) async -> [LibraryEntry] {
        let year = Calendar.current.component(.year, from: Date())
        return await Task.detached(priority: .utility) {
            let titles = entries.indices.filter { entries[$0].kind == "Movie" || entries[$0].kind == "Series" }
            func imdb(_ i: Int) -> (UInt32, IMDbRatings.Rating)? {
                guard let ratings, let number = entries[i].imdb.flatMap(IMDbRatings.number),
                      let rating = ratings.rating(number: number) else { return nil }
                return (number, rating)
            }
            var signals: [[Int: Double]] = []
            if let popularity {
                signals.append(Dictionary(uniqueKeysWithValues: titles.compactMap { i in popularity.popularity(entries[i]).map { (i, $0) } }))
            }
            if let gain {
                // Titles with a few hundred votes swing on a handful.
                signals.append(Dictionary(uniqueKeysWithValues: titles.compactMap { i in
                    imdb(i).flatMap { number, rating in rating.votes >= 500 ? gain[number].map { (i, $0) } : nil }
                }))
            }
            if signals.allSatisfy(\.isEmpty) {
                signals = [Dictionary(uniqueKeysWithValues: titles.compactMap { i -> (Int, Double)? in
                    guard let (_, rating) = imdb(i), rating.votes >= 500, let released = entries[i].year, released >= year - 2 else { return nil }
                    return (i, Double(rating.votes) / max(0.5, Double(year - released) + 0.5))
                })]
            }
            // Each signal's ranks as 0 … 1 (1 the most; equal values share
            // one), averaged over the signals that know the title.
            var sum: [Int: Double] = [:], count: [Int: Double] = [:]
            for signal in signals where !signal.isEmpty {
                let ordered = signal.sorted { $0.value < $1.value }
                var place = 0
                for (k, (i, value)) in ordered.enumerated() {
                    if k > 0, value != ordered[k - 1].value { place = k }
                    // A signal knowing one title ranks it top.
                    sum[i, default: 0] += ordered.count > 1 ? Double(place) / Double(ordered.count - 1) : 1
                    count[i, default: 0] += 1
                }
            }
            return sum.map { ($0.key, $0.value / count[$0.key]!) }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
                .prefix(300)
                .map { entries[$0.0] }
        }.value
    }

    /// Released this year or last, rated 6.5 or more by at least a
    /// thousand IMDb voters; the 300 most voted.
    private nonisolated static func notable(_ entries: [LibraryEntry], _ ratings: IMDbRatings?) async -> [LibraryEntry] {
        guard let ratings else { return [] }
        let year = Calendar.current.component(.year, from: Date())
        return await Task.detached(priority: .utility) {
            entries.filter { ($0.kind == "Movie" || $0.kind == "Series") && ($0.year ?? 0) >= year - 1 }
                .compactMap { entry in ratings.rating(entry.imdb).map { (entry, $0) } }
                .filter { $0.1.score >= 6.5 && $0.1.votes >= 1_000 }
                .sorted { $0.1.votes > $1.1.votes }
                .prefix(300)
                .map(\.0)
        }.value
    }

    private nonisolated static func boost(_ corpus: SearchCorpus<LibraryEntry>, _ ratings: IMDbRatings) async -> SearchCorpus<LibraryEntry> {
        await Task.detached(priority: .userInitiated) { boosted(corpus, ratings) }.value
    }

    private nonisolated static func boosted(_ corpus: SearchCorpus<LibraryEntry>, _ ratings: IMDbRatings) -> SearchCorpus<LibraryEntry> {
        let year = Calendar.current.component(.year, from: Date())
        return corpus.boosted(corpus.items.map { ratings.popularity($0.imdb, year: $0.year, currentYear: year) })
    }

    /// The saved index, and whether it was the older JSON copy.
    private nonisolated static func readCache() async -> (Cache, Bool)? {
        await Task.detached(priority: .userInitiated) {
            #if DEBUG
            let started = CFAbsoluteTimeGetCurrent()
            defer { NSLog("%@", String(format: "PERF index read %.0f ms", (CFAbsoluteTimeGetCurrent() - started) * 1000)) }
            #endif
            if let data = try? Data(contentsOf: AppCache.directory.appending(path: file), options: .alwaysMapped),
               let (header, pages) = LibraryIndexFile.decode(data) {
                return (Cache(version: header.version, server: header.server, syncedAt: header.syncedAt,
                              fullSyncAt: header.fullSyncAt, total: header.total, pages: pages), false)
            }
            return (AppCache.read(legacyFile) as Cache?).map { ($0, true) }
        }.value
    }
}

/// Small JSON files in Caches: display data only, never logins or stream URLs.
enum AppCache {
    static let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]

    /// Downloads cut off when the app last closed, which the system leaves
    /// in the temporary folder (a dataset is hundreds of megabytes). Only
    /// ones untouched for ten minutes: not any under way now.
    static func removeStaleDownloads() {
        let folder = FileManager.default.temporaryDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files where file.lastPathComponent.hasPrefix("CFNetworkDownload_") {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if Date().timeIntervalSince(modified) > 600 { try? FileManager.default.removeItem(at: file) }
        }
    }

    static func read<T: Decodable>(_ name: String) -> T? {
        guard let data = try? Data(contentsOf: directory.appending(path: name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func write<T: Encodable>(_ name: String, _ value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: directory.appending(path: name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static let writer = DispatchQueue(label: "openiptv.cache-writes", qos: .utility)

    /// Writes in the background, in the order asked (a newer copy is never
    /// overwritten by an older one finishing late).
    static func save<T: Encodable & Sendable>(_ name: String, _ value: T) {
        writer.async { write(name, value) }
    }

    /// The same for a file in its own format, made on the writer's queue.
    static func saveData(_ name: String, _ make: @escaping @Sendable () -> Data?) {
        let url = directory.appending(path: name)
        writer.async {
            guard let data = make() else { return }
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    /// Saved files starting with one of these that haven't been written for
    /// `days` (title pages not visited in a month), in the background.
    static func prune(startingWith prefixes: [String], olderThan days: Double) {
        let directory = directory
        writer.async {
            let cutoff = Date().addingTimeInterval(-days * 24 * 3600)
            let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for url in urls where prefixes.contains(where: url.lastPathComponent.hasPrefix) {
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if modified < cutoff { try? FileManager.default.removeItem(at: url) }
            }
        }
    }

    /// Every saved file whose name starts with one of these (an account's
    /// title pages), in order with the background writes.
    static func removeAll(startingWith prefixes: [String]) {
        let directory = directory
        writer.async {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path())) ?? []
            for name in names where prefixes.contains(where: name.hasPrefix) {
                try? FileManager.default.removeItem(at: directory.appending(path: name))
            }
        }
    }

    /// In order with the background writes: one still queued can't put
    /// back what's removed (a signed-out account's Home, say).
    static func remove(_ name: String) {
        let url = directory.appending(path: name)
        writer.async { try? FileManager.default.removeItem(at: url) }
    }
}

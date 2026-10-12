import Foundation

/// How many IMDb votes each title in the library had at the last few
/// downloads of IMDb's ratings (daily on Wi-Fi): votes gained a day, one of
/// "Trending now"'s signals (what people have just watched), the closest
/// IMDb's datasets come to its own popularity chart (which isn't
/// published).
struct IMDbVoteHistory: Codable, Sendable {
    struct Snapshot: Codable, Sendable {
        let at: Date
        /// Title number → votes.
        let votes: [UInt32: UInt32]
    }

    var snapshots: [Snapshot] = []

    private static let file = "imdb-votes.json"

    static func cached() -> IMDbVoteHistory { AppCache.read(file) ?? IMDbVoteHistory() }

    /// Adds today's counts (at most one a day, ten kept) and saves; false
    /// when there was one already.
    mutating func record(_ ratings: IMDbRatings, for titles: Set<UInt32>, at now: Date = Date()) -> Bool {
        if let last = snapshots.last, now.timeIntervalSince(last.at) < 20 * 3600 { return false }
        var votes: [UInt32: UInt32] = [:]
        votes.reserveCapacity(titles.count)
        for title in titles {
            if let rating = ratings.rating(number: title) { votes[title] = UInt32(rating.votes) }
        }
        snapshots = Array((snapshots + [Snapshot(at: now, votes: votes)]).suffix(10))
        AppCache.save(Self.file, self)
        return true
    }

    /// Votes gained per day, title by title: the newest counts against the
    /// oldest from two to eight days before them. Nil until there are two
    /// such downloads.
    func dailyGain() -> [UInt32: Double]? {
        guard let latest = snapshots.last,
              let base = snapshots.first(where: {
                  let days = latest.at.timeIntervalSince($0.at) / 86400
                  return days >= 2 && days <= 8
              }) else { return nil }
        let days = latest.at.timeIntervalSince(base.at) / 86400
        var gain: [UInt32: Double] = [:]
        // Titles in both (none gained is 0, not unknown).
        for (title, now) in latest.votes {
            guard let before = base.votes[title] else { continue }
            gain[title] = Double(now > before ? now - before : 0) / days
        }
        return gain
    }
}

/// Titles in the library alike by IMDb's data: who made them (directors
/// and writers in common count most), their genres, when they came out and
/// how well IMDb voters rate them. Built off the main thread whenever the
/// library or IMDb's data changes; asking is a quick scan.
struct IMDbSimilarity: Sendable {
    private struct Profile: Sendable {
        let genres: Set<String>
        let directors: Set<UInt32>
        let writers: Set<UInt32>
        let year: Int?
        let series: Bool
        /// -1 … 1.5: how well rated, weighed by how many voted.
        let quality: Double
    }

    private let entries: [LibraryEntry]
    private let profiles: [Profile?]
    private let byTitle: [UInt32: Int]

    init(entries: [LibraryEntry], catalog: IMDbCatalog, ratings: IMDbRatings?) {
        self.entries = entries
        var byTitle: [UInt32: Int] = [:]
        profiles = entries.enumerated().map { index, entry in
            guard let number = entry.imdb.flatMap(IMDbRatings.number), let title = catalog.titles[number] else { return nil }
            byTitle[number] = index
            var quality = 0.0
            if let rating = ratings?.rating(number: number) {
                let score = min(1.5, max(-1, (rating.score - 6.5) / 1.5))
                quality = score * min(1, log10(Double(max(rating.votes, 1))) / 5)
            }
            return Profile(genres: Set(title.genres), directors: Set(title.directors), writers: Set(title.writers),
                           year: title.year ?? entry.year, series: title.series, quality: quality)
        }
        self.byTitle = byTitle
    }

    /// The library's titles most like this one (by IMDb id), best first;
    /// empty when IMDb's data doesn't cover it.
    func similar(toIMDb imdb: String, limit: Int) -> [LibraryEntry] {
        guard let number = IMDbRatings.number(imdb), let index = byTitle[number], let seed = profiles[index] else { return [] }
        let key = entries[index].titleKey
        var scored: [(Int, Double)] = []
        for (i, profile) in profiles.enumerated() {
            guard i != index, let profile, entries[i].titleKey != key else { continue }
            let directors = seed.directors.intersection(profile.directors).count
            let writers = seed.writers.intersection(profile.writers).count
            let union = seed.genres.union(profile.genres).count
            let genres = union == 0 ? 0 : Double(seed.genres.intersection(profile.genres).count) / Double(union)
            // Alike in who made it, or close in kind (most genres shared).
            guard directors + writers > 0 || genres >= 0.5 else { continue }
            var score = 4 * Double(min(directors, 2)) + 2.5 * Double(min(writers, 2)) + 3 * genres
            if let a = seed.year, let b = profile.year { score += max(0, 1 - Double(abs(a - b)) / 15) }
            if seed.series == profile.series { score += 0.5 }
            score += profile.quality
            scored.append((i, score))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map { entries[$0.0] }
    }
}

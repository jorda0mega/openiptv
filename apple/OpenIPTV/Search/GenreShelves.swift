import Foundation

/// Each genre's titles, best-known first, and what Search's genre tiles are
/// picked from: worked out in one pass over the catalog, away from the main
/// thread whenever the catalog or IMDb's ratings change (LibraryIndex), so
/// a genre page and the tiles open without a scan of every title.
/// Regression: each drawing of a genre page filtered and sorted all
/// 129,000 titles on the main thread. The order is the one it had: most
/// IMDb votes first, then by name, the catalog's order among equals.
struct GenreShelves: Sendable {
    /// The titles kept per genre (a genre page shows 150).
    static let kept = 150
    /// Titles with a poster kept per genre for the tiles (12 tiles need at
    /// most 12; a few more for titles already on an earlier tile).
    static let keptWithPosters = 64

    struct Entry: Sendable {
        let entry: LibraryEntry
        let votes: Int
    }

    let version: Int
    /// Genre → its best-known titles.
    let titles: [String: [LibraryEntry]]
    /// Genre → how many titles it has.
    let counts: [String: Int]
    /// Genre → its best-known titles with a poster.
    let withPosters: [String: [Entry]]

    init(_ items: [LibraryEntry], ratings: IMDbRatings?, version: Int) {
        self.version = version
        var counts: [String: Int] = [:]
        var all: [String: [Entry]] = [:]
        for entry in items {
            guard let genres = entry.genres, !genres.isEmpty else { continue }
            let votes = ratings?.rating(entry.imdb)?.votes ?? 0
            for genre in genres {
                counts[genre, default: 0] += 1
                all[genre, default: []].append(Entry(entry: entry, votes: votes))
            }
        }
        var titles: [String: [LibraryEntry]] = [:]
        var withPosters: [String: [Entry]] = [:]
        for (genre, entries) in all {
            let ranked = entries.sorted(by: Self.better)
            titles[genre] = ranked.prefix(Self.kept).map(\.entry)
            withPosters[genre] = Array(ranked.lazy.filter { $0.entry.imageTag != nil }.prefix(Self.keptWithPosters))
        }
        self.titles = titles
        self.counts = counts
        self.withPosters = withPosters
    }

    /// More votes first, then by name.
    static func better(_ a: Entry, _ b: Entry) -> Bool {
        a.votes != b.votes ? a.votes > b.votes : a.entry.name < b.entry.name
    }
}

import Foundation

/// A search split for matching across a title's details: years ("1990")
/// apart from words; the words then match the name, genres, or (from the
/// server) cast and directors. "zorro antonio" finds The Mask of Zorro
/// (Antonio Banderas), "zorro 1990" the Zorro of 1990 first, "zorro
/// comedy" the comedies, "antonio banderas" his films.
struct SearchQuery: Sendable, Equatable {
    /// Words that aren't years, folded, in order.
    let words: [String]
    let years: [Int]

    init(_ text: String) {
        var words: [String] = [], years: [Int] = []
        for word in String(decoding: SearchCorpus<String>.fold(text), as: UTF8.self).split(separator: " ") {
            if word.count == 4, let year = Int(word), (1900...2100).contains(year) {
                years.append(year)
            } else {
                words.append(String(word))
            }
        }
        self.words = words
        self.years = years
    }

    var title: String { words.joined(separator: " ") }
    var isEmpty: Bool { words.isEmpty && years.isEmpty }

    /// How far a title's year is from the one asked for (0 when none was).
    func yearDistance(_ year: Int?) -> Int {
        guard let asked = years.first else { return 0 }
        return year.map { abs($0 - asked) } ?? 50
    }

    /// Whether `word` starts a word of `text` ("ban" in "Antonio Banderas").
    static func startsWord(_ word: String, in text: String) -> Bool {
        String(decoding: SearchCorpus<String>.fold(text), as: UTF8.self)
            .split(separator: " ").contains { $0.hasPrefix(word) }
    }
}

/// A library title found for a query, and how.
struct SearchHit: Sendable {
    let entry: LibraryEntry
    /// Query words its name and genres don't contain, still to be found in
    /// its cast (empty once it fully matches).
    var pending: [String]
    /// Whom it matched through ("Antonio Banderas"), shown with it.
    var person: String?
}

enum SmartSearch {
    /// The instant part, on the device: titles whose name has every word
    /// (the asked year's first), then titles whose name has some of the
    /// words and whose genres cover the rest, then titles still waiting for
    /// a cast check.
    static func local(_ query: SearchQuery, corpus: SearchCorpus<LibraryEntry>,
                      previous: SearchCorpus<LibraryEntry>.Match?) -> (match: SearchCorpus<LibraryEntry>.Match?, hits: [SearchHit]) {
        if query.words.isEmpty {
            // Only a year: that year's titles, most popular first.
            guard let year = query.years.first else { return (nil, []) }
            let indices = corpus.items.indices.filter { corpus.items[$0].year == year }
                .sorted { corpus.popularity($0) > corpus.popularity($1) }
            return (nil, indices.prefix(60).map { SearchHit(entry: corpus.items[$0], pending: []) })
        }
        let match = corpus.search(query.title, refining: previous)
        var full = Array(match.ranked.prefix(300))
        if !query.years.isEmpty {
            // Closest year first, keeping the match order within each band.
            func band(_ index: Int) -> Int {
                let distance = query.yearDistance(corpus.items[index].year)
                return distance == 0 ? 0 : distance <= 1 ? 1 : distance <= 3 ? 2 : 3
            }
            full = full.enumerated().sorted { (band($0.element), $0.offset) < (band($1.element), $1.offset) }.map(\.element)
        }
        var hits = full.prefix(60).map { SearchHit(entry: corpus.items[$0], pending: []) }
        guard query.words.count > 1 else { return (match, hits) }

        // Some words in the name; the others must be in its genres or cast.
        let all: UInt64 = query.words.count >= 64 ? .max : (1 << UInt64(query.words.count)) - 1
        let fullSet = Set(full)
        var genreMatches: [SearchHit] = [], castChecks: [SearchHit] = []
        for (index, matched) in corpus.partial(query.words) where matched != all && !fullSet.contains(index) {
            let entry = corpus.items[index]
            if !query.years.isEmpty, query.yearDistance(entry.year) > 3 { continue }
            let rest = query.words.enumerated().filter { matched & (1 << UInt64($0.offset)) == 0 }.map(\.element)
            let genres = (entry.genres ?? []).joined(separator: " ")
            let pending = rest.filter { !SearchQuery.startsWord($0, in: genres) }
            if pending.isEmpty { genreMatches.append(SearchHit(entry: entry, pending: [])) }
            else if pending.count < query.words.count { castChecks.append(SearchHit(entry: entry, pending: pending)) }
        }
        hits += genreMatches.prefix(40)
        hits += castChecks.prefix(30)
        return (match, hits)
    }
}

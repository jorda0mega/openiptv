import Foundation

/// The top of Home: one title, big, to start straight away.
struct Featured: Codable, Hashable {
    let card: Card
    let backdrop: String
    /// "Movie · 2026 · IMDb 7.1"
    let details: String
    let overview: String?
}

struct HomeContent: Codable, Hashable {
    var featured: Featured?
    var rows: [HomeRow]
}

/// Home, personal and current rather than one row per library:
/// - a featured pick: the most popular title you haven't seen, preferring
///   this year's and last year's;
/// - Continue Watching: what you're partway through, then the next episode
///   of each show you're watching (right under the featured pick, where
///   resuming is quickest);
/// - Top picks for you: one row of titles like your last five watches,
///   taken from each in turn so it stays varied;
/// - Trending now: what's popular this week (TMDb) on the server, unwatched;
/// - New & notable: recently added, keeping the popular and well rated.
/// A few rows that each do one job, like Netflix and IMDb's homes. Movies
/// and shows mix, and each title appears once on the page however many
/// libraries hold a copy (HD and 4K are one title). Top picks choose
/// first, then New & notable, and Trending fills from what's left of the
/// week's trending titles, so no row is emptied by another.
@MainActor
enum HomeFeed {
    /// What's partway through, then the next episode of each show being
    /// watched that isn't already there.
    static func continueItems(watching: [EmbyItem], nextUp: [EmbyItem]) -> [EmbyItem] {
        let watchingShows = Set(watching.compactMap(\.seriesId))
        let watchingNames = Set(watching.compactMap { $0.seriesName?.lowercased() })
        return watching + nextUp.filter {
            !watchingShows.contains($0.seriesId ?? "") && !watchingNames.contains(($0.seriesName ?? "").lowercased())
        }
    }

    static func load(_ emby: EmbyClient, library: LibraryIndex, cardWidth: Int, backdropWidth: Int) async throws -> HomeContent {
        // Everything that doesn't depend on something else, at once: what
        // you're watching and what's new, and the trending titles with what
        // you've seen of them.
        let trendingIds = library.trending.prefix(100).map(\.id)
        async let trendingItems = emby.items(ids: trendingIds)
        let sources = try await emby.homeSources()
        let ratings = library.ratings, popularity = library.popularity
        let thisYear = Calendar.current.component(.year, from: Date())

        func trend(_ item: EmbyItem) -> Double? {
            popularity?.popularity(item.tmdb, item.kind == "Series" ? .show : .movie)
        }
        func details(_ item: EmbyItem) -> String {
            [item.kind == "Series" ? "Show" : "Movie", item.productionYear.map(String.init),
             ratings?.rating(item.imdb).map(IMDbRatings.label)].compactMap(\.self).joined(separator: " · ")
        }
        func watched(_ item: EmbyItem) -> Bool {
            item.userData?.played == true || (item.userData?.playedPercentage ?? 0) > 0
        }
        /// Worth suggesting: not something IMDb voters clearly disliked.
        func worthIt(_ item: EmbyItem) -> Bool {
            guard let rating = ratings?.rating(item.imdb), rating.votes >= 500 else { return true }
            return rating.score >= 5.5
        }
        // What's already on the page: titles, and shows by id and by name.
        var shown = Set<String>()
        func keys(_ item: EmbyItem) -> [String] {
            if item.kind == "Episode" {
                return ["show:" + (item.seriesId ?? item.id), "showname:" + (item.seriesName ?? "").lowercased()]
            }
            return [item.titleKey] + (item.kind == "Series" ? ["show:" + item.id, "showname:" + item.name.lowercased()] : [])
        }
        func isShown(_ item: EmbyItem) -> Bool { keys(item).contains(where: shown.contains) }
        func show(_ item: EmbyItem) { shown.formUnion(keys(item)) }
        func posterRow(_ title: String, _ items: [EmbyItem]) -> HomeRow? {
            guard let row = emby.row(title, items, .poster, cardWidth) else { return nil }
            let cards = zip(row.cards, items).map { card, item in
                Card(id: card.id, kind: card.kind, title: card.title, subtitle: details(item),
                     images: card.images, progress: card.progress, playable: card.playable)
            }
            return HomeRow(title: row.title, shape: row.shape, aspect: row.aspect, cards: cards)
        }

        var rows: [HomeRow] = []

        // Continue Watching, then the next episode of shows not already in it.
        let resume = continueItems(watching: sources.watching, nextUp: sources.nextUp)
        if let row = emby.showRow("Continue Watching", resume, cardWidth) { rows.append(row) }
        resume.forEach(show)

        // Trending titles on the server, with what this user has seen of them.
        let popular = await trendingItems.filter { !watched($0) && !isShown($0) && worthIt($0) }

        // New & notable candidates, needed for the featured pick when
        // popularity hasn't downloaded yet.
        func notable(_ item: EmbyItem) -> Bool {
            if ratings == nil, popularity == nil { return true }
            if let score = trend(item), score >= 5 { return true }
            if let rating = ratings?.rating(item.imdb), rating.votes >= 5_000, rating.score >= 6 { return true }
            return false
        }
        let added = sources.added.filter {
            ($0.kind == "Movie" || $0.kind == "Series") && !watched($0) && notable($0) && worthIt($0)
        }

        // Featured: popular and recent, with a backdrop to show.
        let pool = popular.isEmpty ? Array(added.prefix(20)) : popular
        let withBackdrop = pool.filter { emby.backdropURL(for: $0, width: backdropWidth) != nil }
        // The same pick all day (one of the top few recent ones, by date),
        // so refreshing doesn't swap the top of the screen.
        let recent = withBackdrop.filter { ($0.productionYear ?? 0) >= thisYear - 1 }
        let choices = Array((recent.isEmpty ? withBackdrop : recent).prefix(5))
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        let pick = choices.isEmpty ? nil : choices[day % choices.count]
        var featured: Featured?
        if let pick, let backdrop = emby.backdropURL(for: pick, width: backdropWidth) {
            let poster = emby.card(pick, context: .poster, shape: .portrait, width: cardWidth)
            featured = Featured(card: poster, backdrop: backdrop.absoluteString, details: details(pick), overview: pick.overview)
            show(pick)
        }

        // Top picks: titles like the five you watched last, one from each in
        // turn (Emby's own ranking of what's most alike within each).
        let history = (sources.watching + sources.played)
            .sorted { ($0.userData?.lastPlayedDate ?? "") > ($1.userData?.lastPlayedDate ?? "") }
        var seeds: [(id: String, name: String)] = []
        var seedNames = Set<String>()
        for item in history {
            let id = item.kind == "Episode" ? item.seriesId : item.id
            let name = item.kind == "Episode" ? item.seriesName : item.name
            guard let id, let name, seedNames.insert(name.lowercased()).inserted else { continue }
            seeds.append((id, name))
            if seeds.count == 5 { break }
        }
        let similar = await withTaskGroup(of: (Int, [EmbyItem]).self) { group in
            for (order, seed) in seeds.enumerated() {
                group.addTask { (order, await emby.similar(to: seed.id)) }
            }
            var out = [[EmbyItem]](repeating: [], count: seeds.count)
            for await (order, items) in group { out[order] = items }
            return out
        }
        var picks: [EmbyItem] = []
        var queues = similar.map { $0.filter { !watched($0) && worthIt($0) }[...] }
        while picks.count < 20, queues.contains(where: { !$0.isEmpty }) {
            for i in queues.indices where picks.count < 20 {
                while let item = queues[i].popFirst() {
                    guard !isShown(item) else { continue }
                    picks.append(item)
                    show(item)
                    break
                }
            }
        }

        var newRow: [EmbyItem] = []
        for item in added where newRow.count < 20 && !isShown(item) {
            newRow.append(item)
            show(item)
        }

        var popularRow: [EmbyItem] = []
        for item in popular where popularRow.count < 20 && !isShown(item) {
            popularRow.append(item)
            show(item)
        }

        if picks.count >= 4, let row = posterRow("Top picks for you", picks) { rows.append(row) }
        if let row = posterRow("Trending now", popularRow) { rows.append(row) }
        if newRow.count >= 4, let row = posterRow("New & notable", newRow) { rows.append(row) }
        return HomeContent(featured: featured, rows: rows)
    }
}

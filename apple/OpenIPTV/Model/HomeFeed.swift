import Foundation

/// The top of Home: one title, big, to start straight away.
struct Featured: Codable, Hashable {
    let card: Card
    let backdrop: String
    /// "Movie · 2026 · IMDb 7.1"
    let details: String
    let overview: String?
    /// The title's logo (the server's "Logo" art), for Apple TV's hero.
    var logo: String? = nil
}

struct HomeContent: Codable, Hashable {
    var featured: Featured?
    var rows: [HomeRow]
    /// When it was built, and the recent watches Top picks came from: a
    /// launch rebuilds the other rows only when these are out of date.
    var builtAt: Date?
    var history: [String]?
    /// Apple TV's hero: the featured pick and a few more like it, in turn.
    var spotlight: [Featured]?
}

/// Home, personal and current rather than one row per library:
/// - a featured pick: the most popular title you haven't seen, preferring
///   this year's and last year's;
/// - Continue Watching: what you're partway through, then the next episode
///   of each show you're watching (right under the featured pick, where
///   resuming is quickest);
/// - Top picks for you: one row of titles like your last five watches by
///   IMDb's data (who made them, genres, era), taken from each in turn so it
///   stays varied;
/// - Trending now: titles on the server most in demand this week (TMDb's
///   popularity and IMDb's votes gained, together), unwatched;
/// - New & notable: titles on the server released in the last year that
///   IMDb voters rate 6.5 or more, most voted first.
/// A few rows that each do one job, like Netflix and IMDb's homes. Movies
/// and shows mix, and each title appears once on the page however many
/// libraries hold a copy (HD and 4K are one title): the featured titles
/// choose first, then Top picks, then New & notable, and Trending fills
/// from what's left of the week's trending titles, so no row repeats
/// another or the featured titles.
@MainActor
enum HomeFeed {
    /// The titles watched most recently (a show for an episode), newest
    /// first: what Top picks are like.
    static func seeds(watching: [EmbyItem], played: [EmbyItem], limit: Int = 5) -> [(id: String, name: String)] {
        let history = (watching + played).sorted { ($0.userData?.lastPlayedDate ?? "") > ($1.userData?.lastPlayedDate ?? "") }
        var seeds: [(id: String, name: String)] = []
        var names = Set<String>()
        for item in history {
            let id = item.kind == "Episode" ? item.seriesId : item.id
            let name = item.kind == "Episode" ? item.seriesName : item.name
            guard let id, let name, names.insert(name.lowercased()).inserted else { continue }
            seeds.append((id, name))
            if seeds.count == limit { break }
        }
        return seeds
    }

    /// What's partway through, then the next episode of each show being
    /// watched that isn't already there.
    static func continueItems(watching: [EmbyItem], nextUp: [EmbyItem]) -> [EmbyItem] {
        let watchingShows = Set(watching.compactMap(\.seriesId))
        let watchingNames = Set(watching.compactMap { $0.seriesName?.lowercased() })
        return watching + nextUp.filter {
            !watchingShows.contains($0.seriesId ?? "") && !watchingNames.contains(($0.seriesName ?? "").lowercased())
        }
    }

    /// The library's titles most like each of these by IMDb's data (who
    /// made them, genres, era, rating), in the same order, fetched in one
    /// request with what's been watched of them. Emby's own suggestions
    /// only for a title IMDb's data doesn't cover yet.
    private static func similar(_ emby: EmbyClient, library: LibraryIndex, to ids: [String]) async -> [[EmbyItem]] {
        let alike = await library.imdbSimilar(to: ids, limit: 20).map { $0.map(\.id) }
        var seen = Set<String>()
        let all = alike.flatMap { $0 }.filter { seen.insert($0).inserted }
        // Emby's suggestions for the titles IMDb's data doesn't cover, asked
        // alongside the others' details rather than after them.
        let uncovered = alike.indices.filter { alike[$0].isEmpty }.map { ($0, ids[$0]) }
        async let fallbacks = suggestions(emby, for: uncovered)
        let items = await emby.items(ids: all)
        let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let other = await fallbacks
        return alike.enumerated().map { order, list in list.isEmpty ? other[order] ?? [] : list.compactMap { byId[$0] } }
    }

    /// Emby's own suggestions for these (order, id) pairs, by order.
    private nonisolated static func suggestions(_ emby: EmbyClient, for seeds: [(Int, String)]) async -> [Int: [EmbyItem]] {
        await withTaskGroup(of: (Int, [EmbyItem]).self) { group in
            for (order, id) in seeds { group.addTask { (order, await emby.similar(to: id)) } }
            var out: [Int: [EmbyItem]] = [:]
            for await (order, items) in group { out[order] = items }
            return out
        }
    }

    /// `early`: Continue Watching as soon as it's known, before the slower
    /// rows (for a Home with nothing to show yet).
    /// `sources`: what's being watched, already asked for (while the index
    /// opened).
    static func load(_ emby: EmbyClient, library: LibraryIndex, cardWidth: Int, backdropWidth: Int,
                     sources pending: Task<EmbyClient.HomeSources, Error>? = nil,
                     early: ((HomeRow) -> Void)? = nil) async throws -> HomeContent {
        // Everything that doesn't depend on something else, at once: what
        // you're watching and what's new, and the trending titles with what
        // you've seen of them.
        let trendingIds = library.trending.prefix(100).map(\.id)
        async let trendingItems = emby.items(ids: trendingIds)
        let notableIds = library.notable.prefix(100).map(\.id)
        async let notableItems = emby.items(ids: notableIds)
        let sources: EmbyClient.HomeSources
        if let pending { sources = try await pending.value } else { sources = try await emby.homeSources() }
        // Top picks only need what was watched: asked for now, alongside the
        // charts' titles, not after them.
        let seeds = seeds(watching: sources.watching, played: sources.played)
        async let similarLists = Self.similar(emby, library: library, to: seeds.map(\.id))
        let ratings = library.ratings
        let thisYear = Calendar.current.component(.year, from: Date())

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
        if let row = emby.showRow("Continue Watching", resume, cardWidth) {
            rows.append(row)
            early?(row)
        }
        resume.forEach(show)

        // Trending titles on the server, with what this user has seen of them.
        let popular = await trendingItems.filter { !watched($0) && !isShown($0) && worthIt($0) }

        // New & notable: out within the last year (by release date when the
        // server has it, else this year's and last year's), well rated on
        // IMDb, most voted first. Also the featured pick's pool when
        // popularity hasn't downloaded yet.
        let yearAgo = Calendar.current.date(byAdding: .year, value: -1, to: Date()).map {
            $0.formatted(.iso8601.year().month().day())
        } ?? ""
        let today = Date().formatted(.iso8601.year().month().day())
        func outLastYear(_ item: EmbyItem) -> Bool {
            guard let date = item.premiereDate?.prefix(10) else { return true }
            return date >= yearAgo && date <= today
        }
        let fresh = await notableItems.filter { !watched($0) && outLastYear($0) }

        // Featured: popular and recent, with a backdrop to show. Before the
        // charts have downloaded (a new device), the newest additions, so the
        // top of Home is never empty.
        let added = popular.isEmpty && fresh.isEmpty
            ? await emby.recentlyAdded().filter { !watched($0) && !isShown($0) } : []
        let pool = (!popular.isEmpty ? popular : !fresh.isEmpty ? Array(fresh.prefix(20)) : added).filter { !isShown($0) }
        let withBackdrop = pool.filter { emby.backdropURL(for: $0, width: backdropWidth) != nil }
        // The same pick all day (one of the top few recent ones, by date),
        // so refreshing doesn't swap the top of the screen.
        let recent = withBackdrop.filter { ($0.productionYear ?? 0) >= thisYear - 1 }
        let choices = Array((recent.isEmpty ? withBackdrop : recent).prefix(5))
        let day = Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
        let pick = choices.isEmpty ? nil : choices[day % choices.count]
        func featuring(_ item: EmbyItem) -> Featured? {
            guard let backdrop = emby.backdropURL(for: item, width: backdropWidth) else { return nil }
            let poster = emby.card(item, context: .poster, shape: .portrait, width: cardWidth)
            return Featured(card: poster, backdrop: backdrop.absoluteString, details: details(item), overview: item.overview,
                            logo: emby.logoURL(for: item, width: 900)?.absoluteString)
        }
        let featured = pick.flatMap(featuring)
        // The hero's turn: today's pick first, then the other recent
        // popular titles with a backdrop. Each is on the page already, so
        // the rows below leave them out.
        let others = (recent.isEmpty ? withBackdrop : recent).prefix(6)
        let rotation = choices.isEmpty ? [] : (0..<choices.count).map { choices[(day + $0) % choices.count] }
        var spotlight: [Featured] = []
        for item in rotation + others where spotlight.count < 6 && !isShown(item) {
            guard let hero = featuring(item) else { continue }
            spotlight.append(hero)
            show(item)
        }

        // Top picks: titles like the five you watched last, one from each in
        // turn (IMDb's data ranking what's most alike within each).
        let similar = await similarLists
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
        for item in fresh where newRow.count < 20 && !isShown(item) {
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
        // Cut off halfway, the requests above came back empty: not a page.
        try Task.checkCancellation()
        return HomeContent(featured: featured, rows: rows, builtAt: Date(), history: seeds.map(\.id), spotlight: spotlight)
    }
}

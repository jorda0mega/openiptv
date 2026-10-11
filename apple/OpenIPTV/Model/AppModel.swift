import Foundation
import Observation

/// App state. Everything runs on the device, talking straight to the user's
/// Emby server and IPTV providers. Screens render from what's cached first
/// and refresh behind it; live titles refresh the second a programme ends.
@Observable
@MainActor
final class AppModel {
    let sources = SourceStore()
    let guide = GuideStore()
    let library = LibraryIndex()

    // MARK: Home (Emby)

    var rows: [HomeRow] = []
    var featured: Featured?
    var homeError: String?
    private var lastCardWidth = 360

    // MARK: Live TV

    private(set) var categories: [LiveCategory] = []
    private(set) var allChannels: [LiveChannel] = []
    private(set) var liveLoading = false
    var liveErrors: [String] = []
    var selectedCategory: String? {
        didSet { UserDefaults.standard.set(selectedCategory, forKey: "category") }
    }
    private(set) var nowNext: [String: NowNext] = [:]
    private(set) var guideState: GuideStore.State = .idle

    static let favoritesID = "__favorites"
    /// The channels of the area set in Settings.
    static let localID = "__local"

    private var providers: [UUID: any LiveProvider] = [:]
    private var channelsByCategory: [String: [LiveChannel]] = [:]
    private var channelById: [String: LiveChannel] = [:]
    /// Channel names prepared for instant search.
    private(set) var channelCorpus = SearchCorpus<LiveChannel>(name: \.name)
    /// Server search results by query, for episodes the index doesn't hold.
    private var serverSearchCache: [String: [Card]] = [:]
    /// Playback worked out ahead of a tap (Continue Watching, Next Up, an
    /// open show), so selecting it goes straight to the player.
    private var prepared: [String: (at: Date, task: Task<EmbyPlayback, Error>)] = [:]
    private var visible: Set<String> = []
    private var nowNextTask: Task<Void, Never>?
    private var boundaryTask: Task<Void, Never>?
    private var providerEPG: [String: (until: Int64, list: [Programme])] = [:]

    init() {
        #if DEBUG
        // Simulator testing with a real account: a temporary session passed
        // in by the launcher, kept in memory only. Not in release builds.
        if let raw = ProcessInfo.processInfo.environment["OPENREEL_DEBUG_EMBY"],
           let account = try? JSONDecoder().decode(EmbyAccount.self, from: Data(raw.utf8)) {
            sources.useTemporaryEmby(account)
        }
        #endif
        selectedCategory = UserDefaults.standard.string(forKey: "category")
        // Ready before the first film opens.
        DispatchQueue.global(qos: .userInitiated).async { StreamRelay.shared.start() }
        // v4: Top picks layout; older caches had other rows, and showing
        // one first would flash the old layout before the new.
        for old in ["home.json", "home.v2.json", "home.v3.json"] { AppCache.remove(old) }
        let home: HomeContent? = AppCache.read("home.v4.json")
        rows = home?.rows ?? []
        featured = home?.featured
        homeBuiltAt = home?.builtAt
        homeHistory = home?.history ?? []
        live.onChange = { [weak self] change in self?.apply(change) }
        Task { await guide.loadCache(); guideState = await guide.state }
    }

    var emby: EmbyClient? {
        sources.emby.map { EmbyClient(account: $0, deviceId: sources.deviceId) }
    }

    // MARK: Home

    /// `full`: rebuild every row. Otherwise, when the saved Home is recent
    /// (six hours), the catalog hasn't changed since and you haven't watched
    /// anything new elsewhere, only Continue Watching is fetched again.
    func loadHome(cardWidth: Int, sync: Bool = true, full: Bool = false) async {
        lastCardWidth = cardWidth
        guard let emby else {
            rows = []
            featured = nil
            return
        }
        connectLive()
        // Trending and versions come from the index and charts on the device.
        await library.open(emby)
        await library.loadCachedCharts()
        if !full, !rows.isEmpty, let builtAt = homeBuiltAt, Date().timeIntervalSince(builtAt) < 6 * 3600,
           library.changedAt.map({ $0 <= builtAt }) ?? true,
           await !refreshContinueWatching(checkingHistory: true) {
            if sync { Task { await syncLibrary(emby) } }
            return
        }
        do {
            let fresh = try await HomeFeed.load(emby, library: library, cardWidth: cardWidth,
                                                backdropWidth: Self.backdropWidth)
            // The pictures first (all at once), so the page changes in one go
            // instead of covers popping in; on the very first load, show the
            // rows straight away and let the pictures follow.
            let prefetch = Task { await ImagePipeline.shared.prefetch(Self.visibleImages(fresh)) }
            if !rows.isEmpty, fresh.rows != rows || fresh.featured != featured {
                _ = await withTaskGroup(of: Void.self) { group in
                    group.addTask { await prefetch.value }
                    group.addTask { try? await Task.sleep(for: .seconds(1.5)) }
                    await group.next()
                    group.cancelAll()
                }
            }
            if fresh.rows != rows { rows = fresh.rows }
            if fresh.featured != featured { featured = fresh.featured }
            homeBuiltAt = fresh.builtAt
            homeHistory = fresh.history ?? []
            homeError = nil
            AppCache.write("home.v4.json", fresh)
            // The first few things you'd tap on Home are ready before you do.
            let likely = (fresh.featured.map { [$0.card] } ?? []) + fresh.rows.prefix(2).flatMap { $0.cards.prefix(3) }
            prepare(likely.map { (id: $0.episodeId ?? $0.id, kind: Optional($0.episodeId != nil ? "Episode" : $0.kind)) })
            if sync { Task { await syncLibrary(emby) } }
        } catch {
            homeError = SourceError.wrap(error).localizedDescription
        }
    }

    /// Wide enough for Home's featured backdrop on any screen.
    private static let backdropWidth = 1920

    /// The pictures on Home's first screen and a half: the featured
    /// backdrop and the first cards of the first rows.
    private static func visibleImages(_ home: HomeContent) -> [URL] {
        let backdrop = home.featured.flatMap { URL(string: $0.backdrop) }.map { [$0] } ?? []
        let covers = home.rows.prefix(3).flatMap { $0.cards.prefix(6) }.compactMap { $0.images.first.flatMap { URL(string: $0.url) } }
        return backdrop + covers
    }

    /// Which copy of a title to play when there are several: the sharpest
    /// on Apple TV; on iPhone and iPad up to 1080p, which looks the same on
    /// their screens and starts sooner.
    #if os(tvOS)
    private static let maxWidth: Int? = nil
    #else
    private static let maxWidth: Int? = 1920
    #endif

    func playback(itemId: String, kind: String? = nil) async throws -> EmbyPlayback {
        let started = Date()
        let task: Task<EmbyPlayback, Error>
        if let ready = prepared[itemId], Date().timeIntervalSince(ready.at) < 180 {
            task = ready.task
        } else {
            guard let emby else { throw SourceError.unexpected("Add your Emby server in Settings.") }
            let versions = library.versions(of: itemId)
            task = Task { try await emby.playback(versions: versions, kind: kind, maxWidth: Self.maxWidth) }
        }
        prepared[itemId] = nil
        var playback = try await task.value
        playback.resolvedIn = Date().timeIntervalSince(started)
        playback.requestedAt = started
        return playback
    }

    // MARK: Shows

    /// A show page's data, kept so reopening (or opening something prepared
    /// ahead) draws at once; refreshed quietly behind.
    struct ShowData: Codable {
        let show: EmbyItem
        let episodes: [EmbyItem]
        let nextUp: EmbyItem?
        let loadedAt: Date
    }

    private(set) var shows: [String: ShowData] = [:]
    private var showLoads: [String: Task<ShowData?, Never>] = [:]

    /// The show's details, every episode and the next one to watch.
    /// A show's page as last seen: in memory, else saved on the device, so
    /// it opens at once (even after a relaunch) while it's brought up to date.
    func cachedShow(_ id: String) -> ShowData? {
        if let data = shows[id] { return data }
        guard let saved: ShowData = AppCache.read(Self.showFile(id)) else { return nil }
        shows[id] = saved
        return saved
    }

    private static func showFile(_ id: String) -> String { "show-\(id).json" }

    /// Brings a show up to date. Saved within the last day: only the
    /// episodes that changed since (usually none) and the next episode;
    /// otherwise everything (which also drops deleted episodes).
    func loadShow(_ id: String) async -> ShowData? {
        if let running = showLoads[id] { return await running.value }
        guard let emby else { return nil }
        let previous = cachedShow(id)
        let task = Task<ShowData?, Never> {
            if let previous, Date().timeIntervalSince(previous.loadedAt) < 24 * 3600 {
                async let changes = emby.episodeChanges(of: id, since: previous.loadedAt)
                async let next = emby.nextEpisode(of: id)
                if let changed = try? await changes {
                    return ShowData(show: previous.show, episodes: Self.merge(previous.episodes, changed),
                                    nextUp: (try? await next) ?? previous.nextUp, loadedAt: Date())
                }
            }
            async let item = emby.item(id)
            async let list = emby.episodes(of: id, season: nil)
            async let next = emby.nextEpisode(of: id)
            guard let show = try? await item, let episodes = try? await list else { return nil }
            return ShowData(show: show, episodes: episodes, nextUp: try? await next, loadedAt: Date())
        }
        showLoads[id] = task
        let data = await task.value
        showLoads[id] = nil
        if let data {
            if shows.count > 40 { shows.removeAll() }
            shows[id] = data
            let file = Self.showFile(id)
            Task.detached(priority: .utility) { AppCache.write(file, data) }
        }
        return data
    }

    /// Changed episodes replace their old selves; new ones join in order.
    private nonisolated static func merge(_ episodes: [EmbyItem], _ changed: [EmbyItem]) -> [EmbyItem] {
        guard !changed.isEmpty else { return episodes }
        let updates = Dictionary(changed.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var merged = episodes.map { updates[$0.id] ?? $0 }
        let known = Set(episodes.map(\.id))
        merged += changed.filter { !known.contains($0.id) }
        return merged.sorted { ($0.parentIndexNumber ?? 0, $0.indexNumber ?? 0) < ($1.parentIndexNumber ?? 0, $1.indexNumber ?? 0) }
    }

    /// What just played, applied to the saved show straight away (where
    /// it got to, or watched), so its page and Continue Watching are right
    /// before the server is asked.
    private func noteProgress(_ playback: EmbyPlayback, seconds: Double) {
        guard let series = playback.seriesId, let data = cachedShow(series),
              let index = data.episodes.firstIndex(where: { $0.id == playback.itemId }) else { return }
        var episodes = data.episodes
        let duration = playback.durationSeconds ?? 0
        let finished = duration > 0 && seconds >= duration * 0.9
        var user = episodes[index].userData ?? EmbyItem.UserData()
        user.played = finished ? true : user.played
        user.playbackPositionTicks = finished ? 0 : Int64(seconds * 1e7)
        user.playedPercentage = finished || duration == 0 ? nil : seconds / duration * 100
        user.lastPlayedDate = ISO8601DateFormatter().string(from: Date())
        episodes[index].userData = user
        // Keep loadedAt: the next update still asks for everything since.
        shows[series] = ShowData(show: data.show, episodes: episodes, nextUp: data.nextUp, loadedAt: data.loadedAt)
    }

    /// Loads shows the user is likely to open next, in the background.
    func prefetchShows(_ ids: [String], force: Bool = false) {
        for id in ids where force || cachedShow(id).map({ Date().timeIntervalSince($0.loadedAt) > 300 }) ?? true {
            Task(priority: .utility) { _ = await loadShow(id) }
        }
    }

    /// Continue Watching alone (two small requests), after watching
    /// something: the other rows stay put, minus anything now in it.
    /// `checkingHistory`: also ask what was finished lately, and return true
    /// (leaving the page alone) when Top picks' recent watches changed, so
    /// the caller rebuilds everything instead.
    @discardableResult
    func refreshContinueWatching(checkingHistory: Bool = false) async -> Bool {
        guard let emby else { return false }
        async let watching = emby.watching()
        async let nextUp = emby.nextUp()
        async let played: [EmbyItem]? = checkingHistory ? (try? await emby.played(limit: 10)) : nil
        guard let watching = try? await watching else { return false }
        if let played = await played,
           HomeFeed.seeds(watching: watching, played: played).map(\.id) != homeHistory {
            return true
        }
        let items = HomeFeed.continueItems(watching: watching, nextUp: (try? await nextUp) ?? [])
        let row = emby.showRow("Continue Watching", items, lastCardWidth)
        var updated = rows.filter { $0.title != "Continue Watching" }
        let resumed = Set(row?.cards.map(\.id) ?? [])
        updated = updated.map { other in
            HomeRow(title: other.title, shape: other.shape, aspect: other.aspect, cards: other.cards.filter { !resumed.contains($0.id) })
        }.filter { !$0.cards.isEmpty }
        if let row { updated.insert(row, at: 0) }
        if updated != rows { rows = updated }
        AppCache.write("home.v4.json", HomeContent(featured: featured, rows: rows, builtAt: homeBuiltAt, history: homeHistory))
        prepare(Array((row?.cards ?? []).prefix(4)).map { (id: $0.episodeId ?? $0.id, kind: Optional($0.episodeId != nil ? "Episode" : $0.kind)) })
        return false
    }

    // MARK: Live updates from Emby

    let live = EmbyLive()
    private var homeBuiltAt: Date?
    private var homeHistory: [String] = []
    /// What's playing now: its own progress reports don't refresh Home.
    private var playingItem: String?
    private var watchRefresh: Task<Void, Never>?
    private var libraryRefresh: Task<Void, Never>?

    /// Listen for changes while the app is in use.
    func connectLive() {
        guard let account = sources.emby else { return live.disconnect() }
        live.connect(account, deviceId: sources.deviceId)
    }

    func disconnectLive() { live.disconnect() }

    private func apply(_ change: EmbyLive.Change) {
        switch change {
        case let .watched(list):
            for change in list {
                // Its resume point moved: prepare it again when needed.
                if change.itemId != playingItem { prepared[change.itemId] = nil }
                patchShows(change)
            }
            // Mid-video these are its own progress reports; Home is
            // refreshed when it stops.
            guard playingItem == nil else { return }
            watchRefresh?.cancel()
            watchRefresh = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                await refreshContinueWatching()
            }
        case .library:
            libraryRefresh?.cancel()
            libraryRefresh = Task {
                // Additions come in bursts; let them settle.
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled, let emby else { return }
                await library.prepare(emby, now: true)
                await loadHome(cardWidth: lastCardWidth, sync: false, full: true)
            }
        }
    }

    /// A watched or progress change applied to any show saved in memory.
    private func patchShows(_ change: EmbyLive.WatchChange) {
        for (series, data) in shows {
            guard let index = data.episodes.firstIndex(where: { $0.id == change.itemId }) else { continue }
            var episodes = data.episodes
            var user = episodes[index].userData ?? EmbyItem.UserData()
            if let played = change.played { user.played = played }
            if let ticks = change.positionTicks { user.playbackPositionTicks = ticks }
            user.playedPercentage = change.playedPercentage
            episodes[index].userData = user
            shows[series] = ShowData(show: data.show, episodes: episodes, nextUp: data.nextUp, loadedAt: data.loadedAt)
        }
    }

    // MARK: Warm start

    /// The item most likely to be played next, already opened and paused at
    /// its resume point in a hidden player, so selecting it starts at once.
    /// `key` is what was tapped (a show for Play next episode); `playback`
    /// says which episode or movie is actually open.
    private var warm: (key: String, player: MPVPlayer, playback: EmbyPlayback)?
    private var warmExpiry: Task<Void, Never>?

    func warmUp(_ itemId: String, kind: String?, options: [(String, String)], hardwareDecoding: Bool) {
        guard warm?.key != itemId else { return }
        coolDown()
        prepare([(id: itemId, kind: kind)])
        Task {
            guard let playback = try? await prepared[itemId]?.task.value, warm == nil else { return }
            let player = MPVPlayer(options: options + [("pause", "yes")], hardwareDecoding: hardwareDecoding)
            player.prepareOffscreen()
            player.load(playback.url, headers: playback.headers, start: playback.startSeconds, file: true, readahead: .warm)
            warm = (itemId, player, playback)
            // Scrubbing thumbnails ready before the tap too.
            if trickplayCache[playback.itemId] == nil, let emby {
                Task { trickplayCache[playback.itemId] = await emby.trickplay(itemId: playback.itemId, mediaSourceId: playback.mediaSourceId) }
            }
            // Don't hold a connection open for long if it isn't wanted.
            warmExpiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                self?.coolDown()
            }
        }
    }

    /// Hands over the warmed-up player for this episode or movie, if any.
    func takeWarm(_ itemId: String) -> (MPVPlayer, EmbyPlayback)? {
        guard let warm, warm.playback.itemId == itemId else { return nil }
        self.warm = nil
        warmExpiry?.cancel()
        return (warm.player, warm.playback)
    }

    func coolDown() {
        warmExpiry?.cancel()
        warm?.player.shutdown()
        warm = nil
    }

    /// Works out how to play these in the background; a later tap uses it.
    func prepare(_ items: [(id: String, kind: String?)]) {
        guard let emby else { return }
        for (id, kind) in items where prepared[id].map({ Date().timeIntervalSince($0.at) >= 180 }) ?? true {
            let versions = library.versions(of: id)
            prepared[id] = (Date(), Task(priority: .utility) {
                try await emby.playback(versions: versions, kind: kind, maxWidth: Self.maxWidth)
            })
        }
    }

    /// The same item converted by the server at `bitrate`, from `start`.
    func convertedURL(for playback: EmbyPlayback, bitrate: Int, start: Double) -> URL? {
        emby?.hlsURL(playback.itemId, mediaSourceId: playback.mediaSourceId ?? playback.itemId,
                     playSessionId: playback.playSessionId, start: start, bitrate: bitrate)
    }

    /// Download speed (bits/s) last measured from this Emby server, to pick
    /// a starting quality that won't stall.
    var knownSpeed: Double? {
        get {
            #if DEBUG
            if let forced = ProcessInfo.processInfo.environment["OPENREEL_DEBUG_KNOWN_SPEED"].flatMap(Double.init) { return forced }
            #endif
            return sources.emby.map { UserDefaults.standard.double(forKey: "speed." + ($0.serverURL.host() ?? "")) }.flatMap { $0 > 0 ? $0 : nil }
        }
        set { if let host = sources.emby?.serverURL.host(), let newValue, newValue > 0 { UserDefaults.standard.set(newValue, forKey: "speed." + host) } }
    }

    /// Scrubbing thumbnails per item, fetched ahead for warmed-up items.
    private var trickplayCache: [String: TrickplayImages] = [:]

    func trickplay(for playback: EmbyPlayback) async -> TrickplayImages? {
        if let cached = trickplayCache[playback.itemId] { return cached }
        let images = await emby?.trickplay(itemId: playback.itemId, mediaSourceId: playback.mediaSourceId)
        if trickplayCache.count > 4 { trickplayCache.removeAll() }
        if let images { trickplayCache[playback.itemId] = images }
        return images
    }

    func diagnose(_ playback: EmbyPlayback) async -> String {
        await emby?.diagnose(playback) ?? ""
    }

    /// Loads (or quietly updates) the on-device library index. Called when
    /// the app opens; never blocks the UI.
    func prepareLibrary() async {
        if let emby { await syncLibrary(emby) }
    }

    private func syncLibrary(_ emby: EmbyClient) async {
        let before = library.trending.prefix(40).map(\.id)
        async let charts: Void = library.refreshCharts(unmetered: NetworkStatus.shared.unmetered)
        await library.prepare(emby)
        await charts
        // New titles since Home was built: rebuild its other rows.
        if let changed = library.changedAt, let built = homeBuiltAt, changed > built {
            await loadHome(cardWidth: lastCardWidth, sync: false, full: true)
            return
        }
        // Trending arrived for the first time (Home was built without it):
        // rebuild once. Otherwise the next visit or refresh picks it up,
        // rather than the page changing under you.
        if before.isEmpty, !library.trending.isEmpty { await loadHome(cardWidth: lastCardWidth, sync: false) }
    }

    func playback(for card: Card) async throws -> EmbyPlayback {
        try await playback(itemId: card.id, kind: card.kind)
    }

    func report(_ playback: EmbyPlayback, seconds: Double, event: EmbyClient.PlaybackEvent) async {
        if event == .started { playingItem = playback.itemId }
        if event == .stopped { playingItem = nil }
        await emby?.report(event, itemId: playback.itemId, seconds: seconds,
                           mediaSourceId: playback.mediaSourceId, playSessionId: playback.playSessionId)
        guard event == .stopped else { return }
        // Only this title's resume point changed: everything else prepared
        // stays ready.
        prepared[playback.itemId] = nil
        if warm?.key == playback.itemId { coolDown() }
        noteProgress(playback, seconds: seconds)
        if let series = playback.seriesId { prefetchShows([series], force: true) }
        // Only Continue Watching changed; the rest of Home stays as it is.
        await refreshContinueWatching()
    }

    // MARK: Accounts

    func signedInToEmby(_ account: EmbyAccount) async {
        sources.setEmby(account)
        await loadHome(cardWidth: lastCardWidth, full: true)
    }

    func signOutOfEmby() async {
        live.disconnect()
        await emby?.logout()
        sources.setEmby(nil)
        rows = []
        featured = nil
        AppCache.remove("home.v4.json")
        library.clear()
        serverSearchCache = [:]
    }

    func add(_ source: IPTVSource) async {
        sources.add(source)
        await loadLive(force: true)
    }

    func remove(_ source: IPTVSource) async {
        sources.remove(source)
        await loadLive(force: true)
    }

    func forgetEverything() async {
        await emby?.logout()
        sources.forgetEverything()
        await guide.clear()
        AppCache.remove(Self.lineupFile)
        library.clear()
        serverSearchCache = [:]
        channelCorpus = SearchCorpus(name: \.name)
        rows = []
        featured = nil
        AppCache.remove("home.v4.json")
        categories = []
        allChannels = []
        channelsByCategory = [:]
        channelById = [:]
        nowNext = [:]
        providers = [:]
        providerEPG = [:]
        selectedCategory = nil
        guideState = .idle
    }

    // MARK: Live TV

    /// Loads every source's lineup in parallel, then refreshes the full
    /// guide in the background if it's stale.
    /// The lineup saved on the device (names, logos, categories; never a
    /// URL that could hold a login) shows at once, then the providers'
    /// current one replaces it in the background.
    func loadLive(force: Bool = false) async {
        let iptv = sources.iptv
        guard !iptv.isEmpty else {
            categories = []
            allChannels = []
            channelsByCategory = [:]
            liveErrors = []
            return
        }
        if allChannels.isEmpty, let saved = await Self.savedLineup(), saved.sources == iptv.map(\.id) {
            await applyLineup(categories: saved.categories, channels: saved.channels)
            // Saved within the hour: good as it is (event categories are
            // fetched again on their own when opened).
            if let at = saved.savedAt, Date().timeIntervalSince(at) < 3600 { liveFetchedAt = at }
        }
        guard force || liveFetchedAt.map({ Date().timeIntervalSince($0) >= 3600 }) ?? true, !liveLoading else { return }
        liveLoading = true
        defer { liveLoading = false }
        providers = Dictionary(uniqueKeysWithValues: iptv.map { ($0.id, Providers.make($0)) })
        let multiple = iptv.count > 1
        var lineups: [(IPTVSource, Result<LiveLineup, Error>)] = []
        await withTaskGroup(of: (IPTVSource, Result<LiveLineup, Error>).self) { group in
            for source in iptv {
                let provider = providers[source.id]!
                group.addTask {
                    do { return (source, .success(try await provider.load())) } catch { return (source, .failure(error)) }
                }
            }
            for await result in group { lineups.append(result) }
        }
        let order = Dictionary(uniqueKeysWithValues: iptv.enumerated().map { ($1.id, $0) })
        lineups.sort { (order[$0.0.id] ?? 0) < (order[$1.0.id] ?? 0) }

        // A source that can't be reached keeps the channels it had (saved
        // or from earlier), so one failing provider doesn't empty the list.
        let previousCategories = categories, previousChannels = allChannels
        var cats: [LiveCategory] = []
        var channels: [LiveChannel] = []
        var errors: [String] = []
        var guideURLs: [URL] = []
        for (source, result) in lineups {
            switch result {
            case let .success(lineup):
                cats += lineup.categories.map {
                    LiveCategory(id: $0.id, name: multiple ? "\(source.name) · \($0.name)" : $0.name, channels: $0.channels)
                }
                channels += lineup.channels
                guideURLs += lineup.guideURLs
            case let .failure(error):
                errors.append("\(source.name): \(SourceError.wrap(error).localizedDescription)")
                cats += previousCategories.filter { $0.id.hasPrefix(source.id.uuidString + "|") }
                channels += previousChannels.filter { $0.sourceId == source.id }
            }
        }
        liveErrors = errors
        if !channels.isEmpty {
            await applyLineup(categories: cats, channels: channels)
            liveFetchedAt = Date()
            Self.saveLineup(sources: iptv.map(\.id), categories: cats, channels: channels)
        }

        let keep = Set(channels.compactMap(\.epgId))
        let stale = await guide.isStale()
        if !guideURLs.isEmpty, force || stale {
            guideState = .loading
            let guide = guide
            Task.detached {
                await guide.refresh(from: guideURLs, keep: keep)
                await self.guideDidUpdate()
            }
        }
    }

    private func guideDidUpdate() async {
        guideState = await guide.state
        // Re-evaluate visible rows against the new guide.
        nowNext = [:]
        providerEPG = [:]
        scheduleNowNext()
    }

    func channels(in category: String?, favorites: [LiveChannel], area: LocalArea? = nil) -> [LiveChannel] {
        if category == Self.favoritesID { return resolved(favorites) }
        if category == Self.localID { return area.map(localChannels) ?? [] }
        return channelsByCategory[category ?? ""] ?? []
    }

    /// The area's stations from the providers' local categories (US | Local
    /// ABC, NBC…): its city's first, then by network.
    func localChannels(_ area: LocalArea) -> [LiveChannel] {
        let local = Set(categories.filter { $0.name.localizedCaseInsensitiveContains("local") }.map(\.id))
        let networks = ["ABC", "CBS", "NBC", "FOX", "CW", "MY", "PBS", "TELEMUNDO", "UNIVISION"]
        func network(_ name: String) -> Int {
            let upper = name.uppercased()
            return networks.firstIndex { upper.contains($0) } ?? networks.count
        }
        let city = area.city?.lowercased()
        return allChannels
            .filter { local.contains($0.categoryId ?? "") && area.includes($0.name) }
            .sorted { first, second in
                let a = city.map { first.name.lowercased().contains($0) } ?? false
                let b = city.map { second.name.lowercased().contains($0) } ?? false
                if a != b { return a }
                let na = network(first.name), nb = network(second.name)
                return na != nb ? na < nb : first.name.localizedStandardCompare(second.name) == .orderedAscending
            }
    }

    // MARK: Saved lineup

    /// When the providers' lineup was last fetched (or saved, if recent).
    private var liveFetchedAt: Date?
    private var categoryFetchedAt: [String: Date] = [:]

    private struct SavedLineup: Codable {
        let sources: [UUID]
        let categories: [LiveCategory]
        let channels: [LiveChannel]
        var savedAt: Date?
    }

    /// Event and PPV categories are renamed for every game: the one being
    /// looked at is fetched again on its own (at most every 5 minutes),
    /// instead of the whole lineup.
    func refreshCategory(_ id: String?) async {
        guard let id, id != Self.favoritesID, id != Self.localID,
              let category = categories.first(where: { $0.id == id }), Self.isEventCategory(category.name),
              categoryFetchedAt[id].map({ Date().timeIntervalSince($0) >= 300 }) ?? true,
              let sourceId = id.split(separator: "|").first.flatMap({ UUID(uuidString: String($0)) }),
              let provider = providers[sourceId] ?? sources.iptv.first(where: { $0.id == sourceId }).map(Providers.make),
              let fresh = try? await provider.channels(inCategory: id)
        else { return }
        categoryFetchedAt[id] = Date()
        guard fresh != channelsByCategory[id] else { return }
        let channels = allChannels.filter { $0.categoryId != id } + fresh
        await applyLineup(categories: categories, channels: channels)
        Self.saveLineup(sources: sources.iptv.map(\.id), categories: categories, channels: channels)
    }

    private static func isEventCategory(_ name: String) -> Bool {
        let upper = name.uppercased()
        return ["PPV", "EVENT", "NFL", "NBA", "NHL", "MLB", "MLS", "UFC", "BOXING", "DAZN", "ESPN+", "PEACOCK", "FLO",
                "NCAA", "KAYO", "PARAMOUNT+", "MAX", "FANATIZ", "TSN+", "VICTORY+", "SEC+", "BIG TEN+", "FIFA+", "F1 TV", "LIVE"]
            .contains { upper.contains($0) }
    }

    private static let lineupFile = "live-lineup.v1.json"

    private func applyLineup(categories cats: [LiveCategory], channels: [LiveChannel]) async {
        categories = cats
        allChannels = channels
        channelCorpus = await Task.detached(priority: .userInitiated) { SearchCorpus(channels, name: \.name) }.value
        channelsByCategory = Dictionary(grouping: channels, by: { $0.categoryId ?? "" })
        channelById = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if selectedCategory == nil || (selectedCategory != Self.favoritesID && selectedCategory != Self.localID
                                       && !cats.contains { $0.id == selectedCategory }) {
            selectedCategory = cats.first?.id
        }
    }

    private nonisolated static func savedLineup() async -> SavedLineup? {
        await Task.detached(priority: .userInitiated) { AppCache.read(lineupFile) as SavedLineup? }.value
    }

    /// Playlist stream URLs can hold a login, so they're saved blank and
    /// the providers' current lineup supplies them.
    private nonisolated static func saveLineup(sources: [UUID], categories: [LiveCategory], channels: [LiveChannel]) {
        Task.detached(priority: .utility) {
            AppCache.write(lineupFile, SavedLineup(sources: sources, categories: categories,
                                                   channels: channels.map(\.withoutSecrets), savedAt: Date()))
        }
    }

    /// Swap saved channels for their current lineup entries (fresh stream
    /// references, names and logos) where the lineup has them.
    func resolved(_ channels: [LiveChannel]) -> [LiveChannel] {
        channels.map { channelById[$0.id] ?? $0 }
    }

    /// Episodes and anything the on-device index doesn't hold yet, from the
    /// Emby server. Answers are kept for the session so retyping is instant.
    func serverSearch(_ query: String, cardWidth: Int) async -> [Card] {
        let key = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard key.count >= 2, let emby else { return [] }
        if let cached = serverSearchCache[key] { return cached }
        guard let cards = try? await emby.search(key, cardWidth: cardWidth) else { return [] }
        serverSearchCache[key] = cards
        return cards
    }

    func card(for entry: LibraryEntry, width: Int, with person: String? = nil) -> Card? {
        guard let card = emby?.card(for: entry, width: width, rating: library.rating(entry)) else { return nil }
        return person.map { card.adding("with " + $0) } ?? card
    }

    /// A search card for a title found through someone in it.
    func card(for item: EmbyItem, width: Int, with person: String) -> Card? {
        guard let emby else { return nil }
        let base = emby.card(item, context: .poster, shape: .portrait, width: width)
        let details = [item.kind == "Series" ? "Show" : "Movie", item.productionYear.map(String.init),
                       library.ratings?.rating(item.imdb).map(IMDbRatings.label), "with " + person]
        return Card(id: base.id, kind: base.kind, title: base.title, subtitle: details.compactMap(\.self).joined(separator: " · "),
                    images: base.images, progress: nil, playable: base.playable)
    }

    // MARK: Search across cast

    /// Actors and directors of titles checked so far this session.
    private var castCache: [String: [String]] = [:]

    /// The server part of a search. Titles waiting for a cast check keep
    /// only if each leftover word is in an actor's or director's name
    /// (noting whom), and people named by the query bring their titles
    /// ("antonio banderas"), the asked year's and the most popular first.
    func refine(_ query: SearchQuery, hits: [SearchHit]) async -> (hits: [SearchHit], people: [(item: EmbyItem, person: String)]) {
        guard let emby else { return (hits.filter { $0.pending.isEmpty }, []) }
        let unknown = hits.filter { !$0.pending.isEmpty && castCache[$0.entry.id] == nil }.map(\.entry.id)
        async let castLists = emby.people(of: Array(unknown.prefix(40)))
        async let persons = query.words.isEmpty ? [] : emby.persons(matching: query.title)
        for (id, people) in await castLists {
            castCache[id] = people.filter { [nil, "Actor", "Director", "GuestStar"].contains($0.type) }.prefix(25).map(\.name)
        }
        var refined: [SearchHit] = []
        for var hit in hits {
            guard !hit.pending.isEmpty else { refined.append(hit); continue }
            guard let cast = castCache[hit.entry.id] else { continue }
            let found = hit.pending.compactMap { word in cast.first { SearchQuery.startsWord(word, in: $0) } }
            guard found.count == hit.pending.count else { continue }
            hit.pending = []
            hit.person = found.first
            refined.append(hit)
        }
        var people: [(item: EmbyItem, person: String)] = []
        if let person = await persons.first {
            let popularity = library.popularity
            people = await emby.titles(withPerson: person.id)
                .map { (item: $0, person: person.name) }
                .sorted {
                    let a = query.yearDistance($0.item.productionYear), b = query.yearDistance($1.item.productionYear)
                    if a != b { return a < b }
                    let pa = popularity?.popularity($0.item.tmdb, $0.item.kind == "Series" ? .show : .movie) ?? 0
                    let pb = popularity?.popularity($1.item.tmdb, $1.item.kind == "Series" ? .show : .movie) ?? 0
                    return pa > pb
                }
        }
        return (refined, people)
    }

    func playable(_ channel: LiveChannel) async throws -> PlayableStream {
        let channel = channelById[channel.id] ?? channel
        if case let .url(url, _, _) = channel.stream, url.scheme == "about" {
            throw SourceError.unexpected("Channels are still loading; try again in a moment.")
        }
        let provider = providers[channel.sourceId]
            ?? sources.iptv.first(where: { $0.id == channel.sourceId }).map(Providers.make)
        guard let provider else { throw SourceError.unexpected("This channel's source was removed.") }
        do {
            return try await provider.playable(channel)
        } catch {
            throw SourceError.wrap(error)
        }
    }

    // MARK: Now / next

    func appeared(_ id: String) {
        visible.insert(id)
        scheduleNowNext()
    }

    func disappeared(_ id: String) {
        visible.remove(id)
    }

    func ensureNowNext(_ channels: [LiveChannel]) async {
        await resolveNowNext(channels.filter { nowNext[$0.id].map(\.isStale) ?? true })
    }

    private func scheduleNowNext() {
        nowNextTask?.cancel()
        nowNextTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled else { return }
            let stale = self.visible.compactMap { self.channelById[$0] }.filter { self.nowNext[$0.id].map(\.isStale) ?? true }
            await self.resolveNowNext(stale)
            self.scheduleBoundary()
        }
    }

    /// Full guide first (placeholder titles don't count), then the
    /// provider's own short EPG, cached until it expires.
    private func resolveNowNext(_ channels: [LiveChannel]) async {
        guard !channels.isEmpty else { return }
        let now = Int64(Date().timeIntervalSince1970)
        var needProvider: [LiveChannel] = []
        for channel in channels {
            if let id = channel.epgId, let fromGuide = await guide.nowNext(id, at: now),
               let title = fromGuide.now?.title, !NowNext.isPlaceholder(title) {
                nowNext[channel.id] = fromGuide
            } else {
                needProvider.append(channel)
            }
        }
        var fetch: [(LiveChannel, any LiveProvider)] = []
        for channel in needProvider {
            if let cached = providerEPG[channel.id], now < cached.until {
                nowNext[channel.id] = .from(cached.list, at: now, source: .provider)
            } else if let provider = providers[channel.sourceId] {
                fetch.append((channel, provider))
            }
        }
        await withTaskGroup(of: (String, [Programme]).self) { group in
            for (channel, provider) in fetch {
                group.addTask { (channel.id, await provider.shortEPG(for: channel)) }
            }
            for await (id, list) in group {
                let value = NowNext.from(list, at: now, source: .provider)
                providerEPG[id] = (value.refreshAt ?? now + 300, list)
                nowNext[id] = value
            }
        }
    }

    /// One timer for the earliest programme change among visible channels.
    private func scheduleBoundary() {
        boundaryTask?.cancel()
        guard let next = visible.compactMap({ nowNext[$0]?.refreshAt }).min() else { return }
        let delay = max(1, Double(next) - Date().timeIntervalSince1970 + 1.5)
        boundaryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.scheduleNowNext()
        }
    }
}

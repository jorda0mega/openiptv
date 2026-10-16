import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// App state. Everything runs on the device, talking straight to the user's
/// Emby server and IPTV providers. Screens render from what's cached first
/// and refresh behind it; live titles refresh the second a programme ends.
@Observable
@MainActor
final class AppModel {
    let sources = SourceStore()
    let guide = GuideStore()
    let library = LibraryIndex()

    /// "Go to Show" in the player: the show's page to open as the player
    /// closes (on Home, unless that page is the one under the player).
    var showRequest: ShowRoute?
    /// The show whose page is on screen, if any.
    var showOnScreen: String?
    /// The same for a film ("Details" in the player's Continue Watching).
    var movieRequest: MovieRoute?
    var movieOnScreen: String?

    // MARK: Home (Emby)

    var rows: [HomeRow] = []
    var featured: Featured?
    /// Apple TV's hero titles (see HomeContent.spotlight).
    var spotlight: [Featured] = []
    var homeError: String?
    private var lastCardWidth = 360
    /// The viewer's My List (Emby's favorites), newest first, and which
    /// titles are on it (nil: not loaded yet).
    private(set) var myList: [Card] = []
    private(set) var myListIDs: Set<String>?
    /// My List's copies of each title (an HD and a 4K film are one title,
    /// one card): the ids on the server's list, by each key the title is
    /// known by.
    @ObservationIgnored private var myListCopies: [String: Set<String>] = [:]

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
    /// Live TV by what's on (Sports, News, Movies…), one entry per channel;
    /// see LiveOrganizer.
    private(set) var liveLibrary = LiveOrganizer.Library()
    /// The channel to play for each guide id (the best copy), for guide
    /// search; and channels from abroad, listed after the rest.
    @ObservationIgnored private var guideChannels: [String: LiveChannel] = [:]
    @ObservationIgnored private var abroad: Set<String> = []
    /// Channels that wouldn't start, and when: games try others first.
    @ObservationIgnored private var liveFailures: [String: Date] = [:]
    /// Games that played on none of their channels, and when: their rows say
    /// so for half an hour instead of LIVE.
    private(set) var gamesNotPlaying: [String: Date] = [:]
    /// A provider category chosen from the full list (rather than a shelf):
    /// kept until the lineup next loads.
    var browsingProviderCategory = false
    private var refreshingEvents = false

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
    private var prepared: [String: (at: Date, task: Task<EmbyPlayback, Error>, copies: [String])] = [:]
    private var visible: Set<String> = []
    /// The rows just below the last one scrolled to, fetched ahead.
    private var lookahead: [String] = []
    private var resolving: Set<String> = []
    private var nowNextScheduled = false
    private var nowNextForced = false
    @ObservationIgnored private var slots: [String: NowNextSlot] = [:]
    @ObservationIgnored private var localCache: (area: LocalArea, channels: [LiveChannel])?
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
        if let raw = ProcessInfo.processInfo.environment["OPENREEL_DEBUG_IPTV"],
           let source = try? JSONDecoder().decode(IPTVSource.self, from: Data(raw.utf8)) {
            sources.useTemporaryIPTV(source)
        }
        // Real-feed UI tests: the logins from a helper on the Mac. Only its
        // address goes in the launch environment, which the simulator's
        // system log records.
        let environment = ProcessInfo.processInfo.environment
        if let data = environment["OPENREEL_DEBUG_EMBY_URL"].flatMap(Self.debugFetch),
           let account = try? JSONDecoder().decode(EmbyAccount.self, from: data) {
            sources.useTemporaryEmby(account)
        }
        if let data = environment["OPENREEL_DEBUG_IPTV_URL"].flatMap(Self.debugFetch),
           let source = try? JSONDecoder().decode(IPTVSource.self, from: data) {
            sources.useTemporaryIPTV(source)
        }
        #endif
        selectedCategory = UserDefaults.standard.string(forKey: "category")
        // Ready before the first film opens.
        DispatchQueue.global(qos: .userInitiated).async { StreamRelay.shared.start() }
        MPVPlayer.warmUp()
        // v4: Top picks layout; older caches had other rows, and showing
        // one first would flash the old layout before the new.
        for old in ["home.json", "home.v2.json", "home.v3.json"] { AppCache.remove(old) }
        // Lineups saved before v3 could hold a provider's "Account Info"
        // channels, which spell out the login.
        for old in ["live-lineup.v1.json", "live-lineup.v2.json"] { AppCache.remove(old) }
        let home: HomeContent? = AppCache.read("home.v4.json")
        rows = home?.rows ?? []
        featured = home?.featured
        spotlight = home?.spotlight ?? []
        homeBuiltAt = home?.builtAt
        #if DEBUG
        // UI tests (OPENREEL_DEBUG_HOME_STALE): the saved Home is old, so the
        // launch builds every row again.
        if ProcessInfo.processInfo.environment["OPENREEL_DEBUG_HOME_STALE"] != nil { homeBuiltAt = .distantPast }
        #endif
        homeHistory = home?.history ?? []
        shownBuiltAt = home?.builtAt
        shownHistory = home?.history ?? []
        // A launch is a moment Home may change: a build ready in the
        // first seconds goes straight on the page.
        homeAwaitsFirstBuild = true
        observeAppState()
        // Watching the connection from the start (speculative work waits
        // until it's known to be unmetered).
        _ = NetworkStatus.shared
        // Title pages not visited in a month.
        AppCache.prune(startingWith: ["show-", "movie-"], olderThan: 30)
        Task.detached(priority: .background) { AppCache.removeStaleDownloads() }
        // The first screen's pictures, decoded from the disk cache while the
        // app is still drawing its first frame, so Home opens with them.
        if let home {
            let urls = Self.visibleImages(home)
            Task.detached(priority: .userInitiated) { await ImagePipeline.shared.prefetch(urls) }
        }
        live.onChange = { [weak self] change in self?.apply(change) }
        Task { await guide.loadCache(); guideState = await guide.state }
    }

    var emby: EmbyClient? {
        sources.emby.map { EmbyClient(account: $0, deviceId: sources.deviceId) }
    }

    // MARK: Home

    /// The Home build in progress. Leaving Home cancels the page's task but
    /// not this, so a build cut off halfway (its rows fetched as empty)
    /// never replaces the page.
    @ObservationIgnored private var homeLoad: Task<Void, Never>?
    @ObservationIgnored private var homeLoadID = UUID()

    /// Home doesn't change while you look at it, like Netflix's: a Home
    /// built in the background (new titles, the charts, IMDb's catalog, a
    /// server's change) waits here for a moment the page may change. The
    /// moments: a launch or coming back after a long time away (a build
    /// ready in the first seconds), a pull to refresh, and Home chosen from
    /// another tab. Its Continue Watching is the newest the server gave.
    @ObservationIgnored private var stagedHome: HomeContent?
    /// After a launch or a long time away, the first Home built goes
    /// straight on the page, however long the server takes, unless the
    /// viewer has started browsing it meanwhile (then it waits for the next
    /// moment). One per launch: later builds wait. (A five-second window
    /// left a slow server's first build hidden until another tab.)
    @ObservationIgnored private var homeAwaitsFirstBuild = false
    /// Until when Continue Watching's cards may move, appear or go: just
    /// after the player closed, until the server's answer for that stop.
    @ObservationIgnored private var continueMovesUntil: Date?
    /// When the page on screen was built, and the recent watches its Top
    /// picks came from (what's saved; `homeBuiltAt` is the newest build,
    /// waiting or shown). Watched: see `homePending`.
    private var shownBuiltAt: Date?
    @ObservationIgnored private var shownHistory: [String] = []

    /// The first Home is being built (nothing built shown yet, no error):
    /// the page keeps the hero's space meanwhile.
    var homePending: Bool {
        sources.emby != nil && shownBuiltAt == nil && homeError == nil && featured == nil && spotlight.isEmpty
    }
    /// When the app last went to the background.
    @ObservationIgnored private var backgroundedAt: Date?
    /// The card width My List was last loaded at (iPhone, iPad, Apple TV).
    @ObservationIgnored private var myListWidth: Int?
    /// Away this long, coming back is like a launch for Home.
    private static var longAway: TimeInterval {
        #if DEBUG
        // UI tests (OPENREEL_DEBUG_LONG_AWAY=seconds): a shorter time away.
        if let seconds = ProcessInfo.processInfo.environment["OPENREEL_DEBUG_LONG_AWAY"].flatMap(Double.init) { return seconds }
        #endif
        return 30 * 60
    }

    /// `full`: rebuild every row. Otherwise, when the newest Home is recent
    /// (six hours), the catalog hasn't changed since and you haven't watched
    /// anything new elsewhere, only Continue Watching is fetched again.
    /// `show`: put the result on the page when it's ready (pull to refresh,
    /// a new account); otherwise it waits for the next moment, unless Home
    /// is still opening.
    /// One build at a time: a full one waits for the one before, any other
    /// joins it.
    func loadHome(cardWidth: Int, sync: Bool = true, full: Bool = false, show: Bool = false) async {
        if let running = homeLoad, !full { return await running.value }
        let previous = homeLoad
        let id = UUID()
        homeLoadID = id
        let load = Task {
            await previous?.value
            await buildHome(cardWidth: cardWidth, sync: sync, full: full, show: show)
            if homeLoadID == id { homeLoad = nil }
        }
        homeLoad = load
        await load.value
    }

    /// Home came on screen from another tab (or first, at launch): what
    /// was built meanwhile goes on now, before the page is drawn.
    func homeAppeared() {
        showStagedHome()
    }

    /// Try Again after Home failed: every row built afresh, and shown.
    func refreshHome(cardWidth: Int) async {
        await loadHome(cardWidth: cardWidth, full: true, show: true)
    }

    /// Whether a build may go straight on the page: Home is still opening,
    /// or has nothing built on it yet (only Continue Watching, or nothing).
    private var homeOpening: Bool {
        homeAwaitsFirstBuild || shownBuiltAt == nil || rows.isEmpty
    }

    /// The viewer scrolled Home or moved along it: what's built from now
    /// on waits for the next moment.
    func homeBrowsed() {
        homeAwaitsFirstBuild = false
    }

    private func buildHome(cardWidth: Int, sync: Bool, full: Bool, show: Bool) async {
        lastCardWidth = cardWidth
        let account = accountGeneration
        guard let emby else {
            rows = []
            featured = nil
            spotlight = []
            stagedHome = nil
            return
        }
        connectLive()
        // Trending and versions come from the index and charts on the
        // device: opened while Continue Watching is asked of the server, not
        // before it.
        async let opened: Void = openLibrary(emby)
        var pendingSources: Task<EmbyClient.HomeSources, Error>?
        // A page with no featured title is rebuilt: it was made before
        // anything could be picked (or by a build that was cut off). The
        // newest Home decides (one waiting, else the one shown).
        let newestFeatured = stagedHome.map(\.featured) ?? featured
        if !full, !rows.isEmpty, newestFeatured != nil, let builtAt = homeBuiltAt, Date().timeIntervalSince(builtAt) < 6 * 3600 {
            async let historyChanged = refreshContinueWatching(checkingHistory: true)
            await opened
            if library.changedAt.map({ $0 <= builtAt }) ?? true, await !historyChanged {
                if sync { Task { await syncLibrary(emby) } }
                return
            }
        } else {
            // Building Home afresh: what's being watched is asked for while
            // the index and charts open.
            pendingSources = Task { try await emby.homeSources() }
            await opened
        }
        do {
            // Nothing on Home yet (first launch, just signed in): Continue
            // Watching shows as soon as it's known; the rest follows.
            let empty = rows.isEmpty
            var fresh = try await HomeFeed.load(emby, library: library, cardWidth: cardWidth,
                                                backdropWidth: Self.backdropWidth, sources: pendingSources,
                                                early: { [weak self] row in
                                                    guard let self, empty, self.rows.isEmpty, account == self.accountGeneration else { return }
                                                    self.rows = [row]
                                                })
            fresh.rows = variedForTests(fresh.rows)
            // The pictures first (all at once), so the page changes in one go
            // instead of covers popping in; on the very first load, show the
            // rows straight away and let the pictures follow. A Home that
            // waits has them ready when it goes on.
            let prefetch = Task { await ImagePipeline.shared.prefetch(Self.visibleImages(fresh)) }
            // Then every other cover on Home into the disk cache (Wi-Fi),
            // so rows further down don't fill in as they scroll into view.
            if NetworkStatus.shared.knownUnmetered {
                let rest = fresh.rows.flatMap(\.cards).compactMap { $0.images.first.flatMap { URL(string: $0.url) } }
                Task(priority: .utility) {
                    await prefetch.value
                    await ImagePipeline.shared.store(rest)
                }
            }
            homeBuiltAt = fresh.builtAt
            homeHistory = fresh.history ?? []
            homeError = nil
            // Signed out or into another account meanwhile: not its Home.
            guard account == accountGeneration else { return }
            if show || homeOpening {
                // The hero's titles too: a new one undecoded showed black
                // for a moment.
                if !rows.isEmpty, fresh.rows != rows || fresh.featured != featured || (fresh.spotlight ?? []) != spotlight {
                    await Self.wait(for: prefetch, atMost: 1.5)
                }
                guard account == accountGeneration else { return }
                homeAwaitsFirstBuild = false
                showHome(fresh)
            } else {
                stageHome(fresh)
            }
            // The first few things you'd tap on Home are ready before you do:
            // how to play them, and their pages.
            let likely = (fresh.featured.map { [$0.card] } ?? []) + fresh.rows.prefix(2).flatMap { $0.cards.prefix(3) }
            let pages = (fresh.spotlight ?? []).map(\.card) + fresh.rows.prefix(2).flatMap { $0.cards.prefix(4) }
            pages.forEach(prefetchTitle)
            prepareRotation()
            prepare(likely.map { (id: $0.episodeId ?? $0.id, kind: Optional($0.episodeId != nil ? "Episode" : $0.kind)) })
            if sync { Task { await syncLibrary(emby) } }
        } catch {
            homeError = SourceError.wrap(error).localizedDescription
        }
    }

    /// Puts a built Home on the page, and saves it as shown (with this
    /// device's stops), not as the server still had it.
    private func showHome(_ fresh: HomeContent) {
        stagedHome = nil
        // What was just stopped here, even if the server hasn't caught up.
        let freshRows = withStops(fresh.rows)
        if freshRows != rows { rows = freshRows }
        if fresh.featured != featured { featured = fresh.featured }
        if (fresh.spotlight ?? []) != spotlight { spotlight = fresh.spotlight ?? [] }
        shownBuiltAt = fresh.builtAt
        shownHistory = fresh.history ?? []
        saveShownHome()
    }

    /// Keeps a built Home for the next moment. Its Continue Watching's
    /// progress shows at once when only that changed.
    private func stageHome(_ fresh: HomeContent) {
        stagedHome = fresh
        offerContinue(reconciled(fresh.rows.first { $0.title == Self.continueTitle }))
    }

    /// The Home waiting, on the page now (a moment it may change).
    private func showStagedHome() {
        guard let staged = stagedHome else { return }
        showHome(staged)
    }

    private func saveShownHome() {
        AppCache.save("home.v4.json", HomeContent(featured: featured, rows: rows, builtAt: shownBuiltAt,
                                                  history: shownHistory, spotlight: spotlight))
    }

    /// Back from the background: after a long time away (half an hour),
    /// Home opens again as at a launch.
    private func observeAppState() {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.backgroundedAt = Date() }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cameBack() }
        }
        #endif
    }

    private func cameBack() {
        guard let away = backgroundedAt.map({ Date().timeIntervalSince($0) }), away >= Self.longAway else { return }
        homeAwaitsFirstBuild = true
        showStagedHome()
        guard emby != nil else { return }
        Task { await loadHome(cardWidth: lastCardWidth) }
    }

    /// UI tests, debug builds (OPENREEL_DEBUG_HOME_VARY): each Home built
    /// comes with its cards in another order and its number after each
    /// row's name ("Trending now ·12"), and each Continue Watching fetched
    /// in another order, so one put on the page while you look would show.
    /// Otherwise the rows as they are.
    private func variedForTests(_ rows: [HomeRow], numbered: Bool = true) -> [HomeRow] {
        #if DEBUG
        guard ProcessInfo.processInfo.environment["OPENREEL_DEBUG_HOME_VARY"] != nil else { return rows }
        let build = UserDefaults.standard.integer(forKey: "debugHomeBuild") + 1
        UserDefaults.standard.set(build, forKey: "debugHomeBuild")
        return rows.map { row in
            let turn = row.cards.isEmpty ? 0 : build % row.cards.count
            let title = numbered && row.title != Self.continueTitle ? "\(row.title) ·\(build)" : row.title
            return HomeRow(title: title, shape: row.shape, aspect: row.aspect, cards: Array(row.cards[turn...] + row.cards[..<turn]))
        }
        #else
        return rows
        #endif
    }

    private func openLibrary(_ emby: EmbyClient) async {
        await library.open(emby)
        await library.loadCachedCharts()
    }

    /// Waits for `task`, but no longer than `seconds` (a task group can't do
    /// this: it waits for every child, and a task's value ignores cancel).
    private static func wait(for task: Task<Void, Never>, atMost seconds: Double) async {
        let first = AsyncStream<Void> { done in
            Task { await task.value; done.yield() }
            Task { try? await Task.sleep(for: .seconds(seconds)); done.yield() }
        }
        for await _ in first { break }
    }

    /// Wide enough for Home's featured backdrop on any screen.
    private static let backdropWidth = 1920

    /// The pictures on Home's first screen and a half: the featured
    /// backdrop and the first cards of the first rows.
    private static func visibleImages(_ home: HomeContent) -> [URL] {
        // Every title the hero turns to (backdrop and logo), so each
        // arrives complete instead of filling in as it shows.
        let heroes = (home.featured.map { [$0] } ?? []) + (home.spotlight ?? [])
        let art = heroes.flatMap { [URL(string: $0.backdrop), $0.logo.flatMap { URL(string: $0) }].compactMap(\.self) }
        let covers = home.rows.prefix(3).flatMap { $0.cards.prefix(6) }.compactMap { $0.images.first.flatMap { URL(string: $0.url) } }
        var seen = Set<URL>()
        return (art + covers).filter { seen.insert($0).inserted }
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
        // Just closed here, and kept: no need to ask the server anything.
        if let warm, warm.parked, warm.key == itemId {
            var playback = warm.playback
            playback.resolvedIn = 0
            playback.requestedAt = started
            return playback
        }
        let task: Task<EmbyPlayback, Error>
        // Worked out with the copies known now (one prepared before the
        // library was read knew a single copy: a film's other copy, in the
        // language wanted, was passed over).
        if let ready = prepared[itemId], Date().timeIntervalSince(ready.at) < 180, ready.copies == library.versions(of: itemId) {
            task = ready.task
        } else {
            guard let emby else { throw SourceError.unexpected("Add your Emby server in Settings.") }
            let versions = library.versions(of: itemId)
            let shows = showCopies
            task = Task { try await emby.playback(versions: versions, kind: kind, maxWidth: Self.maxWidth, showCopies: shows) }
        }
        prepared[itemId] = nil
        var playback: EmbyPlayback
        do {
            playback = try await task.value
            // Got ready without the server's track list (it didn't answer
            // then): asked again now, or it plays with no subtitle files.
            // Regression: a title got ready at launch played without them.
            if !playback.listed, let emby {
                playback = (try? await emby.playback(versions: library.versions(of: itemId), kind: kind, maxWidth: Self.maxWidth,
                                                     showCopies: showCopies)) ?? playback
            }
        } catch {
            // Worked out ahead and failed then (a moment's network trouble):
            // ask again now rather than fail the tap.
            guard let emby else { throw error }
            playback = try await emby.playback(versions: library.versions(of: itemId), kind: kind, maxWidth: Self.maxWidth,
                                               showCopies: showCopies)
        }
        playback = withLocalResume(playback)
        playback.resolvedIn = Date().timeIntervalSince(started)
        playback.requestedAt = started
        return playback
    }

    /// The title in its copy heard in `language` (picked in the audio menu,
    /// only another copy has it), from `seconds`: the pick is kept for
    /// every copy, so the copies are chosen again with it.
    func playback(heardIn language: String, instead current: EmbyPlayback, from seconds: Double) async throws -> EmbyPlayback {
        guard let emby else { throw SourceError.unexpected("Add your Emby server in Settings.") }
        TrackChoice.rememberAudio(language, role: nil, for: current.trackKeys)
        var next = try await emby.playback(versions: current.copyIds, kind: current.copyKind, maxWidth: Self.maxWidth)
        next.startSeconds = seconds
        next.requestedAt = Date()
        return next
    }

    /// A show's copies by its id (another library's), to find an episode
    /// in each of them.
    private var showCopies: @Sendable (String) -> [String] {
        let versions = library.versions
        return { versions[$0] ?? [$0] }
    }

    // MARK: Shows

    /// A show page's data, kept so reopening (or opening something prepared
    /// ahead) draws at once; refreshed quietly behind.
    struct ShowData: Codable, Equatable {
        /// With its cast, crew and genres.
        let show: EmbyItem
        let episodes: [EmbyItem]
        let nextUp: EmbyItem?
        let loadedAt: Date
        /// Shows like it (nil in pages saved before it was kept).
        var similar: [EmbyItem]? = nil
    }

    /// Not observed as a whole: a page watches its own title's state (see
    /// `showState`), so fetching other shows ahead doesn't redraw it.
    @ObservationIgnored private(set) var shows: [String: ShowData] = [:] {
        didSet { for (id, state) in showStates where state.value != shows[id] { state.value = shows[id] } }
    }
    @ObservationIgnored private var showStates: [String: TitleState<ShowData>] = [:]

    /// One show's page data, to watch: it changes only when this show does.
    func showState(_ id: String) -> TitleState<ShowData> {
        if let state = showStates[id] { return state }
        let state = TitleState(shows[id])
        showStates[id] = state
        return state
    }
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
        let file = Self.showFile(id)
        let inMemory = shows[id]
        // Registered before anything waits, so a page opening while the
        // same show is being fetched ahead joins that fetch.
        let task = Task<ShowData?, Never> {
            // The saved copy is read off the main thread (prefetching several
            // shows shouldn't read and decode each on it).
            var previous = inMemory
            if previous == nil { previous = await Task.detached(priority: .utility) { AppCache.read(file) as ShowData? }.value }
            if let previous, Date().timeIntervalSince(previous.loadedAt) < 24 * 3600 {
                async let changes = emby.episodeChanges(of: id, since: previous.loadedAt)
                async let next = emby.nextEpisode(of: id)
                async let like: [EmbyItem]? = previous.similar == nil ? moreLikeThis(id, emby: emby) : previous.similar
                if let changed = try? await changes {
                    return ShowData(show: previous.show, episodes: Self.merge(previous.episodes, changed),
                                    nextUp: (try? await next) ?? previous.nextUp, loadedAt: Date(), similar: await like)
                }
            }
            // Everything at once: the show (with cast and genres), every
            // episode, the next one, and shows like it.
            async let item = emby.details(id)
            async let list = emby.episodes(of: id, season: nil)
            async let next = emby.nextEpisode(of: id)
            async let like = moreLikeThis(id, emby: emby)
            guard let show = await item, let episodes = try? await list else { return nil }
            return ShowData(show: show, episodes: episodes, nextUp: try? await next, loadedAt: Date(), similar: await like)
        }
        showLoads[id] = task
        let account = accountGeneration
        let data = await task.value
        if showLoads[id] == task { showLoads[id] = nil }
        // Signed out (or in as someone else) meanwhile: not this account's.
        guard account == accountGeneration else { return nil }
        if let data {
            if shows.count > 80 {
                // The oldest go; never a page that's open (or under another).
                for old in shows.filter({ pinned[$0.key] == nil }).sorted(by: { $0.value.loadedAt < $1.value.loadedAt }).prefix(20) {
                    shows[old.key] = nil
                }
            }
            if shows[id] == nil {
                prefetchArt(data.show)
                prefetchStills(data)
            }
            shows[id] = data
            AppCache.save(Self.showFile(id), data)
        }
        return data
    }

    /// Title pages that exist (on screen or under another page), whose data
    /// is never evicted.
    @ObservationIgnored private var pinned: [String: Int] = [:]

    /// Keeps this title's page data for as long as the returned pin lives
    /// (a page holds it in its state).
    func pin(_ id: String) -> PagePin {
        pinned[id, default: 0] += 1
        return PagePin { [weak self] in Task { @MainActor in self?.unpin(id) } }
    }

    private func unpin(_ id: String) {
        if let count = pinned[id], count > 1 {
            pinned[id] = count - 1
        } else {
            pinned[id] = nil
            showStates[id] = nil
            movieStates[id] = nil
        }
    }

    // MARK: Intent

    /// What this device plays, and when (the last 20 times each): the titles
    /// in rotation, and the channels watched most, are kept ready so they
    /// open and start at once.
    private struct Habits: Codable {
        var titles: [String: Played] = [:]
        var channels: [String: [Date]] = [:]
        struct Played: Codable { var kind: String; var at: [Date] }
    }
    @ObservationIgnored private lazy var habits: Habits = AppCache.read("habits.json") ?? Habits()

    /// How much, and how lately (each play counts less the older it is:
    /// half as much after a week).
    private static func score(_ dates: [Date], now: Date = Date()) -> Double {
        dates.reduce(0) { $0 + pow(0.5, now.timeIntervalSince($1) / (7 * 24 * 3600)) }
    }

    private func notePlay(_ id: String, kind: String) {
        var played = habits.titles[id] ?? Habits.Played(kind: kind, at: [])
        played.at = Array((played.at + [Date()]).suffix(20))
        habits.titles[id] = played
        // The 100 that count most are enough.
        if habits.titles.count > 100 {
            for (id, _) in habits.titles.sorted(by: { Self.score($0.value.at) < Self.score($1.value.at) }).prefix(habits.titles.count - 100) {
                habits.titles[id] = nil
            }
        }
        AppCache.save("habits.json", habits)
    }

    func noteChannel(_ id: String) {
        habits.channels[id] = Array(((habits.channels[id] ?? []) + [Date()]).suffix(20))
        if habits.channels.count > 100 {
            for (id, _) in habits.channels.sorted(by: { Self.score($0.value) < Self.score($1.value) }).prefix(habits.channels.count - 100) {
                habits.channels[id] = nil
            }
        }
        AppCache.save("habits.json", habits)
    }

    /// The titles in rotation, most likely first.
    func inRotation(_ limit: Int = 6) -> [(id: String, kind: String)] {
        let now = Date()
        return habits.titles.map { (id: $0.key, kind: $0.value.kind, score: Self.score($0.value.at, now: now)) }
            .filter { $0.score > 0.2 }
            .sorted { $0.score > $1.score }
            .prefix(limit).map { ($0.id, $0.kind) }
    }

    /// The channels watched most, most first.
    func favouriteChannels(_ limit: Int = 12) -> [String] {
        let now = Date()
        return habits.channels.map { ($0.key, Self.score($0.value, now: now)) }
            .filter { $0.1 > 0.2 }.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    /// The titles in rotation ready before they're chosen: their pages and
    /// pictures, and how to play them (the next episode, or where a film
    /// was left), so opening or resuming any of them is instant.
    func prepareRotation() {
        guard !PlaybackActivity.isPlaying else { return }
        let rotation = inRotation()
        for (id, kind) in rotation {
            if kind == "Series" { prefetchShows([id]) } else { Task(priority: .utility) { await refreshTitle(id, kind: kind) } }
        }
        prepare(rotation.map { (id: $0.id, kind: Optional($0.kind)) })
    }

    /// Near the end of an episode: the next one's details and how to play it.
    func prepareNext(after playback: EmbyPlayback) {
        Task {
            guard let next = await episode(after: playback) else { return }
            prepare([(id: next.id, kind: "Episode")], duringPlayback: true)
        }
    }

    /// The first unwatched episode after this one, from the show's data
    /// (loaded when it isn't yet); nil after the last.
    func episode(after playback: EmbyPlayback) async -> EmbyItem? {
        guard let series = playback.seriesId else { return nil }
        var show = shows[series]
        if show == nil { show = await loadShow(series) }
        guard let data = show, let index = data.episodes.firstIndex(where: { $0.id == playback.itemId }) else { return nil }
        return data.episodes[(index + 1)...].first { $0.userData?.played != true }
    }

    /// The channels watched most: what's on now and next, ready for Live TV.
    func prepareFavouriteChannels() async {
        let channels = favouriteChannels().compactMap { channelById[$0] }
        guard !channels.isEmpty else { return }
        await ensureNowNext(channels)
    }

    // MARK: Films

    /// A film's page: its details and the titles like it.
    struct MovieData: Codable, Sendable, Equatable {
        let item: EmbyItem
        let similar: [EmbyItem]
        let loadedAt: Date
    }

    /// Not observed as a whole (see `shows`).
    @ObservationIgnored private(set) var movies: [String: MovieData] = [:] {
        didSet { for (id, state) in movieStates where state.value != movies[id] { state.value = movies[id] } }
    }
    @ObservationIgnored private var movieStates: [String: TitleState<MovieData>] = [:]

    /// One film's page data, to watch: it changes only when this film does.
    func movieState(_ id: String) -> TitleState<MovieData> {
        if let state = movieStates[id] { return state }
        let state = TitleState(movies[id])
        movieStates[id] = state
        return state
    }
    private var movieLoads: [String: Task<MovieData?, Never>] = [:]

    /// A film's page as last seen: in memory, else saved on the device, so
    /// it opens complete at once while it's brought up to date.
    func cachedMovie(_ id: String) -> MovieData? {
        if let data = movies[id] { return data }
        guard let saved: MovieData = AppCache.read(Self.movieFile(id)) else { return nil }
        movies[id] = saved
        return saved
    }

    private static func movieFile(_ id: String) -> String { "movie-\(id).json" }

    /// The library's titles most like this one by IMDb's data (who made
    /// them, genres, era, rating), with what's been watched of them; Emby's
    /// own suggestions for a title IMDb's data doesn't cover yet.
    private func moreLikeThis(_ id: String, emby: EmbyClient) async -> [EmbyItem] {
        let alike = await library.imdbSimilar(to: id, limit: 20).map(\.id)
        guard !alike.isEmpty else { return await emby.similar(to: id, limit: 20) }
        return await emby.items(ids: alike)
    }

    /// Details and titles like it, at once; one load at a time per film.
    func loadMovie(_ id: String) async -> MovieData? {
        if let running = movieLoads[id] { return await running.value }
        guard let emby else { return nil }
        let account = accountGeneration
        let task = Task<MovieData?, Never> {
            async let like = moreLikeThis(id, emby: emby)
            guard let item = await emby.details(id), account == accountGeneration else { return nil }
            // The page's own details (and where you got to) as soon as
            // they're here; titles like it (a slower request) follow.
            if movies[id] == nil { prefetchArt(item) }
            movies[id] = MovieData(item: item, similar: movies[id]?.similar ?? [], loadedAt: Date())
            return MovieData(item: item, similar: await like, loadedAt: Date())
        }
        movieLoads[id] = task
        let data = await task.value
        if movieLoads[id] == task { movieLoads[id] = nil }
        guard account == accountGeneration else { return nil }
        if let data {
            if movies.count > 80 {
                for old in movies.filter({ pinned[$0.key] == nil }).sorted(by: { $0.value.loadedAt < $1.value.loadedAt }).prefix(20) {
                    movies[old.key] = nil
                }
            }
            movies[id] = data
            AppCache.save(Self.movieFile(id), data)
        }
        return data
    }

    /// A film's or show's page, brought up to date if it's over five
    /// minutes old (or not loaded yet).
    func refreshTitle(_ id: String, kind: String) async {
        if kind == "Series" {
            if shows[id].map({ Date().timeIntervalSince($0.loadedAt) > 300 }) ?? true { _ = await loadShow(id) }
        } else if movies[id].map({ Date().timeIntervalSince($0.loadedAt) > 300 }) ?? true {
            _ = await loadMovie(id)
        }
    }

    /// Likely to be opened next (focused a moment, at the top of Home): its
    /// page and its pictures, so it opens complete instead of filling in.
    func prefetchTitle(_ card: Card) {
        guard !PlaybackActivity.isPlaying else { return }
        switch card.kind {
        case "Series": prefetchShows([card.id])
        case "Movie": Task(priority: .utility) { await refreshTitle(card.id, kind: "Movie") }
        default: break
        }
    }

    /// The width a title page asks for its backdrop and logo at (so what's
    /// fetched ahead is exactly what the page shows).
    #if os(tvOS)
    static let pageBackdropWidth = 1920, pageLogoWidth = 900
    #else
    static let pageBackdropWidth = 1280, pageLogoWidth = 800
    #endif

    /// Apple TV's show page opens on the episode you're up to: its still
    /// and its neighbours', fetched with the page.
    private func prefetchStills(_ data: ShowData) {
        #if os(tvOS)
        guard let emby, NetworkStatus.shared.knownUnmetered else { return }
        let at = data.episodes.firstIndex { $0.id == data.nextUp?.id } ?? 0
        let around = data.episodes[max(0, at - 2)..<min(data.episodes.count, at + 4)]
        let urls = around.compactMap { emby.card(for: $0, landscape: true, width: 960).images.first.flatMap { URL(string: $0.url) } }
        Task(priority: .utility) { await ImagePipeline.shared.prefetch(urls) }
        #endif
    }

    private func prefetchArt(_ item: EmbyItem) {
        guard let emby, NetworkStatus.shared.knownUnmetered else { return }
        let urls = [emby.backdropURL(for: item, width: Self.pageBackdropWidth), emby.logoURL(for: item, width: Self.pageLogoWidth)]
            .compactMap(\.self)
        Task(priority: .utility) { await ImagePipeline.shared.prefetch(urls) }
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
        let duration = playback.durationSeconds ?? 0
        let finished = duration > 0 && seconds >= duration * 0.9
        func watched(_ old: EmbyItem.UserData?) -> EmbyItem.UserData {
            var user = old ?? EmbyItem.UserData()
            user.played = finished ? true : user.played
            user.playbackPositionTicks = finished ? 0 : Int64(seconds * 1e7)
            user.playedPercentage = finished || duration == 0 ? nil : seconds / duration * 100
            user.lastPlayedDate = ISO8601DateFormatter().string(from: Date())
            return user
        }
        // A film's page shows where it got to (Continue, time left) at once.
        if let data = movies[playback.itemId] {
            var item = data.item
            item.userData = watched(item.userData)
            movies[playback.itemId] = MovieData(item: item, similar: data.similar, loadedAt: data.loadedAt)
        }
        guard let series = playback.seriesId, let data = cachedShow(series),
              let index = data.episodes.firstIndex(where: { $0.id == playback.itemId }) else { return }
        var episodes = data.episodes
        episodes[index].userData = watched(episodes[index].userData)
        // Finished: the show's Play moves on to the next one at once (as
        // Continue Watching does).
        let nextUp = finished ? episodes[(index + 1)...].first { $0.userData?.played != true } : data.nextUp
        // Keep loadedAt: the next update still asks for everything since.
        shows[series] = ShowData(show: data.show, episodes: episodes, nextUp: nextUp, loadedAt: data.loadedAt, similar: data.similar)
    }

    /// Continue Watching as it'll be, straight away when playback stops
    /// (the server's answer follows): the title just watched first with its
    /// new progress; once finished, a show's next episode instead (as the
    /// TV app does), a film gone. A title that wasn't in the row joins it.
    /// What was stopped on this device in the last two minutes: a server
    /// answer that hasn't caught up yet doesn't undo it.
    @ObservationIgnored private var recentStops: [String: RecentStop] = [:]

    private struct RecentStop {
        enum Outcome {
            /// The card Continue Watching showed for it.
            case card(Card)
            /// Finished with nothing next: no card.
            case gone
            /// Partway, but no card could be made here (nothing about it
            /// saved): the server's card stays, with this progress.
            case progress(Double?)
        }

        let at: Date
        let outcome: Outcome
        /// Its show, whose card it replaces whichever episode that had.
        let seriesId: String?
    }

    /// The server's Continue Watching, with this device's stops of the last
    /// two minutes over anything older it still says: each one's card in
    /// front (newest first) in place of the server's for that title or
    /// show, also when the server doesn't list it yet.
    private func reconciled(_ row: HomeRow?) -> HomeRow? {
        recentStops = recentStops.filter { Date().timeIntervalSince($0.value.at) < 120 }
        guard !recentStops.isEmpty else { return row }
        var cards = row?.cards ?? []
        for (itemId, stop) in recentStops.sorted(by: { $0.value.at < $1.value.at }) {
            func isIt(_ card: Card) -> Bool {
                card.id == itemId || card.episodeId == itemId
                    || stop.seriesId.map { card.id == $0 || card.seriesId == $0 } ?? false
            }
            // Its card as it stands, else as the server sent it (an older
            // stop of the same show may have taken it out already); this
            // very episode or film before any card of its show.
            func exact(_ card: Card) -> Bool { card.id == itemId || card.episodeId == itemId }
            let candidates = cards + (row?.cards ?? [])
            let theirs = candidates.first(where: exact) ?? candidates.first(where: isIt)
            cards.removeAll(where: isIt)
            switch stop.outcome {
            case let .card(card):
                cards.insert(card, at: 0)
            case .gone:
                break
            case let .progress(progress):
                // The server's own card, in front with where it got to.
                guard let old = theirs else { break }
                // The new progress only on a card for this very title.
                cards.insert(Card(id: old.id, kind: old.kind, title: old.title, subtitle: old.subtitle, images: old.images,
                                  progress: exact(old) ? (progress ?? old.progress) : old.progress, playable: old.playable,
                                  episodeId: old.episodeId, seriesId: old.seriesId), at: 0)
            }
        }
        guard !cards.isEmpty else { return nil }
        let shape = Artwork.Shape.landscape
        return HomeRow(title: "Continue Watching", shape: row?.shape ?? shape.rawValue, aspect: row?.aspect ?? shape.aspect, cards: cards)
    }

    private static let continueTitle = "Continue Watching"

    /// Rows with Continue Watching reconciled (first), and the other rows
    /// without what's in it.
    private func withStops(_ rows: [HomeRow]) -> [HomeRow] {
        guard !recentStops.isEmpty else { return rows }
        return Self.replacingContinue(in: rows, with: reconciled(rows.first { $0.title == Self.continueTitle }))
    }

    /// These rows with this Continue Watching first (or none), and the
    /// other rows without what's in it (each title once on the page).
    private static func replacingContinue(in rows: [HomeRow], with row: HomeRow?) -> [HomeRow] {
        let resumed = Set(row?.cards.flatMap { [$0.id] + [$0.seriesId].compactMap(\.self) } ?? [])
        var updated = rows.filter { $0.title != continueTitle }.map { other in
            HomeRow(title: other.title, shape: other.shape, aspect: other.aspect, cards: other.cards.filter { !resumed.contains($0.id) })
        }.filter { !$0.cards.isEmpty }
        if let row { updated.insert(row, at: 0) }
        return updated
    }

    /// These rows with this Continue Watching first (or none), the other
    /// rows as they are: what's on the page keeps its place.
    private static func settingContinue(in rows: [HomeRow], to row: HomeRow?) -> [HomeRow] {
        var updated = rows.filter { $0.title != continueTitle }
        if let row { updated.insert(row, at: 0) }
        return updated
    }

    /// Continue Watching as the server has it now (with this device's
    /// stops). On the page at once when Home is still opening, just after
    /// the player closed, or when only progress changed (the same cards in
    /// the same order); otherwise it waits with the next Home, so no card
    /// appears, goes or moves while you look.
    private func offerContinue(_ row: HomeRow?, now: Bool = false) {
        let shown = rows.first { $0.title == Self.continueTitle }
        let opening = homeOpening
        let mayMove = opening || now || continueMovesUntil.map { Date() < $0 } ?? false
        // The newest Continue Watching always waits too, so a moment
        // later never puts an older one back.
        if var staged = stagedHome {
            staged.rows = Self.replacingContinue(in: staged.rows, with: row)
            stagedHome = staged
        }
        // The same cards: the same titles and, for shows, the same
        // episodes (a show's card moving on to its next episode is a new
        // card, not progress).
        func identity(_ row: HomeRow?) -> [String]? { row?.cards.map { $0.id + "|" + ($0.episodeId ?? "") } }
        if mayMove || identity(row) == identity(shown) {
            // Opening, the other rows lose what's now in it; otherwise
            // they stay as they are until the next moment.
            let updated = opening ? Self.replacingContinue(in: rows, with: row) : Self.settingContinue(in: rows, to: row)
            if updated != rows {
                rows = updated
                saveShownHome()
            }
        } else if stagedHome == nil {
            stagedHome = HomeContent(featured: featured, rows: Self.replacingContinue(in: rows, with: row),
                                     builtAt: shownBuiltAt, history: shownHistory, spotlight: spotlight)
        }
    }

    private func patchContinueWatching(_ playback: EmbyPlayback, seconds: Double) {
        guard let emby else { return }
        // The player closing is a moment for Continue Watching: what the
        // server said meanwhile goes on first, this stop over it, and the
        // server's answer for the stop may still move cards.
        if let staged = stagedHome {
            let updated = Self.settingContinue(in: rows, to: staged.rows.first { $0.title == Self.continueTitle })
            if updated != rows { rows = updated }
        }
        continueMovesUntil = Date().addingTimeInterval(10)
        let duration = playback.durationSeconds ?? 0
        let finished = duration > 0 && seconds >= duration * 0.9
        let index = rows.firstIndex { $0.title == Self.continueTitle }
        var cards = index.map { rows[$0].cards } ?? []
        let old = cards.firstIndex { $0.id == playback.itemId || $0.episodeId == playback.itemId }.map { cards.remove(at: $0) }
        func card(_ item: EmbyItem) -> Card? { emby.showRow(Self.continueTitle, [item], lastCardWidth)?.cards.first }
        var lead: Card?
        if let series = playback.seriesId, let data = shows[series],
           let at = data.episodes.firstIndex(where: { $0.id == playback.itemId }) {
            // One card per show, whichever episode it had.
            cards.removeAll { $0.id == series }
            let next = finished ? data.episodes[(at + 1)...].first { $0.userData?.played != true } : data.episodes[at]
            lead = next.flatMap(card)
        } else if let item = movies[playback.itemId]?.item {
            lead = finished ? nil : card(item)
        } else if let old, !finished {
            let progress = duration > 0 ? seconds / duration * 100 : old.progress
            lead = Card(id: old.id, kind: old.kind, title: old.title, subtitle: old.subtitle, images: old.images,
                        progress: progress, playable: old.playable, episodeId: old.episodeId, seriesId: old.seriesId)
        }
        if let lead { cards.insert(lead, at: 0) }
        let outcome: RecentStop.Outcome = if let lead { .card(lead) } else if finished { .gone } else {
            .progress(duration > 0 ? seconds / duration * 100 : nil)
        }
        recentStops[playback.itemId] = RecentStop(at: Date(), outcome: outcome, seriesId: playback.seriesId)
        let shape = Artwork.Shape.landscape
        let row = cards.isEmpty ? nil : HomeRow(title: Self.continueTitle, shape: index.map { rows[$0].shape } ?? shape.rawValue,
                                                aspect: index.map { rows[$0].aspect } ?? shape.aspect, cards: cards)
        let updated = Self.settingContinue(in: rows, to: row)
        if updated != rows { rows = updated }
        // The Home waiting has it too.
        if var staged = stagedHome {
            staged.rows = Self.replacingContinue(in: staged.rows, with: row)
            stagedHome = staged
        }
    }

    /// Loads shows the user is likely to open next, in the background.
    func prefetchShows(_ ids: [String], force: Bool = false) {
        for id in ids where force || shows[id].map({ Date().timeIntervalSince($0.loadedAt) > 300 }) ?? true {
            Task(priority: .utility) { _ = await loadShow(id) }
        }
    }

    /// Continue Watching alone (two small requests), after watching
    /// something: the other rows stay put (see `offerContinue`).
    /// `checkingHistory`: also ask what was finished lately, and return true
    /// (leaving the page alone) when Top picks' recent watches changed, so
    /// the caller rebuilds everything instead.
    /// `afterStop`: the server's answer for what the player just stopped,
    /// the last that may move cards on the page.
    @discardableResult
    /// `returning`: back in the app, where it goes on at once (what was
    /// watched on another device meanwhile is your own, not a
    /// recommendation; it waited for the next moment and looked unsynced).
    func refreshContinueWatching(checkingHistory: Bool = false, afterStop: Bool = false, returning: Bool = false) async -> Bool {
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
        let server = emby.showRow(Self.continueTitle, items, lastCardWidth).map { variedForTests([$0], numbered: false)[0] }
        let row = reconciled(server)
        offerContinue(row, now: returning)
        if afterStop { continueMovesUntil = nil }
        prepare(Array((row?.cards ?? []).prefix(4)).map { (id: $0.episodeId ?? $0.id, kind: Optional($0.episodeId != nil ? "Episode" : $0.kind)) })
        return false
    }

    // MARK: Live updates from Emby

    let live = EmbyLive()
    /// The newest Home built (waiting or shown): when, and the recent
    /// watches its Top picks came from.
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
                // Additions come in bursts; let them settle. The Home
                // built from them waits for the next moment (see stagedHome).
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
            shows[series] = ShowData(show: data.show, episodes: episodes, nextUp: data.nextUp, loadedAt: data.loadedAt, similar: data.similar)
        }
    }

    // MARK: Warm start

    /// The item most likely to be played next, already opened and paused at
    /// its resume point in a hidden player, so selecting it starts at once.
    /// `key` is what was tapped (a show for Play next episode); `playback`
    /// says which episode or movie is actually open.
    /// `parked`: the player just closed, kept paused where it stopped.
    private var warm: (key: String, player: MPVPlayer, playback: EmbyPlayback, parked: Bool)?
    private var warmExpiry: Task<Void, Never>?
    /// The warm-up under way (still working out how to play it): owned, so
    /// a newer one or a cool-down stops it before it opens a stream nobody
    /// wants any more.
    private var warmTask: Task<Void, Never>?
    private var warming: String?

    func warmUp(_ itemId: String, kind: String?, options: [(String, String)], hardwareDecoding: Bool) {
        // Opens a stream: only on a connection known to be unmetered, never
        // while something plays.
        guard warm?.key != itemId, warming != itemId, !PlaybackActivity.isPlaying,
              NetworkStatus.shared.knownUnmetered else { return }
        coolDown()
        warming = itemId
        prepare([(id: itemId, kind: kind)])
        // Fetched ahead: waiting for it mustn't promote it to the
        // connections kept for what's on screen.
        warmTask = Task(priority: .utility) {
            let playback = (try? await prepared[itemId]?.task.value).map(withLocalResume)
            guard !Task.isCancelled, warming == itemId else { return }
            warming = nil
            guard let playback, warm == nil else { return }
            let player = MPVPlayer(options: options + [("pause", "yes")], hardwareDecoding: hardwareDecoding)
            player.prepareOffscreen()
            player.load(playback.url, headers: playback.headers, start: playback.startSeconds, file: true, readahead: .warm,
                        tracks: playback.tracks)
            player.addSubtitles(playback.subtitleFiles, references: playback.subtitleReferences, speech: playback.speechStretches)
            player.addCopies(playback.subtitleCopies)
            warm = (itemId, player, playback, false)
            // Its preview stills too, so scrubbing has its pictures from
            // the first second of playing.
            // By what plays (a show resolves to one of its episodes).
            Task(priority: .utility) { _ = await previewStills(playback.itemId) }
            // Don't hold a connection open for long if it isn't wanted.
            warmExpiry = Task { [weak self] in
                try? await Task.sleep(for: .seconds(300))
                guard !Task.isCancelled else { return }
                self?.coolDown()
            }
        }
    }

    /// The preview stills (BIF) of the last two titles got ready ahead of a
    /// tap, and fetches under way.
    @ObservationIgnored private var previews: [(id: String, data: Data)] = []
    @ObservationIgnored private var previewLoads: [String: Task<Data?, Never>] = [:]

    /// A title's preview stills, fetched once (joining a fetch under way).
    func previewStills(_ itemId: String) async -> Data? {
        if let data = cachedPreviewStills(itemId) { return data }
        // Per account: another account's fetch of the same id isn't joined.
        let account = accountGeneration
        let key = "\(account)|\(itemId)"
        if let running = previewLoads[key] {
            let data = await running.value
            return account == accountGeneration ? data : nil
        }
        guard let emby else { return nil }
        let task = Task(priority: .utility) { await emby.previewThumbnails(itemId: itemId) }
        previewLoads[key] = task
        let data = await task.value
        if previewLoads[key] == task { previewLoads[key] = nil }
        guard account == accountGeneration else { return nil }
        if let data { previews = Array((previews.filter { $0.id != itemId } + [(itemId, data)]).suffix(2)) }
        return data
    }

    /// Stills already here, without waiting.
    func cachedPreviewStills(_ itemId: String) -> Data? {
        previews.first { $0.id == itemId }?.data
    }

    /// What plays next in the player screen, opened out of sight and paused
    /// at `playback`'s start (another copy of the title, for a language
    /// only it has): the screen keeps playing meanwhile and hands over once
    /// its picture is ready (see takeWarm). Unlike warmUp, while something
    /// plays and on any connection: it was asked for.
    func warmSwitch(_ playback: EmbyPlayback, options: [(String, String)], hardwareDecoding: Bool) -> MPVPlayer {
        coolDown()
        let player = MPVPlayer(options: options + [("pause", "yes")], hardwareDecoding: hardwareDecoding)
        player.prepareOffscreen()
        player.load(playback.url, headers: playback.headers, start: playback.startSeconds, file: true, readahead: .warm,
                    tracks: playback.tracks)
        player.addSubtitles(playback.subtitleFiles, references: playback.subtitleReferences, speech: playback.speechStretches)
        player.addCopies(playback.subtitleCopies)
        warm = (playback.itemId, player, playback, false)
        warmExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            self?.coolDown()
        }
        return player
    }

    /// Hands over the warmed-up player for this episode or movie, if it's
    /// open at `start` (one opened at another second, say before the last
    /// stop reached the server, would play from there: "the same frame
    /// again").
    func takeWarm(_ itemId: String, at start: Double?) -> (MPVPlayer, EmbyPlayback)? {
        guard let warm, warm.playback.itemId == itemId else { return nil }
        // Failed meanwhile (the connection lost, the app away): the title
        // opens afresh. Handed over, it waited for a start that never came.
        guard !warm.player.hasFailed else {
            coolDown()
            return nil
        }
        guard abs((warm.playback.startSeconds ?? 0) - (start ?? 0)) < 2 else {
            coolDown()
            return nil
        }
        self.warm = nil
        warmExpiry?.cancel()
        return (warm.player, warm.playback)
    }

    /// Keeps a player that just closed, paused where it stopped, for five
    /// minutes: the title chosen again carries on at once. Not at the end
    /// (the next episode, or the start, plays then).
    func park(_ player: MPVPlayer, _ playback: EmbyPlayback) {
        let seconds = playback.startSeconds ?? 0
        guard let duration = playback.durationSeconds, duration > 0, seconds < duration * 0.9 else { return player.shutdown() }
        coolDown()
        player.onEvent = nil
        player.setPaused(true)
        player.setReadahead(.warm)
        warm = (playback.itemId, player, playback, true)
        warmExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            self?.coolDown()
        }
    }

    /// Where this device last stopped a title (0: finished), for half an
    /// hour: it wins over the server's resume point, which may not have
    /// heard yet.
    @ObservationIgnored private var stops: [String: (seconds: Double, at: Date)] = [:]

    private func withLocalResume(_ playback: EmbyPlayback) -> EmbyPlayback {
        guard let stop = stops[playback.itemId], Date().timeIntervalSince(stop.at) < 1800 else { return playback }
        var playback = playback
        playback.startSeconds = stop.seconds > 0 ? stop.seconds : nil
        return playback
    }

    func coolDown() {
        warmTask?.cancel()
        warmTask = nil
        warming = nil
        warmExpiry?.cancel()
        warm?.player.shutdown()
        warm = nil
    }

    /// Continue Watching's titles: how to play each, and the start of each
    /// file (its header, its index, the part where it resumes) fetched into
    /// the relay's cache, so a tap starts from the device. A resumed title
    /// waited for the server three times before its first frame. Only on a
    /// connection known to be unmetered, never while something plays.
    func prefetchContinueWatching(_ cards: [Card]) {
        guard NetworkStatus.shared.knownUnmetered, !PlaybackActivity.isPlaying else { return }
        let items = cards.prefix(4).compactMap { card -> (id: String, kind: String?)? in
            if let episode = card.episodeId { return (episode, "Episode") }
            return card.kind == "Series" ? nil : (card.id, card.kind)
        }
        prepare(items)
        for item in items {
            Task(priority: .utility) {
                guard let playback = (try? await prepared[item.id]?.task.value).map(withLocalResume),
                      !PlaybackActivity.isPlaying else { return }
                StreamRelay.shared.prefetchStart(url: playback.url, headers: playback.headers, at: playback.startSeconds ?? 0)
            }
        }
    }

    /// A film heard in neither English nor Spanish with no subtitles in
    /// either: the server's subtitle providers are asked for some (English
    /// first), once a week at most per title, and the subtitle files it
    /// then has are returned for the player to add (and show). Nothing is
    /// asked when the film has what's needed.
    func fetchMissingSubtitles(for playback: EmbyPlayback) async -> [EmbyPlayback.SubtitleFile] {
        #if DEBUG
        NSLog("%@", "PERF subtitles needed? wanted=\(playback.tracks?.subtitles ?? []) has=\(playback.subtitleLanguages.sorted()) source=\(playback.mediaSourceId ?? "none")")
        #endif
        guard let emby, let wanted = playback.tracks?.subtitles,
              playback.subtitleLanguages.isDisjoint(with: ["en", "es"]) else { return [] }
        let key = "subtitleSearch." + playback.itemId
        var recent = (UserDefaults.standard.object(forKey: key) as? Date).map { Date().timeIntervalSince($0) < 7 * 86_400 } ?? false
        #if DEBUG
        // UI tests: `-forgetSubtitleSearches YES` asks again.
        if UserDefaults.standard.bool(forKey: "forgetSubtitleSearches") { recent = false }
        #endif
        if recent { return [] }
        UserDefaults.standard.set(Date(), forKey: key)
        let languages = wanted.compactMap { TrackChoice.normalized($0) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        for language in languages {
            let code = language == "es" ? "spa" : "eng"
            let found: [EmbyClient.RemoteSubtitle]
            do { found = try await emby.searchSubtitles(playback.itemId, mediaSourceId: playback.mediaSourceId, language: code) } catch {
                #if DEBUG
                NSLog("%@", "PERF subtitles search failed: \(error)")
                #endif
                continue
            }
            guard let best = found.first,
                  (try? await emby.downloadSubtitle(playback.itemId, mediaSourceId: playback.mediaSourceId, id: best.Id)) != nil
            else { continue }
            #if DEBUG
            NSLog("%@", "PERF subtitles fetched from \(best.ProviderName ?? "the server"): \(language)")
            #endif
            // The server lists its new file now.
            if let fresh = try? await emby.playback(versions: [playback.itemId], kind: nil, maxWidth: Self.maxWidth) {
                return fresh.subtitleFiles
            }
        }
        return []
    }

    /// Works out how to play these in the background; a later tap uses it.
    func prepare(_ items: [(id: String, kind: String?)], duringPlayback: Bool = false) {
        guard let emby, duringPlayback || !PlaybackActivity.isPlaying else { return }
        if prepared.count > 120 {
            // Kept three minutes at most anyway: drop the stale ones.
            prepared = prepared.filter { Date().timeIntervalSince($0.value.at) < 180 }
        }
        for (id, kind) in items where prepared[id].map({ Date().timeIntervalSince($0.at) >= 180 || $0.copies != library.versions(of: id) }) ?? true {
            let versions = library.versions(of: id)
            let shows = showCopies
            prepared[id] = (Date(), Task(priority: .utility) {
                try await emby.playback(versions: versions, kind: kind, maxWidth: Self.maxWidth, showCopies: shows)
            }, versions)
        }
    }

    /// The same item converted by the server at `bitrate`, from `start`.
    func convertedURL(for playback: EmbyPlayback, bitrate: Int, start: Double, copy: Bool = false) -> URL? {
        emby?.hlsURL(playback.itemId, mediaSourceId: playback.mediaSourceId ?? playback.itemId,
                     playSessionId: playback.playSessionId, start: start, bitrate: bitrate, copy: copy)
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
        let hadNotable = !library.notable.isEmpty
        async let charts: Void = library.refreshCharts(unmetered: NetworkStatus.shared.unmetered)
        await library.prepare(emby)
        // IMDb's genres and makers for the library's titles (Wi-Fi, about
        // monthly), in the background; the first time they arrive, Top
        // picks are remade from them (on the page at the next moment, see
        // stagedHome). Hundreds of megabytes, so not in the
        // first two minutes: browsing and a first play get the connection,
        // and a quick look doesn't start a download it won't finish.
        let hadCatalog = library.catalog != nil
        // One at a time, owned, so signing out stops it.
        catalogJob?.cancel()
        let account = accountGeneration
        catalogJob = Task(priority: .background) { [weak self] in
            try? await Task.sleep(for: .seconds(120))
            guard let self, !Task.isCancelled, account == accountGeneration else { return }
            await withTaskCancellationHandler {
                await self.library.refreshCatalog(unmetered: NetworkStatus.shared.knownUnmetered)
            } onCancel: { [library] in
                Task { @MainActor in library.cancelCatalog() }
            }
            guard !Task.isCancelled, account == accountGeneration else { return }
            if !hadCatalog, library.catalog != nil { await loadHome(cardWidth: lastCardWidth, sync: false, full: true) }
        }
        await charts
        // New titles since Home was built: its other rows are built again,
        // and go on at the next moment, not while you look.
        if let changed = library.changedAt, let built = homeBuiltAt, changed > built {
            await loadHome(cardWidth: lastCardWidth, sync: false, full: true)
            return
        }
        // Trending or New & notable arrived for the first time (Home was
        // built without them): rebuild once, for the next moment. Otherwise
        // a later build picks them up.
        if (before.isEmpty && !library.trending.isEmpty) || (!hadNotable && !library.notable.isEmpty) {
            // Full: a recent page (built from the newest additions) would
            // otherwise only refresh Continue Watching.
            await loadHome(cardWidth: lastCardWidth, sync: false, full: true)
        }
    }

    func playback(for card: Card) async throws -> EmbyPlayback {
        try await playback(itemId: card.id, kind: card.kind)
    }

    @ObservationIgnored private var reportChain: Task<Void, Never>?
    /// The newest position not yet sent: while one progress report waits
    /// its turn, newer ones replace it rather than queueing behind it.
    @ObservationIgnored private var queuedProgress: (playback: EmbyPlayback, seconds: Double)?

    /// The title's page and Home as they'll be after this stop, before the
    /// server hears; called while the player is still up, so the page
    /// appears as it will stay (nothing changes on it after).
    func noteStop(_ playback: EmbyPlayback, seconds: Double) {
        playingItem = nil
        let duration = playback.durationSeconds ?? 0
        stops[playback.itemId] = (duration > 0 && seconds >= duration * 0.9 ? 0 : seconds, Date())
        // Where it was stopped, for every device's Continue Watching (the
        // server keeps nothing this early in a title).
        let finished = duration > 0 && seconds >= duration * 0.9
        if let emby { Task(priority: .utility) { await emby.noteStarted(playback.itemId, seconds: finished ? nil : seconds) } }
        #if DEBUG
        debugStop = "stop noted player=\(debugPlayerUp ? "up" : "gone")"
        #endif
        #if DEBUG
        let began = CFAbsoluteTimeGetCurrent()
        #endif
        noteProgress(playback, seconds: seconds)
        #if DEBUG
        let noted = CFAbsoluteTimeGetCurrent()
        #endif
        patchContinueWatching(playback, seconds: seconds)
        #if DEBUG
        NSLog("%@", String(format: "PERF stop note %.1f ms, continue watching %.1f ms",
                           (noted - began) * 1000, (CFAbsoluteTimeGetCurrent() - noted) * 1000))
        #endif
    }

    #if DEBUG
    /// UI tests: whether the last stop reached the page while the player
    /// still covered it ("stop noted player=up"), and whether it's up.
    var debugStop = ""
    @ObservationIgnored var debugPlayerUp = false
    #endif

    /// `noted`: a stop already on the page (see noteStop).
    func report(_ playback: EmbyPlayback, seconds: Double, event: EmbyClient.PlaybackEvent, noted: Bool = false) async {
        if event == .started {
            playingItem = playback.itemId
            notePlay(playback.seriesId ?? playback.itemId, kind: playback.seriesId != nil ? "Series" : "Movie")
        }
        if event == .stopped, !noted {
            noteStop(playback, seconds: seconds)
        }
        // In the order they happened: a progress report sent a moment before
        // Stopped must not land after it and move the resume point back.
        let client = emby
        if event == .progress {
            let waiting = queuedProgress != nil
            queuedProgress = (playback, seconds)
            if waiting { return }
            await enqueueReport { [weak self] in
                guard let (playback, seconds) = await self?.takeQueuedProgress() else { return }
                await client?.report(.progress, itemId: playback.itemId, seconds: seconds,
                                     mediaSourceId: playback.mediaSourceId, playSessionId: playback.playSessionId)
            }.value
            return
        }
        await enqueueReport {
            await client?.report(event, itemId: playback.itemId, seconds: seconds,
                                 mediaSourceId: playback.mediaSourceId, playSessionId: playback.playSessionId)
        }.value
        guard event == .stopped else { return }
        // Only this title's resume point changed: everything else prepared
        // stays ready.
        prepared[playback.itemId] = nil
        // A show prepared by its series (titles in rotation, Home) now has
        // a different next episode or resume point.
        if let series = playback.seriesId { prepared[series] = nil }
        // A player kept for this title stays if it's where this stopped.
        if let warm, warm.key == playback.itemId || (playback.seriesId != nil && warm.key == playback.seriesId),
           warm.playback.itemId != playback.itemId || abs((warm.playback.startSeconds ?? 0) - seconds) >= 2 {
            coolDown()
        }
        if let series = playback.seriesId { prefetchShows([series], force: true) }
        // Only Continue Watching changed; the rest of Home stays as it is.
        await refreshContinueWatching(afterStop: true)
    }

    private func enqueueReport(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        let previous = reportChain
        let task = Task {
            await previous?.value
            await work()
        }
        reportChain = task
        return task
    }

    private func takeQueuedProgress() -> (playback: EmbyPlayback, seconds: Double)? {
        defer { queuedProgress = nil }
        return queuedProgress
    }

    // MARK: Accounts

    /// Changes when the Emby account does: loads that began before ignore
    /// their results.
    @ObservationIgnored private var accountGeneration = 0
    /// IMDb's catalog, fetched a while after the library syncs.
    @ObservationIgnored private var catalogJob: Task<Void, Never>?

    func signedInToEmby(_ account: EmbyAccount) async {
        accountGeneration += 1
        // A Home on its way for the old account is dropped, not waited for.
        homeLoad = nil
        homeLoadID = UUID()
        stagedHome = nil
        recentStops = [:]
        stops = [:]
        previews = []
        previewLoads = [:]
        catalogJob?.cancel()
        showLoads = [:]
        movieLoads = [:]
        sources.setEmby(account)
        // Another account's Home: nothing of the last one waits or counts.
        stagedHome = nil
        shownBuiltAt = nil
        await loadHome(cardWidth: lastCardWidth, full: true, show: true)
    }

    func signOutOfEmby() async {
        accountGeneration += 1
        homeLoad = nil
        homeLoadID = UUID()
        stagedHome = nil
        recentStops = [:]
        stops = [:]
        catalogJob?.cancel()
        showLoads = [:]
        movieLoads = [:]
        live.disconnect()
        await emby?.logout()
        sources.setEmby(nil)
        rows = []
        featured = nil
        spotlight = []
        stagedHome = nil
        shownBuiltAt = nil
        homeBuiltAt = nil
        coolDown()
        // Title pages carry this account's progress; what was prepared and
        // watched is this account's too.
        shows = [:]
        movies = [:]
        prepared = [:]
        previews = []
        previewLoads = [:]
        habits = Habits()
        AppCache.remove("habits.json")
        AppCache.remove("home.v4.json")
        AppCache.removeAll(startingWith: ["show-", "movie-"])
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
        spotlight = []
        stagedHome = nil
        shownBuiltAt = nil
        homeBuiltAt = nil
        AppCache.remove("home.v4.json")
        categories = []
        allChannels = []
        channelsByCategory = [:]
        channelById = [:]
        clearNowNext()
        localCache = nil
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
            localCache = nil
            liveErrors = []
            return
        }
        if allChannels.isEmpty, !Self.freshLineup, let saved = await Self.savedLineup(), saved.sources == iptv.map(\.id) {
            await applyLineup(categories: saved.categories, channels: saved.channels)
            // Saved within the hour: good as it is (event categories are
            // fetched again on their own when opened). Not playlists': their
            // stream addresses can hold a login, so they're saved blank and
            // only the provider's current lineup can play them.
            let blank = saved.channels.contains { channel in
                if case let .url(url, _, _) = channel.stream { return url.scheme == "about" }
                return false
            }
            if !blank, let at = saved.savedAt, Date().timeIntervalSince(at) < 3600 { liveFetchedAt = at }
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
                let (ownCategories, ownChannels) = LiveOrganizer.withoutLogin(categories: lineup.categories, channels: lineup.channels)
                cats += ownCategories.map {
                    LiveCategory(id: $0.id, name: multiple ? "\(source.name) · \($0.name)" : $0.name, channels: $0.channels)
                }
                channels += ownChannels
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
        // Re-evaluate the rows on screen against the new guide, keeping
        // what they show until the new details are in (no flicker).
        providerEPG = [:]
        scheduleNowNext(force: true)
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
        if let cache = localCache, cache.area == area { return cache.channels }
        let city = area.city?.lowercased()
        let channels = allChannels
            .filter { local.contains($0.categoryId ?? "") && area.includes($0.name) }
            .sorted { first, second in
                let a = city.map { first.name.lowercased().contains($0) } ?? false
                let b = city.map { second.name.lowercased().contains($0) } ?? false
                if a != b { return a }
                let na = network(first.name), nb = network(second.name)
                return na != nb ? na < nb : first.name.localizedStandardCompare(second.name) == .orderedAscending
            }
        // Worked out once per lineup and area, not on every redraw.
        localCache = (area, channels)
        return channels
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
              let listed = try? await provider.channels(inCategory: id)
        else { return }
        let fresh = listed.filter { !LiveOrganizer.leaksLogin($0.name) }
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

    // v2: channels say how many days the provider records. v3: without the
    // channels some providers use to show the login.
    private nonisolated static let lineupFile = "live-lineup.v3.json"

    /// Everything worked out off the main thread (organising, the guide's
    /// channel index, search, lookups: tens of thousands of channels on a
    /// big subscription), then applied in one go.
    private func applyLineup(categories allCategories: [LiveCategory], channels allListed: [LiveChannel]) async {
        let home = Self.homeRegion
        // The provider's own category names (with several providers they're
        // shown as "Provider · US | News"), so the same channel from each
        // provider becomes one entry that can fall back to the other.
        let prefixes = Dictionary(sources.iptv.map { ($0.id.uuidString, $0.name + " · ") }, uniquingKeysWith: { a, _ in a })
        let built = await Task.detached(priority: .userInitiated) {
            Lineup(categories: allCategories, channels: allListed, prefixes: prefixes, home: home)
        }.value
        liveLibrary = built.library
        categories = built.categories
        allChannels = built.channels
        localCache = nil
        guideChannels = built.guideChannels
        localGuideCategories = built.localGuideCategories
        abroad = built.abroad
        channelCorpus = built.corpus
        channelsByCategory = built.byCategory
        channelById = built.byId
        let guide = guide, names = built.guideNames
        Task { await guide.setChannelNames(names) }
        // A shelf, Favorites or Local; a provider category only while it's
        // being browsed from the full list.
        let shelves = built.library.shelves
        let valid = selectedCategory.map { id in
            id == Self.favoritesID || id == Self.localID || shelves.contains { $0.id == id }
                || (browsingProviderCategory && built.categories.contains { $0.id == id })
        } ?? false
        if !valid { selectedCategory = shelves.first?.id ?? built.categories.first?.id }
        // The channels watched most: what's on, ready before Live TV opens;
        // their logos and the first shelf's, so Live TV opens drawn.
        Task { await prepareFavouriteChannels() }
        let firstShelf = shelves.first?.sections.flatMap(\.entries).prefix(30).compactMap(\.logo) ?? []
        let favourites = favouriteChannels().compactMap { built.byId[$0]?.logo }
        let logos = Array(Set(favourites + firstShelf))
        Task(priority: .utility) { await ImagePipeline.shared.prefetch(logos) }
    }

    /// A lineup ready to show: organised into shelves, with which channel
    /// plays each guide id (and the names guide search matches against),
    /// search, and lookups by category and id.
    private struct Lineup: Sendable {
        let library: LiveOrganizer.Library
        let categories: [LiveCategory]
        let channels: [LiveChannel]
        let guideChannels: [String: LiveChannel]
        let guideNames: [String: String]
        let localGuideCategories: Set<String>
        let abroad: Set<String>
        let corpus: SearchCorpus<LiveChannel>
        let byCategory: [String: [LiveChannel]]
        let byId: [String: LiveChannel]

        nonisolated init(categories allCategories: [LiveCategory], channels allListed: [LiveChannel],
                         prefixes: [String: String], home: String) {
            let (cats, channels) = LiveOrganizer.withoutLogin(categories: allCategories, channels: allListed)
            let own = cats.map { category -> LiveCategory in
                guard let source = category.id.split(separator: "|").first, let prefix = prefixes[String(source)],
                      category.name.hasPrefix(prefix) else { return category }
                return LiveCategory(id: category.id, name: String(category.name.dropFirst(prefix.count)), channels: category.channels)
            }
            let library = LiveOrganizer.organize(categories: own, channels: channels, home: home)
            var byGuide: [String: LiveChannel] = [:]
            var names: [String: String] = [:]
            for channel in channels {
                guard let epg = channel.epgId, byGuide[epg] == nil else { continue }
                let best = library.copies[channel.id]?.first ?? channel
                byGuide[epg] = best
                names[epg] = GuideStore.fold(library.titles[best.id] ?? LiveOrganizer.Name(best.name).display)
            }
            self.library = library
            self.categories = cats
            self.channels = channels
            guideChannels = byGuide
            guideNames = names
            localGuideCategories = Set(own.filter { LiveOrganizer.Kind($0.name, home: home).topic == .local }.map(\.id))
            abroad = Set(library.shelves.first { $0.id == LiveOrganizer.internationalID }?.sections
                .flatMap { $0.entries.flatMap { $0.channels.map(\.id) } } ?? [])
            corpus = SearchCorpus(channels, name: \.name)
            byCategory = Dictionary(grouping: channels, by: { $0.categoryId ?? "" })
            byId = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    @ObservationIgnored private var localGuideCategories: Set<String> = []

    /// Something on TV that matches a search: a programme from the guide or
    /// a game from Sports.
    struct GuideHit: Identifiable, Hashable {
        let title: String
        let channel: LiveChannel
        let channelTitle: String
        let start: Int64?
        let stop: Int64?
        let league: String?
        var id: String { "\(channel.id)|\(start ?? 0)|\(title)" }
        func isOn(at now: Int64 = Int64(Date().timeIntervalSince1970)) -> Bool {
            guard let start else { return false }
            return start <= now && (stop.map { now < $0 } ?? true)
        }
    }

    /// What's on now or later that matches the query: programmes from the
    /// guide (each word in the title or the channel's name) and games from
    /// Sports. On now first, then by start; channels from abroad after
    /// local ones; local stations only for your area.
    func searchGuide(_ query: String, area: LocalArea?, limit: Int = 40) async -> [GuideHit] {
        let words = GuideStore.fold(query).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.count >= 2 || $0.allSatisfy(\.isNumber) }
        guard !words.isEmpty else { return [] }
        let now = Int64(Date().timeIntervalSince1970)
        var hits: [GuideHit] = []
        var seen = Set<String>()
        for (epg, programme) in await guide.search(words, now: now) {
            guard let channel = guideChannels[epg] else { continue }
            if localGuideCategories.contains(channel.categoryId ?? "") {
                guard let area, area.includes(channel.name) else { continue }
            }
            let key = "\(channel.id)|\(programme.start)"
            guard seen.insert(key).inserted else { continue }
            hits.append(GuideHit(title: programme.title, channel: channel, channelTitle: title(of: channel),
                                 start: programme.start, stop: programme.stop, league: nil))
        }
        let events = shelf(LiveOrganizer.sportsID)?.sections.first { $0.id == "events" }?.entries ?? []
        for entry in events {
            let start = entry.event?.start.map { Int64($0.timeIntervalSince1970) }
            if let start, now - start > Int64(GameTime.listed) { continue }
            let text = GuideStore.fold(entry.title + " " + (entry.event?.league ?? ""))
            guard words.allSatisfy({ text.contains($0) }) else { continue }
            hits.append(GuideHit(title: entry.title, channel: entry.channels[0], channelTitle: entry.event?.league ?? "",
                                 start: start, stop: start.map { $0 + Int64(GameTime.length(league: entry.event?.league ?? "", title: entry.title)) },
                                 league: entry.event?.league))
        }
        return hits.enumerated().sorted { a, b in
            let x = a.element, y = b.element
            if x.isOn(at: now) != y.isOn(at: now) { return x.isOn(at: now) }
            let ax = abroad.contains(x.channel.id), ay = abroad.contains(y.channel.id)
            if ax != ay { return !ax }
            let sx = x.start ?? .max, sy = y.start ?? .max
            return sx != sy ? sx < sy : a.offset < b.offset
        }.prefix(limit).map(\.element)
    }

    /// The country Live TV is arranged for: the device's region.
    nonisolated static var homeRegion: String {
        let code = Locale.current.region?.identifier ?? "US"
        return code == "GB" ? "UK" : code
    }

    func shelf(_ id: String?) -> LiveOrganizer.Shelf? {
        guard let id else { return nil }
        return liveLibrary.shelves.first { $0.id == id }
    }

    /// Every copy of a channel, best first (itself included): what to fall
    /// back to when one won't play.
    func copies(of channel: LiveChannel) -> [LiveChannel] {
        liveLibrary.copies[channel.id] ?? [channel]
    }

    /// "TLC" for "US: TLC HD"; a game's title for its channel.
    func title(of channel: LiveChannel) -> String {
        liveLibrary.titles[channel.id] ?? LiveOrganizer.Name(channel.name).display
    }

    func event(of channel: LiveChannel) -> LiveOrganizer.Event? {
        liveLibrary.events[channel.id]
    }

    /// One of the channels showing a game ("Watch On").
    struct WatchChoice: Identifiable {
        let channel: LiveChannel
        let feed: WatchOn.Feed
        /// "HD", "SD"; nil when the name doesn't say.
        let quality: String?
        var id: String { channel.id }
    }

    /// Every channel showing this game, the one to play first at the top
    /// (see WatchOn.ranked); empty unless it's a game on more than one.
    func watchChoices(for channel: LiveChannel) -> [WatchChoice] {
        guard let event = event(of: channel) else { return [] }
        let copies = copies(of: channel)
        guard copies.count > 1 else { return [] }
        let choices = copies.map { copy in
            let feed = liveLibrary.feeds[copy.id] ?? WatchOn.Feed(service: LiveOrganizer.serviceName(""))
            return WatchChoice(channel: current(copy), feed: feed, quality: WatchOn.quality(of: copy.name).label)
        }
        let byId = Dictionary(choices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let options = choices.map { WatchOn.Option(id: $0.id, feed: $0.feed, quality: WatchOn.quality(of: $0.channel.name).score) }
        let lately = Set(liveFailures.filter { Date().timeIntervalSince($0.value) < 600 }.keys)
        return WatchOn.ranked(options, pick: watchPicks[event.league],
                              preferred: WatchOn.preferredLanguage(league: event.league, title: title(of: channel)),
                              failed: lately).compactMap { byId[$0.id] }
    }

    /// Every channel showing this game, the one to play first at the top,
    /// one too (its long-press menu); empty for anything but a game.
    func gameChannels(for channel: LiveChannel) -> [WatchChoice] {
        guard event(of: channel) != nil else { return [] }
        let choices = watchChoices(for: channel)
        guard choices.isEmpty else { return choices }
        let feed = liveLibrary.feeds[channel.id] ?? WatchOn.Feed(service: LiveOrganizer.serviceName(""))
        return [WatchChoice(channel: current(channel), feed: feed, quality: WatchOn.quality(of: channel.name).label)]
    }

    /// A channel picked in Watch On: first for this league's games from
    /// now on.
    func pickWatchChoice(_ choice: WatchChoice, league: String) {
        var picks = watchPicks
        picks[league] = WatchOn.Pick(service: choice.feed.service, language: choice.feed.language)
        UserDefaults.standard.set(try? JSONEncoder().encode(picks), forKey: "watchOnPicks")
    }

    /// A channel that wouldn't start: for the next ten minutes, games try
    /// the others first.
    func noteLiveFailure(_ channel: LiveChannel) {
        liveFailures[channel.id] = Date()
    }

    /// A game that played on none of its channels (by any of them).
    func noteGameNotPlaying(_ channel: LiveChannel) {
        for copy in copies(of: channel) { gamesNotPlaying[copy.id] = Date() }
    }

    /// The game tried in the last half hour, and none of its channels played
    /// (opened again, it's tried again).
    func isNotPlaying(_ entry: LiveOrganizer.Entry) -> Bool {
        entry.channels.contains { gamesNotPlaying[$0.id].map { Date().timeIntervalSince($0) < 1800 } ?? false }
    }

    /// A game playing after all: its rows say LIVE again.
    func noteGamePlaying(_ channel: LiveChannel) {
        guard !gamesNotPlaying.isEmpty else { return }
        for copy in copies(of: channel) where gamesNotPlaying[copy.id] != nil { gamesNotPlaying[copy.id] = nil }
    }

    private var watchPicks: [String: WatchOn.Pick] {
        UserDefaults.standard.data(forKey: "watchOnPicks").flatMap { try? JSONDecoder().decode([String: WatchOn.Pick].self, from: $0) } ?? [:]
    }

    /// Event lists change names game by game: when Sports opens, the ones
    /// not fetched in the last 15 minutes are fetched again (four at a
    /// time) and applied together.
    func refreshEvents() async {
        guard !refreshingEvents else { return }
        let stale = liveLibrary.eventCategories.filter { categoryFetchedAt[$0].map { Date().timeIntervalSince($0) >= 900 } ?? true }
        guard !stale.isEmpty else { return }
        refreshingEvents = true
        defer { refreshingEvents = false }
        var work: [(id: String, provider: any LiveProvider)] = []
        for id in stale {
            guard let sourceId = id.split(separator: "|").first.flatMap({ UUID(uuidString: String($0)) }),
                  let source = sources.iptv.first(where: { $0.id == sourceId }) else { continue }
            let provider = providers[sourceId] ?? Providers.make(source)
            providers[sourceId] = provider
            work.append((id, provider))
        }
        var fresh: [String: [LiveChannel]] = [:]
        await withTaskGroup(of: (String, [LiveChannel]?).self) { group in
            var queue = work[...]
            for _ in 0..<4 {
                guard let next = queue.popFirst() else { break }
                group.addTask { (next.id, try? await next.provider.channels(inCategory: next.id)) }
            }
            for await (id, listed) in group {
                categoryFetchedAt[id] = Date()
                if let listed { fresh[id] = listed.filter { !LiveOrganizer.leaksLogin($0.name) } }
                if let next = queue.popFirst() {
                    group.addTask { (next.id, try? await next.provider.channels(inCategory: next.id)) }
                }
            }
        }
        let changed = fresh.filter { $0.value != channelsByCategory[$0.key] }
        guard !changed.isEmpty else { return }
        let channels = allChannels.filter { !changed.keys.contains($0.categoryId ?? "") } + changed.values.flatMap { $0 }
        await applyLineup(categories: categories, channels: channels)
        Self.saveLineup(sources: sources.iptv.map(\.id), categories: categories, channels: allChannels)
    }

    private nonisolated static func savedLineup() async -> SavedLineup? {
        await Task.detached(priority: .userInitiated) { AppCache.read(lineupFile) as SavedLineup? }.value
    }

    /// Playlist stream URLs can hold a login, so they're saved blank and
    /// the providers' current lineup supplies them.
    private nonisolated static func saveLineup(sources: [UUID], categories: [LiveCategory], channels: [LiveChannel]) {
        guard !freshLineup else { return }
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
            let popularity = library.popularity, ratings = library.ratings
            people = await emby.titles(withPerson: person.id)
                .map { (item: $0, person: person.name) }
                .sorted {
                    let a = query.yearDistance($0.item.productionYear), b = query.yearDistance($1.item.productionYear)
                    if a != b { return a < b }
                    // Then the most popular now (TMDb), else the most voted (IMDb).
                    let pa = popularity?.popularity($0.item.tmdb, $0.item.kind == "Series" ? .show : .movie) ?? 0
                    let pb = popularity?.popularity($1.item.tmdb, $1.item.kind == "Series" ? .show : .movie) ?? 0
                    if pa != pb { return pa > pb }
                    return (ratings?.rating($0.item.imdb)?.votes ?? 0) > (ratings?.rating($1.item.imdb)?.votes ?? 0)
                }
        }
        return (refined, people)
    }

    /// The channel as last loaded (the player may hold an older copy).
    func current(_ channel: LiveChannel) -> LiveChannel {
        channelById[channel.id] ?? channel
    }

    /// A channel's schedule with what can be watched again: the
    /// provider's own (days back and ahead), else the guide's.
    func schedule(for channel: LiveChannel) async -> [Programme] {
        let channel = channelById[channel.id] ?? channel
        let own = await provider(for: channel)?.schedule(for: channel) ?? []
        if !own.isEmpty { return own }
        guard let id = channel.epgId else { return [] }
        return await guide.programmes(id)
    }

    /// A recorded programme from its start.
    func catchup(_ channel: LiveChannel, programme: Programme) async throws -> PlayableStream {
        guard let stream = try await provider(for: channel)?.catchup(channelById[channel.id] ?? channel, programme: programme) else {
            throw SourceError.unexpected("This channel can't be watched from the start.")
        }
        return stream
    }

    /// The channel's provider, connected on first use: a lineup saved
    /// within the hour is shown without connecting, and its rows still need
    /// their short EPG.
    private func provider(for channel: LiveChannel) -> LiveProvider? {
        if let known = providers[channel.sourceId] { return known }
        guard let source = sources.iptv.first(where: { $0.id == channel.sourceId }) else { return nil }
        let made = Providers.make(source)
        providers[source.id] = made
        return made
    }

    func playable(_ channel: LiveChannel) async throws -> PlayableStream {
        let channel = channelById[channel.id] ?? channel
        if case let .url(url, _, _) = channel.stream, url.scheme == "about" {
            throw SourceError.unexpected("Channels are still loading; try again in a moment.")
        }
        guard let provider = provider(for: channel) else { throw SourceError.unexpected("This channel's source was removed.") }
        do {
            return try await provider.playable(channel)
        } catch {
            throw SourceError.wrap(error)
        }
    }

    // MARK: Now / next

    /// A row scrolled into view; `ahead` are the rows below it, fetched
    /// now so they're filled in before they're seen.
    func appeared(_ id: String, ahead: some Collection<LiveChannel> = [LiveChannel]()) {
        visible.insert(id)
        if !ahead.isEmpty {
            lookahead = ahead.map(\.id)
            let logos = ahead.compactMap(\.logo).filter { ImagePipeline.shared.cached($0) == nil }
            if !logos.isEmpty { Task.detached(priority: .utility) { await ImagePipeline.shared.prefetch(logos) } }
        }
        scheduleNowNext()
    }

    /// The now/next a row watches (see NowNextSlot).
    func slot(_ id: String) -> NowNextSlot {
        if let slot = slots[id] { return slot }
        // Read without observing: a row creating its slot while drawing
        // would otherwise redraw whenever any channel's schedule changed.
        let slot = NowNextSlot(_nowNext[id])
        slots[id] = slot
        return slot
    }

    private func setNowNext(_ id: String, _ value: NowNext) {
        nowNext[id] = value
        if let slot = slots[id], slot.value != value { slot.value = value }
    }

    private func clearNowNext() {
        nowNext = [:]
        for slot in slots.values where slot.value != nil { slot.value = nil }
    }

    func disappeared(_ id: String) {
        visible.remove(id)
    }

    func ensureNowNext(_ channels: [LiveChannel]) async {
        await resolveNowNext(channels.filter { nowNext[$0.id].map(\.isStale) ?? true })
    }

    /// Fetches what rows on screen and just below them are missing, a
    /// tenth of a second after asked: while scrolling it keeps fetching
    /// (rather than waiting for the scroll to stop), in batches.
    private func scheduleNowNext(force: Bool = false) {
        if force { nowNextForced = true }
        guard !nowNextScheduled else { return }
        nowNextScheduled = true
        nowNextTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, !Task.isCancelled else { return }
            self.nowNextScheduled = false
            let force = self.nowNextForced
            self.nowNextForced = false
            var seen = Set<String>()
            let wanted = (Array(self.visible) + self.lookahead).filter { seen.insert($0).inserted }.compactMap { self.channelById[$0] }
            let stale = force ? wanted : wanted.filter { self.nowNext[$0.id].map(\.isStale) ?? true }
            await self.resolveNowNext(stale)
            self.scheduleBoundary()
        }
    }

    /// Full guide first (placeholder titles don't count), then the
    /// provider's own short EPG, cached until it expires.
    private func resolveNowNext(_ channels: [LiveChannel]) async {
        // Each channel once at a time (scrolling asks again while fetching).
        let channels = channels.filter { !resolving.contains($0.id) }
        guard !channels.isEmpty else { return }
        resolving.formUnion(channels.map(\.id))
        defer { resolving.subtract(channels.map(\.id)) }
        let now = Int64(Date().timeIntervalSince1970)
        var needProvider: [LiveChannel] = []
        for channel in channels {
            let guided = channel.epgId == nil ? (liveLibrary.guideAlias[channel.id] ?? channel) : channel
            if let id = guided.epgId, let fromGuide = await guide.nowNext(id, at: now),
               let title = fromGuide.now?.title, !NowNext.isPlaceholder(title) {
                setNowNext(channel.id, fromGuide)
            } else {
                needProvider.append(channel)
            }
        }
        var fetch: [(id: String, channel: LiveChannel, provider: any LiveProvider)] = []
        for channel in needProvider {
            let guided = channel.epgId == nil ? (liveLibrary.guideAlias[channel.id] ?? channel) : channel
            if let cached = providerEPG[channel.id], now < cached.until {
                setNowNext(channel.id, .from(cached.list, at: now, source: .provider))
            } else if let provider = provider(for: guided) {
                fetch.append((channel.id, guided, provider))
            }
        }
        await withTaskGroup(of: (String, [Programme]).self) { group in
            for item in fetch {
                group.addTask { (item.id, await item.provider.shortEPG(for: item.channel)) }
            }
            for await (id, list) in group {
                let value = NowNext.from(list, at: now, source: .provider)
                providerEPG[id] = (value.refreshAt ?? now + 300, list)
                setNowNext(id, value)
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

/// Held by a title page: its data stays cached while the page exists.
final class PagePin {
    private let release: @Sendable () -> Void
    init(_ release: @escaping @Sendable () -> Void) { self.release = release }
    deinit { release() }
}

/// One title page's data, observed on its own.
@Observable
@MainActor
final class TitleState<Value> {
    var value: Value?
    init(_ value: Value?) { self.value = value }
}

// MARK: - My List

extension AppModel {
    fileprivate static let myListOrderKey = "myListAdded"

    /// When each title was put on My List here (newest first on the row).
    private var myListAdded: [String: Double] {
        get { (UserDefaults.standard.dictionary(forKey: Self.myListOrderKey) as? [String: Double]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.myListOrderKey) }
    }

    /// Every copy on My List the last time this device read it.
    private static let myListSeenKey = "myListSeen"

    #if DEBUG
    /// A helper's answer at launch, in memory only (no cache on disk).
    private static func debugFetch(_ address: String) -> Data? {
        guard let url = URL(string: address) else { return nil }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        var body: Data?
        let done = DispatchSemaphore(value: 0)
        session.dataTask(with: url) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { body = data }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 5)
        return body
    }

    /// UI tests: `-forgetWatchOnPicks YES` at launch starts with no channel
    /// picked for any league.
    static func forgetWatchOnPicksForTesting() {
        guard UserDefaults.standard.bool(forKey: "forgetWatchOnPicks") else { return }
        UserDefaults.standard.removeObject(forKey: "watchOnPicks")
    }

    /// UI tests: `-freshLineup YES` asks the provider for its lineup at
    /// launch, and keeps it for this run only (the saved one stays).
    private nonisolated static var freshLineup: Bool { UserDefaults.standard.bool(forKey: "freshLineup") }
    #else
    private nonisolated static let freshLineup = false
    #endif

    #if DEBUG
    /// UI tests: `-forgetMyListOrder YES` at launch starts with no order
    /// kept (when each title was added, the titles seen).
    static func forgetMyListOrderForTesting() {
        guard UserDefaults.standard.bool(forKey: "forgetMyListOrder") else { return }
        UserDefaults.standard.removeObject(forKey: myListOrderKey)
        UserDefaults.standard.removeObject(forKey: myListSeenKey)
    }
    #endif

    /// My List from the server, newest additions first, as on Netflix, one
    /// card per title however many copies (HD, 4K) are on it. When each was
    /// added comes from the app's record on the server, which every device
    /// writes to (Emby keeps no such date), else from this device; one
    /// neither knows was put on the list elsewhere meanwhile (another app):
    /// added now. Regression: the server lists My List by name, and Dragon
    /// Ball Z, put on it on the Apple TV, sat eleventh on the iPhone's row,
    /// out of sight. (The first read on a device stamps nothing: the
    /// server's order for titles no device dated.)
    func loadMyList(cardWidth: Int) async {
        myListWidth = cardWidth
        guard let emby else { return }
        async let shared = emby.myListDates()
        guard let found = try? await emby.favorites() else { return }
        let record = await shared
        var added = myListAdded
        for (id, date) in record ?? [:] where (added[id] ?? 0) < date { added[id] = date }
        let defaults = UserDefaults.standard
        if let seen = defaults.stringArray(forKey: Self.myListSeenKey).map(Set.init) {
            let now = Date().timeIntervalSince1970
            for item in found where !seen.contains(item.id) && added[item.id] == nil { added[item.id] = now }
        }
        if added != myListAdded { myListAdded = added }
        defaults.set(found.map(\.id), forKey: Self.myListSeenKey)
        // The record kept to what's on the list, with what this device knows.
        if let record {
            let onList = Set(found.map(\.id))
            // Whole seconds, as the record keeps them.
            let kept = added.filter { onList.contains($0.key) }.mapValues { $0.rounded(.down) }
            if kept != record.mapValues({ $0.rounded(.down) }) { Task { await emby.saveMyListDates(kept) } }
        }
        let order = Dictionary(found.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
        let items = found.sorted { (added[$0.id] ?? 0, -(order[$0.id] ?? 0)) > (added[$1.id] ?? 0, -(order[$1.id] ?? 0)) }
        // One group per title: the first copy (its card) and every key and
        // id of its copies.
        var groups: [(first: EmbyItem, keys: Set<String>, ids: Set<String>)] = []
        for item in items {
            let keys = item.titleKeys
            if let i = groups.firstIndex(where: { !$0.keys.isDisjoint(with: keys) }) {
                groups[i].keys.formUnion(keys)
                groups[i].ids.insert(item.id)
            } else {
                groups.append((item, keys, [item.id]))
            }
        }
        myListCopies = Dictionary(groups.flatMap { group in group.keys.map { ($0, group.ids) } }, uniquingKeysWith: { $0.union($1) })
        let cards = groups.map { emby.card($0.first, context: .poster, shape: .portrait, width: cardWidth) }
        if cards != myList { myList = cards }
        let ids = Set(found.map(\.id))
        if ids != myListIDs { myListIDs = ids }
    }

    /// My List read again (back in the app: something may have been put on
    /// it on another device meanwhile).
    func refreshMyList() async {
        guard let myListWidth else { return }
        await loadMyList(cardWidth: myListWidth)
    }

    /// Whether a title is on My List, in any copy (what the server said of
    /// the title itself until the list is loaded).
    func isOnMyList(_ id: String, item: EmbyItem?) -> Bool {
        guard let myListIDs else { return item?.userData?.isFavorite == true }
        if myListIDs.contains(id) { return true }
        return !copiesOnMyList(item).isEmpty
    }

    /// The ids of this title's copies on My List.
    private func copiesOnMyList(_ item: EmbyItem?) -> Set<String> {
        guard let item else { return [] }
        return item.titleKeys.compactMap { myListCopies[$0] }.reduce(into: Set<String>()) { $0.formUnion($1) }
            .union((myListIDs ?? []).contains(item.id) ? [item.id] : [])
    }

    /// Puts a title on My List or takes it off: on screen at once (the row
    /// on Home too), then on the server; back as it was if that fails.
    func toggleMyList(_ item: EmbyItem, cardWidth: Int = 360) {
        guard let emby else { return }
        let on = !isOnMyList(item.id, item: item)
        let before = (myList, myListIDs, myListCopies)
        var ids = myListIDs ?? []
        // Off: every copy of the title comes off (the other one would
        // bring it back).
        let copies = on ? [item.id] : copiesOnMyList(item).union([item.id])
        if on {
            ids.insert(item.id)
            myList.removeAll { $0.id == item.id }
            myList.insert(emby.card(item, context: .poster, shape: .portrait, width: cardWidth), at: 0)
            myListAdded[item.id] = Date().timeIntervalSince1970
            for key in item.titleKeys { myListCopies[key, default: []].insert(item.id) }
        } else {
            ids.subtract(copies)
            myList.removeAll { copies.contains($0.id) }
            for id in copies { myListAdded[id] = nil }
            for key in item.titleKeys { myListCopies[key] = nil }
            myListCopies = myListCopies.filter { $0.value.isDisjoint(with: copies) }
        }
        myListIDs = ids
        let stamp = myListAdded[item.id]
        Task {
            do {
                for id in copies { try await emby.setFavorite(id, on) }
                // The app's record on the server: the other devices put it
                // first too (or forget it).
                if var record = await emby.myListDates() {
                    if on, let stamp { record[item.id] = stamp } else { for id in copies { record[id] = nil } }
                    await emby.saveMyListDates(record)
                }
            } catch {
                myList = before.0
                myListIDs = before.1
                myListCopies = before.2
            }
        }
    }
}


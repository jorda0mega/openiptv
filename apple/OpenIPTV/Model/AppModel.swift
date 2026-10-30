import CryptoKit
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

    /// The signed-in Emby account's data and work (none signed in: a scope
    /// with no server).
    private(set) var account = AccountScope(client: nil)
    @ObservationIgnored private var session = AccountSession(signedIn: false)
    private var lastCardWidth = 360
    /// The card width My List was last loaded at (iPhone, iPad, Apple TV).
    @ObservationIgnored private var myListWidth: Int?

    // MARK: Live TV

    private(set) var categories: [LiveCategory] = []
    private(set) var allChannels: [LiveChannel] = []
    private(set) var liveLoading = false
    /// Each source's last lineup check (when it answered, why it failed):
    /// the failure lines and Sports' notice derive from it.
    private var liveChecks: [UUID: LineupCheck] = [:]
    /// The one lineup update running; a later caller waits for it.
    @ObservationIgnored private var liveUpdate: Task<Void, Never>?
    /// The saved lineup is shown once, by the first update.
    @ObservationIgnored private var restoredLineup = false
    var selectedCategory: String? {
        didSet { UserDefaults.standard.set(selectedCategory, forKey: "category") }
    }
    private(set) var nowNext: [String: NowNext] = [:]
    private(set) var guideState: GuideStore.State = .idle
    #if DEBUG
    @ObservationIgnored let launchedAt = Date()
    #endif
    /// Live TV by what's on (Sports, News, Movies…), one entry per channel;
    /// see LiveOrganizer.
    private(set) var liveLibrary = LiveOrganizer.Library()
    /// The channel to play for each guide id (the best copy), for guide
    /// search; and channels from abroad, listed after the rest.
    @ObservationIgnored private var guideChannels: [String: LiveChannel] = [:]
    @ObservationIgnored private var abroad: Set<String> = []
    private var liveFailures: LiveFailures = {
        var failures = LiveFailures()
        #if DEBUG
        if let life = ProcessInfo.processInfo.environment["OPENREEL_DEBUG_LIVE_FAILURE_MAX_AGE"].flatMap(Double.init) { failures.channelLife = life }
        #endif
        return failures
    }()
    @ObservationIgnored private var nextMarkEnd: Task<Void, Never>?
    /// A provider category chosen from the full list (rather than a shelf):
    /// kept until the lineup next loads.
    var browsingProviderCategory = false

    static let favoritesID = "__favorites"
    /// The channels of the area set in Settings.
    static let localID = "__local"

    private var providers: [UUID: any LiveProvider] = [:]
    private var channelsByCategory: [String: [LiveChannel]] = [:]
    private var channelById: [String: LiveChannel] = [:]
    /// Channel names prepared for instant search.
    private(set) var channelCorpus = SearchCorpus<LiveChannel>(name: \.name)
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
        session = AccountSession(signedIn: sources.emby != nil)
        account = scope(for: sources.emby)
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
        #if DEBUG
        let home: HomeContent? = ProcessInfo.processInfo.environment["OPENREEL_DEBUG_NO_SAVED_HOME"] != nil ? nil : AppCache.read(AccountScope.homeFile)
        #else
        let home: HomeContent? = AppCache.read(AccountScope.homeFile)
        #endif
        account.restore(home)
        #if DEBUG
        // UI tests (OPENREEL_DEBUG_HOME_STALE): the saved Home is old, so the
        // launch builds every row again.
        if ProcessInfo.processInfo.environment["OPENREEL_DEBUG_HOME_STALE"] != nil { account.homeBuiltAt = .distantPast }
        #endif
        // A launch is a moment Home may change: a build ready in the
        // first seconds goes straight on the page.
        account.homeAwaitsFirstBuild = true
        observeAppState()
        // Watching the connection from the start (speculative work waits
        // until it's known to be unmetered).
        _ = NetworkStatus.shared
        MemoryWarnings.watch()
        ServerSubtitles.atLaunch()
        AccountScope.pruneSaved()
        Task.detached(priority: .background) { AppCache.removeStaleDownloads() }
        // The first screen's pictures, decoded from the disk cache while the
        // app is still drawing its first frame, so Home opens with them.
        if let home {
            let urls = Self.visibleImages(home) + startPictures(home)
            Task.detached(priority: .userInitiated) { await ImagePipeline.shared.prefetch(urls) }
        }
        Task { await guide.loadCache(); guideState = await guide.state }
        library.versionsChanged = { [weak self] in self?.holdContinueWatching() }
        holdContinueWatching()
    }

    /// A scope for `account`'s data and work (nil: none signed in).
    private func scope(for account: EmbyAccount?, readsSaved: Bool = true) -> AccountScope {
        AccountScope(client: account.map { EmbyClient(account: $0, deviceId: sources.deviceId) }, readsSaved: readsSaved,
                     askPlan: { [weak self] emby, key in
                         let shows = await self?.showCopies ?? { @Sendable id in [id] }
                         #if DEBUG
                         let clock = PlanClock(copies: key.versions)
                         await self?.notePlanClock(clock, for: key)
                         return try await PlanClock.$current.withValue(clock) {
                             try await emby.playback(versions: key.versions, kind: key.kind, maxWidth: AppModel.maxWidth, showCopies: shows)
                         }
                         #else
                         return try await emby.playback(versions: key.versions, kind: key.kind, maxWidth: AppModel.maxWidth, showCopies: shows)
                         #endif
                     },
                     retryHome: { [weak self] in await self?.tryHomeAgain() },
                     rowsChanged: { [weak self] in self?.holdContinueWatching() })
    }

    // MARK: Home

    /// The first Home is being built (nothing built shown yet, no error):
    /// the page keeps the hero's space meanwhile.
    var homePending: Bool {
        sources.emby != nil && account.shownBuiltAt == nil && account.homeError == nil && account.featured == nil && account.spotlight.isEmpty
    }
    /// When the app last went to the background.
    @ObservationIgnored private var backgroundedAt: Date?
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
        let scope = account
        guard scope.isOpen else { return }
        if let running = scope.homeLoad, !full { return await running.value }
        let previous = scope.homeLoad
        let id = UUID()
        scope.homeLoadID = id
        let load = scope.run {
            await previous?.value
            await self.buildHome(in: scope, cardWidth: cardWidth, sync: sync, full: full, show: show)
            if scope.homeLoadID == id { scope.homeLoad = nil }
        }
        scope.homeLoad = load
        await load.value
    }

    /// Home came on screen from another tab (or first, at launch): what
    /// was built meanwhile goes on now, before the page is drawn.
    func homeAppeared() {
        showStagedHome(in: account)
    }

    /// Try Again after Home failed: the build under way, else every row
    /// built afresh, and shown.
    func tryHomeAgain() async {
        await loadHome(cardWidth: lastCardWidth, full: account.homeLoad == nil, show: true)
    }

    /// The viewer scrolled Home or moved along it: what's built from now
    /// on waits for the next moment.
    func homeBrowsed() {
        account.homeAwaitsFirstBuild = false
    }

    private func buildHome(in scope: AccountScope, cardWidth: Int, sync: Bool, full: Bool, show: Bool) async {
        lastCardWidth = cardWidth
        guard let emby = scope.emby else {
            scope.rows = []
            scope.featured = nil
            scope.spotlight = []
            scope.stagedHome = nil
            return
        }
        // Trending and versions come from the index and charts on the
        // device: opened while Continue Watching is asked of the server, not
        // before it.
        async let opened: Void = openLibrary(emby)
        var pendingSources: Task<EmbyClient.HomeSources, Error>?
        // A page with no featured title is rebuilt: it was made before
        // anything could be picked (or by a build that was cut off). The
        // newest Home decides (one waiting, else the one shown).
        let newestFeatured = scope.stagedHome.map(\.featured) ?? scope.featured
        if !full, !scope.rows.isEmpty, newestFeatured != nil, let builtAt = scope.homeBuiltAt, Date().timeIntervalSince(builtAt) < 6 * 3600 {
            async let historyChanged = refreshContinueWatching(in: scope, checkingHistory: true)
            await opened
            if library.changedAt.map({ $0 <= builtAt }) ?? true, await !historyChanged {
                if sync { scope.run(priority: .background) { await self.syncLibrary(emby, in: scope) } }
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
            let empty = scope.rows.isEmpty
            var fresh = try await HomeFeed.load(emby, library: library, cardWidth: cardWidth,
                                                backdropWidth: Self.backdropWidth, sources: pendingSources,
                                                early: { row in
                                                    guard empty, scope.rows.isEmpty else { return }
                                                    scope.rows = [row]
                                                })
            // Signed out or into another account meanwhile: not its Home.
            guard scope.isOpen else { return }
            fresh.rows = variedForTests(fresh.rows)
            // The pictures first (all at once), so the page changes in one go
            // instead of covers popping in; on the very first load, show the
            // rows straight away and let the pictures follow. A Home that
            // waits has them ready when it goes on.
            let urls = Self.visibleImages(fresh) + startPictures(fresh)
            let prefetch = Task { await ImagePipeline.shared.prefetch(urls) }
            // Then every other cover on Home into the disk cache (Wi-Fi),
            // so rows further down don't fill in as they scroll into view.
            if NetworkStatus.shared.knownUnmetered {
                let rest = fresh.rows.flatMap(\.cards).compactMap { $0.images.first.flatMap { URL(string: $0.url) } }
                Task(priority: .utility) {
                    await prefetch.value
                    await ImagePipeline.shared.store(rest)
                }
            }
            scope.homeBuiltAt = fresh.builtAt
            scope.homeHistory = fresh.history ?? []
            scope.homeError = nil
            if scope.homeRetry.failing { Task { await refreshMyList() } }
            scope.homeRetry.stop()
            if show || scope.homeOpening {
                // The hero's titles too: a new one undecoded showed black
                // for a moment.
                if !scope.rows.isEmpty, fresh.rows != scope.rows || fresh.featured != scope.featured || (fresh.spotlight ?? []) != scope.spotlight {
                    await Self.wait(for: prefetch, atMost: 1.5)
                }
                guard scope.isOpen else { return }
                scope.homeAwaitsFirstBuild = false
                showHome(fresh, in: scope)
            } else {
                stageHome(fresh, in: scope)
            }
            // The first few things you'd tap on Home are ready before you do:
            // their pages, and how to play the featured one (the rows' get
            // ready as they stay on screen).
            let pages = (fresh.spotlight ?? []).map(\.card) + fresh.rows.prefix(2).flatMap { $0.cards.prefix(4) }
            pages.forEach(prefetchTitle)
            prepareRotation()
            prepare(fresh.featured.map { [$0.card.playTarget] } ?? [], at: .homeForecast)
            if sync { scope.run(priority: .background) { await self.syncLibrary(emby, in: scope) } }
        } catch {
            guard scope.isOpen else { return }
            scope.homeError = SourceError.wrap(error).localizedDescription
            if scope.nothingBuiltShown { scope.homeRetry.askAgainLater() }
        }
    }

    /// Puts a built Home on the page, and saves it as shown (with this
    /// device's stops), not as the server still had it.
    private func showHome(_ fresh: HomeContent, in scope: AccountScope) {
        scope.stagedHome = nil
        // What was just stopped here, even if the server hasn't caught up.
        let freshRows = withStops(fresh.rows, in: scope)
        if freshRows != scope.rows { scope.rows = freshRows }
        if fresh.featured != scope.featured { scope.featured = fresh.featured }
        if (fresh.spotlight ?? []) != scope.spotlight { scope.spotlight = fresh.spotlight ?? [] }
        scope.shownBuiltAt = fresh.builtAt
        scope.shownHistory = fresh.history ?? []
        saveShownHome(of: scope)
    }

    /// Keeps a built Home for the next moment. Its Continue Watching's
    /// progress shows at once when only that changed.
    private func stageHome(_ fresh: HomeContent, in scope: AccountScope) {
        scope.stagedHome = fresh
        offerContinue(reconciled(fresh.rows.first { $0.title == Self.continueTitle }, in: scope), in: scope)
    }

    /// The Home waiting, on the page now (a moment it may change).
    private func showStagedHome(in scope: AccountScope) {
        guard let staged = scope.stagedHome else { return }
        showHome(staged, in: scope)
    }

    private func saveShownHome(of scope: AccountScope) {
        scope.save(AccountScope.homeFile, HomeContent(featured: scope.featured, rows: scope.rows, builtAt: scope.shownBuiltAt,
                                                      history: scope.shownHistory, spotlight: scope.spotlight))
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
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.account.homeRetry.askAgainNow() }
        }
        #endif
    }

    /// Plans asked before the app went away may be out of date, and go: the held cards ask afresh. Only then, not
    /// at launch nor each time it becomes active: that stopped the plans Home's cards had just asked for, and the
    /// cards waiting on them got nothing fetched ahead.
    private func cameBack() {
        if let backgroundedAt {
            account.plans.forget(askedBefore: backgroundedAt)
            holdContinueWatchingAgain()
        }
        guard let away = backgroundedAt.map({ Date().timeIntervalSince($0) }), away >= Self.longAway else { return }
        account.homeAwaitsFirstBuild = true
        showStagedHome(in: account)
        guard account.emby != nil else { return }
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

    private func startPictures(_ home: HomeContent) -> [URL] {
        let cards = home.rows.first { $0.title == "Continue Watching" }?.cards.prefix(3) ?? []
        return cards.compactMap { card in
            startBackdrop(card.episodeId ?? card.id, episode: card.episodeId != nil).first.flatMap { URL(string: $0.url) }
        }
    }

    /// Which copy of a title to play when there are several: the sharpest
    /// on Apple TV; on iPhone and iPad up to 1080p, which looks the same on
    /// their screens and starts sooner.
    #if os(tvOS)
    private static let maxWidth: Int? = nil
    #else
    private static let maxWidth: Int? = 1920
    #endif

    func startBackdrop(_ itemId: String, episode: Bool) -> [CardImage] {
        account.emby?.startBackdrop(itemId: itemId, episode: episode) ?? []
    }

    func tap(_ itemId: String, kind: String?, title: String, images: [CardImage] = [], show: String? = nil) -> TappedFilm {
        let tappedAt = Date()
        let held: FirstPicture = playerShown ? .backdrop : keptPicture(of: itemId)
        let plan = Task { try await playback(itemId: itemId, kind: kind) }
        return TappedFilm(itemId: itemId, kind: kind, title: title, held: held,
                          picture: picture(of: itemId, episode: kind == "Episode", images: images, show: show),
                          tappedAt: tappedAt, start: .asking(plan))
    }

    func planned(_ playback: EmbyPlayback, held: FirstPicture) -> TappedFilm {
        TappedFilm(itemId: playback.itemId, kind: nil, title: playback.title, held: held,
                   picture: picture(of: playback.itemId, episode: playback.seriesId != nil, show: playback.seriesId),
                   tappedAt: Date(), start: .planned(playback))
    }

    func keptPicture(of itemId: String) -> FirstPicture {
        guard let warm = account.warm, warm.key == itemId || warm.playback.itemId == itemId, warm.player.hasStarted, !warm.player.hasFailed
        else { return .backdrop }
        return .still(at: warm.playback.startSeconds ?? 0)
    }

    private func picture(of itemId: String, episode: Bool, images: [CardImage] = [], show: String?) -> UIImage? {
        (startBackdrop(itemId, episode: episode) + images).lazy.compactMap { URL(string: $0.url) }
            .compactMap { ImagePipeline.shared.cached($0) }.first
            ?? ImagePipeline.shared.decoded(of: [itemId] + [show].compactMap(\.self))
    }

    func playback(itemId: String, kind: String? = nil, again: Bool = false) async throws -> EmbyPlayback {
        let started = Date()
        let first = !filmTapped
        filmTapped = true
        let scope = account
        // Just closed here, and kept: no need to ask the server anything.
        if let warm = scope.warm, warm.parked, warm.key == itemId {
            var playback = warm.playback
            playback.resolvedIn = 0
            playback.requestedAt = started
            playback.tap = .at(first: first, planKept: scope.plans.isKept(planKey(itemId, kind: kind)), openPlayer: !warm.player.hasFailed)
            return playback
        }
        library.hurry()
        let key = planKey(itemId, kind: kind)
        let prepared = scope.plans.isKept(key)
        #if DEBUG
        lastPlanKept = prepared
        let planAtTheTap = scope.plans.debugState(key, at: .continueWatching, .likely)
        #endif
        var playback = withLocalResume(try await scope.plan(key, again: again), in: scope)
        #if DEBUG
        lastStartAhead = FileStarts.shelf.debugState(FileStart(playback), at: .continueWatching, .likely) + "; " + AheadTaken.readout(playback.itemId)
        lastPlan = debugPlanClocks[key].map { clock in
            let copy = key.versions.firstIndex(of: playback.itemId).map { "copy \($0 + 1)" } ?? "another item"
            let from = playback.lateSession == nil ? "" : " from its item's source"
            return "\(planAtTheTap) at the tap, " + String(format: "asked %+.2f s, ", clock.asked.timeIntervalSince(started))
                + "played \(copy)\(from) of " + clock.readout(tap: started)
        } ?? "no plan clock"
        #endif
        playback.resolvedIn = Date().timeIntervalSince(started)
        playback.requestedAt = started
        playback.tap = .at(first: first, planKept: prepared, openPlayer: false)
        return playback
    }

    /// The title in its copy heard in `language` (picked in the audio menu,
    /// only another copy has it), from `seconds`: the pick is kept for
    /// every copy, so the copies are chosen again with it.
    func playback(heardIn language: String, instead current: EmbyPlayback, from seconds: Double) async throws -> EmbyPlayback {
        guard let emby = account.emby else { throw SourceError.unexpected("Add your Emby server in Settings.") }
        TrackChoice.rememberAudio(language, role: nil, for: current.trackKeys)
        var next = try await emby.playback(versions: current.copyIds, kind: current.copyKind, maxWidth: Self.maxWidth)
        next.startSeconds = seconds
        next.requestedAt = Date()
        return next
    }

    func planKey(_ itemId: String, kind: String?) -> PlanKey {
        PlanKey(itemId: itemId, kind: kind, versions: library.versions(of: itemId))
    }

    /// A show's copies by its id (another library's), to find an episode
    /// in each of them.
    private var showCopies: @Sendable (String) -> [String] {
        let versions = library.versions
        return { versions[$0] ?? [$0] }
    }

    // MARK: Shows

    /// Brings a show up to date. Saved within the last day: only the
    /// episodes that changed since (usually none) and the next episode;
    /// otherwise everything (which also drops deleted episodes).
    func loadShow(_ id: String) async -> ShowData? {
        let scope = account
        if let running = scope.showLoads[id] { return await running.value }
        guard let emby = scope.emby else { return nil }
        let file = AccountScope.showFile(id)
        let inMemory = scope.shows[id]
        // Registered before anything waits, so a page opening while the
        // same show is being fetched ahead joins that fetch.
        let task = scope.run { () -> ShowData? in
            // The saved copy is read off the main thread (prefetching several
            // shows shouldn't read and decode each on it).
            var previous = inMemory
            if previous == nil { previous = await Task.detached(priority: .utility) { AppCache.read(file) as ShowData? }.value }
            if let previous, Date().timeIntervalSince(previous.loadedAt) < 24 * 3600 {
                async let changes = emby.episodeChanges(of: id, since: previous.loadedAt)
                async let next = emby.nextEpisode(of: id)
                async let like: [EmbyItem]? = previous.similar == nil ? self.moreLikeThis(id, emby: emby) : previous.similar
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
            async let like = self.moreLikeThis(id, emby: emby)
            guard let show = await item, let episodes = try? await list else { return nil }
            return ShowData(show: show, episodes: episodes, nextUp: try? await next, loadedAt: Date(), similar: await like)
        }
        scope.showLoads[id] = task
        let data = await task.value
        if scope.showLoads[id] == task { scope.showLoads[id] = nil }
        // Signed out (or in as someone else) meanwhile: not this account's.
        guard scope.isOpen else { return nil }
        if let data {
            if scope.shows.count > 80 {
                // The oldest go; never a page that's open (or under another).
                for old in scope.shows.filter({ scope.pinned[$0.key] == nil }).sorted(by: { $0.value.loadedAt < $1.value.loadedAt }).prefix(20) {
                    scope.shows[old.key] = nil
                }
            }
            if scope.shows[id] == nil {
                prefetchArt(data.show)
                prefetchStills(data)
            }
            scope.shows[id] = data
            scope.save(AccountScope.showFile(id), data)
        }
        return data
    }

    // MARK: Intent

    /// The titles in rotation ready before they're chosen: their pages and
    /// pictures, and how to play them (the next episode, or where a film
    /// was left), so opening or resuming any of them is instant.
    func prepareRotation() {
        guard !PlaybackActivity.isPlaying else { return }
        let rotation = account.inRotation()
        for (id, kind) in rotation {
            if kind == "Series" { prefetchShows([id]) } else { Task(priority: .utility) { await refreshTitle(id, kind: kind) } }
        }
        prepare(rotation.map { .playable(id: $0.id, kind: $0.kind) }, at: .homeForecast)
    }

    /// Near the end of an episode: the next one's details and how to play it.
    func prepareNext(after playback: EmbyPlayback) {
        Task {
            guard let next = await episode(after: playback) else { return }
            prepare([.playable(id: next.id, kind: "Episode")], at: .upNext)
        }
    }

    /// The first unwatched episode after this one, from the show's data
    /// (loaded when it isn't yet); nil after the last.
    func episode(after playback: EmbyPlayback) async -> EmbyItem? {
        guard let series = playback.seriesId else { return nil }
        var show = account.shows[series]
        if show == nil { show = await loadShow(series) }
        guard let data = show, let index = data.episodes.firstIndex(where: { $0.id == playback.itemId }) else { return nil }
        return data.episodes[(index + 1)...].first { $0.userData?.played != true }
    }

    /// The channels watched most: what's on now and next, ready for Live TV.
    func prepareFavouriteChannels() async {
        let channels = account.favouriteChannels().compactMap { channelById[$0] }
        guard !channels.isEmpty else { return }
        await ensureNowNext(channels)
    }

    // MARK: Films

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
        let scope = account
        if let running = scope.movieLoads[id] { return await running.value }
        guard let emby = scope.emby else { return nil }
        let task = scope.run { () -> MovieData? in
            async let like = self.moreLikeThis(id, emby: emby)
            guard let item = await emby.details(id), scope.isOpen else { return nil }
            // The page's own details (and where you got to) as soon as
            // they're here; titles like it (a slower request) follow.
            if scope.movies[id] == nil { self.prefetchArt(item) }
            scope.movies[id] = MovieData(item: item, similar: scope.movies[id]?.similar ?? [], loadedAt: Date())
            return MovieData(item: item, similar: await like, loadedAt: Date())
        }
        scope.movieLoads[id] = task
        let data = await task.value
        if scope.movieLoads[id] == task { scope.movieLoads[id] = nil }
        guard scope.isOpen else { return nil }
        if let data {
            if scope.movies.count > 80 {
                for old in scope.movies.filter({ scope.pinned[$0.key] == nil }).sorted(by: { $0.value.loadedAt < $1.value.loadedAt }).prefix(20) {
                    scope.movies[old.key] = nil
                }
            }
            scope.movies[id] = data
            scope.save(AccountScope.movieFile(id), data)
        }
        return data
    }

    /// A film's or show's page, brought up to date if it's over five
    /// minutes old (or not loaded yet).
    func refreshTitle(_ id: String, kind: String) async {
        if kind == "Series" {
            if account.shows[id].map({ Date().timeIntervalSince($0.loadedAt) > 300 }) ?? true { _ = await loadShow(id) }
        } else if account.movies[id].map({ Date().timeIntervalSince($0.loadedAt) > 300 }) ?? true {
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
        guard let emby = account.emby, NetworkStatus.shared.knownUnmetered else { return }
        let at = data.episodes.firstIndex { $0.id == data.nextUp?.id } ?? 0
        let around = data.episodes[max(0, at - 2)..<min(data.episodes.count, at + 4)]
        let urls = around.compactMap { emby.card(for: $0, landscape: true, width: 960).images.first.flatMap { URL(string: $0.url) } }
        Task(priority: .utility) { await ImagePipeline.shared.prefetch(urls) }
        #endif
    }

    private func prefetchArt(_ item: EmbyItem) {
        guard let emby = account.emby, NetworkStatus.shared.knownUnmetered else { return }
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
        if let data = account.movies[playback.itemId] {
            var item = data.item
            item.userData = watched(item.userData)
            account.movies[playback.itemId] = MovieData(item: item, similar: data.similar, loadedAt: data.loadedAt)
        }
        guard let series = playback.seriesId, let data = account.cachedShow(series),
              let index = data.episodes.firstIndex(where: { $0.id == playback.itemId }) else { return }
        var episodes = data.episodes
        episodes[index].userData = watched(episodes[index].userData)
        // Finished: the show's Play moves on to the next one at once (as
        // Continue Watching does).
        let nextUp = finished ? episodes[(index + 1)...].first { $0.userData?.played != true } : data.nextUp
        // Keep loadedAt: the next update still asks for everything since.
        account.shows[series] = ShowData(show: data.show, episodes: episodes, nextUp: nextUp, loadedAt: data.loadedAt, similar: data.similar)
    }

    /// The server's Continue Watching, with this device's stops of the last
    /// two minutes over anything older it still says: each one's card in
    /// front (newest first) in place of the server's for that title or
    /// show, also when the server doesn't list it yet.
    private func reconciled(_ row: HomeRow?, in scope: AccountScope) -> HomeRow? {
        scope.recentStops = scope.recentStops.filter { Date().timeIntervalSince($0.value.at) < 120 }
        guard !scope.recentStops.isEmpty else { return row }
        let cards = ContinueStop.applied(scope.recentStops.values, toServer: row?.cards ?? [])
        guard !cards.isEmpty else { return nil }
        let shape = Artwork.Shape.landscape
        return HomeRow(title: "Continue Watching", shape: row?.shape ?? shape.rawValue, aspect: row?.aspect ?? shape.aspect, cards: cards)
    }

    private static let continueTitle = "Continue Watching"

    /// Rows with Continue Watching reconciled (first), and the other rows
    /// without what's in it.
    private func withStops(_ rows: [HomeRow], in scope: AccountScope) -> [HomeRow] {
        guard !scope.recentStops.isEmpty else { return rows }
        return Self.replacingContinue(in: rows, with: reconciled(rows.first { $0.title == Self.continueTitle }, in: scope))
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
    private func offerContinue(_ row: HomeRow?, now: Bool = false, in scope: AccountScope) {
        let shown = scope.rows.first { $0.title == Self.continueTitle }
        let opening = scope.homeOpening
        let mayMove = opening || now || scope.continueMovesUntil.map { Date() < $0 } ?? false
        // The newest Continue Watching always waits too, so a moment
        // later never puts an older one back.
        if var staged = scope.stagedHome {
            staged.rows = Self.replacingContinue(in: staged.rows, with: row)
            scope.stagedHome = staged
        }
        // The same cards: the same titles and, for shows, the same
        // episodes (a show's card moving on to its next episode is a new
        // card, not progress).
        func identity(_ row: HomeRow?) -> [String]? { row?.cards.map { $0.id + "|" + ($0.episodeId ?? "") } }
        if mayMove || identity(row) == identity(shown) {
            // Opening, the other rows lose what's now in it; otherwise
            // they stay as they are until the next moment.
            let updated = opening ? Self.replacingContinue(in: scope.rows, with: row) : Self.settingContinue(in: scope.rows, to: row)
            if updated != scope.rows {
                scope.rows = updated
                saveShownHome(of: scope)
            }
        } else if scope.stagedHome == nil {
            scope.stagedHome = HomeContent(featured: scope.featured, rows: Self.replacingContinue(in: scope.rows, with: row),
                                           builtAt: scope.shownBuiltAt, history: scope.shownHistory, spotlight: scope.spotlight)
        }
    }

    /// Continue Watching as it'll be, straight away when playback stops
    /// (the server's answer follows): the title just watched first with its
    /// new progress; once finished, a show's next episode instead (as the
    /// TV app does), a film gone. A title that wasn't in the row joins it.
    private func patchContinueWatching(_ playback: EmbyPlayback, seconds: Double) {
        let scope = account
        guard let emby = scope.emby else { return }
        let page = scope.rows
        // The player closing is a moment for Continue Watching: what the
        // server said meanwhile goes on first, this stop over it, and the
        // server's answer for the stop may still move cards.
        if let staged = scope.stagedHome {
            let updated = Self.settingContinue(in: scope.rows, to: staged.rows.first { $0.title == Self.continueTitle })
            if updated != scope.rows { scope.rows = updated }
        }
        scope.continueMovesUntil = Date().addingTimeInterval(10)
        let duration = playback.durationSeconds ?? 0
        let finished = duration > 0 && seconds >= duration * 0.9
        let progress = duration > 0 ? seconds / duration * 100 : nil
        let index = scope.rows.firstIndex { $0.title == Self.continueTitle }
        let shown = index.map { scope.rows[$0].cards } ?? []
        let old = shown.first { $0.id == playback.itemId || $0.episodeId == playback.itemId }
        func card(_ item: EmbyItem) -> Card? { emby.showRow(Self.continueTitle, [item], lastCardWidth)?.cards.first }
        var lead: Card?
        if let series = playback.seriesId, let data = scope.shows[series],
           let at = data.episodes.firstIndex(where: { $0.id == playback.itemId }) {
            let next = finished ? data.episodes[(at + 1)...].first { $0.userData?.played != true } : data.episodes[at]
            lead = next.flatMap(card)
        } else if let item = scope.movies[playback.itemId]?.item {
            lead = finished ? nil : card(item)
        } else if let old, !finished {
            var card = old
            card.progress = progress ?? old.progress
            lead = card
        }
        let outcome: ContinueStop.Outcome = if let lead { .card(lead) } else if finished { .gone } else { .progress(progress) }
        let stop = ContinueStop(itemId: playback.itemId, at: Date(), outcome: outcome, seriesId: playback.seriesId,
                                seriesName: playback.seriesName)
        scope.recentStops[playback.itemId] = stop
        let cards = stop.applied(to: shown)
        let shape = Artwork.Shape.landscape
        let row = cards.isEmpty ? nil : HomeRow(title: Self.continueTitle, shape: index.map { scope.rows[$0].shape } ?? shape.rawValue,
                                                aspect: index.map { scope.rows[$0].aspect } ?? shape.aspect, cards: cards)
        let updated = Self.settingContinue(in: scope.rows, to: row)
        if updated != scope.rows { scope.rows = updated }
        // The Home waiting has it too.
        if var staged = scope.stagedHome {
            staged.rows = Self.replacingContinue(in: staged.rows, with: row)
            scope.stagedHome = staged
        }
        // Saved now: the server's answer for this stop often matches it,
        // and then saves nothing.
        if scope.rows != page { saveShownHome(of: scope) }
    }

    /// Loads shows the user is likely to open next, in the background.
    func prefetchShows(_ ids: [String], force: Bool = false) {
        for id in ids where force || account.shows[id].map({ Date().timeIntervalSince($0.loadedAt) > 300 }) ?? true {
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
    /// `returning`: back in the app, where it goes on at once (what was
    /// watched on another device meanwhile is your own, not a
    /// recommendation; it waited for the next moment and looked unsynced).
    @discardableResult
    func refreshContinueWatching(checkingHistory: Bool = false, afterStop: Bool = false, returning: Bool = false) async -> Bool {
        await refreshContinueWatching(in: account, checkingHistory: checkingHistory, afterStop: afterStop, returning: returning)
    }

    @discardableResult
    private func refreshContinueWatching(in scope: AccountScope, checkingHistory: Bool = false, afterStop: Bool = false,
                                         returning: Bool = false) async -> Bool {
        guard let emby = scope.emby else { return false }
        async let watching = emby.watching()
        async let nextUp = emby.nextUp()
        async let played: [EmbyItem]? = checkingHistory ? (try? await emby.played(limit: 10)) : nil
        guard let watching = try? await watching else { return false }
        if let played = await played,
           HomeFeed.seeds(watching: watching, played: played).map(\.id) != scope.homeHistory {
            return true
        }
        let items = HomeFeed.continueItems(watching: watching, nextUp: (try? await nextUp) ?? [])
        let server = emby.showRow(Self.continueTitle, items, lastCardWidth).map { variedForTests([$0], numbered: false)[0] }
        let row = reconciled(server, in: scope)
        offerContinue(row, now: returning, in: scope)
        if afterStop { scope.continueMovesUntil = nil }
        return false
    }

    // MARK: Warm start

    @ObservationIgnored private var filmTapped = false

    /// A title's preview stills, fetched once (joining a fetch under way).
    func previewStills(_ itemId: String) async -> Data? {
        let scope = account
        if let data = cachedPreviewStills(itemId) { return data }
        if let running = scope.previewLoads[itemId] {
            let data = await running.value
            return scope.isOpen ? data : nil
        }
        guard let emby = scope.emby else { return nil }
        let task = scope.run(priority: .utility) { await emby.previewThumbnails(itemId: itemId) }
        scope.previewLoads[itemId] = task
        let data = await task.value
        if scope.previewLoads[itemId] == task { scope.previewLoads[itemId] = nil }
        guard scope.isOpen else { return nil }
        if let data { scope.previews = Array((scope.previews.filter { $0.id != itemId } + [(itemId, data)]).suffix(2)) }
        return data
    }

    /// Stills already here, without waiting.
    func cachedPreviewStills(_ itemId: String) -> Data? {
        account.previews.first { $0.id == itemId }?.data
    }

    /// What plays next in the player screen, opened out of sight and paused
    /// at `playback`'s start (another copy of the title, for a language
    /// only it has): the screen keeps playing meanwhile and hands over once
    /// its picture is ready (see takeWarm). Unlike work ahead, while something
    /// plays and on any connection: it was asked for.
    func warmSwitch(_ playback: EmbyPlayback, options: [(String, String)], hardwareDecoding: Bool) -> MPVPlayer {
        account.coolDown()
        let player = MPVPlayer(options: options + [("pause", "yes")], hardwareDecoding: hardwareDecoding,
                               picture: .film(playback.surface))
        player.prepareOffscreen()
        player.load(playback.url, headers: playback.headers, start: playback.startSeconds, film: playback.itemId, readahead: .warm,
                    tracks: playback.tracks)
        player.addSubtitles(playback.subtitleFiles, references: playback.subtitleReferences, speech: playback.speechStretches)
        player.addCopies(playback.subtitleCopies)
        account.keepWarm(player, playback, parked: false, for: .seconds(120))
        return player
    }

    /// The player kept for this episode or movie, if it's open at `start`
    /// (see AccountScope.takeWarm).
    func takeWarm(_ itemId: String, at start: Double?) -> MPVPlayer? {
        account.takeWarm(itemId, at: start) as? MPVPlayer
    }

    /// Keeps a player that just closed, paused where it stopped, for five
    /// minutes: the title chosen again carries on at once. Not at the end
    /// (the next episode, or the start, plays then).
    func park(_ player: MPVPlayer, _ playback: EmbyPlayback) {
        let seconds = playback.startSeconds ?? 0
        guard let duration = playback.durationSeconds, duration > 0, seconds < duration * 0.9 else { return player.shutdown() }
        account.coolDown()
        player.onEvent = nil
        player.setPaused(true)
        player.setReadahead(.warm)
        account.keepWarm(player, playback, parked: true, for: .seconds(300))
    }

    private func withLocalResume(_ playback: EmbyPlayback, in scope: AccountScope) -> EmbyPlayback {
        guard let stop = scope.stops[playback.itemId], Date().timeIntervalSince(stop.at) < 1800 else { return playback }
        var playback = playback
        playback.startSeconds = stop.seconds > 0 ? stop.seconds : nil
        return playback
    }

    #if DEBUG
    @ObservationIgnored var lastPlanKept = false
    @ObservationIgnored var lastStartAhead = ""
    /// The last start's plan, request by request (PlanClock).
    @ObservationIgnored var lastPlan = ""
    @ObservationIgnored private var debugPlanClocks: [PlanKey: PlanClock] = [:]

    private func notePlanClock(_ clock: PlanClock, for key: PlanKey) {
        debugPlanClocks[key] = clock
    }
    /// UI tests: the last switch to another copy's language, timed.
    var debugCopySwitch = ""
    /// UI tests: the search for a film heard in English or Spanish only in
    /// another copy, counts only.
    var debugCopyFilm = ""
    /// UI tests (-debugServerProbe YES): the server's own state at launch.
    var debugServer = ""

    /// The film read is Continue Watching's first card's; none with
    /// -noFileProbe YES (a start that finds the file not yet read).
    func debugProbeServer() async {
        let fileProbe = !UserDefaults.standard.bool(forKey: "noFileProbe")
        for _ in 0..<300 where sources.emby == nil || (fileProbe && continueCard == nil) { try? await Task.sleep(for: .milliseconds(200)) }
        guard let account = sources.emby else { return }
        let film: String? = switch continueCard?.playTarget {
        case let .playable(id, _)? where fileProbe, let .title(id, _)? where fileProbe: id
        default: nil
        }
        debugServer = await ServerProbe.measure(account, film: film)?.readout ?? "server: no answer"
    }

    private var continueCard: Card? { account.rows.first { $0.title == Self.continueTitle }?.cards.first }

    func debugFilmHeardOnlyInAnotherCopy(limit: Int = 12) async -> EmbyPlayback? {
        for _ in 0..<90 where library.versions.isEmpty { try? await Task.sleep(for: .seconds(1)) }
        let films = Set(library.versions.values.filter { $0.count > 1 }.map { $0.sorted() })
            .filter { $0.contains { library.entry($0)?.kind == "Movie" } }
            .sorted { $0[0] < $1[0] }
        var checked = 0
        for copies in films.prefix(limit) {
            checked += 1
            guard let playback = try? await playback(itemId: copies[0], kind: "Movie"), !playback.englishOrSpanishOnlyInOtherCopies.isEmpty else { continue }
            debugCopyFilm = "films with copies \(films.count), checked \(checked), found yes"
            return playback
        }
        debugCopyFilm = "films with copies \(films.count), checked \(checked), found no"
        return nil
    }
    #endif

    var playerShown = false {
        didSet { holdContinueWatching() }
    }

    /// Continue Watching's first two cards, held from launch rather than from when Home shows them, till a film plays:
    /// their plans, starts and connections go before the tap, so a server slow on its first read after a while is slow
    /// before it.
    /// A card is held again from the start when what its plan is asked for changes: another copy the library found
    /// (versionsChanged), another account.
    /// A closed account's cards are held by nothing (its rows stay on the page until the server logs it out).
    private func holdContinueWatching() {
        let cards = account.rows.first { $0.title == Self.continueTitle }?.cards ?? []
        let targets = playerShown || Self.noPrepareAhead || !account.isOpen ? [] : cards.prefix(2).map(\.playTarget)
        let keys = Dictionary(targets.map { ($0, planKey($0)) }, uniquingKeysWith: { first, _ in first })
        let sameAsk = targets.filter { account.heldPlans[$0] == keys[$0] }
        ahead.hold(only: sameAsk, at: .homeForecast)
        account.heldPlans = keys
        ahead.hold(only: targets, at: .homeForecast)
    }

    /// Every held card asked afresh: their plans were forgotten, or are another account's.
    private func holdContinueWatchingAgain() {
        account.heldPlans = [:]
        holdContinueWatching()
    }

    @ObservationIgnored private(set) lazy var ahead = Ahead(Ahead.Work(
        page: { [weak self] target, interest in await self?.preparePage(target, interest) },
        plan: { [weak self] target, interest in await self?.preparePlan(target, interest, held: true) },
        fileStart: { [weak self] start, interest in
            guard !AppModel.noStreamAhead else { return }
            await self?.forAccount { _ = await FileStarts.shelf.hold(FileStart(start), for: interest) }
        },
        connection: { [weak self] start, interest in
            guard !AppModel.noStreamAhead, !AppModel.noPreconnect else { return }
            await self?.forAccount { await Connections.keepWarm(FileStart(start), for: interest) }
        },
        subtitle: { [weak self] subtitle, interest in await self?.forAccount { await ServerSubtitles.warm(subtitle, for: interest) } },
        previews: { [weak self] plan, interest in
            await Lane.embyFiles.whenAllowed(for: interest) { _ = await self?.previewStills(plan.itemId) }
        }))

    /// Work fetched ahead for the signed-in account: none with no account,
    /// and it stops when the account closes.
    private func forAccount(_ job: @escaping @MainActor () async -> Void) async {
        let scope = account
        guard scope.emby != nil else { return }
        await scope.attach(job)
    }

    #if DEBUG
    var aheadCounts: String {
        let now = Conditions.current()
        let lanes: [(String, Lane)] = [("plans", .emby), ("starts", .fileStarts), ("warm reads", .connections)]
        let refused = lanes.filter { $0.1.debugRefused > 0 }.map { name, lane in
            " | \(name) refused \(lane.debugRefused), last: " + (lane.debugLastRefusal.map { "\($0)" } ?? "none")
        }
        return "held \(ahead.held) plans \(account.plans.fetched) starts \(FileStarts.shelf.fetched) warmed \(StreamRelay.warmed.value) "
            + "files \(ServerSubtitles.beside.fetched) "
            + "copies \(ServerSubtitles.inFile.fetched) | \(now.network) " + String(format: "disk %.1f GB", Double(now.freeDisk.bytes) / 1e9)
            + " thermal \(now.thermal.rawValue)"
            + (now.lowPower ? " low power" : "") + (now.memoryWarned ? " memory warned" : "") + (now.playing ? " playing" : "")
            + (Lane.fileStarts.debugRefusal(at: .continueWatching, .likely).map { " | starts not allowed: \($0)" } ?? "")
            + " | no plan \(ahead.planless), plans failed \(account.plans.failed), last \(account.plans.lastFailure), stopped \(account.plans.stopped)"
            + ", starts failed \(FileStarts.shelf.failed) stopped \(FileStarts.shelf.stopped)" + refused.joined()
            + " | holds: " + ahead.trail.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    }
    #endif

    private func preparePage(_ target: Target, _ interest: Interest) async {
        guard case let .title(id, kind) = target else { return }
        await Lane.emby.whenAllowed(for: interest) {
            if kind == "Series" { prefetchShows([id]) } else { await refreshTitle(id, kind: kind) }
        }
    }

    /// `held`: for a card's hold, which waits for the device to allow it (prepare's asks go once).
    private func preparePlan(_ target: Target, _ interest: Interest, held: Bool = false) async -> EmbyPlayback? {
        let scope = account
        let key = planKey(target)
        let plan = if held { await scope.plans.hold(key, for: interest) } else { await scope.plans.warm(key, for: interest) }
        return scope.isOpen ? plan.map { withLocalResume($0, in: scope) } : nil
    }

    private func planKey(_ target: Target) -> PlanKey {
        switch target {
        case let .title(id, kind): planKey(id, kind: kind)
        case let .playable(id, kind): planKey(id, kind: kind)
        }
    }

    /// Continue Watching's cards' plans as the row shows (Plans.forecast).
    func forecastPlans(_ cards: [Card]) async {
        guard !Self.noPrepareAhead, !Self.noPlanForecast else { return }
        await Plans.forecast(cards.map { planKey($0.playTarget) }, on: account.plans)
    }

    /// Subtitle files found for a film heard in neither English nor
    /// Spanish with none in either: the server's providers are asked
    /// (English first), and the likeliest few (made for this file, then
    /// the most downloaded) are read through the server and kept on the
    /// device, unless written in another language. Returned likeliest
    /// first, or only the one picked before (`notePickedSubtitle`): the
    /// player shows the first at once and puts another in its place if it
    /// fits the film clearly better. Asked once a week at most when none
    /// are found; nothing is asked when the film has what's needed or the
    /// files are on the device. Regression: the server was asked to
    /// download the most downloaded one, which an account without the
    /// right to manage subtitles may not, so those films never had any.
    func findMissingSubtitles(for playback: EmbyPlayback) async -> [EmbyPlayback.SubtitleFile] {
        #if DEBUG
        NSLog("%@", "PERF subtitles needed? wanted=\(playback.tracks?.subtitles ?? []) has=\(playback.subtitleLanguages.sorted()) source=\(playback.mediaSourceId ?? "none")")
        #endif
        guard let emby = account.emby, let wanted = playback.tracks?.subtitles,
              playback.subtitleLanguages.isDisjoint(with: ["en", "es"]) else { return [] }
        let folder = FoundSubtitles.folder(playback.itemId)
        #if DEBUG
        // UI tests: `-forgetSubtitleSearches YES` asks again.
        let forget = UserDefaults.standard.bool(forKey: "forgetSubtitleSearches")
        if forget { try? FileManager.default.removeItem(at: folder) }
        #else
        let forget = false
        #endif
        if let kept = FoundSubtitles.read(folder)?.subtitleFiles(in: folder), !kept.isEmpty { return kept }
        let key = "subtitleSearch." + playback.itemId
        let recent = (UserDefaults.standard.object(forKey: key) as? Date).map { Date().timeIntervalSince($0) < 7 * 86_400 } ?? false
        if recent, !forget { return [] }
        let languages = wanted.compactMap { TrackChoice.normalized($0) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        for language in languages {
            let code = language == "es" ? "spa" : "eng"
            let found: [EmbyClient.RemoteSubtitle]
            do { found = try await emby.searchSubtitles(playback.itemId, mediaSourceId: playback.mediaSourceId, language: code) } catch {
                #if DEBUG
                NSLog("%@", "PERF subtitles search failed")
                #endif
                // Asked again next time.
                return []
            }
            // One made for this very file fits it: the only one read. The
            // others all at once.
            let tried = Array(found.prefix(found.first?.IsHashMatch == true ? 1 : FoundSubtitles.tried))
            let texts = await withTaskGroup(of: (Int, String?).self) { group in
                for (n, candidate) in tried.enumerated() { group.addTask { (n, await emby.subtitleText(id: candidate.Id)) } }
                var texts = [String?](repeating: nil, count: tried.count)
                for await (n, text) in group { texts[n] = text }
                return texts
            }
            var kept: [FoundSubtitles.File] = []
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (candidate, text) in zip(tried, texts) {
                guard let text, SubtitleSync.cues(text).count >= 10, !SubtitleLanguage.writtenInAnother(language, text) else { continue }
                let name = "\(kept.count).\(text.contains("[Events]") ? "ass" : text.hasPrefix("WEBVTT") ? "vtt" : "srt")"
                guard (try? text.write(to: folder.appending(path: name), atomically: true, encoding: .utf8)) != nil else { continue }
                kept.append(.init(name: name, id: candidate.Id, language: code))
            }
            #if DEBUG
            NSLog("%@", "PERF subtitles found \(found.count) \(language), kept \(kept.map(\.id))")
            #endif
            guard !kept.isEmpty else { continue }
            let index = FoundSubtitles(files: kept, picked: nil)
            index.write(folder)
            return index.subtitleFiles(in: folder)
        }
        UserDefaults.standard.set(Date(), forKey: key)
        return []
    }

    /// The found file that fits the film best (the player matched them):
    /// the only one from now on, and saved on the server too when the
    /// account may (then it's one of the film's files for every app).
    func notePickedSubtitle(itemId: String, mediaSourceId: String?, url: URL) {
        let folder = FoundSubtitles.folder(itemId)
        guard var index = FoundSubtitles.read(folder), let file = index.files.first(where: { $0.name == url.lastPathComponent }),
              index.picked != file.name else { return }
        index.picked = file.name
        index.write(folder)
        #if DEBUG
        NSLog("%@", "PERF subtitles picked \(file.id)")
        #endif
        guard let emby = account.emby else { return }
        Task(priority: .utility) {
            do { try await emby.downloadSubtitle(itemId, mediaSourceId: mediaSourceId, id: file.id) } catch {
                #if DEBUG
                NSLog("%@", "PERF subtitles not saved on the server")
                #endif
            }
        }
    }

    /// Works out how to play these in the background; a later tap uses it.
    func prepare(_ targets: [Target], at place: Place) {
        guard !Self.noPrepareAhead else { return }
        let interest = Interest(at: place, .likely)
        for target in targets { Task { _ = await preparePlan(target, interest) } }
    }

    /// The same item converted by the server at `bitrate`, from `start`,
    /// with the audio track at `audio` (its place in the file). Its play
    /// session is set as it opens (EmbyPlayback.opening).
    func convertedURL(for playback: EmbyPlayback, bitrate: Int, start: Double, copy: Bool = false, audio: Int? = nil) -> URL? {
        account.emby?.hlsURL(playback.itemId, mediaSourceId: playback.mediaSourceId ?? playback.itemId,
                     playSessionId: nil, start: start, bitrate: bitrate, copy: copy, audioStreamIndex: audio)
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
        await account.emby?.diagnose(playback) ?? ""
    }

    func prepareLibrary(checkingChanges: Bool = false) async {
        let scope = account
        guard let emby = scope.emby else { return }
        await scope.attach { await self.syncLibrary(emby, in: scope, urgent: checkingChanges) }
    }

    private func syncLibrary(_ emby: EmbyClient, in scope: AccountScope, urgent: Bool = false) async {
        guard scope.isOpen else { return }
        let before = library.trending.prefix(40).map(\.id)
        let hadNotable = !library.notable.isEmpty
        async let charts: Void = library.refreshCharts(unmetered: NetworkStatus.shared.unmetered)
        await library.prepare(emby, now: urgent)
        // IMDb's genres and makers for the library's titles (Wi-Fi, about
        // monthly), in the background; the first time they arrive, Top
        // picks are remade from them (on the page at the next moment, see
        // stagedHome). Hundreds of megabytes, so not in the
        // first two minutes: browsing and a first play get the connection,
        // and a quick look doesn't start a download it won't finish.
        let hadCatalog = library.catalog != nil
        // One at a time, owned by the account, so signing out stops it.
        scope.catalogJob?.cancel()
        scope.catalogJob = scope.run(priority: .background) { [library] in
            try? await Task.sleep(for: .seconds(120))
            guard !Task.isCancelled else { return }
            await withTaskCancellationHandler {
                await library.refreshCatalog(unmetered: NetworkStatus.shared.knownUnmetered)
            } onCancel: {
                Task { @MainActor in library.cancelCatalog() }
            }
            guard !Task.isCancelled else { return }
            if !hadCatalog, library.catalog != nil {
                await scope.run(priority: .utility) { await self.loadHome(cardWidth: self.lastCardWidth, sync: false, full: true) }.value
            }
        }
        await charts
        guard scope.isOpen else { return }
        // New titles since Home was built: its other rows are built again,
        // and go on at the next moment, not while you look.
        if let changed = library.changedAt, let built = scope.homeBuiltAt, changed > built {
            await scope.run(priority: .utility) { await self.loadHome(cardWidth: self.lastCardWidth, sync: false, full: true) }.value
            return
        }
        // Trending or New & notable arrived for the first time (Home was
        // built without them): rebuild once, for the next moment. Otherwise
        // a later build picks them up.
        if (before.isEmpty && !library.trending.isEmpty) || (!hadNotable && !library.notable.isEmpty) {
            // Full: a recent page (built from the newest additions) would
            // otherwise only refresh Continue Watching.
            await scope.run(priority: .utility) { await self.loadHome(cardWidth: self.lastCardWidth, sync: false, full: true) }.value
        }
    }

    func playback(for card: Card) async throws -> EmbyPlayback {
        try await playback(itemId: card.id, kind: card.kind)
    }

    /// The title's page and Home as they'll be after this stop, before the
    /// server hears; called while the player is still up, so the page
    /// appears as it will stay (nothing changes on it after).
    func noteStop(_ playback: EmbyPlayback, seconds: Double) {
        let duration = playback.durationSeconds ?? 0
        account.stops[playback.itemId] = (duration > 0 && seconds >= duration * 0.9 ? 0 : seconds, Date())
        // Where it was stopped, for every device's Continue Watching (the
        // server keeps nothing this early in a title).
        let finished = duration > 0 && seconds >= duration * 0.9
        if let emby = account.emby { account.run(priority: .utility) { await emby.noteStarted(playback.itemId, seconds: finished ? nil : seconds) } }
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
        let scope = account
        if event == .started {
            scope.notePlay(playback.seriesId ?? playback.itemId, kind: playback.seriesId != nil ? "Series" : "Movie")
        }
        if event == .stopped, !noted {
            noteStop(playback, seconds: seconds)
        }
        // In the order they happened: a progress report sent a moment before
        // Stopped must not land after it and move the resume point back.
        let client = scope.emby
        if event == .progress {
            let waiting = scope.queuedProgress != nil
            scope.queuedProgress = (playback, seconds)
            if waiting { return }
            await enqueueReport(in: scope) {
                guard let (playback, seconds) = scope.queuedProgress else { return }
                scope.queuedProgress = nil
                await client?.report(.progress, itemId: playback.itemId, seconds: seconds,
                                     mediaSourceId: playback.mediaSourceId, playSessionId: await playback.session())
            }.value
            return
        }
        await enqueueReport(in: scope) {
            await client?.report(event, itemId: playback.itemId, seconds: seconds,
                                 mediaSourceId: playback.mediaSourceId, playSessionId: await playback.session())
        }.value
        guard event == .stopped, scope.isOpen else { return }
        scope.plans.forget { $0.itemId == playback.itemId || $0.itemId == playback.seriesId }
        // A player kept for this title stays if it's where this stopped.
        if let warm = scope.warm, warm.key == playback.itemId || (playback.seriesId != nil && warm.key == playback.seriesId),
           warm.playback.itemId != playback.itemId || abs((warm.playback.startSeconds ?? 0) - seconds) >= 2 {
            scope.coolDown()
        }
        if let series = playback.seriesId { prefetchShows([series], force: true) }
        // Only Continue Watching changed; the rest of Home stays as it is.
        await refreshContinueWatching(in: scope, afterStop: true)
    }

    private func enqueueReport(in scope: AccountScope, _ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = scope.reportChain
        let task = Task {
            await previous?.value
            await work()
        }
        scope.reportChain = task
        return task
    }

    // MARK: Accounts

    func signedInToEmby(_ account: EmbyAccount) async {
        await send(.signedIn(account))
    }

    func signOutOfEmby() async {
        await send(.signOut)
    }

    func forgetEverything() async {
        await send(.forgetEverything)
    }

    func add(_ source: IPTVSource) async {
        sources.add(source)
        await loadLive(force: true)
    }

    func remove(_ source: IPTVSource) async {
        sources.remove(source)
        await loadLive()
    }

    /// One account change at a time: a sign-out asked during a sign-in
    /// waits for it to finish.
    @ObservationIgnored private var accountChange: Task<Void, Never>?

    private func send(_ event: AccountSession.Event) async {
        let previous = accountChange
        let change = Task {
            await previous?.value
            await apply(event)
        }
        accountChange = change
        await change.value
    }

    private func apply(_ event: AccountSession.Event) async {
        for effect in session.on(event) {
            if let next = await run(effect) { await apply(next) }
        }
    }

    /// The event an effect leads to, if any.
    private func run(_ effect: AccountSession.Effect) async -> AccountSession.Event? {
        switch effect {
        case .closeScope:
            account.close()
            holdContinueWatchingAgain()
        case .forgetShared:
            StreamRelay.shared.forgetAccount()
            FileStarts.shelf.forgetAll()
            library.clear()
            await ServerSubtitles.forgetAll()
        case .logOut:
            // Where the last film stopped reaches the server before the account leaves it.
            await account.reportChain?.value
            await sources.emby.map { EmbyClient(account: $0, deviceId: sources.deviceId) }?.logout()
            return .loggedOut
        case let .wipe(wipe):
            sources.setEmby(nil)
            AccountScope.removeSaved()
            Self.forgetMyListOrder()
            account = scope(for: nil, readsSaved: false)
            holdContinueWatchingAgain()
            if wipe == .everything {
                sources.forgetEverything()
                await forgetLiveTV()
                await guide.clear()
                AppCache.remove(Self.lineupFile)
            }
        case let .open(signedIn):
            sources.setEmby(signedIn)
            account = scope(for: signedIn)
            holdContinueWatchingAgain()
        case .loadHome:
            async let list: Void = refreshMyList()
            await loadHome(cardWidth: lastCardWidth, full: true, show: true)
            await list
        }
        return nil
    }

    // MARK: Live TV

    /// Sports and the providers' event lists: game names change game by
    /// game.
    private static var gamesMaxAge: TimeInterval {
        #if DEBUG
        // UI tests set a shorter wait.
        if let seconds = ProcessInfo.processInfo.environment["OPENREEL_DEBUG_GAMES_MAX_AGE"].flatMap(Double.init) { return seconds }
        #endif
        return 15 * 60
    }

    /// Every other page, and the lineup fetched at launch.
    private static let lineupMaxAge: TimeInterval = 3600

    /// How old the lineup may be for `page` (a shelf, Favorites, Local, or
    /// a provider category browsed from the full list).
    private func liveMaxAge(_ page: String?) -> TimeInterval {
        if page == LiveOrganizer.sportsID { return Self.gamesMaxAge }
        if let page, liveLibrary.eventCategories.contains(page) { return Self.gamesMaxAge }
        return Self.lineupMaxAge
    }

    /// Keeps the lineup as current as `page` needs for as long as the
    /// calling task runs: a page's task, so it stops when the page goes or
    /// the app leaves the front (View.keepsLiveCurrent). Sports also picks
    /// up what other devices found not playing.
    func keepLiveCurrent(showing page: String?) async {
        while !Task.isCancelled {
            await updateLive(for: page)
            guard !Task.isCancelled else { return }
            if page == LiveOrganizer.sportsID { await readGamesOtherDevicesFoundNotPlaying() }
            let maxAge = liveMaxAge(page)
            let next = sources.iptv.map { liveChecks[$0.id, default: LineupCheck()].nextAsk(maxAge: maxAge) }.min()
            let wait = min(max(next?.timeIntervalSinceNow ?? maxAge, 1), maxAge)
            try? await Task.sleep(for: .seconds(wait))
        }
    }

    /// The lineup for no page in particular; `force` asks every source now.
    /// An update already running is waited for first.
    func loadLive(force: Bool = false) async {
        await updateLive(for: nil, force: force)
    }

    /// Forget everything: no subscription's lineup, check, session or
    /// guide state is left in memory.
    private func forgetLiveTV() async {
        if let update = liveUpdate {
            update.cancel()
            await update.value
        }
        await applyLineup(categories: [], channels: [])
        selectedCategory = nil
        clearNowNext()
        providers = [:]
        liveChecks = [:]
        providerEPG = [:]
        guideState = .idle
    }

    /// One line per source whose last check failed ("Test: Your provider
    /// is busy right now (too many requests).").
    var liveErrors: [String] {
        sources.iptv.compactMap { source in
            liveChecks[source.id]?.problem.map { "\(source.name): \($0.localizedDescription)" }
        }
    }

    var gamesNotice: GamesNotice {
        let checks = sources.iptv.map { liveChecks[$0.id, default: LineupCheck()] }
        let failed = checks.filter { $0.problem != nil }
        if !failed.isEmpty {
            return .couldNotUpdate(lastUpdated: failed.compactMap(\.answeredAt).min(), reason: liveErrors.joined(separator: " "))
        }
        if liveLoading, checks.contains(where: { $0.askedAt == nil }) { return .checking }
        return .current
    }

    /// One update at a time: a caller arriving mid-update waits for it,
    /// then decides with what it left, so at a launch the saved lineup is
    /// in before anyone decides whether to ask. The update runs in its own
    /// task: a page leaving never cuts a load off halfway.
    private func updateLive(for page: String?, force: Bool = false) async {
        while let running = liveUpdate {
            await running.value
            // Whoever wakes first lets go of the finished update: waiting on
            // a finished task returns without yielding, so a waiter that
            // left this to the task's starter could spin here forever.
            if liveUpdate == running { liveUpdate = nil }
        }
        // A page that went meanwhile asks for nothing.
        guard !Task.isCancelled else { return }
        // userInitiated: HTTP sends a read at utility or below on its
        // prefetch connections, where it may be sent twice.
        let update = Task(priority: .userInitiated) { await runLiveUpdate(for: page, force: force) }
        liveUpdate = update
        #if canImport(UIKit)
        // The app leaving mid-check doesn't cut it off: suspended, it would
        // come back as the provider failing and wait the whole interval.
        // Out of background time it's stopped, which counts as no check.
        let background = BackgroundTime("Live TV lineup") { update.cancel() }
        defer { background.end() }
        #endif
        await update.value
        if liveUpdate == update { liveUpdate = nil }
    }

    /// The lineup saved on the device (names, logos, categories; never a
    /// URL that could hold a login) shows at once, and a source no longer
    /// set up goes from the page and the file with no provider asked. Then,
    /// when any source's lineup is older than `page` allows, every source
    /// is asked, in parallel, and each that answered replaces its channels;
    /// one that failed keeps the channels it had, so one failing provider
    /// never empties another's list. Of the check, only an answer changes
    /// the page or the file: a failure never makes old games look current.
    /// A guide that's due (or `force`) is rebuilt from the sources that
    /// answered, so one provider that keeps failing never stops the guide
    /// for the others; the one that failed has no programmes until a
    /// rebuild it answers in.
    private func runLiveUpdate(for page: String?, force: Bool) async {
        let iptv = sources.iptv
        guard !iptv.isEmpty else {
            categories = []
            allChannels = []
            channelsByCategory = [:]
            localCache = nil
            liveChecks = [:]
            return
        }
        liveChecks = liveChecks.filter { id, _ in iptv.contains { $0.id == id } }
        providers = providers.filter { id, _ in iptv.contains { $0.id == id } }
        // A source removed before it ever answered leaves no rows to drop,
        // only its id in the file.
        var listed = iptv.map(\.id)
        if !restoredLineup {
            restoredLineup = true
            if !Self.freshLineup, let saved = await Self.savedLineup(), Set(iptv.map(\.id)).isSubset(of: saved.sources) {
                listed = saved.sources
                await applyLineup(categories: saved.categories, channels: saved.channels)
                // Playlists' stream addresses can hold a login, so they're
                // saved blank and only the provider's current lineup can play
                // them: never answered, as far as the file goes.
                let blank = Set(saved.channels.filter { channel in
                    if case let .url(url, _, _) = channel.stream { return url.scheme == "about" }
                    return false
                }.map(\.sourceId))
                liveChecks = Dictionary(uniqueKeysWithValues: iptv.map { source in
                    (source.id, LineupCheck(answeredAt: blank.contains(source.id) ? nil : saved.answered?[source.id]))
                })
            }
        }
        let keptCategories = categories.filter { category in iptv.contains { $0.id == category.sourceId } }
        let keptChannels = allChannels.filter { channel in iptv.contains { $0.id == channel.sourceId } }
        let dropped = keptCategories.count < categories.count || keptChannels.count < allChannels.count
        if dropped { await applyLineup(categories: keptCategories, channels: keptChannels) }
        if dropped || listed != iptv.map(\.id), !Task.isCancelled {
            await Self.saveLineup(sources: iptv.map(\.id), categories: keptCategories, channels: keptChannels,
                                  answered: liveChecks.compactMapValues(\.answeredAt))
        }
        // The page's limit read now: an event list's needs the saved lineup in.
        let maxAge = liveMaxAge(page), now = Date()
        guard force || iptv.contains(where: { liveChecks[$0.id, default: LineupCheck()].nextAsk(maxAge: maxAge) <= now }) else { return }
        liveLoading = true
        defer { liveLoading = false }
        let made = Dictionary(uniqueKeysWithValues: iptv.map { ($0.id, Providers.make($0)) })
        var results: [UUID: Result<LiveLineup, SourceError>] = [:]
        await withTaskGroup(of: (UUID, Result<LiveLineup, SourceError>).self) { group in
            for (id, provider) in made {
                group.addTask {
                    do { return (id, .success(try await provider.load())) } catch { return (id, .failure(SourceError.wrap(error))) }
                }
            }
            for await (id, result) in group { results[id] = result }
        }
        // Stopped out of background time (updateLive): no check at all, so
        // nothing is recorded or changed, and the sources are due as before.
        guard !Task.isCancelled else { return }
        let previousCategories = categories, previousChannels = allChannels
        for case let (id, .success(lineup)) in results {
            // Nothing from a source that had it: a failed check, which keeps
            // what the source had.
            if lineup.channels.isEmpty, previousChannels.contains(where: { $0.sourceId == id }) {
                results[id] = .failure(.unexpected("The provider sent no channels."))
            } else if lineup.categories.isEmpty, previousCategories.contains(where: { $0.sourceId == id }) {
                results[id] = .failure(.unexpected("The provider sent no categories."))
            }
        }
        let answered = Date()
        for (id, result) in results {
            liveChecks[id, default: LineupCheck()].record(result.map { _ in () }, at: answered)
            // A provider that loaded stays until another does: it knows the
            // account's stream format and holds a portal's session.
            let keepsProvider = (try? result.get()) == nil && providers[id]?.source == made[id]?.source
            if !keepsProvider { providers[id] = made[id] }
        }

        let multiple = iptv.count > 1
        var cats: [LiveCategory] = []
        var channels: [LiveChannel] = []
        var guides: [URLRequest] = []
        for source in iptv {
            if case let .success(lineup)? = results[source.id] {
                let (ownCategories, ownChannels) = LiveOrganizer.withoutLogin(categories: lineup.categories, channels: lineup.channels)
                cats += ownCategories.map {
                    LiveCategory(id: $0.id, name: multiple ? "\(source.name) · \($0.name)" : $0.name, channels: $0.channels)
                }
                channels += ownChannels
                guides += lineup.guides
            } else {
                cats += previousCategories.filter { $0.sourceId == source.id }
                channels += previousChannels.filter { $0.sourceId == source.id }
            }
        }
        guard results.values.contains(where: { (try? $0.get()) != nil }) else { return }
        await applyLineup(categories: cats, channels: channels)
        guard !Task.isCancelled else { return }
        await Self.saveLineup(sources: iptv.map(\.id), categories: cats, channels: channels, answered: liveChecks.compactMapValues(\.answeredAt))

        let keep = Set(channels.compactMap(\.epgId))
        let stale = await guide.isStale()
        if !guides.isEmpty, force || stale || Self.freshGuide, !Task.isCancelled {
            guideState = .loading
            let guide = guide
            Task.detached {
                await guide.refresh(from: guides, keep: keep)
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

    private struct SavedLineup: Codable {
        let sources: [UUID]
        let categories: [LiveCategory]
        let channels: [LiveChannel]
        /// When each source last returned its lineup; a source that failed
        /// keeps its earlier time. Missing in files from before it was
        /// kept: every source is asked again once.
        var answered: [UUID: Date]?
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
        let prefixes = Dictionary(sources.iptv.map { ($0.id, $0.name + " · ") }, uniquingKeysWith: { a, _ in a })
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
        let favourites = account.favouriteChannels().compactMap { built.byId[$0]?.logo }
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
                         prefixes: [UUID: String], home: String) {
            let (cats, channels) = LiveOrganizer.withoutLogin(categories: allCategories, channels: allListed)
            let own = cats.map { category -> LiveCategory in
                guard let source = category.sourceId, let prefix = prefixes[source],
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
                names[epg] = SharedGuideRule.fold(library.titles[best.id] ?? LiveOrganizer.Name(best.name).display)
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
        func foundAgain(by words: [String], at now: Int64) -> Bool {
            if let league {
                return SharedGuideRule.findsGame(words, text: SharedGuideRule.fold(title + " " + league), start: start, now: now)
            }
            return SharedGuideRule.findsProgramme(words, title: SharedGuideRule.fold(title), channel: SharedGuideRule.fold(channelTitle),
                                                   stop: stop ?? .max, now: now)
        }
    }

    /// What's on now or later that matches the query: programmes from the
    /// guide (each word in the title or the channel's name) and games from
    /// Sports. On now first, then by start; channels from abroad after
    /// local ones; local stations only for your area.
    func searchGuide(_ query: String, area: LocalArea?, limit: Int = 40) async -> [GuideHit] {
        let words = SharedGuideRule.words(in: query)
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
            let text = SharedGuideRule.fold(entry.title + " " + (entry.event?.league ?? ""))
            guard SharedGuideRule.findsGame(words, text: text, start: start, now: now) else { continue }
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

    func liveOrder(of channel: LiveChannel) -> [LiveChannel] {
        liveFailures.failedLast(copies(of: channel))
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
        /// The same feed on other channels (a provider lists one feed in two
        /// slots): not listed, tried after this one if it doesn't play.
        var others: [LiveChannel] = []
        var id: String { channel.id }
        /// Its name in the list and the line under it (see WatchOn.label).
        var label: (title: String, line: String) { WatchOn.label(feed, quality: quality) }
        var channels: [LiveChannel] { [channel] + others }

        func shows(_ id: String?) -> Bool {
            channels.contains { $0.id == id }
        }
    }

    /// Every channel showing this game, the one to play first at the top
    /// (see WatchOn.ranked); empty unless it's a game on more than one.
    func watchChoices(for channel: LiveChannel) -> [WatchChoice] {
        guard let event = event(of: channel) else { return [] }
        // Each channel once (a provider can list one in two categories).
        var seen = Set<String>()
        let copies = copies(of: channel).filter { seen.insert($0.id).inserted }
        guard copies.count > 1 else { return [] }
        let choices = copies.map { copy in
            WatchChoice(channel: current(copy), feed: feed(of: copy), quality: WatchOn.quality(of: copy.name).label)
        }
        let byId = Dictionary(choices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let options = choices.map { choice in
            WatchOn.Option(id: choice.id, feed: choice.feed, quality: WatchOn.quality(of: choice.channel.name).score)
        }
        let ranked = WatchOn.ranked(options, pick: watchPicks[event.league],
                                    preferred: WatchOn.preferredLanguage(league: event.league, title: title(of: channel)),
                                    failed: liveFailures.ids())
        // The same feed on several channels: one entry (the user saw
        // "Football · Soccer, OneSoccer Feed" twice).
        let grouped: [WatchChoice] = WatchOn.grouped(ranked).compactMap { group in
            guard var choice = byId[group.option.id] else { return nil }
            choice.others = group.others.compactMap { byId[$0.id]?.channel }
            return choice
        }
        return grouped.count > 1 ? grouped : []
    }

    func gameState(_ entry: LiveOrganizer.Entry) -> LiveFailures.GameState {
        liveFailures.gameState(feeds: groups(of: entry.channels).map { ([$0.option] + $0.others).map(\.id) })
    }

    private static let unnamedFeed = WatchOn.Feed(service: LiveOrganizer.serviceName(""))

    private func feed(of copy: LiveChannel) -> WatchOn.Feed {
        liveLibrary.feeds[copy.id] ?? Self.unnamedFeed
    }

    private func groups(of channels: [LiveChannel]) -> [(option: WatchOn.Option, others: [WatchOn.Option])] {
        var seen = Set<String>()
        return WatchOn.grouped(channels.filter { seen.insert($0.id).inserted }.map(watchOption))
    }

    private func watchOption(_ copy: LiveChannel) -> WatchOn.Option {
        WatchOn.Option(id: copy.id, feed: feed(of: copy), quality: WatchOn.quality(of: copy.name).score)
    }

    /// Every channel showing this game, the one to play first at the top,
    /// one too (its long-press menu); empty for anything but a game.
    func gameChannels(for channel: LiveChannel) -> [WatchChoice] {
        guard event(of: channel) != nil else { return [] }
        let choices = watchChoices(for: channel)
        guard choices.isEmpty else { return choices }
        let others = copies(of: channel).filter { $0.id != channel.id }
        return [WatchChoice(channel: current(channel), feed: feed(of: channel), quality: WatchOn.quality(of: channel.name).label, others: others)]
    }

    /// A channel picked in Watch On: first for this league's games from
    /// now on.
    func pickWatchChoice(_ choice: WatchChoice, league: String) {
        var picks = watchPicks
        picks[league] = WatchOn.Pick(service: choice.feed.service, language: choice.feed.language)
        UserDefaults.standard.set(try? JSONEncoder().encode(picks), forKey: "watchOnPicks")
    }

    func noteLiveFailure(_ channel: LiveChannel) {
        liveFailures.note(channel.id, kickoff: event(of: channel)?.start)
        dropMarksAsTheyEnd()
    }

    private func dropMarksAsTheyEnd() {
        nextMarkEnd?.cancel()
        guard let end = liveFailures.nextEnd else { return }
        nextMarkEnd = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self else { return }
            liveFailures.dropEnded()
            dropMarksAsTheyEnd()
        }
    }

    func didNotPlay(_ channel: LiveChannel) -> Bool {
        guard liveFailures.contains(channel.id) else { return false }
        return liveFailures.failed(feedSlots(of: channel))
    }

    private func feedSlots(of channel: LiveChannel) -> [String] {
        let copies = copies(of: channel)
        guard event(of: channel) != nil else { return copies.map(\.id) }
        let feeds = groups(of: copies).map { [$0.option] + $0.others }
        return feeds.first { $0.contains { $0.id == channel.id } }?.map(\.id) ?? [channel.id]
    }

    func watchOnShown(_ choice: WatchChoice, playingCopy: String?) -> (line: String, didNotPlay: Bool) {
        let failed = liveFailures.failed(choice.channels.map(\.id), playingCopy: playingCopy)
        let state = choice.shows(playingCopy) ? "Playing" : failed ? LiveFailures.didNotPlay : nil
        let line = choice.label.line
        return ([state, line.isEmpty ? nil : line].compactMap(\.self).joined(separator: " · "), failed)
    }

    func name(of copy: LiveChannel) -> String {
        if let feed = liveLibrary.feeds[copy.id] { return WatchOn.name(feed) }
        return [title(of: copy), WatchOn.quality(of: copy.name).label].compactMap(\.self).joined(separator: " ")
    }

    func shareGameNotPlaying(_ channel: LiveChannel) {
        let all = copies(of: channel)
        liveFailures.noteSharedGame(all.map(\.id), kickoff: event(of: channel)?.start)
        dropMarksAsTheyEnd()
        let keys = all.compactMap(sharedKey)
        guard let emby = account.emby, !keys.isEmpty else { return }
        let life = liveFailures.sharedGameLife
        account.run(priority: .utility) {
            let now = Date().timeIntervalSince1970
            var record = (await emby.notPlayingRecord() ?? [:]).filter { now - $0.value < life }
            for key in keys { record[key] = now }
            await emby.saveNotPlaying(record)
        }
    }

    private func readGamesOtherDevicesFoundNotPlaying() async {
        guard let emby = account.emby, let record = await emby.notPlayingRecord(), !record.isEmpty else { return }
        let found = liveLibrary.feeds.keys.compactMap { id -> (channel: LiveChannel, at: Double)? in
            guard let channel = channelById[id], let key = sharedKey(channel), let at = record[key] else { return nil }
            return (channel, at)
        }
        var failures = liveFailures
        for (channel, at) in found {
            failures.noteSharedGame([channel.id], at: Date(timeIntervalSince1970: at), kickoff: event(of: channel)?.start)
        }
        guard failures != liveFailures else { return }
        liveFailures = failures
        dropMarksAsTheyEnd()
    }

    private func sayCleared(_ mark: LiveFailures.Mark?, game: Bool) {
        #if DEBUG
        if let mark { LivePerf.sayMarkCleared(game ? .game : .channel, mark) }
        #endif
    }

    /// A channel's name the same on every device (each names its own
    /// subscription differently): its provider's address and its number
    /// there, hashed, so the Emby server's owner reads nothing of it.
    private func sharedKey(_ channel: LiveChannel) -> String? {
        guard let source = sources.iptv.first(where: { $0.id == channel.sourceId }) else { return nil }
        let place: String = switch source.kind {
        case let .xtream(server, _, _): server.host() ?? server.absoluteString
        case let .m3u(playlist, _): playlist.host() ?? playlist.absoluteString
        case let .stalker(portal, _): portal.host() ?? portal.absoluteString
        }
        let digest = SHA256.hash(data: Data("\(place)|\(channel.nativeId)".utf8))
        return digest.prefix(10).map { String(format: "%02x", $0) }.joined()
    }

    func notePlaying(_ copy: LiveChannel) {
        if liveFailures.contains(copy.id) { sayCleared(liveFailures.played(copy.id), game: false) }
        let all = copies(of: copy)
        let ids = all.map(\.id)
        guard liveFailures.gameNotPlaying(ids) else { return }
        let cleared = liveFailures.gamePlayed(ids)
        sayCleared(cleared.values.min { $0.noted < $1.noted }, game: true)
        let keys = all.filter { cleared[$0.id] != nil }.compactMap(sharedKey)
        guard let emby = account.emby, !keys.isEmpty else { return }
        account.run(priority: .utility) {
            guard var record = await emby.notPlayingRecord(), keys.contains(where: { record[$0] != nil }) else { return }
            for key in keys { record[key] = nil }
            await emby.saveNotPlaying(record)
        }
    }

    private var watchPicks: [String: WatchOn.Pick] {
        UserDefaults.standard.data(forKey: "watchOnPicks").flatMap { try? JSONDecoder().decode([String: WatchOn.Pick].self, from: $0) } ?? [:]
    }

    private nonisolated static func savedLineup() async -> SavedLineup? {
        await Task.detached(priority: .userInitiated) { AppCache.read(lineupFile) as SavedLineup? }.value
    }

    /// Playlist stream URLs can hold a login, so they're saved blank and
    /// the providers' current lineup supplies them. Awaited: two saves
    /// land in the order asked.
    private nonisolated static func saveLineup(sources: [UUID], categories: [LiveCategory], channels: [LiveChannel],
                                               answered: [UUID: Date]) async {
        guard !freshLineup else { return }
        await Task.detached(priority: .utility) {
            AppCache.write(lineupFile, SavedLineup(sources: sources, categories: categories,
                                                   channels: channels.map(\.withoutSecrets), answered: answered))
        }.value
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
        let scope = account
        guard key.count >= 2, let emby = scope.emby else { return [] }
        if let cached = scope.serverSearchCache[key] { return cached }
        guard let cards = try? await emby.search(key, cardWidth: cardWidth) else { return [] }
        scope.serverSearchCache[key] = cards
        return cards
    }

    func card(for entry: LibraryEntry, width: Int, with person: String? = nil) -> Card? {
        guard let card = account.emby?.card(for: entry, width: width, rating: library.rating(entry)) else { return nil }
        return person.map { card.adding("with " + $0) } ?? card
    }

    /// A search card for a title found through someone in it.
    func card(for item: EmbyItem, width: Int, with person: String) -> Card? {
        guard let emby = account.emby else { return nil }
        let base = emby.card(item, context: .poster, shape: .portrait, width: width)
        let details = [item.kind == "Series" ? "Show" : "Movie", item.productionYear.map(String.init),
                       library.ratings?.rating(item.imdb).map(IMDbRatings.label), "with " + person]
        return Card(id: base.id, kind: base.kind, title: base.title, subtitle: details.compactMap(\.self).joined(separator: " · "),
                    images: base.images, progress: nil, playable: base.playable)
    }

    // MARK: Search across cast

    /// The server part of a search. Titles waiting for a cast check keep
    /// only if each leftover word is in an actor's or director's name
    /// (noting whom), and people named by the query bring their titles
    /// ("antonio banderas"), the asked year's and the most popular first.
    func refine(_ query: SearchQuery, hits: [SearchHit]) async -> (hits: [SearchHit], people: [(item: EmbyItem, person: String)]) {
        let scope = account
        guard let emby = scope.emby else { return (hits.filter { $0.pending.isEmpty }, []) }
        let unknown = hits.filter { !$0.pending.isEmpty && scope.castCache[$0.entry.id] == nil }.map(\.entry.id)
        async let castLists = emby.people(of: Array(unknown.prefix(40)))
        async let persons = query.words.isEmpty ? [] : emby.persons(matching: query.title)
        for (id, people) in await castLists {
            scope.castCache[id] = people.filter { [nil, "Actor", "Director", "GuestStar"].contains($0.type) }.prefix(25).map(\.name)
        }
        var refined: [SearchHit] = []
        for var hit in hits {
            guard !hit.pending.isEmpty else { refined.append(hit); continue }
            guard let cast = scope.castCache[hit.entry.id] else { continue }
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

#if canImport(UIKit)
/// Time to finish a piece of work once the app leaves the front, given
/// back once: when the work ends, or when iOS runs out of it, after
/// `expired`. Given back late, iOS ends the app.
@MainActor
private final class BackgroundTime {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(_ name: String, expired: @escaping @MainActor @Sendable () -> Void) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [self] in
            expired()
            end()
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
#endif

// MARK: - My List

extension AppModel {
    fileprivate static let myListOrderKey = "myListAdded"

    /// When each title was put on My List here (newest first on the row).
    private var myListAdded: [String: Double] {
        get { (UserDefaults.standard.dictionary(forKey: Self.myListOrderKey) as? [String: Double]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.myListOrderKey) }
    }

    /// Every copy on My List the last time this device read it, for this
    /// server and viewer: what another account's list held says nothing of
    /// this one. Regression: a device that had only seen the test server's
    /// list took all 46 titles of the real one as just put on it.
    private static let myListSeenKey = "myListSeen"
    private var myListSeenKey: String {
        Self.myListSeenKey + (sources.emby.map { ".\($0.serverURL.host() ?? "")|\($0.userId)" } ?? "")
    }

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
    private nonisolated static var freshGuide: Bool { UserDefaults.standard.bool(forKey: "freshGuide") }
    #else
    private nonisolated static let freshLineup = false
    private nonisolated static let freshGuide = false
    #endif

    #if DEBUG
    nonisolated static var noPrepareAhead: Bool { UserDefaults.standard.bool(forKey: "noPrepareAhead") }
    #else
    nonisolated static let noPrepareAhead = false
    #endif

    #if DEBUG
    /// UI tests: `-noStreamAhead YES` opens no film before a tap, neither a
    /// player warmed up nor a file's start fetched (a run on the real feeds
    /// that must play nothing).
    private nonisolated static var noStreamAhead: Bool { UserDefaults.standard.bool(forKey: "noStreamAhead") }
    #else
    private nonisolated static let noStreamAhead = false
    #endif

    #if DEBUG
    /// UI tests: `-noPlanForecast YES` asks a Continue Watching card's plan
    /// only when it stays on screen (the start before).
    private nonisolated static var noPlanForecast: Bool { UserDefaults.standard.bool(forKey: "noPlanForecast") }
    #else
    private nonisolated static let noPlanForecast = false
    #endif

    #if DEBUG
    /// UI tests: `-noPreconnect YES` keeps no connection open for a likely
    /// card (the start before it did).
    private nonisolated static var noPreconnect: Bool { UserDefaults.standard.bool(forKey: "noPreconnect") }
    #else
    private nonisolated static let noPreconnect = false
    #endif

    /// When each title was put on My List here, and the titles seen: an
    /// account's own, gone with it (its record on the server keeps them).
    fileprivate static func forgetMyListOrder() {
        UserDefaults.standard.removeObject(forKey: myListOrderKey)
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix(myListSeenKey) {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    #if DEBUG
    /// UI tests: `-forgetMyListOrder YES` at launch starts with no order
    /// kept (when each title was added, the titles seen).
    static func forgetMyListOrderForTesting() {
        guard UserDefaults.standard.bool(forKey: "forgetMyListOrder") else { return }
        forgetMyListOrder()
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
        let scope = account
        myListWidth = cardWidth
        guard let emby = scope.emby else { return }
        let seenKey = myListSeenKey
        async let shared = emby.myListDates()
        guard let found = try? await emby.favorites() else { return }
        let record = await shared
        guard scope.isOpen else { return }
        var added = myListAdded
        for (id, date) in record ?? [:] where (added[id] ?? 0) < date { added[id] = date }
        // A second shared by several titles is nobody's pick: a device
        // stamped them all at once. Undated (the server's order), here and,
        // once written back, in the record. Regression: 46 of the user's 52
        // titles stamped at once came first, by name, before what they had
        // just put on it.
        let stamps = Dictionary(grouping: added.values, by: { $0.rounded(.down) })
        added = added.filter { (stamps[$0.value.rounded(.down)]?.count ?? 0) < Self.massStamp }
        let defaults = UserDefaults.standard
        if let seen = defaults.stringArray(forKey: seenKey).map(Set.init) {
            let now = Date().timeIntervalSince1970
            for item in found where !seen.contains(item.id) && added[item.id] == nil { added[item.id] = now }
        }
        if added != myListAdded { myListAdded = added }
        defaults.set(found.map(\.id), forKey: seenKey)
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
        scope.myListCopies = Dictionary(groups.flatMap { group in group.keys.map { ($0, group.ids) } }, uniquingKeysWith: { $0.union($1) })
        let cards = groups.map { emby.card($0.first, context: .poster, shape: .portrait, width: cardWidth) }
        if cards != scope.myList { scope.myList = cards }
        let ids = Set(found.map(\.id))
        if ids != scope.myListIDs { scope.myListIDs = ids }
    }

    /// The titles that can share one second of being put on My List, at
    /// most, before it's taken for a device's mass stamp.
    private static let massStamp = 3

    /// My List read again (back in the app: something may have been put on
    /// it on another device meanwhile).
    func refreshMyList() async {
        guard let myListWidth else { return }
        await loadMyList(cardWidth: myListWidth)
    }

    /// Whether a title is on My List, in any copy (what the server said of
    /// the title itself until the list is loaded).
    func isOnMyList(_ id: String, item: EmbyItem?) -> Bool {
        guard let myListIDs = account.myListIDs else { return item?.userData?.isFavorite == true }
        if myListIDs.contains(id) { return true }
        return !copiesOnMyList(item).isEmpty
    }

    /// The ids of this title's copies on My List.
    private func copiesOnMyList(_ item: EmbyItem?) -> Set<String> {
        guard let item else { return [] }
        return item.titleKeys.compactMap { account.myListCopies[$0] }.reduce(into: Set<String>()) { $0.formUnion($1) }
            .union((account.myListIDs ?? []).contains(item.id) ? [item.id] : [])
    }

    /// Puts a title on My List or takes it off: on screen at once (the row
    /// on Home too), then on the server; back as it was if that fails.
    func toggleMyList(_ item: EmbyItem, cardWidth: Int = 360) {
        let scope = account
        guard let emby = scope.emby else { return }
        let on = !isOnMyList(item.id, item: item)
        let before = (scope.myList, scope.myListIDs, scope.myListCopies)
        var ids = scope.myListIDs ?? []
        // Off: every copy of the title comes off (the other one would
        // bring it back).
        let copies = on ? [item.id] : copiesOnMyList(item).union([item.id])
        if on {
            ids.insert(item.id)
            scope.myList.removeAll { $0.id == item.id }
            scope.myList.insert(emby.card(item, context: .poster, shape: .portrait, width: cardWidth), at: 0)
            myListAdded[item.id] = Date().timeIntervalSince1970
            for key in item.titleKeys { scope.myListCopies[key, default: []].insert(item.id) }
        } else {
            ids.subtract(copies)
            scope.myList.removeAll { copies.contains($0.id) }
            for id in copies { myListAdded[id] = nil }
            for key in item.titleKeys { scope.myListCopies[key] = nil }
            scope.myListCopies = scope.myListCopies.filter { $0.value.isDisjoint(with: copies) }
        }
        scope.myListIDs = ids
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
                scope.myList = before.0
                scope.myListIDs = before.1
                scope.myListCopies = before.2
            }
        }
    }
}


import Foundation
import Observation

/// A player kept open for the account: a title just closed, or the next
/// one opened out of sight.
protocol KeptPlayer: AnyObject {
    var hasStarted: Bool { get }
    var hasFailed: Bool { get }
    func shutdown()
}

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

/// A film's page: its details and the titles like it.
struct MovieData: Codable, Sendable, Equatable {
    let item: EmbyItem
    let similar: [EmbyItem]
    let loadedAt: Date
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

/// One signed-in Emby account's data on this device, and the work running
/// for it. A new account gets a new scope; signing out or forgetting
/// everything closes this one whole: its work stops, its warm player and
/// plans go, and its server is asked nothing more.
@Observable
@MainActor
final class AccountScope {
    @ObservationIgnored private let client: EmbyClient?
    @ObservationIgnored private(set) var isOpen = true
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let lane: Lane?
    @ObservationIgnored private let askPlan: @Sendable (EmbyClient, PlanKey) async throws -> EmbyPlayback
    @ObservationIgnored private let rowsChanged: @MainActor () -> Void
    @ObservationIgnored private let readsSaved: Bool
    @ObservationIgnored private var work: [UUID: () -> Void] = [:]

    /// `readsSaved`: false for the scope that follows a wipe, whose removal
    /// of the saved habits and title pages may not have run yet.
    init(client: EmbyClient?, readsSaved: Bool = true, lane: Lane? = nil,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         askPlan: @escaping @Sendable (EmbyClient, PlanKey) async throws -> EmbyPlayback = { _, _ in throw CancellationError() },
         retryHome: @escaping @MainActor () async -> Void = {},
         rowsChanged: @escaping @MainActor () -> Void = {}) {
        self.client = client
        self.readsSaved = readsSaved
        self.lane = lane
        self.sleep = sleep
        self.askPlan = askPlan
        self.rowsChanged = rowsChanged
        homeRetry = HomeRetry(sleep: sleep, attempt: retryHome)
    }

    var emby: EmbyClient? { isOpen ? client : nil }

    /// Work for this account: stopped when it closes, at once if it has.
    @discardableResult
    func run<T: Sendable>(priority: TaskPriority? = nil, _ job: @escaping @MainActor () async -> T) -> Task<T, Never> {
        let id = UUID()
        let task = Task(priority: priority) { @MainActor in
            defer { self.work[id] = nil }
            return await job()
        }
        guard isOpen else {
            task.cancel()
            return task
        }
        work[id] = task.cancel
        return task
    }

    /// `job` for this account on a caller's behalf: it stops when the
    /// caller does or when the account closes, whichever comes first.
    func attach<T: Sendable>(_ job: @escaping @MainActor () async -> T) async -> T {
        let task = run(job)
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        let stopping = work.values
        work = [:]
        stopping.forEach { $0() }
        homeRetry.stop()
        coolDown()
        plans.forgetAll()
        for state in showStates.values { state.value = nil }
        for state in movieStates.values { state.value = nil }
    }

    // MARK: Saved on the device

    static let homeFile = "home.v4.json"
    private static let habitsFile = "habits.json"
    private static let pagePrefixes = ["show-", "movie-"]

    /// Written in the background, and only while the scope is open: a load
    /// that ends after sign-out never saves the old account's data again.
    func save<T: Encodable & Sendable>(_ name: String, _ value: T) {
        guard isOpen else { return }
        AppCache.save(name, value)
    }

    /// Every file an account saves, in order with the background writes.
    static func removeSaved() {
        AppCache.remove(homeFile)
        AppCache.remove(habitsFile)
        AppCache.removeAll(startingWith: pagePrefixes)
    }

    /// Title pages not visited in a month.
    static func pruneSaved() {
        AppCache.prune(startingWith: pagePrefixes, olderThan: 30)
    }

    // MARK: Home

    var rows: [HomeRow] = [] {
        didSet { rowsChanged() }
    }
    var featured: Featured?
    /// Apple TV's hero titles (see HomeContent.spotlight).
    var spotlight: [Featured] = []
    var homeError: String?
    /// The Home build in progress. Leaving Home cancels the page's task but
    /// not this, so a build cut off halfway (its rows fetched as empty)
    /// never replaces the page.
    @ObservationIgnored var homeLoad: Task<Void, Never>?
    @ObservationIgnored var homeLoadID = UUID()
    @ObservationIgnored let homeRetry: HomeRetry
    /// Home doesn't change while you look at it, like Netflix's: a Home
    /// built in the background (new titles, the charts, IMDb's catalog, a
    /// server's change) waits here for a moment the page may change. The
    /// moments: a launch or coming back after a long time away (a build
    /// ready in the first seconds), a pull to refresh, and Home chosen from
    /// another tab. Its Continue Watching is the newest the server gave.
    @ObservationIgnored var stagedHome: HomeContent?
    /// After a launch or a long time away, the first Home built goes
    /// straight on the page, however long the server takes, unless the
    /// viewer has started browsing it meanwhile (then it waits for the next
    /// moment). One per launch: later builds wait. (A five-second window
    /// left a slow server's first build hidden until another tab.)
    @ObservationIgnored var homeAwaitsFirstBuild = false
    /// Until when Continue Watching's cards may move, appear or go: just
    /// after the player closed, until the server's answer for that stop.
    @ObservationIgnored var continueMovesUntil: Date?
    /// When the page on screen was built, and the recent watches its Top
    /// picks came from (what's saved; `homeBuiltAt` is the newest build,
    /// waiting or shown). Watched: see `homePending`.
    var shownBuiltAt: Date?
    @ObservationIgnored var shownHistory: [String] = []
    /// The newest Home built (waiting or shown): when, and the recent
    /// watches its Top picks came from.
    var homeBuiltAt: Date?
    var homeHistory: [String] = []
    /// What was stopped on this device in the last two minutes: a server
    /// answer that hasn't caught up yet doesn't undo it.
    @ObservationIgnored var recentStops: [String: ContinueStop] = [:]
    /// The plan each held Continue Watching card was asked for.
    @ObservationIgnored var heldPlans: [Target: PlanKey] = [:]

    /// Whether a build may go straight on the page: Home is still opening,
    /// or has nothing built on it yet (only Continue Watching, or nothing).
    var homeOpening: Bool {
        homeAwaitsFirstBuild || nothingBuiltShown
    }

    var nothingBuiltShown: Bool {
        shownBuiltAt == nil || rows.isEmpty
    }

    /// The Home saved on the device, as the page opens with at a launch.
    func restore(_ home: HomeContent?) {
        rows = home?.rows ?? []
        featured = home?.featured
        spotlight = home?.spotlight ?? []
        homeBuiltAt = home?.builtAt
        homeHistory = home?.history ?? []
        shownBuiltAt = home?.builtAt
        shownHistory = home?.history ?? []
    }

    // MARK: My List

    /// The viewer's My List (Emby's favorites), newest first, and which
    /// titles are on it (nil: not loaded yet).
    var myList: [Card] = []
    var myListIDs: Set<String>?
    /// My List's copies of each title (an HD and a 4K film are one title,
    /// one card): the ids on the server's list, by each key the title is
    /// known by.
    @ObservationIgnored var myListCopies: [String: Set<String>] = [:]

    // MARK: Title pages

    /// Not observed as a whole: a page watches its own title's state (see
    /// `showState`), so fetching other shows ahead doesn't redraw it.
    @ObservationIgnored var shows: [String: ShowData] = [:] {
        didSet { for (id, state) in showStates where state.value != shows[id] { state.value = shows[id] } }
    }
    @ObservationIgnored private var showStates: [String: TitleState<ShowData>] = [:]
    @ObservationIgnored var showLoads: [String: Task<ShowData?, Never>] = [:]

    /// Not observed as a whole (see `shows`).
    @ObservationIgnored var movies: [String: MovieData] = [:] {
        didSet { for (id, state) in movieStates where state.value != movies[id] { state.value = movies[id] } }
    }
    @ObservationIgnored private var movieStates: [String: TitleState<MovieData>] = [:]
    @ObservationIgnored var movieLoads: [String: Task<MovieData?, Never>] = [:]

    /// Title pages that exist (on screen or under another page), whose data
    /// is never evicted.
    @ObservationIgnored private(set) var pinned: [String: Int] = [:]

    /// One show's page data, to watch: it changes only when this show does.
    func showState(_ id: String) -> TitleState<ShowData> {
        if let state = showStates[id] { return state }
        let state = TitleState(shows[id])
        showStates[id] = state
        return state
    }

    /// One film's page data, to watch: it changes only when this film does.
    func movieState(_ id: String) -> TitleState<MovieData> {
        if let state = movieStates[id] { return state }
        let state = TitleState(movies[id])
        movieStates[id] = state
        return state
    }

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

    static func showFile(_ id: String) -> String { "show-\(id).json" }
    static func movieFile(_ id: String) -> String { "movie-\(id).json" }

    /// A show's page as last seen: in memory, else saved on the device, so
    /// it opens at once (even after a relaunch) while it's brought up to date.
    func cachedShow(_ id: String) -> ShowData? {
        if let data = shows[id] { return data }
        guard readsSaved, let saved: ShowData = AppCache.read(Self.showFile(id)) else { return nil }
        shows[id] = saved
        return saved
    }

    /// A film's page as last seen: in memory, else saved on the device, so
    /// it opens complete at once while it's brought up to date.
    func cachedMovie(_ id: String) -> MovieData? {
        if let data = movies[id] { return data }
        guard readsSaved, let saved: MovieData = AppCache.read(Self.movieFile(id)) else { return nil }
        movies[id] = saved
        return saved
    }

    // MARK: Playing

    /// Where this device last stopped a title (0: finished), for half an
    /// hour: it wins over the server's resume point, which may not have
    /// heard yet.
    @ObservationIgnored var stops: [String: (seconds: Double, at: Date)] = [:]
    /// The preview stills (BIF) of the last two titles got ready ahead of a
    /// tap, and fetches under way.
    @ObservationIgnored var previews: [(id: String, data: Data)] = []
    @ObservationIgnored var previewLoads: [String: Task<Data?, Never>] = [:]
    @ObservationIgnored var reportChain: Task<Void, Never>?
    /// The newest position not yet sent: while one progress report waits
    /// its turn, newer ones replace it rather than queueing behind it.
    @ObservationIgnored var queuedProgress: (playback: EmbyPlayback, seconds: Double)?
    /// IMDb's catalog, fetched a while after the library syncs.
    @ObservationIgnored var catalogJob: Task<Void, Never>?

    /// How to play each title, asked of this account's server only.
    @ObservationIgnored private(set) lazy var plans = Plans.shelf(lane: lane) { [weak self, askPlan] key in
        guard let emby = await self?.emby else { throw SourceError.unexpected("Add your Emby server in Settings.") }
        return try await askPlan(emby, key)
    }

    // MARK: Warm start

    struct Warm {
        let player: any KeptPlayer
        let playback: EmbyPlayback
        /// Just closed here, paused where it stopped.
        let parked: Bool
        var key: String { playback.itemId }
    }

    @ObservationIgnored private(set) var warm: Warm?
    @ObservationIgnored private var warmExpiry: Task<Void, Never>?

    /// Keeps `player` open at `playback` for `wait`. A scope with no server
    /// (closed, or none signed in) stops it at once.
    func keepWarm(_ player: any KeptPlayer, _ playback: EmbyPlayback, parked: Bool, for wait: Duration) {
        coolDown()
        guard emby != nil else { return player.shutdown() }
        warm = Warm(player: player, playback: playback, parked: parked)
        warmExpiry = Task { [weak self, sleep] in
            try? await sleep(wait)
            guard !Task.isCancelled else { return }
            self?.coolDown()
        }
    }

    /// Hands over the warmed-up player for this episode or movie, if it's
    /// open at `start` (one opened at another second, say before the last
    /// stop reached the server, would play from there: "the same frame
    /// again"). Failed meanwhile (the connection lost, the app away), the
    /// title opens afresh: handed over, it waited for a start that never came.
    func takeWarm(_ itemId: String, at start: Double?) -> (any KeptPlayer)? {
        guard let warm, warm.playback.itemId == itemId else { return nil }
        guard !warm.player.hasFailed, abs((warm.playback.startSeconds ?? 0) - (start ?? 0)) < 2 else {
            coolDown()
            return nil
        }
        self.warm = nil
        warmExpiry?.cancel()
        return warm.player
    }

    func coolDown() {
        warmExpiry?.cancel()
        warm?.player.shutdown()
        warm = nil
    }

    // MARK: Search

    /// Server search results by query, for episodes the index doesn't hold.
    @ObservationIgnored var serverSearchCache: [String: [Card]] = [:]
    /// Actors and directors of titles checked so far.
    @ObservationIgnored var castCache: [String: [String]] = [:]

    // MARK: Habits

    /// What this device plays, and when (the last 20 times each): the titles
    /// in rotation, and the channels watched most, are kept ready so they
    /// open and start at once.
    private struct Habits: Codable {
        var titles: [String: Played] = [:]
        var channels: [String: [Date]] = [:]
        struct Played: Codable { var kind: String; var at: [Date] }
    }

    @ObservationIgnored private lazy var habits: Habits = readsSaved ? AppCache.read(Self.habitsFile) ?? Habits() : Habits()

    /// How much, and how lately (each play counts less the older it is:
    /// half as much after a week).
    private static func score(_ dates: [Date], now: Date = Date()) -> Double {
        dates.reduce(0) { $0 + pow(0.5, now.timeIntervalSince($1) / (7 * 24 * 3600)) }
    }

    func notePlay(_ id: String, kind: String) {
        var played = habits.titles[id] ?? Habits.Played(kind: kind, at: [])
        played.at = Array((played.at + [Date()]).suffix(20))
        habits.titles[id] = played
        // The 100 that count most are enough.
        if habits.titles.count > 100 {
            for (id, _) in habits.titles.sorted(by: { Self.score($0.value.at) < Self.score($1.value.at) }).prefix(habits.titles.count - 100) {
                habits.titles[id] = nil
            }
        }
        save(Self.habitsFile, habits)
    }

    func noteChannel(_ id: String) {
        habits.channels[id] = Array(((habits.channels[id] ?? []) + [Date()]).suffix(20))
        if habits.channels.count > 100 {
            for (id, _) in habits.channels.sorted(by: { Self.score($0.value) < Self.score($1.value) }).prefix(habits.channels.count - 100) {
                habits.channels[id] = nil
            }
        }
        save(Self.habitsFile, habits)
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
}

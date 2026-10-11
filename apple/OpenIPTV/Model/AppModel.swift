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
        rows = AppCache.read("home.json") ?? []
        Task { await guide.loadCache(); guideState = await guide.state }
    }

    var emby: EmbyClient? {
        sources.emby.map { EmbyClient(account: $0, deviceId: sources.deviceId) }
    }

    // MARK: Home

    func loadHome(cardWidth: Int) async {
        lastCardWidth = cardWidth
        guard let emby else {
            rows = []
            return
        }
        do {
            let fresh = try await emby.home(cardWidth: cardWidth)
            if fresh != rows { rows = fresh }
            homeError = nil
            AppCache.write("home.json", fresh)
            // The first few things you'd tap on Home are ready before you do.
            let likely = fresh.prefix(2).flatMap { $0.cards.prefix(3) }
            prepare(likely.map { (id: $0.episodeId ?? $0.id, kind: Optional($0.episodeId != nil ? "Episode" : $0.kind)) })
            Task { await library.prepare(emby) }
        } catch {
            homeError = SourceError.wrap(error).localizedDescription
        }
    }

    func playback(itemId: String, kind: String? = nil) async throws -> EmbyPlayback {
        let started = Date()
        let task: Task<EmbyPlayback, Error>
        if let ready = prepared[itemId], Date().timeIntervalSince(ready.at) < 180 {
            task = ready.task
        } else {
            guard let emby else { throw SourceError.unexpected("Add your Emby server in Settings.") }
            task = Task { try await emby.playback(itemId: itemId, kind: kind) }
        }
        prepared[itemId] = nil
        var playback = try await task.value
        playback.resolvedIn = Date().timeIntervalSince(started)
        playback.requestedAt = started
        return playback
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
            prepared[id] = (Date(), Task(priority: .utility) { try await emby.playback(itemId: id, kind: kind) })
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
        if let emby { await library.prepare(emby) }
    }

    func playback(for card: Card) async throws -> EmbyPlayback {
        try await playback(itemId: card.id, kind: card.kind)
    }

    func report(_ playback: EmbyPlayback, seconds: Double, event: EmbyClient.PlaybackEvent) async {
        await emby?.report(event, itemId: playback.itemId, seconds: seconds,
                           mediaSourceId: playback.mediaSourceId, playSessionId: playback.playSessionId)
        // Positions changed, so anything prepared earlier may resume wrongly.
        if event == .stopped {
            prepared = [:]
            coolDown()
        }
        if event == .stopped { await loadHome(cardWidth: lastCardWidth) }
    }

    // MARK: Accounts

    func signedInToEmby(_ account: EmbyAccount) async {
        sources.setEmby(account)
        await loadHome(cardWidth: lastCardWidth)
    }

    func signOutOfEmby() async {
        await emby?.logout()
        sources.setEmby(nil)
        rows = []
        AppCache.remove("home.json")
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
        library.clear()
        serverSearchCache = [:]
        channelCorpus = SearchCorpus(name: \.name)
        rows = []
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
    func loadLive(force: Bool = false) async {
        guard force || allChannels.isEmpty, !liveLoading else { return }
        let iptv = sources.iptv
        guard !iptv.isEmpty else {
            categories = []
            allChannels = []
            channelsByCategory = [:]
            liveErrors = []
            return
        }
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
            }
        }
        categories = cats
        allChannels = channels
        channelCorpus = await Task.detached(priority: .userInitiated) { SearchCorpus(channels, name: \.name) }.value
        channelsByCategory = Dictionary(grouping: channels, by: { $0.categoryId ?? "" })
        channelById = Dictionary(channels.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        liveErrors = errors
        if selectedCategory == nil
            || (selectedCategory != Self.favoritesID && !cats.contains { $0.id == selectedCategory }) {
            selectedCategory = cats.first?.id
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

    func channels(in category: String?, favorites: [LiveChannel]) -> [LiveChannel] {
        if category == Self.favoritesID { return resolved(favorites) }
        return channelsByCategory[category ?? ""] ?? []
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

    func card(for entry: LibraryEntry, width: Int) -> Card? {
        emby?.card(for: entry, width: width)
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

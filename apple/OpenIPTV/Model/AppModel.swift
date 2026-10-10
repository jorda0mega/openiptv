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
    private var visible: Set<String> = []
    private var nowNextTask: Task<Void, Never>?
    private var boundaryTask: Task<Void, Never>?
    private var providerEPG: [String: (until: Int64, list: [Programme])] = [:]

    init() {
        selectedCategory = UserDefaults.standard.string(forKey: "category")
        rows = Self.readCache("home.json") ?? []
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
            Self.writeCache("home.json", fresh)
        } catch {
            homeError = SourceError.wrap(error).localizedDescription
        }
    }

    func playback(for card: Card) async throws -> EmbyPlayback {
        guard let emby else { throw SourceError.unexpected("Add your Emby server in Settings.") }
        return try await emby.playback(itemId: card.id)
    }

    func report(_ playback: EmbyPlayback, seconds: Double, event: EmbyClient.PlaybackEvent) async {
        await emby?.report(event, itemId: playback.itemId, seconds: seconds)
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
        Self.removeCache("home.json")
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

    /// Case-insensitive search across every source, on the device.
    func search(_ query: String) -> [LiveChannel] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return [] }
        return Array(allChannels.lazy.filter { $0.name.localizedCaseInsensitiveContains(q) }.prefix(300))
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

    // MARK: Cache (display data only; never credentials or stream URLs)

    private static var cacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    private static func readCache<T: Decodable>(_ name: String) -> T? {
        guard let data = try? Data(contentsOf: cacheDir.appending(path: name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func writeCache<T: Encodable>(_ name: String, _ value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: cacheDir.appending(path: name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func removeCache(_ name: String) {
        try? FileManager.default.removeItem(at: cacheDir.appending(path: name))
    }
}

import Foundation
import Observation

/// App state. Screens render from what's cached first and refresh behind it;
/// live titles refresh at the exact second a programme ends.
@Observable
@MainActor
final class AppModel {
    private(set) var client: APIClient?
    var server: Server? {
        didSet { saveServer() }
    }
    var status: ServerStatus?
    var connectionError: String?

    var rows: [HomeRow] = []
    var homeError: String?
    var homeLoadMs: Int?

    var categories: [Category] = []
    var selectedCategory: String? {
        didSet { UserDefaults.standard.set(selectedCategory, forKey: "category") }
    }
    var channels: [Channel] = []
    var channelsError: String?
    private(set) var nowNext: [Int64: NowNext] = [:]

    private var channelCache: [String: [Channel]] = [:]
    private var visible: Set<Int64> = []
    private var nowNextTask: Task<Void, Never>?
    private var boundaryTask: Task<Void, Never>?

    init() {
        server = Self.loadServer()
        #if targetEnvironment(simulator)
        // The simulator shares this Mac's network; the server trusts loopback.
        if server == nil { server = Server(url: URL(string: "http://127.0.0.1:8787")!, key: nil) }
        #endif
        selectedCategory = UserDefaults.standard.string(forKey: "category")
        rows = Self.readCache("home.json") ?? []
        categories = Self.readCache("categories.json") ?? []
        if let server { client = APIClient(server: server) }
    }

    // MARK: Connection

    func connect(to server: Server) async {
        self.server = server
        client = APIClient(server: server)
        rows = []
        await refreshStatus()
    }

    func refreshStatus() async {
        guard let client else { return }
        do {
            status = try await client.status()
            connectionError = nil
        } catch {
            connectionError = error.localizedDescription
        }
    }

    // MARK: Home

    func loadHome(cardWidth: Int) async {
        guard let client else { return }
        let started = Date()
        do {
            let fresh = try await client.home(width: cardWidth)
            homeLoadMs = Int(Date().timeIntervalSince(started) * 1000)
            if fresh != rows { rows = fresh }
            homeError = nil
            Self.writeCache("home.json", fresh)
        } catch {
            homeError = error.localizedDescription
        }
    }

    // MARK: Live TV

    func loadCategories() async {
        guard let client else { return }
        do {
            let fresh = try await client.categories()
            if fresh != categories { categories = fresh }
            Self.writeCache("categories.json", fresh)
            if selectedCategory == nil || !fresh.contains(where: { $0.id == selectedCategory }) {
                selectedCategory = fresh.first?.id
            }
            if let selectedCategory { await select(category: selectedCategory) }
        } catch {
            channelsError = error.localizedDescription
        }
    }

    func select(category: String) async {
        selectedCategory = category
        if let cached = channelCache[category] { channels = cached }
        guard let client else { return }
        do {
            let fresh = try await client.channels(category: category)
            channelCache[category] = fresh
            if selectedCategory == category { channels = fresh }
            channelsError = nil
        } catch {
            channelsError = error.localizedDescription
        }
    }

    func search(_ query: String) async -> [Channel] {
        guard let client, query.count >= 2 else { return [] }
        return (try? await client.channels(query: query)) ?? []
    }

    func streamURL(for channel: Channel) -> URL? { client?.streamURL(for: channel) }

    // MARK: Now / next

    func appeared(_ id: Int64) {
        visible.insert(id)
        scheduleNowNext()
    }

    func disappeared(_ id: Int64) {
        visible.remove(id)
    }

    /// Fetch now/next for the given channels right away (player overlay).
    func ensureNowNext(_ ids: [Int64]) async {
        let stale = ids.filter { nowNext[$0].map(\.isStale) ?? true }
        await fetchNowNext(stale)
    }

    private func scheduleNowNext() {
        nowNextTask?.cancel()
        nowNextTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard let self, !Task.isCancelled else { return }
            let stale = self.visible.filter { self.nowNext[$0].map(\.isStale) ?? true }
            await self.fetchNowNext(Array(stale))
            self.scheduleBoundary()
        }
    }

    private func fetchNowNext(_ ids: [Int64]) async {
        guard let client, !ids.isEmpty else { return }
        for start in stride(from: 0, to: ids.count, by: 50) {
            let batch = Array(ids[start..<min(start + 50, ids.count)])
            if let fresh = try? await client.nowNext(ids: batch) {
                nowNext.merge(fresh) { _, new in new }
            }
        }
    }

    /// One timer for the earliest programme change among visible channels.
    private func scheduleBoundary() {
        boundaryTask?.cancel()
        let next = visible.compactMap { nowNext[$0]?.refreshAt }.min()
        guard let next else { return }
        let delay = max(1, Double(next) - Date.now.timeIntervalSince1970 + 1.5)
        boundaryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.scheduleNowNext()
        }
    }

    // MARK: Persistence (no secrets here; the pairing key goes to the Keychain)

    private static var cacheDir: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
    }

    private static func readCache<T: Decodable>(_ name: String) -> T? {
        guard let data = try? Data(contentsOf: cacheDir.appending(path: name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func writeCache<T: Encodable>(_ name: String, _ value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: cacheDir.appending(path: name), options: .atomic)
    }

    private func saveServer() {
        UserDefaults.standard.set(server?.url.absoluteString, forKey: "serverURL")
        Keychain.set(server?.key, for: "serverKey")
    }

    private static func loadServer() -> Server? {
        guard let raw = UserDefaults.standard.string(forKey: "serverURL"), let url = URL(string: raw) else {
            return nil
        }
        return Server(url: url, key: Keychain.get("serverKey"))
    }
}

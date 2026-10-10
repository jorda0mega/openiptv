import Foundation

// Mirrors the JSON served by openiptv-edge (crates/edge, crates/core/src/app.rs).

struct CardImage: Codable, Hashable {
    let url: String
    let contain: Bool
}

struct Card: Codable, Hashable, Identifiable {
    let id: String
    let kind: String
    let title: String
    let subtitle: String?
    let images: [CardImage]
    let progress: Double?
    let playable: Bool?
}

/// What the server resolved an Emby item to (series → next episode).
struct EmbyPlayback: Codable, Hashable, Identifiable {
    var id: String { itemId }
    let itemId: String
    let title: String
    let subtitle: String?
    let url: String
    let startSeconds: Double?
    let durationSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case title, subtitle, url
        case itemId = "item_id"
        case startSeconds = "start_seconds"
        case durationSeconds = "duration_seconds"
    }
}

struct HomeRow: Codable, Hashable, Identifiable {
    var id: String { title }
    let title: String
    let shape: String
    let aspect: Double
    let cards: [Card]
}

struct Category: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let channels: Int
}

struct Channel: Codable, Hashable, Identifiable {
    let id: Int64
    let number: Int64?
    let name: String
    let logo: String?
    let category: String?
}

struct Show: Codable, Hashable {
    let title: String
    let start: Int64
    let stop: Int64

    func progress(at date: Date = .now) -> Double {
        let now = date.timeIntervalSince1970
        guard stop > start else { return 0 }
        return min(1, max(0, (now - Double(start)) / Double(stop - start)))
    }
}

struct NowNext: Codable, Hashable {
    let now: Show?
    let next: Show?
    let refreshAt: Int64?
    let source: String

    enum CodingKeys: String, CodingKey {
        case now, next, source
        case refreshAt = "refresh_at"
    }

    var isStale: Bool {
        guard let refreshAt else { return false }
        return Int64(Date.now.timeIntervalSince1970) >= refreshAt
    }
}

struct ServerStatus: Codable {
    struct Emby: Codable {
        let ok: Bool
        let server: String?
        let error: String?
    }
    struct Live: Codable {
        let ok: Bool
        let channels: Int?
        let error: String?
    }
    struct Zap: Codable {
        let channel: Int64
        let headersMs: Int
        let firstBytesMs: Int
    }
    let emby: Emby
    let live: Live
    let lastZap: Zap?
}

/// Where the OpenIPTV server is and the key other devices must present.
struct Server: Codable, Equatable {
    var url: URL
    var key: String?

    /// Accepts the link the server prints (`http://host:8787/?key=…`) or a
    /// bare address.
    init?(link: String) {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var parts = URLComponents(string: withScheme), parts.host != nil else { return nil }
        key = parts.queryItems?.first(where: { $0.name == "key" })?.value
        parts.query = nil
        parts.path = ""
        guard let url = parts.url else { return nil }
        self.url = url
    }

    init(url: URL, key: String?) {
        self.url = url
        self.key = key
    }

    var cookie: String? { key.map { "openiptv_key=\($0)" } }
}

enum APIError: LocalizedError {
    case status(Int, String?)
    var errorDescription: String? {
        switch self {
        case let .status(code, message): message ?? "Server returned HTTP \(code)"
        }
    }
}

final class APIClient: @unchecked Sendable {
    let server: Server
    private let session: URLSession
    private let decoder = JSONDecoder()

    init(server: Server) {
        self.server = server
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    private func get<T: Decodable>(_ path: String, _ query: [URLQueryItem] = []) async throws -> T {
        var parts = URLComponents(url: server.url.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query }
        var request = URLRequest(url: parts.url!)
        if let cookie = server.cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        let (data, response) = try await session.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw APIError.status(code, message)
        }
        return try decoder.decode(T.self, from: data)
    }

    func status() async throws -> ServerStatus { try await get("api/status") }

    func home(width: Int) async throws -> [HomeRow] {
        try await get("api/home", [URLQueryItem(name: "width", value: String(width))])
    }

    func categories() async throws -> [Category] { try await get("api/live/categories") }

    func channels(category: String? = nil, query: String? = nil) async throws -> [Channel] {
        var items: [URLQueryItem] = []
        if let category { items.append(URLQueryItem(name: "category", value: category)) }
        if let query { items.append(URLQueryItem(name: "q", value: query)) }
        return try await get("api/live/channels", items)
    }

    func nowNext(ids: [Int64]) async throws -> [Int64: NowNext] {
        let raw: [String: NowNext] = try await get(
            "api/live/nownext",
            [URLQueryItem(name: "ids", value: ids.map(String.init).joined(separator: ","))]
        )
        return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in Int64(k).map { ($0, v) } })
    }

    func streamURL(for channel: Channel) -> URL {
        server.url.appending(path: "live/\(channel.id).ts")
    }

    func embyPlayback(id: String) async throws -> EmbyPlayback {
        try await get("api/emby/play/\(id)")
    }

    func reportProgress(itemId: String, seconds: Double, event: String) async {
        var request = URLRequest(url: server.url.appending(path: "api/emby/progress"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let cookie = server.cookie { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "item_id": itemId, "position_seconds": seconds, "event": event,
        ])
        _ = try? await session.data(for: request)
    }

    /// Exchange the six-digit code shown on the Mac for the access key.
    static func pair(serverURL: URL, pin: String) async throws -> String {
        var request = URLRequest(url: serverURL.appending(path: "api/pair"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["pin": pin])
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        guard code == 200, let key = body["key"] else { throw APIError.status(code, body["error"]) }
        return key
    }
}

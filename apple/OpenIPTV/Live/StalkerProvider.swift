import Foundation

/// Stalker / Ministra middleware portals ("MAC portals"). The device
/// identifies itself with a MAC address, gets a session token from the
/// handshake, and asks the portal for a fresh link each time a channel plays.
final class StalkerProvider: LiveProvider, @unchecked Sendable {
    let source: IPTVSource
    private let portal: URL
    private let mac: String
    private let session: Session

    private static let userAgent = "Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 (KHTML, like Gecko) MAG200 stbapp ver: 2 rev: 250 Safari/533.3"

    init(source: IPTVSource) {
        self.source = source
        guard case let .stalker(portal, mac) = source.kind else { fatalError("not stalker") }
        self.portal = portal
        self.mac = mac.uppercased()
        session = Session()
    }

    /// `AA:BB:CC:DD:EE:FF`, also accepting dashes or no separators.
    static func normaliseMAC(_ input: String) -> String? {
        let hex = input.uppercased().filter { $0.isHexDigit }
        guard hex.count == 12 else { return nil }
        return stride(from: 0, to: 12, by: 2).map { i -> String in
            let start = hex.index(hex.startIndex, offsetBy: i)
            return String(hex[start..<hex.index(start, offsetBy: 2)])
        }.joined(separator: ":")
    }

    static func normalisePortal(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let parts = URLComponents(string: withScheme), parts.host != nil else { return nil }
        return parts.url
    }

    /// Portals live at different paths; try the common ones.
    private var endpoints: [URL] {
        guard var root = URLComponents(url: portal, resolvingAgainstBaseURL: false) else { return [] }
        let path = root.path.lowercased()
        root.path = ""
        root.query = nil
        guard let base = root.url else { return [] }
        if path.contains("stalker_portal") {
            return [base.appending(path: "stalker_portal/server/load.php")]
        }
        return [base.appending(path: "portal.php"), base.appending(path: "stalker_portal/server/load.php"),
                base.appending(path: "server/load.php")]
    }

    private actor Session {
        var endpoint: URL?
        var token: String?
        func set(endpoint: URL, token: String) { self.endpoint = endpoint; self.token = token }
        func clear() { token = nil }
    }

    private func request(_ endpoint: URL, _ query: [URLQueryItem], token: String?) -> URLRequest {
        var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        parts.queryItems = query + [.init(name: "JsHttpRequest", value: "1-xml")]
        var request = URLRequest(url: parts.url!)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("Model: MAG250; Link: WiFi", forHTTPHeaderField: "X-User-Agent")
        request.setValue("mac=\(mac); stb_lang=en; timezone=UTC", forHTTPHeaderField: "Cookie")
        request.setValue(portal.absoluteString, forHTTPHeaderField: "Referer")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func authenticate() async throws -> (URL, String) {
        if let endpoint = await session.endpoint, let token = await session.token { return (endpoint, token) }
        var lastError: Error = SourceError.unexpected("That portal didn't respond like a Stalker portal.")
        for endpoint in endpoints {
            do {
                let data = try await HTTP.data(request(endpoint, [
                    .init(name: "type", value: "stb"), .init(name: "action", value: "handshake"),
                    .init(name: "token", value: ""), .init(name: "prehash", value: "0"),
                ], token: nil))
                guard let token = Self.js(data)?["token"] as? String, !token.isEmpty else { continue }
                // Some portals only activate the session after a profile call.
                _ = try? await HTTP.data(request(endpoint, [
                    .init(name: "type", value: "stb"), .init(name: "action", value: "get_profile"),
                    .init(name: "hd", value: "1"), .init(name: "stb_type", value: "MAG250"),
                ], token: token))
                await session.set(endpoint: endpoint, token: token)
                return (endpoint, token)
            } catch {
                lastError = error
            }
        }
        throw SourceError.wrap(lastError)
    }

    /// One authenticated call, re-handshaking once if the token expired.
    private func call(_ query: [URLQueryItem]) async throws -> Any? {
        for attempt in 0..<2 {
            let (endpoint, token) = try await authenticate()
            do {
                let data = try await HTTP.data(request(endpoint, query, token: token))
                if let text = String(data: data, encoding: .utf8), text.contains("Authorization failed"), attempt == 0 {
                    await session.clear()
                    continue
                }
                return Self.jsValue(data)
            } catch SourceError.rejected where attempt == 0 {
                await session.clear()
            }
        }
        throw SourceError.rejected
    }

    func load() async throws -> LiveLineup {
        let genres = (try await call([.init(name: "type", value: "itv"), .init(name: "action", value: "get_genres")]) as? [[String: Any]]) ?? []
        let all = try await call([.init(name: "type", value: "itv"), .init(name: "action", value: "get_all_channels")])
        let rows = ((all as? [String: Any])?["data"] as? [[String: Any]]) ?? (all as? [[String: Any]]) ?? []
        guard !rows.isEmpty else { throw SourceError.unexpected("The portal returned no channels for this MAC address.") }

        let channels = rows.compactMap { row -> LiveChannel? in
            guard let id = Self.string(row["id"]), let cmd = Self.string(row["cmd"]),
                  let name = Self.string(row["name"]), !AccountInfoFilter.looksLikeAccountInfo(name) else { return nil }
            let genre = Self.string(row["tv_genre_id"])
            return LiveChannel(
                id: "\(source.id.uuidString)|\(id)", sourceId: source.id, number: Self.string(row["number"]).flatMap { Int64($0) },
                name: name, logo: Self.string(row["logo"]).flatMap { $0.hasPrefix("http") ? URL(string: $0) : nil },
                categoryId: genre.map { "\(source.id.uuidString)|\($0)" }, epgId: Self.string(row["xmltv_id"]),
                nativeId: id, stream: .stalker(cmd: cmd)
            )
        }
        var counts: [String: Int] = [:]
        for c in channels { if let cat = c.categoryId { counts[cat, default: 0] += 1 } }
        let categories = genres.compactMap { g -> LiveCategory? in
            guard let gid = Self.string(g["id"]), let title = Self.string(g["title"]) else { return nil }
            let id = "\(source.id.uuidString)|\(gid)"
            guard let count = counts[id], count > 0 else { return nil }
            return LiveCategory(id: id, name: title, channels: count)
        }
        return LiveLineup(categories: categories, channels: channels, guideURLs: [])
    }

    func shortEPG(for channel: LiveChannel) async -> [Programme] {
        guard let rows = try? await call([
            .init(name: "type", value: "itv"), .init(name: "action", value: "get_short_epg"),
            .init(name: "ch_id", value: channel.nativeId), .init(name: "size", value: "4"),
        ]) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let start = Self.string(row["start_timestamp"]).flatMap({ Int64($0) }),
                  let stop = Self.string(row["stop_timestamp"]).flatMap({ Int64($0) }),
                  let name = Self.string(row["name"]) else { return nil }
            return Programme(start: start, stop: stop, title: name)
        }
    }

    func playable(_ channel: LiveChannel) async throws -> PlayableStream {
        guard case let .stalker(cmd) = channel.stream else { throw SourceError.unexpected("Not a portal channel.") }
        let result = try await call([
            .init(name: "type", value: "itv"), .init(name: "action", value: "create_link"),
            .init(name: "cmd", value: cmd), .init(name: "series", value: ""),
            .init(name: "forced_storage", value: "undefined"), .init(name: "disable_ad", value: "0"),
            .init(name: "download", value: "0"),
        ])
        let raw = (Self.string((result as? [String: Any])?["cmd"]) ?? cmd).trimmingCharacters(in: .whitespaces)
        let link = raw.split(separator: " ").last.map(String.init) ?? raw  // drop "ffmpeg " / "auto " prefixes
        guard let url = URL(string: link), url.scheme != nil else {
            throw SourceError.unexpected("The portal didn't return a playable link.")
        }
        return PlayableStream(url: url, headers: ["User-Agent: \(Self.userAgent)"])
    }

    // MARK: JSON helpers (portal responses are wrapped in {"js": …})

    private static func jsValue(_ data: Data) -> Any? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["js"]
    }

    private static func js(_ data: Data) -> [String: Any]? { jsValue(data) as? [String: Any] }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let s as String: s.isEmpty ? nil : s
        case let n as NSNumber: n.stringValue
        default: nil
        }
    }
}

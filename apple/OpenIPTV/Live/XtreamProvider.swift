import Foundation

/// Xtream Codes `player_api.php`. Mirrors crates/core/src/xtream.rs: every
/// field decoded leniently, EPG text base64-decoded, account-info channels
/// dropped, URLs always built from the login host.
final class XtreamProvider: LiveProvider, @unchecked Sendable {
    let source: IPTVSource
    private let server: URL
    private let username: String
    private let password: String
    private var outputExtension = "ts"

    init(source: IPTVSource) {
        self.source = source
        guard case let .xtream(server, username, password) = source.kind else { fatalError("not xtream") }
        self.server = server
        self.username = username
        self.password = password
    }

    /// Accepts `host:port`, a full URL, or a `get.php`/`player_api.php` link
    /// (which also carries the username and password).
    static func parse(_ input: String) -> (server: URL, username: String?, password: String?)? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var parts = URLComponents(string: withScheme), parts.host != nil else { return nil }
        let items = parts.queryItems ?? []
        let user = items.first { $0.name == "username" }?.value
        let pass = items.first { $0.name == "password" }?.value
        var path = parts.path
        for suffix in ["get.php", "player_api.php", "xmltv.php"] where path.hasSuffix(suffix) {
            path.removeLast(suffix.count)
        }
        if !path.hasSuffix("/") { path += "/" }
        parts.path = path
        parts.query = nil
        guard let url = parts.url else { return nil }
        return (url, user, pass)
    }

    private func api(_ items: [URLQueryItem]) -> URL {
        var parts = URLComponents(url: server.appending(path: "player_api.php"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "username", value: username), .init(name: "password", value: password)] + items
        return parts.url!
    }

    func load() async throws -> LiveLineup {
        async let accountData = HTTP.data(api([]))
        async let categoryData = HTTP.data(api([.init(name: "action", value: "get_live_categories")]))
        async let channelData = HTTP.data(api([.init(name: "action", value: "get_live_streams")]))

        let account = try JSONDecoder().decode(Account.self, from: try await accountData)
        guard account.user_info.auth else { throw SourceError.rejected }
        let formats = account.user_info.allowed_output_formats
        if !formats.isEmpty, !formats.contains("ts"), formats.contains("m3u8") { outputExtension = "m3u8" }

        let rawCategories = JSONDecoder().lenientList(RawCategory.self, from: try await categoryData)
        let hidden = Set(rawCategories.filter { AccountInfoFilter.looksLikeAccountInfo($0.name) }.map(\.id))
        let secrets = [username, password]
        let channels = JSONDecoder().lenientList(RawChannel.self, from: try await channelData).compactMap { raw -> LiveChannel? in
            guard let id = raw.stream_id,
                  !AccountInfoFilter.looksLikeAccountInfo(raw.name),
                  !AccountInfoFilter.mentions(raw.name, secrets: secrets),
                  raw.category_id.map({ !hidden.contains($0) }) ?? true
            else { return nil }
            return LiveChannel(
                id: "\(source.id.uuidString)|\(id)", sourceId: source.id, number: raw.num, name: raw.name,
                logo: raw.stream_icon.flatMap { $0.hasPrefix("http") ? URL(string: $0) : nil },
                categoryId: raw.category_id.map { "\(source.id.uuidString)|\($0)" }, epgId: raw.epg_channel_id,
                nativeId: String(id), stream: .xtream(streamId: id)
            )
        }
        var counts: [String: Int] = [:]
        for c in channels { if let cat = c.categoryId { counts[cat, default: 0] += 1 } }
        let categories = rawCategories.compactMap { raw -> LiveCategory? in
            let id = "\(source.id.uuidString)|\(raw.id)"
            guard let count = counts[id], count > 0 else { return nil }
            return LiveCategory(id: id, name: raw.name, channels: count)
        }
        var xmltv = URLComponents(url: server.appending(path: "xmltv.php"), resolvingAgainstBaseURL: false)!
        xmltv.queryItems = [.init(name: "username", value: username), .init(name: "password", value: password)]
        return LiveLineup(categories: categories, channels: channels, guideURLs: [xmltv.url!])
    }

    func shortEPG(for channel: LiveChannel) async -> [Programme] {
        guard let data = try? await HTTP.data(api([
            .init(name: "action", value: "get_short_epg"), .init(name: "stream_id", value: channel.nativeId),
            .init(name: "limit", value: "4"),
        ])), let epg = try? JSONDecoder().decode(ShortEPG.self, from: data) else { return [] }
        return epg.listings.compactMap { l in
            guard let start = l.start, let stop = l.stop else { return nil }
            return Programme(start: start, stop: stop, title: Self.decodeText(l.title))
        }
    }

    func playable(_ channel: LiveChannel) async throws -> PlayableStream {
        guard case let .xtream(id) = channel.stream else { throw SourceError.unexpected("Not an Xtream channel.") }
        var url = server
        for segment in ["live", username, password, "\(id).\(outputExtension)"] { url.append(path: segment) }
        return PlayableStream(url: url)
    }

    /// EPG text is base64 on most panels and plain on some; decode only when
    /// the result is clean text so plain titles like "News" survive.
    static func decodeText(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        var padded = t
        while padded.count % 4 != 0 { padded += "=" }
        if let data = Data(base64Encoded: padded), let text = String(data: data, encoding: .utf8),
           !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0) }) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return t
    }

    // MARK: Wire formats

    private struct Account: Decodable {
        struct UserInfo: Decodable {
            let auth: Bool
            let allowed_output_formats: [String]
            enum CodingKeys: String, CodingKey { case auth, allowed_output_formats }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                auth = c.flexBool(.auth)
                allowed_output_formats = (try? c.decodeIfPresent([String].self, forKey: .allowed_output_formats)) ?? []
            }
        }
        let user_info: UserInfo
    }

    private struct RawCategory: Decodable {
        let id: String
        let name: String
        enum CodingKeys: String, CodingKey { case category_id, category_name }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guard let id = c.flexString(.category_id) else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "no id"))
            }
            self.id = id
            name = c.flexString(.category_name) ?? id
        }
    }

    private struct RawChannel: Decodable {
        let stream_id: Int64?
        let num: Int64?
        let name: String
        let stream_icon: String?
        let epg_channel_id: String?
        let category_id: String?
        enum CodingKeys: String, CodingKey { case stream_id, num, name, stream_icon, epg_channel_id, category_id }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            stream_id = c.flexInt(.stream_id)
            num = c.flexInt(.num)
            name = (c.flexString(.name) ?? "").trimmingCharacters(in: .whitespaces)
            stream_icon = c.flexString(.stream_icon)
            epg_channel_id = c.flexString(.epg_channel_id)?.trimmingCharacters(in: .whitespaces)
            category_id = c.flexString(.category_id)
        }
    }

    private struct ShortEPG: Decodable {
        struct Listing: Decodable {
            let title: String
            let start: Int64?
            let stop: Int64?
            enum CodingKeys: String, CodingKey { case title, start_timestamp, stop_timestamp, end_timestamp }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                title = c.flexString(.title) ?? ""
                start = c.flexInt(.start_timestamp)
                stop = c.flexInt(.stop_timestamp) ?? c.flexInt(.end_timestamp)
            }
        }
        let listings: [Listing]
        enum CodingKeys: String, CodingKey { case epg_listings }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            listings = ((try? c.decodeIfPresent([Lenient<Listing>].self, forKey: .epg_listings)) ?? nil)?.compactMap(\.value) ?? []
        }
    }
}

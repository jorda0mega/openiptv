import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Talks to the user's Emby server directly. Mirrors crates/core/src/emby.rs
/// and app.rs: small list payloads, the faster resumable-items query for
/// Continue Watching, per-library Latest rows, direct-stream playback.
struct EmbyClient {
    let account: EmbyAccount
    let deviceId: String

    private static let cardQuery: [URLQueryItem] = [
        .init(name: "Fields", value: "PrimaryImageAspectRatio,ProductionYear,BasicSyncInfo"),
        .init(name: "ImageTypeLimit", value: "1"),
        .init(name: "EnableImageTypes", value: "Primary,Backdrop,Thumb"),
        .init(name: "EnableUserData", value: "true"),
        .init(name: "EnableTotalRecordCount", value: "false"),
    ]

    // MARK: Sign-in (passwords are sent once and never kept)

    /// Accepts `host:port`, `http(s)://host[:port]` and paths with or
    /// without `/emby`.
    static func normalise(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard var parts = URLComponents(string: withScheme), parts.host != nil else { return nil }
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.lowercased().hasSuffix("/emby") { path.removeLast(5) }
        if path.lowercased().hasSuffix("/web/index.html") { path.removeLast(15) }
        parts.path = path
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    static func login(server: URL, username: String, password: String, deviceId: String) async throws -> EmbyAccount {
        var request = URLRequest(url: api(server, "Users/AuthenticateByName"))
        request.httpMethod = "POST"
        request.setValue(authorization(deviceId: deviceId, userId: nil, token: nil), forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(["Username": username, "Pw": password])
        let data = try await HTTP.data(request)
        struct Auth: Decodable {
            struct User: Decodable { let Id: String; let Name: String? }
            let AccessToken: String
            let User: User
        }
        let auth = try JSONDecoder().decode(Auth.self, from: data)
        let name = (try? await publicInfoName(server)) ?? server.host() ?? "Emby"
        return EmbyAccount(serverURL: server, serverName: name, userId: auth.User.Id,
                           userName: auth.User.Name ?? username, accessToken: auth.AccessToken)
    }

    /// Emby Connect: sign in with an emby.media account and list the servers
    /// linked to it.
    static func connectLogin(email: String, password: String) async throws -> EmbyConnectSession {
        var request = URLRequest(url: URL(string: "https://connect.emby.media/service/user/authenticate")!)
        request.httpMethod = "POST"
        request.setValue("OpenIPTV/\(HTTP.appVersion)", forHTTPHeaderField: "X-Application")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form(["nameOrEmail": email, "rawpw": password])
        struct Auth: Decodable {
            struct User: Decodable { let Id: String }
            let AccessToken: String
            let User: User
        }
        let auth = try JSONDecoder().decode(Auth.self, from: try await HTTP.data(request))
        var list = URLRequest(url: URL(string: "https://connect.emby.media/service/servers?userId=\(auth.User.Id)")!)
        list.setValue("OpenIPTV/\(HTTP.appVersion)", forHTTPHeaderField: "X-Application")
        list.setValue(auth.AccessToken, forHTTPHeaderField: "X-Connect-UserToken")
        list.setValue("application/json", forHTTPHeaderField: "Accept")
        let servers = JSONDecoder().lenientList(EmbyConnectServer.self, from: try await HTTP.data(list))
        return EmbyConnectSession(userId: auth.User.Id, accessToken: auth.AccessToken, servers: servers)
    }

    /// Trade a Connect server's access key for a normal session, trying the
    /// server's remote then local address.
    static func exchange(_ server: EmbyConnectServer, session: EmbyConnectSession, deviceId: String) async throws -> EmbyAccount {
        var lastError: Error = SourceError.network("That server isn't reachable.")
        for address in server.addresses {
            guard let base = normalise(address.absoluteString) else { continue }
            var parts = URLComponents(url: api(base, "Connect/Exchange"), resolvingAgainstBaseURL: false)!
            parts.queryItems = [.init(name: "format", value: "json"), .init(name: "ConnectUserId", value: session.userId)]
            var request = URLRequest(url: parts.url!)
            request.timeoutInterval = 8
            request.setValue(authorization(deviceId: deviceId, userId: nil, token: nil), forHTTPHeaderField: "X-Emby-Authorization")
            request.setValue(server.accessKey, forHTTPHeaderField: "X-Emby-Token")
            do {
                struct Exchange: Decodable { let LocalUserId: String; let AccessToken: String }
                let result = try JSONDecoder().decode(Exchange.self, from: try await HTTP.data(request))
                return EmbyAccount(serverURL: base, serverName: server.name, userId: result.LocalUserId,
                                   userName: server.name, accessToken: result.AccessToken)
            } catch {
                lastError = error
            }
        }
        throw SourceError.wrap(lastError)
    }

    /// Ends the session on the server so the stored token stops working.
    func logout() async {
        var request = URLRequest(url: Self.api(account.serverURL, "Sessions/Logout"))
        request.httpMethod = "POST"
        authorize(&request)
        _ = try? await HTTP.data(request)
    }

    // MARK: Home

    func home(cardWidth: Int) async throws -> [HomeRow] {
        let views: [EmbyItem] = try await items("Users/\(account.userId)/Views", [])
        let libraries = views.filter { ["movies", "tvshows"].contains($0.collectionType ?? "") }.prefix(8)

        async let resume = items("Users/\(account.userId)/Items", Self.cardQuery + [
            .init(name: "Filters", value: "IsResumable"), .init(name: "Recursive", value: "true"),
            .init(name: "SortBy", value: "DatePlayed"), .init(name: "SortOrder", value: "Descending"),
            .init(name: "IncludeItemTypes", value: "Movie,Episode"), .init(name: "Limit", value: "12"),
        ])
        async let nextUp = items("Shows/NextUp", Self.cardQuery + [
            .init(name: "UserId", value: account.userId), .init(name: "Limit", value: "12"),
        ])
        let latest = await withTaskGroup(of: (Int, [EmbyItem]?).self) { group in
            for (index, library) in libraries.enumerated() {
                group.addTask {
                    let rows = try? await items("Users/\(account.userId)/Items/Latest", Self.cardQuery + [
                        .init(name: "ParentId", value: library.id), .init(name: "Limit", value: "16"),
                    ])
                    return (index, rows)
                }
            }
            var out = [[EmbyItem]?](repeating: nil, count: libraries.count)
            for await (index, rows) in group { out[index] = rows }
            return out
        }

        var rows: [HomeRow] = []
        if let row = row("Continue Watching", try await resume, .landscape, cardWidth) { rows.append(row) }
        if let row = row("Next Up", (try? await nextUp) ?? [], .landscape, cardWidth) { rows.append(row) }
        for (library, items) in zip(libraries, latest) {
            if let items, let row = row("Latest in \(library.name)", items, .poster, cardWidth) { rows.append(row) }
        }
        return rows
    }

    private func row(_ title: String, _ items: [EmbyItem], _ context: Artwork.Context, _ width: Int) -> HomeRow? {
        guard !items.isEmpty else { return nil }
        let shape = Artwork.listShape(items, context: context)
        let pixelWidth = shape == .landscape ? width * 16 / 10 : width
        let cards = items.map { item in
            let images = Artwork.candidates(item, context: context).map { candidate in
                CardImage(url: imageURL(candidate, width: pixelWidth, shape: shape).absoluteString,
                          contain: candidate.contain(in: shape))
            }
            let (title, subtitle) = Self.titles(item)
            let progress = item.userData?.playedPercentage.flatMap { $0 > 0 && $0 < 100 ? $0 : nil }
            let playable = ["Movie", "Episode", "Video", "MusicVideo", "Series", "Season"].contains(item.kind)
            return Card(id: item.id, kind: item.kind, title: title, subtitle: subtitle,
                        images: images, progress: progress, playable: playable)
        }
        return HomeRow(title: title, shape: shape.rawValue, aspect: shape.aspect, cards: cards)
    }

    private static func titles(_ item: EmbyItem) -> (String, String?) {
        if item.kind == "Episode" {
            var code = ""
            if let s = item.parentIndexNumber, let e = item.indexNumber { code = "S\(s):E\(e) · " }
            return (item.seriesName ?? item.name, "\(code)\(item.name)")
        }
        return (item.name, item.productionYear.map(String.init))
    }

    func imageURL(_ candidate: Artwork.Candidate, width: Int, shape: Artwork.Shape) -> URL {
        let path = candidate.index.map { "Items/\(candidate.itemId)/Images/\(candidate.type)/\($0)" }
            ?? "Items/\(candidate.itemId)/Images/\(candidate.type)"
        let w = Artwork.bucket(width)
        var query: [URLQueryItem] = [.init(name: "tag", value: candidate.tag), .init(name: "maxWidth", value: String(w))]
        if candidate.type == "Primary" {
            query.append(.init(name: "maxHeight", value: String(Int((Double(w) / shape.aspect).rounded()))))
        }
        query.append(.init(name: "quality", value: candidate.type == "Backdrop" ? "70" : "90"))
        var parts = URLComponents(url: Self.api(account.serverURL, path), resolvingAgainstBaseURL: false)!
        parts.queryItems = query
        return parts.url!
    }

    // MARK: Playback

    /// Series and seasons resolve to the next unwatched episode; partly
    /// watched items resume.
    func playback(itemId: String) async throws -> EmbyPlayback {
        var item: EmbyItem = try await get("Users/\(account.userId)/Items/\(itemId)", [])
        if item.kind == "Series" || item.kind == "Season" {
            let series = item.kind == "Series" ? item.id : (item.seriesId ?? "")
            guard let episode = try await episodeToPlay(series: series, season: item.kind == "Season" ? item.id : nil) else {
                throw SourceError.unexpected("There's nothing to play in this show yet.")
            }
            item = episode
        }
        let resume = (item.userData?.played == true) ? nil
            : item.userData?.playbackPositionTicks.flatMap { $0 > 0 ? Double($0) / 1e7 : nil }
        var parts = URLComponents(url: Self.api(account.serverURL, "Videos/\(item.id)/stream"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            .init(name: "static", value: "true"), .init(name: "MediaSourceId", value: item.id),
            .init(name: "api_key", value: account.accessToken),
        ]
        let (title, subtitle) = Self.titles(item)
        return EmbyPlayback(itemId: item.id, title: title, subtitle: subtitle, url: parts.url!,
                            startSeconds: resume, durationSeconds: item.runTimeTicks.map { Double($0) / 1e7 })
    }

    private func episodeToPlay(series: String, season: String?) async throws -> EmbyItem? {
        if season == nil {
            let next: [EmbyItem] = try await items("Shows/NextUp", [
                .init(name: "UserId", value: account.userId), .init(name: "SeriesId", value: series),
                .init(name: "Limit", value: "1"),
            ])
            if let first = next.first { return first }
        }
        var query: [URLQueryItem] = [.init(name: "UserId", value: account.userId)]
        if let season { query.append(.init(name: "SeasonId", value: season)) }
        let episodes: [EmbyItem] = try await items("Shows/\(series)/Episodes", query)
        return episodes.first { $0.userData?.played != true } ?? episodes.first
    }

    enum PlaybackEvent: String { case started = "Sessions/Playing", progress = "Sessions/Playing/Progress", stopped = "Sessions/Playing/Stopped" }

    /// Keeps Continue Watching right on every device.
    func report(_ event: PlaybackEvent, itemId: String, seconds: Double) async {
        var request = URLRequest(url: Self.api(account.serverURL, event.rawValue))
        request.httpMethod = "POST"
        authorize(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "ItemId": itemId, "PositionTicks": Int64(max(0, seconds) * 1e7),
            "PlayMethod": "DirectStream", "CanSeek": true,
        ])
        _ = try? await HTTP.data(request)
    }

    // MARK: Plumbing

    static func api(_ server: URL, _ path: String) -> URL {
        server.appending(path: "emby").appending(path: path)
    }

    private static func publicInfoName(_ server: URL) async throws -> String? {
        struct Info: Decodable { let ServerName: String? }
        return try JSONDecoder().decode(Info.self, from: try await HTTP.data(api(server, "System/Info/Public"))).ServerName
    }

    private static func authorization(deviceId: String, userId: String?, token: String?) -> String {
        #if canImport(UIKit)
        let device = UIDevice.current.model.replacingOccurrences(of: "\"", with: "")
        #else
        let device = "Mac"
        #endif
        var value = "Emby UserId=\"\(userId ?? "")\", Client=\"OpenIPTV\", Device=\"\(device)\", DeviceId=\"\(deviceId)\", Version=\"\(HTTP.appVersion)\""
        if let token { value += ", Token=\"\(token)\"" }
        return value
    }

    private func authorize(_ request: inout URLRequest) {
        request.setValue(Self.authorization(deviceId: deviceId, userId: account.userId, token: account.accessToken),
                         forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(account.accessToken, forHTTPHeaderField: "X-Emby-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
    }

    private func get<T: Decodable>(_ path: String, _ query: [URLQueryItem]) async throws -> T {
        var parts = URLComponents(url: Self.api(account.serverURL, path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query }
        var request = URLRequest(url: parts.url!)
        authorize(&request)
        do {
            return try JSONDecoder().decode(T.self, from: try await HTTP.data(request))
        } catch {
            throw SourceError.wrap(error)
        }
    }

    /// Item lists come back either bare or wrapped in `{ Items: [...] }`.
    private func items(_ path: String, _ query: [URLQueryItem]) async throws -> [EmbyItem] {
        var parts = URLComponents(url: Self.api(account.serverURL, path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { parts.queryItems = query }
        var request = URLRequest(url: parts.url!)
        authorize(&request)
        let data = try await HTTP.data(request)
        struct Page: Decodable { let Items: [Lenient<EmbyItem>]? }
        if data.first == UInt8(ascii: "[") {
            return JSONDecoder().lenientList(EmbyItem.self, from: data)
        }
        return (try? JSONDecoder().decode(Page.self, from: data))?.Items?.compactMap(\.value) ?? []
    }

    private static func form(_ fields: [String: String]) -> Data {
        var parts = URLComponents()
        parts.queryItems = fields.map { URLQueryItem(name: $0.key, value: $0.value) }
        let encoded = (parts.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        return Data(encoded.utf8)
    }
}

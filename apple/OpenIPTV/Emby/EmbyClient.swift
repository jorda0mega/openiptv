import Foundation
import os
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
        .init(name: "Fields", value: "PrimaryImageAspectRatio,ProductionYear,BasicSyncInfo,ProviderIds,DateCreated"),
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
        request.setValue("Openreel/\(HTTP.appVersion)", forHTTPHeaderField: "X-Application")
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
        list.setValue("Openreel/\(HTTP.appVersion)", forHTTPHeaderField: "X-Application")
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

    /// Debug builds, UI tests on a real server: `-readOnlyServer YES` sends
    /// nothing that changes it (where titles were left, My List, its
    /// order, subtitle downloads), so a test leaves the viewer's account
    /// as it was.
    #if DEBUG
    static var readOnly: Bool { UserDefaults.standard.bool(forKey: "readOnlyServer") }
    #else
    static let readOnly = false
    #endif

    #if DEBUG
    /// Real-feed checks only (`-debugWebsocketProbe YES`): a title marked
    /// watched or not, whatever `-readOnlyServer` says.
    func debugSetPlayed(_ itemId: String, _ played: Bool) async throws {
        var request = URLRequest(url: Self.api(account.serverURL, "Users/\(account.userId)/PlayedItems/\(itemId)"))
        request.httpMethod = played ? "POST" : "DELETE"
        authorize(&request)
        _ = try await HTTP.data(request)
    }

    /// Emby's websocket with one way of sending the key: refused, opened
    /// but deaf to a watched change made meanwhile, or hearing it.
    func debugProbeSocket(_ form: SocketProbe.Form, marking film: String) async -> String {
        #if canImport(UIKit)
        let device = UIDevice.current.model.replacingOccurrences(of: "\"", with: "")
        #else
        let device = "Mac"
        #endif
        let authorization = "MediaBrowser Client=\"Openreel\", Device=\"\(device)\", DeviceId=\"\(deviceId)\", "
            + "Version=\"\(HTTP.appVersion)\", Token=\"\(account.accessToken)\""
        switch await SocketProbe.open(account.serverURL, form, token: account.accessToken, deviceId: deviceId, authorization: authorization) {
        case .unreachable:
            return "unreachable"
        case .refused:
            return "refused"
        case let .opened(socket):
            try? await debugSetPlayed(film, true)
            let heard = await socket.hears(film, within: .seconds(15))
            try? await debugSetPlayed(film, false)
            socket.close()
            return heard ? "heard the change" : "opened, heard nothing"
        }
    }

    /// A film the viewer hasn't watched or started, to mark and unmark.
    func debugUnwatchedFilm() async -> String? {
        struct Page: Decodable { let Items: [Lenient<EmbyItem>]? }
        let page: Page? = try? await get("Users/\(account.userId)/Items", [
            .init(name: "IncludeItemTypes", value: "Movie"), .init(name: "Recursive", value: "true"),
            .init(name: "Filters", value: "IsUnplayed"), .init(name: "Fields", value: "UserData"), .init(name: "Limit", value: "20"),
        ])
        return page?.Items?.compactMap(\.value).first { $0.userData?.played != true && ($0.userData?.playbackPositionTicks ?? 0) == 0 }?.id
    }
    #endif

    // MARK: My List

    /// Puts a film or show on the viewer's My List (Emby's favorites), or
    /// takes it off.
    func setFavorite(_ itemId: String, _ on: Bool) async throws {
        guard !Self.readOnly else { return }
        var request = URLRequest(url: Self.api(account.serverURL, "Users/\(account.userId)/FavoriteItems/\(itemId)"))
        request.httpMethod = on ? "POST" : "DELETE"
        authorize(&request)
        _ = try await HTTP.data(request)
    }

    /// When each title was put on My List, by any of the viewer's devices:
    /// the app's own record on the server (Emby keeps no such date), in the
    /// viewer's display preferences under the app's own name. Nil when the
    /// server didn't answer.
    func myListDates() async -> [String: Double]? {
        struct Preferences: Decodable { let CustomPrefs: [String: String]? }
        guard let found: Preferences = try? await get("DisplayPreferences/\(Self.myListRecord)", [
            .init(name: "userId", value: account.userId), .init(name: "client", value: Self.recordClient),
        ]) else { return nil }
        return (found.CustomPrefs ?? [:]).compactMapValues(Double.init)
    }

    /// Writes that record (item id → seconds since 1970), replacing it.
    func saveMyListDates(_ dates: [String: Double]) async {
        await saveRecord(Self.myListRecord, dates.mapValues { String(Int($0)) })
    }

    /// Replaces one of the app's records on the server (in the viewer's
    /// display preferences, under the app's own name).
    private func saveRecord(_ id: String, _ values: [String: String]) async {
        guard !Self.readOnly else { return }
        var parts = URLComponents(url: Self.api(account.serverURL, "DisplayPreferences/\(id)"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "userId", value: account.userId), .init(name: "client", value: Self.recordClient)]
        var request = URLRequest(url: parts.url!)
        request.httpMethod = "POST"
        authorize(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The fields Emby's display preferences always carry, then the values.
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "Id": id, "Client": Self.recordClient, "SortBy": "SortName", "SortOrder": "Ascending",
            "RememberIndexing": false, "RememberSorting": false, "ShowBackdrop": false, "ShowSidebar": false,
            "PrimaryImageHeight": 0, "PrimaryImageWidth": 0, "ScrollDirection": "Horizontal",
            "CustomPrefs": values,
        ])
        _ = try? await HTTP.data(request)
    }

    private static let myListRecord = "zapline-mylist"
    private static let recordClient = "zapline"

    /// Games found playing on none of their channels, by any of the
    /// viewer's devices: a channel's key (see AppModel.sharedKey: hashed,
    /// nothing of the provider readable) → when (seconds since 1970). Nil
    /// when the server didn't answer.
    func notPlayingRecord() async -> [String: Double]? {
        struct Preferences: Decodable { let CustomPrefs: [String: String]? }
        guard let found: Preferences = try? await get("DisplayPreferences/\(Self.notPlayingRecordId)", [
            .init(name: "userId", value: account.userId), .init(name: "client", value: Self.recordClient),
        ]) else { return nil }
        return (found.CustomPrefs ?? [:]).compactMapValues(Double.init)
    }

    func saveNotPlaying(_ record: [String: Double]) async {
        await saveRecord(Self.notPlayingRecordId, record.mapValues { String(Int($0)) })
    }

    private static let notPlayingRecordId = "zapline-notplaying"

    // MARK: Short watches

    /// Where a title was last stopped (seconds in), and when (seconds since
    /// 1970), by any of the viewer's devices.
    struct Started: Sendable, Equatable {
        let seconds: Double
        let at: Double
    }

    /// The app's record of where titles were stopped: Emby keeps no place
    /// before 5% of a title (two minutes of an episode), so its Continue
    /// Watching leaves those out; this record keeps them, for every device.
    /// Nil when the server didn't answer.
    func startedRecord() async -> [String: Started]? {
        struct Preferences: Decodable { let CustomPrefs: [String: String]? }
        guard let found: Preferences = try? await get("DisplayPreferences/\(Self.startedRecordId)", [
            .init(name: "userId", value: account.userId), .init(name: "client", value: Self.recordClient),
        ]) else { return nil }
        return (found.CustomPrefs ?? [:]).compactMapValues { value in
            let parts = value.split(separator: "|").compactMap { Double($0) }
            return parts.count == 2 ? Started(seconds: parts[0], at: parts[1]) : nil
        }
    }

    /// A title stopped `seconds` in (nil: finished): kept in the record (the
    /// newest 40), or taken out once finished. Under ten seconds changes
    /// nothing (opened by mistake).
    func noteStarted(_ itemId: String, seconds: Double?) async {
        guard !Self.readOnly else { return }
        var record = await startedRecord() ?? [:]
        if let seconds {
            guard seconds >= 10 else { return }
            record[itemId] = Started(seconds: seconds, at: Date().timeIntervalSince1970)
        } else {
            guard record.removeValue(forKey: itemId) != nil else { return }
        }
        if record.count > 40 {
            record = Dictionary(uniqueKeysWithValues: record.sorted { $0.value.at > $1.value.at }.prefix(40).map { ($0.key, $0.value) })
        }
        Self.started.withLock { $0 = (true, record) }
        await saveRecord(Self.startedRecordId, record.mapValues { "\(Int($0.seconds))|\(Int($0.at))" })
    }

    /// The record as last read or written (and whether it's been read this
    /// run): where a title it holds starts.
    private static let started = OSAllocatedUnfairLock(initialState: (read: false, record: [String: Started]()))
    private static let startedRecordId = "zapline-started"

    /// Where the record says a title was stopped, unless it's been finished
    /// since (the server knows). The record is read first if nothing has
    /// read it this run: a title got ready at launch, from the Home saved
    /// before, started from the beginning.
    private func recordedStart(_ item: EmbyItem) async -> Double? {
        guard item.userData?.played != true else { return nil }
        if !Self.started.withLock({ $0.read }), let record = await startedRecord() {
            Self.started.withLock { $0 = (true, record) }
        }
        return Self.started.withLock { $0.record[item.id]?.seconds }
    }

    /// Subtitles the server's providers (OpenSubtitles, …) offer for an
    /// item in a language ("eng", "spa"), best first: made for this exact
    /// file, then the most downloaded; forced-only ones left out.
    func searchSubtitles(_ itemId: String, mediaSourceId: String?, language: String) async throws -> [RemoteSubtitle] {
        let found: [RemoteSubtitle] = try await get("Items/\(itemId)/RemoteSearch/Subtitles/\(language)",
                                                    [.init(name: "MediaSourceId", value: mediaSourceId)].filter { $0.value != nil })
        return found.filter { $0.IsForced != true }.sorted {
            ($0.IsHashMatch == true ? 1 : 0, $0.DownloadCount ?? 0) > ($1.IsHashMatch == true ? 1 : 0, $1.DownloadCount ?? 0)
        }
    }

    /// Has the server download one of them; it's then one of the item's
    /// subtitle files. Refused for an account without the right to manage
    /// subtitles.
    func downloadSubtitle(_ itemId: String, mediaSourceId: String?, id: String) async throws {
        guard !Self.readOnly else { return }
        var parts = URLComponents(url: Self.api(account.serverURL, "Items/\(itemId)/RemoteSearch/Subtitles"),
                                  resolvingAgainstBaseURL: false)!
        parts.percentEncodedPath += "/" + Self.segment(id)
        if let mediaSourceId { parts.queryItems = [.init(name: "MediaSourceId", value: mediaSourceId)] }
        var request = URLRequest(url: parts.url!)
        request.httpMethod = "POST"
        authorize(&request)
        _ = try await HTTP.data(request)
    }

    /// One of them, read through the server (nothing saved there: any
    /// account may). Nil when it can't be read or isn't text.
    func subtitleText(id: String) async -> String? {
        var parts = URLComponents(url: Self.api(account.serverURL, "Providers/Subtitles/Subtitles"), resolvingAgainstBaseURL: false)!
        parts.percentEncodedPath += "/" + Self.segment(id)
        var request = URLRequest(url: parts.url!)
        authorize(&request)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        guard let data = try? await HTTP.data(request), !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
    }

    /// A provider's id as one path segment, escaped once (escaped by hand
    /// and then by the URL, "-" arrived as "%252D").
    private static func segment(_ id: String) -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
    }

    struct RemoteSubtitle: Decodable {
        let Id: String
        let Name: String?
        let ProviderName: String?
        let DownloadCount: Int?
        let IsHashMatch: Bool?
        let IsForced: Bool?
    }

    /// The films and shows on the viewer's My List.
    func favorites() async throws -> [EmbyItem] {
        try await items("Users/\(account.userId)/Items", [
            .init(name: "Filters", value: "IsFavorite"), .init(name: "Recursive", value: "true"),
            .init(name: "IncludeItemTypes", value: "Movie,Series"), .init(name: "Limit", value: "100"),
            // The IMDb and TMDb ids: an HD and a 4K copy are one title.
            .init(name: "Fields", value: "PrimaryImageAspectRatio,ProductionYear,Genres,ProviderIds"),
            .init(name: "EnableImageTypes", value: "Primary,Thumb,Backdrop"),
        ])
    }

    // MARK: Home

    /// What Home is built from, fetched at once.
    struct HomeSources {
        /// Partly watched, most recent first.
        var watching: [EmbyItem]
        /// The next episode of each show being watched.
        var nextUp: [EmbyItem]
        /// Recently finished, most recent first.
        var played: [EmbyItem]
    }

    func homeSources() async throws -> HomeSources {
        async let watching = watching()
        async let nextUp = nextUp()
        async let played = played()
        return HomeSources(watching: try await watching, nextUp: (try? await nextUp) ?? [],
                           played: (try? await played) ?? [])
    }

    /// Films and shows added lately, newest first, with overview and
    /// backdrop: Home's featured pick before the charts have downloaded.
    func recentlyAdded(limit: Int = 30) async -> [EmbyItem] {
        (try? await items("Users/\(account.userId)/Items", [
            .init(name: "Recursive", value: "true"), .init(name: "IncludeItemTypes", value: "Movie,Series"),
            .init(name: "SortBy", value: "DateCreated"), .init(name: "SortOrder", value: "Descending"),
            .init(name: "Limit", value: String(limit)),
            .init(name: "Fields", value: "PrimaryImageAspectRatio,ProductionYear,ProviderIds,DateCreated,Overview"),
            .init(name: "ImageTypeLimit", value: "1"), .init(name: "EnableImageTypes", value: "Primary,Backdrop,Thumb,Logo"),
            .init(name: "EnableUserData", value: "true"), .init(name: "EnableTotalRecordCount", value: "false"),
        ])) ?? []
    }

    /// Partly watched, most recent first: the server's, and the titles
    /// stopped too early for it to keep (see startedRecord), each where it
    /// was stopped. Regression: CSI watched under two minutes wasn't in
    /// Continue Watching the next time the app opened.
    func watching() async throws -> [EmbyItem] {
        async let record = startedRecord()
        let resumable: [EmbyItem] = try await items("Users/\(account.userId)/Items", Self.cardQuery + [
            .init(name: "Filters", value: "IsResumable"), .init(name: "Recursive", value: "true"),
            .init(name: "SortBy", value: "DatePlayed"), .init(name: "SortOrder", value: "Descending"),
            .init(name: "IncludeItemTypes", value: "Movie,Episode"), .init(name: "Limit", value: "30"),
        ])
        guard let record = await record else { return resumable }
        Self.started.withLock { $0 = (true, record) }
        let listed = Set(resumable.map(\.id))
        let missing = record.filter { !listed.contains($0.key) }.sorted { $0.value.at > $1.value.at }.prefix(20)
        guard !missing.isEmpty else { return resumable }
        let stamp = ISO8601DateFormatter()
        let extra: [EmbyItem] = await items(ids: missing.map(\.key)).compactMap { found in
            guard found.userData?.played != true, let start = record[found.id] else { return nil }
            var item = found
            var user = item.userData ?? EmbyItem.UserData()
            user.playbackPositionTicks = Int64(start.seconds * 10_000_000)
            if let ticks = item.runTimeTicks, ticks > 0 { user.playedPercentage = start.seconds * 10_000_000 / Double(ticks) * 100 }
            user.lastPlayedDate = stamp.string(from: Date(timeIntervalSince1970: start.at))
            item.userData = user
            return item
        }
        // In among the server's by when each was played (the server's
        // own order kept).
        func when(_ item: EmbyItem) -> Substring { (item.userData?.lastPlayedDate ?? "").prefix(19) }
        var merged = resumable
        for item in extra.sorted(by: { when($0) > when($1) }) {
            let at = merged.firstIndex { when($0) < when(item) } ?? merged.endIndex
            merged.insert(item, at: at)
        }
        return merged
    }

    /// Recently finished, most recent first.
    func played(limit: Int = 40) async throws -> [EmbyItem] {
        try await items("Users/\(account.userId)/Items", Self.cardQuery + [
            .init(name: "Filters", value: "IsPlayed"), .init(name: "Recursive", value: "true"),
            .init(name: "SortBy", value: "DatePlayed"), .init(name: "SortOrder", value: "Descending"),
            .init(name: "IncludeItemTypes", value: "Movie,Episode"), .init(name: "Limit", value: String(limit)),
        ])
    }

    /// The next episode of each show being watched.
    func nextUp() async throws -> [EmbyItem] {
        try await items("Shows/NextUp", Self.cardQuery + [
            .init(name: "UserId", value: account.userId), .init(name: "Limit", value: "16"),
        ])
    }

    /// A show's episodes that changed since `date`: watched or progress
    /// (this user's data) or the episode itself (new, or edited). Usually
    /// none, so a saved show is brought up to date with two tiny answers. A
    /// server that ignores the filter just returns them all, which merges
    /// the same.
    func episodeChanges(of series: String, since date: Date) async throws -> [EmbyItem] {
        let stamp = ISO8601DateFormatter().string(from: date.addingTimeInterval(-120))
        let query: [URLQueryItem] = [
            .init(name: "ParentId", value: series), .init(name: "Recursive", value: "true"),
            .init(name: "IncludeItemTypes", value: "Episode"), .init(name: "EnableUserData", value: "true"),
            .init(name: "Fields", value: "Overview,PrimaryImageAspectRatio"),
            .init(name: "ImageTypeLimit", value: "1"), .init(name: "EnableImageTypes", value: "Primary,Thumb,Backdrop"),
            .init(name: "EnableTotalRecordCount", value: "false"),
        ]
        async let forUser = items("Users/\(account.userId)/Items", query + [.init(name: "MinDateLastSavedForUser", value: stamp)])
        async let saved = items("Users/\(account.userId)/Items", query + [.init(name: "MinDateLastSaved", value: stamp)])
        var seen = Set<String>()
        return try await (forUser + saved).filter { seen.insert($0.id).inserted }
    }

    /// Titles like this one (genre, cast, director), as Emby judges it.
    func similar(to id: String, limit: Int = 24) async -> [EmbyItem] {
        (try? await items("Items/\(id)/Similar", Self.cardQuery + [
            .init(name: "UserId", value: account.userId), .init(name: "Limit", value: String(limit)),
        ])) ?? []
    }

    /// These titles with what this user has watched of them, plus overview
    /// and backdrop.
    func items(ids: [String]) async -> [EmbyItem] {
        guard !ids.isEmpty else { return [] }
        let found = (try? await items("Users/\(account.userId)/Items", [
            .init(name: "Ids", value: ids.joined(separator: ",")),
            .init(name: "Fields", value: "PrimaryImageAspectRatio,ProductionYear,ProviderIds,DateCreated,Overview"),
            .init(name: "ImageTypeLimit", value: "1"), .init(name: "EnableImageTypes", value: "Primary,Backdrop,Thumb"),
            .init(name: "EnableUserData", value: "true"), .init(name: "EnableTotalRecordCount", value: "false"),
        ])) ?? []
        let order = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return found.sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
    }

    /// One card per show (Netflix-style), carrying the episode to resume;
    /// movies stay as they are.
    func showRow(_ title: String, _ items: [EmbyItem], _ width: Int) -> HomeRow? {
        // By show, and by show name too: the same show in two libraries (HD
        // and 4K, say) has two ids but should be one card. Films by title.
        var seen = Set<String>()
        let unique = items.filter { item in
            guard item.kind == "Episode" else { return seen.insert(item.titleKey).inserted }
            let byName = "name:" + (item.seriesName ?? "").lowercased()
            let byId = "id:" + (item.seriesId ?? item.id)
            let fresh = !seen.contains(byName) && !seen.contains(byId)
            seen.insert(byName)
            seen.insert(byId)
            return fresh
        }.prefix(20)
        guard !unique.isEmpty else { return nil }
        let shape = Artwork.Shape.landscape
        // As in the Apple TV app: "S1, E1 · 33m" for an episode, "1h 2m" for
        // a film (the time left).
        let cards = unique.map { item -> Card in
            let base = card(item, context: .landscape, shape: shape, width: width)
            guard item.kind == "Episode", let series = item.seriesId else {
                guard let left = Self.timeLeft(item) else { return base }
                return Card(id: base.id, kind: base.kind, title: base.title, subtitle: left, images: base.images,
                            progress: base.progress, playable: base.playable, episodeId: base.episodeId, seriesId: base.seriesId)
            }
            var code = ""
            if let s = item.parentIndexNumber, let e = item.indexNumber { code = "S\(s), E\(e)" }
            let line = [code.isEmpty ? nil : code, Self.timeLeft(item) ?? item.name].compactMap(\.self).joined(separator: " · ")
            return Card(id: series, kind: "Series", title: item.seriesName ?? base.title, subtitle: line,
                        images: base.images, progress: base.progress, playable: true, episodeId: item.id,
                        episodeName: item.name)
        }
        return HomeRow(title: title, shape: shape.rawValue, aspect: shape.aspect, cards: Array(cards))
    }

    /// "33m", "1h 2m": what's left of it.
    static func timeLeft(_ item: EmbyItem) -> String? {
        guard let runtime = item.runTimeTicks, runtime > 0 else { return nil }
        let left = max(0, Double(runtime - (item.userData?.playbackPositionTicks ?? 0)) / 1e7)
        let minutes = max(1, Int((left / 60).rounded()))
        return minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    func row(_ title: String, _ items: [EmbyItem], _ context: Artwork.Context, _ width: Int) -> HomeRow? {
        guard !items.isEmpty else { return nil }
        let shape = Artwork.listShape(items, context: context)
        let cards = items.map { card($0, context: context, shape: shape, width: width) }
        return HomeRow(title: title, shape: shape.rawValue, aspect: shape.aspect, cards: cards)
    }

    func card(_ item: EmbyItem, context: Artwork.Context, shape: Artwork.Shape, width: Int) -> Card {
        let pixelWidth = shape == .landscape ? width * 16 / 10 : width
        let images = Artwork.candidates(item, context: context).map { candidate in
            CardImage(url: imageURL(candidate, width: pixelWidth, shape: shape).absoluteString,
                      contain: candidate.contain(in: shape))
        }
        let (title, subtitle) = Self.titles(item)
        let progress = item.userData?.playedPercentage.flatMap { $0 > 0 && $0 < 100 ? $0 : nil }
        let playable = ["Movie", "Episode", "Video", "MusicVideo", "Series", "Season"].contains(item.kind)
        var card = Card(id: item.id, kind: item.kind, title: title, subtitle: subtitle,
                        images: images, progress: progress, playable: playable)
        if item.kind == "Episode" { card.seriesId = item.seriesId }
        return card
    }

    // MARK: Shows

    /// A show with its overview and artwork.
    func item(_ id: String) async throws -> EmbyItem {
        try await get("Users/\(account.userId)/Items/\(id)", [
            .init(name: "Fields", value: "Overview,PrimaryImageAspectRatio,ProductionYear,ProviderIds"),
        ])
    }

    /// A film's details page: story, genres, cast and crew, artwork and
    /// what this user has watched of it.
    func details(_ id: String) async -> EmbyItem? {
        try? await get("Users/\(account.userId)/Items/\(id)", [
            .init(name: "Fields", value: "Overview,Genres,People,ProviderIds,ProductionYear,PrimaryImageAspectRatio"),
        ])
    }

    func seasons(of series: String) async throws -> [EmbyItem] {
        try await items("Shows/\(series)/Seasons", [
            .init(name: "UserId", value: account.userId), .init(name: "EnableUserData", value: "true"),
            .init(name: "Fields", value: "PrimaryImageAspectRatio"),
        ])
    }

    func episodes(of series: String, season: String?) async throws -> [EmbyItem] {
        var query: [URLQueryItem] = [
            .init(name: "UserId", value: account.userId), .init(name: "EnableUserData", value: "true"),
            .init(name: "Fields", value: "Overview,PrimaryImageAspectRatio"),
            .init(name: "ImageTypeLimit", value: "1"), .init(name: "EnableImageTypes", value: "Primary,Thumb,Backdrop"),
        ]
        if let season { query.append(.init(name: "SeasonId", value: season)) }
        return try await items("Shows/\(series)/Episodes", query)
    }

    /// Card for any item: landscape art for episodes (each one's own still
    /// first) and backdrops, posters otherwise.
    func card(for item: EmbyItem, landscape: Bool, width: Int) -> Card {
        let context: Artwork.Context = landscape ? (item.kind == "Episode" ? .still : .landscape) : .poster
        return card(item, context: context, shape: landscape ? .landscape : .portrait, width: width)
    }

    func backdropURL(for item: EmbyItem, width: Int) -> URL? {
        Artwork.candidates(item, context: .backdrop).first.map { imageURL($0, width: width, shape: .landscape) }
    }

    /// The title's logo (transparent title art), when the server has one.
    func logoURL(for item: EmbyItem, width: Int) -> URL? {
        guard let tag = item.imageTags["Logo"] else { return nil }
        var parts = URLComponents(url: Self.api(account.serverURL, "Items/\(item.id)/Images/Logo"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "tag", value: tag), .init(name: "maxWidth", value: String(Artwork.bucket(width))),
                            .init(name: "quality", value: "90")]
        return parts.url
    }

    /// A cast or crew member's photo.
    func personImageURL(_ person: EmbyItem.Person, width: Int) -> URL? {
        guard let id = person.id, let tag = person.primaryImageTag else { return nil }
        var parts = URLComponents(url: Self.api(account.serverURL, "Items/\(id)/Images/Primary"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "tag", value: tag), .init(name: "maxWidth", value: String(Artwork.bucket(width))),
                            .init(name: "quality", value: "90")]
        return parts.url
    }

    // MARK: Search

    /// Movies and shows (name, year, poster tag) for instant on-device
    /// search: everything, or only what was added or changed since
    /// `changedSince`, page by page.
    func libraryIndex(changedSince: Date? = nil, pageSize: Int = 5000, cap: Int = 250_000) async throws -> [LibraryEntry] {
        var out: [LibraryEntry] = []
        var start = 0
        while start < cap {
            let page = try await libraryPage(start: start, limit: pageSize, changedSince: changedSince)
            out += page.entries
            if page.entries.count < pageSize { break }
            start += pageSize
        }
        return out
    }

    /// One page of the catalog, sorted by name; `total` when asked for.
    func libraryPage(start: Int, limit: Int, changedSince: Date? = nil, withTotal: Bool = false) async throws
        -> (entries: [LibraryEntry], total: Int?) {
        struct Entry: Decodable {
            let id: String
            let name: String?
            let kind: String?
            let year: Int?
            let tags: [String: String]?
            /// Values can be null on some servers.
            let providers: [String: String?]?
            let genres: [String]?
            enum CodingKeys: String, CodingKey {
                case id = "Id", name = "Name", kind = "Type", year = "ProductionYear", tags = "ImageTags", providers = "ProviderIds"
                case genres = "Genres"
            }
        }
        struct Page: Decodable {
            let Items: [Lenient<Entry>]?
            let TotalRecordCount: Int?
        }
        var parts = URLComponents(url: Self.api(account.serverURL, "Users/\(account.userId)/Items"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            .init(name: "Recursive", value: "true"), .init(name: "IncludeItemTypes", value: "Movie,Series"),
            .init(name: "Fields", value: "ProductionYear,ProviderIds,Genres"),
            .init(name: "EnableImageTypes", value: "Primary"), .init(name: "ImageTypeLimit", value: "1"),
            .init(name: "EnableUserData", value: "false"), .init(name: "EnableTotalRecordCount", value: withTotal ? "true" : "false"),
            .init(name: "SortBy", value: "SortName"), .init(name: "SortOrder", value: "Ascending"),
            .init(name: "StartIndex", value: String(start)), .init(name: "Limit", value: String(limit)),
        ]
        if let changedSince {
            parts.queryItems?.append(.init(name: "MinDateLastSaved", value: ISO8601DateFormatter().string(from: changedSince)))
        }
        var request = URLRequest(url: parts.url!)
        request.timeoutInterval = 60
        authorize(&request)
        let data = try await HTTP.data(request)
        return try await Task.detached(priority: .utility) {
            let page = try JSONDecoder().decode(Page.self, from: data)
            let entries: [LibraryEntry] = (page.Items ?? []).compactMap(\.value).compactMap { entry in
                guard let name = entry.name, !name.isEmpty else { return nil }
                return LibraryEntry(id: entry.id, name: name, kind: entry.kind ?? "Movie", year: entry.year,
                                    imageTag: entry.tags?["Primary"], aspect: nil,
                                    imdb: EmbyItem.imdb(in: entry.providers?.compactMapValues { $0 }),
                                    tmdb: EmbyItem.tmdb(in: entry.providers?.compactMapValues { $0 }),
                                    genres: entry.genres.flatMap { $0.isEmpty ? nil : $0 })
            }
            return (entries, page.TotalRecordCount)
        }.value
    }

    /// Cast and crew of these titles (each one's actors and directors).
    func people(of ids: [String]) async -> [String: [EmbyItem.Person]] {
        guard !ids.isEmpty else { return [:] }
        let found = (try? await items("Users/\(account.userId)/Items", [
            .init(name: "Ids", value: ids.joined(separator: ",")), .init(name: "Fields", value: "People"),
            .init(name: "EnableImageTypes", value: "None"), .init(name: "EnableUserData", value: "false"),
            .init(name: "EnableTotalRecordCount", value: "false"),
        ])) ?? []
        return Dictionary(found.map { ($0.id, $0.people ?? []) }, uniquingKeysWith: { a, _ in a })
    }

    /// People on the server whose name matches (actors, directors…).
    func persons(matching term: String, limit: Int = 3) async -> [(id: String, name: String)] {
        let found = (try? await items("Persons", [
            .init(name: "SearchTerm", value: term), .init(name: "UserId", value: account.userId),
            .init(name: "Limit", value: String(limit)), .init(name: "EnableImageTypes", value: "None"),
            .init(name: "EnableTotalRecordCount", value: "false"),
        ])) ?? []
        return found.map { ($0.id, $0.name) }
    }

    /// Movies and shows with this person in them.
    func titles(withPerson id: String, limit: Int = 60) async -> [EmbyItem] {
        (try? await personTitles(id, limit: limit)) ?? []
    }

    /// The same, failing when the server can't be reached (a person's page
    /// says so and offers to try again, rather than "nothing").
    func personTitles(_ id: String, limit: Int = 60) async throws -> [EmbyItem] {
        try await items("Users/\(account.userId)/Items", Self.cardQuery + [
            .init(name: "PersonIds", value: id), .init(name: "Recursive", value: "true"),
            .init(name: "IncludeItemTypes", value: "Movie,Series"), .init(name: "Limit", value: String(limit)),
        ])
    }

    /// The server's own search, for episodes (which the on-device index
    /// leaves out) and anything added since the index was built.
    func search(_ term: String, cardWidth: Int) async throws -> [Card] {
        let found = try await items("Users/\(account.userId)/Items", [
            .init(name: "SearchTerm", value: term), .init(name: "Recursive", value: "true"),
            .init(name: "IncludeItemTypes", value: "Movie,Series,Episode"), .init(name: "Limit", value: "40"),
            .init(name: "Fields", value: "PrimaryImageAspectRatio,ProductionYear,Genres"),
            .init(name: "ImageTypeLimit", value: "1"), .init(name: "EnableImageTypes", value: "Primary,Thumb,Backdrop"),
            .init(name: "EnableUserData", value: "false"), .init(name: "EnableTotalRecordCount", value: "false"),
        ])
        return found.map { item in
            let landscape = item.kind == "Episode"
            let base = card(item, context: landscape ? .landscape : .poster, shape: landscape ? .landscape : .portrait, width: cardWidth)
            guard !landscape else { return base }
            return Card(id: base.id, kind: base.kind, title: base.title,
                        subtitle: Self.searchLine(kind: item.kind, year: item.productionYear, genre: item.genres?.first),
                        images: base.images, progress: base.progress, playable: base.playable,
                        episodeId: base.episodeId, seriesId: base.seriesId)
        }
    }

    /// A search result's line, as in the Apple TV app's: "Drama · 2019" for
    /// a film, "TV Show · Thriller" for a show; then its IMDb score.
    static func searchLine(kind: String, year: Int?, genre: String?, rating: String? = nil) -> String {
        let parts: [String?] = kind == "Series" ? ["TV Show", genre] : [genre ?? "Movie", year.map(String.init)]
        return (parts + [rating]).compactMap(\.self).joined(separator: " · ")
    }

    /// A card for an on-device index entry (poster from its image tag),
    /// with its IMDb score when known.
    func card(for entry: LibraryEntry, width: Int, rating: IMDbRatings.Rating? = nil) -> Card {
        var images: [CardImage] = []
        if let tag = entry.imageTag {
            let candidate = Artwork.Candidate(itemId: entry.id, type: "Primary", tag: tag, index: nil,
                                              aspect: entry.aspect ?? Artwork.Shape.portrait.aspect, letterbox: false)
            images.append(CardImage(url: imageURL(candidate, width: width, shape: .portrait).absoluteString,
                                    contain: candidate.contain(in: .portrait)))
        }
        return Card(id: entry.id, kind: entry.kind, title: entry.name,
                    subtitle: Self.searchLine(kind: entry.kind, year: entry.year, genre: entry.genres?.first,
                                              rating: rating.map(IMDbRatings.label)),
                    images: images, progress: nil, playable: true)
    }

    private static func titles(_ item: EmbyItem) -> (String, String?) {
        if item.kind == "Episode" {
            var code = ""
            if let s = item.parentIndexNumber, let e = item.indexNumber { code = "S\(s), E\(e) · " }
            return (item.seriesName ?? item.name, "\(code)\(item.name)")
        }
        // "2024 · Drama", as Apple's player puts it over the title.
        let line = [item.productionYear.map(String.init), item.genres?.first].compactMap(\.self).joined(separator: " · ")
        return (item.name, line.isEmpty ? nil : line)
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
    /// watched items resume. With `kind` known, the item and how to play it
    /// are fetched at the same time instead of one after the other.
    func playback(itemId: String, kind: String? = nil) async throws -> EmbyPlayback {
        let (item, info) = try await resolve(itemId, kind: kind)
        let resume: Double? = if let point = Self.resumePoint(item) { point } else { await recordedStart(item) }
        return await assemble(item, info: info, resume: resume)
    }

    /// One title with copies in several libraries (HD and 4K, a dubbed
    /// one): the copy heard in the language the title calls for (see
    /// TrackChoice.wantedAudio), before a sharper one without it, the
    /// sharpest of those (up to `maxWidth`), resuming from whichever copy
    /// was watched last. A show plays its next episode (from its first
    /// copy); an episode is also looked for in its show's other copies
    /// (`showCopies`: a show's copies by its id), so the same episode in
    /// another library counts as a copy too (Dragon Ball Z's English one).
    func playback(versions ids: [String], kind: String?, maxWidth: Int?,
                  showCopies: @escaping @Sendable (String) -> [String] = { _ in [] }) async throws -> EmbyPlayback {
        var copies: [(item: EmbyItem, info: PlaybackInfo?)]
        if ids.count == 1 || kind == "Series" {
            let (item, info) = try await resolve(ids[0], kind: kind)
            copies = [(item, info)]
        } else {
            copies = await withTaskGroup(of: (Int, EmbyItem, PlaybackInfo?)?.self) { group in
                for (order, id) in ids.enumerated() {
                    group.addTask { (try? await resolve(id, kind: kind)).map { (order, $0.0, $0.1) } }
                }
                var out: [(order: Int, item: EmbyItem, info: PlaybackInfo?)] = []
                for await copy in group { if let copy { out.append(copy) } }
                return out.sorted { $0.order < $1.order }.map { ($0.item, $0.info) }
            }
            guard !copies.isEmpty else { return try await playback(itemId: ids[0], kind: kind) }
        }
        if copies.count == 1, copies[0].item.kind == "Episode", let show = copies[0].item.seriesId {
            let others = showCopies(show).filter { $0 != show }
            if !others.isEmpty { copies += await sameEpisode(copies[0].item, inShows: others) }
        }
        return await choose(copies, kind: copies[0].item.kind == "Episode" ? "Episode" : kind, maxWidth: maxWidth)
    }

    /// The copy to play, ready (see playback(versions:)).
    private func choose(_ copies: [(item: EmbyItem, info: PlaybackInfo?)], kind: String?, maxWidth: Int?) async -> EmbyPlayback {
        func width(_ info: PlaybackInfo?) -> Int { info?.MediaSources?.first?.videoWidth ?? 0 }
        func sound(_ info: PlaybackInfo?) -> [String] {
            (info?.MediaSources?.first?.MediaStreams ?? []).filter { $0.Type == "Audio" }
                .sorted { ($0.Index ?? 0) < ($1.Index ?? 0) }.compactMap { $0.Language.flatMap(TrackChoice.normalized) }
        }
        var keys: [String] = []
        for copy in copies where !keys.contains(copy.item.seriesId ?? copy.item.id) { keys.append(copy.item.seriesId ?? copy.item.id) }
        var chosen = copies[0]
        if copies.count > 1 {
            // The copies with the sound the title calls for (English, or
            // Spanish for a Spanish-made one, or the viewer's choice in any
            // copy), before a sharper one without it: a French-only copy
            // left no English or Spanish to pick while another copy had
            // it. None has it (or none says): all of them.
            let first = copies[0]
            let wanted = TrackChoice.wantedAudio(countries: first.item.productionLocations ?? [], original: sound(first.info).first,
                                                 heard: Set(copies.flatMap { sound($0.info) }), keys: keys)
            let speaking = copies.filter { sound($0.info).contains(wanted) }
            let pool = speaking.isEmpty ? copies : speaking
            let fitting = pool.filter { maxWidth == nil || width($0.info) <= maxWidth! }
            chosen = fitting.max { width($0.info) < width($1.info) } ?? pool.min { width($0.info) < width($1.info) }!
        }
        // Resume where any copy was left off most recently.
        var resume = copies
            .filter { Self.resumePoint($0.item) != nil }
            .max { ($0.item.userData?.lastPlayedDate ?? "") < ($1.item.userData?.lastPlayedDate ?? "") }
            .flatMap { Self.resumePoint($0.item) }
        // Too early in it for the server: where the app's record has it.
        if resume == nil {
            for copy in copies {
                if let start = await recordedStart(copy.item) { resume = start; break }
            }
        }
        var playback = await assemble(chosen.item, info: chosen.info, resume: resume, keys: keys)
        playback.otherCopies = copies.filter { $0.item.id != chosen.item.id }.map { .init(itemId: $0.item.id, languages: sound($0.info)) }
        playback.copyIds = copies.map(\.item.id)
        playback.copyKind = kind
        playback.trackKeys = keys
        return playback
    }

    /// The same episode (its season and number) in other copies of its
    /// show, with how to play each.
    private func sameEpisode(_ episode: EmbyItem, inShows shows: [String]) async -> [(item: EmbyItem, info: PlaybackInfo?)] {
        guard let season = episode.parentIndexNumber, let number = episode.indexNumber else { return [] }
        return await withTaskGroup(of: (Int, EmbyItem, PlaybackInfo?)?.self) { group in
            for (order, show) in shows.enumerated() {
                group.addTask {
                    let query: [URLQueryItem] = [.init(name: "UserId", value: account.userId), .init(name: "Season", value: String(season))]
                    guard let episodes: [EmbyItem] = try? await items("Shows/\(show)/Episodes", query),
                          let match = episodes.first(where: { $0.parentIndexNumber == season && $0.indexNumber == number }),
                          let found = try? await resolve(match.id, kind: "Episode") else { return nil }
                    return (order, found.0, found.1)
                }
            }
            var out: [(order: Int, item: EmbyItem, info: PlaybackInfo?)] = []
            for await copy in group { if let copy { out.append(copy) } }
            return out.sorted { $0.order < $1.order }.map { ($0.item, $0.info) }
        }
    }

    private static func resumePoint(_ item: EmbyItem) -> Double? {
        item.resumeTicks.map { Double($0) / 1e7 }
    }

    /// The item to play (a show's next episode) and, when it could be asked
    /// at the same time, how to play it.
    private func resolve(_ itemId: String, kind: String?) async throws -> (EmbyItem, PlaybackInfo?) {
        let item: EmbyItem
        var prefetchedInfo: PlaybackInfo?
        if kind == "Series" {
            guard let episode = try await episodeToPlay(series: itemId, season: nil) else {
                throw SourceError.unexpected("There's nothing to play in this show yet.")
            }
            // Its full record (a list's has no chapters: the intro's marks),
            // fetched with how to play it.
            async let full: EmbyItem? = try? get("Users/\(account.userId)/Items/\(episode.id)", [])
            async let info = try? playbackInfo(episode.id, startSeconds: nil)
            item = await full ?? episode
            prefetchedInfo = await info
        } else if kind == "Movie" || kind == "Episode" || kind == "Video" {
            async let fetched: EmbyItem = get("Users/\(account.userId)/Items/\(itemId)", [])
            async let info = try? playbackInfo(itemId, startSeconds: nil)
            item = try await fetched
            prefetchedInfo = await info
        } else {
            var fetched: EmbyItem = try await get("Users/\(account.userId)/Items/\(itemId)", [])
            if fetched.kind == "Series" || fetched.kind == "Season" {
                let series = fetched.kind == "Series" ? fetched.id : (fetched.seriesId ?? "")
                guard let episode = try await episodeToPlay(series: series, season: fetched.kind == "Season" ? fetched.id : nil) else {
                    throw SourceError.unexpected("There's nothing to play in this show yet.")
                }
                fetched = episode
            }
            item = fetched
        }
        return (item, prefetchedInfo)
    }

    private func assemble(_ item: EmbyItem, info prefetchedInfo: PlaybackInfo?, resume: Double?, keys: [String] = []) async -> EmbyPlayback {
        let (title, subtitle) = Self.titles(item)
        var playback = EmbyPlayback(itemId: item.id, title: title, subtitle: subtitle,
                                    url: directStreamURL(item.id, mediaSourceId: item.id, playSessionId: nil),
                                    startSeconds: resume, durationSeconds: item.runTimeTicks.map { Double($0) / 1e7 },
                                    fallbacks: [hlsURL(item.id, mediaSourceId: item.id, playSessionId: nil, start: resume)])
        // Ask the server how to play it, like Emby's own apps do: the media
        // source id can differ from the item id, and some sources are remote
        // files to open directly. Fall back to direct stream if this fails.
        let info: PlaybackInfo?
        if let prefetchedInfo { info = prefetchedInfo } else {
            do { info = try await playbackInfo(item.id, startSeconds: resume) } catch {
                #if DEBUG
                NSLog("%@", "PERF playback info failed for \(item.id)")
                #endif
                info = nil
            }
        }
        if let info, let source = info.MediaSources?.first {
            playback.mediaSourceId = source.Id
            playback.playSessionId = info.PlaySessionId
            if source.Protocol == "Http", let path = source.Path, let remote = URL(string: path),
               remote.scheme?.hasPrefix("http") == true {
                playback = EmbyPlayback(itemId: item.id, title: title, subtitle: subtitle, url: remote,
                                        headers: (source.RequiredHttpHeaders ?? [:]).map { "\($0.key): \($0.value)" },
                                        startSeconds: resume, durationSeconds: playback.durationSeconds,
                                        mediaSourceId: source.Id, playSessionId: info.PlaySessionId, method: "remote file",
                                        fallbacks: [directStreamURL(item.id, mediaSourceId: source.Id, playSessionId: info.PlaySessionId),
                                                    hlsURL(item.id, mediaSourceId: source.Id, playSessionId: info.PlaySessionId, start: resume)])
            } else {
                // The original file, even when the server would rather
                // convert it (a remote bitrate limit, say): libmpv plays
                // every common format, opens it in about a second and seeks
                // in it freely, where a conversion takes 5-15 s to begin and
                // restarts on every seek. Converting stays the fallback.
                playback = EmbyPlayback(itemId: item.id, title: title, subtitle: subtitle,
                                        url: directStreamURL(item.id, mediaSourceId: source.Id, playSessionId: info.PlaySessionId,
                                                             container: source.Container),
                                        startSeconds: resume, durationSeconds: playback.durationSeconds,
                                        mediaSourceId: source.Id, playSessionId: info.PlaySessionId,
                                        fallbacks: [hlsURL(item.id, mediaSourceId: source.Id, playSessionId: info.PlaySessionId, start: resume)])
            }
        }
        playback.bitrate = info?.MediaSources?.first?.Bitrate
        playback.listed = info?.MediaSources?.first != nil
        playback.seriesId = item.seriesId
        playback.overview = item.overview
        playback.intro = item.intro
        playback.stills = Artwork.candidates(item, context: item.kind == "Episode" ? .still : .backdrop).prefix(3).map {
            CardImage(url: imageURL($0, width: 540, shape: .landscape).absoluteString, contain: $0.contain(in: .landscape))
        }
        // English or Spanish audio as the title calls for, subtitles off
        // (see TrackChoice), from the tracks the server lists.
        // Always a plan: without the server's track list (it didn't answer
        // in time) it still asks for the language the title calls for, and
        // the player keeps the file's own only when that one isn't there.
        let audio = (info?.MediaSources?.first?.MediaStreams ?? [])
            .filter { $0.Type == "Audio" }
            .sorted { ($0.Index ?? 0) < ($1.Index ?? 0) }
            .map(\.Language)
        playback.tracks = TrackChoice.plan(audio: audio, countries: item.productionLocations ?? [],
                                           key: item.seriesId ?? item.id, keys: keys)
        if let source = info?.MediaSources?.first {
            playback.subtitleLanguages = Set((source.MediaStreams ?? []).filter { $0.Type == "Subtitle" }
                .compactMap { $0.Language.flatMap(TrackChoice.normalized) })
            playback.subtitleFiles = subtitleFiles(item.id, source)
            playback.subtitleCopies = subtitleCopies(item.id, source)
            // For the files, and for any the server finds later (only
            // addresses: nothing is asked for until a file needs it).
            playback.subtitleReferences = subtitleReferences(item.id, source)
            playback.speechStretches = speechStretches(item, source)
        }
        #if DEBUG
        if audio.isEmpty { NSLog("%@", "PERF tracks planned without the server's track list") }
        #endif
        let auth = ["X-Emby-Token: \(account.accessToken)"]
        if playback.method != "remote file" { playback.headers += auth }
        playback.fallbackHeaders = auth
        return playback
    }

    /// The server's subtitle files beside the film, in English or Spanish
    /// (text ones; the server serves each as SRT or ASS).
    private func subtitleFiles(_ itemId: String, _ source: PlaybackInfo.Source) -> [EmbyPlayback.SubtitleFile] {
        (source.MediaStreams ?? []).compactMap { stream in
            guard stream.Type == "Subtitle", stream.IsExternal == true, let language = stream.Language,
                  ["en", "es"].contains(TrackChoice.normalized(language) ?? ""),
                  let subtitle = subtitle(itemId, source, stream)
            else { return nil }
            let kind = [stream.IsForced == true ? "Forced" : nil, stream.IsHearingImpaired == true ? "SDH" : nil, stream.Title]
            return EmbyPlayback.SubtitleFile(source: .server(subtitle), language: language, title: kind.compactMap(\.self).joined(separator: " "))
        }
    }

    /// The film's own text subtitles in English or Spanish (not forced
    /// ones, which show by themselves), as files from the server.
    private func subtitleCopies(_ itemId: String, _ source: PlaybackInfo.Source) -> [EmbyPlayback.SubtitleCopy] {
        (source.MediaStreams ?? []).compactMap { stream in
            guard stream.Type == "Subtitle", stream.IsExternal != true, stream.IsForced != true, let index = stream.Index,
                  let codec = stream.Codec?.lowercased(), Self.textSubtitles.contains(codec),
                  ["en", "es"].contains(stream.Language.flatMap(TrackChoice.normalized) ?? "") else { return nil }
            return subtitle(itemId, source, stream).map { .init(streamIndex: index, subtitle: $0) }
        }
    }

    /// The film's own text track (one, not forced: the server reads the
    /// whole film to extract it), then its other text files in any
    /// language, at most eight in all.
    private func subtitleReferences(_ itemId: String, _ source: PlaybackInfo.Source) -> [EmbyPlayback.SubtitleReference] {
        let tracks = (source.MediaStreams ?? []).filter { $0.Type == "Subtitle" && Self.textSubtitles.contains($0.Codec?.lowercased() ?? "") }
        let own = tracks.filter { $0.IsExternal != true }
        let files = tracks.filter { $0.IsExternal == true && $0.IsForced != true }
        let references = ((own.first { $0.IsForced != true } ?? own.first).map { [$0] } ?? []) + files
        return references.prefix(8).compactMap { subtitle(itemId, source, $0) }.map { .init(subtitle: $0) }
    }

    private static let textSubtitles: Set<String> = ["srt", "subrip", "ass", "ssa", "webvtt", "vtt", "mov_text", "text"]

    /// One format per track, so a copy and a reference are one request.
    private func subtitle(_ itemId: String, _ source: PlaybackInfo.Source, _ stream: PlaybackInfo.Stream) -> ServerSubtitle? {
        guard let index = stream.Index else { return nil }
        let format = ["ass", "ssa"].contains(stream.Codec?.lowercased() ?? "") ? "ass" : "srt"
        let url = Self.api(account.serverURL, "Videos/\(itemId)/\(source.Id)/Subtitles/\(index)/Stream.\(format)")
        let beside = stream.IsExternal == true
        let version = beside
            ? [stream.Codec, stream.Language, stream.Title, stream.IsForced.map(String.init), stream.IsHearingImpaired.map(String.init)]
            : [source.Size.map(String.init), source.Container, stream.Codec]
        return ServerSubtitle(address: url, token: account.accessToken, kind: beside ? .beside : .inFile,
                              version: version.map { $0 ?? "" }.joined(separator: "|"))
    }

    /// Sixteen one-minute stretches evenly across the film (from 2% to 92%:
    /// a file for another cut can be off differently in each part, the
    /// opening too) as audio alone, mono MP3 at 64 kb/s (about 0.5 MB
    /// each). Each its own play session: under one, the server kept sending
    /// the first stretch's sound for every later one.
    private func speechStretches(_ item: EmbyItem, _ source: PlaybackInfo.Source) -> [EmbyPlayback.SpeechStretch] {
        guard let ticks = item.runTimeTicks, ticks > 0 else { return [] }
        let length = Double(ticks) / 10_000_000
        guard length > 2 * SpeechHeard.seconds else { return [] }
        return (0..<16).compactMap { i in
            let start = (length * (0.02 + 0.06 * Double(i))).rounded()
            guard start + SpeechHeard.seconds <= length else { return nil }
            var parts = URLComponents(url: Self.api(account.serverURL, "Audio/\(item.id)/stream.mp3"), resolvingAgainstBaseURL: false)!
            parts.queryItems = [.init(name: "MediaSourceId", value: source.Id),
                                .init(name: "StartTimeTicks", value: String(Int64(start * 10_000_000))),
                                .init(name: "AudioCodec", value: "mp3"), .init(name: "AudioBitRate", value: "64000"),
                                .init(name: "AudioChannels", value: "1"),
                                .init(name: "PlaySessionId", value: UUID().uuidString.replacingOccurrences(of: "-", with: ""))]
            return parts.url.map { .init(start: start, url: $0, token: account.accessToken) }
        }
    }

    /// When nothing would play: how the server answers each address, in
    /// words (no addresses or tokens), so the cause is visible on screen.
    func diagnose(_ playback: EmbyPlayback) async -> String {
        var attempts: [(String, URL, [String])] = [(Self.label(playback.method), playback.url, playback.headers)]
        for url in playback.fallbacks {
            attempts.append((url.path().hasSuffix(".m3u8") ? "Converted" : "Direct", url, playback.fallbackHeaders))
        }
        var parts: [String] = []
        for (label, url, headers) in attempts {
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
            for header in headers {
                let pair = header.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if pair.count == 2 { request.setValue(pair[1], forHTTPHeaderField: pair[0]) }
            }
            do {
                let (data, response) = try await HTTP.session.data(for: request, delegate: HTTP.keyOutOfRedirects)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "?"
                var text = "\(label): HTTP \(status)"
                if status >= 400 {
                    let message = String(decoding: data.prefix(80), as: UTF8.self)
                        .components(separatedBy: .newlines).joined(separator: " ")
                    if !message.contains("http"), !message.contains(account.accessToken) { text += " \(message)" }
                } else {
                    text += " (\(type))"
                }
                parts.append(text)
            } catch {
                parts.append("\(label): \(SourceError.wrap(error).localizedDescription)")
            }
        }
        return parts.joined(separator: " · ")
    }

    private static func label(_ method: String) -> String {
        switch method {
        case "remote file": "Remote file"
        case "transcode": "Converted"
        default: "Direct"
        }
    }

    func directStreamURL(_ itemId: String, mediaSourceId: String, playSessionId: String?, container: String? = nil) -> URL {
        // A file extension helps the player pick the demuxer straight away.
        let ext = container.flatMap { $0.split(separator: ",").first.map { ".\($0)" } } ?? ""
        var parts = URLComponents(url: Self.api(account.serverURL, "Videos/\(itemId)/stream\(ext)"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "Static", value: "true"), .init(name: "MediaSourceId", value: mediaSourceId)]
            + (playSessionId.map { [URLQueryItem(name: "PlaySessionId", value: $0)] } ?? [])
        return parts.url!
    }

    /// Emby's HLS stream, converted on the server: the last resort when the
    /// original file won't open. Starts at `start` because seeking in a
    /// live-converted stream is limited.
    /// `copy`: the server may copy the video and audio as they are (H.264,
    /// AAC) instead of converting them, which starts in about a second.
    func hlsURL(_ itemId: String, mediaSourceId: String, playSessionId: String?, start: Double?, bitrate: Int = 20_000_000,
                copy: Bool = false, audioStreamIndex: Int? = nil) -> URL {
        // Lower bitrates read better at lower resolutions.
        let maxWidth = bitrate >= 8_000_000 ? 1920 : bitrate >= 3_000_000 ? 1280 : 854
        var parts = URLComponents(url: Self.api(account.serverURL, "Videos/\(itemId)/master.m3u8"), resolvingAgainstBaseURL: false)!
        var items: [URLQueryItem] = [
            .init(name: "MediaSourceId", value: mediaSourceId), .init(name: "DeviceId", value: deviceId),
            .init(name: "VideoCodec", value: "h264"), .init(name: "AudioCodec", value: "aac"),
            .init(name: "TranscodingMaxAudioChannels", value: "2"), .init(name: "SegmentContainer", value: "ts"),
            .init(name: "MinSegments", value: "1"), .init(name: "BreakOnNonKeyFrames", value: "True"),
            .init(name: "MaxStreamingBitrate", value: String(bitrate)),
            .init(name: "VideoBitrate", value: String(max(bitrate - 192_000, 500_000))), .init(name: "AudioBitrate", value: "192000"),
            .init(name: "MaxWidth", value: String(maxWidth)),
            .init(name: "StartTimeTicks", value: String(Int64((start ?? 0) * 1e7))),
        ]
        if let playSessionId { items.append(.init(name: "PlaySessionId", value: playSessionId)) }
        if copy { items += [.init(name: "AllowVideoStreamCopy", value: "true"), .init(name: "AllowAudioStreamCopy", value: "true")] }
        // The audio playing (else the server takes the file's first).
        if let audioStreamIndex { items.append(.init(name: "AudioStreamIndex", value: String(audioStreamIndex))) }
        parts.queryItems = items
        return parts.url!
    }

    struct PlaybackInfo: Decodable {
        struct Source: Decodable {
            let Id: String
            let `Protocol`: String?
            let Path: String?
            let Container: String?
            let Size: Int64?
            let Bitrate: Int?
            let SupportsDirectPlay: Bool?
            let SupportsDirectStream: Bool?
            let TranscodingUrl: String?
            let RequiredHttpHeaders: [String: String]?
            let MediaStreams: [Stream]?

            var videoWidth: Int? { MediaStreams?.first { $0.Type == "Video" }?.Width }
        }
        struct Stream: Decodable {
            let `Type`: String?
            let Width: Int?
            let Index: Int?
            let Language: String?
            let Codec: String?
            let Title: String?
            let IsExternal: Bool?
            let IsForced: Bool?
            let IsHearingImpaired: Bool?
        }
        let MediaSources: [Source]?
        let PlaySessionId: String?
        let ErrorCode: String?
    }

    /// The server's view of how this device can play the item. The profile
    /// says "anything plays directly" (libmpv handles every common format)
    /// with HLS transcoding only as a last resort.
    func playbackInfo(_ itemId: String, startSeconds: Double?) async throws -> PlaybackInfo {
        var parts = URLComponents(url: Self.api(account.serverURL, "Items/\(itemId)/PlaybackInfo"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [
            // IsPlayback=false: just the plan, so it can be asked ahead of a tap.
            .init(name: "UserId", value: account.userId), .init(name: "IsPlayback", value: "false"),
            .init(name: "AutoOpenLiveStream", value: "false"), .init(name: "MaxStreamingBitrate", value: "200000000"),
            .init(name: "StartTimeTicks", value: String(Int64((startSeconds ?? 0) * 1e7))),
        ]
        var request = URLRequest(url: parts.url!)
        request.httpMethod = "POST"
        authorize(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["DeviceProfile": [
            "MaxStreamingBitrate": 200_000_000, "MaxStaticBitrate": 200_000_000,
            "DirectPlayProfiles": [["Type": "Video"], ["Type": "Audio"]],
            "TranscodingProfiles": [[
                "Container": "ts", "Type": "Video", "Protocol": "hls", "Context": "Streaming",
                "VideoCodec": "h264,hevc", "AudioCodec": "aac,ac3,eac3,mp3", "MaxAudioChannels": "6",
                "BreakOnNonKeyFrames": true,
            ]],
            "ContainerProfiles": [], "CodecProfiles": [],
            // Text subtitles in files beside the film too (the player adds
            // them to the film's own tracks).
            "SubtitleProfiles": [["Format": "srt", "Method": "Embed"], ["Format": "ass", "Method": "Embed"],
                                 ["Format": "subrip", "Method": "Embed"], ["Format": "pgssub", "Method": "Embed"],
                                 ["Format": "srt", "Method": "External"], ["Format": "ass", "Method": "External"],
                                 ["Format": "vtt", "Method": "External"]],
        ]])
        let info = try JSONDecoder().decode(PlaybackInfo.self, from: try await HTTP.data(request))
        if let code = info.ErrorCode { throw SourceError.unexpected("Emby can't play this (\(code)).") }
        return info
    }

    /// The episode Play starts for a show: the next unwatched one.
    func nextEpisode(of series: String) async throws -> EmbyItem? {
        try await episodeToPlay(series: series, season: nil)
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
    func report(_ event: PlaybackEvent, itemId: String, seconds: Double,
                mediaSourceId: String? = nil, playSessionId: String? = nil) async {
        guard !Self.readOnly else { return }
        var request = URLRequest(url: Self.api(account.serverURL, event.rawValue))
        request.httpMethod = "POST"
        // A slow report mustn't hold up the ones behind it (Stopped above all).
        request.timeoutInterval = 10
        authorize(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "ItemId": itemId, "PositionTicks": Int64(max(0, seconds) * 1e7),
            "PlayMethod": "DirectStream", "CanSeek": true,
            "MediaSourceId": mediaSourceId ?? itemId, "PlaySessionId": playSessionId ?? "",
        ])
        _ = try? await HTTP.data(request)
    }

    /// The film's preview thumbnails (BIF), when the server has made them
    /// (a library option); nil otherwise.
    func previewThumbnails(itemId: String, width: Int = 320) async -> Data? {
        var parts = URLComponents(url: Self.api(account.serverURL, "Videos/\(itemId)/index.bif"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "Width", value: String(width))]
        var request = URLRequest(url: parts.url!)
        request.timeoutInterval = 30
        authorize(&request)
        guard let (data, response) = try? await HTTP.ahead.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
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
        var value = "Emby UserId=\"\(userId ?? "")\", Client=\"Openreel\", Device=\"\(device)\", DeviceId=\"\(deviceId)\", Version=\"\(HTTP.appVersion)\""
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

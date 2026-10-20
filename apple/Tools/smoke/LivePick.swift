import Foundation

/// `OPENIPTV_SMOKE_MODE=live-pick`: the stream ids for the live probe's
/// rounds, picked for now from the provider's lineup. Two provider requests
/// (the live categories and the live streams); the login as live-probe takes
/// it. The "Account Info" channels go first, as XtreamProvider and AppModel
/// drop them; the rest is the app's own Live TV (LiveOrganizer, GameTime):
///
/// - up to 6 slots of games live now, both slots of a game listed twice
///   first, then one slot of each other game, in start order;
/// - the FHD and SD copies of one always-on channel: the biggest copy group
///   named with OPENIPTV_PICK_ALWAYS (a word, "ESPN" unless set), else that
///   group's best and lowest copies;
/// - the best copy of the 2 biggest other copy groups, the home region's
///   (OPENIPTV_PICK_HOME, else the Mac's, as the app takes the device's)
///   before those from abroad.
///
/// Prints `PICK live= twins= always= requests=` and the line for the shell,
/// `OPENIPTV_PROBE_IDS=<id,…>`, through `LiveProbe.say`: numbers only.
enum LivePick {
    static let slots = 6

    /// As XtreamProvider decodes them; its own types are private.
    struct Category: Decodable {
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

    struct Stream: Decodable {
        let streamId: Int64?
        let num: Int64?
        let name: String
        let epgId: String?
        let categoryId: String?
        let archiveDays: Int?
        enum CodingKeys: String, CodingKey { case stream_id, num, name, epg_channel_id, category_id, tv_archive, tv_archive_duration }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            streamId = c.flexInt(.stream_id)
            num = c.flexInt(.num)
            name = (c.flexString(.name) ?? "").trimmingCharacters(in: .whitespaces)
            epgId = c.flexString(.epg_channel_id)?.trimmingCharacters(in: .whitespaces)
            categoryId = c.flexString(.category_id)
            let days = c.flexInt(.tv_archive_duration).map(Int.init) ?? 0
            archiveDays = c.flexInt(.tv_archive) == 1 && days > 0 ? days : nil
        }
    }

    /// One player_api.php list, whole, or nil after printing why.
    static func list(_ login: LiveProbe.Login, _ action: String) async -> Data? {
        guard let url = login.api(action) else { LiveProbe.say("PICK error=other"); return nil }
        let r = await LiveProbe.read(url, agent: LiveProbe.agent(.app), cap: 120, keep: 256 << 20)
        let http = r.response?.statusCode ?? 0
        guard http == 200, r.capped == nil, r.error == nil, r.bytes == r.body.count else {
            let headers = r.response != nil || r.metrics?.transactionMetrics.last?.responseStartDate != nil
            let word = r.capped != nil ? "timeout" : r.error != nil ? LiveProbe.failure(r, headers: headers).rawValue
                : http != 200 ? "http" : "too_big"
            LiveProbe.say("PICK error=\(word) http=\(http) requests=\(LiveProbe.requests)")
            return nil
        }
        return r.body
    }

    static func run(_ env: [String: String]) async -> Int32 {
        func value(_ key: String) -> String? { LiveProbe.envValue(key, env) }
        let word = (value("OPENIPTV_PICK_ALWAYS") ?? "ESPN").lowercased()
        let region = Locale.current.region?.identifier ?? "US"
        let home = value("OPENIPTV_PICK_HOME") ?? (region == "GB" ? "UK" : region)
        guard let login = await LiveProbe.login(env) else { LiveProbe.say("PICK config no_login"); return 1 }
        LiveProbe.agents = [.app: "Openreel/\(LiveProbe.appVersion)"]
        guard let categoryData = await list(login, "get_live_categories"), let streamData = await list(login, "get_live_streams")
        else { return 1 }

        let source = UUID()
        let rawCategories = JSONDecoder().lenientList(Category.self, from: categoryData)
        let hidden = Set(rawCategories.filter { AccountInfoFilter.looksLikeAccountInfo($0.name) }.map(\.id))
        let channels = JSONDecoder().lenientList(Stream.self, from: streamData).compactMap { raw -> LiveChannel? in
            guard let id = raw.streamId,
                  !AccountInfoFilter.looksLikeAccountInfo(raw.name),
                  !AccountInfoFilter.mentions(raw.name, secrets: [login.username, login.password]),
                  raw.categoryId.map({ !hidden.contains($0) }) ?? true
            else { return nil }
            return LiveChannel(id: "\(source.uuidString)|\(id)", sourceId: source, number: raw.num, name: raw.name, logo: nil,
                               categoryId: raw.categoryId.map { "\(source.uuidString)|\($0)" }, epgId: raw.epgId,
                               nativeId: String(id), stream: .xtream(streamId: id), archiveDays: raw.archiveDays)
        }
        var counts: [String: Int] = [:]
        for c in channels { if let category = c.categoryId { counts[category, default: 0] += 1 } }
        let categories = rawCategories.compactMap { raw -> LiveCategory? in
            let id = "\(source.uuidString)|\(raw.id)"
            guard let count = counts[id], count > 0 else { return nil }
            return LiveCategory(id: id, name: raw.name, channels: count)
        }
        let (own, shown) = LiveOrganizer.withoutLogin(categories: categories, channels: channels)
        let now = Date()
        let library = LiveOrganizer.organize(categories: own, channels: shown, home: home, now: now)
        let sections = library.shelves.flatMap { shelf in shelf.sections.map { (shelf: shelf.id, section: $0) } }

        let games = sections.filter { $0.section.id == "events" }.flatMap(\.section.entries).filter {
            GameTime.state(start: $0.event?.start, league: $0.event?.league ?? "", title: $0.title, now: now) == .live
        }
        var live: [String] = []
        var twins = 0
        for game in games where game.channels.count > 1 && live.count + 2 <= slots {
            live += game.channels.prefix(2).map(\.nativeId)
            twins += 1
        }
        for game in games where live.count < slots && !live.contains(game.channels[0].nativeId) {
            live.append(game.channels[0].nativeId)
        }

        // Copy groups: the biggest first, the home region's before abroad,
        // else as Live TV lists them.
        let international = LiveOrganizer.internationalID
        let groups = sections.filter { $0.section.id != "events" }
            .flatMap { place in place.section.entries.map { (abroad: place.shelf == international, entry: $0) } }
            .enumerated().sorted { a, b in
                let (x, y) = (a.element, b.element)
                if x.abroad != y.abroad { return y.abroad }
                if x.entry.channels.count != y.entry.channels.count { return x.entry.channels.count > y.entry.channels.count }
                return a.offset < b.offset
            }.map(\.element.entry)
        func quality(_ channel: LiveChannel) -> Int { WatchOn.quality(of: channel.name).score }
        func named(_ entry: LiveOrganizer.Entry) -> Bool { LiveOrganizer.EventName.words(entry.title).contains(word) }
        let candidates = groups.filter(named)
        let chosen = candidates.first { e in e.channels.contains { quality($0) == 6 } && e.channels.contains { quality($0) == 2 } }
            ?? candidates.first { $0.channels.count > 1 } ?? candidates.first
        var always: [String] = []
        if let chosen {
            let fhd = chosen.channels.first { quality($0) == 6 }, sd = chosen.channels.first { quality($0) == 2 }
            for channel in [fhd ?? chosen.channels[0], sd ?? chosen.channels[chosen.channels.count - 1]]
            where !always.contains(channel.nativeId) && !live.contains(channel.nativeId) {
                always.append(channel.nativeId)
            }
        }
        var others = 0
        for entry in groups where others < 2 && !named(entry) {
            let id = entry.channels[0].nativeId
            guard !live.contains(id), !always.contains(id) else { continue }
            always.append(id)
            others += 1
        }

        LiveProbe.say("PICK live=\(live.count) twins=\(twins) always=\(always.count) requests=\(LiveProbe.requests)")
        LiveProbe.say("OPENIPTV_PROBE_IDS=" + (live + always).joined(separator: ","))
        return LiveProbe.refusedLines == 0 ? 0 : 2
    }
}

import Foundation

enum LivePick {
    static let slots = 6

    static func list(_ login: LiveProbe.Login, _ action: String) async -> Data? {
        let r = await LiveProbe.read(login.api(action), agent: LiveProbe.agent(.app), cap: 120, keep: 256 << 20)
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
        LiveProbe.agents = [.app: "Zapline/\(LiveProbe.appVersion)"]
        guard let categoryData = await list(login, "get_live_categories"), let streamData = await list(login, "get_live_streams")
        else { return 1 }

        let source = IPTVSource(name: "Pick", kind: .xtream(server: login.server, username: login.username, password: login.password))
        let lineup = XtreamProvider(source: source).lineup(categoryData: categoryData, channelData: streamData)
        let (own, shown) = LiveOrganizer.withoutLogin(categories: lineup.categories, channels: lineup.channels)
        let now = Date()
        let library = LiveOrganizer.organize(categories: own, channels: shown, home: home, now: now)
        let sections = library.shelves.flatMap { shelf in shelf.sections.map { Placed(shelf: shelf.id, section: $0) } }

        let (live, twins) = liveGameSlotsTwinsFirst(sections, now: now)
        let groups = copyGroupsHomeFirstBiggestFirst(sections)
        var always = fhdAndSDCopies(in: groups.filter { named($0, word) }, besides: live)
        always += bestCopies(ofFirst: 2, groups.filter { !named($0, word) }, besides: live + always)

        LiveProbe.say("PICK live=\(live.count) twins=\(twins) always=\(always.count) requests=\(LiveProbe.requests)")
        LiveProbe.say("OPENIPTV_PROBE_IDS=" + (live + always).joined(separator: ","))
        return LiveProbe.refusedLines == 0 ? 0 : 2
    }

    struct Placed {
        let shelf: String
        let section: LiveOrganizer.Section
    }

    static let fhd = 6, sd = 2

    static func quality(_ channel: LiveChannel) -> Int { WatchOn.quality(of: channel.name).score }

    static func named(_ entry: LiveOrganizer.Entry, _ word: String) -> Bool {
        LiveOrganizer.EventName.words(entry.title).contains(word)
    }

    static func liveGameSlotsTwinsFirst(_ sections: [Placed], now: Date) -> (ids: [String], twins: Int) {
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
        return (live, twins)
    }

    static func copyGroupsHomeFirstBiggestFirst(_ sections: [Placed]) -> [LiveOrganizer.Entry] {
        let international = LiveOrganizer.internationalID
        return sections.filter { $0.section.id != "events" }
            .flatMap { place in place.section.entries.map { (abroad: place.shelf == international, entry: $0) } }
            .enumerated().sorted { a, b in
                let (x, y) = (a.element, b.element)
                if x.abroad != y.abroad { return y.abroad }
                if x.entry.channels.count != y.entry.channels.count { return x.entry.channels.count > y.entry.channels.count }
                return a.offset < b.offset
            }.map(\.element.entry)
    }

    static func fhdAndSDCopies(in candidates: [LiveOrganizer.Entry], besides live: [String]) -> [String] {
        let chosen = candidates.first { e in e.channels.contains { quality($0) == fhd } && e.channels.contains { quality($0) == sd } }
            ?? candidates.first { $0.channels.count > 1 } ?? candidates.first
        guard let chosen else { return [] }
        let fhdCopy = chosen.channels.first { quality($0) == fhd } ?? chosen.channels[0]
        let sdCopy = chosen.channels.first { quality($0) == sd } ?? chosen.channels[chosen.channels.count - 1]
        var picked: [String] = []
        for channel in [fhdCopy, sdCopy] where !picked.contains(channel.nativeId) && !live.contains(channel.nativeId) {
            picked.append(channel.nativeId)
        }
        return picked
    }

    static func bestCopies(ofFirst count: Int, _ groups: [LiveOrganizer.Entry], besides taken: [String]) -> [String] {
        var picked: [String] = []
        for entry in groups where picked.count < count {
            let id = entry.channels[0].nativeId
            guard !taken.contains(id), !picked.contains(id) else { continue }
            picked.append(id)
        }
        return picked
    }
}

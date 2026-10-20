import Foundation

/// Live TV by what you'd want to watch rather than by the provider's
/// categories (one large provider has 245: "US | Local ABC", "NCAAB (2)",
/// "24/7 Netflix", "Sports | DE Sports"…, and 16,000 channels with TLC
/// listed 14 times).
///
/// - Shelves: Sports, News, Entertainment, Movies, Kids, 24/7, Music, Radio,
///   International (by country) and More, from the categories' names. Local
///   stations stay with the area set in Settings.
/// - One entry per channel: the copies of a channel (HD, FHD, SD, low
///   bandwidth, other categories) become one row that plays the best copy
///   and falls back to the others.
/// - Sports events are read from the event channels' names ("NFL 01:
///   Eagles vs. Jaguars (10.11 9:30 AM ET)", "Paramount+ 02: Serie A: Como
///   vs. Roma @ 11 Oct 06:20 AM ET", "(Apple) (MLS) 001 | St. Louis vs. LA
///   (2026-10-11 18:25:00)"): title, league and start time, empty slots
///   ("NO EVENT", "MiLB 02:") dropped, the same game from several services
///   merged.
/// - Never shown: adult categories, and the "Account Info" channels some
///   providers use to show the login (see `withoutLogin`).
///
/// Pure and quick (16,000 channels in well under a second), run off the main
/// thread whenever the lineup changes.
enum LiveOrganizer {
    struct Shelf: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        var sections: [Section]
    }

    struct Section: Identifiable, Hashable, Sendable {
        let id: String
        let title: String
        /// International: the country this section belongs to.
        var country: String? = nil
        var entries: [Entry]
    }

    struct Entry: Identifiable, Hashable, Sendable {
        let title: String
        var channels: [LiveChannel]
        var event: Event? = nil

        var id: String { channels[0].id }
        var logo: URL? { channels.lazy.compactMap(\.logo).first }
    }

    struct Event: Hashable, Sendable {
        let league: String
        let start: Date?
        /// The network or feed ("ESPN2", "Sharks Broadcast").
        let detail: String?
    }

    struct Library: Sendable {
        var shelves: [Shelf] = []
        /// Every copy of each channel, best first (for falling back).
        var copies: [String: [LiveChannel]] = [:]
        /// For channels without a guide id: a copy that has one.
        var guideAlias: [String: LiveChannel] = [:]
        /// Categories listing events, refreshed when Sports opens.
        var eventCategories: [String] = []
        /// Each channel's tidy title, and its game if it's one (for the
        /// player).
        var titles: [String: String] = [:]
        var events: [String: Event] = [:]
        /// Each game channel's own service, feed and language ("Watch On").
        var feeds: [String: WatchOn.Feed] = [:]
    }

    static let sportsID = "shelf:sports"
    static let internationalID = "shelf:international"

    /// Leagues and sports first in the Sports filters, in this order; the
    /// "Top" filter shows these.
    static let featuredLeagues = [
        "NFL", "College Football", "NBA", "WNBA", "College Basketball", "Women's College Basketball", "NHL", "MLB",
        "MLS", "Premier League", "UEFA", "La Liga", "Serie A", "Bundesliga", "Ligue 1", "EFL", "SPFL", "Soccer",
        "UFC", "Boxing", "Wrestling", "Formula 1", "NASCAR", "IndyCar", "Motorsport", "Tennis", "Golf", "Cricket",
        "Rugby", "Darts", "Snooker & Pool", "PPV",
    ]

    // MARK: Logins listed as channels

    /// A lineup without the categories and channels some providers use to
    /// show the account (name, expiry and the password itself), so they're
    /// never shown or saved.
    static func withoutLogin(categories: [LiveCategory], channels: [LiveChannel]) -> ([LiveCategory], [LiveChannel]) {
        let hidden = Set(categories.filter { isAccountInfo($0.name) }.map(\.id))
        guard !hidden.isEmpty || channels.contains(where: { leaksLogin($0.name) }) else { return (categories, channels) }
        return (categories.filter { !hidden.contains($0.id) },
                channels.filter { !hidden.contains($0.categoryId ?? "") && !leaksLogin($0.name) })
    }

    static func isAccountInfo(_ category: String) -> Bool {
        let lower = category.lowercased()
        return lower.contains("account info") || lower.contains("account details") || lower == "account"
    }

    static func leaksLogin(_ name: String) -> Bool {
        name.range(of: #"pass\s?word|user\s?name|your account"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: Organising

    static func organize(categories: [LiveCategory], channels: [LiveChannel], home: String, now: Date = Date()) -> Library {
        let home = region(home) ?? "US"
        var byCategory: [String: [LiveChannel]] = [:]
        for channel in channels { byCategory[channel.categoryId ?? "", default: []].append(channel) }

        var shelves = ShelfSet()
        var events: [Entry] = []
        var eventCategories: [String] = []
        var feeds: [String: WatchOn.Feed] = [:]
        /// Low-bandwidth copies, kept to fall back to: region → name key.
        var spare: [String: [String: [LiveChannel]]] = [:]

        for category in categories {
            let kind = Kind(category.name, home: home)
            // Local stations are the Local tab's (by the area in Settings).
            guard ![.adult, .hidden, .local].contains(kind.topic), let members = byCategory[category.id], !members.isEmpty else { continue }
            let place = kind.region ?? home
            if kind.lowBandwidth {
                for channel in members { spare[place, default: [:]][Name(channel.name).key, default: []].append(channel) }
                continue
            }

            // Categories that list events ("NFL 01: …", "PEACOCK SPORTS 003:
            // …"): the events go to Sports, whatever the region.
            var rest = members
            if ![.nonstop, .radio, .music, .kids].contains(kind.topic), !kind.isTeams, !kind.isReplays {
                var listed: [Entry] = []
                var slots = 0
                rest = []
                for channel in members {
                    switch EventName.parse(channel.name, kind: kind, now: now) {
                    case let .event(entry):
                        listed.append(Entry(title: entry.title, channels: [channel], event: entry.event))
                        let language = entry.language ?? WatchOn.language(in: channel.name) ?? WatchOn.language(in: category.name)
                            ?? WatchOn.language(ofRegion: kind.region)
                        feeds[channel.id] = WatchOn.Feed(service: kind.label, detail: entry.event.detail, language: language)
                    case .emptySlot:
                        slots += 1
                    case .none:
                        rest.append(channel)
                    }
                }
                if !listed.isEmpty || slots > 0 {
                    eventCategories.append(category.id)
                    events += listed
                    // In an event list, what's left are its fixed channels
                    // (NFL RedZone, NFL Network) or unnamed slots.
                    rest = rest.filter { !EventName.isBareSlot($0.name) }
                }
                if rest.isEmpty { continue }
            }

            let (shelf, section) = kind.placement(home: home)
            let country = kind.region.flatMap { $0 == home ? nil : $0 }
            shelves.add(rest, shelf: shelf, section: section, country: shelf == internationalID ? country : nil,
                        spareRegion: place)
        }

        // Fall back to low-bandwidth copies of the same channel.
        shelves.attachSpares(spare)

        var library = Library()
        library.eventCategories = eventCategories
        library.feeds = feeds
        let sportsEvents = mergeEvents(events, now: now)
        library.shelves = shelves.build(events: sportsEvents)
        for shelf in library.shelves {
            for section in shelf.sections {
                for entry in section.entries {
                    for channel in entry.channels {
                        library.titles[channel.id] = entry.title
                        if let event = entry.event { library.events[channel.id] = event }
                    }
                    guard entry.channels.count > 1 else { continue }
                    for channel in entry.channels { library.copies[channel.id] = entry.channels }
                    if let guided = entry.channels.first(where: { $0.epgId != nil }) {
                        for channel in entry.channels where channel.epgId == nil { library.guideAlias[channel.id] = guided }
                    }
                }
            }
        }
        return library
    }

    // MARK: Shelves

    enum Topic: String, CaseIterable {
        case sports, local, news, entertainment, movies, kids, nonstop, music, radio, documentary, faith, ambiance, other, adult, hidden
    }

    static let shelfOrder: [(id: String, title: String)] = [
        (sportsID, "Sports"), ("shelf:news", "News"), ("shelf:entertainment", "Entertainment"),
        ("shelf:movies", "Movies"), ("shelf:kids", "Kids"), ("shelf:nonstop", "24/7"), ("shelf:music", "Music"),
        ("shelf:radio", "Radio"), (internationalID, "International"), ("shelf:more", "More"),
    ]

    /// What a category is, from its name ("US | Local ABC", "24/7 Kids",
    /// "DAZN UK (2)", "Germany | Sports").
    struct Kind {
        var region: String?
        var topic: Topic
        /// The category's own name without region or "(2)": a section title.
        var label: String
        var lowBandwidth = false
        /// The league its events or teams belong to, if it says.
        var league: String?
        var isTeams = false
        var isReplays = false

        init(_ name: String, home: String) {
            var text = name.trimmingCharacters(in: .whitespaces)
            // "(2)", "(Test)", "(HEVC)": a second list of the same thing.
            text = text.replacingOccurrences(of: #"\s*\((\d+|test|hevc|lbw)\)\s*$"#, with: "",
                                             options: [.regularExpression, .caseInsensitive])
            let upper = name.uppercased()
            lowBandwidth = upper.contains("LOW BANDWIDTH") || upper.contains("(LBW)") || upper.hasPrefix("LBW")
            let parts = text.split(separator: "|", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, let code = LiveOrganizer.region(parts[0]) {
                region = code
                text = parts[1]
            } else if parts.count == 2, ["sports", "sport"].contains(parts[0].lowercased()) {
                // "Sports | DE Sports"
                text = parts[1]
            } else if parts.count == 2 {
                // "Radio | Sirius XM", "OnePlay | Netflix Series", "PPV Events | 1"
                text = parts[1].allSatisfy(\.isNumber) ? parts[0] : "\(parts[0]) · \(parts[1])"
            }
            // "DAZN UK", "HBO Max US", "DE Sports": a code at either end.
            if region == nil {
                let words = text.split(separator: " ").map(String.init)
                if words.count > 1, let last = words.last, last.count <= 3, last == last.uppercased(), let code = LiveOrganizer.region(last) {
                    region = code
                } else if words.count > 1, let first = words.first, first.count <= 3, first == first.uppercased(),
                          let code = LiveOrganizer.region(first) {
                    region = code
                }
            }
            label = text.replacingOccurrences(of: " / ", with: " · ")
            topic = Self.topic(of: text, whole: name)
            league = LiveOrganizer.league(in: text)
            let lower = text.lowercased()
            isTeams = lower.hasSuffix("teams")
            isReplays = lower.contains("replay")
        }

        private static func topic(of text: String, whole: String) -> Topic {
            let lower = text.lowercased(), wholeLower = whole.lowercased()
            let words = Set(lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            // Short keys as whole words ("epl" isn't in "OnePlay").
            func has(_ keys: [String]) -> Bool { keys.contains { $0.count <= 4 ? words.contains($0) : lower.contains($0) } }
            if wholeLower.contains("adult") || has(["xxx", "18+", "for adults"]) { return .adult }
            if LiveOrganizer.isAccountInfo(whole) { return .hidden }
            if has(["local"]) { return .local }
            if has(["radio", "sirius"]) { return .radio }
            if has(["ambiance", "ambience", "lofi", "relax"]) { return .ambiance }
            if has(["news"]) { return .news }
            if has(["kids", "kid's", "children", "cartoon", "toddler", "junior"]) { return .kids }
            if has(["music", "mtv", "vevo"]) { return .music }
            if wholeLower.hasPrefix("24/7") || has(["24/7"]) { return .nonstop }
            if has(["religion", "faith", "christian", "church", "gospel"]) { return .faith }
            if has(["documentar", "factual", "nature", "science", "history"]) { return .documentary }
            if has(["movie", "cinema", "cine", "film", "premiere", "estrenos"]) { return .movies }
            if has(["sport", "deportes", "espn", "dazn", "ppv", "event", "replay", "teams", "flosports", "flow rush", "kayo",
                    "fight", "ufc", "boxing", "wrestling", "darts", "snooker", "tennis", "golf", "racing", "f1", "formula",
                    "nascar", "soccer", "football", "league", "liga", "ligue", "serie a", "bundesliga", "uefa", "fifa",
                    "epl", "efl", "spfl", "mls", "nfl", "nba", "wnba", "nhl", "mlb", "milb", "ncaa", "ncaab", "ncaaf",
                    "chl", "ohl", "whl", "qmjhl", "triller", "victory+", "tsn", "sportsnet", "sec", "big ten",
                    "fanatiz", "setanta", "stan", "viaplay", "tv2 play", "starhub", "nowhk", "monomax", "coupang",
                    "superleague", "dirtvision", "astro", "hub", "4k", "uhd"])
                || LiveOrganizer.league(in: text) != nil {
                return .sports
            }
            if has(["entertainment", "general", "tv", "television", "regional", "sky", "variety", "reality",
                    "comedy", "drama", "series", "original", "asian", "french", "america", "famosos", "mix", "play"]) {
                return .entertainment
            }
            return .other
        }

        /// Which shelf and section this category's channels go to.
        func placement(home: String) -> (shelf: String, section: String) {
            let abroad = region != nil && region != home
            if abroad, topic != .sports || league == nil {
                // Everything from elsewhere sits under its country, by topic.
                return (internationalID, label)
            }
            switch topic {
            case .sports:
                if isTeams { return (sportsID, "teams:" + (league ?? label)) }
                if isReplays { return (sportsID, "replays") }
                return (sportsID, "channels:" + label)
            case .news: return ("shelf:news", label)
            case .entertainment, .documentary: return ("shelf:entertainment", label)
            case .movies: return ("shelf:movies", label)
            case .kids: return ("shelf:kids", label)
            case .nonstop: return ("shelf:nonstop", label)
            case .music: return ("shelf:music", label)
            case .radio: return ("shelf:radio", label)
            case .faith, .ambiance, .other, .adult, .hidden, .local: return ("shelf:more", label)
            }
        }
    }

    /// Shelves being filled: sections in the order first seen, each channel
    /// once per shelf (its copies merged into one entry).
    private struct ShelfSet {
        struct Building {
            var sections: [(id: String, title: String, country: String?, entries: [Entry])] = []
            var sectionIndex: [String: Int] = [:]
            /// Name key (with country) → (section, entry).
            var entryIndex: [String: (Int, Int)] = [:]
            /// Entries by the region whose low-bandwidth copies they take.
            var regionOf: [String: String] = [:]
        }

        var shelves: [String: Building] = [:]

        mutating func add(_ channels: [LiveChannel], shelf: String, section: String, country: String?, spareRegion: String) {
            var building = shelves[shelf] ?? Building()
            let sectionKey = (country ?? "") + "|" + section
            let s: Int
            if let known = building.sectionIndex[sectionKey] {
                s = known
            } else {
                s = building.sections.count
                building.sections.append((sectionKey, section, country, []))
                building.sectionIndex[sectionKey] = s
            }
            for channel in channels {
                let name = Name(channel.name)
                guard !name.key.isEmpty else { continue }
                let key = (country ?? "") + "|" + name.key
                if let (es, ei) = building.entryIndex[key] {
                    building.sections[es].entries[ei].channels.append(channel)
                } else {
                    building.entryIndex[key] = (s, building.sections[s].entries.count)
                    building.sections[s].entries.append(Entry(title: name.display, channels: [channel]))
                    building.regionOf[key] = spareRegion
                }
            }
            shelves[shelf] = building
        }

        mutating func attachSpares(_ spare: [String: [String: [LiveChannel]]]) {
            for (shelfID, var building) in shelves {
                for (key, (s, e)) in building.entryIndex {
                    guard let region = building.regionOf[key],
                          let copies = spare[region]?[String(key.split(separator: "|", maxSplits: 1).last ?? "")] else { continue }
                    building.sections[s].entries[e].channels += copies
                }
                shelves[shelfID] = building
            }
        }

        func build(events: [Entry]) -> [Shelf] {
            var result: [Shelf] = []
            for (id, title) in LiveOrganizer.shelfOrder {
                var sections: [Section] = []
                if id == LiveOrganizer.sportsID, !events.isEmpty {
                    sections.append(Section(id: "events", title: "Events", entries: events))
                }
                if let building = shelves[id] {
                    var built = building.sections.map { raw in
                        Section(id: raw.id, title: Self.sectionTitle(raw.title, shelf: id), country: raw.country,
                                entries: raw.entries.map { entry in
                                    var entry = entry
                                    entry.channels = LiveOrganizer.bestFirst(entry.channels)
                                    return entry
                                })
                    }.filter { !$0.entries.isEmpty }
                    if id == LiveOrganizer.internationalID {
                        built.sort { (LiveOrganizer.countryName($0.country ?? ""), $0.title) < (LiveOrganizer.countryName($1.country ?? ""), $1.title) }
                    }
                    sections += built
                }
                if !sections.isEmpty { result.append(Shelf(id: id, title: title, sections: sections)) }
            }
            return result
        }

        private static func sectionTitle(_ raw: String, shelf: String) -> String {
            if shelf == LiveOrganizer.sportsID {
                if raw == "channels:Sports" { return "Sports channels" }
                if raw.hasPrefix("channels:") { return String(raw.dropFirst(9)) }
                if raw == "replays" { return "Replays" }
                if raw.hasPrefix("teams:") { return String(raw.dropFirst(6)) + " teams" }
            }
            var title = raw
            if shelf == "shelf:nonstop", title.lowercased().hasPrefix("24/7") {
                title = String(title.dropFirst(4)).trimmingCharacters(in: .whitespaces)
            }
            return title.isEmpty ? raw : title
        }
    }

    // MARK: Channel names and copies

    /// A channel's name without the provider's decoration ("US: TLC HD",
    /// "UK◈ Sky One ᴴᴰ", "LBW: A&E"), and a key that's the same for every
    /// copy ("ESPN 2" and "ESPN2 FHD" → "espn2").
    struct Name {
        let display: String
        let key: String

        private static let symbols = try! NSRegularExpression(pattern: "[\\x{1D00}-\\x{1DBF}\\x{2070}-\\x{209F}◈▼▲•●★☆✪◉►◄|]+")
        private static let prefix = try! NSRegularExpression(
            pattern: #"^\s*(?:\(?[A-Z]{2,4}\)?\s*[:|◈]\s*|\([A-Z]{2,4}\)\s+|LBW\s*[:|-]\s*|Radio\s*:\s*)+"#)
        private static let tags = try! NSRegularExpression(
            pattern: #"[\[(]?\b(?:F?HD|UHD|SD|[48]K|2160P?|1080[PI]?|720P?|HEVC|H\.?26[45]|RAW|VIP|BACKUP|HDR|[56]0\s?FPS|EAST|LBW)\b[\])]?"#,
            options: [.caseInsensitive])
        private static let emptyBrackets = try! NSRegularExpression(pattern: #"\(\s*\)|\[\s*\]"#)

        init(_ raw: String) {
            var text = raw
            func strip(_ regex: NSRegularExpression, with replacement: String = " ") {
                text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
            }
            strip(Self.prefix, with: "")
            strip(Self.symbols)
            strip(Self.tags)
            strip(Self.emptyBrackets)
            text = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                .trimmingCharacters(in: CharacterSet(charactersIn: " -:|·"))
            if text.isEmpty { text = raw.trimmingCharacters(in: .whitespaces) }
            text = text.replacingOccurrences(of: #"\bWEST\b"#, with: "West", options: .regularExpression)
            display = LiveOrganizer.tidyCase(text)
            key = String(display.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
        }
    }

    /// The copy to play first: the fuller picture, then one with a guide,
    /// then one that records; low-bandwidth and backups last.
    static func bestFirst(_ channels: [LiveChannel]) -> [LiveChannel] {
        guard channels.count > 1 else { return channels }
        func score(_ channel: LiveChannel) -> Int {
            WatchOn.quality(of: channel.name).score * 10 + (channel.epgId != nil ? 2 : 0) + (channel.archiveDays != nil ? 1 : 0)
        }
        return channels.enumerated().sorted { a, b in
            let sa = score(a.element), sb = score(b.element)
            return sa != sb ? sa > sb : a.offset < b.offset
        }.map(\.element)
    }

    /// "DISCOVERY CHANNEL" → "Discovery Channel"; names already in mixed case,
    /// and abbreviations (CNN, HGTV, ESPN2), are left alone.
    static func tidyCase(_ text: String) -> String {
        let letters = text.filter(\.isLetter)
        guard letters == letters.uppercased(),
              text.split(separator: " ").contains(where: { $0.filter(\.isLetter).count >= 6 }) else { return text }
        let small: Set<String> = ["at", "vs", "vs.", "v", "of", "the", "and", "on", "in", "de", "la", "el", "y"]
        let keep: Set<String> = ["ABC", "AMC", "BBC", "BET", "CBS", "CNN", "ESPN", "FOX", "HBO", "HGTV", "ITV", "MTV", "NBC",
                                 "PBS", "TLC", "TNT", "TBS", "USA", "UFC", "NFL", "NBA", "NHL", "MLB", "MLS", "WWE", "SEC",
                                 "ACC", "BYU", "UCF", "UCLA", "USC", "LSU", "SMU", "TCU", "UNC", "NC", "TV", "FC", "AFC",
                                 "CF", "A&M", "ID", "DIY", "QVC", "HSN", "OWN", "IFC", "TCM", "CMT", "VH1", "A&E", "NASA",
                                 "CNBC", "MSNBC", "CSPAN", "C-SPAN", "EWTN", "TBN", "NHK", "DW", "RT", "CGTN", "CBC", "CTV",
                                 "TSN", "RDS", "SNY", "YES", "MSG", "NESN", "BTN", "FS1", "FS2", "ESPNU", "WNBA", "PGA", "LPGA",
                                 "DAZN", "ESPNEWS", "NCAA", "NASCAR", "UEFA", "FIFA", "WWE", "AEW", "TNA", "BKFC", "PFL"]
        let words = text.split(separator: " ", omittingEmptySubsequences: true).enumerated().map { index, word -> String in
            let w = String(word)
            if keep.contains(w) || w.contains(where: \.isNumber) || !w.contains(where: { "AEIOUY".contains($0) })
                || (w.count <= 3 && !small.contains(w.lowercased())) { return w }
            if index > 0, small.contains(w.lowercased()) { return w.lowercased() }
            return w.prefix(1) + w.dropFirst().lowercased()
        }
        return words.joined(separator: " ")
    }

    // MARK: Events

    enum EventName {
        case event(Entry)
        /// "NBA 02:", "MiLB 01: NO EVENT", "NFL GP 02 | Offline".
        case emptySlot
        case none

        struct Entry {
            let title: String
            let event: Event
            /// The commentary's language when the name says ("(ESP)").
            var language: String? = nil
        }

        /// "NFL 01: ", "MLB 01 | ", "(FLSP 001) | ", "(UK) Dazn  01: ",
        /// "NFL Multi Screen / HDR 01: ", "Soccer01: ", "EPL04:".
        private static let slotPrefix = try! NSRegularExpression(
            pattern: #"^\s*(?:\([^)]{1,16}\)\s*)*[^:|ⓧ]{0,34}?\d{1,4}\)?\s*(?:[:|ⓧ]+|(?<=EVENT \d{1,4})\s-|(?<=Event \d{1,4})\s-)\s*"#)
        private static let placeholder = try! NSRegularExpression(
            pattern: #"^\W*(no (scheduled )?events?( scheduled)?|offline|tba|tbd|coming soon|stand ?by|no game|not live|off ?air|event \d+)\W*$"#,
            options: [.caseInsensitive])
        private static let ukFixture = try! NSRegularExpression(
            pattern: #"^(.+?)\s(\d{1,2}):(\d{2})\s(.+?)\s(\d{1,2})/(\d{1,2})$"#)
        private static let bare = try! NSRegularExpression(pattern: #"^\s*\[?[A-Za-z+.() /-]{1,30}\s\d{1,4}\]?\s*:?\s*$"#)

        private static let sports: [String: String] = [
            "fc": "Soccer", "soccer": "Soccer", "football": "Soccer", "vb": "Volleyball", "volleyball": "Volleyball",
            "bb": "Basketball", "basketball": "Basketball", "hockey": "Hockey", "baseball": "Baseball", "softball": "Softball",
            "grappling": "Grappling", "wrestling": "Wrestling", "track": "Track & Field", "xc": "Track & Field",
            "lacrosse": "Lacrosse", "rugby": "Rugby", "cricket": "Cricket", "tennis": "Tennis", "golf": "Golf",
            "racing": "Motorsport", "rodeo": "Rodeo", "cycling": "Cycling", "swimming": "Swimming", "gymnastics": "Gymnastics",
        ]

        static func words(_ text: String) -> Set<String> {
            Set(text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        }

        /// A channel that's only a numbered slot ("NBA 02", "EVENT 05").
        static func isBareSlot(_ name: String) -> Bool {
            bare.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
                || name.range(of: "no event", options: .caseInsensitive) != nil
        }

        static func parse(_ raw: String, kind: Kind, now: Date) -> EventName {
            let name = raw.trimmingCharacters(in: .whitespaces)
            let range = NSRange(name.startIndex..., in: name)
            guard let prefix = slotPrefix.firstMatch(in: name, range: range), let cut = Range(prefix.range, in: name) else {
                return name.range(of: "no event", options: .caseInsensitive) != nil ? .emptySlot : .none
            }
            var rest = String(name[cut.upperBound...]).trimmingCharacters(in: .whitespaces)
            rest = rest.trimmingCharacters(in: CharacterSet(charactersIn: " :"))
            // A sport named before the title: "grappling:  UIJJ Cup", "fc:", "live:".
            var sport: String?
            var label: String?
            if let colon = rest.firstIndex(of: ":"), rest.distance(from: rest.startIndex, to: colon) <= 14 {
                let head = rest[..<colon].trimmingCharacters(in: .whitespaces)
                if !head.isEmpty, head == head.lowercased(), head.allSatisfy({ $0.isLetter || $0 == " " }) {
                    if let known = Self.sports[head] { sport = known } else if head != "live" { label = head }
                    rest = String(rest[rest.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                }
            }
            if let match = Self.ukFixture.firstMatch(in: rest, range: NSRange(rest.startIndex..., in: rest)),
               let home = Range(match.range(at: 1), in: rest), let hour = Range(match.range(at: 2), in: rest),
               let minute = Range(match.range(at: 3), in: rest), let away = Range(match.range(at: 4), in: rest),
               let day = Range(match.range(at: 5), in: rest), let month = Range(match.range(at: 6), in: rest),
               let monthNumber = Int(rest[month]), (1...12).contains(monthNumber) {
                let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
                rest = "\(rest[home]) vs \(rest[away]) @ \(rest[day]) \(months[monthNumber - 1]) \(rest[hour]):\(rest[minute]) London"
            }
            let (start, withoutTime) = EventTime.extract(from: rest, region: kind.region, now: now)
            // "(ESP)", "(In French)": the feed's language, not the game's
            // name (the same game in two languages is one game).
            let (withoutLanguage, language) = WatchOn.withoutLanguage(withoutTime)
            rest = withoutLanguage
            // Title, then a network or feed after "|".
            var pieces = rest.split(separator: "|").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " @-–_")) }
                .filter { !$0.isEmpty }
            if pieces.count > 1, isBareSlot(pieces[0]) || pieces[0].range(of: #"^\S+\s?\d{1,4}$"#, options: .regularExpression) != nil {
                pieces.removeFirst()
            }
            var title = pieces.first ?? ""
            var detail = pieces.count > 1 ? pieces.dropFirst().joined(separator: " · ") : label
            title = title.replacingOccurrences(of: " _ ", with: " · ").replacingOccurrences(of: "`", with: "’")
                .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: " @-–_:·•●◈▼▲★"))
            // "( OneSoccer Feed )" → a detail.
            if detail == nil, let open = title.lastIndex(of: "("), title.hasSuffix(")") {
                let inside = title[title.index(after: open)..<title.index(before: title.endIndex)].trimmingCharacters(in: .whitespaces)
                if inside.lowercased().contains("feed") || inside.lowercased().contains("broadcast") || inside.lowercased().contains("in-arena") {
                    detail = inside
                    title = title[..<open].trimmingCharacters(in: .whitespaces)
                }
            }
            // "Chicago Marathon (Chicago Marathon)": the repeat goes.
            if let open = title.lastIndex(of: "("), title.hasSuffix(")"), open > title.startIndex {
                let inside = Self.words(String(title[open...]))
                if !inside.isEmpty, inside.isSubset(of: Self.words(String(title[..<open]))) {
                    title = title[..<open].trimmingCharacters(in: .whitespaces)
                }
            }
            let titleRange = NSRange(title.startIndex..., in: title)
            if title.isEmpty || placeholder.firstMatch(in: title, range: titleRange) != nil { return .emptySlot }
            // Far-future dates mark unused slots ("(2098-12-31 08:00:01)").
            if let start, start.timeIntervalSince(now) > 60 * 86400 { return .emptySlot }
            // Long finished.
            if let start, now.timeIntervalSince(start) > 8 * 3600 { return .emptySlot }
            let league = kind.league ?? LiveOrganizer.league(in: title) ?? sport ?? LiveOrganizer.serviceName(kind.label)
            return .event(Entry(title: LiveOrganizer.tidyCase(title), event: Event(league: league, start: start, detail: detail),
                                language: language))
        }
    }

    /// Start times in the forms event channels use, read in the zone they
    /// name (ET when they don't, London for UK lists, Sydney for Australian).
    /// Date stamps ("(2026-10-17 12:00:05)") name none: the provider's own
    /// Eastern time. Regression: read as UTC, noon games were LIVE from 8 AM
    /// (Mississippi State vs. LSU, kickoff noon ET) and didn't play, and
    /// didn't merge with the same game listed "12:00 PM ET" elsewhere.
    enum EventTime {
        private static let zone = #"(?:\s*(ET|EST|EDT|CT|CST|CDT|MT|MST|MDT|PT|PST|PDT|UK|London|BST|GMT|UTC|CET|CEST|AEST|AEDT))?"#
        private static let month = #"(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?"#
        private static let clock = #"(\d{1,2})[:.](\d{2})\s*([ap]\.?m\.?)?"#
        private static let isoPattern: String = #"\(?\s*(\d{4})-(\d{2})-(\d{2})[ T](\d{1,2}):(\d{2})(?::\d{2})?\s*\)?"#
        private static let dayMonthPattern: String = [#"\(?@?\s*(\d{1,2})\s+"#, month, #"\s+"#, clock, zone, #"\s*\)?"#].joined()
        private static let monthDayPattern: String = [#"\(?@?\s*"#, month, #"\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+"#, clock, zone, #"\s*\)?"#].joined()
        private static let dottedPattern: String = [#"\(?\s*(\d{1,2})[./](\d{1,2})\s+"#, clock, zone, #"\s*\)?"#].joined()
        private static let timeOnlyPattern: String = [#"@\s*"#, clock, zone, #"\s*$"#].joined()
        private static let leadingPattern: String = [#"^\s*(\d{1,2})(?::(\d{2}))?\s*([ap]m)\b"#, zone].joined()
        private static let patterns: [(NSRegularExpression, Form)] = {
            let forms: [(String, Form)] = [(isoPattern, .iso), (dayMonthPattern, .dayMonth), (monthDayPattern, .monthDay),
                                           (dottedPattern, .dotted), (timeOnlyPattern, .timeOnly), (leadingPattern, .leading)]
            return forms.map { (try! NSRegularExpression(pattern: $0.0, options: [.caseInsensitive]), $0.1) }
        }()

        private enum Form { case iso, dayMonth, monthDay, dotted, timeOnly, leading }

        static func extract(from text: String, region: String?, now: Date) -> (Date?, String) {
            let range = NSRange(text.startIndex..., in: text)
            for (regex, form) in patterns {
                guard let match = regex.firstMatch(in: text, range: range), let whole = Range(match.range, in: text) else { continue }
                func group(_ i: Int) -> String? {
                    guard i < match.numberOfRanges, let r = Range(match.range(at: i), in: text) else { return nil }
                    return String(text[r])
                }
                var parts = DateComponents()
                var zoneName: String?
                var meridiem: String?
                switch form {
                case .iso:
                    parts.year = group(1).flatMap(Int.init); parts.month = group(2).flatMap(Int.init)
                    parts.day = group(3).flatMap(Int.init); parts.hour = group(4).flatMap(Int.init); parts.minute = group(5).flatMap(Int.init)
                case .dayMonth:
                    parts.day = group(1).flatMap(Int.init); parts.month = monthNumber(group(2))
                    parts.hour = group(3).flatMap(Int.init); parts.minute = group(4).flatMap(Int.init)
                    meridiem = group(5); zoneName = group(6)
                case .monthDay:
                    parts.month = monthNumber(group(1)); parts.day = group(2).flatMap(Int.init)
                    parts.hour = group(3).flatMap(Int.init); parts.minute = group(4).flatMap(Int.init)
                    meridiem = group(5); zoneName = group(6)
                case .dotted:
                    parts.month = group(1).flatMap(Int.init); parts.day = group(2).flatMap(Int.init)
                    parts.hour = group(3).flatMap(Int.init); parts.minute = group(4).flatMap(Int.init)
                    meridiem = group(5); zoneName = group(6)
                case .timeOnly:
                    parts.hour = group(1).flatMap(Int.init); parts.minute = group(2).flatMap(Int.init)
                    meridiem = group(3); zoneName = group(4)
                case .leading:
                    parts.hour = group(1).flatMap(Int.init); parts.minute = group(2).flatMap(Int.init) ?? 0
                    meridiem = group(3); zoneName = group(4)
                }
                guard let hour = parts.hour, hour < 24, let minute = parts.minute, minute < 60 else { continue }
                if let meridiem = meridiem?.lowercased().replacingOccurrences(of: ".", with: "") {
                    if meridiem == "pm", hour < 12 { parts.hour = hour + 12 }
                    if meridiem == "am", hour == 12 { parts.hour = 0 }
                }
                if form == .dotted, (parts.month ?? 13) > 12 || (parts.day ?? 32) > 31 { continue }
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = timeZone(zoneName, region: region)
                let today = calendar.dateComponents([.year, .month, .day], from: now)
                if parts.year == nil { parts.year = today.year }
                if parts.month == nil { parts.month = today.month; parts.day = today.day }
                guard var date = calendar.date(from: parts) else { continue }
                // No year given: the nearest one (a December list read in January).
                if form != .iso {
                    if date.timeIntervalSince(now) > 180 * 86400, let earlier = calendar.date(byAdding: .year, value: -1, to: date) { date = earlier }
                    if now.timeIntervalSince(date) > 180 * 86400, let later = calendar.date(byAdding: .year, value: 1, to: date) { date = later }
                }
                var rest = text
                rest.removeSubrange(whole)
                return (date, rest)
            }
            return (nil, text)
        }

        private static func monthNumber(_ text: String?) -> Int? {
            guard let text = text?.lowercased().prefix(3) else { return nil }
            return ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"].firstIndex(of: String(text)).map { $0 + 1 }
        }

        private static func timeZone(_ name: String?, region: String?) -> TimeZone {
            let id: String
            switch name?.uppercased() {
            case "ET", "EST", "EDT": id = "America/New_York"
            case "CT", "CST", "CDT": id = "America/Chicago"
            case "MT", "MST", "MDT": id = "America/Denver"
            case "PT", "PST", "PDT": id = "America/Los_Angeles"
            case "UK", "LONDON", "BST", "GMT": id = "Europe/London"
            case "UTC": id = "UTC"
            case "CET", "CEST": id = "Europe/Paris"
            case "AEST", "AEDT": id = "Australia/Sydney"
            default:
                switch region {
                case "UK", "IE": id = "Europe/London"
                case "AU": id = "Australia/Sydney"
                default: id = "America/New_York"
                }
            }
            return TimeZone(identifier: id) ?? .current
        }
    }

    /// The same game listed by several services or twice by one (NHL and
    /// NHL (2); a feed in SD): one entry, its copies to fall back to. Then
    /// in start order.
    static func mergeEvents(_ events: [Entry], now: Date) -> [Entry] {
        let skip: Set<String> = ["vs", "at", "the", "and", "feed", "broadcast", "live", "game", "match", "of", "fc", "v", "in", "arena"]
        func words(_ title: String) -> Set<String> {
            Set(title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                .filter { $0.count > 2 && !skip.contains($0) })
        }
        var merged: [Entry] = []
        var buckets: [Int: [Int]] = [:]
        var wordsOf: [Set<String>] = []
        for event in events {
            let w = words(event.title)
            let bucket = event.event.map { $0.start.map { Int($0.timeIntervalSince1970 / 600) } ?? -1 } ?? -1
            var found: Int?
            if bucket >= 0, !w.isEmpty {
                for b in [bucket - 1, bucket, bucket + 1] {
                    for index in buckets[b] ?? [] where wordsOf[index].isSubset(of: w) || w.isSubset(of: wordsOf[index]) {
                        found = index
                        break
                    }
                    if found != nil { break }
                }
            }
            if let found {
                merged[found].channels += event.channels
                // A league one listing names and another doesn't (it fell
                // back to its service's name): the league.
                if let league = event.event?.league, isLeague(league), let current = merged[found].event, !isLeague(current.league) {
                    merged[found].event = Event(league: league, start: current.start, detail: current.detail)
                }
                // Keep the fuller title ("Edmonton Oilers vs. San Jose Sharks").
                if event.title.count > merged[found].title.count, w.count >= wordsOf[found].count {
                    let channels = merged[found].channels
                    merged[found] = Entry(title: event.title, channels: channels, event: merged[found].event)
                    wordsOf[found] = w
                }
            } else {
                buckets[bucket, default: []].append(merged.count)
                wordsOf.append(w)
                merged.append(event)
            }
        }
        return merged.map { entry in
            var entry = entry
            // Each channel once: a provider can list one in two categories.
            var seen = Set<String>()
            entry.channels = bestFirst(entry.channels.filter { seen.insert($0.id).inserted })
            return entry
        }.sorted { a, b in
            switch (a.event?.start, b.event?.start) {
            case let (x?, y?): return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.title < b.title
            }
        }
    }

    static func gameSections(_ events: [Entry], now: Date) -> [(title: String, entries: [Entry])] {
        let calendar = Calendar.current
        var live: [Entry] = [], today: [Entry] = [], tomorrow: [Entry] = []
        var later: [Entry] = [], earlier: [Entry] = [], undated: [Entry] = []
        for event in events {
            guard let start = event.event?.start else { undated.append(event); continue }
            // Started longer ago than such a game lasts: probably over (see
            // GameTime), listed apart, not LIVE.
            switch GameTime.state(start: start, league: event.event?.league ?? "", title: event.title, now: now) {
            case .live: live.append(event)
            case .over: earlier.append(event)
            default:
                if calendar.isDate(start, inSameDayAs: now) { today.append(event) }
                else if calendar.isDateInTomorrow(start) { tomorrow.append(event) }
                else { later.append(event) }
            }
        }
        return [("Live now", live), ("Later today", today), ("Tomorrow", tomorrow), ("Coming up", later),
                ("Earlier today", earlier), ("More events", undated)]
            .filter { !$0.1.isEmpty }
    }

    // MARK: Leagues, services, regions

    private static let leagues: [(keys: [String], name: String)] = [
        (["NCAAB WOMEN", "WOMEN'S COLLEGE BASKETBALL"], "Women's College Basketball"),
        (["NCAAF", "NCAA FOOTBALL", "COLLEGE FOOTBALL", "FCS ", "FBS "], "College Football"),
        (["NCAAB", "NCAA BASKETBALL", "COLLEGE BASKETBALL"], "College Basketball"),
        (["NCAA BASEBALL", "COLLEGE BASEBALL"], "College Baseball"),
        (["WNBA"], "WNBA"), (["NFL"], "NFL"), (["NBA"], "NBA"), (["NHL"], "NHL"), (["MILB", "MINOR LEAGUE"], "Minor League Baseball"),
        (["MLB"], "MLB"), (["MLS"], "MLS"), (["EPL", "PREMIER LEAGUE"], "Premier League"), (["EFL", "ENGLISH FOOTBALL LEAGUE"], "EFL"),
        (["SPFL", "SCOTTISH PROFESSIONAL"], "SPFL"), (["LA LIGA", "LALIGA"], "La Liga"), (["SERIE A"], "Serie A"),
        (["BUNDESLIGA"], "Bundesliga"), (["LIGUE 1"], "Ligue 1"), (["CHAMPIONS LEAGUE", "UEFA"], "UEFA"),
        (["NATIONAL LEAGUE"], "National League"), (["CHL", "OHL", "WHL", "QMJHL"], "Junior Hockey"),
        (["UFC"], "UFC"), (["WWE", "WRESTLING", "AEW", "TNA"], "Wrestling"), (["BOXING"], "Boxing"),
        (["FORMULA 1", "F1"], "Formula 1"), (["NASCAR"], "NASCAR"), (["INDYCAR"], "IndyCar"),
        (["DARTS", "PDC"], "Darts"), (["SNOOKER", "POOL"], "Snooker & Pool"), (["TENNIS", "ATP ", "WTA "], "Tennis"),
        (["GOLF", "PGA", "LPGA"], "Golf"), (["CRICKET", "T20", " ODI", "TEST, D"], "Cricket"),
        (["RUGBY", "NRL", "SUPERLEAGUE"], "Rugby"), (["SOCCER", "FOOTBALL / SOCCER"], "Soccer"),
    ]

    /// The league a category or event title names, if any.
    /// One of the leagues known by name (not a service's name).
    static func isLeague(_ name: String) -> Bool {
        leagues.contains { $0.name == name }
    }

    static func league(in text: String) -> String? {
        let upper = text.uppercased()
        let words = Set(upper.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        for (keys, name) in leagues where keys.contains(where: { key in
            // Short codes as whole words (NBA isn't in WNBA).
            let trimmed = key.trimmingCharacters(in: .whitespaces)
            return trimmed.count <= 4 && !trimmed.contains(" ") ? words.contains(trimmed) : upper.contains(trimmed)
        }) {
            return name
        }
        return nil
    }

    /// "ESPN Unlimited", "Paramount+", "DAZN UK" → a short service name
    /// for events with no league.
    static func serviceName(_ label: String) -> String {
        let cleaned = label.replacingOccurrences(of: #"\s+(US|UK|CA|AU)$"#, with: "", options: .regularExpression)
        return cleaned.isEmpty ? "Events" : cleaned
    }

    private static let regionTable: [String: String] = {
        let pairs: [(String, [String])] = [
            ("US", ["US", "USA", "UNITED STATES"]), ("UK", ["UK", "GB", "UNITED KINGDOM", "ENGLAND"]), ("CA", ["CA", "CANADA"]),
            ("AU", ["AU", "AUSTRALIA"]), ("NZ", ["NZ", "NEW ZEALAND"]), ("IE", ["IE", "IRELAND"]),
            ("DE", ["DE", "GER", "GERMANY"]), ("FR", ["FR", "FRANCE"]), ("ES", ["ES", "SPAIN"]), ("IT", ["IT", "ITALY"]),
            ("PT", ["PT", "PORTUGAL"]), ("NL", ["NL", "NETHERLANDS", "HOLLAND"]), ("BE", ["BE", "BELGIUM"]),
            ("CH", ["CH", "SWITZERLAND"]), ("AT", ["AT", "AUSTRIA"]), ("SE", ["SE", "SWEDEN"]), ("NO", ["NO", "NORWAY"]),
            ("DK", ["DK", "DENMARK"]), ("FI", ["FI", "FINLAND"]), ("PL", ["PL", "POLAND"]), ("CZ", ["CZ", "CZECH"]),
            ("GR", ["GR", "GREECE"]), ("TR", ["TR", "TURKEY"]), ("IN", ["IND", "INDIA"]), ("PK", ["PK", "PAKISTAN"]),
            ("PH", ["PH", "PHILIPPINES"]), ("MX", ["MX", "MEXICO"]), ("AR", ["ARGENTINA"]), ("BR", ["BR", "BRAZIL"]),
            ("CL", ["CL", "CHILE"]), ("CO", ["CO", "COLOMBIA"]), ("PE", ["PE", "PERU"]), ("CR", ["CR", "COSTA RICA"]),
            ("DO", ["DOMINICAN REPUBLIC"]), ("SV", ["EL SALVADOR"]), ("PA", ["PANAMA"]), ("PR", ["PUERTO RICO"]),
            ("LAT", ["LAT", "LATAM", "LATINO", "LATIN AMERICA"]), ("CAR", ["CAR", "CARIBBEAN"]), ("ARABIC", ["ARABIC", "ARAB", "MENA"]),
            ("IL", ["IL", "ISRAEL"]), ("AL", ["AL", "ALBANIA"]), ("RO", ["RO", "ROMANIA"]), ("HU", ["HU", "HUNGARY"]),
            ("HR", ["HR", "CROATIA"]), ("RS", ["RS", "SERBIA"]), ("BG", ["BG", "BULGARIA"]), ("RU", ["RU", "RUSSIA"]),
            ("UA", ["UA", "UKRAINE"]), ("KR", ["KR", "KOREA"]), ("JP", ["JP", "JAPAN"]), ("CN", ["CN", "CHINA"]),
            ("HK", ["HK", "HONG KONG"]), ("ZA", ["ZA", "SOUTH AFRICA"]), ("AFRICA", ["AFRICA"]), ("VN", ["VN", "VIETNAM"]),
            ("TH", ["TH", "THAILAND"]), ("EXYU", ["EXYU", "EX-YU", "BALKANS"]),
        ]
        var table: [String: String] = [:]
        for (code, names) in pairs { for name in names { table[name] = code } }
        return table
    }()

    static func region(_ text: String) -> String? { regionTable[text.uppercased().trimmingCharacters(in: .whitespaces)] }

    static func countryName(_ code: String) -> String {
        switch code {
        case "UK": "United Kingdom"
        case "LAT": "Latin America"
        case "CAR": "Caribbean"
        case "ARABIC": "Arabic"
        case "AFRICA": "Africa"
        case "EXYU": "Balkans"
        default: Locale(identifier: "en_US").localizedString(forRegionCode: code) ?? code
        }
    }

    static func flag(_ code: String) -> String {
        let iso = code == "UK" ? "GB" : code
        guard iso.count == 2 else { return code == "LAT" ? "🌎" : code == "CAR" ? "🏝️" : "🌍" }
        return iso.unicodeScalars.compactMap { UnicodeScalar(127_397 + $0.value) }.map(String.init).joined()
    }
}

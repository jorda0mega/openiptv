import Foundation

/// "Watch On": the channels showing one game, side by side. Each one's
/// service, feed, commentary language and picture; which plays first.
enum WatchOn {
    /// What one channel's listing says about how it shows a game.
    struct Feed: Hashable, Sendable {
        /// The category listing it ("ESPN Unlimited", "DAZN CA").
        let service: String
        /// Its network or feed ("ESPN2", "Sharks Broadcast").
        var detail: String?
        /// The commentary's language ("es", "fr"); nil for the main one.
        var language: String?
    }

    /// One channel showing the game, as the ranking sees it.
    struct Option: Hashable, Sendable {
        let id: String
        let feed: Feed
        /// The picture, as `quality(of:)` scores it.
        var quality: Int
    }

    /// The channel picked for a league last time: its service and language.
    struct Pick: Codable, Hashable, Sendable {
        let service: String
        let language: String?
    }

    // MARK: Language

    /// "(ESP)", "(Spanish Broadcast)", "(In French)": a feed's language,
    /// after the game's name.
    private static let marker = try! NSRegularExpression(
        pattern: #"\s*\(\s*(?:in\s+)?(esp|spa|spn|spanish|espa[ñn]ol|castellano|french|fran[çc]ais|fr)(?:\s+(?:broadcast|feed|audio|commentary|language|version))?\s*\)"#,
        options: [.caseInsensitive])
    /// "En Español-Elche CF vs. Celta de Vigo".
    private static let spanishLead = try! NSRegularExpression(pattern: #"^\s*en\s+espa[ñn]ol\s*[-–:]\s*"#, options: [.caseInsensitive])
    /// Networks that only speak one language. Not "Deportes" or "Español"
    /// alone: teams have them (Deportes Tolima, Español Osorno).
    private static let networks: [(pattern: String, language: String)] = [
        (#"\b(espn|fox|bein sports|bein)\s*deportes\b"#, "es"), (#"\b(tudn|univision|unimas|telemundo|galavisi[oó]n)\b"#, "es"),
        (#"\btv ?azteca\b"#, "es"), (#"\b(bein sports|bein)\s*(ñ|espa[ñn]ol)\b"#, "es"), (#"\bspanish (broadcast|feed|audio|commentary)\b"#, "es"),
        (#"\ben espa[ñn]ol\b"#, "es"), (#"\b(rds|tva sports)\b"#, "fr"), (#"\bfrench (broadcast|feed|audio|commentary)\b"#, "fr"),
    ]
    private static let spanishRegions: Set<String> = ["ES", "MX", "AR", "CL", "CO", "PE", "CR", "DO", "SV", "PA", "PR", "LAT"]

    /// A game's name without its language marker, and the language it named.
    static func withoutLanguage(_ title: String) -> (title: String, language: String?) {
        var title = title
        var language: String?
        let range = NSRange(title.startIndex..., in: title)
        if let match = spanishLead.firstMatch(in: title, range: range), let cut = Range(match.range, in: title) {
            title.removeSubrange(cut)
            language = "es"
        }
        while let match = marker.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let cut = Range(match.range, in: title), let word = Range(match.range(at: 1), in: title) {
            language = code(String(title[word]))
            title.removeSubrange(cut)
        }
        return (title.trimmingCharacters(in: .whitespaces), language)
    }

    /// The language a channel's name or category gives its commentary;
    /// nil when it doesn't say.
    static func language(in text: String) -> String? {
        if let marked = withoutLanguage(text).language { return marked }
        let lower = text.lowercased()
        return networks.first { lower.range(of: $0.pattern, options: .regularExpression) != nil }?.language
    }

    /// A category's region's language: Spanish for Spain and Latin America,
    /// French for France.
    static func language(ofRegion region: String?) -> String? {
        guard let region else { return nil }
        if spanishRegions.contains(region) { return "es" }
        return region == "FR" ? "fr" : nil
    }

    /// The language to hear a game in: Spanish for Spanish and Latin
    /// American football, otherwise the main (English) commentary.
    static func preferredLanguage(league: String, title: String) -> String? {
        let text = "\(league) \(title)".lowercased()
        let spanish = ["la liga", "laliga", "liga mx", "copa del rey", "libertadores", "sudamericana", "liga profesional",
                       "primera división", "primera division", "liga betplay", "segunda división", "segunda division"]
        return spanish.contains { text.contains($0) } ? "es" : nil
    }

    static func languageName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code.uppercased()
    }

    private static func code(_ word: String) -> String {
        let lower = word.lowercased()
        return lower.hasPrefix("fr") ? "fr" : "es"
    }

    // MARK: Picture

    /// The picture a channel's name promises: 6 full HD, 5 HD or 4K, 4
    /// unsaid, 2 SD, 1 low bandwidth, 0 a backup; and its label.
    static func quality(of name: String) -> (score: Int, label: String?) {
        let upper = name.uppercased()
        let words = Set(upper.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        if upper.contains("BACKUP") { return (0, "Backup") }
        if upper.hasPrefix("LBW") || upper.contains("(LBW)") { return (1, "Low Bandwidth") }
        if words.contains("FHD") || upper.contains("1080") { return (6, "HD") }
        if words.contains("UHD") || words.contains("4K") { return (5, "4K") }
        if words.contains("HD") || upper.contains("ᴴᴰ") { return (5, "HD") }
        if words.contains("SD") || upper.contains("ˢᴰ") { return (2, "SD") }
        return (4, nil)
    }

    // MARK: Order

    /// Which plays first: not one that failed lately; then the one picked
    /// for this league before; then the language (the pick's, else the
    /// league's), the main commentary next and others last; then the
    /// service picked; then the better picture; then as listed.
    static func ranked(_ options: [Option], pick: Pick?, preferred: String?, failed: Set<String>) -> [Option] {
        let language = pick.map(\.language) ?? preferred
        func key(_ option: Option) -> [Int] {
            let feed = option.feed
            let exact = pick.map { $0.service == feed.service && $0.language == feed.language } ?? false
            let spoken = feed.language == language ? 0 : feed.language == nil ? 1 : 2
            return [failed.contains(option.id) ? 1 : 0, exact ? 0 : 1, spoken,
                    pick?.service == feed.service ? 0 : 1, -option.quality]
        }
        return options.enumerated().sorted { a, b in
            let ka = key(a.element), kb = key(b.element)
            return ka != kb ? ka.lexicographicallyPrecedes(kb) : a.offset < b.offset
        }.map(\.element)
    }

    static func next<Channel: Identifiable>(after picked: Channel.ID, feeds: [[Channel]], tried: Set<Channel.ID>) -> Channel? {
        let own = feeds.first { $0.contains { $0.id == picked } } ?? []
        return (own + feeds.joined()).first { !tried.contains($0.id) }
    }

    static func name(_ feed: Feed) -> String {
        let title = label(feed, quality: nil).title
        return feed.language.map { "\(title) (\(languageName($0)))" } ?? title
    }

    static func switchSentence(from: String, to: String?) -> String {
        let now = to.map { $0 == from ? "Now on another \($0) channel." : "Now on \($0)." } ?? "Switching."
        return "\(from) didn’t play. \(now)"
    }

    /// How a channel is named in the list: by its service ("ESPN
    /// Unlimited"), or, when its category only names a sport or league
    /// ("Football / Soccer"), by the network its feed names ("OneSoccer"
    /// for "OneSoccer Feed"), the category under it. Then its feed, language
    /// and picture.
    static func label(_ feed: Feed, quality: String?) -> (title: String, line: String) {
        if isGeneric(feed.service), let detail = feed.detail, let network = network(detail) {
            let line = [feed.service, feed.language.map(languageName), quality].compactMap(\.self).joined(separator: " · ")
            return (network, line)
        }
        return (feed.service, line(feed, quality: quality))
    }

    /// "Spanish · HD", for a channel in the list.
    static func line(_ feed: Feed, quality: String?) -> String {
        [feed.detail, feed.language.map(languageName), quality].compactMap(\.self).joined(separator: " · ")
    }

    /// A category that names a sport or a league, not who shows it.
    static func isGeneric(_ service: String) -> Bool {
        let words = ["soccer", "football", "futbol", "basketball", "hockey", "baseball", "rugby", "cricket", "tennis", "golf",
                     "boxing", "mma", "nfl", "nba", "nhl", "mlb", "mls", "ncaa", "sports", "events", "ppv"]
        let text = service.lowercased()
        return words.contains { text.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }
    }

    /// "OneSoccer Feed" → "OneSoccer"; "ESPN Deportes USA Feed" → "ESPN
    /// Deportes USA"; a team's own feed ("Sharks Broadcast") as it is.
    private static func network(_ detail: String) -> String? {
        let name = detail.replacingOccurrences(of: #"\s+feed$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? nil : name
    }

    /// The same feed on several channels (a provider lists one feed in two
    /// slots): one entry, the best first, the others kept to fall back to.
    /// The same: the same service, feed, language and picture.
    static func grouped(_ options: [Option]) -> [(option: Option, others: [Option])] {
        var out: [(option: Option, others: [Option])] = []
        var at: [String: Int] = [:]
        for option in options {
            let feed = option.feed
            let key = [feed.service, feed.detail ?? "", feed.language ?? "", String(option.quality)].joined(separator: "|")
            if let index = at[key] {
                out[index].others.append(option)
            } else {
                at[key] = out.count
                out.append((option, []))
            }
        }
        return out
    }
}

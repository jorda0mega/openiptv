import Foundation

/// The audio and subtitles a film or episode starts with, decided before it
/// opens (the server lists its tracks), instead of whatever the file or
/// the server's account settings put first.
struct TrackPlan: Hashable, Sendable {
    /// Audio languages for the player, best first ("eng", "en").
    var audio: [String]
    /// Subtitle languages; nil: none, except forced ones (signs, foreign
    /// lines) in the audio's language.
    var subtitles: [String]?
    /// The kind of track picked for this title besides its language
    /// ("sdh", "commentary"; nil: the main one).
    var audioRole: String? = nil
    var subtitleRole: String? = nil
    /// Which Spanish, when a file has both: Spain's for titles made in
    /// Spain, Latin American otherwise (the user's rule).
    var spanish: TrackChoice.Variant = .latinAmerica
    /// What it was made from, to make it again with the viewer's newest
    /// picks (a playback got ready before a pick still has the old plan).
    var basis: Basis?

    struct Basis: Hashable, Sendable {
        let audio: [String?]
        let countries: [String]
        let key: String
        /// The title's other copies' keys (another library's show or film).
        var keys: [String] = []
    }

    /// The plan with the viewer's newest picks.
    func refreshed() -> TrackPlan {
        guard let basis else { return self }
        return TrackChoice.plan(audio: basis.audio, countries: basis.countries, key: basis.key, keys: basis.keys)
    }
}

/// The rules (the user's): Spanish for titles made in Spanish, English for
/// everything else; no subtitles unless the audio is in neither language
/// (sound with no language on it counts as the language of where the title
/// was made); what the viewer picks for a show or film is kept for it.
enum TrackChoice {
    /// Spain's Spanish or Latin American Spanish.
    enum Variant: String, Hashable, Sendable { case spain, latinAmerica }

    /// The Spanish for a title made in these countries (the first is the
    /// main one): Spain's for Spain, Latin American for anywhere else.
    static func spanish(for countries: [String]) -> Variant {
        countries.first == "Spain" ? .spain : .latinAmerica
    }

    /// Countries whose own films and shows are in Spanish.
    private static let spanishCountries: Set<String> = [
        "Spain", "Mexico", "Argentina", "Colombia", "Chile", "Peru", "Venezuela", "Cuba", "Uruguay", "Ecuador",
        "Bolivia", "Paraguay", "Guatemala", "Costa Rica", "Dominican Republic", "Puerto Rico", "Panama",
        "Honduras", "El Salvador", "Nicaragua",
    ]

    /// Countries whose own films and shows are in English.
    private static let englishCountries: Set<String> = [
        "United States of America", "United Kingdom", "Canada", "Australia", "Ireland", "New Zealand",
    ]

    /// `audio`: the file's audio languages in its own order (the first is
    /// usually the original); `countries`: where the title was made, first
    /// the main one; `key`: the show (for an episode) or the film, and
    /// `keys` its other copies' (a pick in any of them counts).
    /// The sound a title calls for, before looking at any file of it: the
    /// viewer's choice for it, else Spanish for a Spanish-made title, else
    /// English. Where it was made isn't known: Spanish when its sound
    /// starts in Spanish and English isn't heard in it (`heard`: every
    /// language in it, all its copies). Regression: Dragon Ball Z (no
    /// country on the server) played in Spanish, the dub first in a Latin
    /// American release, while its other copy had English.
    static func wantedAudio(countries: [String], original: String?, heard: Set<String> = [], keys: [String]) -> String {
        if let audio = keys.lazy.compactMap({ remembered($0)?.audio }).first { return audio }
        let made = countries.first.map { spanishCountries.contains($0) }
        return (made ?? (original.flatMap(normalized) == "es" && !heard.contains("en"))) ? "es" : "en"
    }

    static func plan(audio: [String?], countries: [String], key: String, keys: [String] = []) -> TrackPlan {
        let languages = audio.map { $0.flatMap(normalized) }
        let original = languages.first ?? nil
        let all = [key] + keys.filter { $0 != key }
        var wanted = wantedAudio(countries: countries, original: original, heard: Set(languages.compactMap(\.self)), keys: all)
        let kept = all.lazy.compactMap(remembered).first
        #if DEBUG
        NSLog("%@", "PERF plan audio=\(audio) countries=\(countries) keys=\(all) wanted=\(wanted) kept=\(kept?.audio ?? "-")")
        #endif
        // Not in the file: the original language.
        if !languages.contains(wanted), let original { wanted = original }
        // No language on any of its sound (a fifth of one server's titles),
        // made where neither is spoken: heard in that country's language
        // (War 2, India: Hindi), so subtitles. Regression: none showed.
        let unlabelledForeign = !languages.isEmpty && languages.allSatisfy { $0 == nil }
            && countries.first.map { !englishCountries.contains($0) && !spanishCountries.contains($0) } == true
        let subtitles: [String]?
        if let chosen = kept?.subtitles {
            subtitles = chosen == "off" ? nil : codes(chosen)
        } else if unlabelledForeign {
            subtitles = codes("en") + codes("es")
        } else if wanted == "en" || wanted == "es" {
            subtitles = nil
        } else {
            subtitles = codes("en") + codes("es")
        }
        return TrackPlan(audio: codes(wanted), subtitles: subtitles,
                         audioRole: kept?.audio == wanted ? kept?.audioRole : nil,
                         subtitleRole: subtitles == nil ? nil : kept?.subtitleRole,
                         spanish: spanish(for: countries),
                         basis: TrackPlan.Basis(audio: audio, countries: countries, key: key, keys: keys))
    }

    /// The plan's tracks among a file's: its audio (nil: the player's own
    /// choice) and subtitles (nil: none). In the plan's languages, the kind
    /// picked for the title (SDH, commentary), else the main track; no
    /// subtitles asked for: forced ones in the audio's language only.
    static func choose(_ tracks: [Track], plan: TrackPlan) -> (audio: Int?, subtitle: Int?) {
        func matches(_ track: Track, _ codes: [String]) -> Bool {
            let wanted = Set(codes.compactMap(normalized))
            return track.language.flatMap(normalized).map(wanted.contains) ?? false
        }
        func best(_ list: [Track], _ codes: [String], role: String?) -> Track? {
            var found = list.filter { matches($0, codes) }
            // Two Spanish: the one for where the title was made.
            let variant = found.filter { $0.variant == plan.spanish }
            if !variant.isEmpty, found.contains(where: { $0.variant != nil && $0.variant != plan.spanish }) {
                found = variant + found.filter { $0.variant == nil }
            }
            found = ranked(found)
            return found.first { $0.role == role } ?? found.first { $0.role == nil } ?? found.first
        }
        let audio = tracks.filter { $0.kind == .audio }
        let subtitles = tracks.filter { $0.kind == .subtitle }
        let chosen = best(audio, plan.audio, role: plan.audioRole)
        if let wanted = plan.subtitles {
            let shown = subtitles.filter { !$0.forced || plan.subtitleRole == "forced" }
            // English before Spanish (the plan's order), whatever their kind:
            // a Spanish file beside the film came before English drawn
            // subtitles inside it (Either Way).
            var languages: [String] = []
            for code in wanted { if let language = normalized(code), !languages.contains(language) { languages.append(language) } }
            for language in languages {
                if let track = best(shown, wanted.filter { normalized($0) == language }, role: plan.subtitleRole) {
                    return (chosen?.id, track.id)
                }
            }
            return (chosen?.id, nil)
        }
        let spoken = (chosen ?? audio.first)?.language
        let forced = subtitles.first { track in track.forced && (spoken.map { matches(track, [$0]) } ?? false) }
        return (chosen?.id, forced?.id)
    }

    /// How far before where a Matroska film starts mpv reads, so the
    /// subtitle line already on shows. None when it starts with none shown:
    /// the likely ones read along hidden then show from the next line, and
    /// reading back for them cost 1.1-1.4 s on the real feed. mpv's own
    /// with subtitles shown, for another quality of the same film, and live.
    static func subtitlePreroll(_ plan: TrackPlan?, reopening: Bool) -> [(name: String, value: String)] {
        let none = plan != nil && plan?.subtitles == nil && !reopening
        return [("demuxer-mkv-subtitle-preroll-secs", none ? "0" : "1"), ("demuxer-mkv-subtitle-preroll-secs-index", none ? "0" : "10")]
    }

    static func likelySubtitle(_ tracks: [Track], plan: TrackPlan) -> Int? {
        var plan = plan
        if plan.subtitles == nil { plan.subtitles = plan.audio }
        return choose(tracks.filter { !$0.image }, plan: plan).subtitle
    }

    /// Best first: more channels and a better sound (TrueHD, DTS, E-AC-3,
    /// AC-3, then the rest) for audio; for subtitles text before pictures
    /// (sharper, any size), inside the film before a file beside it (always
    /// in time with it); then the file's own order.
    static func ranked(_ tracks: [Track]) -> [Track] {
        func sound(_ codec: String?) -> Int {
            switch codec ?? "" {
            case "truehd", "mlp": 4
            case "dts", "dts-hd", "dtshd": 3
            case "eac3": 2
            case "ac3": 1
            default: 0
            }
        }
        return tracks.sorted { a, b in
            if a.kind == .audio {
                if (a.channels ?? 0) != (b.channels ?? 0) { return (a.channels ?? 0) > (b.channels ?? 0) }
                if sound(a.codec) != sound(b.codec) { return sound(a.codec) > sound(b.codec) }
            } else {
                if a.image != b.image { return !a.image }
                if a.external != b.external { return !a.external }
            }
            return a.id < b.id
        }
    }

    /// The tracks the viewer chooses from: one per language and kind, the
    /// best of each (see `ranked`), the one playing always among them.
    /// Audio: English, Spanish and the film's own language when it's
    /// neither, then commentaries; subtitles: English and Spanish, full
    /// and SDH (forced ones show by themselves where they're needed).
    /// Spanish: the variant for where the title was made. Other languages
    /// are left out; with nothing left, everything shows.
    static func menu(_ tracks: [Track], spanish: Variant) -> [Track] {
        let audio = tracks.filter { $0.kind == .audio }
        let subtitles = tracks.filter { $0.kind == .subtitle }
        let original = audio.first?.language.flatMap(normalized)
        func language(_ track: Track) -> String? { track.language.flatMap(normalized) }
        func pick(_ list: [Track], languages: [String], roles: [String?]) -> [Track] {
            var chosen: [Track] = []
            for role in roles {
                for code in languages {
                    var group = list.filter { language($0) == code && $0.role == role }
                    if code == "es", group.contains(where: { $0.variant == spanish }) {
                        group = group.filter { $0.variant == spanish || $0.variant == nil }
                    }
                    if let playing = group.first(where: \.selected) { chosen.append(playing) }
                    else if let best = ranked(group).first { chosen.append(best) }
                }
            }
            return chosen
        }
        var languages = ["en", "es"]
        if let original, !languages.contains(original) { languages.insert(original, at: 0) }
        var shownAudio = pick(audio, languages: languages, roles: [nil, "commentary"])
        if shownAudio.isEmpty { shownAudio = audio }
        if let playing = audio.first(where: \.selected), !shownAudio.contains(playing) { shownAudio.insert(playing, at: 0) }
        var shownSubtitles = pick(subtitles, languages: ["en", "es"], roles: [nil, "sdh"])
        if let playing = subtitles.first(where: { $0.selected && !$0.forced }), !shownSubtitles.contains(playing) {
            shownSubtitles.insert(playing, at: 0)
        }
        // English, then Spanish, the SDH beside its language.
        shownSubtitles.sort { (languages.firstIndex(of: language($0) ?? "") ?? 9, $0.role ?? "") < (languages.firstIndex(of: language($1) ?? "") ?? 9, $1.role ?? "") }
        return shownAudio + shownSubtitles
    }

    /// "eng", "en", "en-US" → "en"; "spa", "es-419", "esl" → "es"; a
    /// language's name as some files have it ("English", "Español",
    /// "Castellano") → its code.
    static func normalized(_ language: String) -> String? {
        let code = language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        if code.count > 3 {
            let name = language.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .split { !$0.isLetter }.first.map(String.init) ?? ""
            if let named = names[name] { return named }
        }
        switch code {
        case "", "und", "unk", "mis", "mul", "zxx": return nil
        case "en", "eng": return "en"
        case "es", "spa", "esl", "esp": return "es"
        default:
            if let modern = bibliographic[code] { return modern }
            return Locale.LanguageCode(code).identifier(.alpha2) ?? code
        }
    }

    /// The older ISO 639-2 codes some files still use ("fre" for French).
    private static let bibliographic: [String: String] = [
        "fre": "fr", "ger": "de", "chi": "zh", "dut": "nl", "gre": "el", "per": "fa", "cze": "cs", "rum": "ro",
        "slo": "sk", "alb": "sq", "arm": "hy", "baq": "eu", "bur": "my", "geo": "ka", "ice": "is", "mac": "mk",
        "mao": "mi", "may": "ms", "tib": "bo", "wel": "cy",
    ]

    /// Languages by their names in English and Spanish, folded ("english",
    /// "ingles", "espanol"), and the names files use for Spanish's kinds.
    private static let names: [String: String] = {
        var all: [String: String] = ["castellano": "es", "castilian": "es", "latino": "es"]
        for code in Locale.LanguageCode.isoLanguageCodes where code.identifier.count == 2 {
            for locale in [Locale(identifier: "en"), Locale(identifier: "es")] {
                guard let name = locale.localizedString(forLanguageCode: code.identifier) else { continue }
                let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                if let word = folded.split(whereSeparator: { !$0.isLetter }).first.map(String.init), all[word] == nil {
                    all[word] = code.identifier
                }
            }
        }
        return all
    }()

    /// The forms files use for a language ("en": "eng", "en").
    private static func codes(_ language: String) -> [String] {
        let alpha3 = Locale.LanguageCode(language).identifier(.alpha3) ?? language
        var all = [alpha3, language] + bibliographic.filter { $0.value == language }.map(\.key)
        if language == "es" { all += ["spa-419", "es-419", "esl"] }
        return all.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    // MARK: What the viewer picked

    private struct Kept: Codable {
        var audio: String?
        /// A language, or "off".
        var subtitles: String?
        /// "sdh", "commentary", …; nil: the main track.
        var audioRole: String?
        var subtitleRole: String?
    }

    private static let defaultsKey = "trackChoices"
    /// The most recent 300 titles.
    private static let limit = 300

    private static func remembered(_ key: String) -> Kept? {
        all()[key]
    }

    /// The viewer chose this audio track for the title, in every copy of it.
    static func rememberAudio(_ language: String?, role: String?, for keys: [String]) {
        for key in keys { rememberAudio(language, role: role, for: key) }
    }

    /// The viewer chose these subtitles for the title, in every copy of it.
    static func rememberSubtitles(_ language: String?, role: String?, for keys: [String]) {
        for key in keys { rememberSubtitles(language, role: role, for: key) }
    }

    /// The viewer chose this audio track (its language and kind) for the title.
    static func rememberAudio(_ language: String?, role: String?, for key: String) {
        guard let language = language.flatMap(normalized) else { return }
        update(key) {
            $0.audio = language
            $0.audioRole = role
        }
    }

    /// The viewer chose these subtitles (nil: off; their language and
    /// kind) for the title.
    static func rememberSubtitles(_ language: String?, role: String?, for key: String) {
        update(key) {
            $0.subtitles = language.flatMap(normalized) ?? "off"
            $0.subtitleRole = language == nil ? nil : role
        }
    }

    private static func all() -> [String: Kept] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let list = try? JSONDecoder().decode([String: Kept].self, from: data) else { return [:] }
        return list
    }

    private static let order = "trackChoicesOrder"

    #if DEBUG
    /// UI tests: `-forgetTrackChoices YES` at launch starts with no picks.
    static func forgetForTesting() {
        guard UserDefaults.standard.bool(forKey: "forgetTrackChoices") else { return }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: order)
    }
    #endif

    private static func update(_ key: String, _ change: (inout Kept) -> Void) {
        var list = all()
        var kept = list[key] ?? Kept()
        change(&kept)
        list[key] = kept
        var recent = (UserDefaults.standard.stringArray(forKey: order) ?? []).filter { $0 != key } + [key]
        if recent.count > limit {
            for old in recent.prefix(recent.count - limit) { list[old] = nil }
            recent = Array(recent.suffix(limit))
        }
        UserDefaults.standard.set(recent, forKey: order)
        if let data = try? JSONEncoder().encode(list) { UserDefaults.standard.set(data, forKey: defaultsKey) }
    }
}

/// An audio or subtitle track of the file.
struct Track: Identifiable, Hashable, Sendable {
    enum Kind: Sendable { case audio, subtitle }
    let id: Int
    let kind: Kind
    let title: String?
    /// ISO 639 code ("eng"), when the file says.
    let language: String?
    let channels: Int?
    let forced: Bool
    var selected: Bool
    /// Subtitles for the deaf and hard of hearing (the file says so).
    var hearingImpaired = false
    /// "subrip", "ass", "hdmv_pgs_subtitle", "truehd", "eac3", …
    var codec: String? = nil
    /// Subtitles drawn as pictures (PGS, VobSub), not text.
    var image = false
    /// From a file beside the film (the server's), not inside it.
    var external = false
    /// The file marks it as its default.
    var isDefault = false
    /// Its place in the file (FFmpeg's stream index; the server's
    /// "Index" for the same track).
    var ffIndex: Int? = nil

    /// Spain's or Latin American Spanish, from the track's language tag
    /// or name ("es-ES", "Castellano"; "es-419", "Latino"); nil: not said.
    var variant: TrackChoice.Variant? {
        let tag = (language ?? "").lowercased()
        if tag == "es-es" { return .spain }
        if ["es-419", "es-mx", "es-us", "es-ar", "es-co", "es-cl", "spa-419"].contains(tag) { return .latinAmerica }
        let name = (title ?? "").folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        let words = Set(name.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        if !words.isDisjoint(with: ["castellano", "castilian", "espana", "spain", "european", "europe"]) { return .spain }
        if !words.isDisjoint(with: ["latino", "latin", "latam", "latinoamerica", "latinoamericano", "mexico", "mexican", "419"]) {
            return .latinAmerica
        }
        return nil
    }

    /// What the track is for besides its language: "commentary", "sdh",
    /// "forced", or nil (the main one). Two English subtitle tracks,
    /// say, are told apart by it.
    var role: String? {
        let words = Set((title ?? "").lowercased().split { !$0.isLetter }.map(String.init))
        if words.contains("commentary") { return "commentary" }
        if hearingImpaired || !words.isDisjoint(with: ["sdh", "cc", "hoh"]) { return "sdh" }
        if forced || words.contains("forced") { return "forced" }
        return nil
    }
}

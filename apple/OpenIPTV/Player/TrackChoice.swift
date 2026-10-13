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
    /// What it was made from, to make it again with the viewer's newest
    /// picks (a playback got ready before a pick still has the old plan).
    var basis: Basis?

    struct Basis: Hashable, Sendable {
        let audio: [String?]
        let countries: [String]
        let key: String
    }

    /// The plan with the viewer's newest picks.
    func refreshed() -> TrackPlan {
        guard let basis else { return self }
        return TrackChoice.plan(audio: basis.audio, countries: basis.countries, key: basis.key)
    }
}

/// The rules (the user's): Spanish for titles made in Spanish, English for
/// everything else; no subtitles unless the audio is in neither language;
/// what the viewer picks for a show or film is kept for it.
enum TrackChoice {
    /// Countries whose own films and shows are in Spanish.
    private static let spanishCountries: Set<String> = [
        "Spain", "Mexico", "Argentina", "Colombia", "Chile", "Peru", "Venezuela", "Cuba", "Uruguay", "Ecuador",
        "Bolivia", "Paraguay", "Guatemala", "Costa Rica", "Dominican Republic", "Puerto Rico", "Panama",
        "Honduras", "El Salvador", "Nicaragua",
    ]

    /// `audio`: the file's audio languages in its own order (the first is
    /// usually the original); `countries`: where the title was made, first
    /// the main one; `key`: the show (for an episode) or the film.
    static func plan(audio: [String?], countries: [String], key: String) -> TrackPlan {
        let languages = audio.map { $0.flatMap(normalized) }
        let original = languages.first ?? nil
        let made = countries.first.map { spanishCountries.contains($0) }
        var wanted = (made ?? (original == "es")) ? "es" : "en"
        let kept = remembered(key)
        if let audio = kept?.audio { wanted = audio }
        // Not in the file: the original language.
        if !languages.contains(wanted), let original { wanted = original }
        let subtitles: [String]?
        if let chosen = kept?.subtitles {
            subtitles = chosen == "off" ? nil : codes(chosen)
        } else if wanted == "en" || wanted == "es" {
            subtitles = nil
        } else {
            subtitles = codes("en") + codes("es")
        }
        return TrackPlan(audio: codes(wanted), subtitles: subtitles,
                         audioRole: kept?.audio == wanted ? kept?.audioRole : nil,
                         subtitleRole: subtitles == nil ? nil : kept?.subtitleRole,
                         basis: TrackPlan.Basis(audio: audio, countries: countries, key: key))
    }

    /// The plan's tracks among a file's: its audio (nil: the player's own
    /// choice) and subtitles (nil: none). In the plan's languages, the kind
    /// picked for the title (SDH, commentary), else the main track; no
    /// subtitles asked for: forced ones in the audio's language only.
    static func choose(_ tracks: [MPVPlayer.Track], plan: TrackPlan) -> (audio: Int?, subtitle: Int?) {
        func matches(_ track: MPVPlayer.Track, _ codes: [String]) -> Bool {
            let wanted = Set(codes.compactMap(normalized))
            return track.language.flatMap(normalized).map(wanted.contains) ?? false
        }
        func best(_ list: [MPVPlayer.Track], _ codes: [String], role: String?) -> MPVPlayer.Track? {
            let found = list.filter { matches($0, codes) }
            return found.first { $0.role == role } ?? found.first { $0.role == nil } ?? found.first
        }
        let audio = tracks.filter { $0.kind == .audio }
        let subtitles = tracks.filter { $0.kind == .subtitle }
        let chosen = best(audio, plan.audio, role: plan.audioRole)
        if let wanted = plan.subtitles {
            let shown = subtitles.filter { !$0.forced || plan.subtitleRole == "forced" }
            return (chosen?.id, best(shown, wanted, role: plan.subtitleRole)?.id)
        }
        let spoken = (chosen ?? audio.first)?.language
        let forced = subtitles.first { track in track.forced && (spoken.map { matches(track, [$0]) } ?? false) }
        return (chosen?.id, forced?.id)
    }

    /// "eng", "en", "en-US" → "en"; "spa", "es-419", "esl" → "es".
    static func normalized(_ language: String) -> String? {
        let code = language.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
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

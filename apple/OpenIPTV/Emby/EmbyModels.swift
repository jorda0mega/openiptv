import Foundation

/// The subset of an Emby item the app renders.
struct EmbyItem: Codable, Hashable {
    struct UserData: Codable, Hashable {
        var playbackPositionTicks: Int64?
        var playedPercentage: Double?
        var played: Bool?
        /// ISO 8601, as the server sends it (sorts as text).
        var lastPlayedDate: String?
        /// On the viewer's My List (Emby's favorites).
        var isFavorite: Bool?
        enum CodingKeys: String, CodingKey {
            case playbackPositionTicks = "PlaybackPositionTicks"
            case playedPercentage = "PlayedPercentage"
            case played = "Played"
            case lastPlayedDate = "LastPlayedDate"
            case isFavorite = "IsFavorite"
        }
    }

    var id: String
    var name: String
    var kind: String
    var collectionType: String?
    var seriesName: String?
    var seriesId: String?
    var parentIndexNumber: Int?
    var indexNumber: Int?
    var productionYear: Int?
    var runTimeTicks: Int64?
    var primaryImageAspectRatio: Double?
    var imageTags: [String: String]
    var backdropImageTags: [String]
    var seriesPrimaryImageTag: String?
    var parentThumbItemId: String?
    var parentThumbImageTag: String?
    var parentBackdropItemId: String?
    var parentBackdropImageTags: [String]
    var parentPrimaryImageItemId: String?
    var parentPrimaryImageTag: String?
    var albumId: String?
    var albumPrimaryImageTag: String?
    var channelId: String?
    var channelPrimaryImageTag: String?
    var userData: UserData?
    var overview: String?
    var providerIds: [String: String]?
    /// ISO 8601: when the server added it.
    var dateCreated: String?
    /// ISO 8601: when it came out (a show: its first episode).
    var premiereDate: String?
    /// Cast and crew, when asked for (`Fields=People`).
    var people: [Person]?
    var genres: [String]?
    /// Where it was made, the main country first (a single item's full
    /// record has it): which language it starts in.
    var productionLocations: [String]?

    struct Person: Codable, Hashable {
        var name: String
        /// "Actor", "Director", "Writer", "GuestStar", …
        var type: String?
        var id: String?
        /// The part they play.
        var role: String?
        var primaryImageTag: String?
        enum CodingKeys: String, CodingKey {
            case name = "Name", type = "Type", id = "Id", role = "Role", primaryImageTag = "PrimaryImageTag"
        }
    }

    /// IMDb title id ("tt…"), when the server has matched one.
    var imdb: String? { Self.imdb(in: providerIds) }
    var tmdb: Int? { Self.tmdb(in: providerIds) }

    /// The same for every copy of a title in different libraries.
    var titleKey: String {
        guard kind == "Movie" || kind == "Series" else { return "id:" + id }
        return LibraryEntry.titleKey(kind: kind, name: name, year: productionYear, imdb: imdb, tmdb: tmdb)
    }

    /// Every key this title is known by: its IMDb and its TMDb id, so two
    /// copies match when each has only one of them; its name and year only
    /// when it has neither (two films can share a name and year).
    var titleKeys: Set<String> {
        guard kind == "Movie" || kind == "Series" else { return ["id:" + id] }
        var keys: Set<String> = []
        if let imdb { keys.insert(LibraryEntry.titleKey(kind: kind, name: name, year: productionYear, imdb: imdb, tmdb: nil)) }
        if let tmdb { keys.insert(LibraryEntry.titleKey(kind: kind, name: name, year: productionYear, imdb: nil, tmdb: tmdb)) }
        return keys.isEmpty ? [titleKey] : keys
    }

    static func imdb(in providers: [String: String]?) -> String? {
        providers?.first { $0.key.caseInsensitiveCompare("Imdb") == .orderedSame && $0.value.hasPrefix("tt") }?.value
    }

    static func tmdb(in providers: [String: String]?) -> Int? {
        providers?.first { $0.key.caseInsensitiveCompare("Tmdb") == .orderedSame }.flatMap { Int($0.value) }
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", kind = "Type", collectionType = "CollectionType"
        case seriesName = "SeriesName", seriesId = "SeriesId"
        case parentIndexNumber = "ParentIndexNumber", indexNumber = "IndexNumber"
        case productionYear = "ProductionYear", runTimeTicks = "RunTimeTicks"
        case primaryImageAspectRatio = "PrimaryImageAspectRatio"
        case imageTags = "ImageTags", backdropImageTags = "BackdropImageTags"
        case seriesPrimaryImageTag = "SeriesPrimaryImageTag"
        case parentThumbItemId = "ParentThumbItemId", parentThumbImageTag = "ParentThumbImageTag"
        case parentBackdropItemId = "ParentBackdropItemId", parentBackdropImageTags = "ParentBackdropImageTags"
        case parentPrimaryImageItemId = "ParentPrimaryImageItemId", parentPrimaryImageTag = "ParentPrimaryImageTag"
        case albumId = "AlbumId", albumPrimaryImageTag = "AlbumPrimaryImageTag"
        case channelId = "ChannelId", channelPrimaryImageTag = "ChannelPrimaryImageTag"
        case userData = "UserData"
        case overview = "Overview"
        case providerIds = "ProviderIds"
        case dateCreated = "DateCreated"
        case premiereDate = "PremiereDate"
        case people = "People"
        case genres = "Genres"
        case productionLocations = "ProductionLocations"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? ""
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? ""
        collectionType = try? c.decodeIfPresent(String.self, forKey: .collectionType)
        seriesName = try? c.decodeIfPresent(String.self, forKey: .seriesName)
        seriesId = try? c.decodeIfPresent(String.self, forKey: .seriesId)
        parentIndexNumber = try? c.decodeIfPresent(Int.self, forKey: .parentIndexNumber)
        indexNumber = try? c.decodeIfPresent(Int.self, forKey: .indexNumber)
        productionYear = try? c.decodeIfPresent(Int.self, forKey: .productionYear)
        runTimeTicks = try? c.decodeIfPresent(Int64.self, forKey: .runTimeTicks)
        primaryImageAspectRatio = try? c.decodeIfPresent(Double.self, forKey: .primaryImageAspectRatio)
        imageTags = (try? c.decodeIfPresent([String: String].self, forKey: .imageTags)) ?? [:]
        backdropImageTags = (try? c.decodeIfPresent([String].self, forKey: .backdropImageTags)) ?? []
        seriesPrimaryImageTag = try? c.decodeIfPresent(String.self, forKey: .seriesPrimaryImageTag)
        parentThumbItemId = try? c.decodeIfPresent(String.self, forKey: .parentThumbItemId)
        parentThumbImageTag = try? c.decodeIfPresent(String.self, forKey: .parentThumbImageTag)
        parentBackdropItemId = try? c.decodeIfPresent(String.self, forKey: .parentBackdropItemId)
        parentBackdropImageTags = (try? c.decodeIfPresent([String].self, forKey: .parentBackdropImageTags)) ?? []
        parentPrimaryImageItemId = try? c.decodeIfPresent(String.self, forKey: .parentPrimaryImageItemId)
        parentPrimaryImageTag = try? c.decodeIfPresent(String.self, forKey: .parentPrimaryImageTag)
        albumId = try? c.decodeIfPresent(String.self, forKey: .albumId)
        albumPrimaryImageTag = try? c.decodeIfPresent(String.self, forKey: .albumPrimaryImageTag)
        channelId = try? c.decodeIfPresent(String.self, forKey: .channelId)
        channelPrimaryImageTag = try? c.decodeIfPresent(String.self, forKey: .channelPrimaryImageTag)
        userData = try? c.decodeIfPresent(UserData.self, forKey: .userData)
        overview = try? c.decodeIfPresent(String.self, forKey: .overview)
        // Values can be null on some servers; keep the ones that are there.
        providerIds = (try? c.decodeIfPresent([String: String?].self, forKey: .providerIds))?.compactMapValues { $0 }
        dateCreated = try? c.decodeIfPresent(String.self, forKey: .dateCreated)
        premiereDate = try? c.decodeIfPresent(String.self, forKey: .premiereDate)
        people = (try? c.decodeIfPresent([Lenient<Person>].self, forKey: .people))?.compactMap(\.value)
        genres = try? c.decodeIfPresent([String].self, forKey: .genres)
        productionLocations = try? c.decodeIfPresent([String].self, forKey: .productionLocations)
    }
}

struct CardImage: Codable, Hashable {
    let url: String
    let contain: Bool
}

extension Card {
    /// The same card with more after its subtitle ("… · with Antonio Banderas").
    func adding(_ note: String) -> Card {
        Card(id: id, kind: kind, title: title, subtitle: [subtitle, note].compactMap(\.self).joined(separator: " · "),
             images: images, progress: progress, playable: playable, episodeId: episodeId, seriesId: seriesId,
             episodeName: episodeName)
    }
}

struct Card: Codable, Hashable, Identifiable {
    let id: String
    let kind: String
    let title: String
    let subtitle: String?
    let images: [CardImage]
    let progress: Double?
    let playable: Bool
    /// For a show in Continue Watching / Next Up: the episode to resume.
    var episodeId: String? = nil
    /// For an episode: its show, to open from search.
    var seriesId: String? = nil
    /// Continue Watching: the episode's name, for VoiceOver (the card shows
    /// "S1, E1 · 33m", as in the Apple TV app).
    var episodeName: String? = nil
}

struct HomeRow: Codable, Hashable, Identifiable {
    var id: String { title }
    let title: String
    let shape: String
    let aspect: Double
    let cards: [Card]
}

/// Where and from what position to play an Emby item.
struct EmbyPlayback: Hashable, Identifiable {
    var id: String { itemId }
    let itemId: String
    let title: String
    let subtitle: String?
    let url: URL
    /// "Name: value" headers the source needs (remote sources only).
    var headers: [String] = []
    var startSeconds: Double?
    let durationSeconds: Double?
    var mediaSourceId: String?
    var playSessionId: String?
    /// How it plays, for diagnostics: "direct stream", "remote file" or "transcode".
    var method = "direct stream"
    /// Tried in order if `url` fails to open (Emby's direct stream, then HLS).
    var fallbacks: [URL] = []
    /// Headers for the fallbacks (Emby's token, in case a server ignores it
    /// in the address).
    var fallbackHeaders: [String] = []
    /// Seconds spent asking the server before the player started (0 when
    /// it was prepared ahead of the tap).
    var resolvedIn: Double = 0
    /// When the user asked for it, to time the whole start.
    var requestedAt = Date()
    /// Bitrate of the original file (bits/s), when the server knows it.
    var bitrate: Int?
    /// The show an episode belongs to.
    var seriesId: String?
    /// The story, for the player's Info panel.
    var overview: String?
    /// A still from it (an episode's own, a film's backdrop), for the
    /// player's Info panel sideways.
    var stills: [CardImage] = []
    /// The audio and subtitles it starts with (see TrackChoice).
    var tracks: TrackPlan?
    /// Subtitle files beside the film on the server (English and Spanish),
    /// added to its own tracks once fetched.
    var subtitleFiles: [SubtitleFile] = []
    /// One of the film's own subtitle tracks as text (the server extracts
    /// it): in time with the film, so the files can be put in time by it.
    var subtitleReference: URL?
    /// The languages of every subtitle track the server knows for it (the
    /// film's own and files), normalized ("en", "es").
    var subtitleLanguages: Set<String> = []

    struct SubtitleFile: Hashable, Sendable {
        let url: URL
        let language: String?
        /// "SDH", "Forced": words the player reads the kind from.
        let title: String
    }

    /// The same, starting from this second (back from Picture in Picture).
    func resuming(at seconds: Double) -> EmbyPlayback {
        var copy = self
        copy.startSeconds = seconds
        copy.requestedAt = Date()
        return copy
    }
}

struct EmbyConnectServer: Decodable, Hashable, Identifiable {
    var id: String { accessKey }
    let name: String
    let remoteAddress: String?
    let localAddress: String?
    let accessKey: String

    enum CodingKeys: String, CodingKey {
        case name = "Name", remoteAddress = "Url", localAddress = "LocalAddress", accessKey = "AccessKey"
    }

    var addresses: [URL] {
        [remoteAddress, localAddress].compactMap { $0 }.filter { !$0.isEmpty }.compactMap(URL.init(string:))
    }
}

struct EmbyConnectSession {
    let userId: String
    let accessToken: String
    let servers: [EmbyConnectServer]
}

extension EmbyItem {
    /// Where to pick up. Any saved spot counts, even on something watched
    /// before (a rewatch keeps Played but saves the spot), as Emby's own
    /// apps do.
    var resumeTicks: Int64? {
        userData?.playbackPositionTicks.flatMap { $0 > 0 ? $0 : nil }
    }

    /// How far in (0…1), for the bar under Continue.
    var resumeFraction: Double? {
        guard let ticks = resumeTicks else { return nil }
        if let total = runTimeTicks, total > 0 { return min(Double(ticks) / Double(total), 1) }
        return userData?.playedPercentage.map { min($0 / 100, 1) }
    }

    /// "18 min left", "1 h 5 min left".
    var timeLeft: String? {
        guard let ticks = resumeTicks, let total = runTimeTicks, total > ticks else { return nil }
        let minutes = max(1, Int((total - ticks) / 600_000_000))
        if minutes < 60 { return "\(minutes) min left" }
        return minutes % 60 == 0 ? "\(minutes / 60) h left" : "\(minutes / 60) h \(minutes % 60) min left"
    }

    /// "S4 E2"
    var episodeCode: String? {
        parentIndexNumber.flatMap { season in indexNumber.map { "S\(season) E\($0)" } }
    }
}

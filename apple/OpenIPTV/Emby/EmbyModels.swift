import Foundation

/// The subset of an Emby item the app renders.
struct EmbyItem: Decodable, Hashable {
    struct UserData: Decodable, Hashable {
        var playbackPositionTicks: Int64?
        var playedPercentage: Double?
        var played: Bool?
        /// ISO 8601, as the server sends it (sorts as text).
        var lastPlayedDate: String?
        enum CodingKeys: String, CodingKey {
            case playbackPositionTicks = "PlaybackPositionTicks"
            case playedPercentage = "PlayedPercentage"
            case played = "Played"
            case lastPlayedDate = "LastPlayedDate"
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
    /// Cast and crew, when asked for (`Fields=People`).
    var people: [Person]?

    struct Person: Decodable, Hashable {
        var name: String
        /// "Actor", "Director", "Writer", "GuestStar", …
        var type: String?
        enum CodingKeys: String, CodingKey { case name = "Name", type = "Type" }
    }

    /// IMDb title id ("tt…"), when the server has matched one.
    var imdb: String? { Self.imdb(in: providerIds) }
    var tmdb: Int? { Self.tmdb(in: providerIds) }

    /// The same for every copy of a title in different libraries.
    var titleKey: String {
        guard kind == "Movie" || kind == "Series" else { return "id:" + id }
        return LibraryEntry.titleKey(kind: kind, name: name, year: productionYear, imdb: imdb, tmdb: tmdb)
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
        case people = "People"
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
        people = (try? c.decodeIfPresent([Lenient<Person>].self, forKey: .people))?.compactMap(\.value)
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
             images: images, progress: progress, playable: playable, episodeId: episodeId)
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
    let startSeconds: Double?
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

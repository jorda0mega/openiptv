import Foundation

/// The subset of an Emby item the app renders.
struct EmbyItem: Decodable, Hashable {
    struct UserData: Decodable, Hashable {
        var playbackPositionTicks: Int64?
        var playedPercentage: Double?
        var played: Bool?
        enum CodingKeys: String, CodingKey {
            case playbackPositionTicks = "PlaybackPositionTicks"
            case playedPercentage = "PlayedPercentage"
            case played = "Played"
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
    }
}

struct CardImage: Codable, Hashable {
    let url: String
    let contain: Bool
}

struct Card: Codable, Hashable, Identifiable {
    let id: String
    let kind: String
    let title: String
    let subtitle: String?
    let images: [CardImage]
    let progress: Double?
    let playable: Bool
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
    let startSeconds: Double?
    let durationSeconds: Double?
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

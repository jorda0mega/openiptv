import Foundation
import Observation

/// How libmpv trades start-up speed against resilience to network hiccups.
enum PlayerProfile: String, CaseIterable, Codable, Identifiable {
    case fastStart, balanced, smooth
    var id: String { rawValue }

    var title: String {
        switch self {
        case .fastStart: "Fast start"
        case .balanced: "Balanced"
        case .smooth: "Smooth"
        }
    }

    var detail: String {
        switch self {
        case .fastStart: "Plays the first frame as soon as possible. Best on a good connection."
        case .balanced: "A little more buffering before and during playback."
        case .smooth: "Buffers more up front; fewest stalls on a weak connection."
        }
    }

    /// libmpv options applied when the player is created.
    var mpvOptions: [(String, String)] {
        switch self {
        case .fastStart:
            [("cache-pause-initial", "no"), ("demuxer-readahead-secs", "8"),
             ("demuxer-lavf-probesize", "524288"), ("demuxer-lavf-analyzeduration", "1")]
        case .balanced:
            [("cache-pause-initial", "no"), ("demuxer-readahead-secs", "20"),
             ("demuxer-lavf-probesize", "1048576"), ("demuxer-lavf-analyzeduration", "2")]
        case .smooth:
            [("cache-pause-initial", "yes"), ("cache-pause-wait", "2"), ("demuxer-readahead-secs", "60"),
             ("demuxer-lavf-probesize", "4194304"), ("demuxer-lavf-analyzeduration", "3")]
        }
    }
}

/// Everything the user can tune, persisted in UserDefaults.
@Observable
@MainActor
final class Preferences {
    var playerProfile: PlayerProfile { didSet { save() } }
    var hardwareDecoding: Bool { didSet { save() } }
    /// Lower the quality instead of stopping to buffer (Emby).
    var adaptiveQuality: Bool { didSet { save() } }
    var favorites: [LiveChannel] { didSet { save() } }
    var hiddenCategories: Set<String> { didSet { save() } }
    var hiddenRows: Set<String> { didSet { save() } }
    /// Where local channels come from (set in Settings, or from the
    /// iPhone's approximate location).
    var area: LocalArea? { didSet { save() } }
    /// Turn videos with the phone even when Rotation Lock is on (iPhone).
    var rotateWithPhone: Bool { didSet { save() } }

    private struct Stored: Codable {
        var playerProfile = PlayerProfile.fastStart
        var hardwareDecoding = true
        var adaptiveQuality: Bool? = true
        var favorites: [LiveChannel] = []
        var hiddenCategories: Set<String> = []
        var hiddenRows: Set<String> = []
        var area: LocalArea?
        var rotateWithPhone: Bool? = true
    }

    // Favourites hold channel names, logos and stream references. Xtream and
    // Stalker references carry no credentials; M3U stream URLs can, so those
    // are stored without their URL and re-resolved from the live lineup.
    private static let key = "preferences.v2"

    init() {
        let stored = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
        playerProfile = stored.playerProfile
        hardwareDecoding = stored.hardwareDecoding
        adaptiveQuality = stored.adaptiveQuality ?? true
        favorites = stored.favorites
        hiddenCategories = stored.hiddenCategories
        hiddenRows = stored.hiddenRows
        area = stored.area
        rotateWithPhone = stored.rotateWithPhone ?? true
    }

    func isFavorite(_ channel: LiveChannel) -> Bool { favorites.contains { $0.id == channel.id } }

    func toggleFavorite(_ channel: LiveChannel) {
        if isFavorite(channel) {
            favorites.removeAll { $0.id == channel.id }
        } else {
            favorites.append(channel)
        }
    }

    private func save() {
        let stored = Stored(
            playerProfile: playerProfile,
            hardwareDecoding: hardwareDecoding,
            adaptiveQuality: adaptiveQuality,
            favorites: favorites.map(\.withoutSecrets),
            hiddenCategories: hiddenCategories,
            hiddenRows: hiddenRows,
            area: area,
            rotateWithPhone: rotateWithPhone
        )
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

extension LiveChannel {
    /// Playlist stream URLs can embed credentials, so they're never written
    /// to preferences; the live lineup supplies them again when played.
    var withoutSecrets: LiveChannel {
        guard case .url = stream else { return self }
        return LiveChannel(id: id, sourceId: sourceId, number: number, name: name, logo: logo,
                           categoryId: categoryId, epgId: epgId, nativeId: nativeId,
                           stream: .url(URL(string: "about:blank")!, userAgent: nil, referrer: nil))
    }
}

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
    var favorites: [Channel] { didSet { save() } }
    var hiddenCategories: Set<String> { didSet { save() } }
    var hiddenRows: Set<String> { didSet { save() } }

    private struct Stored: Codable {
        var playerProfile = PlayerProfile.fastStart
        var hardwareDecoding = true
        var favorites: [Channel] = []
        var hiddenCategories: Set<String> = []
        var hiddenRows: Set<String> = []
    }

    private static let key = "preferences"

    init() {
        let stored = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(Stored.self, from: $0) } ?? Stored()
        playerProfile = stored.playerProfile
        hardwareDecoding = stored.hardwareDecoding
        favorites = stored.favorites
        hiddenCategories = stored.hiddenCategories
        hiddenRows = stored.hiddenRows
    }

    func isFavorite(_ channel: Channel) -> Bool { favorites.contains { $0.id == channel.id } }

    func toggleFavorite(_ channel: Channel) {
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
            favorites: favorites,
            hiddenCategories: hiddenCategories,
            hiddenRows: hiddenRows
        )
        if let data = try? JSONEncoder().encode(stored) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

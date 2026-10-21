import Foundation

/// How to play a title (Emby's PlaybackInfo with the item), asked of the
/// server once and kept a short while: by the title and its copies known
/// now, whatever kind it was asked as.
struct PlanKey: Hashable, Sendable {
    let itemId: String
    let kind: String?
    let versions: [String]

    static func == (a: PlanKey, b: PlanKey) -> Bool { a.itemId == b.itemId && a.versions == b.versions }

    func hash(into hasher: inout Hasher) {
        hasher.combine(itemId)
        hasher.combine(versions)
    }
}

extension Lane {
    static let emby = Lane(.light, atOnce: 4, conditions: Conditions.current)
}

@MainActor
enum Plans {
    /// A play takes its plan (one play session each). One got ready ahead
    /// and failed is asked again by the play.
    static func shelf(lane: Lane? = nil, now: @escaping @Sendable () -> Date = { Date() },
                      fetch: @escaping @Sendable (PlanKey) async throws -> EmbyPlayback) -> Shelf<PlanKey, EmbyPlayback> {
        Shelf(.init(lane: lane ?? .emby, lifetime: .seconds(180), failureKept: .zero), now: now, fetch: fetch)
    }
}

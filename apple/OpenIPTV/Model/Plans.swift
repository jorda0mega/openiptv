import Foundation

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
    static func shelf(lane: Lane? = nil, now: @escaping @Sendable () -> Date = { Date() },
                      fetch: @escaping @Sendable (PlanKey) async throws -> EmbyPlayback) -> Shelf<PlanKey, EmbyPlayback> {
        Shelf(.init(lane: lane ?? .emby, lifetime: .seconds(180), failureKept: .zero), now: now, fetch: fetch)
    }
}

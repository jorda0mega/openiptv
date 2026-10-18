import Foundation

struct LiveCategory: Codable, Hashable, Identifiable {
    /// Unique across sources: "<source>|<provider id>".
    let id: String
    let name: String
    var channels: Int

    /// The source it came from (the first part of its id).
    var sourceId: UUID? { id.split(separator: "|").first.flatMap { UUID(uuidString: String($0)) } }
}

/// How to start a channel. Resolved to a URL only when it's played, because
/// stream URLs embed credentials (and Stalker issues per-play links).
enum StreamRef: Codable, Hashable {
    case xtream(streamId: Int64)
    case url(URL, userAgent: String?, referrer: String?)
    case stalker(cmd: String)
}

struct LiveChannel: Codable, Hashable, Identifiable {
    /// Unique across sources: "<source>|<provider id>".
    let id: String
    let sourceId: UUID
    let number: Int64?
    let name: String
    let logo: URL?
    let categoryId: String?
    let epgId: String?
    /// Provider id used for its own short-EPG lookups.
    let nativeId: String
    let stream: StreamRef
    /// Days of programmes the provider keeps to watch again (catch-up).
    var archiveDays: Int? = nil
}

struct Programme: Codable, Hashable {
    let start: Int64
    let stop: Int64
    let title: String
    /// The provider keeps a recording to watch from the start (catch-up).
    var archived: Bool? = nil

    func progress(at date: Date = .now) -> Double {
        guard stop > start else { return 0 }
        return min(1, max(0, (date.timeIntervalSince1970 - Double(start)) / Double(stop - start)))
    }
}

/// What's on now and next, plus the second this stops being true, so the UI
/// updates exactly at programme boundaries instead of polling.
/// One channel's now/next for its row to watch: details arriving for one
/// channel redraw that row alone, not the whole list.
@Observable
@MainActor
final class NowNextSlot {
    var value: NowNext?
    init(_ value: NowNext?) { self.value = value }
}

struct NowNext: Hashable {
    enum Source: String { case guide, provider, none }

    var now: Programme?
    var next: Programme?
    var refreshAt: Int64?
    var source: Source

    static let empty = NowNext(now: nil, next: nil, refreshAt: nil, source: .none)

    var isStale: Bool {
        guard let refreshAt else { return false }
        return Int64(Date.now.timeIntervalSince1970) >= refreshAt
    }

    /// From an unsorted list; on overlap the latest-starting programme wins.
    static func from(_ programmes: [Programme], at now: Int64 = Int64(Date.now.timeIntervalSince1970), source: Source) -> NowNext {
        var current: Programme?
        var upcoming: Programme?
        for p in programmes where p.stop > p.start {
            if p.start <= now, now < p.stop {
                if current == nil || p.start > current!.start { current = p }
            } else if p.start > now, upcoming == nil || p.start < upcoming!.start {
                upcoming = p
            }
        }
        let refresh: Int64? = switch (current, upcoming) {
        case let (c?, n?): min(c.stop, n.start)
        case let (c?, nil): c.stop
        case let (nil, n?): n.start
        // Nothing known: ask again in a quarter of an hour, not never (an
        // empty answer used to stay "fresh" and the row blank for good).
        default: now + 900
        }
        let found = current != nil || upcoming != nil
        return NowNext(now: current, next: upcoming, refreshAt: refresh, source: found ? source : .none)
    }

    /// Guide filler that says nothing about what's on.
    static func isPlaceholder(_ title: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespaces).lowercased()
        return t.isEmpty || ["tba", "tbd", "n/a", "no info", "to be announced"].contains(t)
            || ["no information", "information available", "no programme", "no program", "not available"]
                .contains(where: t.contains)
    }
}

/// A playable stream: the URL plus any headers the provider requires.
struct PlayableStream {
    let url: URL
    var headers: [String] = []
}

/// A provider's channel lineup.
struct LiveLineup {
    var categories: [LiveCategory]
    var channels: [LiveChannel]
    /// XMLTV guide(s) the provider publishes.
    var guideURLs: [URL]
}

protocol LiveProvider: Sendable {
    var source: IPTVSource { get }
    func load() async throws -> LiveLineup
    /// Quick per-channel now/next straight from the provider, if it has one.
    func shortEPG(for channel: LiveChannel) async -> [Programme]
    func playable(_ channel: LiveChannel) async throws -> PlayableStream
    /// The channel's schedule, days back and ahead, marking what can be
    /// watched again (empty when the provider has no per-channel guide).
    func schedule(for channel: LiveChannel) async -> [Programme]
    /// A recorded programme from its start (nil without catch-up).
    func catchup(_ channel: LiveChannel, programme: Programme) async throws -> PlayableStream?
}

extension LiveProvider {
    func shortEPG(for channel: LiveChannel) async -> [Programme] { [] }
    func schedule(for channel: LiveChannel) async -> [Programme] { [] }
    func catchup(_ channel: LiveChannel, programme: Programme) async throws -> PlayableStream? { nil }
}

enum Providers {
    static func make(_ source: IPTVSource) -> any LiveProvider {
        switch source.kind {
        case .xtream: XtreamProvider(source: source)
        case .m3u: M3UProvider(source: source)
        case .stalker: StalkerProvider(source: source)
        }
    }
}

/// Panels often list account details (login, expiry, connections) as fake
/// channels or a whole category; they aren't watchable and can leak logins.
enum AccountInfoFilter {
    static func looksLikeAccountInfo(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["username", "user name", "user:", "password", "pass:", "expire", "expiry",
                "max conn", "active conn", "account info"].contains(where: n.contains)
    }

    static func mentions(_ text: String, secrets: [String]) -> Bool {
        let t = text.lowercased()
        return secrets.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= 4 }
            .contains(where: t.contains)
    }
}

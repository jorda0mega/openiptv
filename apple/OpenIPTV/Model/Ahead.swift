import Foundation

enum Target: Hashable, Sendable {
    case title(id: String, kind: String)
    case playable(id: String, kind: String?)

    static func showMain(_ show: String, upNext episode: String?) -> Target {
        episode.map { .playable(id: $0, kind: "Episode") } ?? .playable(id: show, kind: "Series")
    }
}

enum Platform: Sendable {
    case phone, tv

    static var current: Platform {
        #if os(tvOS)
        .tv
        #else
        .phone
        #endif
    }
}

extension Place {
    struct Step: Equatable, Sendable {
        let after: Duration
        let likelihood: Likelihood
    }

    func ladder(on platform: Platform) -> [Step] {
        switch (self, platform) {
        case (.continueWatching, .phone): return [.init(after: .milliseconds(600), likelihood: .likely), .init(after: .seconds(2), likelihood: .next)]
        case (.continueWatching, .tv), (.episodeRow, .tv): return [.init(after: .milliseconds(150), likelihood: .likely), .init(after: .milliseconds(400), likelihood: .next)]
        case (.episodeRow, .phone): return [.init(after: .milliseconds(600), likelihood: .glance), .init(after: .seconds(2), likelihood: .likely)]
        case (.posterRow, .phone), (.grid, .phone), (.moreLikeThis, .phone), (.person, .phone), (.searchResult, .phone):
            return [.init(after: .milliseconds(600), likelihood: .glance)]
        case (.posterRow, .tv), (.grid, .tv), (.moreLikeThis, .tv), (.person, .tv), (.searchResult, .tv):
            return [.init(after: .milliseconds(150), likelihood: .glance), .init(after: .seconds(1), likelihood: .likely)]
        case (.searchTop, _): return [.init(after: .zero, likelihood: .likely)]
        case (.hero, .phone): return [.init(after: .seconds(1), likelihood: .likely)]
        case (.hero, .tv): return [.init(after: .milliseconds(400), likelihood: .next)]
        case (.page, _): return [.init(after: .zero, likelihood: .next)]
        case (.homeForecast, _): return [.init(after: .zero, likelihood: .likely)]
        case (.upNext, _): return [.init(after: .zero, likelihood: .glance)]
        case (.liveRow, _): return [.init(after: .milliseconds(250), likelihood: .likely)]
        case (.liveLookahead, _): return [.init(after: .milliseconds(500), likelihood: .glance)]
        }
    }

    var heldWhileOpen: Bool { self == .page || self == .homeForecast }

    /// The likely rung of a ladder that waits first: the card the user
    /// rests on, not a row's forecast, the top result or a page.
    func isRestedOn(at likelihood: Likelihood, on platform: Platform = .current) -> Bool {
        likelihood == .likely && ladder(on: platform).contains { $0.likelihood == .likely && $0.after > .zero }
    }
}

enum Need: Hashable, Sendable {
    case page
    case plan
    case fileStart
    /// The connection playback will use, kept open.
    case connection
    case subtitleFile
    /// The likeliest subtitles, when they are one of the film's own tracks:
    /// the server's copy (it reads the whole film for it).
    case subtitleCopy
    case previews
}

@MainActor
final class Ahead {
    struct Work {
        var page: @MainActor (Target, Interest) async -> Void
        var plan: @MainActor (Target, Interest) async -> EmbyPlayback?
        var fileStart: @MainActor (EmbyPlayback, Interest) async -> Void
        var connection: @MainActor (EmbyPlayback, Interest) async -> Void
        var subtitle: @MainActor (ServerSubtitle, Interest) async -> Void
        var previews: @MainActor (EmbyPlayback, Interest) async -> Void
    }

    private let work: Work
    #if DEBUG
    private(set) var held = 0
    #endif
    private let platform: Platform
    private let sleep: @Sendable (Duration) async throws -> Void

    init(_ work: Work, platform: Platform = .current,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.work = work
        self.platform = platform
        self.sleep = sleep
    }

    nonisolated static func needs(_ target: Target, _ likelihood: Likelihood) -> [Need] {
        switch (target, likelihood) {
        case (.title, .glance): [.page]
        case (.title, _): [.page, .plan, .subtitleFile]
        case (.playable, .glance): [.plan]
        case (.playable, .likely): [.plan, .fileStart, .connection, .subtitleFile]
        case (.playable, .next): [.plan, .fileStart, .connection, .subtitleFile, .subtitleCopy, .previews]
        }
    }

    func holding(_ target: Target, at place: Place) async {
        #if DEBUG
        held += 1
        #endif
        await withTaskGroup(of: Void.self) { group in
            var waited = Duration.zero
            var started: Set<Need> = []
            for step in place.ladder(on: platform) {
                guard (try? await sleep(step.after - waited)) != nil, !Task.isCancelled else { return }
                waited = step.after
                let interest = Interest(at: place, step.likelihood)
                let needs = Self.needs(target, step.likelihood).filter { started.insert($0).inserted }
                group.addTask { await self.run(needs, for: target, interest) }
            }
        }
    }

    private func run(_ needs: [Need], for target: Target, _ interest: Interest) async {
        await withTaskGroup(of: Void.self) { group in
            if needs.contains(.page) { group.addTask { await self.work.page(target, interest) } }
            let playing = needs.filter { $0 != .page }
            guard !playing.isEmpty, let plan = await work.plan(target, interest) else { return }
            for need in playing { group.addTask { await self.prepare(need, of: plan, interest) } }
        }
    }

    private func prepare(_ need: Need, of plan: EmbyPlayback, _ interest: Interest) async {
        switch need {
        case .fileStart: await work.fileStart(plan, interest)
        case .connection: await work.connection(plan, interest)
        case .subtitleFile, .subtitleCopy:
            guard let likely = plan.likelySubtitle, (likely.kind == .beside) == (need == .subtitleFile) else { return }
            await work.subtitle(likely, interest)
        case .previews: await work.previews(plan, interest)
        case .page, .plan: break
        }
    }
}

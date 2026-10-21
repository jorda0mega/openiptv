import Foundation

/// What a screen shows that may be opened next.
enum Target: Hashable, Sendable {
    /// A poster: a tap opens its page.
    case title(id: String, kind: String)
    /// A tap plays it (Continue Watching, a page's Play).
    case playable(id: String, kind: String?)
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

    /// iPhone: on screen at least 60 %. Apple TV: in focus. A fast scroll or
    /// a sweep across posters never reaches the first step.
    func ladder(on platform: Platform) -> [Step] {
        func step(_ after: Duration, _ likelihood: Likelihood) -> Step { Step(after: after, likelihood: likelihood) }
        switch (self, platform) {
        case (.continueWatching, .phone): return [step(.milliseconds(600), .likely), step(.seconds(2), .next)]
        case (.continueWatching, .tv), (.episodeRow, .tv): return [step(.milliseconds(150), .likely), step(.milliseconds(400), .next)]
        case (.episodeRow, .phone): return [step(.milliseconds(600), .glance), step(.seconds(2), .likely)]
        case (.posterRow, .phone), (.grid, .phone), (.moreLikeThis, .phone), (.person, .phone), (.searchResult, .phone):
            return [step(.milliseconds(600), .glance)]
        case (.posterRow, .tv), (.grid, .tv), (.moreLikeThis, .tv), (.person, .tv), (.searchResult, .tv):
            return [step(.milliseconds(150), .glance), step(.seconds(1), .likely)]
        case (.searchTop, _): return [step(.zero, .likely)]
        case (.hero, .phone): return [step(.seconds(1), .likely)]
        case (.hero, .tv): return [step(.milliseconds(400), .next)]
        case (.page, _): return [step(.zero, .next)]
        case (.homeForecast, _): return [step(.zero, .likely)]
        case (.upNext, _): return [step(.zero, .glance)]
        case (.liveRow, _): return [step(.milliseconds(250), .likely)]
        case (.liveLookahead, _): return [step(.milliseconds(500), .glance)]
        }
    }
}

/// What a target gets ready. A higher likelihood only adds, and the work
/// for playing waits for the plan.
enum Need: Hashable, Sendable {
    case page
    case plan
    /// The file's start at the resume point (or at 0), in the relay's cache.
    case fileStart
    /// The likeliest subtitles, when they are a file beside the film.
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
        var subtitle: @MainActor (ServerSubtitle, Interest) async -> Void
        var previews: @MainActor (EmbyPlayback, Interest) async -> Void
    }

    private let work: Work
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
        case (.playable, .likely): [.plan, .fileStart, .subtitleFile]
        case (.playable, .next): [.plan, .fileStart, .subtitleFile, .subtitleCopy, .previews]
        }
    }

    /// Climbs the place's ladder while the caller's task lives; what hasn't
    /// started stops when it ends (the target left the screen or focus).
    func holding(_ target: Target, at place: Place) async {
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
        case .subtitleFile, .subtitleCopy:
            guard let likely = plan.likelySubtitle, (likely.kind == .beside) == (need == .subtitleFile) else { return }
            await work.subtitle(likely, interest)
        case .previews: await work.previews(plan, interest)
        case .page, .plan: break
        }
    }
}

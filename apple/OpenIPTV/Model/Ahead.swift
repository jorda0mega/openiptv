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

/// How much of each card shows on screen: on a phone network under 150 MB
/// a day only the most shown, at any place, counts as rested on.
@MainActor
final class Showing {
    private struct Card: Hashable {
        let target: Target
        let place: Place
    }

    private struct Shown {
        var share: Double
        var origin: CGPoint

        /// Less shown, or as much and later in reading order.
        func showsLess(than other: Shown) -> Bool {
            let (mine, theirs) = ((share * 100).rounded(), (other.share * 100).rounded())
            if mine != theirs { return mine < theirs }
            return origin.y != other.origin.y ? origin.y > other.origin.y : origin.x > other.origin.x
        }
    }

    private var shown: [Card: Shown] = [:]
    private var mostShown: Card?
    private var waiting: [UUID: (card: Card, turn: CheckedContinuation<Bool, Never>)] = [:]

    func show(_ target: Target, at place: Place, share: Double, from origin: CGPoint) {
        shown[Card(target: target, place: place)] = Shown(share: share, origin: origin)
        wake()
    }

    func hide(_ target: Target, at place: Place) {
        shown[Card(target: target, place: place)] = nil
        wake()
    }

    func isMostShown(_ target: Target, at place: Place) -> Bool {
        isMostShown(Card(target: target, place: place))
    }

    /// False when cancelled first.
    func untilMostShown(_ target: Target, at place: Place) async -> Bool {
        let card = Card(target: target, place: place)
        if isMostShown(card) { return true }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { turn in waiting[id] = (card, turn) }
        } onCancel: {
            Task { @MainActor in self.waiting.removeValue(forKey: id)?.turn.resume(returning: false) }
        }
    }

    /// Nothing measured (an Apple TV's focus): each card held is rested on.
    private func isMostShown(_ card: Card) -> Bool {
        shown.isEmpty || mostShown == card
    }

    /// A card that lost the place stops what it fetched under way.
    private func wake() {
        let now = shown.max { $0.value.showsLess(than: $1.value) }?.key
        if now != mostShown {
            mostShown = now
            Lane.conditionsChangedEverywhere()
        }
        for (id, waiter) in waiting where isMostShown(waiter.card) {
            waiting[id] = nil
            waiter.turn.resume(returning: true)
        }
    }
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
    private(set) var planless = 0
    private(set) var trail: [String: Int] = [:]
    private func note(_ place: Place, _ event: String) { trail["\(place) \(event)", default: 0] += 1 }
    #endif
    let showing = Showing()
    private var kept: [Target: (mark: UUID, task: Task<Void, Never>)] = [:]
    private let platform: Platform
    private let sleep: @Sendable (Duration) async throws -> Void
    private let restsOnOneCard: @MainActor () -> Bool

    init(_ work: Work, platform: Platform = .current,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         restsOnOneCard: @escaping @MainActor () -> Bool = { Conditions.current().restsOnOneCard }) {
        self.work = work
        self.platform = platform
        self.sleep = sleep
        self.restsOnOneCard = restsOnOneCard
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

    func hold(only targets: [Target], at place: Place) {
        for (target, held) in kept where !targets.contains(target) {
            held.task.cancel()
            kept[target] = nil
        }
        for target in targets where kept[target] == nil {
            let mark = UUID()
            kept[target] = (mark, Task(priority: .utility) { [weak self] in
                await self?.holding(target, at: place)
                if self?.kept[target]?.mark == mark { self?.kept[target] = nil }
            })
        }
    }

    func holding(_ target: Target, at place: Place) async {
        #if DEBUG
        held += 1
        note(place, "began")
        defer { note(place, "ended") }
        #endif
        await withTaskGroup(of: Void.self) { group in
            var waited = Duration.zero
            var started: Set<Need> = []
            for step in place.ladder(on: platform) {
                guard (try? await sleep(step.after - waited)) != nil, !Task.isCancelled else { return }
                #if DEBUG
                note(place, "\(step.likelihood)")
                #endif
                waited = step.after
                if place.isRestedOn(at: step.likelihood, on: platform), restsOnOneCard() {
                    guard await showing.untilMostShown(target, at: place) else { return }
                }
                let interest = Interest(at: place, step.likelihood) { [showing] in showing.isMostShown(target, at: place) }
                let needs = Self.needs(target, step.likelihood).filter { started.insert($0).inserted }
                group.addTask { await self.run(needs, for: target, interest) }
            }
        }
    }

    private func run(_ needs: [Need], for target: Target, _ interest: Interest) async {
        await withTaskGroup(of: Void.self) { group in
            if needs.contains(.page) { group.addTask { await self.work.page(target, interest) } }
            let playing = needs.filter { $0 != .page }
            guard !playing.isEmpty else { return }
            guard let plan = await work.plan(target, interest) else {
                #if DEBUG
                planless += 1
                note(interest.place, Task.isCancelled ? "no plan, ended" : "no plan")
                #endif
                return
            }
            #if DEBUG
            note(interest.place, "planned")
            #endif
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

enum FirstPicture: Equatable {
    case still(at: Double)
    case backdrop
}

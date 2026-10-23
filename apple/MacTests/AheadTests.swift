import XCTest
@testable import OpenIPTV

@MainActor
final class AheadTests: XCTestCase {
    private final class Screen: @unchecked Sendable {
        private let lock = NSLock()
        private var elapsed = Duration.zero
        private let stays: Duration

        init(stays: Duration) { self.stays = stays }

        func sleep(_ duration: Duration) async throws {
            let within = lock.withLock { () -> Bool in
                elapsed += duration
                return elapsed <= stays
            }
            if within { return }
            try await Task.sleep(for: .seconds(3600))
        }
    }

    @MainActor
    private final class Server {
        var asked: [String] = []
        var plan: EmbyPlayback?
        var holdFileStart = false
        var stopped: [String] = []

        var work: Ahead.Work {
            Ahead.Work(
                page: { [unowned self] _, _ in asked.append("page") },
                plan: { [unowned self] _, _ in
                    asked.append("plan")
                    return plan
                },
                fileStart: { [unowned self] _, _ in
                    asked.append("file start")
                    guard holdFileStart else { return }
                    do { try await Task.sleep(for: .seconds(3600)) } catch { stopped.append("file start") }
                },
                connection: { [unowned self] _, _ in asked.append("connection") },
                subtitle: { [unowned self] subtitle, _ in asked.append(subtitle.kind == .beside ? "subtitle file" : "subtitle copy") },
                previews: { [unowned self] _, _ in asked.append("previews") })
        }
    }

    private func film(saved: (language: String?, role: String?)? = nil, audio: String = "eng") -> EmbyPlayback {
        var playback = EmbyPlayback(itemId: "m5", title: "Movie 5", subtitle: nil, url: URL(string: "http://server/Videos/m5/stream")!,
                                    durationSeconds: 7200)
        let key = UUID().uuidString
        if let saved { TrackChoice.rememberSubtitles(saved.language, role: saved.role, for: key) }
        playback.tracks = TrackChoice.plan(audio: [audio], countries: [], key: key)
        func subtitle(_ index: Int, _ kind: ServerSubtitle.Kind) -> ServerSubtitle {
            ServerSubtitle(address: URL(string: "http://server/Videos/m5/ms-m5/Subtitles/\(index)/Stream.srt")!, token: "tok",
                           kind: kind, version: "v")
        }
        playback.subtitleCopies = [.init(streamIndex: 3, subtitle: subtitle(3, .inFile), language: "spa"),
                                   .init(streamIndex: 4, subtitle: subtitle(4, .inFile), language: "eng")]
        playback.subtitleFiles = [.init(source: .server(subtitle(100, .beside)), language: "eng", title: "SDH")]
        return playback
    }

    private func settle() async {
        for _ in 0..<50 { await Task.yield() }
    }

    private func asked(_ target: Target, at place: Place, on platform: Platform = .phone, stays: Duration,
                       plan: EmbyPlayback? = nil) async -> [String] {
        let server = Server()
        server.plan = plan ?? film()
        let ahead = Ahead(server.work, platform: platform, sleep: Screen(stays: stays).sleep)
        let held = Task { await ahead.holding(target, at: place) }
        await settle()
        held.cancel()
        await held.value
        return server.asked
    }

    private let card = Target.playable(id: "m5", kind: "Movie")

    func testAFastScrollPastACardAsksNothing() async {
        let asked = await asked(card, at: .continueWatching, stays: .milliseconds(400))
        XCTAssertEqual(asked, [])
    }

    func testACardOnScreenPastItsDwellGetsItsPlanThenItsStartAndSubtitles() async {
        let asked = await asked(card, at: .continueWatching, stays: .seconds(1))
        XCTAssertEqual(asked.first, "plan")
        XCTAssertEqual(Set(asked.dropFirst()), ["file start", "connection"],
                       "an English film's likely subtitles are its own track: a copy, later")
    }

    func testALongDwellAddsTheHeavierWork() async {
        let asked = await asked(card, at: .continueWatching, stays: .seconds(3))
        XCTAssertEqual(Set(asked), ["plan", "file start", "connection", "subtitle copy", "previews"])
    }

    func testAppleTVFocusClimbsFaster() async {
        let asked = await asked(card, at: .continueWatching, on: .tv, stays: .milliseconds(500))
        XCTAssertEqual(Set(asked), ["plan", "file start", "connection", "subtitle copy", "previews"])
    }

    func testAFileBesideTheFilmIsFetchedAtTheFirstStep() async {
        let asked = await asked(card, at: .continueWatching, stays: .seconds(1), plan: film(saved: ("eng", "sdh")))
        XCTAssertEqual(Set(asked), ["plan", "file start", "connection", "subtitle file"])
    }

    func testTheLikeliestSubtitlesAreThePick() {
        func likely(_ playback: EmbyPlayback) -> String? {
            playback.likelySubtitle.map { $0.kind == .beside ? "file" : $0.address.pathComponents[5] }
        }
        XCTAssertEqual(likely(film()), "4", "an English film: its own English track")
        XCTAssertEqual(likely(film(saved: ("spa", nil))), "3", "picked Spanish for the title")
        XCTAssertEqual(likely(film(saved: (nil, nil))), "4", "turned off for the title: on again, in its language")
        XCTAssertEqual(likely(film(saved: ("eng", "sdh"))), "file", "picked the SDH file")
        XCTAssertEqual(likely(film(audio: "fre")), "4", "a French film: English")
        XCTAssertEqual(likely(film(audio: "spa")), "3", "a Spanish film: Spanish")
    }

    func testNothingButThePlanWithoutOne() async {
        let server = Server()
        let ahead = Ahead(server.work, platform: .phone, sleep: Screen(stays: .seconds(3)).sleep)
        await ahead.holding(card, at: .continueWatching)
        XCTAssertEqual(server.asked, ["plan", "plan"])
    }

    func testAPosterGlancedAtGetsItsPageOnly() async {
        let asked = await asked(.title(id: "m5", kind: "Movie"), at: .posterRow, stays: .seconds(5))
        XCTAssertEqual(asked, ["page"])
    }

    func testLeavingStopsWhatIsUnderWay() async {
        let server = Server()
        server.plan = film()
        server.holdFileStart = true
        let ahead = Ahead(server.work, platform: .phone, sleep: Screen(stays: .seconds(1)).sleep)
        let held = Task { await ahead.holding(card, at: .continueWatching) }
        await settle()
        held.cancel()
        await held.value
        XCTAssertEqual(server.stopped, ["file start"])
    }

    func testAShowPagePreparesWhatItsPlayPlays() {
        XCTAssertEqual(Target.showMain("s1", upNext: "e203"), .playable(id: "e203", kind: "Episode"))
        XCTAssertEqual(Target.showMain("s1", upNext: nil), .playable(id: "s1", kind: "Series"))
    }

    func testAFileStartStoppedShortIsFetchedAgain() async {
        final class Starts: @unchecked Sendable {
            let lock = NSLock()
            var asked = 0
            var completes: Bool
            init(completes: Bool) { self.completes = completes }
        }
        let starts = Starts(completes: false)
        let open = Conditions(network: .unmetered, playing: false, lowPower: false, thermal: .nominal, memoryWarned: false,
                              freeDisk: 10_000_000_000)
        let shelf = FileStarts.shelf(lane: Lane(.bytes, atOnce: 2) { open }) { _ in
            starts.lock.withLock {
                starts.asked += 1
                return starts.completes
            }
        }
        let start = FileStart(film())
        let interest = Interest(at: .continueWatching, .likely)
        let stoppedShort = await shelf.warm(start, for: interest)
        starts.lock.withLock { starts.completes = true }
        let fetched = await shelf.warm(start, for: interest)
        let kept = await shelf.warm(start, for: interest)
        XCTAssertNil(stoppedShort)
        XCTAssertEqual(fetched, true)
        XCTAssertEqual(kept, true)
        XCTAssertEqual(starts.lock.withLock { starts.asked }, 2, "a start stopped short was kept as done, or a done one fetched again")
    }

    func testARefusedFileStartSaysWhichConditionRefusedIt() async {
        var full = conditions(playing: false)
        full.freeDisk = 1_234_000_000
        let shelf = FileStarts.shelf(lane: Lane(.bytes, atOnce: 2) { [full] in full }) { _ in true }
        let start = FileStart(film())
        let fetched = await shelf.warm(start, for: Interest(at: .continueWatching, .likely))
        XCTAssertNil(fetched)
        XCTAssertEqual(shelf.debugState(start, at: .continueWatching), "not asked, not allowed now: disk 1.2 GB, needs 2.0 GB")
    }

    private final class Pings: @unchecked Sendable {
        private let lock = NSLock()
        private var made = 0
        var count: Int { lock.withLock { made } }
        func ping(_ file: FileStart) async { lock.withLock { made += 1 } }
    }

    private func conditions(playing: Bool) -> Conditions {
        Conditions(network: .unmetered, playing: playing, lowPower: false, thermal: .nominal, memoryWarned: false, freeDisk: 10_000_000_000)
    }

    func testALikelyCardKeepsTheConnectionPlaybackUsesOpenTillItGoes() async {
        let pings = Pings(), open = conditions(playing: false), screen = Screen(stays: .seconds(25))
        let warm = Task {
            await Connections.keepWarm(FileStart(film()), for: Interest(at: .continueWatching, .likely), lane: Lane(.light, atOnce: 1) { open },
                                       every: .seconds(10), sleep: screen.sleep, ping: pings.ping)
        }
        await settle()
        XCTAssertEqual(pings.count, 3, "opened at once, and used again every 10 s while on screen for 25 s")
        warm.cancel()
        await warm.value
        await settle()
        XCTAssertEqual(pings.count, 3, "used again after the card went")
    }

    func testNoConnectionIsKeptOpenWhileSomethingPlays() async {
        let pings = Pings(), playing = conditions(playing: true)
        await Connections.keepWarm(FileStart(film()), for: Interest(at: .continueWatching, .likely), lane: Lane(.light, atOnce: 1) { playing },
                                   every: .seconds(10), sleep: Screen(stays: .seconds(60)).sleep, ping: pings.ping)
        XCTAssertEqual(pings.count, 0)
    }

    func testEachLikelihoodOnlyAdds() {
        for target in [card, .title(id: "m5", kind: "Movie")] {
            let ladder = [Likelihood.glance, .likely, .next].map { Set(Ahead.needs(target, $0)) }
            XCTAssertTrue(ladder[0].isSubset(of: ladder[1]) && ladder[1].isSubset(of: ladder[2]), "\(target)")
        }
        XCTAssertEqual(Ahead.needs(card, .glance), [.plan])
        XCTAssertEqual(Ahead.needs(card, .likely), [.plan, .fileStart, .connection, .subtitleFile])
        XCTAssertEqual(Ahead.needs(card, .next), [.plan, .fileStart, .connection, .subtitleFile, .subtitleCopy, .previews])
        XCTAssertEqual(Ahead.needs(.title(id: "m5", kind: "Movie"), .glance), [.page])
        XCTAssertEqual(Ahead.needs(.title(id: "m5", kind: "Movie"), .likely), [.page, .plan, .subtitleFile])
    }

    func testDwellTimes() {
        typealias Step = Place.Step
        XCTAssertEqual(Place.continueWatching.ladder(on: .phone), [Step(after: .milliseconds(600), likelihood: .likely),
                                                                   Step(after: .seconds(2), likelihood: .next)])
        XCTAssertEqual(Place.continueWatching.ladder(on: .tv), [Step(after: .milliseconds(150), likelihood: .likely),
                                                                Step(after: .milliseconds(400), likelihood: .next)])
        XCTAssertEqual(Place.posterRow.ladder(on: .phone), [Step(after: .milliseconds(600), likelihood: .glance)])
        XCTAssertEqual(Place.posterRow.ladder(on: .tv), [Step(after: .milliseconds(150), likelihood: .glance),
                                                         Step(after: .seconds(1), likelihood: .likely)])
        for place in [Place.posterRow, .grid, .moreLikeThis, .person, .searchResult, .searchTop, .continueWatching, .hero, .episodeRow,
                      .page, .upNext, .homeForecast, .liveRow, .liveLookahead] {
            for platform in [Platform.phone, .tv] {
                let ladder = place.ladder(on: platform)
                XCTAssertEqual(ladder, ladder.sorted { $0.after < $1.after }, "\(place) \(platform)")
                XCTAssertEqual(ladder.map(\.likelihood), ladder.map(\.likelihood).sorted(), "\(place) \(platform)")
            }
        }
    }
}

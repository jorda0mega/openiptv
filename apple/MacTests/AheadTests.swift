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

    @MainActor
    private final class Rests {
        var started: [String] = []
        let ahead: Ahead

        init(oneCard: Bool) {
            var rests: Rests?
            ahead = Ahead(Ahead.Work(page: { _, _ in }, plan: { target, _ in
                guard case let .playable(id, _) = target else { return nil }
                return EmbyPlayback(itemId: id, title: id, subtitle: nil, url: URL(string: "http://server/Videos/\(id)/stream")!,
                                    durationSeconds: 7200)
            }, fileStart: { plan, _ in rests?.started.append(plan.itemId) }, connection: { _, _ in }, subtitle: { _, _ in },
            previews: { _, _ in }), platform: .phone, sleep: { if $0 > .seconds(1) { try await Task.sleep(for: .seconds(3600)) } },
            restsOnOneCard: { oneCard })
            rests = self
        }

        func hold(_ cards: [(id: String, share: Double, x: Double, y: Double)], at place: Place = .continueWatching) -> [String: Task<Void, Never>] {
            var held: [String: Task<Void, Never>] = [:]
            for card in cards {
                let target = Target.playable(id: card.id, kind: "Movie")
                ahead.showing.show(target, at: place, share: card.share, from: CGPoint(x: card.x, y: card.y))
                held[card.id] = Task { await ahead.holding(target, at: place) }
            }
            return held
        }

        func leave(_ id: String, _ held: Task<Void, Never>?, at place: Place = .continueWatching) {
            held?.cancel()
            ahead.showing.hide(.playable(id: id, kind: "Movie"), at: place)
        }
    }

    func testOnAPhoneNetworkADayOnlyTheMostShownCardIsRestedOn() async {
        let rests = Rests(oneCard: true)
        let held = rests.hold([("m1", 1, 20, 300), ("m2", 0.7, 272, 300)])
        await settle()
        XCTAssertEqual(rests.started, ["m1"], "the card 70% on screen beside it got its start too")
        rests.leave("m1", held["m1"])
        await settle()
        XCTAssertEqual(rests.started, ["m1", "m2"], "the card left on screen didn't become the one rested on")
        rests.leave("m2", held["m2"])
        for task in held.values { await task.value }
    }

    func testOnAPhoneNetworkADayATieGoesToTheFirstInReadingOrder() async {
        let rests = Rests(oneCard: true)
        let held = rests.hold([("m2", 1, 272, 300), ("m1", 1, 20, 300), ("m0", 1, 400, 100)])
        await settle()
        XCTAssertEqual(rests.started, ["m0"])
        for (id, task) in held { rests.leave(id, task) }
        for task in held.values { await task.value }
    }

    func testOnAPhoneNetworkADayOneCardOnTheWholeScreenIsRestedOnNotOneAtEachPlace() async {
        let rests = Rests(oneCard: true)
        let hero = rests.hold([("m1", 1, 0, 0)], at: .hero)
        let row = rests.hold([("m2", 1, 20, 500)])
        await settle()
        XCTAssertEqual(rests.started, ["m1"], "the Continue Watching card got its start beside the hero's")
        rests.leave("m1", hero["m1"], at: .hero)
        await settle()
        XCTAssertEqual(rests.started, ["m1", "m2"], "the card left on screen didn't become the one rested on")
        rests.leave("m2", row["m2"])
        for task in Array(hero.values) + Array(row.values) { await task.value }
    }

    /// Cards whose starts go through a lane and a shelf, as in the app, on
    /// a phone network: 150 MB a day (one card) or As on Wi-Fi.
    @MainActor
    private final class Fetching {
        let started = Locked<[String]>([])
        let stopped = Locked<[String]>([])
        let ahead: Ahead
        let shelf: Shelf<String, Int>
        private var planHeld: CheckedContinuation<Void, Never>?

        init(oneCard: Bool, holdingPlanOf held: String? = nil) {
            let device = Conditions(network: .expensive, playing: false, lowPower: false, thermal: .nominal, memoryWarned: false,
                                    freeDisk: .init(bytes: 10_000_000_000, countsPurgeable: true), phoneNetwork: oneCard ? .daily : .wifi)
            let (started, stopped) = (started, stopped)
            let shelf = Shelf<String, Int>(.init(lane: Lane(.bytes, atOnce: 2) { device }, lifetime: .seconds(60))) { id in
                started.mutate { $0.append(id) }
                do { try await Task.sleep(for: .seconds(3600)) } catch {
                    stopped.mutate { $0.append(id) }
                    throw error
                }
                return 0
            }
            self.shelf = shelf
            var fetching: Fetching?
            ahead = Ahead(Ahead.Work(page: { _, _ in }, plan: { target, _ in
                guard case let .playable(id, _) = target else { return nil }
                if id == held { await withCheckedContinuation { fetching?.planHeld = $0 } }
                return EmbyPlayback(itemId: id, title: id, subtitle: nil, url: URL(string: "http://server/Videos/\(id)/stream")!,
                                    durationSeconds: 7200)
            }, fileStart: { plan, interest in _ = await shelf.warm(plan.itemId, for: interest) }, connection: { _, _ in },
            subtitle: { _, _ in }, previews: { _, _ in }), platform: .phone,
            sleep: { if $0 > .seconds(1) { try await Task.sleep(for: .seconds(3600)) } }, restsOnOneCard: { oneCard })
            fetching = self
        }

        func show(_ id: String, share: Double, x: Double) {
            ahead.showing.show(.playable(id: id, kind: "Movie"), at: .continueWatching, share: share, from: CGPoint(x: x, y: 300))
        }

        func hold(_ id: String, share: Double, x: Double) -> Task<Void, Never> {
            show(id, share: share, x: x)
            return Task { await ahead.holding(.playable(id: id, kind: "Movie"), at: .continueWatching) }
        }

        func letPlanGo() {
            planHeld?.resume()
            planHeld = nil
        }

        func leave(_ held: [Task<Void, Never>]) async {
            for task in held { task.cancel() }
            for task in held { await task.value }
            shelf.forgetAll()
        }
    }

    func testOnAPhoneNetworkADayACardNoLongerMostShownWhenItsPlanCameFetchesNothing() async {
        let fetching = Fetching(oneCard: true, holdingPlanOf: "m1")
        let held = [fetching.hold("m1", share: 1, x: 20), fetching.hold("m2", share: 0.7, x: 272)]
        await settle()
        fetching.show("m1", share: 0.65, x: -120)
        fetching.show("m2", share: 1, x: 132)
        await settle()
        fetching.letPlanGo()
        await settle()
        XCTAssertEqual(fetching.started.value, ["m2"], "the card scrolled from fetched its start when its plan came")
        await fetching.leave(held)
    }

    func testOnAPhoneNetworkADayACardNoLongerMostShownStopsItsFetch() async {
        let fetching = Fetching(oneCard: true)
        let held = [fetching.hold("m1", share: 1, x: 20), fetching.hold("m2", share: 0.7, x: 272)]
        await settle()
        fetching.show("m1", share: 0.65, x: -120)
        fetching.show("m2", share: 1, x: 132)
        await settle()
        XCTAssertEqual(fetching.started.value, ["m1", "m2"])
        XCTAssertEqual(fetching.stopped.value, ["m1"], "the card scrolled from went on fetching")
        await fetching.leave(held)
    }

    func testAsOnWiFiACardNoLongerMostShownGoesOnFetching() async {
        let fetching = Fetching(oneCard: false)
        let held = [fetching.hold("m1", share: 1, x: 20), fetching.hold("m2", share: 0.7, x: 272)]
        await settle()
        fetching.show("m1", share: 0.65, x: -120)
        fetching.show("m2", share: 1, x: 132)
        await settle()
        XCTAssertEqual(Set(fetching.started.value), ["m1", "m2"])
        XCTAssertEqual(fetching.stopped.value, [])
        await fetching.leave(held)
    }

    func testOnWiFiEveryCardOnScreenIsRestedOn() async {
        let rests = Rests(oneCard: false)
        let held = rests.hold([("m1", 1, 20, 300), ("m2", 0.7, 272, 300)])
        await settle()
        XCTAssertEqual(Set(rests.started), ["m1", "m2"])
        for (id, task) in held { rests.leave(id, task) }
        for task in held.values { await task.value }
    }

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
                              freeDisk: .init(bytes: 10_000_000_000, countsPurgeable: true))
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
        full.freeDisk.bytes = 1_234_000_000
        let shelf = FileStarts.shelf(lane: Lane(.bytes, atOnce: 2) { [full] in full }) { _ in true }
        let start = FileStart(film())
        let fetched = await shelf.warm(start, for: Interest(at: .continueWatching, .likely))
        XCTAssertNil(fetched)
        XCTAssertEqual(shelf.debugState(start, at: .continueWatching, .likely), "not asked, not allowed now: disk 1.2 GB, needs 2.0 GB")
    }

    func testAnAppleTVNeedsRoomForWhatTheFetchAheadWritesNotTwoGigabytes() async {
        func ahead(_ free: Int64, countsPurgeable: Bool) async -> (fetched: Bool?, state: String) {
            var device = conditions(playing: false)
            device.freeDisk = .init(bytes: free, countsPurgeable: countsPurgeable)
            let shelf = FileStarts.shelf(lane: Lane(.bytes, atOnce: 2) { [device] in device }) { _ in true }
            let start = FileStart(film())
            let fetched = await shelf.warm(start, for: Interest(at: .continueWatching, .likely))
            return (fetched, shelf.debugState(start, at: .continueWatching, .likely))
        }
        let tv = await ahead(1_200_000_000, countsPurgeable: false)
        XCTAssertEqual(tv.fetched, true, "an Apple TV with 1.2 GB free now, its caches not counted, fetched no card ahead")
        let fullTV = await ahead(400_000_000, countsPurgeable: false)
        XCTAssertNil(fullTV.fetched)
        XCTAssertEqual(fullTV.state, "not asked, not allowed now: disk 0.4 GB, needs 0.5 GB")
        let phone = await ahead(1_200_000_000, countsPurgeable: true)
        XCTAssertNil(phone.fetched, "a phone fetched ahead with under 2 GB of room for important use")
    }

    func testLowDiskRefusesAFileStartAheadThatWouldGoWithoutIt() async {
        let open = conditions(playing: false)
        let shelf = FileStarts.shelf(lane: Lane(.bytes, atOnce: 2) { [open] in open.forFetchAhead }) { _ in true }
        let start = FileStart(film()), interest = Interest(at: .continueWatching, .likely)
        UserDefaults.standard.set(true, forKey: "lowDisk")
        defer { UserDefaults.standard.removeObject(forKey: "lowDisk") }
        let refused = await shelf.warm(start, for: interest)
        let state = shelf.debugState(start, at: .continueWatching, .likely)
        UserDefaults.standard.removeObject(forKey: "lowDisk")
        let fetched = await shelf.warm(start, for: interest)
        XCTAssertNil(refused, "fetched ahead with -lowDisk YES")
        XCTAssertEqual(state, "not asked, not allowed now: disk 1.0 GB, needs 2.0 GB")
        XCTAssertEqual(fetched, true, "not fetched ahead without -lowDisk")
    }

    private final class Pings: @unchecked Sendable {
        private let lock = NSLock()
        private var made = 0
        var count: Int { lock.withLock { made } }
        func ping(_ file: FileStart) async { lock.withLock { made += 1 } }
    }

    private func conditions(playing: Bool) -> Conditions {
        Conditions(network: .unmetered, playing: playing, lowPower: false, thermal: .nominal, memoryWarned: false,
                   freeDisk: .init(bytes: 10_000_000_000, countsPurgeable: true))
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

    private func pings(over device: Conditions, at place: Place = .continueWatching) async -> Int {
        let pings = Pings()
        let warm = Task {
            await Connections.keepWarm(FileStart(film()), for: Interest(at: place, .likely), lane: Lane(Lane.connections.weight, atOnce: 1) { device },
                                       every: .seconds(10), sleep: Screen(stays: .seconds(25)).sleep, ping: pings.ping)
        }
        await settle()
        warm.cancel()
        await warm.value
        return pings.count
    }

    func testOnAPhoneNetworkTheConnectionIsKeptOpenOnlyAsTheChoiceSays() async {
        func phone(_ choice: PhoneNetworkFilms, used: Int64 = 0, _ network: Conditions.Network = .expensive) -> Conditions {
            var device = conditions(playing: false)
            (device.network, device.phoneNetwork, device.usedToday) = (network, choice, used)
            return device
        }
        let none = await pings(over: phone(.none))
        let usedUp = await pings(over: phone(.daily, used: PhoneNetworkFilms.dailyBytes))
        let lowData = await pings(over: phone(.wifi, .constrained))
        let forecast = await pings(over: phone(.daily), at: .homeForecast)
        let daily = await pings(over: phone(.daily))
        let asOnWiFi = await pings(over: phone(.wifi))
        let onWiFi = await pings(over: phone(.none, .unmetered))
        XCTAssertEqual(none, 0, "None")
        XCTAssertEqual(usedUp, 0, "today's 150 MB used")
        XCTAssertEqual(lowData, 0, "Low Data Mode")
        XCTAssertEqual(forecast, 0, "150 MB a day, a row's forecast")
        XCTAssertEqual(daily, 3, "150 MB a day, the card rested on")
        XCTAssertEqual(asOnWiFi, 3, "As on Wi-Fi")
        XCTAssertEqual(onWiFi, 3, "Wi-Fi, whatever the choice")
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

import XCTest
@testable import OpenIPTV

/// Watch On: what each channel showing a game says about its feed, and
/// which plays first.
final class WatchOnTests: XCTestCase {
    /// Names from a real provider's lineup.
    func testLanguageFromTheName() {
        XCTAssertEqual(WatchOn.language(in: "ESPN UNLTD 016: Football: Eagles vs. Jaguars (Eagles vs. Jaguars (ESP)) (10.11 09:30 AM ET)"), "es")
        XCTAssertEqual(WatchOn.language(in: "DAZN CA 58: Ravens @ Falcons (Spanish Broadcast) @ 11 Oct 07:20 PM ET"), "es")
        XCTAssertEqual(WatchOn.language(in: "ESPN+ 03: En Español-Elche CF vs. Celta de Vigo @ Oct 11 8:00AM ET"), "es")
        XCTAssertEqual(WatchOn.language(in: "Soccer04: Barcelona vs Paris FC ( ESPN Deportes USA Feed ) @ 3:00 pm"), "es")
        XCTAssertEqual(WatchOn.language(in: "DAZN CA 19: Eagles vs. Jaguars (In French) @ 11 Oct 08:30 AM ET"), "fr")
        // The main commentary, and teams named like Spanish networks.
        XCTAssertNil(WatchOn.language(in: "ESPN UNLTD 015: Football: Eagles vs. Jaguars (10.11 09:30 AM ET)"))
        XCTAssertNil(WatchOn.language(in: "ESPN UNLTD 157: Spanish LALIGA: Racing vs. Valencia (10.11 02:50 PM ET)"))
        XCTAssertNil(WatchOn.language(in: "(Fanatiz 049) | Águilas Doradas vs Deportes Tolima (2026-10-18 15:00:00)"))
        XCTAssertNil(WatchOn.language(in: "(Fanatiz 013) | Valdivia vs Español Osorno (2026-10-11 19:00:00)"))
        XCTAssertNil(WatchOn.language(in: "ESPN UNLTD 020: ESPN2: Eagles vs. Jaguars"))
    }

    /// The marker goes from the game's name, so both languages are one game.
    func testMarkerLeavesTheName() {
        XCTAssertEqual(WatchOn.withoutLanguage("Eagles vs. Jaguars (In French)").title, "Eagles vs. Jaguars")
        XCTAssertEqual(WatchOn.withoutLanguage("Football: Eagles vs. Jaguars (Eagles vs. Jaguars (ESP))").title,
                       "Football: Eagles vs. Jaguars (Eagles vs. Jaguars)")
        XCTAssertEqual(WatchOn.withoutLanguage("En Español-Real Betis vs. CA Osasuna").title, "Real Betis vs. CA Osasuna")
        XCTAssertEqual(WatchOn.withoutLanguage("Racing vs. Valencia").title, "Racing vs. Valencia")
        XCTAssertNil(WatchOn.withoutLanguage("Racing vs. Valencia").language)
    }

    func testLanguageToHear() {
        XCTAssertEqual(WatchOn.preferredLanguage(league: "La Liga", title: "Racing vs. Valencia"), "es")
        XCTAssertEqual(WatchOn.preferredLanguage(league: "Soccer", title: "Liga MX: América vs. Chivas"), "es")
        XCTAssertNil(WatchOn.preferredLanguage(league: "NFL", title: "Eagles vs. Jaguars"))
        XCTAssertNil(WatchOn.preferredLanguage(league: "Premier League", title: "Arsenal vs. Chelsea"))
        XCTAssertEqual(WatchOn.language(ofRegion: "MX"), "es")
        XCTAssertNil(WatchOn.language(ofRegion: "CA"))
    }

    func testPicture() {
        XCTAssertEqual(WatchOn.quality(of: "US: ESPN FHD").label, "HD")
        XCTAssertEqual(WatchOn.quality(of: "US: ESPN 4K").label, "4K")
        XCTAssertEqual(WatchOn.quality(of: "NFL SD 01: Eagles vs. Jaguars").label, "SD")
        XCTAssertNil(WatchOn.quality(of: "NFL 01: Eagles vs. Jaguars").label)
        XCTAssertGreaterThan(WatchOn.quality(of: "ESPN FHD").score, WatchOn.quality(of: "ESPN").score)
        XCTAssertLessThan(WatchOn.quality(of: "ESPN BACKUP").score, WatchOn.quality(of: "LBW ESPN").score)
    }

    private func option(_ id: String, _ service: String, _ language: String? = nil, quality: Int = 4) -> WatchOn.Option {
        WatchOn.Option(id: id, feed: WatchOn.Feed(service: service, language: language), quality: quality)
    }

    private let game = [("nfl", "NFL", nil as String?), ("espn", "ESPN Unlimited", nil), ("espn-es", "ESPN Unlimited", "es"),
                        ("dazn", "DAZN CA", nil), ("dazn-fr", "DAZN CA", "fr")]

    private func ranked(pick: WatchOn.Pick? = nil, preferred: String? = nil, failed: Set<String> = [],
                        quality: [String: Int] = [:]) -> [String] {
        WatchOn.ranked(game.map { option($0.0, $0.1, $0.2, quality: quality[$0.0] ?? 4) },
                       pick: pick, preferred: preferred, failed: failed).map(\.id)
    }

    /// Nothing picked: the main commentary, the better picture, as listed.
    func testFirstPlays() {
        XCTAssertEqual(ranked(), ["nfl", "espn", "dazn", "espn-es", "dazn-fr"])
        XCTAssertEqual(ranked(quality: ["dazn": 6]), ["dazn", "nfl", "espn", "espn-es", "dazn-fr"])
        // A Spanish-made game: Spanish first.
        XCTAssertEqual(ranked(preferred: "es"), ["espn-es", "nfl", "espn", "dazn", "dazn-fr"])
    }

    /// The league's pick plays first: its service in its language, then
    /// that language elsewhere, then that service.
    func testPickedForTheLeague() {
        XCTAssertEqual(ranked(pick: .init(service: "ESPN Unlimited", language: "es")), ["espn-es", "espn", "nfl", "dazn", "dazn-fr"])
        XCTAssertEqual(ranked(pick: .init(service: "DAZN CA", language: nil)), ["dazn", "nfl", "espn", "dazn-fr", "espn-es"])
        // Picked in English: a service now only in Spanish comes after English ones.
        let spanishOnly = [option("espn-es", "ESPN Unlimited", "es"), option("nfl", "NFL")]
        XCTAssertEqual(WatchOn.ranked(spanishOnly, pick: .init(service: "ESPN Unlimited", language: nil), preferred: nil, failed: []).map(\.id),
                       ["nfl", "espn-es"])
    }

    /// One that wouldn't start lately goes last, even when picked.
    func testFailedLately() {
        XCTAssertEqual(ranked(failed: ["nfl"]), ["espn", "dazn", "espn-es", "dazn-fr", "nfl"])
        XCTAssertEqual(ranked(pick: .init(service: "DAZN CA", language: nil), failed: ["dazn"]).first, "nfl")
    }

    /// One feed listed on two channels (the user's "Football · Soccer, OneSoccer
    /// Feed" twice): one entry, the second kept to fall back to.
    func testSameFeedTwiceIsOneEntry() {
        let feed = WatchOn.Feed(service: "Football · Soccer", detail: "OneSoccer Feed")
        let options = [WatchOn.Option(id: "a", feed: feed, quality: 4), option("b", "ESPN Unlimited"),
                       WatchOn.Option(id: "c", feed: feed, quality: 4), WatchOn.Option(id: "d", feed: feed, quality: 6)]
        let grouped = WatchOn.grouped(options)
        XCTAssertEqual(grouped.map(\.option.id), ["a", "b", "d"], "the same feed in the same picture twice")
        XCTAssertEqual(grouped[0].others.map(\.id), ["c"])
    }

    /// Named by the network when the category only names a sport.
    func testNamedByTheNetwork() {
        let generic = WatchOn.label(.init(service: "Football · Soccer", detail: "OneSoccer Feed"), quality: nil)
        XCTAssertEqual(generic.title, "OneSoccer")
        XCTAssertEqual(generic.line, "Football · Soccer")
        let spanish = WatchOn.label(.init(service: "Soccer", detail: "ESPN Deportes USA Feed", language: "es"), quality: "HD")
        XCTAssertEqual(spanish.title, "ESPN Deportes USA")
        XCTAssertEqual(spanish.line, "Soccer · Spanish · HD")
        // A service keeps its name; its feed is the line under it.
        let service = WatchOn.label(.init(service: "ESPN Unlimited", detail: "Senators Broadcast"), quality: nil)
        XCTAssertEqual(service.title, "ESPN Unlimited")
        XCTAssertEqual(service.line, "Senators Broadcast")
        XCTAssertFalse(WatchOn.isGeneric("FloSports"))
        XCTAssertTrue(WatchOn.isGeneric("NFL"))
        // A sport category with no feed named keeps its name.
        XCTAssertEqual(WatchOn.label(.init(service: "NFL"), quality: nil).title, "NFL")
    }
}

final class WatchOnMoveTests: XCTestCase {
    private struct Copy: Identifiable, Equatable { let id: String }

    private func next(after picked: String, tried: Set<String>) -> String? {
        let feeds = [["nfl"], ["espn-es", "espn-es2"], ["dazn"]].map { $0.map(Copy.init) }
        return WatchOn.next(after: picked, feeds: feeds, tried: tried)?.id
    }

    func testNextTriesThePickedFeedFirst() {
        XCTAssertEqual(next(after: "espn-es", tried: ["espn-es"]), "espn-es2")
        XCTAssertEqual(next(after: "espn-es", tried: ["espn-es", "espn-es2"]), "nfl")
        XCTAssertEqual(next(after: "espn-es", tried: ["espn-es", "espn-es2", "nfl"]), "dazn")
        XCTAssertEqual(next(after: "nfl", tried: ["nfl"]), "espn-es")
        XCTAssertNil(next(after: "nfl", tried: ["nfl", "espn-es", "espn-es2", "dazn"]))
    }

    func testNames() {
        XCTAssertEqual(WatchOn.name(.init(service: "NFL")), "NFL")
        XCTAssertEqual(WatchOn.name(.init(service: "ESPN Unlimited", language: "es")), "ESPN Unlimited (Spanish)")
        XCTAssertEqual(WatchOn.name(.init(service: "Football · Soccer", detail: "OneSoccer Feed")), "OneSoccer")
        XCTAssertEqual(WatchOn.switchSentence(from: "ESPN Unlimited (Spanish)", to: nil), "ESPN Unlimited (Spanish) didn’t play. Switching.")
        XCTAssertEqual(WatchOn.switchSentence(from: "ESPN Unlimited (Spanish)", to: "NFL"), "ESPN Unlimited (Spanish) didn’t play. Now on NFL.")
        XCTAssertEqual(WatchOn.switchSentence(from: "OneSoccer", to: "OneSoccer"), "OneSoccer didn’t play. Now on another OneSoccer channel.")
    }
}

final class LiveFailuresTests: XCTestCase {
    private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    func testChannelMarkLastsTenMinutes() {
        var failures = LiveFailures()
        failures.note("a", at: at(0))
        XCTAssertTrue(failures.contains("a", at: at(599)))
        XCTAssertFalse(failures.contains("a", at: at(600)), "the mark outlived 10 min")
        failures.note("a", at: at(300))
        XCTAssertTrue(failures.contains("a", at: at(600)), "a later failure ended with the first")
        XCTAssertEqual(failures.played("a")?.noted, at(300))
        XCTAssertFalse(failures.contains("a", at: at(301)), "still failed after it played")
        XCTAssertEqual(failures.ids(at: at(301)), [])
    }

    func testGameMarkLastsFifteenMinutes() {
        var failures = LiveFailures()
        failures.noteSharedGame(["a", "b"], at: at(0), now: at(0))
        XCTAssertTrue(failures.gameNotPlaying(["b", "c"], at: at(899)))
        XCTAssertFalse(failures.gameNotPlaying(["a"], at: at(900)), "the game's mark outlived 15 min")
        failures.noteSharedGame(["a"], at: at(-600), now: at(0))
        XCTAssertTrue(failures.gameNotPlaying(["a"], at: at(899)), "an older finding from another device shortened the mark")
        XCTAssertEqual(Set(failures.gamePlayed(["a", "c"]).keys), ["a"])
        XCTAssertFalse(failures.gameNotPlaying(["a"], at: at(1)))
    }

    func testMarkBeforeKickoffEndsAtKickoff() {
        var failures = LiveFailures()
        failures.note("soon", at: at(0), kickoff: at(120))
        failures.note("later", at: at(0), kickoff: at(3600))
        failures.note("on", at: at(0), kickoff: at(-60))
        failures.noteSharedGame(["game"], at: at(0), kickoff: at(120), now: at(0))
        XCTAssertTrue(failures.contains("soon", at: at(119)))
        XCTAssertFalse(failures.contains("soon", at: at(120)), "a try before kickoff outlived it")
        XCTAssertFalse(failures.gameNotPlaying(["game"], at: at(120)), "a game tried before kickoff stayed Not playing")
        XCTAssertFalse(failures.contains("later", at: at(600)), "a try an hour early outlived its 10 min")
        XCTAssertTrue(failures.contains("on", at: at(599)), "a try during the game ended at its kickoff")
        XCTAssertEqual(failures.played("soon")?.madeBeforeKickoff, true)
        XCTAssertEqual(failures.played("on")?.madeBeforeKickoff, false)
    }

    func testAnEndedGameMarkIsNotNoted() {
        var failures = LiveFailures()
        let before = failures
        failures.noteSharedGame(["g"], at: at(0), now: at(900))
        XCTAssertEqual(failures, before, "a game mark already over was noted again")
        failures.noteSharedGame(["g"], at: at(0), kickoff: at(60), now: at(60))
        XCTAssertEqual(failures, before, "a mark from before kickoff was noted after kickoff")
    }

    func testEndedMarksGo() {
        var failures = LiveFailures()
        XCTAssertNil(failures.nextEnd)
        failures.note("a", at: at(0))
        failures.noteSharedGame(["g"], at: at(0), kickoff: at(60), now: at(0))
        XCTAssertEqual(failures.nextEnd, at(60))
        failures.dropEnded(at: at(60))
        XCTAssertEqual(failures.nextEnd, at(600))
        failures.dropEnded(at: at(600))
        XCTAssertNil(failures.nextEnd)
    }

    func testEveryCopyFailed() {
        var failures = LiveFailures()
        failures.note("hd")
        XCTAssertTrue(failures.failed(["hd"]))
        XCTAssertFalse(failures.failed(["hd", "sd"]), "a channel whose other copy didn't fail")
        failures.note("sd")
        XCTAssertTrue(failures.failed(["hd", "sd"]))
        XCTAssertFalse(failures.failed(["hd", "sd"], playingCopy: "sd"), "the one playing isn't failed")
        XCTAssertFalse(failures.failed([]))
    }

    func testFailedCopiesGoLast() {
        struct Copy: Identifiable, Equatable { let id: String }
        let copies = ["fhd", "hd", "sd", "lbw"].map(Copy.init)
        var failures = LiveFailures()
        XCTAssertEqual(failures.failedLast(copies), copies, "the order changed with nothing failed")
        failures.note("fhd")
        failures.note("sd")
        XCTAssertEqual(failures.failedLast(copies).map(\.id), ["hd", "lbw", "fhd", "sd"])
        _ = failures.played("fhd")
        XCTAssertEqual(failures.failedLast(copies).map(\.id), ["fhd", "hd", "lbw", "sd"])
    }
}

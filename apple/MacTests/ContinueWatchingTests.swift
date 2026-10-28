import XCTest
@testable import OpenIPTV

/// Continue Watching has one card per show: the episode watched last.
/// Dragon Ball Z has two copies, s1 and cs1, in two libraries.
@MainActor
final class ContinueWatchingTests: XCTestCase {
    private let film = Card(id: "m5", kind: "Movie", title: "Movie 5", subtitle: "1h 2m", images: [], progress: 10, playable: true)
    private let otherShow = Card(id: "s4", kind: "Series", title: "The Office", subtitle: "S1, E2 · 20m", images: [], progress: 30,
                                 playable: true, episodeId: "e402")

    private func dragonBall(_ id: String, episode: String, progress: Double) -> Card {
        Card(id: id, kind: "Series", title: "Dragon Ball Z", subtitle: "S2, E3 · 13m", images: [], progress: progress, playable: true,
             episodeId: episode, episodeName: "Goku's Ordeal")
    }

    private func stop(_ itemId: String, of show: String, named name: String? = "Dragon Ball Z", _ outcome: ContinueStop.Outcome,
                      at: Date = Date()) -> ContinueStop {
        ContinueStop(itemId: itemId, at: at, outcome: outcome, seriesId: show, seriesName: name)
    }

    /// Regression: pressing Dragon Ball Z's card plays the episode from the
    /// show's other copy. Back on Home, Continue Watching had a card for
    /// each copy.
    func testStoppingAnEpisodeOfTheShowsOtherCopyLeavesOneCard() {
        let shown = [dragonBall("s1", episode: "e203", progress: 40), otherShow, film]

        let row = stop("ce203", of: "cs1", .card(dragonBall("cs1", episode: "ce203", progress: 5))).applied(to: shown)

        XCTAssertEqual(row.map(\.id), ["cs1", "s4", "m5"])
        XCTAssertEqual(row.first?.progress, 5)
    }

    /// A stop with no card of its own (nothing about its show on the device)
    /// after one on the other copy: the server's card for the first copy
    /// came back beside it.
    func testAStopWithNoCardAfterOneOnTheOtherCopyLeavesOneCard() {
        let server = [dragonBall("s1", episode: "e205", progress: 20), otherShow, film]
        let stops = [stop("e205", of: "s1", .progress(60)),
                     stop("ce203", of: "cs1", .card(dragonBall("cs1", episode: "ce203", progress: 5)), at: Date(timeIntervalSinceNow: -60))]

        let row = ContinueStop.applied(stops, toServer: server)

        XCTAssertEqual(row.map(\.id), ["s1", "s4", "m5"])
        XCTAssertEqual(row.first?.progress, 60)
        XCTAssertEqual(row.first?.episodeName, "Goku's Ordeal")
    }

    /// Finished on the other copy with nothing next known there: the first
    /// copy's card stays, as it may go further.
    func testFinishingTheOtherCopyLeavesTheFirstCopysCard() {
        let shown = [dragonBall("s1", episode: "e203", progress: 40), otherShow, film]

        XCTAssertEqual(stop("ce208", of: "cs1", .gone).applied(to: shown).map(\.id), ["s1", "s4", "m5"])
    }

    /// Finished on the other copy within two minutes of an earlier stop
    /// there: the first copy's card stays.
    func testFinishingTheOtherCopyAfterAnEarlierStopThereLeavesTheFirstCopysCard() {
        let server = [dragonBall("s1", episode: "e209", progress: 10), otherShow, film]
        let stops = [stop("ce207", of: "cs1", .card(dragonBall("cs1", episode: "ce208", progress: 0)), at: Date(timeIntervalSinceNow: -60)),
                     stop("ce208", of: "cs1", .gone)]

        XCTAssertEqual(ContinueStop.applied(stops, toServer: server).map(\.id), ["s1", "s4", "m5"])
    }

    /// Finished with nothing next known: its own copy's card goes.
    func testFinishingAnEpisodeTakesOutItsShowsCard() {
        let shown = [dragonBall("s1", episode: "e203", progress: 40), otherShow, film]

        XCTAssertEqual(stop("e208", of: "s1", .gone).applied(to: shown).map(\.id), ["s4", "m5"])
    }

    /// A show the server sends no name for: its card is found by its id.
    func testAStopOnAShowWithNoNameReplacesItsCardById() {
        let shown = [dragonBall("s1", episode: "e203", progress: 40), otherShow, film]
        let next = dragonBall("s1", episode: "e205", progress: 0)

        let row = stop("e205", of: "s1", named: nil, .card(next)).applied(to: shown)

        XCTAssertEqual(row.map(\.id), ["s1", "s4", "m5"])
        XCTAssertEqual(row.first?.episodeId, "e205")
    }

    /// Stopped with nothing about its show on the device: the show's card
    /// comes first, at its own place.
    func testAStopWithNoCardBringsItsShowsCardFirst() {
        let shown = [film, dragonBall("s1", episode: "e203", progress: 40)]

        let row = stop("e207", of: "s1", .progress(10)).applied(to: shown)

        XCTAssertEqual(row.map(\.id), ["s1", "m5"])
        XCTAssertEqual(row.first?.progress, 40)
    }

    /// The server lists what's partway through newest first: the two
    /// copies' episodes make one card, on the newer one.
    func testTheServersEpisodesOfBothCopiesMakeOneCardOnTheNewest() throws {
        let json = """
        [{"Id": "ce205", "Name": "Case 5", "Type": "Episode", "SeriesId": "cs1", "SeriesName": "Dragon Ball Z",
          "ParentIndexNumber": 2, "IndexNumber": 5, "RunTimeTicks": 13200000000,
          "UserData": {"PlaybackPositionTicks": 2640000000, "PlayedPercentage": 20, "LastPlayedDate": "2026-10-28T20:00:00.0000000Z"}},
         {"Id": "e201", "Name": "Case 1", "Type": "Episode", "SeriesId": "s1", "SeriesName": "Dragon Ball Z",
          "ParentIndexNumber": 2, "IndexNumber": 1, "RunTimeTicks": 13200000000,
          "UserData": {"PlaybackPositionTicks": 6600000000, "PlayedPercentage": 50, "LastPlayedDate": "2026-10-20T20:00:00.0000000Z"}}]
        """
        let watching = try JSONDecoder().decode([EmbyItem].self, from: Data(json.utf8))
        let account = EmbyAccount(serverURL: URL(string: "http://127.0.0.1:1")!, serverName: "test", userId: "U1",
                                  userName: "tester", accessToken: "tok")
        let emby = EmbyClient(account: account, deviceId: "mac-test")

        let row = try XCTUnwrap(emby.showRow("Continue Watching", HomeFeed.continueItems(watching: watching, nextUp: []), 300))

        XCTAssertEqual(row.cards.map(\.id), ["cs1"])
        XCTAssertEqual(row.cards.first?.episodeId, "ce205")
        XCTAssertEqual(row.cards.first?.progress, 20)
    }
}

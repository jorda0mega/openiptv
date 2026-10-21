import CryptoKit
import XCTest

/// iPhone: a game listed by several services (the test server's
/// `sports=1`: one NFL game from NFL, ESPN Unlimited in English and
/// Spanish, DAZN CA in English and French). Run with `xcodebuild test
/// -scheme OpenIPTV` on an iPhone simulator signed in to the test server
/// (scripts/mock_server.py) through TEST_RUNNER_DEBUG_EMBY.
final class LiveSportsTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        if let account = ProcessInfo.processInfo.environment["DEBUG_EMBY"] {
            app.launchEnvironment["OPENREEL_DEBUG_EMBY"] = account
        }
        // The test server's channels too (its test login, for this run).
        if let server = testServer() {
            app.launchEnvironment["OPENREEL_DEBUG_IPTV"] = #"{"id":"6F9A1E52-0000-4000-8000-000000000001","name":"Test","kind":"#
                + #"{"xtream":{"server":"\#(server.absoluteString)","username":"u","password":"p"}}}"#
        }
        XCUIDevice.shared.orientation = .portrait
    }

    /// The game plays on the best channel at once (the main commentary,
    /// as listed first); Watch On lists all five with their language, and
    /// one picked plays and comes first for the league's games after.
    func testGameOnSeveralChannelsOffersWatchOn() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1", "dead_live": "none"])
        addTeardownBlock { [self] in configure(server, ["sports": "0"]) }
        app.launchArguments = ["-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        openGame()
        XCTAssertTrue(playing("NFL 01"), "the game didn't start on the best channel: \(liveCopy())")

        showControls()
        let watchOn = app.buttons["Watch On"].firstMatch
        XCTAssertTrue(watchOn.waitForExistence(timeout: 5), "no Watch On for a game on five channels")
        watchOn.tap()
        let choices = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'player.card.'"))
        XCTAssertTrue(choices.firstMatch.waitForExistence(timeout: 5), "Watch On listed nothing")
        XCTAssertEqual(choices.count, 5, "not every channel showing the game")
        XCTAssertTrue(choices.matching(NSPredicate(format: "label BEGINSWITH 'NFL' AND label CONTAINS 'Playing'")).firstMatch.exists,
                      "the channel playing isn't marked")
        XCTAssertTrue(choices.matching(NSPredicate(format: "label BEGINSWITH 'DAZN CA' AND label CONTAINS 'French'")).firstMatch.exists,
                      "the French feed doesn't say so")
        let spanish = choices.matching(NSPredicate(format: "label BEGINSWITH 'ESPN Unlimited' AND label CONTAINS 'Spanish'")).firstMatch
        XCTAssertTrue(spanish.exists, "the Spanish feed doesn't say so")
        spanish.tap()
        XCTAssertTrue(playing("ESPN UNLTD 016"), "the channel picked didn't open: \(liveCopy())")
        XCTAssertTrue(started(), "the channel picked didn't play")

        // The league's next game (this one again): the pick plays first.
        showControls()
        app.buttons["Close player"].firstMatch.tap()
        openGame()
        XCTAssertTrue(playing("ESPN UNLTD 016"), "the league's pick didn't play first: \(liveCopy())")
    }

    /// Regression: a channel picked in Watch On that never started (an
    /// event feed that was over) was remembered for the league, so the
    /// league's next game opened on it and hung.
    func testFeedThatNeverStartsIsNotRemembered() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1", "dead_live": "2003"])
        addTeardownBlock { [self] in configure(server, ["sports": "0", "dead_live": "none"]) }
        app.launchArguments = ["-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        openGame()
        XCTAssertTrue(playing("NFL 01"), "the game didn't start on the best channel: \(liveCopy())")
        showControls()
        app.buttons["Watch On"].firstMatch.tap()
        let spanish = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'player.card.' AND label CONTAINS 'Spanish'")).firstMatch
        XCTAssertTrue(spanish.waitForExistence(timeout: 5), "no Spanish feed in Watch On")
        spanish.tap()
        XCTAssertTrue(playing("ESPN UNLTD 016"), "the channel picked didn't open: \(liveCopy())")
        sleep(6)
        XCTAssertEqual(app.staticTexts["debug-live-state"].firstMatch.label, "starting", "the dead feed played")

        showControls()
        app.buttons["Close player"].firstMatch.tap()
        openGame()
        XCTAssertTrue(playing("NFL 01"), "the feed that never started was tried first: \(liveCopy())")
    }

    /// A game's best channel that never sends a picture (its feed over, the
    /// slot still listed) gives way to another channel showing the game
    /// after the start limit (shortened to 5 s here). Regression: the user's
    /// game said LIVE and spun forever.
    func testDeadChannelGivesWayToAnother() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1", "dead_live": "2001"])
        addTeardownBlock { [self] in configure(server, ["sports": "0", "dead_live": "none"]) }
        app.launchEnvironment["OPENREEL_DEBUG_LIVE_START_LIMIT"] = "5"
        app.launchArguments = ["-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        openGame()
        XCTAssertTrue(playing("NFL 01"), "the game didn't open on the best channel: \(liveCopy())")
        let readout = app.staticTexts["debug-live-copy"].firstMatch
        let deadline = Date().addingTimeInterval(20)
        while readout.label.hasPrefix("NFL 01"), Date() < deadline { usleep(250_000) }
        XCTAssertFalse(readout.label.hasPrefix("NFL 01"), "still waiting on the channel that sends nothing")
        XCTAssertTrue(started(), "the next channel didn't play: \(liveCopy())")
    }

    /// No channel of the game sends a picture: after trying each, the player
    /// says the game isn't playing, instead of spinning forever, and its row
    /// in Sports says so too instead of LIVE.
    func testGameNotPlayingSaysSo() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1", "dead_live": "2001,2002,2003,2004,2005"])
        addTeardownBlock { [self] in configure(server, ["sports": "0", "dead_live": "none"]) }
        app.launchEnvironment["OPENREEL_DEBUG_LIVE_START_LIMIT"] = "3"
        app.launchArguments = ["-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        openGame()
        let state = app.staticTexts["debug-live-state"].firstMatch
        let deadline = Date().addingTimeInterval(40)
        while state.label != "failed", Date() < deadline { usleep(250_000) }
        XCTAssertEqual(state.label, "failed", "still trying after every channel: \(liveCopy())")
        let note = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'playing right now'")).firstMatch
        XCTAssertTrue(note.waitForExistence(timeout: 3), "no word that the game isn't playing")

        // Back in Sports, the game no longer says LIVE: it says it isn't
        // playing (for half an hour; it's tried again when opened).
        showControls()
        app.buttons["Close player"].firstMatch.tap()
        let game = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Jaguars'")).firstMatch
        XCTAssertTrue(game.waitForExistence(timeout: 10), "the game left Sports")
        XCTAssertFalse(game.label.contains("LIVE"), "still LIVE after no channel played: \(game.label)")
        XCTAssertTrue(game.label.contains("Not playing"), "no word on the row that it isn't playing: \(game.label)")
    }

    /// A game's row says how many channels show it, and a long press on it
    /// lists them (Watch On, as in the player); the one picked plays.
    /// Regression: when Watch On would be there was a guess (the user:
    /// "I don't know when we get Watch On versus no Watch On"), and there
    /// was no long press.
    func testLongPressListsTheGamesChannels() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1", "dead_live": "none"])
        addTeardownBlock { [self] in configure(server, ["sports": "0"]) }
        app.launchArguments = ["-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        let tab = app.tabBars.buttons["Live TV"].firstMatch
        if tab.waitForExistence(timeout: 10) { tab.tap() }
        let sports = app.buttons["Sports"].firstMatch
        if sports.waitForExistence(timeout: 10) { sports.tap() }
        let game = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Jaguars'")).firstMatch
        XCTAssertTrue(game.waitForExistence(timeout: 15), "the game isn't in Sports")
        XCTAssertTrue(game.label.contains("5 channels"), "the row doesn't say how many channels: \(game.label)")
        game.press(forDuration: 1.2)
        // In the order they'd play: NFL, ESPN Unlimited and DAZN CA in
        // English, then ESPN Unlimited in Spanish and DAZN CA in French (the
        // language is each item's second line).
        let espn = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'ESPN Unlimited'"))
        XCTAssertTrue(espn.firstMatch.waitForExistence(timeout: 5),
                      "no channels on a long press: \(app.buttons.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }.prefix(20))")
        XCTAssertEqual(espn.count, 2, "not both ESPN Unlimited feeds")
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'DAZN CA'")).count, 2, "not both DAZN CA feeds")
        XCTAssertTrue(app.buttons["NFL"].firstMatch.exists, "no NFL channel")
        espn.element(boundBy: 1).tap()
        XCTAssertTrue(playing("ESPN UNLTD 016"), "the channel picked didn't play: \(liveCopy())")
    }

    /// One feed listed in two slots of a sport's own category ("Football /
    /// Soccer: … ( OneSoccer Feed )" twice, as the user saw): one entry in
    /// Watch On, named by the network with the category under it, and
    /// counted once on the game's row. Regression: two identical entries
    /// "Football · Soccer, OneSoccer Feed".
    func testSameFeedOnTwoChannelsIsOneEntry() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1", "sports_dupes": "1", "dead_live": "none"])
        addTeardownBlock { [self] in configure(server, ["sports": "0", "sports_dupes": "0"]) }
        app.launchArguments = ["-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        let tab = app.tabBars.buttons["Live TV"].firstMatch
        if tab.waitForExistence(timeout: 10) { tab.tap() }
        let sports = app.buttons["Sports"].firstMatch
        if sports.waitForExistence(timeout: 10) { sports.tap() }
        let game = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Jaguars'")).firstMatch
        XCTAssertTrue(game.waitForExistence(timeout: 15), "the game isn't in Sports")
        XCTAssertTrue(game.label.contains("6 channels"), "the same feed counted twice: \(game.label)")
        game.tap()
        XCTAssertTrue(playing("NFL 01"), "the game didn't start: \(liveCopy())")
        showControls()
        app.buttons["Watch On"].firstMatch.tap()
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'player.card.'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5), "Watch On listed nothing")
        XCTAssertEqual(cards.count, 6, "the same feed listed twice: \(cards.allElementsBoundByIndex.map(\.label))")
        let soccer = cards.matching(NSPredicate(format: "label BEGINSWITH 'OneSoccer' AND label CONTAINS 'Football · Soccer'"))
        XCTAssertEqual(soccer.count, 1, "not one OneSoccer entry: \(cards.allElementsBoundByIndex.map(\.label))")
    }

    /// A game found playing on none of its channels says so on every
    /// device: the app opened afresh (as another device, nothing of this
    /// one's kept) shows its row "Not playing" from the app's record on the
    /// server. Regression: only the device that tried it knew.
    func testNotPlayingIsSharedAcrossDevices() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["reset": "1"])
        configure(server, ["sports": "1", "dead_live": "2001,2002,2003,2004,2005"])
        addTeardownBlock { [self] in configure(server, ["reset": "1"]) }
        app.launchEnvironment["OPENREEL_DEBUG_LIVE_START_LIMIT"] = "3"
        app.launchArguments = ["-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        openGame()
        let state = app.staticTexts["debug-live-state"].firstMatch
        let deadline = Date().addingTimeInterval(40)
        while state.label != "failed", Date() < deadline { usleep(250_000) }
        XCTAssertEqual(state.label, "failed", "still trying after every channel")
        sleep(2)
        app.terminate()

        // Another device: a fresh start, the server's record only.
        app.launch()
        let tab = app.tabBars.buttons["Live TV"].firstMatch
        if tab.waitForExistence(timeout: 10) { tab.tap() }
        let sports = app.buttons["Sports"].firstMatch
        if sports.waitForExistence(timeout: 10) { sports.tap() }
        let game = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Jaguars'")).firstMatch
        XCTAssertTrue(game.waitForExistence(timeout: 15), "the game isn't in Sports")
        let shown = Date().addingTimeInterval(10)
        while !game.label.contains("Not playing"), Date() < shown { usleep(250_000) }
        XCTAssertTrue(game.label.contains("Not playing"), "the other device's finding isn't shown: \(game.label)")
    }

    /// Sports opened right after the lineup loaded asks the provider for
    /// nothing: the lineup it has is minutes old. Regression: it asked for
    /// every event category again (76 requests on a real lineup, a third
    /// to a half of them refused as too many).
    func testOpeningSportsAfterLoadAsksNothing() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1"])
        addTeardownBlock { [self] in configure(server, ["sports": "0"]) }
        app.launchArguments = ["-freshLineup", "YES", "-category", "__local"]
        app.launch()
        let tab = app.tabBars.buttons["Live TV"].firstMatch
        if tab.waitForExistence(timeout: 10) { tab.tap() }
        let sports = app.buttons["Sports"].firstMatch
        XCTAssertTrue(sports.waitForExistence(timeout: 20), "no Sports tab: the lineup didn't load")
        let mark = try markTime(server)
        sports.tap()
        let game = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Jaguars'")).firstMatch
        XCTAssertTrue(game.waitForExistence(timeout: 15), "the game isn't in Sports")
        sleep(3)
        XCTAssertEqual(try lineupRequests(server, since: mark), [], "Sports asked the provider again for a lineup minutes old")
    }

    /// The provider refusing (429, too many requests) at a relaunch: Sports
    /// says it couldn't update the games and how old its list is, instead
    /// of "Nothing on right now"; once the provider answers again it asks
    /// again (the wait shortened to 5 s) and the game shows LIVE.
    /// Regression: a refused check was silent and counted as done.
    func testSportsSaysWhenItCouldNotUpdate() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1", "sports_started": "300"])
        addTeardownBlock { [self] in configure(server, ["sports": "0", "sports_started": "20", "xtream_status": "0"]) }
        app.launchEnvironment["OPENREEL_DEBUG_GAMES_MAX_AGE"] = "5"
        app.launchArguments = ["-cacheFolder", "live-\(UUID().uuidString.prefix(8))"]
        app.launch()
        openSports()
        XCTAssertTrue(app.staticTexts["Nothing on right now"].firstMatch.waitForExistence(timeout: 20), "a game five hours in is still listed")
        app.terminate()

        configure(server, ["xtream_status": "429", "sports_started": "20"])
        sleep(6)
        app.launch()
        openSports()
        let notice = app.staticTexts["Couldn't update the games"].firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 20), "no word that the games couldn't be updated")
        let detail = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Last updated' AND label CONTAINS 'too many requests'")).firstMatch
        XCTAssertTrue(detail.exists, "the notice doesn't say how old the list is and why")
        XCTAssertFalse(app.staticTexts["Nothing on right now"].firstMatch.exists, "\"Nothing on right now\" with the check refused")

        configure(server, ["xtream_status": "0"])
        let game = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Jaguars'")).firstMatch
        XCTAssertTrue(game.waitForExistence(timeout: 15), "the game didn't show once the provider answered again")
        XCTAssertTrue(game.label.contains("LIVE") && game.label.contains("5 channels"), "the game's row: \(game.label)")
        XCTAssertFalse(notice.exists, "the notice stayed after a good check")
    }

    /// Sports' Channels list says a failed check too (the provider refusing,
    /// 429, while it's open). Regression: only the games' lists said it.
    func testSportsChannelsSaysWhenItCouldNotUpdate() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1"])
        addTeardownBlock { [self] in configure(server, ["sports": "0", "xtream_status": "0"]) }
        app.launchEnvironment["OPENREEL_DEBUG_GAMES_MAX_AGE"] = "5"
        app.launchArguments = ["-freshLineup", "YES"]
        app.launch()
        openSports()
        let game = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Jaguars'")).firstMatch
        XCTAssertTrue(game.waitForExistence(timeout: 20), "the game isn't in Sports")
        app.buttons["Channels"].firstMatch.tap()
        XCTAssertTrue(game.waitForNonExistence(timeout: 5), "the Channels filter still lists the games")

        configure(server, ["xtream_status": "429"])
        XCTAssertTrue(app.staticTexts["Couldn't update the games"].firstMatch.waitForExistence(timeout: 20),
                      "Sports' Channels list doesn't say the games couldn't be updated")
    }

    /// A refused check leaves the saved lineup's age as it was: relaunched
    /// once the provider answers again, the app sees a list older than the
    /// limit (30 s here) and asks at once. Had the refusal stamped the file
    /// as just checked, the old list would stay another 30 s.
    func testFailedCheckKeepsTheListsAge() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1", "sports_started": "300"])
        addTeardownBlock { [self] in configure(server, ["sports": "0", "sports_started": "20", "xtream_status": "0"]) }
        app.launchEnvironment["OPENREEL_DEBUG_GAMES_MAX_AGE"] = "30"
        app.launchArguments = ["-cacheFolder", "live-\(UUID().uuidString.prefix(8))"]
        app.launch()
        openSports()
        XCTAssertTrue(app.staticTexts["Nothing on right now"].firstMatch.waitForExistence(timeout: 20), "a game five hours in is still listed")
        app.terminate()
        sleep(35)

        configure(server, ["xtream_status": "429", "sports_started": "20"])
        app.launch()
        openSports()
        XCTAssertTrue(app.staticTexts["Couldn't update the games"].firstMatch.waitForExistence(timeout: 20),
                      "no word that the games couldn't be updated")
        app.terminate()

        configure(server, ["xtream_status": "0"])
        app.launch()
        openSports()
        let game = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Jaguars'")).firstMatch
        XCTAssertTrue(game.waitForExistence(timeout: 15), "the list wasn't checked at once: the refused check made it look current")
        XCTAssertTrue(game.label.contains("LIVE"), "the game's row: \(game.label)")
    }

    /// Sports left open: a game that starts meanwhile shows on its own (the
    /// lineup is checked every 15 minutes; 10 s here). Regression: the list
    /// stayed as it was when the page opened.
    func testSportsLeftOpenStaysCurrent() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1", "sports_started": "300"])
        addTeardownBlock { [self] in configure(server, ["sports": "0", "sports_started": "20"]) }
        app.launchEnvironment["OPENREEL_DEBUG_GAMES_MAX_AGE"] = "10"
        app.launchArguments = ["-freshLineup", "YES"]
        app.launch()
        openSports()
        XCTAssertTrue(app.staticTexts["Nothing on right now"].firstMatch.waitForExistence(timeout: 20), "a game five hours in is still listed")
        configure(server, ["sports_started": "20"])
        let game = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Jaguars'")).firstMatch
        XCTAssertTrue(game.waitForExistence(timeout: 25), "the game that started didn't show while Sports stayed open")
        XCTAssertTrue(game.label.contains("LIVE"), "the game's row: \(game.label)")
    }

    /// Back from the background, Sports checks for games at once when its
    /// list is older than the limit (10 s here). Regression: nothing
    /// refreshed Live TV on coming back.
    func testSportsCurrentAfterComingBack() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1", "sports_started": "300"])
        addTeardownBlock { [self] in configure(server, ["sports": "0", "sports_started": "20"]) }
        app.launchEnvironment["OPENREEL_DEBUG_GAMES_MAX_AGE"] = "10"
        app.launchArguments = ["-freshLineup", "YES"]
        app.launch()
        openSports()
        XCTAssertTrue(app.staticTexts["Nothing on right now"].firstMatch.waitForExistence(timeout: 20), "a game five hours in is still listed")
        XCUIDevice.shared.press(.home)
        configure(server, ["sports_started": "20"])
        sleep(12)
        app.activate()
        let game = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Jaguars'")).firstMatch
        XCTAssertTrue(game.waitForExistence(timeout: 15), "the game that started while away didn't show on coming back")
        XCTAssertTrue(game.label.contains("LIVE"), "the game's row: \(game.label)")
    }

    /// The provider answering with no channels, or no categories, at all
    /// (HTTP 200, an empty list): the games listed stay, on screen and in
    /// the saved lineup a relaunch shows, and Sports says it couldn't
    /// update them and why; once the provider sends its lineup again the
    /// notice goes. Regression: an empty answer emptied Live TV and was
    /// saved as the lineup just checked; with no categories, the games went.
    func testEmptyAnswerKeepsTheGames() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1"])
        addTeardownBlock { [self] in configure(server, ["sports": "0", "xtream_empty": "0"]) }
        app.launchEnvironment["OPENREEL_DEBUG_GAMES_MAX_AGE"] = "5"
        app.launchArguments = ["-cacheFolder", "live-\(UUID().uuidString.prefix(8))"]
        app.launch()
        openSports()
        let game = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Jaguars'")).firstMatch
        XCTAssertTrue(game.waitForExistence(timeout: 20), "the game isn't in Sports")

        let notice = app.staticTexts["Couldn't update the games"].firstMatch
        for (list, reason) in [("streams", "sent no channels"), ("categories", "sent no categories")] {
            configure(server, ["xtream_empty": list])
            let why = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", reason)).firstMatch
            XCTAssertTrue(why.waitForExistence(timeout: 20), "no word that the games couldn't be updated, and why, after no \(list)")
            XCTAssertTrue(notice.exists, "no notice after no \(list)")
            XCTAssertTrue(game.exists, "the game went with the provider's answer of no \(list)")
        }

        app.terminate()
        app.launch()
        openSports()
        XCTAssertTrue(game.waitForExistence(timeout: 20), "the relaunch lost the game: an empty answer was saved")
        XCTAssertTrue(notice.waitForExistence(timeout: 20), "no word after the relaunch that the games couldn't be updated")

        configure(server, ["xtream_empty": "0"])
        XCTAssertTrue(notice.waitForNonExistence(timeout: 20), "the notice stayed after the provider sent its lineup again")
        XCTAssertTrue(game.exists, "the game went once the lineup came back")
    }

    func testMoveSaysWhichChannelDidntPlay() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1", "dead_live": "2001", "slow_live": "2002"])
        addTeardownBlock { [self] in configure(server, ["sports": "0", "dead_live": "none", "slow_live": "none"]) }
        app.launchEnvironment["OPENREEL_DEBUG_LIVE_START_LIMIT"] = "8"
        app.launchEnvironment["OPENREEL_DEBUG_SWITCH_CUE_SECONDS"] = "10"
        app.launchArguments = ["-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        openGame()
        XCTAssertTrue(playing("NFL 01"), "the game didn't open on the best channel: \(liveCopy())")
        XCTAssertTrue(waitForCue("NFL didn’t play", "Switching"), "no word while the player moves on: \(cueWords())")
        XCTAssertTrue(waitForCue("Now on ESPN Unlimited"), "the cue doesn't say where the player went: \(cueWords())")
        XCTAssertTrue(started(), "the next channel didn't play: \(liveCopy())")
        let frame = switchCue.frame
        XCTAssertEqual(frame.midX, app.frame.midX, accuracy: 4, "the cue isn't centred: \(frame)")
        XCTAssertLessThan(frame.maxY, app.frame.height * 0.3, "the cue isn't at the top: \(frame)")
        sleep(3)
        XCTAssertTrue(switchCue.exists, "the cue went before it could be read")
        XCTAssertTrue(switchCue.waitForNonExistence(timeout: 15), "the cue stayed")
    }

    func testGameNotPlayingMarksEveryCard() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1", "dead_live": "2001,2002,2003,2004,2005"])
        addTeardownBlock { [self] in configure(server, ["sports": "0", "dead_live": "none"]) }
        app.launchEnvironment["OPENREEL_DEBUG_LIVE_START_LIMIT"] = "3"
        app.launchArguments = ["-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        openGame()
        let state = app.staticTexts["debug-live-state"].firstMatch
        let deadline = Date().addingTimeInterval(40)
        while state.label != "failed", Date() < deadline { usleep(250_000) }
        XCTAssertEqual(state.label, "failed", "still trying after every channel: \(liveCopy())")
        showControls()
        app.buttons["Watch On"].firstMatch.tap()
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'player.card.'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5), "Watch On listed nothing")
        XCTAssertEqual(cards.count, 5, "not every channel showing the game")
        for card in cards.allElementsBoundByIndex {
            XCTAssertTrue(card.label.contains("Didn’t play") && !card.label.contains("Playing"), "a card of a game that played nowhere: \(card.label)")
        }
    }

    func testPickThatDidntPlayIsMarked() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1", "dead_live": "2003"])
        addTeardownBlock { [self] in configure(server, ["sports": "0", "dead_live": "none"]) }
        app.launchEnvironment["OPENREEL_DEBUG_LIVE_START_LIMIT"] = "3"
        app.launchArguments = ["-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        pickSpanishThatDoesntPlay()

        showControls()
        app.buttons["Watch On"].firstMatch.tap()
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'player.card.'"))
        let spanish = cards.matching(NSPredicate(format: "label CONTAINS 'Spanish'")).firstMatch
        let nfl = cards.matching(NSPredicate(format: "label BEGINSWITH 'NFL'")).firstMatch
        XCTAssertTrue(spanish.waitForExistence(timeout: 5), "no Spanish feed in Watch On")
        XCTAssertTrue(spanish.label.contains("Didn’t play · Spanish"), "the card doesn't say it didn't play: \(spanish.label)")
        XCTAssertTrue(nfl.label.contains("Playing") && !nfl.label.contains("Didn’t"), "the card playing: \(nfl.label)")
        let shot = XCUIScreen.main.screenshot()
        XCTAssertGreaterThan(brightest(shot, in: badge(on: picture(of: spanish)).insetBy(dx: 2, dy: 2)), 200,
                             "no mark on the picture of the card that didn't play")
        XCTAssertLessThan(brightest(shot, in: badge(on: picture(of: nfl)).insetBy(dx: 2, dy: 2)), 150,
                          "a mark on the picture of the card playing")

        app.buttons["Close player"].firstMatch.tap()
        let game = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Jaguars'")).firstMatch
        XCTAssertTrue(game.waitForExistence(timeout: 10), "the game left Sports")
        game.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == 'ESPN Unlimited'")).firstMatch.waitForExistence(timeout: 5),
                      "no channels on a long press")
        XCTAssertTrue(app.buttons["ESPN Unlimited, Didn’t play · Spanish"].firstMatch.exists, "the long press doesn't say which channel didn't play")
    }

    func testMarkGoesWhenTheChannelPlays() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1", "dead_live": "2003"])
        addTeardownBlock { [self] in configure(server, ["sports": "0", "dead_live": "none"]) }
        app.launchEnvironment["OPENREEL_DEBUG_LIVE_START_LIMIT"] = "3"
        app.launchArguments = ["-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        pickSpanishThatDoesntPlay()
        showControls()
        app.buttons["Watch On"].firstMatch.tap()
        let spanish = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'player.card.' AND label CONTAINS 'Spanish'")).firstMatch
        XCTAssertTrue(spanish.waitForExistence(timeout: 5), "no Spanish feed in Watch On")
        XCTAssertTrue(spanish.label.contains("Didn’t play"), "the card doesn't say it didn't play: \(spanish.label)")

        configure(server, ["dead_live": "none"])
        spanish.tap()
        XCTAssertTrue(playing("ESPN UNLTD 016"), "the channel picked didn't open: \(liveCopy())")
        XCTAssertTrue(started(), "the channel picked didn't play")
        showControls()
        app.buttons["Watch On"].firstMatch.tap()
        XCTAssertTrue(spanish.waitForExistence(timeout: 5), "no Spanish feed in Watch On")
        XCTAssertTrue(spanish.label.contains("Playing") && !spanish.label.contains("Didn’t"), "still marked once it played: \(spanish.label)")
    }

    func testMarkAgesOut() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1", "dead_live": "2001"])
        addTeardownBlock { [self] in configure(server, ["sports": "0", "dead_live": "none"]) }
        app.launchEnvironment["OPENREEL_DEBUG_LIVE_START_LIMIT"] = "3"
        app.launchEnvironment["OPENREEL_DEBUG_LIVE_FAILURE_MAX_AGE"] = "20"
        app.launchArguments = ["-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        openGame()
        XCTAssertTrue(playing("NFL 01"), "the game didn't open on the best channel: \(liveCopy())")
        XCTAssertTrue(started(), "the next channel didn't play: \(liveCopy())")
        showControls()
        app.buttons["Watch On"].firstMatch.tap()
        let nfl = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'player.card.' AND label BEGINSWITH 'NFL'")).firstMatch
        XCTAssertTrue(nfl.waitForExistence(timeout: 5), "no NFL in Watch On")
        XCTAssertTrue(nfl.label.contains("Didn’t play"), "the channel that didn't play isn't marked: \(nfl.label)")
        let deadline = Date().addingTimeInterval(40)
        while nfl.label.contains("Didn’t play"), Date() < deadline { usleep(500_000) }
        XCTAssertFalse(nfl.label.contains("Didn’t play"), "the mark outlived the failure: \(nfl.label)")
    }

    func testChannelThatDidntPlayIsMarkedInItsList() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["dead_live": "5"])
        addTeardownBlock { [self] in configure(server, ["dead_live": "none"]) }
        app.launchEnvironment["OPENREEL_DEBUG_LIVE_START_LIMIT"] = "3"
        app.launchArguments = ["-freshLineup", "YES", "-category", "6F9A1E52-0000-4000-8000-000000000001|1"]
        app.launch()
        let five = channelFive()
        let six = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Channel 6'")).firstMatch
        five.tap()
        let state = app.staticTexts["debug-live-state"].firstMatch
        let deadline = Date().addingTimeInterval(20)
        while state.label != "failed", Date() < deadline { usleep(250_000) }
        XCTAssertEqual(state.label, "failed", "the channel that sends nothing didn't fail")
        showControls()
        app.buttons["Close player"].firstMatch.tap()

        XCTAssertTrue(five.waitForExistence(timeout: 10), "the list went")
        XCTAssertTrue(five.label.contains("Didn’t play"), "the row doesn't say it didn't play: \(five.label)")
        XCTAssertFalse(six.label.contains("Didn’t play"), "a row that wasn't tried is marked: \(six.label)")
        let shot = XCUIScreen.main.screenshot()
        let marked = try XCTUnwrap(tile(of: five, in: shot), "no logo tile on the row")
        let plain = try XCTUnwrap(tile(of: six, in: shot), "no logo tile on the next row")
        XCTAssertGreaterThan(brightest(shot, in: badge(on: marked).insetBy(dx: 2, dy: 2)), 200,
                             "no mark on the logo of the channel that didn't play")
        XCTAssertLessThan(brightest(shot, in: badge(on: plain).insetBy(dx: 2, dy: 2)), 150,
                          "a mark on the logo of a channel that wasn't tried")
    }

    func testStartOverEndsTheCue() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["hd_copy": "5", "dead_live": "955", "slow_live": "5"])
        addTeardownBlock { [self] in configure(server, ["hd_copy": "none", "dead_live": "none", "slow_live": "none"]) }
        app.launchEnvironment["OPENREEL_DEBUG_LIVE_START_LIMIT"] = "5"
        app.launchArguments = ["-freshLineup", "YES", "-category", "6F9A1E52-0000-4000-8000-000000000001|1"]
        app.launch()
        channelFive().tap()
        XCTAssertTrue(waitForCue("Channel 5 HD didn’t play", "Switching"), "no cue after the HD copy didn't play: \(cueWords())")
        startOver()
        XCTAssertTrue(switchCue.waitForNonExistence(timeout: 2), "the cue stayed after Start Over: \(cueWords())")
        XCTAssertTrue(started(), "the recording didn't play")
        sleep(1)
        XCTAssertFalse(switchCue.exists, "the cue came back with the recording: \(cueWords())")
    }

    func testFailedPickTriesItsOtherSlotFirst() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1", "sports_dupes": "1", "dead_live": "none"])
        addTeardownBlock { [self] in configure(server, ["sports": "0", "sports_dupes": "0", "dead_live": "none"]) }
        app.launchEnvironment["OPENREEL_DEBUG_LIVE_START_LIMIT"] = "3"
        app.launchEnvironment["OPENREEL_DEBUG_SWITCH_CUE_SECONDS"] = "10"
        app.launchArguments = ["-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        let twin = try moveOffDeadOneSoccerSlot(server)
        XCTAssertTrue(waitForCue("OneSoccer didn’t play", "Now on another OneSoccer channel"), "the cue doesn't say where the player went: \(cueWords())")

        showControls()
        app.buttons["Close player"].firstMatch.tap()
        openGame()
        XCTAssertTrue(playing(twin), "the pick that played on its other slot wasn't kept: \(liveCopy())")
    }

    func testPlayingCardAfterAMoveStaysPut() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1", "sports_dupes": "1", "dead_live": "none"])
        addTeardownBlock { [self] in configure(server, ["sports": "0", "sports_dupes": "0", "dead_live": "none"]) }
        app.launchEnvironment["OPENREEL_DEBUG_LIVE_START_LIMIT"] = "3"
        app.launchArguments = ["-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        let twin = try moveOffDeadOneSoccerSlot(server)
        XCTAssertTrue(switchCue.waitForNonExistence(timeout: 10), "the cue stayed")
        showControls()
        app.buttons["Watch On"].firstMatch.tap()
        let soccer = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'player.card.' AND label BEGINSWITH 'OneSoccer'")).firstMatch
        XCTAssertTrue(soccer.waitForExistence(timeout: 5), "no OneSoccer in Watch On")
        XCTAssertTrue(soccer.label.contains("Playing"), "the feed playing on its other slot: \(soccer.label)")
        soccer.tap()
        let readout = app.staticTexts["debug-live-copy"].firstMatch
        let deadline = Date().addingTimeInterval(5)
        while readout.label.hasPrefix(twin), !switchCue.exists, Date() < deadline { usleep(250_000) }
        XCTAssertTrue(readout.label.hasPrefix(twin), "the card playing reopened \(liveCopy())")
        XCTAssertFalse(switchCue.exists, "a cue after tapping the card playing: \(cueWords())")
    }

    func testGameFeedThatDidntPlayIsMarkedInItsCategory() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1", "dead_live": "2001"])
        addTeardownBlock { [self] in configure(server, ["sports": "0", "dead_live": "none"]) }
        app.launchEnvironment["OPENREEL_DEBUG_LIVE_START_LIMIT"] = "3"
        app.launchArguments = ["-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        openGame()
        XCTAssertTrue(playing("NFL 01"), "the game didn't open on the best channel: \(liveCopy())")
        XCTAssertTrue(started(), "the next channel didn't play: \(liveCopy())")
        showControls()
        app.buttons["Close player"].firstMatch.tap()
        let game = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Jaguars'")).firstMatch
        XCTAssertTrue(game.waitForExistence(timeout: 10), "the game left Sports")
        app.buttons["Provider categories"].firstMatch.tap()
        let category = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'NFL,'")).firstMatch
        XCTAssertTrue(category.waitForExistence(timeout: 5),
                      "no NFL category: \(app.buttons.allElementsBoundByIndex.map(\.label).filter { !$0.isEmpty }.prefix(20))")
        category.tap()
        let row = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Jaguars'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10), "the NFL category doesn't list the game's channel")
        XCTAssertTrue(row.label.contains("Didn’t play"), "the game's feed that didn't play isn't marked: \(row.label)")
    }

    func testGameRowShowsItsChannelCountOnItsTile() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["sports": "1", "dead_live": "none"])
        addTeardownBlock { [self] in configure(server, ["sports": "0"]) }
        app.launchArguments = ["-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        openSports()
        let game = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Jaguars'")).firstMatch
        XCTAssertTrue(game.waitForExistence(timeout: 15), "the game isn't in Sports")
        XCTAssertTrue(game.label.contains("5 channels"), "VoiceOver doesn't hear how many channels: \(game.label)")
        sleep(1)
        let shot = XCUIScreen.main.screenshot()
        let logo = try XCTUnwrap(tile(of: game, in: shot), "no logo tile on the game's row")
        let corner = badge(on: logo).insetBy(dx: 2, dy: 2)
        let countCapsule = CGRect(x: corner.maxX - 24, y: corner.minY, width: 24, height: corner.height)
        XCTAssertGreaterThan(luminance(shot, in: countCapsule), 120,
                             "no count badge on the game's tile (mean \(Int(luminance(shot, in: countCapsule))))")

        game.tap()
        XCTAssertTrue(started(), "the game didn't play: \(liveCopy())")
        showControls()
        app.buttons["Watch On"].firstMatch.tap()
        let cards = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'player.card.'"))
        XCTAssertTrue(cards.firstMatch.waitForExistence(timeout: 5), "Watch On listed nothing")
        XCTAssertEqual(cards.count, 5, "the badge and Watch On don't agree")
    }

    func testCountLeavesOutAFeedThatDidntPlay() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["reset": "1"])
        configure(server, ["sports": "1", "dead_live": "2001"])
        addTeardownBlock { [self] in configure(server, ["reset": "1"]) }
        app.launchEnvironment["OPENREEL_DEBUG_LIVE_START_LIMIT"] = "3"
        app.launchArguments = ["-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        openGame()
        XCTAssertTrue(playing("NFL 01"), "the game didn't open on the best channel: \(liveCopy())")
        let readout = app.staticTexts["debug-live-copy"].firstMatch
        let deadline = Date().addingTimeInterval(20)
        while readout.label.hasPrefix("NFL 01"), Date() < deadline { usleep(250_000) }
        XCTAssertTrue(started(), "the next channel didn't play: \(liveCopy())")
        closePlayer()
        let game = gameRow()
        XCTAssertTrue(game.waitForExistence(timeout: 10), "the game left Sports")
        XCTAssertTrue(game.label.contains("4 channels"), "the count still has the feed that didn't play: \(game.label)")
    }

    func testNoFeedPlayedCrossesOutTheTile() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["reset": "1"])
        configure(server, ["sports": "1", "dead_live": "2001,2002,2003,2004,2005"])
        addTeardownBlock { [self] in configure(server, ["reset": "1"]) }
        app.launchEnvironment["OPENREEL_DEBUG_LIVE_START_LIMIT"] = "3"
        app.launchArguments = ["-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        openGame()
        XCTAssertTrue(failed(within: 40), "still trying after every channel: \(liveCopy())")
        closePlayer()
        let game = gameRow()
        XCTAssertTrue(game.waitForExistence(timeout: 10), "the game left Sports")
        XCTAssertTrue(game.label.contains("Not playing"), "no word that nothing played: \(game.label)")
        XCTAssertFalse(game.label.contains("channels"), "a channel count on a game that played nowhere: \(game.label)")
        try assertTileCrossedOut(game)
    }

    func testMarkBeforeKickoffEndsAtKickoff() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["reset": "1"])
        addTeardownBlock { [self] in configure(server, ["reset": "1"]) }
        let kickoff = ((try markTime(server) + 100) / 60).rounded(.up) * 60
        configure(server, ["sports": "1", "sports_kickoff": String(Int(kickoff)), "dead_live": "2001,2002,2003,2004,2005"])
        app.launchEnvironment["OPENREEL_DEBUG_LIVE_START_LIMIT"] = "3"
        app.launchArguments = ["-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        openGame()
        XCTAssertTrue(failed(within: 40), "still trying after every channel: \(liveCopy())")
        closePlayer()
        configure(server, ["dead_live": "none"])
        let game = gameRow()
        XCTAssertTrue(game.waitForExistence(timeout: 10), "the game left Sports")
        XCTAssertFalse(game.label.contains("LIVE"), "on before its kickoff: \(game.label)")
        let wait = kickoff + 5 - (try markTime(server))
        XCTAssertGreaterThan(wait, 5, "the tries outlasted the kickoff")
        sleep(UInt32(wait))
        openSports()
        XCTAssertTrue(game.waitForExistence(timeout: 10), "the game left Sports")
        XCTAssertTrue(game.label.contains("LIVE"), "not live at its kickoff: \(game.label)")
        XCTAssertFalse(game.label.contains("Not playing"), "a try before kickoff outlived it: \(game.label)")
        XCTAssertTrue(game.label.contains("5 channels"), "channels tried before kickoff still left out: \(game.label)")

        app.terminate()
        app.launch()
        openSports()
        XCTAssertTrue(game.waitForExistence(timeout: 15), "the game isn't in Sports")
        sleep(5)
        XCTAssertFalse(game.label.contains("Not playing"), "the server's mark from before kickoff outlived it: \(game.label)")
    }

    func testSharedMarkLastsFifteenMinutes() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["reset": "1"])
        configure(server, ["sports": "1", "dead_live": "none"])
        addTeardownBlock { [self] in configure(server, ["reset": "1"]) }
        app.launchArguments = ["-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        let game = gameRow()

        try markNotPlaying(server, minutesAgo: 14)
        app.launch()
        openSports()
        XCTAssertTrue(game.waitForExistence(timeout: 15), "the game isn't in Sports")
        let shown = Date().addingTimeInterval(10)
        while !game.label.contains("Not playing"), Date() < shown { usleep(250_000) }
        XCTAssertTrue(game.label.contains("Not playing"), "another device's finding 14 min ago isn't shown: \(game.label)")
        try assertTileCrossedOut(game)
        app.terminate()

        try markNotPlaying(server, minutesAgo: 16)
        app.launch()
        openSports()
        XCTAssertTrue(game.waitForExistence(timeout: 15), "the game isn't in Sports")
        sleep(5)
        XCTAssertFalse(game.label.contains("Not playing"), "another device's finding 16 min ago is still shown: \(game.label)")
        XCTAssertTrue(game.label.contains("LIVE"), "the game isn't live: \(game.label)")
    }

    func testGameNotPlayingStillOpensAndPlayingClearsIt() throws {
        let server = try XCTUnwrap(testServer(), "no test server")
        configure(server, ["reset": "1"])
        configure(server, ["sports": "1", "dead_live": "2001,2002,2003,2004,2005"])
        addTeardownBlock { [self] in configure(server, ["reset": "1"]) }
        app.launchEnvironment["OPENREEL_DEBUG_LIVE_START_LIMIT"] = "3"
        app.launchArguments = ["-freshLineup", "YES", "-forgetWatchOnPicks", "YES"]
        app.launch()
        openGame()
        XCTAssertTrue(failed(within: 40), "still trying after every channel: \(liveCopy())")
        closePlayer()
        let game = gameRow()
        XCTAssertTrue(game.waitForExistence(timeout: 10), "the game left Sports")
        XCTAssertTrue(game.label.contains("Not playing"), "no word that nothing played: \(game.label)")

        configure(server, ["dead_live": "none"])
        game.tap()
        XCTAssertTrue(started(), "a game marked as not playing didn't play: \(liveCopy())")
        closePlayer()
        XCTAssertTrue(game.waitForExistence(timeout: 10), "the game left Sports")
        XCTAssertTrue(game.label.contains("LIVE") && !game.label.contains("Not playing"), "playing didn't clear the mark: \(game.label)")
        XCTAssertFalse(game.label.contains("5 channels"), "the feeds that didn't play are counted: \(game.label)")
    }

    private func assertTileCrossedOut(_ game: XCUIElement, file: StaticString = #filePath, line: UInt = #line) throws {
        sleep(1)
        let shot = XCUIScreen.main.screenshot()
        let logo = try XCTUnwrap(tile(of: game, in: shot), "no logo tile on the game's row", file: file, line: line)
        let corner = badge(on: logo).insetBy(dx: 2, dy: 2)
        let countCapsule = CGRect(x: corner.maxX - 24, y: corner.minY, width: 24, height: corner.height)
        XCTAssertGreaterThan(brightest(shot, in: corner), 200, "no crossed-out TV on the game's tile", file: file, line: line)
        XCTAssertLessThan(luminance(shot, in: countCapsule), 120,
                          "a channel count on the tile of a game that played nowhere (mean \(Int(luminance(shot, in: countCapsule))))",
                          file: file, line: line)
    }

    private func gameRow() -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS 'Jaguars'")).firstMatch
    }

    private func failed(within seconds: Double) -> Bool {
        let state = app.staticTexts["debug-live-state"].firstMatch
        let deadline = Date().addingTimeInterval(seconds)
        while state.label != "failed", Date() < deadline { usleep(250_000) }
        return state.label == "failed"
    }

    private func closePlayer() {
        showControls()
        app.buttons["Close player"].firstMatch.tap()
    }

    private func markNotPlaying(_ server: URL, minutesAgo: Double) throws {
        let at = Int(try markTime(server) - minutesAgo * 60)
        let place = try XCTUnwrap(server.host(), "the test server has no host")
        let record = Dictionary(uniqueKeysWithValues: (2001...2005).map { id in
            (SHA256.hash(data: Data("\(place)|\(id)".utf8)).prefix(10).map { String(format: "%02x", $0) }.joined(), String(at))
        })
        var parts = URLComponents(url: server.appending(path: "DisplayPreferences/zapline-notplaying"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "userId", value: "U1"), .init(name: "client", value: "zapline")]
        var request = URLRequest(url: parts.url!)
        request.httpMethod = "POST"
        request.setValue("tok", forHTTPHeaderField: "X-Emby-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["CustomPrefs": record])
        var status: Int?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            status = (response as? HTTPURLResponse)?.statusCode
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 10)
        XCTAssertEqual(status, 204, "the test server didn't keep the record")
    }

    private func moveOffDeadOneSoccerSlot(_ server: URL) throws -> String {
        openGame()
        XCTAssertTrue(started(), "the game didn't play: \(liveCopy())")
        showControls()
        app.buttons["Watch On"].firstMatch.tap()
        let soccer = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'player.card.' AND label BEGINSWITH 'OneSoccer'")).firstMatch
        XCTAssertTrue(soccer.waitForExistence(timeout: 5), "no OneSoccer in Watch On")
        let dead = String(try XCTUnwrap(soccer.identifier.split(separator: "|").last))
        let slots = ["2006": "Soccer04", "2007": "Soccer05"]
        let deadName = try XCTUnwrap(slots[dead], "the OneSoccer card isn't one of its two slots: \(soccer.identifier)")
        let twin = try XCTUnwrap(slots.first { $0.key != dead }?.value)
        configure(server, ["dead_live": dead])
        soccer.tap()
        XCTAssertTrue(playing(deadName), "the channel picked didn't open: \(liveCopy())")
        let readout = app.staticTexts["debug-live-copy"].firstMatch
        let deadline = Date().addingTimeInterval(20)
        while readout.label.hasPrefix(deadName), Date() < deadline { usleep(250_000) }
        XCTAssertTrue(readout.label.hasPrefix(twin), "moved to \(liveCopy()), not the picked feed's other slot \(twin)")
        XCTAssertTrue(started(), "the other slot didn't play")
        return twin
    }

    private func channelFive() -> XCUIElement {
        let tab = app.tabBars.buttons["Live TV"].firstMatch
        if tab.waitForExistence(timeout: 10) { tab.tap() }
        let five = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Channel 5'")).firstMatch
        XCTAssertTrue(five.waitForExistence(timeout: 20), "no Channel 5 in the UK list")
        return five
    }

    private func startOver() {
        showControls()
        app.buttons["More"].firstMatch.tap()
        let button = app.buttons["Start Over"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "no Start Over in the player's menu")
        button.tap()
    }

    private func pickSpanishThatDoesntPlay() {
        openGame()
        XCTAssertTrue(playing("NFL 01"), "the game didn't start on the best channel: \(liveCopy())")
        XCTAssertTrue(started(), "the game didn't play")
        showControls()
        app.buttons["Watch On"].firstMatch.tap()
        let spanish = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'player.card.' AND label CONTAINS 'Spanish'")).firstMatch
        XCTAssertTrue(spanish.waitForExistence(timeout: 5), "no Spanish feed in Watch On")
        spanish.tap()
        XCTAssertTrue(playing("ESPN UNLTD 016"), "the channel picked didn't open: \(liveCopy())")
        XCTAssertTrue(waitForCue("ESPN Unlimited (Spanish) didn’t play", "Now on NFL"), "the cue doesn't say what happened: \(cueWords())")
        XCTAssertTrue(started(), "NFL didn't play again: \(liveCopy())")
    }

    private var switchCue: XCUIElement { app.descendants(matching: .any)["live.switch-cue"].firstMatch }

    private func cueWords() -> String { switchCue.exists ? switchCue.label : "no cue" }

    private func waitForCue(_ words: String..., timeout: Double = 20) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if switchCue.exists, words.allSatisfy(switchCue.label.contains) { return true }
            usleep(200_000)
        }
        return false
    }

    private func picture(of watchOnCard: XCUIElement) -> CGRect {
        let size = CGSize(width: 86, height: 48), rowPadding: CGFloat = 10
        return CGRect(origin: CGPoint(x: watchOnCard.frame.minX, y: watchOnCard.frame.minY + rowPadding), size: size)
    }

    private func badge(on picture: CGRect) -> CGRect {
        let size: CGFloat = 17, outset: CGFloat = 6
        return CGRect(x: picture.maxX + outset - size, y: picture.maxY + outset - size, width: size, height: size)
    }

    private func tile(of row: XCUIElement, in shot: XCUIScreenshot) -> CGRect? {
        let area = CGRect(x: row.frame.minX, y: row.frame.minY, width: min(140, row.frame.width), height: row.frame.height)
        guard let found = pixels(shot, in: area) else { return nil }
        let (data, width, height, scale) = found
        func grey(_ x: Int, _ y: Int) -> Bool {
            let i = (y * width + x) * 4
            let r = Int(data[i]), g = Int(data[i + 1]), b = Int(data[i + 2])
            return (28...46).contains(r) && abs(r - g) < 5 && abs(r - b) < 5
        }
        func longest(_ count: Int, _ isGrey: (Int) -> Bool) -> (start: Int, end: Int)? {
            var best: (start: Int, end: Int)?, start: Int?
            for i in 0...count {
                if i < count, isGrey(i) { start = start ?? i; continue }
                if let s = start, i - s > (best.map { $0.end - $0.start } ?? 0) { best = (s, i - 1) }
                start = nil
            }
            return best
        }
        let down = (0..<width).compactMap { x in longest(height) { grey(x, $0) } }.filter { CGFloat($0.end - $0.start) > 30 * scale }
        guard let minY = down.map(\.start).min(), let maxY = down.map(\.end).max() else { return nil }
        let across = (minY...maxY).compactMap { y in longest(width) { grey($0, y) } }.filter { CGFloat($0.end - $0.start) > 40 * scale }
        guard let minX = across.map(\.start).min(), let maxX = across.map(\.end).max() else { return nil }
        return CGRect(x: area.minX + CGFloat(minX) / scale, y: area.minY + CGFloat(minY) / scale,
                      width: CGFloat(maxX - minX + 1) / scale, height: CGFloat(maxY - minY + 1) / scale)
    }

    private func brightest(_ shot: XCUIScreenshot, in rect: CGRect) -> Double {
        guard let data = pixels(shot, in: rect)?.data else { return 0 }
        return stride(from: 0, to: data.count, by: 4).map { lum(data, $0) }.max() ?? 0
    }

    private func luminance(_ shot: XCUIScreenshot, in rect: CGRect) -> Double {
        guard let data = pixels(shot, in: rect)?.data, !data.isEmpty else { return 0 }
        return stride(from: 0, to: data.count, by: 4).map { lum(data, $0) }.reduce(0, +) / Double(data.count / 4)
    }

    private func lum(_ data: [UInt8], _ i: Int) -> Double {
        0.2126 * Double(data[i]) + 0.7152 * Double(data[i + 1]) + 0.0722 * Double(data[i + 2])
    }

    private func pixels(_ shot: XCUIScreenshot, in rect: CGRect) -> (data: [UInt8], width: Int, height: Int, scale: CGFloat)? {
        guard let image = shot.image.cgImage else { return nil }
        let scale = CGFloat(image.width) / app.frame.width
        let box = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale).integral
        guard let crop = image.cropping(to: box) else { return nil }
        let width = crop.width, height = crop.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (data, width, height, scale)
    }

    /// Live TV → Sports.
    private func openSports() {
        let tab = app.tabBars.buttons["Live TV"].firstMatch
        if tab.waitForExistence(timeout: 10) { tab.tap() }
        let sports = app.buttons["Sports"].firstMatch
        if sports.waitForExistence(timeout: 20) { sports.tap() }
    }

    /// Live TV → Sports → the game.
    private func openGame() {
        let tab = app.tabBars.buttons["Live TV"].firstMatch
        if tab.waitForExistence(timeout: 10) { tab.tap() }
        let sports = app.buttons["Sports"].firstMatch
        if sports.waitForExistence(timeout: 10) { sports.tap() }
        let game = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Jaguars'")).firstMatch
        XCTAssertTrue(game.waitForExistence(timeout: 15), "the game isn't in Sports")
        game.tap()
    }

    /// The live player shows a picture within 15 s.
    private func started() -> Bool {
        let readout = app.staticTexts["debug-live-state"].firstMatch
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if readout.exists, readout.label == "playing" { return true }
            usleep(250_000)
        }
        return false
    }

    private func liveCopy() -> String {
        app.staticTexts["debug-live-copy"].firstMatch.label
    }

    /// The channel open in the player starts with `name`, within 10 s.
    private func playing(_ name: String) -> Bool {
        let readout = app.staticTexts["debug-live-copy"].firstMatch
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if readout.exists, readout.label.hasPrefix(name) { return true }
            usleep(250_000)
        }
        return false
    }

    private func showControls() {
        guard !app.buttons["Close player"].firstMatch.exists else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        _ = app.buttons["Close player"].firstMatch.waitForExistence(timeout: 3)
    }

    private func testServer() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment["DEBUG_EMBY"],
              let json = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let address = json["serverURL"] as? String else { return nil }
        return URL(string: address)
    }

    /// The test server's clock, for `lineupRequests(since:)`.
    private func markTime(_ server: URL) throws -> Double {
        let clock: [String: Double] = try answer(server.appending(path: "mock/mark"))
        return try XCTUnwrap(clock["t"], "the test server's clock has no time")
    }

    /// The lineup the app asked the provider for since `since`: "account",
    /// "get_live_categories", "get_live_streams" or "get_live_streams:<cat>"
    /// (one category); not the guide requests its rows make.
    private func lineupRequests(_ server: URL, since: Double) throws -> [String] {
        let url = server.appending(path: "mock/xtream_requests").appending(queryItems: [.init(name: "since", value: String(since))])
        let requests: [String: [String]] = try answer(url)
        let items = try XCTUnwrap(requests["items"], "the test server's request list has no items")
        return items.filter { $0 == "account" || $0.hasPrefix("get_live_") }
    }

    /// The test server's JSON answer to `url`. No answer in 10 s, another
    /// status, or other JSON fails the test: a count that couldn't be read
    /// never passes as none.
    private func answer<Answer>(_ url: URL) throws -> Answer {
        var data: Data?
        var status: Int?
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { body, response, _ in
            data = body
            status = (response as? HTTPURLResponse)?.statusCode
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 10)
        let body = try XCTUnwrap(status == 200 ? data : nil, "the test server's answer to \(url.path): status \(status.map(String.init) ?? "none")")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? Answer, "the test server's answer to \(url.path) isn't the JSON expected")
    }

    /// Sets the test server's behaviour (scripts/mock_server.py, /mock/set).
    private func configure(_ server: URL, _ settings: [String: String]) {
        let url = server.appending(path: "mock/set").appending(queryItems: settings.map { URLQueryItem(name: $0.key, value: $0.value) })
        // A semaphore, not an expectation: it runs in tear-down too.
        let done = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: url) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 10)
    }
}

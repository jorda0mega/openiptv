import XCTest
@testable import OpenIPTV

final class AccountSessionTests: XCTestCase {
    private let tester = EmbyAccount(serverURL: URL(string: "http://server")!, serverName: "Mock", userId: "U1", userName: "tester",
                                     accessToken: "test")
    private let other = EmbyAccount(serverURL: URL(string: "http://other")!, serverName: "Other", userId: "U2", userName: "other",
                                    accessToken: "test")

    private func session(signedIn: Bool, _ events: [AccountSession.Event]) -> (AccountSession, [[AccountSession.Effect]]) {
        var session = AccountSession(signedIn: signedIn)
        let effects = events.map { session.on($0) }
        return (session, effects)
    }

    func testSignInOpensAFreshScopeAndBuildsHome() {
        let (session, effects) = session(signedIn: false, [.signedIn(tester)])
        XCTAssertEqual(effects, [[.open(tester), .loadHome]])
        XCTAssertEqual(session.phase, .signedIn)
    }

    func testSignOutAndForgetEverythingCloseTheScopeTheSameWay() {
        let (_, signOut) = session(signedIn: true, [.signOut])
        let (_, forget) = session(signedIn: true, [.forgetEverything])
        XCTAssertEqual(signOut, [[.closeScope, .forgetShared, .logOut]])
        XCTAssertEqual(forget, signOut)
    }

    func testSignOutWipesTheAccountOnceLoggedOut() {
        let (session, effects) = session(signedIn: true, [.signOut, .loggedOut])
        XCTAssertEqual(effects[1], [.wipe(.account)])
        XCTAssertEqual(session.phase, .signedOut)
    }

    func testForgetEverythingWipesEverythingOnceLoggedOut() {
        let (session, effects) = session(signedIn: true, [.forgetEverything, .loggedOut])
        XCTAssertEqual(effects[1], [.wipe(.everything)])
        XCTAssertEqual(session.phase, .signedOut)
    }

    func testForgetEverythingWhenSignedOutStillClosesAndWipesEverything() {
        let (session, effects) = session(signedIn: false, [.forgetEverything, .loggedOut])
        XCTAssertEqual(effects, [[.closeScope, .forgetShared, .logOut], [.wipe(.everything)]])
        XCTAssertEqual(session.phase, .signedOut)
    }

    func testForgetEverythingDuringSignOutWipesEverything() {
        let (session, effects) = session(signedIn: true, [.signOut, .forgetEverything, .loggedOut])
        XCTAssertEqual(effects[1], [], "the scope is closed and the logout under way already")
        XCTAssertEqual(effects[2], [.wipe(.everything)])
        XCTAssertEqual(session.phase, .signedOut)
    }

    func testASecondSignOutWhileLeavingDoesNothing() {
        let (session, effects) = session(signedIn: true, [.signOut, .signOut, .forgetEverything, .forgetEverything])
        XCTAssertEqual(effects[1], [])
        XCTAssertEqual(effects[3], [])
        XCTAssertEqual(session.phase, .leaving(.everything))
    }

    func testSigningOutWhenSignedOutDoesNothing() {
        let (session, effects) = session(signedIn: false, [.signOut, .loggedOut])
        XCTAssertEqual(effects, [[], []])
        XCTAssertEqual(session.phase, .signedOut)
    }

    func testASignInWhileLeavingChangesNothing() {
        let (session, effects) = session(signedIn: true, [.signOut, .signedIn(other)])
        XCTAssertEqual(effects[1], [])
        XCTAssertEqual(session.phase, .leaving(.account))
    }

    func testASecondSignInWhileSignedInChangesNothing() {
        let (session, effects) = session(signedIn: true, [.signedIn(other)])
        XCTAssertEqual(effects, [[]], "an account is signed out before another signs in")
        XCTAssertEqual(session.phase, .signedIn)
    }
}

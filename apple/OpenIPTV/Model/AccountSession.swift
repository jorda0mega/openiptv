import Foundation

/// The Emby account's life on this device. Leaving closes the account's
/// scope at once; what's saved goes once the server has logged it out.
struct AccountSession: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case signedOut
        case signedIn
        case leaving(Wipe)
    }

    enum Wipe: Equatable, Sendable {
        case account, everything
    }

    enum Event: Equatable, Sendable {
        case signedIn(EmbyAccount)
        case signOut, forgetEverything
        case loggedOut
    }

    enum Effect: Equatable, Sendable {
        case closeScope
        /// The account's files fetched ahead, kept starts, server subtitles and library index.
        case forgetShared
        case logOut
        case wipe(Wipe)
        case open(EmbyAccount)
        case loadHome
    }

    private(set) var phase: Phase

    init(signedIn: Bool) {
        phase = signedIn ? .signedIn : .signedOut
    }

    mutating func on(_ event: Event) -> [Effect] {
        switch (phase, event) {
        case let (.signedOut, .signedIn(account)):
            phase = .signedIn
            return [.open(account), .loadHome]
        case let (.signedIn, .signedIn(account)):
            return [.closeScope, .forgetShared, .wipe(.account), .open(account), .loadHome]
        case (.signedIn, .signOut):
            phase = .leaving(.account)
            return [.closeScope, .forgetShared, .logOut]
        case (.signedIn, .forgetEverything), (.signedOut, .forgetEverything):
            phase = .leaving(.everything)
            return [.closeScope, .forgetShared, .logOut]
        case (.leaving(.account), .forgetEverything):
            phase = .leaving(.everything)
            return []
        case let (.leaving(wipe), .loggedOut):
            phase = .signedOut
            return [.wipe(wipe)]
        default:
            return []
        }
    }
}

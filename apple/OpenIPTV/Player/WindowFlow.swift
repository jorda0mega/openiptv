import Foundation

struct WindowFlow: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case none
        /// iOS may start the window by itself.
        case inline
        /// `appBack`: the app came back before iOS said the window was up.
        case starting(byButton: Bool, appBack: Bool)
        case windowed(screenClosed: Bool)
        /// The player screen shows the film; the window is up until iOS says it stopped.
        case closingWindow
        /// The dock holds the film's layer until the player screen takes it. `reclaimed`: the screen has the player.
        case awaitingScreen(reclaimed: Bool, restoreWaiting: Bool, windowUp: Bool)
    }

    enum Event: Equatable, Sendable {
        case offered, buttonTapped, willStart, didStart, failedToStart
        /// iOS waits until `finishRestore` runs.
        case restoreAsked
        case appOpened, appLeft
        /// The player screen took the film back (the window's restore, or the film chosen again).
        case reclaimed
        case screenHosts
        case didStop, restoreTimedOut
        case screenLetGo
        case otherTitle
        case filmEnded
    }

    enum Effect: Equatable, Sendable {
        case startWindow, stopWindow
        case framesToWindow, framesToScreen
        case measureStart, measureReturn
        case dock, closeScreen, presentScreen, armRestoreTimeout
        case finishRestore(Bool)
        case pausePlayer, stopFilm, releaseController, noteUnavailable
    }

    private(set) var phase = Phase.none

    var keepsFilm: Bool {
        switch phase {
        case .windowed(screenClosed: true), .awaitingScreen(reclaimed: false, _, _): true
        default: false
        }
    }

    /// iOS may deliver these in either order, twice, or late.
    mutating func on(_ event: Event) -> [Effect] {
        switch (phase, event) {
        case (.none, .offered):
            phase = .inline
            return []
        case (.inline, .buttonTapped):
            phase = .starting(byButton: true, appBack: false)
            return [.measureStart, .framesToWindow, .startWindow]
        case (.inline, .willStart):
            phase = .starting(byButton: false, appBack: false)
            return [.measureStart, .framesToWindow]
        case (.starting(byButton: false, _), .appOpened):
            phase = .starting(byButton: false, appBack: true)
            return []
        case (.starting(byButton: false, appBack: true), .appLeft):
            phase = .starting(byButton: false, appBack: false)
            return []
        case (.starting(_, appBack: true), .didStart):
            phase = .closingWindow
            return [.measureReturn, .framesToScreen, .stopWindow]
        case let (.starting(byButton, _), .didStart):
            phase = .windowed(screenClosed: byButton)
            return byButton ? [.dock, .closeScreen] : []
        case let (.starting(byButton, _), .failedToStart):
            phase = .inline
            return byButton ? [.framesToScreen, .noteUnavailable] : [.framesToScreen]

        case (.windowed(screenClosed: false), .restoreAsked):
            phase = .closingWindow
            return [.measureReturn, .framesToScreen, .finishRestore(true)]
        case (.windowed(screenClosed: false), .appOpened):
            phase = .closingWindow
            return [.measureReturn, .framesToScreen, .stopWindow]
        case (.windowed(screenClosed: false), .didStop):
            phase = .inline
            return [.framesToScreen, .pausePlayer]
        case (.windowed(screenClosed: true), .restoreAsked):
            phase = .awaitingScreen(reclaimed: false, restoreWaiting: true, windowUp: true)
            return [.measureReturn, .presentScreen, .armRestoreTimeout]
        case (.windowed(screenClosed: true), .reclaimed):
            phase = .awaitingScreen(reclaimed: true, restoreWaiting: false, windowUp: true)
            return [.measureReturn, .stopWindow]
        case (.windowed(screenClosed: true), .didStop):
            phase = .none
            return [.stopFilm, .releaseController]
        case (.windowed(screenClosed: true), .filmEnded):
            return [.stopWindow]
        case (.windowed(screenClosed: true), .otherTitle):
            phase = .none
            return [.stopWindow, .stopFilm, .releaseController]

        case (.closingWindow, .restoreAsked):
            return [.finishRestore(true)]
        case (.closingWindow, .didStop):
            phase = .inline
            return []

        case let (.awaitingScreen(false, restoreWaiting, windowUp), .reclaimed):
            phase = .awaitingScreen(reclaimed: true, restoreWaiting: restoreWaiting, windowUp: windowUp)
            return []
        case let (.awaitingScreen(_, restoreWaiting, windowUp), .screenHosts):
            phase = windowUp ? .closingWindow : .inline
            return [.framesToScreen] + (restoreWaiting ? [.finishRestore(true)] : [])
        case let (.awaitingScreen(reclaimed, false, windowUp), .restoreAsked):
            phase = .awaitingScreen(reclaimed: reclaimed, restoreWaiting: true, windowUp: windowUp)
            return [.armRestoreTimeout]
        case (.awaitingScreen(_, restoreWaiting: true, _), .restoreAsked):
            return []
        case let (.awaitingScreen(reclaimed, restoreWaiting, true), .didStop):
            phase = .awaitingScreen(reclaimed: reclaimed, restoreWaiting: restoreWaiting, windowUp: false)
            return []
        case let (.awaitingScreen(true, restoreWaiting, windowUp), .restoreTimedOut):
            phase = .awaitingScreen(reclaimed: true, restoreWaiting: false, windowUp: windowUp)
            return restoreWaiting ? [.finishRestore(false)] : []
        case let (.awaitingScreen(false, restoreWaiting, windowUp), .restoreTimedOut),
             let (.awaitingScreen(false, restoreWaiting, windowUp), .otherTitle):
            phase = .none
            return (restoreWaiting ? [.finishRestore(false)] : []) + (windowUp ? [.stopWindow] : []) + [.stopFilm, .releaseController]
        case let (.awaitingScreen(true, restoreWaiting, windowUp), .screenLetGo):
            phase = .none
            return (restoreWaiting ? [.finishRestore(false)] : []) + (windowUp ? [.stopWindow] : []) + [.releaseController]

        case (.inline, .screenLetGo):
            phase = .none
            return [.releaseController]
        case (.starting, .screenLetGo), (.windowed(screenClosed: false), .screenLetGo), (.closingWindow, .screenLetGo):
            phase = .none
            return [.stopWindow, .releaseController]

        case (_, .restoreAsked):
            return [.finishRestore(false)]
        default:
            return []
        }
    }
}

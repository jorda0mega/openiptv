import Foundation

struct WindowFlow: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case none
        /// iOS may start the window by itself.
        case inline
        case starting(byButton: Bool)
        case windowed(screenClosed: Bool)
        case returning(screenClosed: Bool, restoreWaiting: Bool, windowUp: Bool)
    }

    enum Event: Equatable, Sendable {
        case offered, buttonTapped, willStart, didStart, failedToStart
        /// iOS waits until `finishRestore` runs.
        case restoreAsked
        case appOpened
        case chosenAgain
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
        case .windowed(screenClosed: true), .returning(screenClosed: true, _, _): true
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
            phase = .starting(byButton: true)
            return [.measureStart, .framesToWindow, .startWindow]
        case (.inline, .willStart):
            phase = .starting(byButton: false)
            return [.measureStart, .framesToWindow]
        case let (.starting(byButton), .didStart):
            phase = .windowed(screenClosed: byButton)
            return byButton ? [.dock, .closeScreen] : []
        case let (.starting(byButton), .failedToStart):
            phase = .inline
            return byButton ? [.framesToScreen, .noteUnavailable] : [.framesToScreen]

        case (.windowed(screenClosed: false), .restoreAsked):
            phase = .returning(screenClosed: false, restoreWaiting: false, windowUp: true)
            return [.measureReturn, .framesToScreen, .finishRestore(true)]
        case (.windowed(screenClosed: false), .appOpened):
            phase = .returning(screenClosed: false, restoreWaiting: false, windowUp: true)
            return [.measureReturn, .framesToScreen, .stopWindow]
        case (.windowed(screenClosed: false), .didStop):
            phase = .inline
            return [.framesToScreen, .pausePlayer]
        case (.windowed(screenClosed: true), .restoreAsked):
            phase = .returning(screenClosed: true, restoreWaiting: true, windowUp: true)
            return [.measureReturn, .presentScreen, .armRestoreTimeout]
        case (.windowed(screenClosed: true), .chosenAgain):
            phase = .returning(screenClosed: true, restoreWaiting: false, windowUp: true)
            return [.measureReturn, .stopWindow]
        case (.windowed(screenClosed: true), .didStop):
            phase = .none
            return [.stopFilm, .releaseController]
        case (.windowed(screenClosed: true), .filmEnded):
            return [.stopWindow]

        case let (.returning(screenClosed, restoreWaiting, windowUp), .screenHosts) where screenClosed:
            phase = windowUp ? .returning(screenClosed: false, restoreWaiting: false, windowUp: true) : .inline
            return [.framesToScreen] + (restoreWaiting ? [.finishRestore(true)] : [])
        case let (.returning(screenClosed, restoreWaiting, windowUp), .restoreAsked) where !restoreWaiting:
            if screenClosed {
                phase = .returning(screenClosed: true, restoreWaiting: true, windowUp: windowUp)
                return [.armRestoreTimeout]
            }
            return [.finishRestore(true)]
        case let (.returning(screenClosed, restoreWaiting, windowUp), .didStop) where windowUp:
            phase = screenClosed ? .returning(screenClosed: true, restoreWaiting: restoreWaiting, windowUp: false) : .inline
            return []
        case let (.returning(screenClosed, restoreWaiting, windowUp), .restoreTimedOut) where screenClosed,
             let (.returning(screenClosed, restoreWaiting, windowUp), .otherTitle) where screenClosed:
            return releaseDockedFilm(restoreWaiting: restoreWaiting, windowUp: windowUp)
        case (.windowed(screenClosed: true), .otherTitle):
            return releaseDockedFilm(restoreWaiting: false, windowUp: true)

        case (.inline, .screenLetGo):
            phase = .none
            return [.releaseController]
        case (.starting, .screenLetGo), (.windowed(screenClosed: false), .screenLetGo):
            phase = .none
            return [.stopWindow, .releaseController]
        case let (.returning(screenClosed, _, windowUp), .screenLetGo) where !screenClosed:
            phase = .none
            return (windowUp ? [.stopWindow] : []) + [.releaseController]

        default:
            return []
        }
    }

    private mutating func releaseDockedFilm(restoreWaiting: Bool, windowUp: Bool) -> [Effect] {
        phase = .none
        return (restoreWaiting ? [.finishRestore(false)] : []) + (windowUp ? [.stopWindow] : []) + [.stopFilm, .releaseController]
    }
}

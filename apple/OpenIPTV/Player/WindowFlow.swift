import Foundation

/// Picture in Picture for the one film offered, as events in and effects out (PictureInPicture runs the
/// effects). An event that doesn't apply changes nothing and asks for nothing, so iOS's callbacks may come in
/// either order, twice, or late.
struct WindowFlow: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case none
        /// On the player screen; iOS may start the window by itself.
        case inline
        case starting(byButton: Bool)
        /// `docked`: the player screen closed (the button); the dock holds the film's layer.
        case windowed(docked: Bool)
        /// Back to the player screen. `docked` until the screen holds the layer again; `waiting`: iOS's restore
        /// waits for that; `windowUp` until iOS says the window stopped.
        case returning(docked: Bool, waiting: Bool, windowUp: Bool)
    }

    enum Event: Equatable, Sendable {
        case offered, buttonTapped, willStart, didStart, failedToStart
        /// The window's restore button (iOS waits for `finishRestore`).
        case restoreAsked
        case appOpened
        /// The same film chosen again in the app while the window has it.
        case chosenAgain
        /// The player screen holds the film's layer again.
        case screenHosts
        case didStop, restoreTimedOut
        /// The player screen closed with the film.
        case screenLetGo
        /// Another title starts.
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

    /// The window holds the film with no player screen: the screen that closed must leave the player running.
    var keepsFilm: Bool {
        switch phase {
        case .windowed(docked: true), .returning(docked: true, _, _): true
        default: false
        }
    }

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
            phase = .windowed(docked: byButton)
            return byButton ? [.dock, .closeScreen] : []
        case let (.starting(byButton), .failedToStart):
            phase = .inline
            return byButton ? [.framesToScreen, .noteUnavailable] : [.framesToScreen]

        case (.windowed(docked: false), .restoreAsked):
            phase = .returning(docked: false, waiting: false, windowUp: true)
            return [.measureReturn, .framesToScreen, .finishRestore(true)]
        case (.windowed(docked: false), .appOpened):
            phase = .returning(docked: false, waiting: false, windowUp: true)
            return [.measureReturn, .framesToScreen, .stopWindow]
        case (.windowed(docked: false), .didStop):
            phase = .inline
            return [.framesToScreen, .pausePlayer]
        case (.windowed(docked: true), .restoreAsked):
            phase = .returning(docked: true, waiting: true, windowUp: true)
            return [.measureReturn, .presentScreen, .armRestoreTimeout]
        case (.windowed(docked: true), .chosenAgain):
            phase = .returning(docked: true, waiting: false, windowUp: true)
            return [.measureReturn, .stopWindow]
        case (.windowed(docked: true), .didStop):
            phase = .none
            return [.stopFilm, .releaseController]
        case (.windowed(docked: true), .filmEnded):
            return [.stopWindow]

        case let (.returning(docked, waiting, windowUp), .screenHosts) where docked:
            phase = windowUp ? .returning(docked: false, waiting: false, windowUp: true) : .inline
            return [.framesToScreen] + (waiting ? [.finishRestore(true)] : [])
        case let (.returning(docked, waiting, windowUp), .restoreAsked) where !waiting:
            if docked {
                phase = .returning(docked: true, waiting: true, windowUp: windowUp)
                return [.armRestoreTimeout]
            }
            return [.finishRestore(true)]
        case let (.returning(docked, waiting, windowUp), .didStop) where windowUp:
            phase = docked ? .returning(docked: true, waiting: waiting, windowUp: false) : .inline
            return []
        case let (.returning(docked, waiting, windowUp), .restoreTimedOut) where docked:
            phase = .none
            return (waiting ? [.finishRestore(false)] : []) + (windowUp ? [.stopWindow] : []) + [.stopFilm, .releaseController]

        case let (.returning(docked, waiting, windowUp), .otherTitle) where docked:
            phase = .none
            return (waiting ? [.finishRestore(false)] : []) + (windowUp ? [.stopWindow] : []) + [.stopFilm, .releaseController]
        case (.windowed(docked: true), .otherTitle):
            phase = .none
            return [.stopWindow, .stopFilm, .releaseController]

        case (.inline, .screenLetGo):
            phase = .none
            return [.releaseController]
        case (.starting, .screenLetGo), (.windowed(docked: false), .screenLetGo):
            phase = .none
            return [.stopWindow, .releaseController]
        case let (.returning(docked, _, windowUp), .screenLetGo) where !docked:
            phase = .none
            return (windowUp ? [.stopWindow] : []) + [.releaseController]

        default:
            return []
        }
    }
}

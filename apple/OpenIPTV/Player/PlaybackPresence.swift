import Foundation
#if canImport(UIKit)
import SwiftUI
#endif
#if os(tvOS)
import MediaPlayer
#endif

struct PlaybackPresence: Equatable, Sendable {
    enum App: Equatable, Sendable {
        case active, inactive, background
    }

    enum Event: Equatable, Sendable {
        case moving(Bool)
        case app(App)
    }

    enum Effect: Equatable, Sendable {
        case pause
    }

    let pausesWhenAway: Bool
    private(set) var moving = false
    private(set) var app = App.active

    var keepsAwake: Bool { moving }

    mutating func on(_ event: Event) -> [Effect] {
        switch event {
        case let .moving(on): moving = on
        case let .app(now): app = now
        }
        return pausesWhenAway && moving && app == .background ? [.pause] : []
    }
}

#if canImport(UIKit)
extension PlaybackPresence {
    #if os(tvOS)
    static let here = PlaybackPresence(pausesWhenAway: true)
    #else
    static let here = PlaybackPresence(pausesWhenAway: false)
    #endif
}

extension PlaybackPresence.App {
    init(_ phase: ScenePhase) {
        switch phase {
        case .active: self = .active
        case .background: self = .background
        default: self = .inactive
        }
    }
}

@MainActor
enum ScreenAwake {
    private static var playing: Set<UUID> = []

    static func open(_ player: UUID, title: String, live: Bool, pause: @escaping @MainActor (Bool) -> Void) {
        #if os(tvOS)
        NowPlaying.open(player, title: title, live: live, playing: playing.contains(player), pause: pause)
        #endif
    }

    static func set(_ player: UUID, playing on: Bool) {
        if on { playing.insert(player) } else { playing.remove(player) }
        UIApplication.shared.isIdleTimerDisabled = !playing.isEmpty
        #if os(tvOS)
        NowPlaying.set(player, playing: on)
        #endif
    }

    static func close(_ player: UUID) {
        set(player, playing: false)
        #if os(tvOS)
        NowPlaying.close(player)
        #endif
    }
}

#if os(tvOS)
/// tvOS sleeps after its "Sleep After" time unless Now Playing says
/// something plays: the idle timer holds back the screen saver alone.
@MainActor
private enum NowPlaying {
    private static var owner: UUID?
    private static var targets: [Any] = []
    private static var asked: (@MainActor (Bool) -> Void)?

    static func open(_ player: UUID, title: String, live: Bool, playing: Bool, pause: @escaping @MainActor (Bool) -> Void) {
        removeTargets()
        owner = player
        asked = pause
        #if DEBUG
        planDebugAsks()
        #endif
        let commands = MPRemoteCommandCenter.shared()
        targets = [
            commands.pauseCommand.addTarget { _ in
                Task { @MainActor in pause(true) }
                return .success
            },
            commands.playCommand.addTarget { _ in
                Task { @MainActor in pause(false) }
                return .success
            },
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: title,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: live,
            MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
        ]
    }

    static func set(_ player: UUID, playing: Bool) {
        guard owner == player else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPNowPlayingInfoPropertyPlaybackRate] = playing ? 1.0 : 0.0
    }

    static func close(_ player: UUID) {
        guard owner == player else { return }
        removeTargets()
        owner = nil
        asked = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    #if DEBUG
    private static var debugAsksPlanned = false

    private static func planDebugAsks() {
        guard !debugAsksPlanned, let plan = ProcessInfo.processInfo.environment["OPENREEL_DEBUG_NOW_PLAYING_ASKS"] else { return }
        debugAsksPlanned = true
        for step in plan.split(separator: ",") {
            let parts = step.split(separator: "@")
            guard parts.count == 2, let seconds = Double(parts[1]) else { continue }
            let pause = parts[0] == "pause"
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(seconds))
                asked?(pause)
            }
        }
    }
    #endif

    private static func removeTargets() {
        let commands = MPRemoteCommandCenter.shared()
        for target in targets {
            commands.pauseCommand.removeTarget(target)
            commands.playCommand.removeTarget(target)
        }
        targets = []
    }
}
#endif
#endif

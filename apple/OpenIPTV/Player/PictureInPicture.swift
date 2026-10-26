#if os(iOS)
import AVKit
import CoreMedia
import Observation
import UIKit

/// Debug builds: what Picture in Picture is doing, for UI tests (shown in
/// an invisible element, "debug-pip").
@MainActor @Observable
final class PictureInPictureProbe {
    static let shared = PictureInPictureProbe()
    var text = ""
    /// The last switch each way, "debug-pip-gap" (see SwitchGap).
    var gaps: [SwitchGap.Kind: String] = [:]
    var gapText: String { [SwitchGap.Kind.start, .return].compactMap { gaps[$0] }.joined(separator: " | ") }
}

/// Picture in Picture for films and episodes (iPhone and iPad). The film's one layer (FilmFrames) is on the
/// player screen, and the floating window shows that same layer, so nothing in the player changes and
/// nothing stops either way. The window opens by itself when the app goes with the film playing (swiping
/// home), or from the player's button: then the player screen closes and the layer waits in a dock at the
/// back of the app's window until the film comes back. WindowFlow decides each step; this runs them.
@MainActor
final class PictureInPicture: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    static let shared = PictureInPicture()

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    /// Puts the full-screen player up again for this playback (it takes the player with `reclaim`). Set by the
    /// screen that presents the player.
    var restore: ((EmbyPlayback) -> Void)?
    /// Where a docked film got to, every ten seconds and when it stops.
    var report: ((EmbyPlayback, Double, EmbyClient.PlaybackEvent) -> Void)?

    private var flow = WindowFlow()
    private var film: Film?
    private let dock = Dock()
    private nonisolated let facts = Facts()
    private var restoreDone: ((Bool) -> Void)?
    private var restoreTimeout: Task<Void, Never>?
    private var button: (started: () -> Void, failed: () -> Void)?
    private var windowSize: PixelSize?
    private var holdsActivity = false
    #if DEBUG
    private var askedAt = Date()
    private var startMs = 0
    #endif

    private struct Film {
        let player: MPVPlayer
        let frames: FilmFrames
        let playback: EmbyPlayback
        let controller: AVPictureInPictureController
        var total: Double
        /// The player screen's own skip, while it holds the film.
        var skip: (Double) -> Void
        /// While docked, from the player's events (the player screen keeps them otherwise).
        var stream: FilmStream = .whole
        var position: Double = 0
        var paused = false
        var lastReport: Double = 0
        /// Just after a jump the player still reports where it was for a moment.
        var jumpUntil: Date?
    }

    var isActive: Bool { film?.controller.isPictureInPictureActive ?? false }

    override private init() {
        super.init()
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PictureInPicture.shared.happen(.appOpened) }
        }
    }

    /// The player screen plays this film: the window may open from its picture, by itself as the app goes
    /// or from the button.
    func offer(_ player: MPVPlayer, playback: EmbyPlayback, total: Double, skip: @escaping (Double) -> Void) {
        guard Self.isSupported, let frames = player.frames else { return }
        if film?.player === player {
            film?.skip = skip
            film?.total = total
            facts.set(total: total, frames: frames)
            return
        }
        if film != nil { happen(.screenLetGo) }
        // Known before iOS first asks, at once: it asked, found the film paused and with no length, and
        // never opened the window as the app went.
        facts.set(total: total, frames: frames)
        let controller = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: frames.layer, playbackDelegate: self))
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        film = Film(player: player, frames: frames, playback: playback, controller: controller, total: total, skip: skip)
        frames.onPlayingChanged = { [weak controller] _ in
            Task { @MainActor in controller?.invalidatePlaybackState() }
        }
        controller.invalidatePlaybackState()
        happen(.offered)
    }

    /// The player's button. `started`: the window is up and the player screen may close (the film plays on in
    /// the window); `failed`: it couldn't open.
    func startFromButton(stream: FilmStream, position: Double, paused: Bool, started: @escaping () -> Void, failed: @escaping () -> Void) {
        guard let film, film.controller.isPictureInPicturePossible else { return failed() }
        self.film?.stream = stream
        self.film?.position = position
        self.film?.lastReport = position
        self.film?.paused = paused
        button = (started, failed)
        #if DEBUG
        askedAt = Date()
        #endif
        happen(.buttonTapped)
    }

    /// A player screen starting `itemId`: the window's film when it is this title (it comes back from the
    /// window to that screen); any other film in the window stops.
    func reclaim(_ itemId: String) -> (player: MPVPlayer, stream: FilmStream, position: Double, paused: Bool)? {
        guard let film, flow.keepsFilm else { return nil }
        guard film.playback.itemId == itemId else {
            happen(.otherTitle)
            return nil
        }
        if case .windowed = flow.phase { happen(.chosenAgain) }
        film.player.onEvent = nil
        endActivity()
        return (film.player, film.stream, film.position, film.paused)
    }

    /// The player screen closes with `player`. true: the window keeps it playing (don't stop it).
    func letGo(_ player: MPVPlayer) -> Bool {
        guard film?.player === player else { return false }
        if flow.keepsFilm { return true }
        happen(.screenLetGo)
        return false
    }

    /// The player's view holds the film's layer on a screen again.
    func hosted(_ player: MPVPlayer) {
        guard film?.player === player else { return }
        dock.release()
        happen(.screenHosts)
    }

    // MARK: Inside

    private func happen(_ event: WindowFlow.Event) {
        for effect in flow.on(event) { run(effect) }
        if let done = restoreDone, !waitsForScreen {
            restoreDone = nil
            done(false)
        }
    }

    private var waitsForScreen: Bool {
        if case .returning(docked: true, waiting: true, _) = flow.phase { return true }
        return false
    }

    private func run(_ effect: WindowFlow.Effect) {
        guard let film else { return }
        switch effect {
        case .startWindow:
            film.controller.startPictureInPicture()
        case .stopWindow:
            film.controller.stopPictureInPicture()
        case .framesToWindow:
            film.player.showFrames(inWindow: windowSize ?? FramePlan.firstWindow)
        case .framesToScreen:
            windowSize = nil
            film.player.showFrames(inWindow: nil)
        case .measureStart:
            #if DEBUG
            film.player.measureGap(.start)
            #endif
            break
        case .measureReturn:
            #if DEBUG
            film.player.measureGap(.return)
            #endif
            break
        case .dock:
            dock.hold(film.frames.layer)
            film.player.onEvent = { [weak self] event, _ in self?.heard(event) }
            beginActivity()
        case .closeScreen:
            button?.started()
            button = nil
        case .noteUnavailable:
            button?.failed()
            button = nil
        case .presentScreen:
            restore?(film.playback.resuming(at: film.position))
        case .armRestoreTimeout:
            restoreTimeout?.cancel()
            restoreTimeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                self?.happen(.restoreTimedOut)
            }
        case let .finishRestore(ok):
            restoreTimeout?.cancel()
            let done = restoreDone
            restoreDone = nil
            done?(ok)
        case .pausePlayer:
            film.player.setPaused(true)
        case .stopFilm:
            film.player.onEvent = nil
            report?(film.playback, film.position, .stopped)
            film.player.shutdown()
            endActivity()
        case .releaseController:
            restoreTimeout?.cancel()
            film.frames.onPlayingChanged = nil
            film.player.showFrames(inWindow: nil)
            dock.release()
            windowSize = nil
            button = nil
            self.film = nil
            facts.set(total: 0, frames: nil)
            #if DEBUG
            PictureInPictureProbe.shared.text = ""
            #endif
        }
        #if DEBUG
        probe()
        #endif
    }

    private func beginActivity() {
        guard !holdsActivity else { return }
        holdsActivity = true
        PlaybackActivity.began()
    }

    private func endActivity() {
        guard holdsActivity else { return }
        holdsActivity = false
        PlaybackActivity.ended()
    }

    /// The player's events while the film is docked.
    private func heard(_ event: MPVPlayer.Event) {
        guard var film else { return }
        switch event {
        case let .time(raw, _):
            if let until = film.jumpUntil {
                guard Date() >= until else { return }
                film.jumpUntil = nil
            }
            film.position = film.total > 0 ? min(raw + film.stream.clockStart, film.total) : raw + film.stream.clockStart
            if abs(film.position - film.lastReport) >= 10 {
                film.lastReport = film.position
                report?(film.playback, film.position, .progress)
            }
        case let .paused(paused):
            film.paused = paused
        case .ended:
            film.position = film.total
        default:
            break
        }
        self.film = film
        if case .ended = event { happen(.filmEnded) }
        #if DEBUG
        probe()
        #endif
    }

    private func skip(by seconds: Double) {
        guard var film else { return }
        guard flow.keepsFilm else { return film.skip(seconds) }
        let player = film.player
        let target = max(0, film.total > 0 ? min(film.position + seconds, film.total) : film.position + seconds)
        film.stream = player.jump(in: film.stream, to: target, for: film.playback) { _ in player.seek(by: seconds) }
        film.position = target
        film.jumpUntil = Date().addingTimeInterval(1.5)
        self.film = film
        #if DEBUG
        probe()
        #endif
    }

    #if DEBUG
    /// "pip active=true playing=true seconds=84 clock=84 start=420"
    private func probe() {
        guard let film, film.controller.isPictureInPictureActive else { return }
        let clock = film.frames.layer.controlTimebase.map { CMTimebaseGetTime($0).seconds } ?? 0
        PictureInPictureProbe.shared.text = "pip active=true playing=\(film.frames.isPlaying) seconds=\(Int(film.position)) clock=\(Int(clock)) start=\(startMs)"
    }
    #endif

    // MARK: AVPictureInPictureControllerDelegate

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            guard controller === film?.controller else { return }
            happen(.willStart)
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            guard controller === film?.controller else { return }
            #if DEBUG
            startMs = Int(Date().timeIntervalSince(askedAt) * 1000)
            #endif
            happen(.didStart)
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        #if DEBUG
        NSLog("%@", "PERF pip failed \((error as NSError).code)")
        #endif
        MainActor.assumeIsolated {
            guard controller === film?.controller else { return }
            happen(.failedToStart)
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler done: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated {
            guard controller === film?.controller else { return done(false) }
            restoreDone?(false)
            restoreDone = done
            happen(.restoreAsked)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            guard controller === film?.controller else { return }
            happen(.didStop)
        }
    }

    // MARK: AVPictureInPictureSampleBufferPlaybackDelegate

    // iOS may ask these on any thread: the answers are kept in `facts`.

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        Task { @MainActor in self.film?.player.setPaused(!playing) }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        let total = facts.total
        return total > 0 ? CMTimeRange(start: .zero, duration: CMTime(seconds: total, preferredTimescale: 600))
            : CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        !facts.playing
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        let size = PixelSize(width: Int(newRenderSize.width), height: Int(newRenderSize.height))
        Task { @MainActor in
            guard size.width > 0, size.height > 0, let film = self.film else { return }
            switch self.flow.phase {
            case .starting, .windowed:
                self.windowSize = size
                film.player.showFrames(inWindow: size)
            default:
                break
            }
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
                                                completion completionHandler: @escaping () -> Void) {
        let seconds = skipInterval.seconds
        Task { @MainActor in self.skip(by: seconds) }
        completionHandler()
    }
}

/// The film's length and its picture's clock, readable on any thread.
private final class Facts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: (total: Double, frames: FilmFrames?) = (0, nil)
    var total: Double { lock.withLock { values.total } }
    var playing: Bool { lock.withLock { values.frames }?.isPlaying ?? false }
    func set(total: Double, frames: FilmFrames?) { lock.withLock { values = (total, frames) } }
}

/// Holds the film's layer at the back of the app's window while the floating window shows it and no player
/// screen does: iOS keeps feeding the window from a layer that stays in a window.
@MainActor
private final class Dock {
    private var view: UIView?

    func hold(_ layer: CALayer) {
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow) else { return }
        let view = self.view ?? UIView(frame: window.bounds)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        window.insertSubview(view, at: 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        view.layer.addSublayer(layer)
        layer.frame = view.bounds
        CATransaction.commit()
        self.view = view
    }

    func release() {
        view?.removeFromSuperview()
        view = nil
    }
}
#endif

#if os(iOS)
import AVKit
import CoreMedia
import Observation
import UIKit

#if DEBUG
@MainActor @Observable
final class PictureInPictureProbe {
    static let shared = PictureInPictureProbe()
    var text = ""
    var gaps: [SwitchGap.Kind: String] = [:]
    /// iOS's "playing in Picture in Picture" icon on the film's layer as the app came back with the window up.
    var iconOnOpen: String?
    var fadeOnStop: String?
    var gapText: String {
        ([SwitchGap.Kind.start, .return].compactMap { gaps[$0] }
            + [iconOnOpen.map { "open icon=\($0)" }, fadeOnStop.map { "stop fade=\($0)" }].compactMap(\.self))
            .joined(separator: " | ")
    }
}
#endif

@MainActor
final class PictureInPicture: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    static let shared = PictureInPicture()

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    var restore: ((EmbyPlayback) -> Void)?
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
        var screenSkip: (Double) -> Void
        var stream: FilmStream = .whole
        var position: Double = 0
        var paused = false
        var lastReport: Double = 0
        var ignoreTimeUntil: Date?
    }

    override private init() {
        super.init()
        NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                #if DEBUG
                PictureInPicture.shared.noteIcon()
                #endif
                PictureInPicture.shared.happen(.appOpened)
            }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { PictureInPicture.shared.happen(.appLeft) }
        }
    }

    func offer(_ player: MPVPlayer, playback: EmbyPlayback, total: Double, skip: @escaping (Double) -> Void) {
        guard Self.isSupported, let frames = player.frames else { return }
        if film?.player === player {
            film?.screenSkip = skip
            return update(player, total: total)
        }
        if film != nil { happen(.screenLetGo) }
        // iOS asks whether the film plays as soon as the controller is made; answered "paused" then, it never
        // opened the window by itself as the app went.
        facts.set(total: total, frames: frames)
        let controller = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: frames.layer, playbackDelegate: self))
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        film = Film(player: player, frames: frames, playback: playback, controller: controller, total: total, screenSkip: skip)
        frames.onPlayingChanged = { [weak controller] _ in
            Task { @MainActor in controller?.invalidatePlaybackState() }
        }
        controller.invalidatePlaybackState()
        happen(.offered)
    }

    /// The film's length, once the player knows it (no window before the film plays).
    func update(_ player: MPVPlayer, total: Double) {
        guard var film, film.player === player else { return }
        setTotal(total, of: &film)
        self.film = film
    }

    private func setTotal(_ total: Double, of film: inout Film) {
        guard film.total != total else { return }
        film.total = total
        facts.set(total: total, frames: film.frames)
        film.controller.invalidatePlaybackState()
    }

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

    func reclaim(_ itemId: String) -> (player: MPVPlayer, stream: FilmStream, position: Double, paused: Bool)? {
        guard let film, flow.keepsFilm else { return nil }
        guard film.playback.itemId == itemId else {
            happen(.otherTitle)
            return nil
        }
        happen(.reclaimed)
        film.player.onEvent = nil
        endActivity()
        return (film.player, film.stream, film.position, film.paused)
    }

    enum ScreenRelease { case keepPlaying, stopped }

    func letGo(_ player: MPVPlayer) -> ScreenRelease {
        guard film?.player === player else { return .stopped }
        if flow.keepsFilm { return .keepPlaying }
        happen(.screenLetGo)
        return .stopped
    }

    func hosted(_ player: MPVPlayer) {
        guard film?.player === player else { return }
        dock.release()
        happen(.screenHosts)
    }

    private func happen(_ event: WindowFlow.Event) {
        for effect in flow.on(event) { run(effect) }
    }

    private func run(_ effect: WindowFlow.Effect) {
        if case let .finishRestore(ok) = effect {
            restoreTimeout?.cancel()
            let done = restoreDone
            restoreDone = nil
            done?(ok)
            return
        }
        guard let film else { return }
        switch effect {
        case .startWindow:
            film.controller.startPictureInPicture()
        case .stopWindow:
            film.controller.stopPictureInPicture()
        case .framesToWindow:
            film.player.showFrames(inWindow: windowSize ?? FramePlan.fallbackWindow)
        case .framesToScreen:
            windowSize = nil
            film.player.showFrames(inWindow: nil)
        case .measureStart:
            timeGap(.start, film.frames)
            #if DEBUG
            film.player.measureGap(.start)
            #endif
        case .measureReturn:
            timeGap(.return, film.frames)
            #if DEBUG
            film.player.measureGap(.return)
            #endif
        case .dock:
            dock.hold(film.frames.layer)
            film.player.onEvent = { [weak self] event, _ in self?.dockedEvent(event) }
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
        case .finishRestore:
            break
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

    private func dockedEvent(_ event: MPVPlayer.Event) {
        guard var film else { return }
        switch event {
        case let .time(raw, duration):
            if let duration, film.stream.clockStart == 0 { setTotal(duration, of: &film) }
            if let until = film.ignoreTimeUntil, Date() < until {
                self.film = film
                return
            }
            film.ignoreTimeUntil = nil
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

    private func timeGap(_ edge: Metric.PipEdge, _ frames: FilmFrames) {
        frames.timeFrameGap(edge, for: 4) { edge, seconds in
            Task { @MainActor in Telemetry.note(.pipGap(edge, seconds: seconds)) }
        }
    }

    private func skip(by seconds: Double) {
        guard var film else { return }
        guard flow.keepsFilm else { return film.screenSkip(seconds) }
        let player = film.player
        let target = max(0, film.total > 0 ? min(film.position + seconds, film.total) : film.position + seconds)
        film.stream = player.jump(in: film.stream, to: target, for: film.playback) { _ in player.seek(by: seconds) }
        film.position = target
        film.ignoreTimeUntil = Date().addingTimeInterval(1.5)
        self.film = film
        #if DEBUG
        probe()
        #endif
    }

    #if DEBUG
    private func noteIcon() {
        guard let film, film.controller.isPictureInPictureActive else { return }
        let icons = Self.icons(on: film.frames.layer)
        PictureInPictureProbe.shared.iconOnOpen = icons.isEmpty ? "none" : icons.allSatisfy(\.isHidden) ? "hidden" : "shown"
    }

    private func probe() {
        guard let film, film.controller.isPictureInPictureActive else { return }
        let clock = film.frames.layer.controlTimebase.map { CMTimebaseGetTime($0).seconds } ?? 0
        PictureInPictureProbe.shared.text = "pip active=true playing=\(film.frames.isPlaying) seconds=\(Int(film.position)) clock=\(Int(clock)) start=\(startMs)"
    }
    #endif

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            guard controller === film?.controller else { return }
            #if DEBUG
            PictureInPictureProbe.shared.iconOnOpen = nil
            PictureInPictureProbe.shared.fadeOnStop = nil
            #endif
            happen(.willStart)
            // iOS can start the window by itself after the viewer is already back in the app.
            if UIApplication.shared.applicationState == .active { happen(.appOpened) }
        }
    }

    /// AVKit draws its "playing in Picture in Picture" icon in this sublayer of the film's layer while the window is up,
    /// and offers no public way to turn it off. Should a later iOS rename the class, the icon shows again.
    private static func icons(on layer: CALayer) -> [CALayer] {
        guard let icon = NSClassFromString("AVPictureInPictureIndicatorLayer") else { return [] }
        return layer.sublayers?.filter { $0.isKind(of: icon) } ?? []
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            guard let film, controller === film.controller else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            Self.icons(on: film.frames.layer).forEach { $0.isHidden = true }
            CATransaction.commit()
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
            #if DEBUG
            if let layer = film?.frames.layer {
                DispatchQueue.main.async { PictureInPictureProbe.shared.fadeOnStop = (layer.animationKeys() ?? []).isEmpty ? "none" : "fade" }
            }
            #endif
            happen(.didStop)
        }
    }

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

private final class Facts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: (total: Double, frames: FilmFrames?) = (0, nil)
    var total: Double { lock.withLock { values.total } }
    var playing: Bool { lock.withLock { values.frames }?.isPlaying ?? false }
    func set(total: Double, frames: FilmFrames?) { lock.withLock { values = (total, frames) } }
}

/// iOS keeps feeding the floating window only while its layer stays in a window.
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

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
}

/// Picture in Picture for films and episodes (iPhone and iPad), from the
/// app's own player: its picture moves into the floating window and the
/// same playback carries on (no second stream, no pause, no jump); brought
/// back, the full-screen player takes the same player again.
///
/// It used to start a second stream (Emby's converted one) in an AVPlayer
/// and hand over to it: seconds to start on a real server, the picture
/// paused or jumped at the handover, and the window's own clock had to be
/// worked out.
///
/// One state at a time, and whoever holds the player owns it:
/// idle → starting (the picture drawn into the window's layer, waiting for
/// iOS) → active (the window has the player) → restoring (the full-screen
/// player takes it back) → idle; or active → idle when the window closes
/// (stopped there, the player let go).
@MainActor
final class PictureInPicture: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    static let shared = PictureInPicture()

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    /// Puts the full-screen player up again for this playback (it takes the
    /// player with `takeBack`). Set by the screen that presents the player.
    var restore: ((EmbyPlayback) -> Void)?
    /// Where it got to, every ten seconds and when the window closes.
    var report: ((EmbyPlayback, Double, EmbyClient.PlaybackEvent) -> Void)?

    private enum Phase { case idle, starting, active, restoring }
    private var phase = Phase.idle
    private var player: MPVPlayer?
    private var playback: EmbyPlayback?
    private var host: FrameView?
    private var controller: AVPictureInPictureController?
    private var timebase: CMTimebase?
    /// Where a server-converted stream starts (its clock starts at 0).
    private var offset: Double = 0
    private var position: Double = 0
    private var total: Double = 0
    private var paused = false {
        didSet { facts.set(total: total, paused: paused) }
    }
    private nonisolated let facts = Facts()
    private var lastReport: Double = 0
    private var started: (() -> Void)?
    private var failed: (() -> Void)?
    private var restored: ((Bool) -> Void)?
    private var watch: Task<Void, Never>?
    #if DEBUG
    private var askedAt = Date()
    private var startMs = 0
    /// When iOS said the window was possible, and when the first frame was
    /// in its layer (ms after the tap).
    private var possibleMs = -1
    private var drawnMs = -1
    private var firstStill = false
    private var grewFromScreen = false
    #endif

    var isActive: Bool { controller?.isPictureInPictureActive ?? false }

    /// Moves `player`'s picture into the window. `started`: the window has
    /// it (the full-screen player closes, leaving the player running);
    /// `failed`: it couldn't (the player carries on on screen).
    func start(_ player: MPVPlayer, playback: EmbyPlayback, offset: Double, position: Double, total: Double, paused: Bool,
               started: @escaping () -> Void, failed: @escaping () -> Void) {
        close()
        guard Self.isSupported, let window = Self.window else { return failed() }
        // Over the picture, where the window grows out of; behind the app
        // once the window is up.
        let host = FrameView(frame: window.bounds)
        host.isUserInteractionEnabled = false
        host.backgroundColor = .clear
        window.addSubview(host)
        var clock: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: nil, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &clock)
        if let clock {
            CMTimebaseSetTime(clock, time: CMTime(seconds: position, preferredTimescale: 600))
            CMTimebaseSetRate(clock, rate: paused ? 0 : 1)
            host.frames.controlTimebase = clock
        }
        // Known before iOS first asks (it asked at once, saw no length,
        // and showed a live stream).
        facts.set(total: total, paused: paused)
        let controller = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: host.frames, playbackDelegate: self))
        controller.delegate = self
        phase = .starting
        self.player = player
        self.playback = playback
        self.host = host
        self.controller = controller
        self.timebase = clock
        self.offset = offset
        self.position = position
        self.lastReport = position
        self.total = total
        self.paused = paused
        self.started = started
        self.failed = failed
        #if DEBUG
        askedAt = Date()
        possibleMs = -1
        drawnMs = -1
        #endif
        let drawn = DrawnFlag()
        player.drawFrames(into: host.frames) { drawn.set() }
        // Up as soon as the picture is in the layer and iOS says it's
        // possible; not up in 4 s: the player carries on on screen.
        watch = Task { [weak self] in
            for _ in 0..<80 {
                try? await Task.sleep(for: .milliseconds(50))
                guard let self, !Task.isCancelled, self.phase == .starting, let controller = self.controller else { return }
                #if DEBUG
                let since = Int(Date().timeIntervalSince(self.askedAt) * 1000)
                if self.possibleMs < 0, controller.isPictureInPicturePossible { self.possibleMs = since }
                if self.drawnMs < 0, drawn.isSet { self.drawnMs = since }
                // UI tests: the picture held in the app's layer a while first.
                if let hold = ProcessInfo.processInfo.environment["OPENREEL_DEBUG_PIP_HOLD"].flatMap(Double.init),
                   Date().timeIntervalSince(self.askedAt) < hold { continue }
                #endif
                if drawn.isSet, controller.isPictureInPicturePossible {
                    #if DEBUG
                    self.grewFromScreen = host.window != nil && host.superview?.subviews.last === host
                    #endif
                    controller.startPictureInPicture()
                    return
                }
            }
            self?.fail()
        }
    }

    /// The window's player, for the full-screen player putting up this
    /// title (brought back, or chosen again): the same playback, where it
    /// has got to. The window closes.
    func takeBack(_ itemId: String) -> (player: MPVPlayer, offset: Double, position: Double, paused: Bool)? {
        guard phase == .active || phase == .restoring, let player, playback?.itemId == itemId else { return nil }
        let back = (player, offset, position, paused)
        self.player = nil
        player.onEvent = nil
        if let restored {
            self.restored = nil
            restored(true)
        } else {
            controller?.stopPictureInPicture()
        }
        return back
    }

    /// Closes the window, stopped where it got to: another title is
    /// starting in the full-screen player.
    func close() {
        switch phase {
        case .idle: break
        case .starting: fail()
        case .active, .restoring:
            if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() } else { finish() }
        }
    }

    // MARK: Inside

    private func fail() {
        let failed = failed
        let player = player
        self.player = nil
        tearDown()
        player?.drawOnScreen()
        failed?()
    }

    /// The window is gone: the player stops there unless it was taken back.
    private func finish() {
        if let player, let playback {
            report?(playback, position, .stopped)
            player.shutdown()
        }
        player = nil
        if phase == .active || phase == .restoring { PlaybackActivity.ended() }
        tearDown()
    }

    private func tearDown() {
        watch?.cancel()
        watch = nil
        restored?(false)
        restored = nil
        host?.removeFromSuperview()
        host = nil
        controller = nil
        timebase = nil
        playback = nil
        started = nil
        failed = nil
        phase = .idle
        #if DEBUG
        PictureInPictureProbe.shared.text = ""
        #endif
    }

    /// The player's events while it's in the window.
    private func handle(_ event: MPVPlayer.Event) {
        switch event {
        case let .time(raw, _):
            position = total > 0 ? min(raw + offset, total) : raw + offset
            if let timebase, abs(CMTimebaseGetTime(timebase).seconds - position) > 0.5 {
                CMTimebaseSetTime(timebase, time: CMTime(seconds: position, preferredTimescale: 600))
            }
            if abs(position - lastReport) >= 10, let playback {
                lastReport = position
                report?(playback, position, .progress)
            }
            #if DEBUG
            probe()
            #endif
        case let .paused(isPaused):
            paused = isPaused
            if let timebase { CMTimebaseSetRate(timebase, rate: isPaused ? 0 : 1) }
            controller?.invalidatePlaybackState()
            #if DEBUG
            probe()
            #endif
        case .ended:
            position = total
            controller?.stopPictureInPicture()
        default:
            break
        }
    }

    #if DEBUG
    /// "pip active=true playing=true seconds=84 clock=84 start=420 from=screen"
    private func probe() {
        PictureInPictureProbe.shared.text = "pip active=\(isActive) playing=\(!paused) seconds=\(Int(position)) clock=\(Int(position)) start=\(startMs) from=\(grewFromScreen ? "screen" : "hidden") possible=\(possibleMs) drawn=\(drawnMs) first=\(firstStill ? "still" : "live")"
    }
    #endif

    private static var window: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
    }

    // MARK: AVPictureInPictureControllerDelegate

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            guard phase == .starting else { return }
            phase = .active
            PlaybackActivity.began()
            player?.onEvent = { [weak self] event in self?.handle(event) }
            if let host { host.superview?.sendSubviewToBack(host) }
            #if DEBUG
            startMs = Int(Date().timeIntervalSince(askedAt) * 1000)
            firstStill = player?.windowStartedFromStill ?? false
            probe()
            #endif
            let started = started
            self.started = nil
            started?()
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        #if DEBUG
        NSLog("%@", "PERF pip failed \((error as NSError).code)")
        #endif
        MainActor.assumeIsolated { if phase == .starting { fail() } }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler done: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated {
            guard phase == .active, let playback else { return done(false) }
            phase = .restoring
            // Finished once the full-screen player has taken the player back
            // (see takeBack); not in 3 s, the window just closes.
            restored = done
            restore?(playback.resuming(at: position))
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, let restored = self.restored else { return }
                self.restored = nil
                restored(false)
            }
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { if phase == .active || phase == .restoring { finish() } }
    }

    // MARK: AVPictureInPictureSampleBufferPlaybackDelegate

    // iOS may ask these on any thread: the answers are kept in `facts`.

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        Task { @MainActor in self.player?.setPaused(!playing) }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        let total = facts.total
        return total > 0 ? CMTimeRange(start: .zero, duration: CMTime(seconds: total, preferredTimescale: 600))
            : CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        facts.paused
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
                                                completion completionHandler: @escaping () -> Void) {
        let seconds = skipInterval.seconds
        Task { @MainActor in self.player?.seek(by: seconds) }
        completionHandler()
    }
}

/// The film's length and whether it's paused, readable on any thread.
private final class Facts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: (total: Double, paused: Bool) = (0, false)
    var total: Double { lock.withLock { values.total } }
    var paused: Bool { lock.withLock { values.paused } }
    func set(total: Double, paused: Bool) { lock.withLock { values = (total, paused) } }
}

/// Set once from the frame-drawing thread, read on the main one.
private final class DrawnFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

/// A view whose layer takes frames (the picture in the window).
private final class FrameView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var frames: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        frames.videoGravity = .resizeAspect
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
#endif

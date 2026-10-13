#if os(iOS)
import AVKit
import Observation
import UIKit

/// Debug builds: what Picture in Picture is doing, for UI tests (shown in
/// an invisible element, "debug-pip").
@MainActor @Observable
final class PictureInPictureProbe {
    static let shared = PictureInPictureProbe()
    var text = ""
}

/// Picture in Picture for films and episodes (iPhone and iPad). iOS shows
/// PiP only for its own player, so the film carries on in an AVPlayer in
/// the floating window, from the same second (Emby's converted stream at a
/// window's bitrate), while the app's player closes; it comes back to the
/// app's player at the second it reached, or stops there.
@MainActor
final class PictureInPicture: NSObject, AVPictureInPictureControllerDelegate {
    static let shared = PictureInPicture()

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    /// The app's player again, from this playback (its start: where the
    /// window got to). Set by the screen that presents the player.
    var restore: ((EmbyPlayback) -> Void)?
    /// Where the window got to, every ten seconds and when it closes.
    var report: ((EmbyPlayback, Double, EmbyClient.PlaybackEvent) -> Void)?

    private var player: AVPlayer?
    private var host: UIView?
    private var controller: AVPictureInPictureController?
    private var playback: EmbyPlayback?
    /// Where in the film the window starts, and how the stream's clock
    /// reads: the film's own seconds (Emby's converted stream lists the
    /// whole film from 0:00, or keeps the film's timestamps), or seconds
    /// since that start. Adding the start to a clock that already counted
    /// from 0:00 reported positions past the end, and Emby marked the
    /// episode watched (it "skipped the episode").
    private var offset: Double = 0
    private var clockIsFilm = false
    /// The film's length: nothing past its end is reported.
    private var total: Double = 0
    /// Where the app's player is now (it plays on while the window gets
    /// ready): the window starts there.
    private var now: () -> Double = { 0 }
    private var restoring = false
    #if DEBUG
    /// When the window was asked for, and whether it grew out of a picture
    /// on screen (for UI tests: one behind the app made the start stutter).
    private var askedAt = Date()
    private var grewFromScreen = false
    #endif
    private var started: (() -> Void)?
    private var failed: (() -> Void)?
    private var watch: Task<Void, Never>?
    private var progress: Task<Void, Never>?

    var isActive: Bool { controller?.isPictureInPictureActive ?? false }

    /// Starts the window with `url`, at `offset` seconds into a film
    /// `total` seconds long. `started`: the window is up (the app's player
    /// can close); `failed`: it couldn't start (the app's player carries on).
    func start(_ playback: EmbyPlayback, url: URL, headers: [String], offset: Double, total: Double,
               now: @escaping () -> Double, started: @escaping () -> Void, failed: @escaping () -> Void) {
        stop()
        guard Self.isSupported, let window = Self.window else { return failed() }
        var fields: [String: String] = [:]
        for header in headers {
            let pair = header.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 { fields[pair[0]] = pair[1] }
        }
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": fields])
        let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player.allowsExternalPlayback = true
        // Silent until the window is up: the app's player still plays.
        player.isMuted = true
        // Over the picture, invisible until the stream is at the right
        // second: PiP grows out of a picture on screen (one behind the app
        // made the start stutter); behind everything once it's up.
        let host = PlayerLayerView(frame: window.bounds)
        host.isUserInteractionEnabled = false
        host.backgroundColor = .clear
        host.alpha = 0
        host.playerLayer.player = player
        host.playerLayer.videoGravity = .resizeAspect
        window.addSubview(host)
        guard let controller = AVPictureInPictureController(playerLayer: host.playerLayer) else {
            host.removeFromSuperview()
            return failed()
        }
        controller.delegate = self
        self.player = player
        self.host = host
        self.controller = controller
        self.playback = playback
        self.offset = offset
        self.total = total
        self.now = now
        self.started = started
        self.failed = failed
        clockIsFilm = false
        #if DEBUG
        askedAt = Date()
        #endif
        // Up as soon as the stream is at the right second and playing, and
        // iOS says it's possible; not up in 15 s: the app's player carries on.
        watch = Task { [weak self] in
            var placed = false
            for step in 0..<150 {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled, let controller = self.controller else { return }
                #if DEBUG
                if step % 10 == 0 {
                    NSLog("%@", "PERF pip waiting status=\(player.currentItem?.status.rawValue ?? -1) possible=\(controller.isPictureInPicturePossible) error=\(player.currentItem?.error?.localizedDescription ?? "none")")
                }
                #endif
                if !placed, let item = player.currentItem, item.status == .readyToPlay {
                    placed = true
                    await self.place(item, player)
                    player.play()
                }
                if placed, controller.isPictureInPicturePossible, player.timeControlStatus == .playing {
                    host.alpha = 1
                    #if DEBUG
                    self.grewFromScreen = host.window != nil && host.superview?.subviews.last === host
                    #endif
                    controller.startPictureInPicture()
                    return
                }
                if player.currentItem?.status == .failed { break }
            }
            self?.fail()
        }
    }

    /// The film's second the window is at (never past its end).
    private var seconds: Double {
        let clock = max(0, player?.currentTime().seconds.nanToZero ?? 0)
        let film = clockIsFilm ? clock : offset + clock
        return total > 0 ? min(film, total) : film
    }

    /// Works out how the stream's clock reads, and starts it at the film's
    /// second where the app's player was.
    private func place(_ item: AVPlayerItem, _ player: AVPlayer) async {
        let length = item.duration.seconds
        let start = player.currentTime().seconds.nanToZero
        // Where the app's player has got to meanwhile (a moment ahead: the
        // seek itself takes one).
        let target = max(offset, now() + 0.3)
        if length.isFinite, total > 0, abs(length - total) < max(30, total * 0.05) {
            // The whole film from 0:00: jump to where it is.
            clockIsFilm = true
            await player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                              toleranceBefore: CMTime(seconds: 1, preferredTimescale: 600), toleranceAfter: .zero)
        } else {
            // The film's own timestamps from the start, or a clock from 0.
            clockIsFilm = offset > 30 && start > offset - 30
            let ahead = clockIsFilm ? target : target - offset
            if ahead > 1 {
                await player.seek(to: CMTime(seconds: ahead, preferredTimescale: 600),
                                  toleranceBefore: CMTime(seconds: 1, preferredTimescale: 600), toleranceAfter: .zero)
            }
        }
        #if DEBUG
        NSLog("%@", "PERF pip placed length=\(Int(length.nanToZero)) total=\(Int(total)) offset=\(Int(offset)) clockIsFilm=\(clockIsFilm) at=\(Int(seconds))")
        #endif
    }

    private func fail() {
        let failed = failed
        stop()
        failed?()
    }

    /// Closes the window (it reports where it got to): another film is
    /// starting in the app's player.
    func close() {
        if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() } else { stop() }
    }

    /// Lets go of the window's player.
    func stop() {
        watch?.cancel()
        progress?.cancel()
        if controller?.isPictureInPictureActive == true { controller?.stopPictureInPicture() }
        player?.pause()
        host?.removeFromSuperview()
        #if DEBUG
        PictureInPictureProbe.shared.text = ""
        #endif
        player = nil
        host = nil
        controller = nil
        playback = nil
        started = nil
        failed = nil
    }

    private static var window: UIWindow? {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first { $0.isKeyWindow }
    }

    // MARK: AVPictureInPictureControllerDelegate

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            started?()
            started = nil
            // Behind the app now (the window shows it), heard, and playing:
            // the handoff could leave it paused.
            if let host { host.superview?.sendSubviewToBack(host) }
            player?.isMuted = false
            player?.play()
            #if DEBUG
            let startMs = Int(Date().timeIntervalSince(askedAt) * 1000)
            let from = grewFromScreen ? "screen" : "hidden"
            #endif
            // Progress kept on the server while it plays in the window.
            progress = Task { [weak self] in
                var tick = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    tick += 1
                    guard let self, !Task.isCancelled, let playback = self.playback else { continue }
                    #if DEBUG
                    PictureInPictureProbe.shared.text =
                        "pip active=\(self.isActive) playing=\(self.player?.timeControlStatus == .playing) seconds=\(Int(self.seconds)) clock=\(Int(self.player?.currentTime().seconds.nanToZero ?? 0)) start=\(startMs) from=\(from)"
                    #endif
                    if tick % 20 == 0, self.player?.timeControlStatus == .playing {
                        self.report?(playback, self.seconds, .progress)
                    }
                }
            }
        }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        #if DEBUG
        NSLog("%@", "PERF pip failed \(error.localizedDescription)")
        #endif
        MainActor.assumeIsolated { fail() }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler done: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated {
            guard let playback else { return done(false) }
            restoring = true
            // The app's player from where the window got to.
            restore?(playback.resuming(at: seconds))
            done(true)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            // Closed (not brought back): stopped there, for Continue Watching.
            if !restoring, let playback { report?(playback, seconds, .stopped) }
            restoring = false
            stop()
        }
    }
}

/// A view whose layer is an AVPlayerLayer.
private final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

private extension Double {
    var nanToZero: Double { isFinite ? self : 0 }
}
#endif

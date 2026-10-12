#if os(iOS)
import AVKit
import UIKit

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
    /// Where in the film the stream starts (its clock starts at 0).
    private var offset: Double = 0
    private var restoring = false
    private var started: (() -> Void)?
    private var failed: (() -> Void)?
    private var watch: Task<Void, Never>?
    private var progress: Task<Void, Never>?

    var isActive: Bool { controller?.isPictureInPictureActive ?? false }

    /// Starts the window with `url` (a stream starting at `offset` seconds
    /// into the film). `started`: the window is up (the app's player can
    /// close); `failed`: it couldn't start (the app's player carries on).
    func start(_ playback: EmbyPlayback, url: URL, headers: [String], offset: Double,
               started: @escaping () -> Void, failed: @escaping () -> Void) {
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
        // In the window, behind everything (PiP grows out of it).
        let host = PlayerLayerView(frame: window.bounds)
        host.isUserInteractionEnabled = false
        host.playerLayer.player = player
        host.playerLayer.videoGravity = .resizeAspect
        window.insertSubview(host, at: 0)
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
        self.started = started
        self.failed = failed
        player.play()
        // Up as soon as iOS says it's possible (the stream has a picture);
        // not up in 15 s: the app's player carries on.
        watch = Task { [weak self] in
            for step in 0..<150 {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled, let controller = self.controller else { return }
                #if DEBUG
                if step % 10 == 0 {
                    NSLog("%@", "PERF pip waiting status=\(player.currentItem?.status.rawValue ?? -1) possible=\(controller.isPictureInPicturePossible) error=\(player.currentItem?.error?.localizedDescription ?? "none")")
                }
                #endif
                if controller.isPictureInPicturePossible, player.currentItem?.status == .readyToPlay {
                    controller.startPictureInPicture()
                    return
                }
                if player.currentItem?.status == .failed { break }
            }
            self?.fail()
        }
    }

    /// The film's second the window is at.
    private var seconds: Double {
        offset + max(0, player?.currentTime().seconds.nanToZero ?? 0)
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
            // Progress kept on the server while it plays in the window.
            progress = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    guard let self, !Task.isCancelled, let playback = self.playback,
                          self.player?.timeControlStatus == .playing else { continue }
                    self.report?(playback, self.seconds, .progress)
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

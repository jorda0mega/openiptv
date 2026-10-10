import Libmpv
import QuartzCore
import UIKit

/// CAMetalLayer that ignores MoltenVK's 1×1 drawable resize, which otherwise
/// causes flicker (mpv-player/mpv#13651).
final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if newValue.width > 1, newValue.height > 1 { super.drawableSize = newValue }
        }
    }
}

/// libmpv playing MPEG-TS live streams directly (AVPlayer can't), rendered
/// with Vulkan-on-Metal and decoded in hardware by VideoToolbox. One instance
/// is reused across channel changes so zapping only swaps the stream.
final class MPVPlayer: @unchecked Sendable {
    enum Event {
        /// First frame is on screen; seconds since `load`.
        case started(Double)
        case buffering(Bool)
        case failed(String)
    }

    let layer = MPVMetalLayer()
    var onEvent: (@MainActor (Event) -> Void)?

    private var mpv: OpaquePointer?
    private let queue = DispatchQueue(label: "openiptv.mpv", qos: .userInitiated)
    private var loadStarted = CFAbsoluteTimeGetCurrent()
    private var reportedStart = false

    init(httpHeaders: [String]) {
        layer.framebufferOnly = true
        layer.backgroundColor = UIColor.black.cgColor

        guard let mpv = mpv_create() else { return }
        self.mpv = mpv
        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &wid)
        set("vo", "gpu-next")
        set("gpu-api", "vulkan")
        set("gpu-context", "moltenvk")
        set("hwdec", "videotoolbox")
        set("video-rotate", "no")
        set("idle", "yes")
        set("terminal", "no")
        // Live TV: start on the first decodable frame instead of filling a
        // cache, and probe less of the stream before starting.
        set("cache", "yes")
        set("cache-pause-initial", "no")
        set("demuxer-readahead-secs", "8")
        set("demuxer-lavf-probesize", "524288")
        set("demuxer-lavf-analyzeduration", "1")
        if !httpHeaders.isEmpty { set("http-header-fields", httpHeaders.joined(separator: ",")) }
        mpv_initialize(mpv)
        mpv_observe_property(mpv, 0, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_set_wakeup_callback(mpv, { context in
            guard let context else { return }
            Unmanaged<MPVPlayer>.fromOpaque(context).takeUnretainedValue().drainEvents()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func load(_ url: URL) {
        queue.async { [self] in
            loadStarted = CFAbsoluteTimeGetCurrent()
            reportedStart = false
            command(["loadfile", url.absoluteString, "replace"])
        }
    }

    func stop() {
        queue.async { [self] in command(["stop"]) }
    }

    /// Stops playback and frees libmpv; the provider connection closes with it.
    func shutdown() {
        queue.sync {
            guard let mpv else { return }
            mpv_set_wakeup_callback(mpv, nil, nil)
            mpv_terminate_destroy(mpv)
            self.mpv = nil
        }
    }

    private func set(_ name: String, _ value: String) {
        guard let mpv else { return }
        mpv_set_option_string(mpv, name, value)
    }

    private func command(_ args: [String]) {
        guard let mpv else { return }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) } + [nil]
        mpv_command(mpv, &cargs)
        for pointer in cargs { free(UnsafeMutablePointer(mutating: pointer)) }
    }

    private func drainEvents() {
        queue.async { [self] in
            while let mpv, let event = mpv_wait_event(mpv, 0), event.pointee.event_id != MPV_EVENT_NONE {
                handle(event.pointee)
            }
        }
    }

    private func handle(_ event: mpv_event) {
        switch event.event_id {
        case MPV_EVENT_PLAYBACK_RESTART where !reportedStart:
            reportedStart = true
            emit(.started(CFAbsoluteTimeGetCurrent() - loadStarted))
        case MPV_EVENT_END_FILE:
            guard let data = event.data else { return }
            let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            if end.reason == MPV_END_FILE_REASON_ERROR {
                emit(.failed(String(cString: mpv_error_string(end.error))))
            }
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.data else { return }
            let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
            if String(cString: property.name) == "paused-for-cache", property.format == MPV_FORMAT_FLAG,
               let value = property.data {
                emit(.buffering(value.assumingMemoryBound(to: Int32.self).pointee != 0))
            }
        default:
            break
        }
    }

    private func emit(_ event: Event) {
        let handler = onEvent
        Task { @MainActor in handler?(event) }
    }
}

/// Hosts the player's Metal layer and keeps it sized to the view.
final class MPVHostView: UIView {
    private let metalLayer: CALayer

    init(player: MPVPlayer) {
        metalLayer = player.layer
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(metalLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = bounds
        metalLayer.contentsScale = traitCollection.displayScale
        CATransaction.commit()
    }
}

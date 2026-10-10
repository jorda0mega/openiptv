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

/// libmpv: plays MPEG-TS live streams (which AVPlayer can't) and any file
/// Emby has, rendered with Vulkan-on-Metal and decoded by VideoToolbox. One
/// instance is reused across channel changes so zapping only swaps streams.
final class MPVPlayer: @unchecked Sendable {
    enum Event {
        /// First frame is on screen; seconds since `load`.
        case started(Double)
        case buffering(Bool)
        case failed(String)
        case time(position: Double, duration: Double?)
        case paused(Bool)
        case ended
    }

    let layer = MPVMetalLayer()
    var onEvent: (@MainActor (Event) -> Void)?

    private var mpv: OpaquePointer?
    private let queue = DispatchQueue(label: "openiptv.mpv", qos: .userInitiated)
    private var loadStarted = CFAbsoluteTimeGetCurrent()
    private var reportedStart = false
    private var duration: Double?

    init(options: [(String, String)], hardwareDecoding: Bool) {
        layer.framebufferOnly = true
        layer.backgroundColor = UIColor.black.cgColor

        guard let mpv = mpv_create() else { return }
        self.mpv = mpv
        var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &wid)
        set("vo", "gpu-next")
        set("gpu-api", "vulkan")
        set("gpu-context", "moltenvk")
        set("hwdec", hardwareDecoding ? "videotoolbox" : "no")
        set("video-rotate", "no")
        set("idle", "yes")
        set("terminal", "no")
        set("keep-open", "no")
        set("cache", "yes")
        // No log output at all: stream URLs carry credentials.
        set("msg-level", "all=no")
        for (name, value) in options { set(name, value) }
        mpv_initialize(mpv)
        mpv_observe_property(mpv, 0, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_set_wakeup_callback(mpv, { context in
            guard let context else { return }
            Unmanaged<MPVPlayer>.fromOpaque(context).takeUnretainedValue().drainEvents()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Start a stream with any headers the provider requires; `start`
    /// resumes a file at that many seconds.
    func load(_ url: URL, headers: [String] = [], start: Double? = nil) {
        queue.async { [self] in
            guard let mpv else { return }
            loadStarted = CFAbsoluteTimeGetCurrent()
            reportedStart = false
            duration = nil
            mpv_set_property_string(mpv, "http-header-fields", headers.joined(separator: ","))
            mpv_set_property_string(mpv, "start", start.map { String(format: "%.1f", $0) } ?? "none")
            command(["loadfile", url.absoluteString, "replace"])
        }
    }

    func togglePause() {
        queue.async { [self] in command(["cycle", "pause"]) }
    }

    func seek(by seconds: Double) {
        queue.async { [self] in command(["seek", String(seconds), "relative"]) }
    }

    func seek(to seconds: Double) {
        queue.async { [self] in command(["seek", String(seconds), "absolute"]) }
    }

    /// Stops playback and frees libmpv; the network connection closes with it.
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
            } else if end.reason == MPV_END_FILE_REASON_EOF {
                emit(.ended)
            }
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.data else { return }
            let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
            guard let value = property.data else { return }
            switch String(cString: property.name) {
            case "paused-for-cache" where property.format == MPV_FORMAT_FLAG:
                emit(.buffering(value.assumingMemoryBound(to: Int32.self).pointee != 0))
            case "pause" where property.format == MPV_FORMAT_FLAG:
                emit(.paused(value.assumingMemoryBound(to: Int32.self).pointee != 0))
            case "duration" where property.format == MPV_FORMAT_DOUBLE:
                duration = value.assumingMemoryBound(to: Double.self).pointee
            case "time-pos" where property.format == MPV_FORMAT_DOUBLE:
                emit(.time(position: value.assumingMemoryBound(to: Double.self).pointee, duration: duration))
            default:
                break
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

/// Hosts the player's Metal layer and keeps it sized to the view, including
/// its drawable size so rotation re-creates mpv's swapchain at full size.
final class MPVHostView: UIView {
    private let metalLayer: CAMetalLayer

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
        let scale = traitCollection.displayScale
        metalLayer.frame = bounds
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        CATransaction.commit()
    }
}

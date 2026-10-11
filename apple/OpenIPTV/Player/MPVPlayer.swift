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
        /// Seconds buffered ahead and the current download speed (bytes/s),
        /// about once a second.
        case network(buffer: Double, bytesPerSecond: Double)
        /// A jump landed and playback carried on; seconds since it was asked.
        case seeked(Double)
        case ended
    }

    let layer = MPVMetalLayer()
    var onEvent: (@MainActor (Event) -> Void)?

    private var mpv: OpaquePointer?
    private let queue = DispatchQueue(label: "openiptv.mpv", qos: .userInitiated)
    private var loadStarted = CFAbsoluteTimeGetCurrent()
    /// When the file was open (headers read), for the start-up breakdown.
    private(set) var openedAfter: Double?
    private var reportedStart = false
    /// When the last explicit jump was asked for (not scrubbing previews).
    private var seekStarted: CFAbsoluteTime?
    /// The first frame is ready (a warmed-up player may already be there).
    var hasStarted: Bool { queue.sync { reportedStart } }
    private var duration: Double?
    private var buffered: Double = 0
    private var downloadSpeed: Double = 0
    private var lastNetworkReport: CFAbsoluteTime = 0

    /// How far ahead to download. Files on an unmetered connection are
    /// fetched to the end into a temporary file, so any seek ahead (or back
    /// over what's been played) is instant.
    enum Readahead: Equatable {
        /// Live streams: the profile's small buffer, in memory.
        case live
        /// Opened in the background before a tap: a minute, on disk.
        case warm
        /// Cellular / low space: five minutes, in memory.
        case modest
        /// Wi-Fi: the whole rest of the file, on disk, up to `bytes`.
        case whole(bytes: Int64)
    }

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
        set("demuxer-mkv-probe-start-time", "no")
        // Carry on quickly after a seek or a short stall.
        set("cache-pause-wait", "0.3")
        set("demuxer-seekable-cache", "yes")
        let cacheDir = FileManager.default.temporaryDirectory.appending(path: "player-cache")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        set("demuxer-cache-dir", cacheDir.path())
        // No log output at all: stream URLs carry credentials.
        set("msg-level", "all=no")
        for (name, value) in options { set(name, value) }
        mpv_initialize(mpv)
        mpv_observe_property(mpv, 0, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "demuxer-cache-duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "cache-speed", MPV_FORMAT_INT64)
        mpv_set_wakeup_callback(mpv, { context in
            guard let context else { return }
            Unmanaged<MPVPlayer>.fromOpaque(context).takeUnretainedValue().drainEvents()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Start a stream with any headers the provider requires; `start`
    /// resumes a file at that many seconds. Files (`file: true`, Emby) are
    /// read in bounded ranges over one kept-alive connection, so the jumps
    /// to the end of a Matroska file and back (index, tags) and the resume
    /// seek don't each pay for a new HTTPS handshake. Live streams can't be
    /// range-requested, so they're read as one stream.
    func load(_ url: URL, headers: [String] = [], start: Double? = nil, file: Bool = false, readahead: Readahead = .live) {
        // Files go through the in-app relay, which keeps one warm HTTP/2
        // connection to the server instead of a new one per seek.
        var url = url, headers = headers
        if file, url.scheme?.hasPrefix("http") == true, let local = StreamRelay.shared.localURL(for: url, headers: headers) {
            url = local
            headers = []
        }
        queue.async { [self] in
            guard let mpv else { return }
            apply(readahead, mpv)
            loadStarted = CFAbsoluteTimeGetCurrent()
            openedAfter = nil
            reportedStart = false
            duration = nil
            mpv_set_property_string(mpv, "http-header-fields", headers.joined(separator: ","))
            mpv_set_property_string(mpv, "stream-lavf-o", file
                ? "multiple_requests=1,initial_request_size=524288,request_size=8388608,short_seek_size=1048576"
                : "")
            mpv_set_property_string(mpv, "start", start.map { String(format: "%.1f", $0) } ?? "none")
            // Resume at the nearest keyframe instead of decoding up to the
            // exact second; precise seeking comes back once it's playing.
            mpv_set_property_string(mpv, "hr-seek", start == nil ? "default" : "no")
            command(["loadfile", url.absoluteString, "replace"])
        }
    }

    /// Changes how far ahead the current file downloads (a warmed-up player
    /// switches to the whole file once it's actually being watched).
    func setReadahead(_ readahead: Readahead) {
        queue.async { [self] in
            guard let mpv else { return }
            apply(readahead, mpv, opening: false)
        }
    }

    private func apply(_ readahead: Readahead, _ mpv: OpaquePointer, opening: Bool = true) {
        func set(_ name: String, _ value: String) { mpv_set_property_string(mpv, name, value) }
        switch readahead {
        case .live:
            if opening { set("cache-on-disk", "no") }
            set("demuxer-max-bytes", "150MiB")
            set("demuxer-max-back-bytes", "50MiB")
        case .warm:
            if opening { set("cache-on-disk", "yes") }
            set("demuxer-readahead-secs", "60")
            set("demuxer-max-bytes", "1GiB")
            set("demuxer-max-back-bytes", "1GiB")
        case .modest:
            if opening { set("cache-on-disk", "no") }
            set("demuxer-readahead-secs", "300")
            set("demuxer-max-bytes", "300MiB")
            set("demuxer-max-back-bytes", "100MiB")
        case let .whole(bytes):
            if opening { set("cache-on-disk", "yes") }
            set("demuxer-readahead-secs", "86400")
            set("demuxer-max-bytes", String(bytes))
            set("demuxer-max-back-bytes", String(bytes))
        }
    }

    /// The video surface changed size (the phone turned). libmpv's Metal
    /// output only measures its surface when the picture's format changes,
    /// so nudge the aspect ratio by a hundredth of a percent (invisible) and
    /// put it back: each change makes it lay the picture out for the new size.
    func surfaceChanged() {
        queue.async { [self] in
            guard let mpv else { return }
            var aspect: Double = 0
            guard mpv_get_property(mpv, "video-params/aspect", MPV_FORMAT_DOUBLE, &aspect) >= 0, aspect > 0 else { return }
            mpv_set_property_string(mpv, "video-aspect-override", String(aspect * 1.0001))
            queue.asyncAfter(deadline: .now() + 0.12) { [self] in
                guard let current = self.mpv else { return }
                mpv_set_property_string(current, "video-aspect-override", "-1")
            }
        }
    }

    func setPaused(_ paused: Bool) {
        queue.async { [self] in
            guard let mpv else { return }
            mpv_set_property_string(mpv, "pause", paused ? "yes" : "no")
        }
    }

    /// Gives the video layer a full-screen drawable before it's on screen,
    /// so a player warmed up in the background can render its first frame.
    @MainActor func prepareOffscreen() {
        guard let screen = UIApplication.shared.connectedScenes.compactMap({ ($0 as? UIWindowScene)?.screen }).first else { return }
        layer.frame = screen.bounds
        layer.contentsScale = screen.scale
        layer.drawableSize = CGSize(width: screen.bounds.width * screen.scale, height: screen.bounds.height * screen.scale)
    }

    func togglePause() {
        queue.async { [self] in command(["cycle", "pause"]) }
    }

    func seek(by seconds: Double) {
        queue.async { [self] in
            seekStarted = CFAbsoluteTimeGetCurrent()
            command(["seek", String(seconds), "relative"])
        }
    }

    /// `exact: false` lands on the nearest keyframe: quick enough to follow
    /// a finger while scrubbing.
    /// `report`: time it and say how long it took (`.seeked`), for jumps
    /// the viewer asked for rather than scrubbing previews.
    func seek(to seconds: Double, exact: Bool = true, report: Bool = false) {
        queue.async { [self] in
            seekStarted = report ? CFAbsoluteTimeGetCurrent() : nil
            command(["seek", String(seconds), exact ? "absolute+exact" : "absolute+keyframes"])
        }
    }

    /// Stops playback and frees libmpv; the network connection closes with
    /// it. Returns at once: closing a connection mid-download can take a
    /// moment, and the screen mustn't wait for it.
    func shutdown() {
        onEvent = nil
        queue.async { [self] in
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
        case MPV_EVENT_FILE_LOADED:
            openedAfter = CFAbsoluteTimeGetCurrent() - loadStarted
        case MPV_EVENT_PLAYBACK_RESTART where !reportedStart:
            reportedStart = true
            seekStarted = nil
            if let mpv { mpv_set_property_string(mpv, "hr-seek", "default") }
            emit(.started(CFAbsoluteTimeGetCurrent() - loadStarted))
        case MPV_EVENT_PLAYBACK_RESTART:
            if let asked = seekStarted {
                seekStarted = nil
                emit(.seeked(CFAbsoluteTimeGetCurrent() - asked))
            }
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
            case "demuxer-cache-duration" where property.format == MPV_FORMAT_DOUBLE:
                buffered = value.assumingMemoryBound(to: Double.self).pointee
                reportNetwork()
            case "cache-speed" where property.format == MPV_FORMAT_INT64:
                downloadSpeed = Double(value.assumingMemoryBound(to: Int64.self).pointee)
                reportNetwork()
            default:
                break
            }
        default:
            break
        }
    }

    private func reportNetwork() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastNetworkReport >= 1 else { return }
        lastNetworkReport = now
        emit(.network(buffer: buffered, bytesPerSecond: downloadSpeed))
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
    private weak var player: MPVPlayer?
    private var lastSize: CGSize = .zero

    init(player: MPVPlayer) {
        metalLayer = player.layer
        self.player = player
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
        // Turned (or resized): libmpv resizes its surface but keeps placing
        // the picture for the old size, so tell it the surface changed.
        if lastSize != .zero, bounds.size != lastSize { player?.surfaceChanged() }
        lastSize = bounds.size
    }
}

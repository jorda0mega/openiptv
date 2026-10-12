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
        /// A preview while choosing where to jump is on screen (its target,
        /// in the player's seconds).
        case previewShown(Double)
        /// Streams (not files), about once a second: the stretch kept to
        /// rewind into, in the stream's own seconds, and whether the server
        /// also lets it jump outside that stretch.
        case window(start: Double, end: Double, seekable: Bool)
        case ended
    }

    let layer = MPVMetalLayer()
    var onEvent: (@MainActor (Event) -> Void)?
    /// Players still closing their connection. A live stream waits for them
    /// (up to 2 s) before opening its own: many IPTV accounts allow one
    /// connection, and a second while the first is closing gets refused.
    private static let closing = DispatchGroup()
    /// Shut down (set at once, so a load still queued is dropped instead of
    /// opening a stream), and whether a live stream was asked for (only
    /// those make the next live stream wait for them to close).
    private let stateLock = NSLock()
    private var closed = false
    private var playedLive = false

    private var mpv: OpaquePointer?
    private let queue = DispatchQueue(label: "openiptv.mpv", qos: .userInitiated)
    private var loadStarted = CFAbsoluteTimeGetCurrent()
    /// When the file was open (headers read), for the start-up breakdown.
    private(set) var openedAfter: Double?
    private var reportedStart = false
    /// When the last explicit jump was asked for (not scrubbing previews).
    private var seekStarted: CFAbsoluteTime?
    /// Choosing where to jump: when the picture's current jump was asked
    /// for, and the newest target to show once it lands.
    private var followStarted: CFAbsoluteTime?
    private var followNext: (seconds: Double, exact: Bool)?
    /// Where the jump under way is going, and where the last one landed.
    private var followTarget: Double?
    private var followShown: Double?
    /// Whether those were exact frames (else the keyframe before).
    private var followTargetExact = false
    private var followShownExact = false
    /// The bar moves a few times a second; every frame (24-60 a second)
    /// used to re-render the player's screen for nothing.
    private var lastTimeEmit: CFAbsoluteTime = 0
    private var lastTimePosition: Double = 0
    /// `reportedStart`, readable from the screen without waiting for the
    /// player's queue (busy starting up or opening a file).
    private let startLock = NSLock()
    private var startedFlag = false
    /// The first frame is ready (a warmed-up player may already be there).
    var hasStarted: Bool { startLock.withLock { startedFlag } }
    private var duration: Double?
    private var buffered: Double = 0
    private var downloadSpeed: Double = 0
    private var lastNetworkReport: CFAbsoluteTime = 0
    private var reportsWindow = false

    /// How far ahead to download, always in memory for files: libmpv's
    /// disk cache is append-only (every byte downloaded stays in the file
    /// until playback closes), so a whole 4K film could fill an Apple TV's
    /// disk. `cache-secs` is set with each, or libmpv's default (far larger)
    /// overrides the readahead and a "warm" player downloads for minutes.
    enum Readahead: Equatable {
        /// Live streams: what's been watched since tuning in, to rewind (on
        /// disk when there's plenty of room: it's only as big as the session).
        case live
        /// Opened in the background before a tap: a few seconds, enough to
        /// start at once without taking bandwidth from anything else.
        case warm
        /// Cellular / Low Data Mode: two minutes.
        case modest
        /// Wi-Fi: as much as fits in 300 MB ahead, 100 MB behind.
        case generous
    }

    /// Returns at once: libmpv starts up on the player's own queue (its
    /// initialisation takes a while, and used to hold up the screen that
    /// opened the player); everything asked of the player queues behind it.
    init(options: [(String, String)], hardwareDecoding: Bool) {
        layer.framebufferOnly = true
        layer.backgroundColor = UIColor.black.cgColor
        let wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        queue.async { [self] in setUp(wid: wid, options: options, hardwareDecoding: hardwareDecoding) }
    }

    private func setUp(wid: Int64, options: [(String, String)], hardwareDecoding: Bool) {
        guard let mpv = mpv_create() else { return }
        self.mpv = mpv
        var wid = wid
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
        #if DEBUG
        // Tests comparing options: "name=value;name=value".
        for pair in (ProcessInfo.processInfo.environment["OPENREEL_DEBUG_MPV"] ?? "").split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { set(parts[0], parts[1]) }
        }
        #endif
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
    /// range-requested, so they're read as one stream. `sequential` reads
    /// a stream straight through even if the server could jump (an IPTV
    /// recording: opening one jumps to its end and back, extra connections
    /// a one-connection provider may refuse); jumps stay within what's
    /// downloaded.
    func load(_ url: URL, headers: [String] = [], start: Double? = nil, file: Bool = false, sequential: Bool = false,
              readahead: Readahead = .live, tracks: TrackPlan? = nil) {
        // Files go through the in-app relay, which keeps one warm HTTP/2
        // connection to the server instead of a new one per seek.
        var url = url, headers = headers
        if file, url.scheme?.hasPrefix("http") == true, let local = StreamRelay.shared.localURL(for: url, headers: headers) {
            url = local
            headers = []
        }
        if !file { stateLock.withLock { playedLive = true } }
        queue.async { [self] in
            guard let mpv, !stateLock.withLock({ closed }) else { return }
            if !file { _ = Self.closing.wait(timeout: .now() + 2) }
            apply(readahead, mpv)
            loadStarted = CFAbsoluteTimeGetCurrent()
            reportsWindow = !file
            openedAfter = nil
            reportedStart = false
            startLock.withLock { startedFlag = false }
            duration = nil
            mpv_set_property_string(mpv, "http-header-fields", headers.joined(separator: ","))
            mpv_set_property_string(mpv, "stream-lavf-o", file
                ? "multiple_requests=1,initial_request_size=524288,request_size=8388608,short_seek_size=1048576"
                : sequential ? "seekable=0" : "")
            mpv_set_property_string(mpv, "start", start.map { String(format: "%.1f", $0) } ?? "none")
            // Resume at the nearest keyframe instead of decoding up to the
            // exact second; precise seeking comes back once it's playing.
            mpv_set_property_string(mpv, "hr-seek", start == nil ? "default" : "no")
            Self.apply(tracks, mpv)
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
        func ahead(_ seconds: Int) {
            set("demuxer-readahead-secs", String(seconds))
            set("cache-secs", String(seconds))
        }
        switch readahead {
        case .live:
            // Keeps what's been watched (up to about an hour of a typical
            // channel) so live TV can be paused and rewound, and keeps
            // downloading while paused.
            let onDisk = NetworkStatus.shared.roomForTimeshift
            if opening { set("cache-on-disk", onDisk ? "yes" : "no") }
            ahead(7200)
            set("demuxer-max-bytes", onDisk ? "1GiB" : "128MiB")
            set("demuxer-max-back-bytes", onDisk ? "1GiB" : "256MiB")
        case .warm:
            if opening { set("cache-on-disk", "no") }
            ahead(10)
            set("demuxer-max-bytes", "96MiB")
            set("demuxer-max-back-bytes", "32MiB")
        case .modest:
            if opening { set("cache-on-disk", "no") }
            ahead(120)
            set("demuxer-max-bytes", "128MiB")
            set("demuxer-max-back-bytes", "64MiB")
        case .generous:
            if opening { set("cache-on-disk", "no") }
            ahead(3600)
            set("demuxer-max-bytes", "300MiB")
            set("demuxer-max-back-bytes", "100MiB")
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

    /// `exact: false` (the remote's skips): the keyframe just past the
    /// target going forward (just before it going back), so it always moves
    /// at least that far, and the picture is there at once. An exact seek
    /// first decodes every frame from the keyframe before the target: 1-2 s
    /// on Apple TV for a 4K film with keyframes 10 s apart.
    func seek(by seconds: Double, exact: Bool = true) {
        queue.async { [self] in
            #if DEBUG
            if let mpv {
                var position: Double = 0
                mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &position)
                let ranges = Self.allRanges(mpv).map { String(format: "%.0f-%.0f", $0.0, $0.1) }.joined(separator: ",")
                func text(_ name: String) -> String {
                    guard let value = mpv_get_property_string(mpv, name) else { return "?" }
                    defer { mpv_free(value) }
                    return String(cString: value)
                }
                NSLog("%@", String(format: "PERF cache at %.1f by %+.0f ranges %@ ahead %@ readahead %@ cache-secs %@ max %@",
                                   position, seconds, ranges, text("demuxer-cache-duration"), text("demuxer-readahead-secs"),
                                   text("cache-secs"), text("demuxer-max-bytes")))
            }
            #endif
            stopFollowing()
            seekStarted = CFAbsoluteTimeGetCurrent()
            command(["seek", String(seconds), exact ? "relative+exact" : "relative+keyframes"])
        }
    }

    /// `exact: false` lands on the nearest keyframe: quick enough to follow
    /// a finger while scrubbing.
    /// `report`: time it and say how long it took (`.seeked`), for jumps
    /// the viewer asked for rather than scrubbing previews.
    func seek(to seconds: Double, exact: Bool = true, report: Bool = false) {
        queue.async { [self] in
            stopFollowing()
            seekStarted = report ? CFAbsoluteTimeGetCurrent() : nil
            command(["seek", String(seconds), exact ? "absolute+exact" : "absolute+keyframes"])
        }
    }

    /// While choosing where to jump (a swipe, a held button, a drag): the
    /// picture follows as fast as the player can show frames, one jump at a
    /// time, the newest target next. Sent all at once, each jump cancelled
    /// the one before when the data had to download, and the picture never
    /// moved. A jump that hasn't landed in 1.5 s gives way.
    func follow(to seconds: Double, exact: Bool) {
        queue.async { [self] in
            let now = CFAbsoluteTimeGetCurrent()
            if let started = followStarted, now - started < 1.5 {
                if followNext == nil {
                    queue.asyncAfter(deadline: .now() + 1.5 - (now - started)) { [self] in
                        guard let next = followNext, let started = followStarted,
                              CFAbsoluteTimeGetCurrent() - started >= 1.45 else { return }
                        startFollowing(next.seconds, exact: next.exact)
                    }
                }
                followNext = (seconds, exact)
                return
            }
            startFollowing(seconds, exact: exact)
        }
    }

    /// Choosing is over: the picture ends on `seconds` and playback carries
    /// on from there. At once when the last preview already shows it (or is
    /// about to); otherwise one jump there, replacing any still queued, so
    /// nothing lands after letting go.
    func settle(at seconds: Double, exact: Bool) {
        queue.async { [self] in
            // Kept when it's the same second and at least as precise as asked.
            let (at, precise) = followStarted == nil ? (followShown, followShownExact) : (followTarget, followTargetExact)
            if followNext == nil, let at, abs(at - seconds) < 0.5, precise || !exact { return }
            stopFollowing()
            seekStarted = CFAbsoluteTimeGetCurrent()
            command(["seek", String(seconds), exact ? "absolute+exact" : "absolute+keyframes"])
        }
    }

    private func startFollowing(_ seconds: Double, exact: Bool) {
        followStarted = CFAbsoluteTimeGetCurrent()
        followTarget = seconds
        followTargetExact = exact
        followShown = nil
        followNext = nil
        seekStarted = nil
        command(["seek", String(seconds), exact ? "absolute+exact" : "absolute+keyframes"])
    }

    private func stopFollowing() {
        followStarted = nil
        followTarget = nil
        followShown = nil
        followNext = nil
    }

    /// An audio or subtitle track of the file.
    struct Track: Identifiable, Hashable, Sendable {
        enum Kind: Sendable { case audio, subtitle }
        let id: Int
        let kind: Kind
        let title: String?
        /// ISO 639 code ("eng"), when the file says.
        let language: String?
        let channels: Int?
        let forced: Bool
        let selected: Bool
    }

    /// The file's audio and subtitle tracks, as they are now.
    func tracks() async -> [Track] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let mpv else { return continuation.resume(returning: []) }
                continuation.resume(returning: Self.trackList(mpv))
            }
        }
    }

    /// The audio and subtitles to start with: the plan's languages, and no
    /// subtitles but forced ones in the audio's language when it has none
    /// (a file's or the server's "default" subtitles are not shown). No
    /// plan (live TV): the stream's own choice.
    private static func apply(_ plan: TrackPlan?, _ mpv: OpaquePointer) {
        func set(_ name: String, _ value: String) {
            let result = mpv_set_property_string(mpv, name, value)
            #if DEBUG
            if result < 0 { NSLog("%@", "PERF option \(name)=\(value) failed \(result)") }
            #endif
        }
        set("aid", "auto")
        set("sid", "auto")
        guard let plan else {
            set("alang", "")
            set("slang", "")
            set("subs-fallback", "default")
            set("subs-fallback-forced", "yes")
            return
        }
        set("alang", plan.audio.joined(separator: ","))
        set("slang", plan.subtitles?.joined(separator: ",") ?? "")
        set("subs-fallback", "no")
        set("subs-fallback-forced", "yes")
        set("subs-with-matching-audio", "no")
        // Not the phone's language either (only the plan's).
        set("subs-match-os-language", "no")
    }

    /// Fills the screen with the picture (cropping its edges) or fits it.
    func setFill(_ fill: Bool) {
        queue.async { [self] in
            guard let mpv else { return }
            mpv_set_property_string(mpv, "panscan", fill ? "1.0" : "0.0")
        }
    }

    /// Plays this audio track.
    func selectAudio(_ id: Int) {
        queue.async { [self] in
            guard let mpv else { return }
            mpv_set_property_string(mpv, "aid", String(id))
        }
    }

    /// Shows this subtitle track (nil: none).
    func selectSubtitle(_ id: Int?) {
        queue.async { [self] in
            guard let mpv else { return }
            mpv_set_property_string(mpv, "sid", id.map(String.init) ?? "no")
        }
    }

    /// The picture's height and transfer ("pq", "hlg" for HDR), once it's
    /// playing: the Info panel's 4K / HD and HDR badges.
    func videoFormat() async -> (height: Int, gamma: String?)? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let mpv else { return continuation.resume(returning: nil) }
                var height: Int64 = 0
                guard mpv_get_property(mpv, "video-params/h", MPV_FORMAT_INT64, &height) >= 0, height > 0 else {
                    return continuation.resume(returning: nil)
                }
                var gamma: String?
                if let value = mpv_get_property_string(mpv, "video-params/gamma") {
                    gamma = String(cString: value)
                    mpv_free(value)
                }
                continuation.resume(returning: (Int(height), gamma))
            }
        }
    }

    private static func trackList(_ mpv: OpaquePointer) -> [Track] {
        var node = mpv_node()
        guard mpv_get_property(mpv, "track-list", MPV_FORMAT_NODE, &node) >= 0 else { return [] }
        defer { mpv_free_node_contents(&node) }
        guard node.format == MPV_FORMAT_NODE_ARRAY, let list = node.u.list?.pointee else { return [] }
        return (0..<Int(list.num)).compactMap { i in
            let track = list.values[i]
            guard track.format == MPV_FORMAT_NODE_MAP, let map = track.u.list?.pointee else { return nil }
            var fields: [String: mpv_node] = [:]
            for k in 0..<Int(map.num) {
                if let key = map.keys[k] { fields[String(cString: key)] = map.values[k] }
            }
            func text(_ name: String) -> String? {
                guard let value = fields[name], value.format == MPV_FORMAT_STRING, let s = value.u.string else { return nil }
                return String(cString: s)
            }
            func number(_ name: String) -> Int? {
                guard let value = fields[name], value.format == MPV_FORMAT_INT64 else { return nil }
                return Int(value.u.int64)
            }
            func flag(_ name: String) -> Bool {
                guard let value = fields[name], value.format == MPV_FORMAT_FLAG else { return false }
                return value.u.flag != 0
            }
            let kind: Track.Kind
            switch text("type") {
            case "audio": kind = .audio
            case "sub": kind = .subtitle
            default: return nil
            }
            guard let id = number("id") else { return nil }
            return Track(id: id, kind: kind, title: text("title"), language: text("lang"),
                         channels: number("demux-channel-count"), forced: flag("forced"), selected: flag("selected"))
        }
    }

    /// Stops playback and frees libmpv; the network connection closes with
    /// it. Returns at once: closing a connection mid-download can take a
    /// moment, and the screen mustn't wait for it.
    func shutdown() {
        onEvent = nil
        let live = stateLock.withLock { () -> Bool in
            closed = true
            return playedLive
        }
        if live { Self.closing.enter() }
        queue.async { [self] in
            defer { if live { Self.closing.leave() } }
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
            startLock.withLock { startedFlag = true }
            seekStarted = nil
            if let mpv { mpv_set_property_string(mpv, "hr-seek", "default") }
            emit(.started(CFAbsoluteTimeGetCurrent() - loadStarted))
        case MPV_EVENT_PLAYBACK_RESTART:
            if followStarted != nil {
                followStarted = nil
                followShown = followTarget
                followShownExact = followTargetExact
                if let shown = followTarget { emit(.previewShown(shown)) }
                if let next = followNext { startFollowing(next.seconds, exact: next.exact) }
            }
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
                // Four times a second, and at once after a jump.
                let position = value.assumingMemoryBound(to: Double.self).pointee
                let now = CFAbsoluteTimeGetCurrent()
                guard now - lastTimeEmit >= 0.25 || abs(position - lastTimePosition) > 1.5 else { break }
                lastTimeEmit = now
                lastTimePosition = position
                emit(.time(position: position, duration: duration))
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
        if reportsWindow, let mpv, let window = Self.keptWindow(mpv) {
            var seekable: Int32 = 0
            mpv_get_property(mpv, "seekable", MPV_FORMAT_FLAG, &seekable)
            emit(.window(start: window.start, end: window.end, seekable: seekable != 0))
        }
    }

    #if DEBUG
    private static func allRanges(_ mpv: OpaquePointer) -> [(Double, Double)] {
        var state = mpv_node()
        guard mpv_get_property(mpv, "demuxer-cache-state", MPV_FORMAT_NODE, &state) >= 0 else { return [] }
        defer { mpv_free_node_contents(&state) }
        func field(_ node: mpv_node, _ name: String) -> mpv_node? {
            guard node.format == MPV_FORMAT_NODE_MAP, let map = node.u.list?.pointee else { return nil }
            for i in 0..<Int(map.num) where map.keys[i].map({ String(cString: $0) }) == name { return map.values[i] }
            return nil
        }
        guard let ranges = field(state, "seekable-ranges"), ranges.format == MPV_FORMAT_NODE_ARRAY,
              let list = ranges.u.list?.pointee else { return [] }
        return (0..<Int(list.num)).compactMap { i in
            guard let s = field(list.values[i], "start"), let e = field(list.values[i], "end") else { return nil }
            return (s.u.double_, e.u.double_)
        }
    }
    #endif

    /// The span of the demuxer cache that can be jumped to
    /// (demuxer-cache-state's seekable ranges; the newest one, which a
    /// stream read straight through only ever has).
    private static func keptWindow(_ mpv: OpaquePointer) -> (start: Double, end: Double)? {
        var state = mpv_node()
        guard mpv_get_property(mpv, "demuxer-cache-state", MPV_FORMAT_NODE, &state) >= 0 else { return nil }
        defer { mpv_free_node_contents(&state) }
        func field(_ node: mpv_node, _ name: String) -> mpv_node? {
            guard node.format == MPV_FORMAT_NODE_MAP, let map = node.u.list?.pointee else { return nil }
            for i in 0..<Int(map.num) where map.keys[i].map({ String(cString: $0) }) == name { return map.values[i] }
            return nil
        }
        guard let ranges = field(state, "seekable-ranges"), ranges.format == MPV_FORMAT_NODE_ARRAY,
              let list = ranges.u.list?.pointee else { return nil }
        var best: (start: Double, end: Double)?
        for i in 0..<Int(list.num) {
            guard let start = field(list.values[i], "start"), start.format == MPV_FORMAT_DOUBLE,
                  let end = field(list.values[i], "end"), end.format == MPV_FORMAT_DOUBLE else { continue }
            if end.u.double_ > best?.end ?? -.infinity { best = (start.u.double_, end.u.double_) }
        }
        return best
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
    private var settle: DispatchWorkItem?

    init(player: MPVPlayer) {
        metalLayer = player.layer
        self.player = player
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(metalLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
    }

    /// The picture always covers the whole window, whatever SwiftUI makes
    /// of this view: showing the controls (and with them the status bar)
    /// used to change its height by 30 points, animated, and the picture
    /// zoomed and lost its top and bottom.
    override func layoutSubviews() {
        super.layoutSubviews()
        let area = window.map { convert($0.bounds, from: $0) } ?? bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = area
        let scale = traitCollection.displayScale
        metalLayer.contentsScale = scale
        if area.size != lastSize {
            metalLayer.drawableSize = CGSize(width: area.width * scale, height: area.height * scale)
        }
        CATransaction.commit()
        guard area.size != lastSize else { return }
        #if DEBUG
        NSLog("%@", "PERF surface \(Int(area.width))x\(Int(area.height))")
        #endif
        // Turned: libmpv resizes its surface but keeps placing the picture
        // for the old size, so tell it, now and once the turn has settled
        // (not on every frame of it, which could leave a size from midway).
        if lastSize != .zero {
            player?.surfaceChanged()
            settle?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.player?.surfaceChanged() }
            settle = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
        lastSize = area.size
    }
}

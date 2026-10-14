import Libmpv
import QuartzCore
import UIKit
#if os(iOS)
import Accelerate
import AVFoundation
#endif

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
    /// The file's audio and subtitles to pick (the player's queue).
    private var trackPlan: TrackPlan?
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
    /// How it decodes on screen (the hardware's output goes straight to the
    /// GPU), to go back to after Picture in Picture.
    private let hardwareDecoding: Bool
    #if os(iOS)
    /// Picture in Picture: the picture drawn into the window's layer.
    private var frameTap: FrameTap?
    /// The picture drawn on screen again: shown once it is (the screen's
    /// surface still holds a frame from before the window).
    private var revealPending = false
    #endif

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
        self.hardwareDecoding = hardwareDecoding
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
        // Subtitles sized by the picture and kept on it, as in the Apple TV
        // app (by the window, a phone held upright drew them huge, under the
        // picture and off the bottom of the screen).
        set("sub-scale-with-window", "no")
        set("sub-use-margins", "no")
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
        // A file's tracks are known, none picked yet: see handle(_:).
        mpv_hook_add(mpv, 0, "on_preloaded", 50)
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
            trackPlan = tracks
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

    /// Sound off or on (the film plays on).
    func setMuted(_ muted: Bool) {
        queue.async { [self] in
            guard let mpv else { return }
            mpv_set_property_string(mpv, "mute", muted ? "yes" : "no")
        }
    }

    /// Playback speed (1: normal); the sound keeps its pitch.
    func setSpeed(_ speed: Double) {
        queue.async { [self] in
            guard let mpv else { return }
            mpv_set_property_string(mpv, "speed", String(speed))
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
        var selected: Bool
        /// Subtitles for the deaf and hard of hearing (the file says so).
        var hearingImpaired = false

        /// What the track is for besides its language: "commentary", "sdh",
        /// "forced", or nil (the main one). Two English subtitle tracks,
        /// say, are told apart by it.
        var role: String? {
            let words = Set((title ?? "").lowercased().split { !$0.isLetter }.map(String.init))
            if words.contains("commentary") { return "commentary" }
            if hearingImpaired || !words.isDisjoint(with: ["sdh", "cc", "hoh"]) { return "sdh" }
            if forced { return "forced" }
            return nil
        }
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
        // Subtitles asked for (picked by the viewer, or the audio in
        // neither language) show even in the audio's language.
        set("subs-with-matching-audio", plan.subtitles == nil ? "no" : "yes")
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
                         channels: number("demux-channel-count"), forced: flag("forced"), selected: flag("selected"),
                         hearingImpaired: flag("hearing-impaired"))
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
            #if os(iOS)
            // libmpv's renderer goes before libmpv does.
            if let tap = frameTap {
                frameTap = nil
                mpv_set_property_string(mpv, "vo", "null")
                tap.close()
            }
            #endif
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
        #if os(iOS)
        // Back on screen after Picture in Picture: shown once libmpv has
        // drawn the picture where it is now.
        if revealPending, event.event_id == MPV_EVENT_VIDEO_RECONFIG || event.event_id == MPV_EVENT_PLAYBACK_RESTART {
            revealPending = false
            let layer = layer
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { layer.isHidden = false }
        }
        #endif
        switch event.event_id {
        case MPV_EVENT_HOOK:
            guard let data = event.data, let mpv else { return }
            let hook = data.assumingMemoryBound(to: mpv_event_hook.self).pointee
            // The plan's exact tracks (language and kind, with the viewer's
            // newest picks) before anything is decoded: nothing switches
            // once it plays (a switch just after the start could stall it).
            if String(cString: hook.name) == "on_preloaded", let plan = trackPlan?.refreshed() {
                let choice = TrackChoice.choose(Self.trackList(mpv), plan: plan)
                if let audio = choice.audio { mpv_set_property_string(mpv, "aid", String(audio)) }
                mpv_set_property_string(mpv, "sid", choice.subtitle.map(String.init) ?? "no")
            }
            mpv_hook_continue(mpv, hook.id)
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

#if os(iOS)
extension MPVPlayer {
    /// Picture in Picture: the same playback (nothing reopens, pauses or
    /// jumps), its picture drawn into `layer` by the CPU instead of onto
    /// the screen by the GPU. iOS's floating window shows only its own
    /// kinds of layer, and an app in the background can't use the GPU.
    /// `drawn`: the first frame is in the layer.
    func drawFrames(into layer: AVSampleBufferDisplayLayer, drawn: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            guard let mpv, frameTap == nil else { return }
            // The picture's shape, at most 1280 wide: plenty for the
            // window, and quick to draw.
            var width: Int64 = 0, height: Int64 = 0
            mpv_get_property(mpv, "video-params/dw", MPV_FORMAT_INT64, &width)
            mpv_get_property(mpv, "video-params/dh", MPV_FORMAT_INT64, &height)
            if width <= 0 || height <= 0 { (width, height) = (1280, 720) }
            let w = Int(min(width, 1280)) & ~1
            let h = max(2, Int((Double(w) * Double(height) / Double(width)).rounded()) & ~1)
            guard let tap = FrameTap(mpv: mpv, layer: layer, width: w, height: h, drawn: drawn) else { return }
            frameTap = tap
            mpv_set_property_string(mpv, "sw-fast", "yes")
            // Decoded frames copied back from the decoder for the CPU.
            mpv_set_property_string(mpv, "hwdec", hardwareDecoding ? "videotoolbox-copy" : "no")
            let switched = mpv_set_property_string(mpv, "vo", "libmpv")
            #if DEBUG
            NSLog("%@", "PERF pip frames \(w)x\(h) vo=\(switched)")
            #endif
        }
    }

    /// Back on screen from Picture in Picture (the screen's layer is in a
    /// window again): the GPU draws it, as before.
    func drawOnScreen() {
        guard stateLock.withLock({ !closed }) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.isHidden = true
        CATransaction.commit()
        queue.async { [self] in
            guard let mpv, let tap = frameTap else { return }
            frameTap = nil
            revealPending = true
            mpv_set_property_string(mpv, "vo", "gpu-next")
            mpv_set_property_string(mpv, "hwdec", hardwareDecoding ? "videotoolbox" : "no")
            tap.close()
            // Shown in any case after a moment (a paused picture may not
            // say it's drawn).
            let layer = layer
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { layer.isHidden = false }
        }
    }
}

/// Draws libmpv's picture into frames for an AVSampleBufferDisplayLayer, on
/// its own thread, each when libmpv says it's due. libmpv draws RGB; the
/// frames go out as video's own 4:2:0 YUV.
private final class FrameTap: @unchecked Sendable {
    private let context: OpaquePointer
    private let layer: AVSampleBufferDisplayLayer
    private let width: Int
    private let height: Int
    private let drawn: @Sendable () -> Void
    private let queue = DispatchQueue(label: "openiptv.pip-frames", qos: .userInteractive)
    private let lock = NSLock()
    private var closed = false
    private var waiting = false
    private var pool: CVPixelBufferPool?
    private var format: CMVideoFormatDescription?
    private var count = 0
    #if DEBUG
    private var updates = 0
    #endif
    /// libmpv's RGB picture, before it's converted.
    private let rgb: UnsafeMutableRawPointer
    private let rgbStride: Int
    private var conversion = vImage_ARGBToYpCbCr()

    init?(mpv: OpaquePointer, layer: AVSampleBufferDisplayLayer, width: Int, height: Int, drawn: @escaping @Sendable () -> Void) {
        self.layer = layer
        self.width = width
        self.height = height
        self.drawn = drawn
        rgbStride = (width * 4 + 63) & ~63
        var memory: UnsafeMutableRawPointer?
        guard posix_memalign(&memory, 64, rgbStride * height) == 0, let memory else { return nil }
        rgb = memory
        var made: OpaquePointer?
        let api = strdup("sw")
        defer { free(api) }
        var params = [mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(api)),
                      mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)]
        guard mpv_render_context_create(&made, mpv, &params) >= 0, let made else {
            free(memory)
            return nil
        }
        context = made
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            // The floating window draws them with the GPU, in another process.
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        // Video range, HD colours.
        var range = vImage_YpCbCrPixelRange(Yp_bias: 16, CbCr_bias: 128, YpRangeMax: 235, CbCrRangeMax: 240,
                                            YpMax: 235, YpMin: 16, CbCrMax: 240, CbCrMin: 16)
        vImageConvert_ARGBToYpCbCr_GenerateConversion(kvImage_ARGBToYpCbCrMatrix_ITU_R_709_2, &range, &conversion,
                                                      kvImageARGB8888, kvImage420Yp8_CbCr8, vImage_Flags(kvImageNoFlags))
        mpv_render_context_set_update_callback(context, { raw in
            guard let raw else { return }
            Unmanaged<FrameTap>.fromOpaque(raw).takeUnretainedValue().due()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// Called by libmpv (any thread; nothing of libmpv's may be called here).
    private func due() {
        let skip = lock.withLock { () -> Bool in
            if closed || waiting { return true }
            waiting = true
            return false
        }
        if !skip { queue.async { [self] in draw() } }
    }

    private func draw() {
        guard lock.withLock({ waiting = false; return !closed }) else { return }
        let flags = mpv_render_context_update(context)
        #if DEBUG
        updates += 1
        if updates % 60 == 1 { NSLog("%@", "PERF pip update \(updates) flags=\(flags) drawn=\(count)") }
        #endif
        guard flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0, let pool else { return }
        var size: [Int32] = [Int32(width), Int32(height)]
        var stride = rgbStride
        var rendered: Int32 = 0
        let pixels = strdup("bgr0")
        size.withUnsafeMutableBufferPointer { size in
            withUnsafeMutablePointer(to: &stride) { stride in
                var params = [mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: UnsafeMutableRawPointer(size.baseAddress)),
                              mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(pixels)),
                              mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: UnsafeMutableRawPointer(stride)),
                              mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: rgb),
                              mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)]
                rendered = mpv_render_context_render(context, &params)
            }
        }
        free(pixels)
        var made: CVPixelBuffer?
        let pooled = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made)
        #if DEBUG
        if rendered < 0 || pooled != kCVReturnSuccess { NSLog("%@", "PERF pip frame lost render=\(rendered) pool=\(pooled)") }
        #endif
        guard rendered >= 0, pooled == kCVReturnSuccess, let buffer = made else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        var source = vImage_Buffer(data: rgb, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: rgbStride)
        var luma = vImage_Buffer(data: CVPixelBufferGetBaseAddressOfPlane(buffer, 0), height: vImagePixelCount(height),
                                 width: vImagePixelCount(width), rowBytes: CVPixelBufferGetBytesPerRowOfPlane(buffer, 0))
        var chroma = vImage_Buffer(data: CVPixelBufferGetBaseAddressOfPlane(buffer, 1), height: vImagePixelCount(height / 2),
                                   width: vImagePixelCount(width / 2), rowBytes: CVPixelBufferGetBytesPerRowOfPlane(buffer, 1))
        // Memory order B, G, R, (unused): read as A, R, G, B.
        let order: [UInt8] = [3, 2, 1, 0]
        vImageConvert_ARGB8888To420Yp8_CbCr8(&source, &luma, &chroma, &conversion, order, vImage_Flags(kvImageNoFlags))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        if format == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        }
        guard let format else { return }
        let now = layer.controlTimebase.map { CMTimebaseGetTime($0) } ?? CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: now, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = layer.sampleBufferRenderer
        // Interrupted (the app was away, or the phone locked): start over.
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding { renderer.flush() }
        renderer.enqueue(sample)
        count += 1
        if count == 1 { drawn() }
        #if DEBUG
        if count % 60 == 1 {
            NSLog("%@", "PERF pip frame \(count) render=\(rendered) status=\(renderer.status.rawValue) error=\(renderer.error?.localizedDescription ?? "none")")
        }
        #endif
    }

    /// Stops drawing and lets go of libmpv's renderer (after the player
    /// has gone back to drawing on screen).
    func close() {
        lock.withLock { closed = true }
        queue.sync {}
        mpv_render_context_set_update_callback(context, nil, nil)
        mpv_render_context_free(context)
        free(rgb)
    }
}
#endif

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

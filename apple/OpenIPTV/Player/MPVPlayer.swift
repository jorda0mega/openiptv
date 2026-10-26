import Libmpv
import QuartzCore
import UIKit
#if os(iOS)
import AVFoundation
import CoreText
import Metal
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
        case opening
        /// The stream is open (its first data read): its picture is next.
        case opened
        /// First frame is on screen; seconds since `load`.
        case started(Double)
        case buffering(Bool)
        case failed(String, StreamFailure?)
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
        case ended(StreamFailure?)
        /// Tracks were added (the server's subtitle files, once fetched).
        case tracksChanged
    }

    /// How the player draws, chosen when it's made and never changed while it lives (in libmpv a change of
    /// output is a seek back to the last keyframe and a restart).
    enum Picture {
        /// gpu-next on a Metal layer: Apple TV and live TV.
        case gpu
        #if os(iOS)
        /// FilmFrames: films and episodes on iPhone and iPad, the one layer Picture in Picture also shows.
        case frames
        #endif

        static var film: Picture {
            #if os(iOS)
            .frames
            #else
            .gpu
            #endif
        }
    }

    let layer = MPVMetalLayer()
    #if os(iOS)
    let frames: FilmFrames?
    #endif
    /// What the player's view hosts.
    var pictureLayer: CALayer {
        #if os(iOS)
        frames?.layer ?? layer
        #else
        layer
        #endif
    }
    var onEvent: (@MainActor (Event, Int) -> Void)? {
        didSet {
            // Tracks added, or a failure, while nobody listened (a player
            // opened ahead): the screen that takes it over hears it now.
            guard let handler = onEvent else { return }
            let (tracks, failure, attempt) = stateLock.withLock {
                defer { tracksUnheard = false; failureUnheard = nil }
                return (tracksUnheard, failureUnheard, loads.current)
            }
            if tracks { Task { @MainActor in handler(.tracksChanged, attempt) } }
            if let failure { Task { @MainActor in handler(.failed(failure.message, failure.class), failure.attempt) } }
        }
    }
    /// A `.tracksChanged` went out with no one listening.
    private var tracksUnheard = false
    /// A `.failed` that went out with no one listening.
    private var failureUnheard: (message: String, class: StreamFailure?, attempt: Int)?
    private var logged: (failure: StreamFailure, at: CFAbsoluteTime, attempt: Int)?
    private var loads = LoadEvents()
    private var askedAttempt = 0
    /// The attempt events carry for the last load asked for.
    var currentAttempt: Int { stateLock.withLock { askedAttempt } }
    private static let ids = NSLock()
    nonisolated(unsafe) private static var lastID = 0
    private let ledgerID: Int = MPVPlayer.ids.withLock {
        MPVPlayer.lastID += 1
        return MPVPlayer.lastID
    }
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
    private var subtitleTasks: [Task<Void, Never>] = []
    #if DEBUG
    private var playlistKeys = ""
    var hlsKeys: String { stateLock.withLock { playlistKeys } }
    private var perf = LivePerf.Opening()
    var livePerf: LivePerf.Opening {
        let (snapshot, attempt) = stateLock.withLock { (perf, loads.current) }
        var opening = snapshot
        let load = FailureLedger.Load(player: ledgerID, attempt: attempt)
        if let loadfile = opening.loadfile, let failure = FFmpegLog.failure(of: load, since: loadfile) { opening.failure = failure }
        return opening
    }
    #endif

    private var mpv: OpaquePointer?
    private let queue = DispatchQueue(label: "openiptv.mpv", qos: .userInitiated)
    private var loadStarted = CFAbsoluteTimeGetCurrent()
    /// The file's audio and subtitles to pick (the player's queue).
    private var trackPlan: TrackPlan?
    /// The server's subtitle files added to this film, their tracks, and
    /// the shift and stretch that put each in time (the player's queue).
    private var addedFiles: Set<String> = []
    /// The film's own subtitle tracks and their copies from the server (by
    /// track id, both ways): a pick of the track shows the copy, which the
    /// menu never lists.
    private var copies: [Int: Int] = [:]
    private var copied: [Int: Int] = [:]
    private var fileTracks: [EmbyPlayback.SubtitleFile.ID: Int] = [:]
    private var fits: [Int: SubtitleSync.Fit] = [:]
    private var pendingFits: [EmbyPlayback.SubtitleFile.ID: SubtitleSync.Fit] = [:]
    /// The subtitle tracks the files are put in time with, as text: the
    /// film's other files (quick) and its own track (the server reads the
    /// whole film for it), asked for once a film, dropped on close.
    private var references: (urls: [URL], files: Task<[SubtitleSync.Reference], Never>, own: Task<[SubtitleSync.Reference], Never>)?
    /// The speech heard in the film: listened for once a film, dropped on
    /// close.
    private var speech: Task<[SubtitleSync.Speech], Never>?
    /// Files to put in time by the speech once they show (the server
    /// converts sixteen stretches of the film's sound for it: not asked
    /// for a film watched without them), by their text; those stretches;
    /// and the references to match against beside them.
    private var bySpeech: [EmbyPlayback.SubtitleFile.ID: String] = [:]
    private var speechStretches: [EmbyPlayback.SpeechStretch] = []
    private var guides: [SubtitleSync.Reference] = []
    /// Each file as listed, and the files shown rewritten part by part
    /// (their track is the rewritten copy from then on).
    private var fileInfo: [EmbyPlayback.SubtitleFile.ID: EmbyPlayback.SubtitleFile] = [:]
    private var rewritten: Set<EmbyPlayback.SubtitleFile.ID> = []
    #if DEBUG
    /// A rewritten file's sections, by its track (UI tests' readout).
    private var sectionNotes: [Int: String] = [:]
    #endif
    private var shownSubtitle: Int?
    private var subtitlesHidden = false
    /// Every subtitle file added to the film (the server's, those found for
    /// it, copies of its own tracks; a rewritten file's copy in its place),
    /// on the device, and its track now: added again when the film is
    /// opened again at another quality, since a new stream has none of
    /// them. Regression: lowered to the server's converted version on a
    /// slow connection, the film went on with no subtitles.
    private var carried: [(key: CarriedKey, local: URL, title: String, language: String)] = []
    private var carriedIds: [CarriedKey: Int] = [:]
    enum CarriedKey: Hashable {
        case file(EmbyPlayback.SubtitleFile.ID)
        /// A copy of the film's own track at this place in the file.
        case copy(Int)
        /// The film's own track at this place (no copy: a picture one).
        case own(Int)
    }
    /// What to show again once the next stream is open: the subtitles
    /// showing, and each file's fit.
    private var carryOver: (shown: CarriedKey?, fits: [CarriedKey: SubtitleSync.Fit])?
    /// Where in the film the stream's clock starts: a converted version
    /// starts at 0 where it was asked from, and the subtitles (in the
    /// film's time) are moved back by as much.
    private var clock: Double = 0
    /// The stream is the film's own file (not a converted version).
    private var playingFile = true
    /// The audio playing before a converted version, whose one track says
    /// no language: said for it.
    private var carriedAudio: (language: String?, title: String?)?
    /// The film's own audio track playing (its place in the file), for
    /// asking the server for a converted version in the same language.
    private var audioIndex: Int?
    var audioStreamIndex: Int? { stateLock.withLock { audioIndex } }
    #if DEBUG
    /// "delay speed" applied to the subtitles showing (UI tests).
    private var shift = "0.00 1.0000"
    var subtitleShift: String { stateLock.withLock { shift } }
    /// The subtitle line on screen (UI tests).
    private var line = ""
    var subtitleLine: String { stateLock.withLock { line } }
    let stopwatch = SubtitleStopwatch()
    private var subtitleSwitchCount = 0
    private var subtitleSwitchRequestedAt: CFAbsoluteTime?
    private var switchedFromHidden = false
    private var startTiming = (loadedAt: CFAbsoluteTime(0), note: "", preroll: "")
    var startLoadedAt: CFAbsoluteTime { stateLock.withLock { startTiming.loadedAt } }
    var startNote: String { stateLock.withLock { startTiming.note } }
    private var bufferingLog = BufferingLog()
    private var convertedAskedAt: CFAbsoluteTime?
    /// The stream's first timestamp: libmpv's clock is 0 there.
    private var streamStart = 0.0
    var streamStartTime: Double { stateLock.withLock { streamStart } }
    private var serverBytesAtSeek: Int64 = 0
    var bufferingReadout: String { stateLock.withLock { bufferingLog.readout } }
    private var awaitingSubtitleLine: (n: Int, since: CFAbsoluteTime)?
    private var stalledSince: CFAbsoluteTime?
    #endif
    /// When the file was open (headers read), for the start-up breakdown.
    private(set) var openedAfter: Double?
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
    private let readableWhileQueueIsBusy = NSLock()
    private var firstPictureShown = false
    /// The first frame is ready (a warmed-up player may already be there).
    var hasStarted: Bool { readableWhileQueueIsBusy.withLock { firstPictureShown } }
    private var lastFileFailed = false
    /// The last file failed to play (a player opened ahead can't be used).
    var hasFailed: Bool { readableWhileQueueIsBusy.withLock { lastFileFailed } }
    private var duration: Double?
    private var buffered: Double = 0
    private var downloadSpeed: Double = 0
    private var lastNetworkReport: CFAbsoluteTime = 0
    private var reportsWindow = false
    #if os(iOS)
    /// Seconds since the film's clock starts in this stream, and whether it's paused (the window's clock).
    private var rawTime: Double = 0
    private var isPaused = false
    private var goingAway: DispatchWorkItem?
    #if DEBUG
    private var gap: SwitchGap?
    private var gapTimer: DispatchSourceTimer?
    #endif
    #endif
    /// Away from the app (another app, the Home Screen, an Apple TV asleep)
    /// with the picture on the GPU: its track, off meanwhile. iOS and tvOS
    /// stop an app's GPU work in the background; the picture kept being
    /// drawn there, failed, and stayed frozen after coming back. The sound
    /// plays on.
    private var awayTrack: String?
    private var appObservers: [NSObjectProtocol] = []
    /// Times the picture went off while away and came back (UI tests).
    private var awayReturns = 0
    var pictureReturnsFromAway: Int { stateLock.withLock { awayReturns } }

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
    init(options: [(String, String)], hardwareDecoding: Bool, picture: Picture) {
        layer.framebufferOnly = true
        layer.backgroundColor = UIColor.black.cgColor
        #if os(iOS)
        frames = picture == .frames ? FilmFrames() : nil
        #if DEBUG
        frames?.onFrame = { [weak self] time in self?.noteFrame(at: time) }
        #endif
        #endif
        let wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
        queue.async { [self] in setUp(wid: wid, options: options, hardwareDecoding: hardwareDecoding) }
        let center = NotificationCenter.default
        appObservers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
                self?.leftApp()
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
                self?.cameBack()
            },
        ]
    }

    /// Away from the app (or an Apple TV asleep): the picture off, the sound on. A film's frames go on into the
    /// floating window, or go by undrawn: iOS may open the window a moment after the app has gone.
    private func leftApp() {
        #if os(iOS)
        if let frames {
            queue.async { [self] in
                goingAway?.cancel()
                let away = DispatchWorkItem { if !frames.isInWindow { frames.setAway(true) } }
                goingAway = away
                queue.asyncAfter(deadline: .now() + 1, execute: away)
            }
            return
        }
        #endif
        queue.async { [self] in
            guard let mpv, awayTrack == nil,
                  let track = mpv_get_property_string(mpv, "vid") else { return }
            let current = String(cString: track)
            mpv_free(track)
            guard current != "no" else { return }
            awayTrack = current
            mpv_set_property_string(mpv, "vid", "no")
        }
    }

    /// Back in the app: the picture on again, through a fresh video output
    /// (even one that failed while away is replaced).
    private func cameBack() {
        queue.async { [self] in
            #if os(iOS)
            if let frames {
                goingAway?.cancel()
                goingAway = nil
                if frames.isAway {
                    frames.setAway(false)
                    stateLock.withLock { awayReturns += 1 }
                }
                return
            }
            #endif
            guard let mpv, let track = awayTrack else { return }
            awayTrack = nil
            mpv_set_property_string(mpv, "vid", track)
            stateLock.withLock { awayReturns += 1 }
        }
    }

    private func setUp(wid: Int64, options: [(String, String)], hardwareDecoding: Bool) {
        #if DEBUG
        let began = CFAbsoluteTimeGetCurrent()
        defer { perfSetUp(since: began) }
        #endif
        guard let mpv = mpv_create() else { return }
        self.mpv = mpv
        #if os(iOS)
        let drawsFrames = frames != nil
        #else
        let drawsFrames = false
        #endif
        if drawsFrames {
            // No GPU output to hand VideoToolbox's frames to: decoded there and copied back (else libmpv
            // decodes on the CPU).
            set("vo", "libmpv")
            set("hwdec", hardwareDecoding ? "videotoolbox-copy" : "no")
            set("sw-fast", "yes")
        } else {
            var wid = wid
            mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &wid)
            set("vo", "gpu-next")
            set("gpu-api", "vulkan")
            set("gpu-context", "moltenvk")
            set("hwdec", hardwareDecoding ? "videotoolbox" : "no")
        }
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
        if HTTP.debugProxy() != nil { setenv("no_proxy", "127.0.0.1", 1) }
        #endif
        mpv_initialize(mpv)
        #if os(iOS)
        frames?.attach(to: mpv)
        #endif
        mpv_request_log_messages(mpv, "warn")
        FFmpegLog.listen()
        mpv_observe_property(mpv, 0, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "demuxer-cache-duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "cache-speed", MPV_FORMAT_INT64)
        mpv_observe_property(mpv, 0, "sid", MPV_FORMAT_STRING)
        mpv_observe_property(mpv, 0, "aid", MPV_FORMAT_STRING)
        #if DEBUG
        // Told when it changes: asking for it waits on a busy player.
        mpv_observe_property(mpv, 0, "sub-text", MPV_FORMAT_STRING)
        #endif
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
    /// downloaded. `converting`: segments the server converts as they're
    /// asked for (Emby's converted versions).
    func load(_ url: URL, headers: [String] = [], start: Double? = nil, file: Bool = false, sequential: Bool = false,
              converting: Bool = false, readahead: Readahead = .live, tracks: TrackPlan? = nil, sameFilm clock: Double? = nil,
              attempt: Int? = nil) {
        // A reload of its own (a converted version's open, a jump in it)
        // keeps the attempt its owner last asked for.
        let attempt = stateLock.withLock {
            askedAttempt = attempt ?? askedAttempt
            return askedAttempt
        }
        // Files go through the in-app relay, which keeps one warm HTTP/2
        // connection to the server instead of a new one per seek.
        var url = url, headers = headers
        #if DEBUG
        // The player's own requests (a converted version's) through the
        // throttling proxy too: https as a tunnel, plain http only to the
        // test server, never to the relay on this device.
        let proxy = HTTP.debugProxy().map { url.scheme?.lowercased() == "https" || HTTP.plainThroughDebugProxy() ? "http://\($0.host):\($0.port)" : "" }
        #endif
        if file, url.scheme?.hasPrefix("http") == true, let local = StreamRelay.shared.localURL(for: url, headers: headers) {
            url = local
            headers = []
        }
        if !file { stateLock.withLock { playedLive = true } }
        #if DEBUG
        if !file, url.path().hasSuffix(".m3u8"), UserDefaults.standard.bool(forKey: "debugHLSCounts") {
            let (master, sent) = (url, headers)
            Task.detached { [weak self] in
                let counts = await PlaylistKeys.count(master, headers: sent)
                self?.stateLock.withLock { self?.playlistKeys = counts }
            }
        }
        #endif
        queue.async { [self] in
            guard let mpv, !stateLock.withLock({ closed }) else { return }
            #if DEBUG
            if let proxy { mpv_set_property_string(mpv, "http-proxy", proxy) }
            #endif
            #if DEBUG
            let asked = CFAbsoluteTimeGetCurrent()
            #endif
            if !file { _ = Self.closing.wait(timeout: .now() + 2) }
            #if DEBUG
            let waited = CFAbsoluteTimeGetCurrent() - asked
            #endif
            apply(readahead, mpv)
            loadStarted = CFAbsoluteTimeGetCurrent()
            #if DEBUG
            awaitingSubtitleLine = (subtitleSwitchCount, loadStarted)
            stateLock.withLock {
                startTiming = (loadStarted, "", startTiming.preroll)
                bufferingLog.opening(converted: !file)
            }
            if file { StreamRelay.shared.beginStartReads() }
            perfLoad(waited: waited)
            #endif
            reportsWindow = !file
            openedAfter = nil
            readableWhileQueueIsBusy.withLock { firstPictureShown = false; lastFileFailed = false }
            duration = nil
            mpv_set_property_string(mpv, "http-header-fields", headers.joined(separator: ","))
            mpv_set_property_string(mpv, "stream-lavf-o", file
                ? "multiple_requests=1,initial_request_size=\(StreamRelay.firstRead),request_size=\(StreamRelay.readSize),short_seek_size=1048576"
                : sequential ? "seekable=0" : "")
            // Emby answers for a segment once it's converted: ffmpeg asking
            // for the next one as it opened one (http_multiple) waited for
            // that before reading the one it had.
            mpv_set_property_string(mpv, "demuxer-lavf-o", converting ? "http_multiple=0" : "")
            mpv_set_property_string(mpv, "start", start.map(FileStart.mpvStart) ?? "none")
            let preroll = TrackChoice.subtitlePreroll(Self.noHiddenSubtitles ? nil : tracks, reopening: clock != nil)
            for option in preroll { mpv_set_property_string(mpv, option.name, option.value) }
            #if DEBUG
            stateLock.withLock { startTiming.preroll = preroll.allSatisfy { $0.value == "0" } ? "none" : "as mpv's" }
            #endif
            // Resume at the nearest keyframe instead of decoding up to the
            // exact second; precise seeking comes back once it's playing.
            mpv_set_property_string(mpv, "hr-seek", start == nil ? "default" : "no")
            Self.apply(tracks, mpv)
            trackPlan = tracks
            if let clock { carry(to: clock, file: file) }
            stateLock.withLock { playingFile = file }
            emit(.opening, attempt: attempt)
            let load = FailureLedger.Load(player: ledgerID, attempt: attempt)
            FFmpegLog.began(load)
            let sent = loadfile(url.absoluteString)
            if !sent.ok { FFmpegLog.ended(load) }
            stateLock.withLock { loads.asked(attempt, entry: sent.entry) }
        }
    }

    #if DEBUG
    /// Timed from here: its playlists may be fetched before `load`.
    func askedForConverted() {
        let now = CFAbsoluteTimeGetCurrent()
        stateLock.withLock { convertedAskedAt = now }
        OpenRequests.begin()
    }
    #endif

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
            var seconds = seconds
            #if DEBUG
            // UI tests (OPENREEL_DEBUG_READAHEAD=seconds): a short read-ahead,
            // so a small test film isn't all downloaded at once (a real
            // film's end, and its index there, aren't).
            if let cap = ProcessInfo.processInfo.environment["OPENREEL_DEBUG_READAHEAD"].flatMap(Int.init) { seconds = min(seconds, cap) }
            #endif
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
        #if os(iOS)
        guard frames == nil else { return }
        #endif
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
        #if os(iOS)
        guard frames == nil else { return }
        #endif
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
            #if DEBUG
            let read = StreamRelay.shared.serverBytes
            stateLock.withLock { serverBytesAtSeek = read }
            #endif
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

    /// The file's audio and subtitle tracks, as they are now.
    func tracks() async -> [Track] {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                guard let mpv else { return continuation.resume(returning: []) }
                continuation.resume(returning: shown(Self.trackList(mpv)))
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

    /// The server's subtitle files for this film, added once fetched (the
    /// player never waits on the network for them); shown at once when the
    /// plan asked for subtitles that only a file has. Each is added once.
    /// Each is then put in time (see SubtitleSync.match), part by part: as
    /// remembered from an earlier play, at once; by the film's other files
    /// as soon as they're in (seconds); by its own track once the server
    /// has it; and, unless its own track settled it, by the speech heard
    /// in `speech` once it shows.
    func addSubtitles(_ files: [EmbyPlayback.SubtitleFile], references: [EmbyPlayback.SubtitleReference] = [],
                      speech stretches: [EmbyPlayback.SpeechStretch] = []) {
        guard !files.isEmpty else { return }
        // Asked for at once, beside the files: the server may take
        // minutes to give the film's own.
        let asked = stateLock.withLock { () -> (files: Task<[SubtitleSync.Reference], Never>, own: Task<[SubtitleSync.Reference], Never>) in
            let urls = references.map(\.subtitle.address)
            if let asked = self.references, asked.urls == urls { return (asked.files, asked.own) }
            let others = references.filter { !$0.own }, own = references.filter(\.own)
            let filesTask = Task.detached(priority: .utility) { await Self.fetchReferences(others) }
            let ownTask = Task.detached(priority: .utility) { await Self.fetchReferences(own) }
            self.references = (urls, filesTask, ownTask)
            return (filesTask, ownTask)
        }
        startSubtitleWork { [weak self] in
            var fetched: [(EmbyPlayback.SubtitleFile, String)] = []
            for file in files {
                guard !Task.isCancelled else { return }
                #if DEBUG
                let asked = CFAbsoluteTimeGetCurrent()
                #endif
                guard let local = await Self.local(file.source) else {
                    #if DEBUG
                    self?.stopwatch.note(.fetchFailed, [.kind: .word(.file), .ms: .seconds(CFAbsoluteTimeGetCurrent() - asked)])
                    #endif
                    continue
                }
                #if DEBUG
                self?.stopwatch.note(.fetched, [.kind: .word(.file), .ms: .seconds(CFAbsoluteTimeGetCurrent() - asked),
                                                .bytes: .number(Self.size(local)), .lang: .language(file.language)])
                #endif
                let text = try? String(contentsOf: local, encoding: .utf8)
                if let text { fetched.append((file, text)) }
                // In time from the first line when it played before.
                let remembered = text.flatMap { SubtitleTiming.remembered(file.url, text: $0) }
                self?.queue.async { [weak self] in
                    self?.add(file, at: local)
                    if let remembered, let text { self?.apply(remembered, to: file.id, text: text, why: "remembered") }
                }
            }
            guard !fetched.isEmpty else { return }
            // By the references: the files first (seconds), then with the
            // film's own too, once the server has it (minutes, at times).
            var settled = Set<EmbyPlayback.SubtitleFile.ID>()
            let quick = await asked.files.value
            for stage in ["files", "own"] {
                let references = stage == "files" ? quick : quick + (await asked.own.value)
                guard !references.isEmpty, stage == "files" || references.contains(where: \.own) else { continue }
                for (file, text) in fetched {
                    guard let match = SubtitleSync.match(text, speech: [], references: references), match.score >= 1 else { continue }
                    SubtitleTiming.remember(match, for: file.url, text: text)
                    self?.queue.async { [weak self] in self?.apply(match, to: file.id, text: text, why: "references (\(stage))") }
                    // The film's own track is in time with it: no need to hear it.
                    if stage == "own", match.isGoodEnough { settled.insert(file.id) }
                }
            }
            let guides = await asked.files.value + asked.own.value
            // The speech heard, once one of the files shows (and then
            // remembered, so a film played again isn't heard again).
            guard !stretches.isEmpty else { return }
            self?.queue.async { [weak self] in
                guard let self else { return }
                speechStretches = stretches
                self.guides = guides
                for (file, text) in fetched where !settled.contains(file.id) && !SubtitleTiming.settles(file.url, text: text) {
                    bySpeech[file.id] = text
                }
                fitBySpeechIfShown()
            }
        }
    }

    /// Subtitle files the server's providers found for the film (see
    /// AppModel.findMissingSubtitles), likeliest first: that one is added
    /// as a server file is, and shows at once. With others, each is matched
    /// against the references and the speech heard once they're in, and
    /// the one that fits the film clearly better takes its place (in time
    /// from its first line); `picked` hears which one fits best, when one
    /// fits well enough. Only one shows in the menu either way: the viewer
    /// never chooses among them.
    func addFound(_ files: [EmbyPlayback.SubtitleFile], references: [EmbyPlayback.SubtitleReference],
                  speech stretches: [EmbyPlayback.SpeechStretch], picked: @escaping @Sendable (URL) -> Void) {
        guard let first = files.first else { return }
        addSubtitles([first], references: references, speech: stretches)
        guard files.count > 1 else { return }
        Task.detached(priority: .utility) { [weak self] in
            let texts = files.compactMap { file -> (file: EmbyPlayback.SubtitleFile, text: String)? in
                guard case let .device(found) = file.source, let text = try? String(contentsOf: found, encoding: .utf8) else { return nil }
                return (file, text)
            }
            guard let asked = self?.stateLock.withLock({ self?.references }) ?? nil else { return }
            let guides = await asked.files.value + asked.own.value
            // After the file showing has started listening: it's put in
            // time at half the stretches heard already.
            try? await Task.sleep(for: .seconds(2))
            let heard = stretches.isEmpty ? [] : await self?.listen(stretches).value ?? []
            let matched = texts.compactMap { file, text in
                SubtitleSync.match(text, speech: heard, references: guides).map { (file: file, text: text, match: $0) }
            }
            #if DEBUG
            NSLog("%@", "PERF subtitles found, matched: " + matched.map { "\($0.file.url.lastPathComponent) " + Self.describe($0.match) }.joined(separator: " | "))
            #endif
            guard let self, let best = matched.max(by: { $0.match < $1.match }) else { return }
            let shown = matched.first { $0.file.id == first.id }?.match
            guard best.file.id != first.id, Self.clearlyBetter(best.match, than: shown) else {
                if let shown, shown.isGoodEnough { picked(first.url) }
                return
            }
            SubtitleTiming.remember(best.match, for: best.file.url, text: best.text)
            picked(best.file.url)
            queue.async { [weak self] in self?.replaceFound(first.id, with: best.file, references: references, speech: stretches) }
        }
    }

    /// Good enough where the other isn't, or a clearly closer fit.
    private static func clearlyBetter(_ a: SubtitleSync.Match, than b: SubtitleSync.Match?) -> Bool {
        guard a.isGoodEnough else { return false }
        guard let b, b.isGoodEnough else { return true }
        return a.score * a.evenness > 1.25 * b.score * b.evenness
    }

    /// On the queue: a found file in another's place: the other's track
    /// taken off, this one added (and shown, if subtitles are wanted).
    private func replaceFound(_ old: EmbyPlayback.SubtitleFile.ID, with file: EmbyPlayback.SubtitleFile, references: [EmbyPlayback.SubtitleReference],
                              speech stretches: [EmbyPlayback.SpeechStretch]) {
        if let id = fileTracks.removeValue(forKey: old) {
            command(["sub-remove", String(id)])
            fits[id] = nil
        }
        bySpeech[old] = nil
        fileInfo[old] = nil
        carried.removeAll { $0.key == .file(old) }
        carriedIds[.file(old)] = nil
        emit(.tracksChanged)
        addSubtitles([file], references: references, speech: stretches)
    }

    /// On the queue: the file showing, if it waits for the speech heard,
    /// put in time by it and the references (the stretches are listened
    /// to once a film).
    private func fitBySpeechIfShown() {
        guard let shown = shownSubtitle, let (file, text) = bySpeech.first(where: { fileTracks[$0.key] == shown }),
              let url = fileInfo[file]?.url else { return }
        bySpeech[file] = nil
        let guides = guides
        // Half the stretches heard (spread across the film): a file off by
        // the same everywhere is put in time by them already; one off by
        // parts waits for all (a part not measured yet would be moved by
        // its neighbour's shift).
        let listening = listen(speechStretches) { [weak self] partial in
            let match = SubtitleSync.match(text, speech: partial, references: guides)
            #if DEBUG
            NSLog("%@", "PERF subsync speech (half) \(partial.count) stretches, \(guides.count) references: " + Self.describe(match))
            #endif
            guard let match, match.score >= 1, match.sections.count == 1, match.evenness >= 0.9 else { return }
            self?.queue.async { [weak self] in self?.apply(match, to: file, text: text, why: "speech (half)") }
        }
        let stretches = speechStretches
        Task.detached(priority: .utility) { [weak self] in
            let heard = await listening.value
            let match = SubtitleSync.match(text, speech: heard, references: guides)
            #if DEBUG
            NSLog("%@", "PERF subsync speech \(heard.count) stretches, \(guides.count) references: " + Self.describe(match))
            #endif
            guard let match, match.score >= 1 else { return }
            SubtitleTiming.remember(match, for: url, text: text)
            self?.queue.async { [weak self] in self?.apply(match, to: file, text: text, why: "speech") }
            // Parts at odds with their section: heard in more places, then
            // matched again (see SubtitleSync.moreSpeech).
            let more = SubtitleSync.moreSpeech(match.unsure ?? [], heard: heard)
            guard let template = stretches.first, !more.isEmpty, self != nil else { return }
            let extra = await SpeechHeard.listen(more.map { template.moved(to: $0) })
            let again = SubtitleSync.match(text, speech: (heard + extra).sorted { $0.start < $1.start }, references: guides)
            #if DEBUG
            NSLog("%@", "PERF subsync more speech at \(more.map { Int($0) }), \(extra.count) heard: " + Self.describe(again))
            #endif
            guard let again, again.score >= 1, again != match else { return }
            SubtitleTiming.remember(again, for: url, text: text)
            self?.queue.async { [weak self] in self?.apply(again, to: file, text: text, why: "more speech") }
        }
    }

    /// On the queue: a file put in time. One section, by shifting it as it
    /// shows; several (a file for another cut), by showing it rewritten
    /// in its place, and from then on always rewritten (a shift on top of
    /// a rewritten copy would move it twice).
    private func apply(_ match: SubtitleSync.Match, to file: EmbyPlayback.SubtitleFile.ID, text: String, why: String) {
        #if DEBUG
        NSLog("%@", "PERF subsync \(why): " + Self.describe(match))
        #endif
        if match.sections.count == 1, !rewritten.contains(file), let section = match.sections.first {
            store(SubtitleSync.Fit(delay: section.delay, speed: section.speed, score: match.score), for: file)
            return
        }
        let local = ServerSubtitles.perPlayFile(text.contains("[Events]") ? "ass" : "srt")
        guard (try? SubtitleSync.retimed(text, by: match).write(to: local, atomically: true, encoding: .utf8)) != nil,
              let mpv, let old = fileTracks[file], let info = fileInfo[file] else { return }
        let showing = shownSubtitle == old
        command(["sub-add", local.path, showing ? "select" : "auto", info.title.isEmpty ? (info.language ?? "") : info.title, info.language ?? ""])
        guard let id = Self.trackList(mpv).filter({ $0.kind == .subtitle && $0.external }).map(\.id).max(), id != old else { return }
        rewritten.insert(file)
        if let n = carried.firstIndex(where: { $0.key == .file(file) }) { carried[n].local = local }
        carriedIds[.file(file)] = id
        fileTracks[file] = id
        fits[old] = nil
        #if DEBUG
        sectionNotes[id] = "sections " + match.sections.map { String(format: "%.0f:%+.2f", $0.from, $0.delay) }.joined(separator: " ")
        #endif
        command(["sub-remove", String(old)])
        if showing { applyFit(for: id) }
        emit(.tracksChanged)
    }

    #if DEBUG
    private static func describe(_ match: SubtitleSync.Match?) -> String {
        guard let match else { return "no match" }
        return String(format: "score %.2f evenness %.2f, ", match.score, match.evenness)
            + match.sections.map { String(format: "from %.0f s %+.2f s ×%.4f", $0.from, $0.delay, $0.speed) }.joined(separator: "; ")
    }
    #endif

    /// The speech in the film's stretches, listened for once (`halfway`:
    /// for the first file it's heard for).
    private func listen(_ stretches: [EmbyPlayback.SpeechStretch],
                        halfway: (@Sendable ([SubtitleSync.Speech]) async -> Void)? = nil) -> Task<[SubtitleSync.Speech], Never> {
        stateLock.withLock {
            if let speech { return speech }
            let task = Task.detached(priority: .utility) { await SpeechHeard.listen(stretches, halfway: halfway) }
            speech = task
            return task
        }
    }

    private func add(_ file: EmbyPlayback.SubtitleFile, at local: URL) {
        guard let mpv, addedFiles.insert(file.id).inserted else { return }
        fileInfo[file.id] = file
        let title = file.title.isEmpty ? (file.language ?? "") : file.title
        #if DEBUG
        let adding = CFAbsoluteTimeGetCurrent()
        #endif
        command(["sub-add", local.path, "auto", title, file.language ?? ""])
        #if DEBUG
        stopwatch.note(.added, [.kind: .word(.file), .ms: .seconds(CFAbsoluteTimeGetCurrent() - adding), .lang: .language(file.language)])
        #endif
        if let id = Self.trackList(mpv).filter({ $0.kind == .subtitle && $0.external }).map(\.id).max() {
            fileTracks[file.id] = id
            carried.append((.file(file.id), local, title, file.language ?? ""))
            carriedIds[.file(file.id)] = id
            if let fit = pendingFits.removeValue(forKey: file.id) { fits[id] = fit }
        }
        // The menu hears of it once it's chosen or not.
        defer { emit(.tracksChanged) }
        guard let plan = trackPlan?.refreshed(), plan.subtitles != nil,
              let now = mpv_get_property_string(mpv, "sid") else { return }
        let off = String(cString: now) == "no" || subtitlesHidden
        mpv_free(now)
        if off, let id = TrackChoice.choose(shown(Self.trackList(mpv)), plan: plan).subtitle {
            mpv_set_property_string(mpv, "sid", String(copies[id] ?? id))
            hideSubtitles(false)
        }
    }

    /// A file's fit: kept for its track, applied now if it's showing.
    private func store(_ fit: SubtitleSync.Fit, for file: EmbyPlayback.SubtitleFile.ID) {
        guard let id = fileTracks[file] else { return pendingFits[file] = fit }
        fits[id] = fit
        if shownSubtitle == id { applyFit(for: id) }
    }

    /// On the queue, before the same film opens again (another quality):
    /// what shows now, to show again, and each file's fit; the old
    /// stream's track numbers mean nothing in the new one.
    private func carry(to clock: Double, file: Bool) {
        guard let mpv else { return }
        let list = Self.trackList(mpv)
        var shown: CarriedKey?
        if let id = shownSubtitle {
            shown = carriedIds.first { $0.value == id }?.key
                ?? copied[id].flatMap { original in list.first { $0.id == original }?.ffIndex }.map { .copy($0) }
                ?? list.first { $0.id == id && !$0.external }?.ffIndex.map { .own($0) }
        }
        var carriedFits: [CarriedKey: SubtitleSync.Fit] = [:]
        for (file, id) in fileTracks { if let fit = fits[id] { carriedFits[.file(file)] = fit } }
        carryOver = (shown, carriedFits)
        #if DEBUG
        NSLog("%@", "PERF subtitles carry: showing \(shownSubtitle.map(String.init) ?? "none") as \(shown.map { "\($0)" } ?? "none"), ids \(carriedIds.values.sorted())")
        #endif
        // A converted version's one audio track says no language: the one
        // playing now.
        if !file, let audio = list.first(where: { $0.kind == .audio && $0.selected }) {
            carriedAudio = carriedAudio ?? (audio.language, audio.title)
        } else if file {
            carriedAudio = nil
        }
        fileTracks = [:]
        fits = [:]
        copies = [:]
        copied = [:]
        carriedIds = [:]
        #if DEBUG
        sectionNotes = [:]
        #endif
        self.clock = clock
    }

    /// On the queue, once the film is open again: its subtitle files added
    /// back (each in its fit) and the ones showing before shown again.
    private func restoreCarried() {
        guard let carry = carryOver, let mpv else { return }
        carryOver = nil
        let own = Self.trackList(mpv).filter { $0.kind == .subtitle && !$0.external }
        for entry in carried {
            // Subtitle numbers only: audio tracks are numbered apart.
            let known = Set(Self.trackList(mpv).filter { $0.kind == .subtitle }.map(\.id))
            command(["sub-add", entry.local.path, "auto", entry.title, entry.language])
            guard let id = Self.trackList(mpv).filter({ $0.kind == .subtitle && $0.external && !known.contains($0.id) }).map(\.id).max() else {
                #if DEBUG
                NSLog("%@", "PERF subtitles carry: \(entry.local.lastPathComponent) not added (there: \(FileManager.default.fileExists(atPath: entry.local.path)))")
                #endif
                continue
            }
            carriedIds[entry.key] = id
            switch entry.key {
            case let .file(file):
                fileTracks[file] = id
                if let fit = carry.fits[entry.key] { fits[id] = fit }
            case let .copy(index):
                if let original = own.first(where: { $0.ffIndex == index }) {
                    copies[original.id] = id
                    copied[id] = original.id
                }
            case .own:
                break
            }
        }
        let sid: Int? = switch carry.shown {
        case let .own(index)?: own.first { $0.ffIndex == index }?.id
        case let shown?: carriedIds[shown]
        case nil: nil
        }
        #if DEBUG
        NSLog("%@", "PERF subtitles carried \(carried.count) to the new stream (clock \(clock)), showing \(sid.map(String.init) ?? "none")")
        #endif
        mpv_set_property_string(mpv, "sid", sid.map(String.init) ?? "no")
        // The same track as before: its fit for the new clock.
        if sid == shownSubtitle { applyFit(for: sid) }
        emit(.tracksChanged)
    }

    /// The shift and stretch for the subtitles showing (none for the
    /// film's own tracks, always in time).
    private func applyFit(for id: Int?) {
        guard let mpv else { return }
        let fit = id.flatMap { fits[$0] }
        #if DEBUG
        NSLog("%@", "PERF subsync showing \(id.map(String.init) ?? "none") fit \(fit.map { "\($0.delay) \($0.speed)" } ?? "none") known \(fits.keys.sorted())")
        #endif
        // Typed first: in String(format:) a bare `?? 1` is an integer when
        // there's no fit, which "%f" reads as 0 (a speed of 0 broke the
        // film's own subtitles after a file's).
        let delay: Double = fit?.delay ?? 0
        let speed: Double = fit?.speed ?? 1
        mpv_set_property_string(mpv, "sub-delay", String(format: "%.3f", delay - clock))
        mpv_set_property_string(mpv, "sub-speed", String(format: "%.6f", speed))
        #if DEBUG
        let note = id.flatMap { sectionNotes[$0] }
        stateLock.withLock { shift = fit == nil ? note ?? String(format: "%.2f %.4f", delay, speed) : String(format: "%.2f %.4f", delay, speed) }
        #endif
        fitBySpeechIfShown()
    }

    private static func fetchReferences(_ references: [EmbyPlayback.SubtitleReference]) async -> [SubtitleSync.Reference] {
        await withTaskGroup(of: (Int, SubtitleSync.Reference?).self) { group in
            for (i, reference) in references.enumerated() {
                group.addTask {
                    guard let local = await ServerSubtitles.local(reference.subtitle),
                          let text = try? String(contentsOf: local, encoding: .utf8) else { return (i, nil) }
                    return (i, SubtitleSync.Reference(cues: SubtitleSync.cues(text), own: reference.own))
                }
            }
            var found: [(Int, SubtitleSync.Reference)] = []
            for await (i, reference) in group { if let reference { found.append((i, reference)) } }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private static func local(_ source: EmbyPlayback.SubtitleSource) async -> URL? {
        switch source {
        case let .server(subtitle):
            return await ServerSubtitles.local(subtitle)
        case let .device(file):
            let local = ServerSubtitles.perPlayFile(file.pathExtension.isEmpty ? "srt" : file.pathExtension)
            return (try? FileManager.default.copyItem(at: file, to: local)) != nil ? local : nil
        }
    }

    private func startSubtitleWork(_ work: @escaping @Sendable () async -> Void) {
        stateLock.withLock {
            guard !closed else { return }
            subtitleTasks.append(Task.detached(priority: .utility, operation: work))
        }
    }

    /// Fills the screen with the picture (cropping its edges) or fits it.
    func setFill(_ fill: Bool) {
        #if os(iOS)
        if let frames { return apply(frames.fill(fill)) }
        #endif
        queue.async { [self] in
            guard let mpv else { return }
            mpv_set_property_string(mpv, "panscan", fill ? "1.0" : "0.0")
        }
    }

    #if os(iOS)
    /// The film's picture on the player screen (its size in pixels; nil: off it).
    func showFrames(onScreen pixels: PixelSize?) {
        if let frames { apply(frames.show(onScreen: pixels)) }
    }

    /// The film's picture in the floating window (its size in pixels; nil: not there).
    func showFrames(inWindow pixels: PixelSize?) {
        if let frames { apply(frames.show(inWindow: pixels)) }
    }

    private func apply(_ plan: FramePlan) {
        queue.async { [self] in
            guard let mpv else { return }
            mpv_set_property_string(mpv, "panscan", plan.fills ? "1.0" : "0.0")
        }
    }

    private func noteFilmSize() {
        guard let frames, let mpv else { return }
        var width: Int64 = 0, height: Int64 = 0
        mpv_get_property(mpv, "video-params/dw", MPV_FORMAT_INT64, &width)
        mpv_get_property(mpv, "video-params/dh", MPV_FORMAT_INT64, &height)
        guard width > 0, height > 0 else { return }
        let gamma = mpv_get_property_string(mpv, "video-params/gamma").map { raw -> String in
            defer { mpv_free(raw) }
            return String(cString: raw)
        }
        apply(frames.video(PixelSize(width: Int(width), height: Int(height)), color: FrameColor(gamma: gamma)))
    }
    #endif

    /// Plays this audio track.
    func selectAudio(_ id: Int) {
        queue.async { [self] in
            guard let mpv else { return }
            #if DEBUG
            stateLock.withLock { bufferingLog.audioAsked(at: CFAbsoluteTimeGetCurrent()) }
            #endif
            mpv_set_property_string(mpv, "aid", String(id))
        }
    }

    /// Shows this subtitle track (nil: none): from its copy when the
    /// server's is here.
    func selectSubtitle(_ id: Int?) {
        #if DEBUG
        let asked = CFAbsoluteTimeGetCurrent()
        #endif
        queue.async { [self] in
            guard let mpv else { return }
            let shown = id.map { $0 == shownSubtitle ? $0 : copies[$0] ?? $0 }
            let sameTrack = shown == nil || shown == shownSubtitle
            #if DEBUG
            if !sameTrack || (shown == nil) != subtitlesHidden {
                subtitleSwitchRequestedAt = asked
                switchedFromHidden = subtitlesHidden
            }
            if sameTrack, (shown == nil) != subtitlesHidden { noteSwitch(to: shown, hidden: true) }
            #endif
            if let shown, !sameTrack { mpv_set_property_string(mpv, "sid", String(shown)) }
            hideSubtitles(shown == nil, sameTrack: sameTrack)
        }
    }

    private func hideSubtitles(_ hidden: Bool, sameTrack: Bool = true) {
        guard let mpv, hidden != subtitlesHidden else { return }
        subtitlesHidden = hidden
        mpv_set_property_string(mpv, "sub-visibility", hidden ? "no" : "yes")
        #if DEBUG
        if hidden { awaitingSubtitleLine = nil }
        let text = hidden || !sameTrack ? nil : mpv_get_property_string(mpv, "sub-text")
        let line = text.map { String(cString: $0) } ?? ""
        if let text { mpv_free(text) }
        stateLock.withLock { self.line = line }
        if !line.isEmpty { noteFirstLine() }
        #endif
        emit(.tracksChanged)
    }

    /// The tracks as the menu lists them: the copies left out, a track
    /// marked chosen while its copy shows.
    private func shown(_ list: [Track]) -> [Track] {
        var list = list
        if let carriedAudio, !stateLock.withLock({ playingFile }) {
            list = list.map { track in
                guard track.kind == .audio, track.language == nil || track.language == "und" else { return track }
                var said = Track(id: track.id, kind: .audio, title: track.title ?? carriedAudio.title, language: carriedAudio.language,
                                 channels: track.channels, forced: track.forced, selected: track.selected)
                said.codec = track.codec
                said.ffIndex = track.ffIndex
                return said
            }
        }
        // Subtitles only: audio tracks are numbered apart (audio 2 and
        // subtitles 2 are different tracks).
        let subtitles = list.filter { $0.kind == .subtitle }
        let showingCopy = Set(subtitles.filter { $0.selected }.compactMap { copied[$0.id] })
        return list.compactMap { track in
            guard track.kind == .subtitle else { return track }
            if copied[track.id] != nil { return nil }
            var track = track
            if subtitlesHidden { track.selected = false } else if showingCopy.contains(track.id) { track.selected = true }
            return track
        }
    }

    /// Fetches the server's copies of the film's own subtitle tracks and
    /// adds them, unshown (see `subtitleCopies`). Each once.
    func addCopies(_ wanted: [EmbyPlayback.SubtitleCopy]) {
        guard !wanted.isEmpty else { return }
        startSubtitleWork { [weak self] in
            for copy in wanted {
                guard !Task.isCancelled else { return }
                #if DEBUG
                let asked = CFAbsoluteTimeGetCurrent()
                #endif
                guard let local = await ServerSubtitles.local(copy.subtitle) else {
                    #if DEBUG
                    self?.stopwatch.note(.fetchFailed, [.kind: .word(.copy), .track: .number(copy.streamIndex),
                                                        .ms: .seconds(CFAbsoluteTimeGetCurrent() - asked)])
                    #endif
                    continue
                }
                #if DEBUG
                self?.stopwatch.note(.fetched, [.kind: .word(.copy), .track: .number(copy.streamIndex),
                                                .ms: .seconds(CFAbsoluteTimeGetCurrent() - asked), .bytes: .number(Self.size(local))])
                #endif
                self?.queue.async { [weak self] in self?.addCopy(copy, at: local, tries: 10) }
            }
        }
    }

    private func addCopy(_ copy: EmbyPlayback.SubtitleCopy, at local: URL, tries: Int) {
        guard let mpv, !addedFiles.contains(copy.subtitle.id) else { return }
        let list = Self.trackList(mpv)
        guard let original = list.first(where: { $0.kind == .subtitle && !$0.external && $0.ffIndex == copy.streamIndex }) else {
            // The file isn't open yet (a player opened ahead): again shortly.
            if tries > 0 { queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.addCopy(copy, at: local, tries: tries - 1) } }
            return
        }
        addedFiles.insert(copy.subtitle.id)
        #if DEBUG
        let adding = CFAbsoluteTimeGetCurrent()
        #endif
        command(["sub-add", local.path, "auto", original.title ?? "", original.language ?? ""])
        #if DEBUG
        stopwatch.note(.added, [.kind: .word(.copy), .track: .number(copy.streamIndex), .ms: .seconds(CFAbsoluteTimeGetCurrent() - adding),
                                .lang: .language(original.language)])
        #endif
        // Subtitle numbers only: audio tracks are numbered apart.
        let known = Set(list.filter { $0.kind == .subtitle }.map(\.id))
        guard let id = Self.trackList(mpv).filter({ $0.kind == .subtitle && $0.external && !known.contains($0.id) }).map(\.id).max() else { return }
        copies[original.id] = id
        copied[id] = original.id
        carried.append((.copy(copy.streamIndex), local, original.title ?? "", original.language ?? ""))
        carriedIds[.copy(copy.streamIndex)] = id
        #if DEBUG
        NSLog("%@", "PERF subtitles copy of track \(original.id) (\(original.language ?? "?")) is track \(id)")
        #endif
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
                         hearingImpaired: flag("hearing-impaired"), codec: text("codec"), image: flag("image"),
                         external: flag("external"), isDefault: flag("default"), ffIndex: number("ff-index"))
        }
    }

    /// Closes the stream and its connection; the player stays for the next
    /// `load`. libmpv lets the connection go after `stop` returns, so
    /// `closed` runs a second later.
    func stop(closed: @escaping @MainActor @Sendable () -> Void) {
        queue.async { [self] in
            command(["stop"])
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                closed()
            }
        }
    }

    /// Stops playback and frees libmpv; the network connection closes with
    /// it. Returns at once: closing a connection mid-download can take a
    /// moment, and the screen mustn't wait for it.
    func shutdown() {
        onEvent = nil
        appObservers.forEach(NotificationCenter.default.removeObserver)
        appObservers = []
        let live = stateLock.withLock { () -> Bool in
            closed = true
            references?.files.cancel()
            references?.own.cancel()
            speech?.cancel()
            subtitleTasks.forEach { $0.cancel() }
            return playedLive
        }
        if live { Self.closing.enter() }
        queue.async { [self] in
            defer { if live { Self.closing.leave() } }
            guard let mpv else { return }
            #if os(iOS)
            #if DEBUG
            gapTimer?.cancel()
            gapTimer = nil
            #endif
            goingAway?.cancel()
            // libmpv's renderer goes before libmpv does.
            if let frames {
                mpv_set_property_string(mpv, "vo", "null")
                frames.close()
            }
            #endif
            mpv_set_wakeup_callback(mpv, nil, nil)
            mpv_terminate_destroy(mpv)
            self.mpv = nil
            FFmpegLog.closed(player: ledgerID)
            FFmpegLog.listen()
        }
    }

    private func set(_ name: String, _ value: String) {
        guard let mpv else { return }
        mpv_set_option_string(mpv, name, value)
    }

    private func loadfile(_ url: String) -> (ok: Bool, entry: Int64?) {
        guard let mpv else { return (false, nil) }
        let words = ["loadfile", url, "replace"]
        var args: [UnsafePointer<CChar>?] = words.map { UnsafePointer(strdup($0)) } + [nil]
        defer { for pointer in args { free(UnsafeMutablePointer(mutating: pointer)) } }
        var result = mpv_node()
        guard mpv_command_ret(mpv, &args, &result) >= 0 else { return (false, nil) }
        defer { mpv_free_node_contents(&result) }
        guard result.format == MPV_FORMAT_NODE_MAP, let map = result.u.list?.pointee else { return (true, nil) }
        for i in 0..<Int(map.num) where map.keys[i].map({ String(cString: $0) }) == "playlist_entry_id"
            && map.values[i].format == MPV_FORMAT_INT64 {
            return (true, map.values[i].u.int64)
        }
        return (true, nil)
    }

    private func command(_ args: [String]) {
        guard let mpv else { return }
        var cargs: [UnsafePointer<CChar>?] = args.map { UnsafePointer(strdup($0)) } + [nil]
        mpv_command(mpv, &cargs)
        for pointer in cargs { free(UnsafeMutablePointer(mutating: pointer)) }
    }

    private func drainEvents() {
        queue.async { [self] in
            stateLock.withLock { loads.drainBegan() }
            while let mpv, let event = mpv_wait_event(mpv, 0), event.pointee.event_id != MPV_EVENT_NONE {
                handle(event.pointee)
            }
        }
    }

    private func handle(_ event: mpv_event) {
        #if DEBUG && os(iOS)
        if event.event_id == MPV_EVENT_SEEK { gap?.seeked() }
        if event.event_id == MPV_EVENT_PLAYBACK_RESTART { gap?.restarted() }
        #endif
        #if os(iOS)
        if event.event_id == MPV_EVENT_VIDEO_RECONFIG { noteFilmSize() }
        #endif
        switch event.event_id {
        case MPV_EVENT_HOOK:
            guard let data = event.data, let mpv else { return }
            let hook = data.assumingMemoryBound(to: mpv_event_hook.self).pointee
            // The plan's exact tracks (language and kind, with the viewer's
            // newest picks) before anything is decoded: nothing switches
            // once it plays (a switch just after the start could stall it).
            if String(cString: hook.name) == "on_preloaded", let plan = trackPlan?.refreshed() {
                let list = Self.trackList(mpv)
                let choice = TrackChoice.choose(list, plan: plan)
                if let audio = choice.audio { mpv_set_property_string(mpv, "aid", String(audio)) }
                // None to show: the ones most likely turned on, read along
                // out of sight. Turned on from the film's own track, they
                // made the player read back into the film for the line on
                // screen (7 s on a big film). Another quality keeps its own.
                let hidden = choice.subtitle == nil && carryOver == nil && !Self.noHiddenSubtitles
                    ? TrackChoice.likelySubtitle(list.filter { $0.kind == .subtitle && !$0.external }, plan: plan) : nil
                mpv_set_property_string(mpv, "sid", (choice.subtitle ?? hidden).map(String.init) ?? "no")
                if carryOver == nil { hideSubtitles(hidden != nil) }
            }
            mpv_hook_continue(mpv, hook.id)
        case MPV_EVENT_START_FILE:
            guard let data = event.data else { return }
            let entry = data.assumingMemoryBound(to: mpv_event_start_file.self).pointee.playlist_entry_id
            if let attempt = stateLock.withLock({ loads.started(entry: entry) }) {
                FFmpegLog.started(FailureLedger.Load(player: ledgerID, attempt: attempt))
            }
        case MPV_EVENT_FILE_LOADED:
            openedAfter = CFAbsoluteTimeGetCurrent() - loadStarted
            emit(.opened)
            #if DEBUG
            stateLock.withLock { perf.opened = Int(((openedAfter ?? 0) * 1000).rounded()) }
            #endif
            restoreCarried()
            #if DEBUG
            noteTracks()
            var start = 0.0
            if let mpv, mpv_get_property(mpv, "demuxer-start-time", MPV_FORMAT_DOUBLE, &start) < 0 { start = 0 }
            stateLock.withLock { streamStart = start }
            #endif
        case MPV_EVENT_PLAYBACK_RESTART:
            if let attempt = stateLock.withLock({ loads.restarted() }) {
                #if DEBUG
                stopwatch.note(.firstFrame)
                let opened = openedAfter ?? 0, shown = CFAbsoluteTimeGetCurrent() - loadStarted
                let subtitles = shownSubtitle == nil ? "off" : subtitlesHidden ? "hidden" : "shown"
                let preroll = stateLock.withLock { startTiming.preroll }
                let note = String(format: "open %.2f s, first frame %.2f s after, subtitles %@, read before the start %@ | relay %@", opened,
                                  shown - opened, subtitles, preroll, StreamRelay.shared.startReadsReadout)
                stateLock.withLock {
                    startTiming.note = note
                    if let asked = convertedAskedAt {
                        convertedAskedAt = nil
                        bufferingLog.firstFrame(after: CFAbsoluteTimeGetCurrent() - asked, waits: OpenRequests.finish())
                    } else {
                        bufferingLog.firstFrame(after: shown)
                    }
                }
                #endif
                readableWhileQueueIsBusy.withLock { firstPictureShown = true }
                seekStarted = nil
                if let mpv { mpv_set_property_string(mpv, "hr-seek", "default") }
                emit(.started(CFAbsoluteTimeGetCurrent() - loadStarted), attempt: attempt)
                return
            }
            if followStarted != nil {
                followStarted = nil
                followShown = followTarget
                followShownExact = followTargetExact
                if let shown = followTarget { emit(.previewShown(shown)) }
                if let next = followNext { startFollowing(next.seconds, exact: next.exact) }
            }
            if let asked = seekStarted {
                seekStarted = nil
                #if DEBUG
                let read = Double(StreamRelay.shared.serverBytes - stateLock.withLock { serverBytesAtSeek }) / 1e6
                stateLock.withLock { bufferingLog.seeked(after: CFAbsoluteTimeGetCurrent() - asked, megabytes: read) }
                #endif
                emit(.seeked(CFAbsoluteTimeGetCurrent() - asked))
            }
        #if DEBUG
        case MPV_EVENT_AUDIO_RECONFIG:
            stateLock.withLock { bufferingLog.audioReconfigured(at: CFAbsoluteTimeGetCurrent()) }
        #endif
        case MPV_EVENT_END_FILE:
            guard let data = event.data else { return }
            let end = data.assumingMemoryBound(to: mpv_event_end_file.self).pointee
            let since = loadStarted
            let attempt = stateLock.withLock { loads.ended(entry: end.playlist_entry_id) }
            FFmpegLog.ended(FailureLedger.Load(player: ledgerID, attempt: attempt))
            // libmpv hands over the warnings that led to an end after the end
            // itself: the class is read once they're in.
            if end.reason == MPV_END_FILE_REASON_ERROR {
                readableWhileQueueIsBusy.withLock { lastFileFailed = true }
                let message = String(cString: mpv_error_string(end.error))
                queue.async { [self] in emit(.failed(message, failure(attempt: attempt, since: since)), attempt: attempt) }
            } else if end.reason == MPV_END_FILE_REASON_EOF {
                queue.async { [self] in emit(.ended(failure(attempt: attempt, since: since)), attempt: attempt) }
            }
        case MPV_EVENT_LOG_MESSAGE:
            guard let data = event.data else { return }
            let message = data.assumingMemoryBound(to: mpv_event_log_message.self).pointee
            let failure = StreamFailure(logged: String(cString: message.text))
            let now = CFAbsoluteTimeGetCurrent()
            stateLock.withLock {
                if let failure, let attempt = loads.logAttempt { logged = (failure, now, attempt) }
                #if DEBUG
                perf.warnings += 1
                if let failure { perf.failure = failure }
                #endif
            }
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let data = event.data else { return }
            let property = data.assumingMemoryBound(to: mpv_event_property.self).pointee
            guard let value = property.data else { return }
            switch String(cString: property.name) {
            case "paused-for-cache" where property.format == MPV_FORMAT_FLAG:
                let stalled = value.assumingMemoryBound(to: Int32.self).pointee != 0
                emit(.buffering(stalled))
                #if DEBUG
                noteStall(stalled)
                stateLock.withLock { bufferingLog.stalled(stalled, at: CFAbsoluteTimeGetCurrent()) }
                #endif
            case "pause" where property.format == MPV_FORMAT_FLAG:
                let paused = value.assumingMemoryBound(to: Int32.self).pointee != 0
                #if os(iOS)
                isPaused = paused
                frames?.follow(rawTime + clock, playing: !paused)
                #endif
                emit(.paused(paused))
            case "duration" where property.format == MPV_FORMAT_DOUBLE:
                duration = value.assumingMemoryBound(to: Double.self).pointee
            case "time-pos" where property.format == MPV_FORMAT_DOUBLE:
                // Four times a second, and at once after a jump.
                let position = value.assumingMemoryBound(to: Double.self).pointee
                #if os(iOS)
                rawTime = position
                frames?.follow(position + clock, playing: !isPaused)
                #endif
                let now = CFAbsoluteTimeGetCurrent()
                guard now - lastTimeEmit >= 0.25 || abs(position - lastTimePosition) > 1.5 else { break }
                lastTimeEmit = now
                lastTimePosition = position
                emit(.time(position: position, duration: duration))
            case "demuxer-cache-duration" where property.format == MPV_FORMAT_DOUBLE:
                buffered = value.assumingMemoryBound(to: Double.self).pointee
                #if DEBUG
                stateLock.withLock { bufferingLog.cacheSeconds = buffered }
                #endif
                reportNetwork()
            case "cache-speed" where property.format == MPV_FORMAT_INT64:
                downloadSpeed = Double(value.assumingMemoryBound(to: Int64.self).pointee)
                #if DEBUG
                stateLock.withLock { bufferingLog.bytesPerSecond = downloadSpeed }
                #endif
                reportNetwork()
            #if DEBUG
            case "sub-text" where property.format == MPV_FORMAT_STRING:
                let text = value.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee.map { String(cString: $0) } ?? ""
                let shown = subtitlesHidden ? "" : text
                stateLock.withLock { line = shown }
                if !shown.isEmpty { noteFirstLine() }
            case "frame-drop-count" where property.format == MPV_FORMAT_INT64:
                let drops = Int(value.assumingMemoryBound(to: Int64.self).pointee)
                stateLock.withLock { perf.drops = drops }
            #endif
            case "aid" where property.format == MPV_FORMAT_STRING:
                // The film's own audio track (not a converted version's).
                let id = value.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee.flatMap { Int(String(cString: $0)) }
                if let mpv, stateLock.withLock({ playingFile }), let id,
                   let index = Self.trackList(mpv).first(where: { $0.kind == .audio && $0.id == id })?.ffIndex {
                    stateLock.withLock { audioIndex = index }
                }
            case "sid" where property.format == MPV_FORMAT_STRING:
                // Other subtitles showing: their shift (a file's), or none.
                let id = value.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee.flatMap { Int(String(cString: $0)) }
                if id != shownSubtitle {
                    #if DEBUG
                    noteSwitch(to: id, hidden: false)
                    #endif
                    shownSubtitle = id
                    applyFit(for: id)
                }
            default:
                break
            }
        default:
            break
        }
    }

    private func failure(attempt: Int, since time: CFAbsoluteTime) -> StreamFailure? {
        FFmpegLog.failure(of: FailureLedger.Load(player: ledgerID, attempt: attempt), since: time)
            ?? stateLock.withLock { logged.flatMap { $0.attempt == attempt && $0.at >= time ? $0.failure : nil } }
    }

    #if DEBUG
    private static var noHiddenSubtitles: Bool { UserDefaults.standard.bool(forKey: "noHiddenSubtitles") }
    #else
    private static let noHiddenSubtitles = false
    #endif

    #if DEBUG
    private func noteTracks() {
        guard let mpv else { return }
        let subtitles = Self.trackList(mpv).filter { $0.kind == .subtitle }
        let own = subtitles.filter { !$0.external }
        stopwatch.note(.loaded)
        stopwatch.note(.tracks, [.text: .number(own.filter { !$0.image }.count), .picture: .number(own.filter(\.image).count),
                                 .external: .number(subtitles.filter { $0.external && copied[$0.id] == nil }.count),
                                 .copies: .number(copied.count), .lang: .language(subtitles.first(where: \.selected)?.language)])
    }

    private func noteSwitch(to id: Int?, hidden: Bool) {
        let asked = subtitleSwitchRequestedAt, fromHidden = switchedFromHidden || hidden && id != nil
        subtitleSwitchRequestedAt = nil
        switchedFromHidden = false
        guard hasStarted, let mpv else { return }
        let list = Self.trackList(mpv).filter { $0.kind == .subtitle }
        func kind(_ id: Int?) -> (word: SubtitleStopwatch.Word, language: String?) {
            guard let id else { return (.off, nil) }
            let track = list.first { $0.id == id }
            if copied[id] != nil { return (.copy, track?.language) }
            guard let track else { return (.none, nil) }
            return (track.external ? .file : track.image ? .picture : .own, track.language)
        }
        subtitleSwitchCount += 1
        awaitingSubtitleLine = id == nil ? nil : (subtitleSwitchCount, asked ?? CFAbsoluteTimeGetCurrent())
        let from = kind(fromHidden ? nil : shownSubtitle), to = kind(id)
        stopwatch.note(.switched, [.n: .number(subtitleSwitchCount), .from: .word(from.word), .to: .word(to.word), .lang: .language(to.language),
                                   .hidden: .word(hidden ? .yes : .no)])
    }

    private func noteFirstLine() {
        guard let mpv, let awaiting = awaitingSubtitleLine else { return }
        awaitingSubtitleLine = nil
        var start = 0.0, position = 0.0
        let secondsIntoSubtitle: SubtitleStopwatch.Value = mpv_get_property(mpv, "sub-start", MPV_FORMAT_DOUBLE, &start) >= 0
            && mpv_get_property(mpv, "time-pos", MPV_FORMAT_DOUBLE, &position) >= 0 ? .seconds(position - start) : .word(.none)
        stopwatch.note(.shown, [.n: .number(awaiting.n), .after: .seconds(CFAbsoluteTimeGetCurrent() - awaiting.since), .late: secondsIntoSubtitle])
    }

    private func noteStall(_ stalled: Bool) {
        guard hasStarted else { return }
        if stalled { return stalledSince = CFAbsoluteTimeGetCurrent() }
        guard let since = stalledSince else { return }
        stalledSince = nil
        stopwatch.note(.rebuffer, [.n: .number(subtitleSwitchCount), .ms: .seconds(CFAbsoluteTimeGetCurrent() - since)])
    }

    private static func size(_ file: URL) -> Int {
        (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private func perfSetUp(since began: CFAbsoluteTime) {
        guard let mpv else { return }
        mpv_observe_property(mpv, 0, "frame-drop-count", MPV_FORMAT_INT64)
        stateLock.withLock { perf.setup = Int(((CFAbsoluteTimeGetCurrent() - began) * 1000).rounded()) }
    }

    private func perfLoad(waited: Double) {
        stateLock.withLock {
            perf = LivePerf.Opening(setup: perf.setup, closeWait: Int((waited * 1000).rounded()), loadfile: loadStarted)
        }
    }

    func withLivePerf(_ use: @escaping @MainActor (LivePerf.Opening) -> Void) {
        queue.async { [self] in
            let opening = livePerf
            Task { @MainActor in use(opening) }
        }
    }

    func sayLiveConfig() {
        queue.async { [self] in if let mpv { LivePerf.sayConfig(mpv) } }
    }

    func sayLiveCodec() {
        queue.async { [self] in if let mpv { LivePerf.sayCodec(mpv) } }
    }
    #endif

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

    private func emit(_ event: Event, attempt: Int? = nil) {
        let attempt = attempt ?? stateLock.withLock { loads.current }
        let handler = onEvent
        if handler == nil {
            if case .tracksChanged = event { stateLock.withLock { tracksUnheard = true } }
            if case let .failed(message, failure) = event { stateLock.withLock { failureUnheard = (message, failure, attempt) } }
        }
        Task { @MainActor in handler?(event, attempt) }
    }
}

#if os(iOS) && DEBUG
extension MPVPlayer {
    /// Measures the next four seconds (see SwitchGap), into "debug-pip-gap".
    func measureGap(_ kind: SwitchGap.Kind) {
        queue.async { [self] in
            gapTimer?.cancel()
            let began = CFAbsoluteTimeGetCurrent()
            gap = SwitchGap(kind, at: began)
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(10))
            timer.setEventHandler { [self] in
                guard let mpv else { return }
                func read(_ name: String) -> Double? {
                    var value = 0.0
                    return mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &value) >= 0 ? value : nil
                }
                let now = CFAbsoluteTimeGetCurrent()
                var paused: Int32 = 0
                mpv_get_property(mpv, "pause", MPV_FORMAT_FLAG, &paused)
                gap?.sample(at: now, time: read("time-pos"), audio: read("audio-pts"), paused: paused != 0)
                guard now - began >= 4, let text = gap?.readout(until: now) else { return }
                gapTimer?.cancel()
                gapTimer = nil
                gap = nil
                NSLog("%@", "PERF pip gap \(text)")
                Task { @MainActor in PictureInPictureProbe.shared.gaps[kind] = text }
            }
            gapTimer = timer
            timer.resume()
        }
    }

    fileprivate func noteFrame(at time: Double) {
        queue.async { [self] in gap?.frame(at: time) }
    }
}
#endif

/// Hosts the player's picture and keeps it sized to the view: a film's frames (iPhone, iPad), drawn at the
/// view's size; or the Metal layer, with its drawable size so rotation re-creates mpv's swapchain at full size.
/// The newest host takes the picture's layer.
final class MPVHostView: UIView {
    private let picture: CALayer
    private weak var player: MPVPlayer?
    private var lastSize: CGSize = .zero
    private var settle: DispatchWorkItem?

    init(player: MPVPlayer) {
        picture = player.pictureLayer
        self.player = player
        super.init(frame: .zero)
        backgroundColor = .black
        layer.addSublayer(picture)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        setNeedsLayout()
        #if os(iOS)
        guard let player, player.frames != nil, picture.superlayer === layer else { return }
        if window == nil {
            player.showFrames(onScreen: nil)
            lastSize = .zero
        } else {
            PictureInPicture.shared.hosted(player)
        }
        #endif
    }

    /// The picture always covers the whole window, whatever SwiftUI makes
    /// of this view: showing the controls (and with them the status bar)
    /// used to change its height by 30 points, animated, and the picture
    /// zoomed and lost its top and bottom.
    override func layoutSubviews() {
        super.layoutSubviews()
        guard picture.superlayer === layer else { return }
        let area = window.map { convert($0.bounds, from: $0) } ?? bounds
        let scale = traitCollection.displayScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        picture.frame = area
        picture.contentsScale = scale
        if area.size != lastSize, let metal = picture as? CAMetalLayer {
            metal.drawableSize = CGSize(width: area.width * scale, height: area.height * scale)
        }
        CATransaction.commit()
        guard area.size != lastSize else { return }
        #if os(iOS)
        if let player, player.frames != nil {
            lastSize = area.size
            if window != nil { player.showFrames(onScreen: PixelSize(width: Int(area.width * scale), height: Int(area.height * scale))) }
            return
        }
        #endif
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

extension MPVPlayer {
    /// Warms, once at launch and off the main thread, what the first
    /// subtitles need on a device: CoreText's fonts (libass looks up its
    /// font the first time it draws text) and the Metal shader compiler
    /// (libmpv draws subtitles with a shader made the first time they
    /// show). Both fell on the picture, which stopped for a moment the
    /// first time subtitles were picked.
    static func warmUp() {
        DispatchQueue.global(qos: .utility).async {
            for family in ["Helvetica", UIFont.systemFont(ofSize: 17).familyName] {
                let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
                _ = CTFontDescriptorCreateMatchingFontDescriptors(descriptor, nil)
                let font = CTFontCreateWithName(family as CFString, 24, nil)
                _ = CTFontCreateForString(font, "Aa" as CFString, CFRange(location: 0, length: 2))
            }
            let source = "#include <metal_stdlib>\nusing namespace metal;\nfragment half4 warm() { return half4(0.0h); }"
            _ = try? MTLCreateSystemDefaultDevice()?.makeLibrary(source: source, options: nil)
        }
    }
}

extension NetworkStatus {
    var fileReadahead: MPVPlayer.Readahead {
        unmetered ? .generous : .modest
    }
}

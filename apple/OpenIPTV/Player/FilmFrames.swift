#if os(iOS)
import Accelerate
import AVFoundation
import Libmpv
import Observation
import UIKit

/// No view owns this layer or the ones AVFoundation puts inside it, so Core Animation animates every change to
/// them for a quarter second, and AVFoundation adds its own animation as it sizes the picture inside: AVKit's
/// Picture in Picture icon faded the film in from black, and the picture slid and grew as a film opened.
final class FilmLayer: AVSampleBufferDisplayLayer {
    override func action(forKey event: String) -> CAAction? { nil }

    override func layoutSublayers() {
        super.layoutSublayers()
        sublayers?.forEach(Still.hold)
    }

    private final class Still: NSObject, CALayerDelegate {
        static let delegate = Still()

        static func hold(_ layer: CALayer) {
            if layer.delegate == nil { layer.delegate = delegate }
            layer.removeAllAnimations()
            layer.sublayers?.forEach(hold)
        }

        func action(for layer: CALayer, forKey event: String) -> CAAction? { NSNull() }
    }
}

final class FilmFrames: @unchecked Sendable {
    let layer = FilmLayer()
    private let clock: CMTimebase?
    var onPlayingChanged: (@Sendable (Bool) -> Void)? {
        get { lock.withLock { playingChanged } }
        set { lock.withLock { playingChanged = newValue } }
    }
    private var playingChanged: (@Sendable (Bool) -> Void)?
    private var context: OpaquePointer?
    private let queue = DispatchQueue(label: "openiptv.film-frames", qos: .userInteractive)
    private let lock = NSLock()
    private var inputs = FrameInputs()
    private var redraw = false
    private var waiting = false
    private var closed = false
    private var pool: CVPixelBufferPool?
    private var pooled = PixelSize(width: 0, height: 0)
    private var format: CMVideoFormatDescription?
    private var gaps = Metric.FrameGapWatch()
    #if DEBUG
    var onFrame: (@Sendable (Double) -> Void)?
    /// UI tests (perf/subtitle_look.py): the last sampled frame, "drawn 1920x1080 shown 2096x1179 color pq peak 255",
    /// its peak the brightest channel value in its bottom 30%, where subtitles go.
    var look: String { lock.withLock { lastLook } }
    private var lastLook = ""
    private var drawnFrames = 0
    #endif


    init() {
        var clock: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: nil, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &clock)
        self.clock = clock
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
        #if DEBUG
        if ProcessInfo.processInfo.environment["OPENREEL_DEBUG_BEHIND_PICTURE"] == "red" { layer.backgroundColor = UIColor.red.cgColor }
        #endif
        layer.controlTimebase = clock
        #if DEBUG
        let layer = layer
        DispatchQueue.main.async { MainActor.assumeIsolated { FilmLayerProbe.shared.watch(layer) } }
        #endif
    }

    func attach(to mpv: OpaquePointer) {
        var made: OpaquePointer?
        let api = strdup("sw")
        defer { free(api) }
        var params = [mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(api)),
                      mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)]
        guard mpv_render_context_create(&made, mpv, &params) >= 0, let made else { return }
        lock.withLock { context = made }
        mpv_render_context_set_update_callback(made, { raw in
            guard let raw else { return }
            Unmanaged<FilmFrames>.fromOpaque(raw).takeUnretainedValue().due()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func show(onScreen pixels: PixelSize?) -> FramePlan { change { $0.screen = pixels } }
    func show(inWindow pixels: PixelSize?) -> FramePlan { change { $0.window = pixels } }
    func fill(_ fill: Bool) -> FramePlan { change { $0.fill = fill } }
    func video(_ size: PixelSize, color: FrameColor) -> FramePlan {
        change {
            $0.video = size
            $0.color = color
        }
    }

    func setInBackground(_ inBackground: Bool) { _ = change { $0.inBackground = inBackground } }
    var isUndrawn: Bool { lock.withLock { inputs.undrawn } }

    func afterDraws(on target: DispatchQueue, _ work: @escaping @Sendable () -> Void) {
        queue.async { target.async(execute: work) }
    }

    func syncClock(_ seconds: Double, playing: Bool) {
        guard let clock else { return }
        let was = CMTimebaseGetRate(clock) != 0
        if abs(CMTimebaseGetTime(clock).seconds - seconds) > 0.5 || !was {
            CMTimebaseSetTime(clock, time: CMTime(seconds: seconds, preferredTimescale: 600))
        }
        CMTimebaseSetRate(clock, rate: playing ? 1 : 0)
        if !playing { lock.withLock { gaps.held() } }
        if was != playing { onPlayingChanged?(playing) }
    }

    var isPlaying: Bool { clock.map { CMTimebaseGetRate($0) != 0 } ?? false }

    func timeFrameGap(_ edge: Metric.PipEdge, for seconds: Double, done: @escaping @Sendable (Metric.PipEdge, Double) -> Void) {
        let began = CFAbsoluteTimeGetCurrent()
        let playing = isPlaying
        if let cut = lock.withLock({ gaps.start(edge, at: began, playing: playing) }) { done(cut.edge, cut.seconds) }
        queue.asyncAfter(deadline: .now() + seconds) { [self] in
            if let ended = lock.withLock({ gaps.end(began: began, at: CFAbsoluteTimeGetCurrent()) }) { done(ended.edge, ended.seconds) }
        }
    }

    func close() {
        let context = lock.withLock {
            closed = true
            defer { self.context = nil }
            return self.context
        }
        queue.sync {}
        guard let context else { return }
        mpv_render_context_set_update_callback(context, nil, nil)
        mpv_render_context_free(context)
    }

    private func change(_ edit: (inout FrameInputs) -> Void) -> FramePlan {
        let plan = lock.withLock {
            edit(&inputs)
            redraw = true
            return inputs.plan
        }
        due()
        return plan
    }

    /// Called by libmpv on any thread (nothing of libmpv's may be called here).
    private func due() {
        let scheduled = lock.withLock { () -> Bool in
            guard !closed, !waiting else { return false }
            waiting = true
            return true
        }
        if scheduled { queue.async { [self] in draw() } }
    }

    private func draw() {
        let state = lock.withLock { () -> (inputs: FrameInputs, redraw: Bool, context: OpaquePointer)? in
            waiting = false
            guard !closed, let current = self.context else { return nil }
            defer { redraw = false }
            return (inputs, redraw, current)
        }
        guard let state else { return }
        let context = state.context
        let fresh = mpv_render_context_update(context) & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0
        guard fresh || state.redraw else { return }
        let plan = state.inputs.plan
        guard !state.inputs.undrawn, let buffer = buffer(plan.size) else { return skip(context) }
        CVPixelBufferLockBaseAddress(buffer, [])
        let drawn = render(context, into: buffer, size: plan.size)
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard drawn else { return }
        state.inputs.color.tag(buffer)
        enqueue(buffer)
        #if DEBUG
        sample(buffer, plan: plan, inputs: state.inputs)
        #endif
    }

    #if DEBUG
    /// -debugFrameLook YES (the subtitle look test): the timed runs don't pay for the scan.
    private static let samples = UserDefaults.standard.bool(forKey: "debugFrameLook")

    private func sample(_ buffer: CVPixelBuffer, plan: FramePlan, inputs: FrameInputs) {
        guard Self.samples else { return }
        drawnFrames += 1
        guard drawnFrames % 24 == 1 else { return }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer)?.assumingMemoryBound(to: UInt8.self) else { return }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        var peak: UInt8 = 0
        for y in stride(from: height * 7 / 10, to: height, by: 2) {
            for x in stride(from: 0, to: width, by: 2) {
                let pixel = base + y * rowBytes + x * 4
                peak = max(peak, pixel[0], pixel[1], pixel[2])
            }
        }
        let box = inputs.window ?? inputs.screen
        let shown = box.map { min(Double($0.width), Double($0.height) * plan.size.aspect) } ?? Double(plan.size.width)
        let text = String(format: "drawn %dx%d shown %.0fx%.0f color %@ peak %d", width, height, shown, shown / plan.size.aspect,
                          "\(inputs.color)", Int(peak))
        lock.withLock { lastLook = text }
    }
    #endif

    private func buffer(_ size: PixelSize) -> CVPixelBuffer? {
        if size != pooled {
            pooled = size
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: size.width,
                kCVPixelBufferHeightKey as String: size.height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            pool = nil
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        var made: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess else { return nil }
        return made
    }

    private func render(_ context: OpaquePointer, into buffer: CVPixelBuffer, size: PixelSize) -> Bool {
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return false }
        var dims: [Int32] = [Int32(size.width), Int32(size.height)]
        var stride = CVPixelBufferGetBytesPerRow(buffer)
        // No alpha: libmpv draws subtitles on a frame with alpha only through zimg, which MPVKit leaves out.
        let pixels = strdup("bgr0")
        defer { free(pixels) }
        let drawn = dims.withUnsafeMutableBufferPointer { dims in
            withUnsafeMutablePointer(to: &stride) { stride in
                var params = [mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: UnsafeMutableRawPointer(dims.baseAddress)),
                              mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(pixels)),
                              mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: UnsafeMutableRawPointer(stride)),
                              mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: base),
                              mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)]
                return mpv_render_context_render(context, &params) >= 0
            }
        }
        guard drawn else { return false }
        // libmpv leaves the fourth byte 0 under subtitles, and the layer reads it as alpha.
        var image = vImage_Buffer(data: base, height: vImagePixelCount(size.height), width: vImagePixelCount(size.width), rowBytes: stride)
        vImageOverwriteChannelsWithScalar_ARGB8888(255, &image, &image, 0x1, vImage_Flags(kvImageNoFlags))
        return true
    }

    private func skip(_ context: OpaquePointer) {
        var yes: Int32 = 1
        withUnsafeMutablePointer(to: &yes) { yes in
            var params = [mpv_render_param(type: MPV_RENDER_PARAM_SKIP_RENDERING, data: UnsafeMutableRawPointer(yes)),
                          mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)]
            _ = mpv_render_context_render(context, &params)
        }
    }

    private func enqueue(_ buffer: CVPixelBuffer) {
        if format.map({ !CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: buffer) }) ?? true {
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format)
        }
        guard let format else { return }
        let now = clock.map { CMTimebaseGetTime($0) } ?? CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: now, decodeTimeStamp: .invalid)
        var made: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &made)
        guard let sample = made else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(first, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
            #if DEBUG
            DispatchQueue.main.async { MainActor.assumeIsolated { FilmLayerProbe.shared.flushed() } }
            #endif
        }
        renderer.enqueue(sample)
        lock.withLock { gaps.frame(at: CFAbsoluteTimeGetCurrent()) }
        #if DEBUG
        onFrame?(CFAbsoluteTimeGetCurrent())
        #endif
    }
}

#if DEBUG
/// UI tests: whether the film's picture ever moved, faded or went black on screen, read off every frame.
@MainActor @Observable
final class FilmLayerProbe {
    static let shared = FilmLayerProbe()
    private(set) var text = "anims=none fades=0 flushes=0"
    @ObservationIgnored private weak var film: CALayer?
    @ObservationIgnored private var link: CADisplayLink?
    @ObservationIgnored private var anims: [String] = []
    @ObservationIgnored private var fades = 0
    @ObservationIgnored private var fading = false
    @ObservationIgnored private var flushes = 0

    func watch(_ layer: CALayer) {
        film = layer
        guard link == nil else { return }
        let link = CADisplayLink(target: Ticker { FilmLayerProbe.shared.tick() }, selector: #selector(Ticker.tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func flushed() {
        flushes += 1
        publish()
    }

    private func tick() {
        guard let film else { return }
        let chain = Array(sequence(first: film, next: \.superlayer))
        let looks = { (layer: CALayer) in layer.presentation() ?? layer }
        let shown = chain.contains { ($0.delegate as? UIView)?.window != nil } && !chain.contains { looks($0).isHidden }
        let opacity = chain.reduce(Float(1)) { $0 * looks($1).opacity }
        let nowFading = shown && opacity > 0.02 && opacity < 0.98
        if nowFading, !fading { fades += 1 }
        fading = nowFading
        if shown {
            func walk(_ layer: CALayer) -> [String] {
                (layer.animationKeys() ?? []).map { "\(type(of: layer)).\($0)" } + (layer.sublayers ?? []).flatMap(walk)
            }
            for name in walk(film) where !anims.contains(name) { anims.append(name) }
        }
        publish()
    }

    private func publish() {
        let next = "anims=\(anims.isEmpty ? "none" : anims.joined(separator: ",")) fades=\(fades) flushes=\(flushes)"
        if next != text {
            text = next
            NSLog("%@", "PERF filmlayer \(text)")
        }
    }

    private final class Ticker: NSObject {
        let action: () -> Void
        init(_ action: @escaping () -> Void) { self.action = action }
        @objc func tick() { MainActor.assumeIsolated { action() } }
    }
}
#endif
#endif

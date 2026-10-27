#if os(iOS)
import AVFoundation
import Libmpv
import UIKit

final class FilmFrames: @unchecked Sendable {
    let layer = AVSampleBufferDisplayLayer()
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
    #if DEBUG
    var onFrame: (@Sendable (Double) -> Void)?
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

    func syncClock(_ seconds: Double, playing: Bool) {
        guard let clock else { return }
        let was = CMTimebaseGetRate(clock) != 0
        if abs(CMTimebaseGetTime(clock).seconds - seconds) > 0.5 || !was {
            CMTimebaseSetTime(clock, time: CMTime(seconds: seconds, preferredTimescale: 600))
        }
        CMTimebaseSetRate(clock, rate: playing ? 1 : 0)
        if was != playing { onPlayingChanged?(playing) }
    }

    var isPlaying: Bool { clock.map { CMTimebaseGetRate($0) != 0 } ?? false }

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
        tag(buffer, state.inputs.color)
        enqueue(buffer)
    }

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
        let pixels = strdup("bgra")
        defer { free(pixels) }
        return dims.withUnsafeMutableBufferPointer { dims in
            withUnsafeMutablePointer(to: &stride) { stride in
                var params = [mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: UnsafeMutableRawPointer(dims.baseAddress)),
                              mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(pixels)),
                              mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: UnsafeMutableRawPointer(stride)),
                              mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: base),
                              mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)]
                return mpv_render_context_render(context, &params) >= 0
            }
        }
    }

    private func skip(_ context: OpaquePointer) {
        var yes: Int32 = 1
        withUnsafeMutablePointer(to: &yes) { yes in
            var params = [mpv_render_param(type: MPV_RENDER_PARAM_SKIP_RENDERING, data: UnsafeMutableRawPointer(yes)),
                          mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)]
            _ = mpv_render_context_render(context, &params)
        }
    }

    private func tag(_ buffer: CVPixelBuffer, _ color: FrameColor) {
        let (primaries, transfer): (CFString, CFString) = switch color {
        case .bt709: (kCVImageBufferColorPrimaries_ITU_R_709_2, kCVImageBufferTransferFunction_ITU_R_709_2)
        case .pq: (kCVImageBufferColorPrimaries_ITU_R_2020, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
        case .hlg: (kCVImageBufferColorPrimaries_ITU_R_2020, kCVImageBufferTransferFunction_ITU_R_2100_HLG)
        }
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
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
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding { renderer.flush() }
        renderer.enqueue(sample)
        #if DEBUG
        onFrame?(CFAbsoluteTimeGetCurrent())
        #endif
    }
}
#endif

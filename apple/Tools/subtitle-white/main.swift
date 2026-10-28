import CoreImage
import CoreVideo
import Foundation
import Libmpv

setvbuf(stdout, nil, _IONBF, 0)

enum Expect { case sdrWhite, remains }

struct Case {
    let film: String
    let subtitle: String?
    let expect: Expect
}

/// libmpv's frames drawn on their own queue, as FilmFrames draws them: only mpv_render_* runs there, and nothing
/// there waits for the player's thread.
final class Frames: @unchecked Sendable {
    let width = 1920, height = 1080
    private let queue = DispatchQueue(label: "subtitle-white.frames")
    private let context: OpaquePointer
    private var pixels: [UInt8]

    init(_ context: OpaquePointer) {
        self.context = context
        pixels = [UInt8](repeating: 0, count: width * height * 4)
        mpv_render_context_set_update_callback(context, { raw in
            guard let raw else { return }
            let frames = Unmanaged<Frames>.fromOpaque(raw).takeUnretainedValue()
            frames.queue.async { frames.drawIfDue() }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    /// The frame drawn again with the subtitles as they are now: its brightest code in the bottom 40%.
    func peak() -> UInt8 {
        queue.sync {
            _ = mpv_render_context_update(context)
            draw()
            var peak: UInt8 = 0
            for y in (height * 6 / 10)..<height {
                for x in 0..<width {
                    let i = (y * width + x) * 4
                    peak = max(peak, pixels[i], pixels[i + 1], pixels[i + 2])
                }
            }
            return peak
        }
    }

    func close() {
        queue.sync { mpv_render_context_set_update_callback(context, nil, nil) }
        mpv_render_context_free(context)
    }

    private func drawIfDue() {
        if mpv_render_context_update(context) & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 { draw() }
    }

    private func draw() {
        var dims: [Int32] = [Int32(width), Int32(height)]
        var stride = width * 4
        let format = strdup("bgr0")
        defer { free(format) }
        pixels.withUnsafeMutableBytes { buffer in
            dims.withUnsafeMutableBufferPointer { dims in
                withUnsafeMutablePointer(to: &stride) { stride in
                    var params = [mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: UnsafeMutableRawPointer(dims.baseAddress)),
                                  mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(format)),
                                  mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: UnsafeMutableRawPointer(stride)),
                                  mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: buffer.baseAddress),
                                  mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)]
                    _ = mpv_render_context_render(context, &params)
                }
            }
        }
    }
}

/// One frame with its subtitle as the iPhone's software picture draws it, and how bright Core Image shows the
/// subtitle's peak, in SDR whites, once the frame is tagged as the app tags it.
func brightest(film: URL, subtitle: URL?) -> (codec: String, peak: UInt8, white: Double) {
    guard let mpv = mpv_create() else { fatalError("mpv_create") }
    defer { mpv_terminate_destroy(mpv) }
    func set(_ name: String, _ value: String) { mpv_set_option_string(mpv, name, value) }
    for option in ["load-scripts", "osc", "ytdl", "load-stats-overlay", "load-console", "load-auto-profiles", "load-select",
                   "load-commands", "load-positioning", "load-context-menu", "input-default-bindings"] {
        set(option, "no")
    }
    set("vo", "libmpv")
    set("ao", "null")
    set("hwdec", "videotoolbox-copy")
    set("sub-scale-with-window", "no")
    set("sub-use-margins", "no")
    set("msg-level", "all=no")
    if let subtitle { set("sub-files", subtitle.path) }
    set("sid", "1")
    set("pause", "yes")
    mpv_initialize(mpv)
    var made: OpaquePointer?
    let api = strdup("sw")
    defer { free(api) }
    var create = [mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(api)),
                  mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)]
    guard mpv_render_context_create(&made, mpv, &create) >= 0, let context = made else { fatalError("render context") }
    let frames = Frames(context)
    defer { frames.close() }

    func command(_ words: [String]) {
        let owned = words.map { strdup($0) }
        var c: [UnsafePointer<CChar>?] = owned.map { UnsafePointer($0) } + [nil]
        mpv_command(mpv, &c)
        owned.forEach { free($0) }
    }
    func property(_ name: String) -> String {
        guard let raw = mpv_get_property_string(mpv, name) else { return "none" }
        defer { mpv_free(raw) }
        return String(cString: raw)
    }

    command(["loadfile", film.path])
    var color = FrameColor.bt709
    var restarts = 0
    let deadline = Date().addingTimeInterval(20)
    while restarts < 2 {
        guard Date() < deadline else { fatalError("\(film.lastPathComponent) did not play in 20 s") }
        guard let event = mpv_wait_event(mpv, 0.1)?.pointee else { continue }
        switch event.event_id {
        case MPV_EVENT_VIDEO_RECONFIG:
            // As MPVPlayer.noteFilmSize does.
            color = FrameColor(gamma: property("video-params/gamma"))
            mpv_set_property_string(mpv, "sub-color", color.subtitleColor)
        case MPV_EVENT_PLAYBACK_RESTART:
            restarts += 1
            // Into the subtitle's time: it begins half a second in.
            if restarts == 1 { command(["seek", "1", "absolute+exact"]) }
        case MPV_EVENT_END_FILE, MPV_EVENT_SHUTDOWN: fatalError("\(film.lastPathComponent) did not play")
        default: continue
        }
    }
    var peak: UInt8 = 0
    for _ in 0..<3 {
        usleep(50_000)
        peak = frames.peak()
    }
    return (property("current-tracks/sub/codec"), peak, shownWhite(peak, color))
}

func shownWhite(_ code: UInt8, _ color: FrameColor) -> Double {
    var made: CVPixelBuffer?
    CVPixelBufferCreate(nil, 4, 4, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &made)
    guard let buffer = made else { fatalError("pixel buffer") }
    CVPixelBufferLockBaseAddress(buffer, [])
    let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
    for i in 0..<(CVPixelBufferGetBytesPerRow(buffer) * 4) { base[i] = i % 4 == 3 ? 255 : code }
    CVPixelBufferUnlockBaseAddress(buffer, [])
    color.tag(buffer)
    let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    var out = [Float](repeating: 0, count: 4)
    CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf])
        .render(CIImage(cvPixelBuffer: buffer), toBitmap: &out, rowBytes: 16, bounds: CGRect(x: 2, y: 2, width: 1, height: 1),
                format: .RGBAf, colorSpace: linear)
    return Double(out[1])
}

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
let cases = ["hdr10", "hlg"].flatMap { transfer in
    [Case(film: "\(transfer).mkv", subtitle: "text.srt", expect: .sdrWhite),
     Case(film: "\(transfer).mkv", subtitle: "text.vtt", expect: .sdrWhite),
     Case(film: "\(transfer)-mov_text.mp4", subtitle: nil, expect: .sdrWhite),
     Case(film: "\(transfer).mkv", subtitle: "tagged.srt", expect: .remains),
     Case(film: "\(transfer).mkv", subtitle: "styled.ass", expect: .remains),
     Case(film: "\(transfer)-pgs.mkv", subtitle: nil, expect: .remains)]
} + [Case(film: "sdr.mkv", subtitle: "text.srt", expect: .sdrWhite),
     Case(film: "sdr.mkv", subtitle: "styled.ass", expect: .sdrWhite),
     Case(film: "sdr-pgs.mkv", subtitle: nil, expect: .sdrWhite)]
var failed = 0
for test in cases {
    let seen = brightest(film: folder.appending(path: test.film), subtitle: test.subtitle.map { folder.appending(path: $0) })
    let atWhite = (0.9...1.05).contains(seen.white)
    let verdict = switch test.expect {
    case .sdrWhite: atWhite ? "PASS" : "FAIL"
    case .remains: atWhite ? "NOW AT SDR WHITE" : "REMAINS"
    }
    if verdict == "FAIL" { failed += 1 }
    print(String(format: "%@ %@ %@ (%@): peak code %d, %.2fx SDR white", verdict, test.film, test.subtitle ?? "own track", seen.codec,
                 Int(seen.peak), seen.white))
}
exit(failed == 0 ? 0 : 1)

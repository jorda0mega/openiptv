// frame_probe: one frame of a film, subtitles on, drawn by the app's libmpv (MPVKit's macOS slice) the way the
// iPhone's software picture draws it (vo=libmpv, videotoolbox-copy, sw-fast, bgr0), at each size given.
// For each size: the frame's transfer, the subtitle's peak code value, and its text box in drawn pixels.
//   perf/frame_probe.sh FILM SECONDS WIDTHxHEIGHT...
import Foundation
import Libmpv

setvbuf(stdout, nil, _IONBF, 0)
let args = CommandLine.arguments
guard args.count >= 4, let at = Double(args[2]) else { fatalError("frame_probe FILM SECONDS WIDTHxHEIGHT...") }
guard let mpv = mpv_create() else { fatalError("create") }
func set(_ name: String, _ value: String) { mpv_set_option_string(mpv, name, value) }
for option in ["load-scripts", "osc", "ytdl", "load-stats-overlay", "load-console", "load-auto-profiles", "load-select", "load-commands",
               "load-positioning", "load-context-menu", "input-default-bindings"] {
    set(option, "no")
}
set("vo", "libmpv")
set("ao", "null")
set("hwdec", "videotoolbox-copy")
set("sw-fast", "yes")
set("sub-scale-with-window", "no")
set("sub-use-margins", "no")
set("sid", "1")
set("pause", "yes")
mpv_initialize(mpv)
var context: OpaquePointer?
let api = strdup("sw")
var params = [mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(api)),
              mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)]
guard mpv_render_context_create(&context, mpv, &params) >= 0, let context else { fatalError("render context") }
func command(_ words: [String]) {
    let owned = words.map { strdup($0) }
    var c: [UnsafePointer<CChar>?] = owned.map { UnsafePointer($0) } + [nil]
    mpv_command(mpv, &c)
    owned.forEach { free($0) }
}
// libmpv's video output waits for each frame to be drawn: draw into a scratch frame while waiting.
var scratch = [UInt8](repeating: 0, count: 64 * 64 * 4)
func drawScratch() {
    guard mpv_render_context_update(context) & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 else { return }
    var dims: [Int32] = [64, 64]
    var stride = 64 * 4
    let format = strdup("bgr0")
    defer { free(format) }
    scratch.withUnsafeMutableBytes { buffer in
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
func waitForRestart() {
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
        drawScratch()
        guard let event = mpv_wait_event(mpv, 0.02)?.pointee else { continue }
        if event.event_id == MPV_EVENT_PLAYBACK_RESTART { return }
        if event.event_id == MPV_EVENT_SHUTDOWN || event.event_id == MPV_EVENT_END_FILE { fatalError("no playback") }
    }
    fatalError("no restart in 20 s")
}
command(["loadfile", args[1]])
print("loading")
waitForRestart()
print("playing")
command(["seek", String(at), "absolute+exact"])
waitForRestart()
let gamma = mpv_get_property_string(mpv, "video-params/gamma").map { String(cString: $0) } ?? "?"
let source = (mpv_get_property_string(mpv, "video-params/w").map { String(cString: $0) } ?? "?") + "x"
    + (mpv_get_property_string(mpv, "video-params/h").map { String(cString: $0) } ?? "?")
for size in args.dropFirst(3) {
    let parts = size.split(separator: "x").compactMap { Int($0) }
    let (width, height) = (parts[0], parts[1])
    var stride = width * 4
    var pixels = [UInt8](repeating: 0, count: stride * height)
    var dims: [Int32] = [Int32(width), Int32(height)]
    let format = strdup("bgr0")
    // Draw twice: the first render after a size change can still be the old frame's.
    for _ in 0..<2 {
        _ = mpv_render_context_update(context)
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
    var peak: UInt8 = 0, background: UInt8 = 0
    var box = (minX: width, minY: height, maxX: -1, maxY: -1)
    for y in (height * 6 / 10)..<height {
        for x in 0..<width {
            let i = y * stride + x * 4
            let value = max(pixels[i], pixels[i + 1], pixels[i + 2])
            peak = max(peak, value)
            if value >= 200 {
                box = (min(box.minX, x), min(box.minY, y), max(box.maxX, x), max(box.maxY, y))
            }
        }
    }
    let middle = (height / 3) * stride + (width / 2) * 4
    background = max(pixels[middle], pixels[middle + 1], pixels[middle + 2])
    print("FRAME source \(source) gamma \(gamma) drawn \(width)x\(height) picture \(background) subtitle peak \(peak) "
          + (box.maxX >= 0 ? "text box \(box.maxX - box.minX + 1)x\(box.maxY - box.minY + 1) px" : "no text"))
}
mpv_render_context_free(context)
mpv_terminate_destroy(mpv)

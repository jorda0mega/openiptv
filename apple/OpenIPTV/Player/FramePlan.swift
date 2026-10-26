import Foundation

struct PixelSize: Equatable, Sendable {
    var width: Int
    var height: Int

    var aspect: Double { Double(width) / Double(height) }
}

struct FramePlan: Equatable, Sendable {
    static let fullHDPixels = 1920 * 1080
    static let fallbackWindow = PixelSize(width: 1280, height: 720)

    var size: PixelSize
    /// libmpv crops when this is set, and subtitles stay in the part shown.
    var fills: Bool

    static func make(video: PixelSize, screen: PixelSize?, window: PixelSize?, fill: Bool) -> FramePlan {
        let screen = screen.flatMap(nonEmpty), window = window.flatMap(nonEmpty)
        let fills = fill && window == nil && screen != nil
        let box = window ?? screen ?? video
        let shape = fills ? box.aspect : video.aspect
        let shown = video.aspect > shape
            ? (width: Double(video.height) * shape, height: Double(video.height))
            : (width: Double(video.width), height: Double(video.width) / shape)
        let fitted = min(shown.width, Double(box.width), Double(box.height) * shape)
        let cap = (Double(fullHDPixels) * shape).squareRoot()
        let width = min(fitted, cap)
        return FramePlan(size: PixelSize(width: even(width), height: even(width / shape)), fills: fills)
    }

    private static func even(_ value: Double) -> Int { max(2, Int(value.rounded()) & ~1) }
    private static func nonEmpty(_ size: PixelSize) -> PixelSize? { size.width > 0 && size.height > 0 ? size : nil }
}

/// What a film's frames are drawn for: written by the player, its view and Picture in Picture.
struct FrameInputs: Equatable, Sendable {
    var video = PixelSize(width: 1920, height: 1080)
    var color = FrameColor.bt709
    var screen: PixelSize?
    var window: PixelSize?
    var fill = false
    var inBackground = false

    /// Behind the app with no window to show them: frames go by undrawn, and the sound plays on.
    var undrawn: Bool { inBackground && window == nil }

    var plan: FramePlan { FramePlan.make(video: video, screen: screen, window: window, fill: fill) }
}

/// libmpv's software renderer converts the matrix only, so an HDR film's RGB stays coded for its own transfer and primaries.
enum FrameColor: Equatable, Sendable {
    case bt709, pq, hlg

    init(gamma: String?) {
        switch gamma {
        case "pq": self = .pq
        case "hlg": self = .hlg
        default: self = .bt709
        }
    }
}

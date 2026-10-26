import Foundation

struct PixelSize: Equatable, Sendable {
    var width: Int
    var height: Int

    var aspect: Double { Double(width) / Double(height) }
}

/// What libmpv's software renderer draws for a film's one layer: the size of each frame, and whether libmpv
/// crops the picture to fill (subtitles then stay in the part shown).
struct FramePlan: Equatable, Sendable {
    /// About 1080p: drawn by the CPU for every frame, and the layer scales it up on the GPU for free.
    static let mostPixels = 1920 * 1080
    /// The floating window before iOS says its size.
    static let firstWindow = PixelSize(width: 1280, height: 720)

    var size: PixelSize
    var fills: Bool

    /// The window wins over the screen, and always fits (the window takes the frames' shape). On screen, fill
    /// draws the screen's shape and fit the film's. Off screen (a player opened ahead or kept), the film's own
    /// size. Never more pixels than the film has in the part shown, nor than `mostPixels`.
    static func make(video: PixelSize, screen: PixelSize?, window: PixelSize?, fill: Bool) -> FramePlan {
        let fills = fill && window == nil && screen != nil
        let box = window ?? screen ?? video
        let shape = fills ? box.aspect : video.aspect
        let shown = video.aspect > shape
            ? (width: Double(video.height) * shape, height: Double(video.height))
            : (width: Double(video.width), height: Double(video.width) / shape)
        var width = min(shown.width, Double(box.width), Double(box.height) * shape)
        let most = (Double(mostPixels) * shape).squareRoot()
        width = min(width, most)
        return FramePlan(size: PixelSize(width: even(width), height: even(width / shape)), fills: fills)
    }

    private static func even(_ value: Double) -> Int { max(2, Int(value.rounded()) & ~1) }
}

/// How a frame's colours are coded, for its tags: libmpv's software renderer converts the matrix only, so an
/// HDR film's RGB stays coded for its own transfer and primaries.
enum FrameColor: Equatable, Sendable {
    case bt709, pq, hlg

    /// From libmpv's "video-params/gamma".
    init(gamma: String?) {
        switch gamma {
        case "pq": self = .pq
        case "hlg": self = .hlg
        default: self = .bt709
        }
    }
}

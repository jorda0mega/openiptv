import Foundation

/// Which image to show for an Emby item and what to try if it fails to load.
/// Same order as Emby's own web client (docs/emby-client-behavior.md §2),
/// but every usable candidate is returned so a broken image falls through to
/// the next instead of leaving a blank card. Mirrors crates/core/src/artwork.rs.
enum Artwork {
    enum Context { case poster, landscape, backdrop }

    enum Shape: String {
        case portrait, square, fourThree, landscape

        var aspect: Double {
            switch self {
            case .portrait: 2.0 / 3.0
            case .square: 1
            case .fourThree: 4.0 / 3.0
            case .landscape: 16.0 / 9.0
            }
        }

        static func from(ratio: Double) -> Shape {
            switch ratio {
            case 1.5556...: .landscape
            case 1.1333...: .fourThree
            case 0.8333...: .square
            default: .portrait
            }
        }

        static func forKind(_ kind: String) -> Shape {
            switch kind {
            case "Movie", "Series", "Season", "BoxSet", "Trailer": .portrait
            case "Episode", "Video", "Program", "TvChannel", "Recording", "MusicVideo": .landscape
            default: .square
            }
        }
    }

    struct Candidate {
        let itemId: String
        let type: String
        let tag: String
        let index: Int?
        let aspect: Double
        let letterbox: Bool

        func contain(in shape: Shape) -> Bool {
            letterbox || abs(aspect - shape.aspect) > 0.28
        }
    }

    /// One shape per row, decided before images load so the grid never jumps.
    static func listShape(_ items: [EmbyItem], context: Context) -> Shape {
        guard context == .poster else { return .landscape }
        var counts: [Shape: Int] = [:]
        for ratio in items.compactMap(\.primaryImageAspectRatio) where ratio > 0 {
            counts[Shape.from(ratio: ratio), default: 0] += 1
        }
        let order: [Shape] = [.portrait, .square, .fourThree, .landscape]
        if let best = order.max(by: { counts[$0, default: 0] < counts[$1, default: 0] }), counts[best, default: 0] > 0 {
            return best
        }
        return items.first.map { Shape.forKind($0.kind) } ?? .portrait
    }

    static func candidates(_ item: EmbyItem, context: Context) -> [Candidate] {
        var out: [Candidate] = []
        func push(_ id: String?, _ type: String, _ tag: String?, index: Int? = nil, aspect: Double, letterbox: Bool = false) {
            guard let id, !id.isEmpty, let tag, !tag.isEmpty else { return }
            guard !out.contains(where: { $0.itemId == id && $0.type == type && $0.index == index }) else { return }
            out.append(Candidate(itemId: id, type: type, tag: tag, index: index, aspect: aspect, letterbox: letterbox))
        }
        let wide = 16.0 / 9.0
        func ownPrimary() {
            let ratio = item.primaryImageAspectRatio.flatMap { $0 > 0 ? $0 : nil } ?? Shape.forKind(item.kind).aspect
            push(item.id, "Primary", item.imageTags["Primary"], aspect: ratio, letterbox: item.kind == "TvChannel")
        }
        func ownThumb() { push(item.id, "Thumb", item.imageTags["Thumb"], aspect: wide) }
        func ownBackdrop() { push(item.id, "Backdrop", item.backdropImageTags.first, index: 0, aspect: wide) }
        func parentThumb() { push(item.parentThumbItemId, "Thumb", item.parentThumbImageTag, aspect: wide) }
        func parentBackdrop() {
            push(item.parentBackdropItemId, "Backdrop", item.parentBackdropImageTags.first, index: 0, aspect: wide)
        }
        func poster() {
            ownPrimary()
            push(item.albumId, "Primary", item.albumPrimaryImageTag, aspect: 1)
            push(item.parentPrimaryImageItemId, "Primary", item.parentPrimaryImageTag, aspect: item.kind == "Episode" ? 2.0 / 3.0 : 1)
            push(item.seriesId, "Primary", item.seriesPrimaryImageTag, aspect: 2.0 / 3.0)
            if item.kind == "Season" { ownThumb() }
            push(item.channelId, "Primary", item.channelPrimaryImageTag, aspect: wide, letterbox: true)
            ownBackdrop()
            ownThumb()
            parentThumb()
            parentBackdrop()
        }
        switch context {
        case .poster:
            poster()
        case .landscape:
            ownThumb()
            if item.kind != "Photo" { parentThumb() }
            ownBackdrop()
            if item.kind == "Episode" { parentBackdrop() }
            ownPrimary()
            poster()
        case .backdrop:
            ownBackdrop()
            parentBackdrop()
            ownThumb()
            parentThumb()
            poster()
        }
        return out
    }

    /// Requested widths snap to a ladder so nearby sizes share a cached image.
    static func bucket(_ px: Int) -> Int {
        [120, 160, 240, 320, 400, 480, 640, 720, 960, 1280, 1920, 2560, 3840].first { $0 >= px } ?? 3840
    }
}

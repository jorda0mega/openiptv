import Foundation

struct PictureIndex: Sendable {
    private struct Picture: Sendable {
        let url: URL
        let width: Int
    }

    private var byItem: [String: [Picture]] = [:]

    mutating func note(_ url: URL) {
        let parts = url.pathComponents
        guard let items = parts.firstIndex(of: "Items"), items + 2 < parts.count, parts[items + 2] == "Images" else { return }
        let width = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { ["maxWidth", "width", "fillWidth"].contains($0.name) }?.value.flatMap(Int.init) ?? 0
        if byItem.count > 2000 { byItem.removeAll() }
        var pictures = byItem[parts[items + 1], default: []].filter { $0.url != url }.suffix(7)
        pictures.append(Picture(url: url, width: width))
        byItem[parts[items + 1]] = Array(pictures)
    }

    func pictures(of items: [String]) -> [URL] {
        items.flatMap { byItem[$0] ?? [] }.sorted { $0.width > $1.width }.map(\.url)
    }
}

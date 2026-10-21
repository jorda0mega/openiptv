import Foundation

/// The server's converted version of a film, as the player is given it.
struct ConvertedPlaylist: Sendable {
    /// Each segment: its length, its own tags, and where it is.
    let segments: [(seconds: Double, tags: [String], url: URL)]
    /// The playlist's tags before its first segment.
    let header: [String]

    /// The master playlist's first variant, where it is.
    static func variant(of master: [String], at url: URL) -> URL? {
        master.lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") }
            .flatMap { URL(string: $0, relativeTo: url)?.absoluteURL }
    }

    /// nil for a playlist that can't be listed again from elsewhere: one
    /// still growing (no end), or with tags pointing to other addresses
    /// (keys, a first part to read before each segment).
    init?(_ lines: [String], at url: URL) {
        var header: [String] = [], tags: [String] = [], segments: [(seconds: Double, tags: [String], url: URL)] = []
        var ended = false
        for line in lines.map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
            if line.contains("URI=") { return nil }
            if line == "#EXT-X-ENDLIST" {
                ended = true
            } else if line.hasPrefix("#") {
                if segments.isEmpty, tags.isEmpty, !line.hasPrefix("#EXTINF:") { header.append(line) } else { tags.append(line) }
            } else {
                guard let seconds = tags.first(where: { $0.hasPrefix("#EXTINF:") }).flatMap({ Double($0.dropFirst(8).prefix { $0 != "," }) }),
                      let segment = URL(string: line, relativeTo: url)?.absoluteURL else { return nil }
                segments.append((seconds, tags, segment))
                tags = []
            }
        }
        guard ended, !segments.isEmpty else { return nil }
        self.header = header
        self.segments = segments
    }

    /// The playlist for the player to play `second` from, and where in the
    /// film the player's clock starts.
    func from(_ second: Double) -> (text: String, start: Double) {
        let lines = header + segments.flatMap { $0.tags + [$0.url.absoluteString] } + ["#EXT-X-ENDLIST"]
        return (lines.joined(separator: "\n") + "\n", 0)
    }
}

import Foundation

/// The server's converted version of a film, listed from where it plays.
/// Emby lists the whole film whatever second it was asked from, and the
/// player (ffmpeg) reads a playlist's first segment before it jumps: Emby
/// converted the film's start, then started again at the second asked, two
/// waits for its slow first segment. Listed from the segment holding that
/// second, the player asks for that one first.
struct ConvertedPlaylist: Sendable {
    /// Each segment: its length, its own tags, and where it is.
    let segments: [(seconds: Double, tags: [String], url: URL)]
    /// The playlist's tags before its first segment.
    let header: [String]

    /// Emby's playlist for this master, fetched with the key in a header as
    /// the player sends it; nil when it can't be read or listed again.
    static func load(_ master: URL, headers: [String]) async -> ConvertedPlaylist? {
        guard let top = await lines(master, headers), let variant = variant(of: top.lines, at: top.url),
              let list = await lines(variant, headers) else { return nil }
        return ConvertedPlaylist(list.lines, at: list.url)
    }

    private static func lines(_ url: URL, _ headers: [String]) async -> (lines: [String], url: URL)? {
        var request = HTTP.keyInHeader(URLRequest(url: url))
        request.timeoutInterval = 20
        for header in headers {
            let pair = header.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 { request.setValue(pair[1], forHTTPHeaderField: pair[0]) }
        }
        #if DEBUG
        let asked = CFAbsoluteTimeGetCurrent()
        #endif
        guard let (bytes, response) = try? await HTTP.session.bytes(for: request, delegate: HTTP.keyOutOfRedirects) else { return nil }
        #if DEBUG
        let answered = CFAbsoluteTimeGetCurrent()
        OpenRequests.note { $0.fetched(.playlist, from: asked, to: answered) }
        #endif
        guard (response as? HTTPURLResponse)?.statusCode == 200, let at = response.url else { return nil }
        var lines: [String] = []
        do {
            for try await line in bytes.lines { lines.append(line) }
        } catch {
            return nil
        }
        return (lines, at)
    }

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
    /// film the player's clock starts (its first segment's start).
    func from(_ second: Double) -> (text: String, start: Double) {
        var first = 0, start = 0.0
        while first < segments.count - 1, start + segments[first].seconds <= second {
            start += segments[first].seconds
            first += 1
        }
        let tag = "#EXT-X-MEDIA-SEQUENCE:"
        let sequence = header.first { $0.hasPrefix(tag) }.flatMap { Int($0.dropFirst(tag.count)) } ?? 0
        let lines = header.filter { !$0.hasPrefix(tag) } + [tag + String(sequence + first)]
            + segments[first...].flatMap { $0.tags + [$0.url.absoluteString] } + ["#EXT-X-ENDLIST"]
        return (lines.joined(separator: "\n") + "\n", start)
    }
}

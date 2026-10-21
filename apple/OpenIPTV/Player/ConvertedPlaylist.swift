import Foundation

/// Emby lists the whole film whatever second it was asked from, and ffmpeg
/// reads a playlist's first segment before it jumps.
struct ConvertedPlaylist: Sendable {
    let segments: [(seconds: Double, tags: [String], url: URL)]
    let header: [String]

    enum Opening: Sendable {
        case listed(ConvertedPlaylist)
        /// The server's own playlist: one that can't be listed again.
        case whole
        /// Not with the key: words and counts for the debug readout.
        case refused(String)
    }

    static func load(_ master: URL, headers: [String],
                     fetch: (URLRequest) async -> (lines: [String], url: URL)? = lines) async -> Opening {
        guard let top = await fetch(request(master, headers, given: master)), let variant = variant(of: top.lines, at: top.url),
              let list = await fetch(request(variant, headers, given: master)) else { return .whole }
        return ConvertedPlaylist(list.lines, at: list.url).map(Opening.listed) ?? .whole
    }

    /// The account's key goes only to the server the app was given: not to
    /// one the master was redirected to, nor to one it lists the variant on.
    private static func request(_ url: URL, _ headers: [String], given: URL) -> URLRequest {
        var request = HTTP.redirected(URLRequest(url: url), from: given)
        request.timeoutInterval = 20
        guard HTTP.sameServer(url, given) else { return request }
        for header in headers {
            let pair = header.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 { request.setValue(pair[1], forHTTPHeaderField: pair[0]) }
        }
        return request
    }

    private static func lines(_ request: URLRequest) async -> (lines: [String], url: URL)? {
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

    func listed(from second: Double) -> (playlist: String, clockStart: Double) {
        var first = 0, clockStart = 0.0
        while first < segments.count - 1, clockStart + segments[first].seconds <= second {
            clockStart += segments[first].seconds
            first += 1
        }
        let tag = "#EXT-X-MEDIA-SEQUENCE:"
        let sequence = header.first { $0.hasPrefix(tag) }.flatMap { Int($0.dropFirst(tag.count)) } ?? 0
        let lines = header.filter { !$0.hasPrefix(tag) } + [tag + String(sequence + first)]
            + segments[first...].flatMap { $0.tags + [$0.url.absoluteString] } + ["#EXT-X-ENDLIST"]
        return (lines.joined(separator: "\n") + "\n", clockStart)
    }
}

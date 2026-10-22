import Foundation

/// Emby lists the whole film whatever second it was asked from, and ffmpeg
/// reads a playlist's first segment before it jumps.
struct ConvertedPlaylist: Sendable {
    let segments: [(seconds: Double, tags: [String], url: URL)]
    let header: [String]

    enum Opening: Sendable {
        case listed(ConvertedPlaylist)
        case whole
        case refused(String)
    }

    /// The player sends the key with every request for the version, so it
    /// opens only when every address the playlists name is on the server
    /// the app was given. The master names one: the player reads every
    /// variant it lists.
    static func load(_ master: URL, headers: [String],
                     fetch: (URLRequest) async -> (lines: [String], url: URL)? = lines) async -> Opening {
        guard let top = await fetch(request(master, headers, given: master)) else { return .refused("master unread") }
        let named = addresses(top.lines, at: top.url)
        guard named.count == 1, let variant = variant(of: top.lines, at: top.url) else { return .refused("master names \(named.count)") }
        let away = elsewhere([top.url] + named, from: master)
        guard away == 0 else { return .refused("master \(away) of \(named.count + 1) elsewhere") }
        guard let list = await fetch(request(variant, headers, given: master)) else { return .refused("variant unread") }
        let inside = addresses(list.lines, at: list.url)
        let out = elsewhere([list.url] + inside, from: master)
        guard out == 0 else { return .refused("variant \(out) of \(inside.count + 1) elsewhere") }
        return ConvertedPlaylist(list.lines, at: list.url).map(Opening.listed) ?? .whole
    }

    private static func addresses(_ lines: [String], at url: URL) -> [URL?] {
        lines.map { $0.trimmingCharacters(in: .whitespaces) }.compactMap { line -> String? in
            guard line.hasPrefix("#") else { return line.isEmpty ? nil : line }
            guard let start = line.range(of: "URI=") else { return nil }
            let value = line[start.upperBound...]
            return value.hasPrefix("\"") ? String(value.dropFirst().prefix { $0 != "\"" }) : String(value.prefix { $0 != "," })
        }.map { URL(string: $0, relativeTo: url)?.absoluteURL }
    }

    private static func elsewhere(_ addresses: [URL?], from given: URL) -> Int {
        addresses.filter { $0.map { !HTTP.sameServer($0, given) } ?? true }.count
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

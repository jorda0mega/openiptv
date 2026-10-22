import Foundation

/// Emby lists the whole film whatever second it was asked from, and ffmpeg
/// reads a playlist's first segment before it jumps.
struct ConvertedPlaylist: Sendable {
    let segments: [(seconds: Double, tags: [String], url: URL)]
    let header: [String]

    enum Opening: Sendable {
        case listed(ConvertedPlaylist)
        case refused(String)
    }

    /// The player sends the key with every request for the version, so it
    /// opens only as listed again here, every address on the server the app
    /// was given.
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
        return listing(list.lines, at: list.url)
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

    /// Refused for a playlist that can't be listed again from elsewhere: one
    /// still growing (no end), with tags pointing to other addresses (keys,
    /// a first part to read before each segment), or a segment unread.
    static func listing(_ lines: [String], at url: URL) -> Opening {
        let lines = lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let tagged = lines.filter { $0.contains("URI=") }.count
        guard tagged == 0 else { return .refused("variant has \(tagged) URI= lines") }
        let masters = lines.filter { line in mastersTags.contains { line.uppercased().hasPrefix($0) } }.count
        guard masters == 0 else { return .refused("variant has \(masters) master tags") }
        var header: [String] = [], tags: [String] = [], segments: [(seconds: Double, tags: [String], url: URL)] = []
        var ended = false
        for line in lines {
            if line == "#EXT-X-ENDLIST" {
                ended = true
            } else if line.hasPrefix("#") {
                if segments.isEmpty, tags.isEmpty, !line.hasPrefix("#EXTINF:") { header.append(line) } else { tags.append(line) }
            } else {
                guard let seconds = tags.first(where: { $0.hasPrefix("#EXTINF:") }).flatMap({ Double($0.dropFirst(8).prefix { $0 != "," }) }),
                      let segment = URL(string: line, relativeTo: url)?.absoluteURL else {
                    return .refused("variant segment \(segments.count + 1) unread")
                }
                segments.append((seconds, tags, segment))
                tags = []
            }
        }
        guard ended else { return .refused("variant still growing at \(segments.count) segments") }
        guard !segments.isEmpty else { return .refused("variant lists no segments") }
        return .listed(ConvertedPlaylist(segments: segments, header: header))
    }

    /// A media playlist with one of these is read by the player as a master,
    /// and the playlists it names are read unchecked.
    private static let mastersTags = ["#EXT-X-STREAM-INF", "#EXT-X-I-FRAME-STREAM-INF", "#EXT-X-MEDIA:", "#EXT-X-SESSION-DATA",
                                      "#EXT-X-SESSION-KEY"]

    #if DEBUG
    /// The redirects counted for converted versions, and the segments asked.
    static let redirects = Locked((asked: 0, count: RedirectCount()))

    /// Debug builds (-debugRedirectCounts YES): the first segments listed
    /// from `second`, asked as the player asks them, following no redirect.
    @discardableResult
    static func countRedirects(_ list: ConvertedPlaylist, from second: Double, headers: [String], given: URL,
                               ask: (URLRequest) async -> HTTPURLResponse? = firstAnswer) async -> (asked: Int, count: RedirectCount) {
        var asked = 0, count = RedirectCount()
        for segment in list.segments[list.first(from: second).index...].prefix(3) {
            asked += 1
            guard let answer = await ask(request(segment.url, headers, given: given)), (300..<400).contains(answer.statusCode) else { continue }
            count.note(answer.value(forHTTPHeaderField: "Location").flatMap { URL(string: $0, relativeTo: segment.url)?.absoluteURL }, from: given)
        }
        redirects.mutate { $0 = ($0.asked + asked, $0.count + count) }
        return (asked, count)
    }

    private static func firstAnswer(_ request: URLRequest) async -> HTTPURLResponse? {
        guard let (bytes, response) = try? await HTTP.session.bytes(for: request, delegate: NoRedirect()) else { return nil }
        bytes.task.cancel()
        return response as? HTTPURLResponse
    }

    private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            nil
        }
    }
    #endif

    private func first(from second: Double) -> (index: Int, clockStart: Double) {
        var first = 0, clockStart = 0.0
        while first < segments.count - 1, clockStart + segments[first].seconds <= second {
            clockStart += segments[first].seconds
            first += 1
        }
        return (first, clockStart)
    }

    struct Listed: Sendable {
        let playlist: String
        let segments: [URL]
        let clockStart: Double
    }

    func listed(from second: Double) -> Listed {
        let (first, clockStart) = first(from: second)
        let tag = "#EXT-X-MEDIA-SEQUENCE:"
        let sequence = header.first { $0.hasPrefix(tag) }.flatMap { Int($0.dropFirst(tag.count)) } ?? 0
        let lines = header.filter { !$0.hasPrefix(tag) } + [tag + String(sequence + first)]
            + segments[first...].flatMap { $0.tags + [$0.url.absoluteString] } + ["#EXT-X-ENDLIST"]
        return Listed(playlist: lines.joined(separator: "\n") + "\n", segments: segments[first...].map(\.url), clockStart: clockStart)
    }
}

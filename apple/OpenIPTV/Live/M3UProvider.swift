import Foundation

/// M3U / M3U8 playlists (`#EXTINF` with tvg-* attributes). Categories come
/// from `group-title`, the guide from the playlist header (`url-tvg` /
/// `x-tvg-url`) or the guide URL the user entered.
final class M3UProvider: LiveProvider, @unchecked Sendable {
    let source: IPTVSource
    private let playlist: URL
    private let guide: URL?

    init(source: IPTVSource) {
        self.source = source
        guard case let .m3u(playlist, guide) = source.kind else { fatalError("not m3u") }
        self.playlist = playlist
        self.guide = guide
    }

    func load() async throws -> LiveLineup {
        let data = try await HTTP.data(playlist)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw SourceError.unexpected("The playlist couldn't be read.")
        }
        guard text.contains("#EXTINF") || text.contains("#EXTM3U") else {
            throw SourceError.unexpected("That address didn't return an M3U playlist.")
        }
        let secrets = (URLComponents(url: playlist, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .filter { ["username", "password", "user", "pass", "token"].contains($0.name.lowercased()) }
            .compactMap(\.value)
        let parsed = Self.parse(text, sourceId: source.id, secrets: secrets)
        var guides = guide.map { [$0] } ?? []
        if guides.isEmpty { guides = parsed.headerGuides }
        return LiveLineup(categories: parsed.categories, channels: parsed.channels, guideURLs: guides)
    }

    func playable(_ channel: LiveChannel) async throws -> PlayableStream {
        guard case let .url(url, userAgent, referrer) = channel.stream else { throw SourceError.unexpected("Not a playlist channel.") }
        var headers: [String] = []
        if let userAgent { headers.append("User-Agent: \(userAgent)") }
        if let referrer { headers.append("Referer: \(referrer)") }
        return PlayableStream(url: url, headers: headers)
    }

    struct Parsed {
        var categories: [LiveCategory]
        var channels: [LiveChannel]
        var headerGuides: [URL]
    }

    static func parse(_ text: String, sourceId: UUID, secrets: [String] = []) -> Parsed {
        var channels: [LiveChannel] = []
        var headerGuides: [URL] = []
        var counts: [String: Int] = [:]
        var order: [String] = []

        var attributes: [String: String] = [:]
        var name = ""
        var userAgent: String?
        var referrer: String?
        var group: String?
        var pending = false

        text.enumerateLines { rawLine, _ in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return }
            if line.hasPrefix("#EXTM3U") {
                let header = attributesAndName(String(line.dropFirst(7))).attributes
                for key in ["url-tvg", "x-tvg-url", "tvg-url"] {
                    for part in (header[key] ?? "").split(separator: ",") {
                        if let url = URL(string: part.trimmingCharacters(in: .whitespaces)) { headerGuides.append(url) }
                    }
                }
            } else if line.hasPrefix("#EXTINF:") {
                (attributes, name) = attributesAndName(String(line.dropFirst(8)))
                userAgent = nil
                referrer = nil
                group = nil
                pending = true
            } else if line.hasPrefix("#EXTVLCOPT:") {
                let option = line.dropFirst(11)
                if option.hasPrefix("http-user-agent=") { userAgent = String(option.dropFirst(16)) }
                if option.hasPrefix("http-referrer=") { referrer = String(option.dropFirst(14)) }
            } else if line.hasPrefix("#EXTGRP:") {
                group = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
            } else if !line.hasPrefix("#"), pending, let url = URL(string: line) {
                pending = false
                let title = name.isEmpty ? (attributes["tvg-name"] ?? "Channel") : name
                guard !AccountInfoFilter.looksLikeAccountInfo(title), !AccountInfoFilter.mentions(title, secrets: secrets) else { return }
                let groupName = attributes["group-title"].flatMap { $0.isEmpty ? nil : $0 } ?? group ?? "Uncategorised"
                let categoryId = "\(sourceId.uuidString)|\(groupName)"
                if counts[categoryId] == nil { order.append(categoryId) }
                counts[categoryId, default: 0] += 1
                channels.append(LiveChannel(
                    id: "\(sourceId.uuidString)|\(stableHash(line))", sourceId: sourceId,
                    number: attributes["tvg-chno"].flatMap { Int64($0) }, name: title,
                    logo: attributes["tvg-logo"].flatMap { $0.hasPrefix("http") ? URL(string: $0) : nil },
                    categoryId: categoryId, epgId: attributes["tvg-id"].flatMap { $0.isEmpty ? nil : $0 },
                    nativeId: attributes["tvg-id"] ?? "", stream: .url(url, userAgent: userAgent, referrer: referrer)
                ))
            }
        }
        let categories = order.compactMap { id -> LiveCategory? in
            let name = String(id.split(separator: "|", maxSplits: 1).last ?? "")
            guard !AccountInfoFilter.looksLikeAccountInfo(name) else { return nil }
            return LiveCategory(id: id, name: name, channels: counts[id] ?? 0)
        }
        let hidden = Set(order).subtracting(categories.map(\.id))
        return Parsed(categories: categories,
                      channels: channels.filter { !hidden.contains($0.categoryId ?? "") },
                      headerGuides: headerGuides)
    }

    /// `-1 tvg-id="x" group-title="News",BBC One` → (attributes, "BBC One").
    /// The name starts after the first comma outside quotes.
    static func attributesAndName(_ s: String) -> (attributes: [String: String], name: String) {
        var attributes: [String: String] = [:]
        var inQuotes = false
        var nameStart: String.Index?
        var key = ""
        var value = ""
        var readingValue = false
        var index = s.startIndex
        while index < s.endIndex {
            let ch = s[index]
            if ch == "\"" {
                if inQuotes {
                    attributes[key.lowercased()] = value
                    key = ""
                    value = ""
                    readingValue = false
                }
                inQuotes.toggle()
            } else if inQuotes {
                value.append(ch)
            } else if ch == "=" {
                readingValue = true
            } else if ch == "," {
                nameStart = s.index(after: index)
                break
            } else if ch == " " || ch == "\t" {
                if !readingValue { key = "" }
            } else if !readingValue {
                key.append(ch)
            }
            index = s.index(after: index)
        }
        let name = nameStart.map { String(s[$0...]).trimmingCharacters(in: .whitespaces) } ?? ""
        return (attributes, name)
    }

    /// FNV-1a; stable across launches so favourites survive playlist reloads.
    static func stableHash(_ s: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}

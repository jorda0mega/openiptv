#if DEBUG
import Foundation

enum PlaylistKeys {
    static func count(_ master: URL, headers: [String]) async -> String {
        guard headers.contains(where: { $0.hasPrefix("X-Emby-Token:") }) else { return "not an Emby stream" }
        guard let top = await read(master, headers) else { return "master unread" }
        let found = addresses(top)
        var keyed = 0, total = 0
        for uri in found.filter({ $0.lowercased().contains(".m3u8") }).prefix(3) {
            guard let variant = URL(string: uri, relativeTo: master)?.absoluteURL, let text = await read(variant, headers) else { continue }
            let inside = addresses(text)
            keyed += inside.filter(hasKey).count
            total += inside.count
        }
        return "master \(found.filter(hasKey).count)/\(found.count) variants \(keyed)/\(total)"
    }

    private static func hasKey(_ uri: String) -> Bool {
        uri.lowercased().contains("api_key=")
    }

    private static func addresses(_ playlist: String) -> [String] {
        playlist.components(separatedBy: .newlines).flatMap { line -> [String] in
            let line = line.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return [] }
            if !line.hasPrefix("#") { return [line] }
            guard let start = line.range(of: "URI=\"") else { return [] }
            return [String(line[start.upperBound...].prefix { $0 != "\"" })]
        }
    }

    /// The address without its key (the header carries it): a fetch that
    /// fails is logged by the system, address and all.
    static func keyless(_ url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.queryItems = parts.queryItems?.filter { $0.name.lowercased() != "api_key" }
        if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
        return parts.url
    }

    private static func read(_ url: URL, _ headers: [String]) async -> String? {
        guard let address = keyless(url) else { return nil }
        var request = URLRequest(url: address)
        request.timeoutInterval = 20
        for header in headers {
            let pair = header.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 { request.setValue(pair[1], forHTTPHeaderField: pair[0]) }
        }
        guard let (data, response) = try? await HTTP.session.data(for: request, delegate: HTTP.keyOutOfRedirects),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
#endif

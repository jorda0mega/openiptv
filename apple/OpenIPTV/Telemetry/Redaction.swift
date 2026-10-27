import Foundation

enum Redaction {
    static let removed = "[removed]"
    static let longest = 256

    static func clean(_ text: String) -> String {
        var afterKeyWord = false
        let cleaned = text.replacing(quoted, with: removed).replacing(#/\S+/#) { match in
            let word = match.output
            defer { afterKeyWord = word.wholeMatch(of: keyWord) != nil }
            return afterKeyWord || holdsAddress(word) || word.contains(longKey) ? removed : String(word)
        }
        return String(cleaned.prefix(longest))
    }

    static func holdsAddress(_ text: some StringProtocol) -> Bool {
        let text = Substring(text)
        return addressShapes.contains { text.contains($0) } || text.localizedCaseInsensitiveContains("localhost")
            || text.matches(of: #/[A-Za-z0-9.\-]+/#).contains { isHost($0.output) }
    }

    private static func isHost(_ run: Substring) -> Bool {
        run.trimmingCharacters(in: CharacterSet(charactersIn: ".")).wholeMatch(of: #/(?:[A-Za-z0-9\-]+\.)+(?:[A-Za-z]{2,}|xn--[A-Za-z0-9\-]+)/#) != nil
    }

    static func fileName(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? removed
    }

    private static let quoted = #/"[^"]*"|“[^”]*”|‘[^’]*’/#

    private static let addressShapes: [Regex<Substring>] = [
        #/:\/\/|^\/\/|(?i:www\.)/#,
        #/\d{1,3}(?:\.\d{1,3}){3}/#,
        #/::|[0-9A-Fa-f]{1,4}(?::[0-9A-Fa-f]{1,4}){2,}/#,
        #/[A-Za-z0-9\-]+:\d{2,5}(?!\d)/#,
        #/[=&]|\?\S/#,
        #/[^\/\s]\/[^\/\s]/#,
        #/[^@\s]@[^@\s]/#,
        #/%[0-9A-Fa-f]{2}/#,
    ]

    private static let longKey = #/(?=[A-Za-z0-9_\-]*\d)[A-Za-z0-9_\-]{24,}/#

    private static let keyWord = #/(?i)(?:api_?key|x-emby-token|x-emby-authorization|access_?token|token|password|passwd|pass|username|user|login|auth|authorization|key):/#
}

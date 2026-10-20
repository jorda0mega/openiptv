import Foundation

/// How a guide search matches: one rule for the search itself and for the
/// rows kept from an earlier search while the next one runs, so a kept row
/// is one the next answer has too.
enum GuideMatch {
    nonisolated static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// The words searched for: two letters or more, or a number.
    nonisolated static func words(_ query: String) -> [String] {
        fold(query).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.count >= 2 || $0.allSatisfy(\.isNumber) }
    }

    /// A programme not over yet with each word in its title or its channel's
    /// name, at least one in the title (title and channel folded).
    nonisolated static func programme(_ words: [String], title: String, channel: String?, stop: Int64, now: Int64) -> Bool {
        guard stop > now else { return false }
        var inTitle = false
        for word in words {
            if title.contains(word) {
                inTitle = true
            } else if channel?.contains(word) != true {
                return false
            }
        }
        return inTitle
    }

    /// A game still listed with each word in its title or league (folded).
    nonisolated static func game(_ words: [String], text: String, start: Int64?, now: Int64) -> Bool {
        if let start, now - start > Int64(GameTime.listed) { return false }
        return !words.isEmpty && words.allSatisfy(text.contains)
    }
}

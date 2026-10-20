import Foundation

enum SharedGuideRule {
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func words(in query: String) -> [String] {
        fold(query).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.count >= 2 || $0.allSatisfy(\.isNumber) }
    }

    static func findsProgramme(_ words: [String], title: String, channel: String?, stop: Int64, now: Int64) -> Bool {
        guard stop > now else { return false }
        var inTitle = false
        for word in words {
            if title.contains(word) { inTitle = true; continue }
            if channel?.contains(word) != true { return false }
        }
        return inTitle
    }

    static func findsGame(_ words: [String], text: String, start: Int64?, now: Int64) -> Bool {
        if let start, now - start > Int64(GameTime.listed) { return false }
        return !words.isEmpty && words.allSatisfy(text.contains)
    }
}

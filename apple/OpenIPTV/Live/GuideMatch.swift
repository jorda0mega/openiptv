import Foundation

enum GuideMatch {
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func words(_ query: String) -> [String] {
        fold(query).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.count >= 2 || $0.allSatisfy(\.isNumber) }
    }

    static func programme(_ words: [String], title: String, channel: String?, stop: Int64, now: Int64) -> Bool {
        guard stop > now else { return false }
        var inTitle = false
        for word in words {
            if title.contains(word) { inTitle = true; continue }
            if channel?.contains(word) != true { return false }
        }
        return inTitle
    }

    static func game(_ words: [String], text: String, start: Int64?, now: Int64) -> Bool {
        if let start, now - start > Int64(GameTime.listed) { return false }
        return !words.isEmpty && words.allSatisfy(text.contains)
    }
}

extension AppModel.GuideHit {
    func found(by words: [String], at now: Int64) -> Bool {
        if let league {
            return GuideMatch.game(words, text: GuideMatch.fold(title + " " + league), start: start, now: now)
        }
        return GuideMatch.programme(words, title: GuideMatch.fold(title), channel: GuideMatch.fold(channelTitle),
                                    stop: stop ?? .max, now: now)
    }
}

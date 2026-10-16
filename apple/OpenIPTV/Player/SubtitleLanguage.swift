import Foundation
import NaturalLanguage

/// The language a subtitle file is written in, told from its lines.
enum SubtitleLanguage {
    /// Whether `text`'s lines are clearly written in another language than
    /// `language` ("en", "es"): providers' files are labelled by whoever
    /// sent them, and a file offered as English can be Spanish. Nothing is
    /// told from lines too few or too plain to tell.
    static func writtenInAnother(_ language: String, _ text: String) -> Bool {
        let lines = text.components(separatedBy: .newlines).compactMap { line -> String? in
            // ASS: the words after the ninth comma.
            if line.hasPrefix("Dialogue:") { return line.split(separator: ",", maxSplits: 9, omittingEmptySubsequences: false).last.map(String.init) }
            let plain = line.trimmingCharacters(in: .whitespaces)
            guard !plain.isEmpty, !plain.contains("-->"), Int(plain) == nil, plain != "WEBVTT" else { return nil }
            return plain
        }
        let words = lines.prefix(400).joined(separator: " ")
            .replacingOccurrences(of: "<[^>]*>|\\{[^}]*\\}", with: "", options: .regularExpression)
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(words)
        guard let (found, share) = recognizer.languageHypotheses(withMaximum: 1).first else { return false }
        return share >= 0.8 && found.rawValue != language
    }
}

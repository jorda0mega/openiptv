#if DEBUG
import Foundation

/// When a film's subtitles get ready and show, from the Play tap: lines
/// "PERF subs <event> t=<ms since the tap> <key>=<value> …" in the log, and
/// all of them in the player's readout for the UI tests. Built from numbers
/// and fixed words only: the log must never hold an address, a key, a host,
/// an error (its description can carry the address) or a subtitle's text.
final class SubtitleStopwatch: @unchecked Sendable {
    enum Event: String {
        case tapped, loaded, tracks, fetched, added, shown, rebuffer
        case firstFrame = "first-frame", fetchFailed = "fetch-failed"
        case switched = "switch"
    }

    enum Key: String {
        case n, ms, bytes, track, after, late, kind, from, to, lang, text, picture, external, copies, hidden
    }

    enum Word: String {
        case yes, no, none, off, file, copy, own, picture
    }

    enum Value {
        case number(Int)
        case seconds(Double)
        case word(Word)
        case language(String?)

        fileprivate var text: String {
            switch self {
            case let .number(number): String(number)
            case let .seconds(seconds): String(Int((seconds * 1000).rounded()))
            case let .word(word): word.rawValue
            case .language(nil): "none"
            case let .language(code?) where code.count <= 8 && code.allSatisfy({ $0.isASCII && ($0.isLowercase || $0.isNumber || $0 == "-") }): code
            case .language: "other"
            }
        }
    }

    private typealias Line = (at: CFAbsoluteTime, event: Event, fields: String)
    private let lock = NSLock()
    private var tap: CFAbsoluteTime?
    private var lines: [Line] = []

    func note(_ event: Event, _ fields: KeyValuePairs<Key, Value> = [:]) {
        record((CFAbsoluteTimeGetCurrent(), event, fields.map { " \($0.key.rawValue)=\($0.value.text)" }.joined()))
    }

    /// Lines noted before the tap (a film opened ahead) are logged now.
    func tapped(at time: CFAbsoluteTime) {
        let before = lock.withLock { () -> [Line] in
            tap = time
            return lines
        }
        for line in before { NSLog("%@", "PERF subs " + Self.format(line, since: time)) }
        record((time, .tapped, ""))
    }

    var readout: String {
        lock.withLock {
            guard let tap else { return "" }
            return lines.sorted { $0.at < $1.at }.map { Self.format($0, since: tap) }.joined(separator: " | ")
        }
    }

    private func record(_ line: Line) {
        let tap = lock.withLock { () -> CFAbsoluteTime? in
            lines.append(line)
            return self.tap
        }
        if let tap { NSLog("%@", "PERF subs " + Self.format(line, since: tap)) }
    }

    private static func format(_ line: Line, since tap: CFAbsoluteTime) -> String {
        "\(line.event.rawValue) t=\(Value.seconds(line.at - tap).text)\(line.fields)"
    }
}
#endif

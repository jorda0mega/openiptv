import Foundation

/// Which load libmpv's events belong to. It keeps sending a replaced file's
/// events after the next file is asked for, until that one starts; it tells
/// a file's first picture with the same event as a jump's; and it hands over
/// its log lines only after the events queued with them, so a line read
/// after a file started may be the file before's.
struct LoadEvents {
    private var entries: [Int64: Int] = [:]
    private(set) var current = 0
    private var pictured = true
    private var startedSinceDrain = false

    mutating func asked(_ attempt: Int, entry: Int64?) {
        guard let entry else {
            current = attempt
            pictured = false
            return
        }
        entries[entry] = attempt
    }

    @discardableResult
    mutating func started(entry: Int64) -> Int? {
        guard let attempt = entries[entry] else { return nil }
        entries = entries.filter { $0.key >= entry }
        current = attempt
        pictured = false
        startedSinceDrain = true
        return attempt
    }

    mutating func drainBegan() {
        startedSinceDrain = false
    }

    var logAttempt: Int? {
        startedSinceDrain ? nil : current
    }

    /// The load whose first picture this is; nil for a jump.
    mutating func restarted() -> Int? {
        guard !pictured else { return nil }
        pictured = true
        return current
    }

    mutating func ended(entry: Int64) -> Int {
        entries.removeValue(forKey: entry) ?? current
    }
}

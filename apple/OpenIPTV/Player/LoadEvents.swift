import Foundation

/// Which load libmpv's events belong to. It keeps sending a replaced file's
/// events after the next file is asked for, until that one starts, and it
/// tells a file's first picture with the same event as a jump's.
struct LoadEvents {
    private var entries: [Int64: Int] = [:]
    private(set) var current = 0
    private var pictured = true

    mutating func asked(_ attempt: Int, entry: Int64?) {
        guard let entry else {
            current = attempt
            pictured = false
            return
        }
        entries[entry] = attempt
    }

    mutating func started(entry: Int64) {
        guard let attempt = entries[entry] else { return }
        current = attempt
        pictured = false
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

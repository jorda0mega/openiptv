import Foundation

enum Scrubber {
    static let removed = "[removed]"
    static let longest = 256

    static func clean(_ text: String) -> String {
        text
    }

    static func holdsAddress(_ text: String) -> Bool {
        false
    }

    static func fileName(_ path: String) -> String {
        path
    }
}

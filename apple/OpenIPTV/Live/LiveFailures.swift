import Foundation

struct LiveFailures {
    static let didNotPlay = "Didn’t play"

    private var noted: [String: Date] = [:]

    var ids: Set<String> { Set(noted.keys) }

    func contains(_ id: String) -> Bool { noted[id] != nil }

    mutating func note(_ id: String, at date: Date = Date()) -> Date {
        noted[id] = date
        return date
    }

    mutating func played(_ id: String) {
        noted[id] = nil
    }

    mutating func expire(_ id: String, noted date: Date) {
        if noted[id] == date { noted[id] = nil }
    }

    func failed(_ ids: [String], playing: String? = nil) -> Bool {
        !ids.isEmpty && !ids.contains { $0 == playing } && ids.allSatisfy(contains)
    }
}

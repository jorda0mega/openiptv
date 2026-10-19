import Foundation

struct LiveFailures {
    static let didNotPlay = "Didn’t play"

    struct Expiry {
        let id: String
        let noted: Date
    }

    private var noted: [String: Date] = [:]

    var ids: Set<String> { Set(noted.keys) }

    func contains(_ id: String) -> Bool { noted[id] != nil }

    mutating func note(_ id: String, at date: Date = Date()) -> Expiry {
        noted[id] = date
        return Expiry(id: id, noted: date)
    }

    mutating func played(_ id: String) {
        noted[id] = nil
    }

    mutating func expire(_ expiry: Expiry) {
        if noted[expiry.id] == expiry.noted { noted[expiry.id] = nil }
    }

    func failedLast<Copy: Identifiable>(_ copies: [Copy]) -> [Copy] where Copy.ID == String {
        copies.filter { !contains($0.id) } + copies.filter { contains($0.id) }
    }

    func failed(_ ids: [String], playingCopy: String? = nil) -> Bool {
        !ids.isEmpty && !ids.contains { $0 == playingCopy } && ids.allSatisfy(contains)
    }
}

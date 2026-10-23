#if DEBUG
import Foundation

enum AheadTaken {
    enum Part { case open, rest }

    static func note(_ itemId: String, _ part: Part, bytes: Int) {}

    static func readout(_ itemId: String) -> String {
        "took ahead: open 0.00 MB in 0 reads, rest 0.00 MB in 0 reads"
    }

    static func itemId(in address: URL) -> String? { nil }
}
#endif

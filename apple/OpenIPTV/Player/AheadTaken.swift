#if DEBUG
import Foundation

/// Debug builds: what each title took off the network before its tap. The
/// open's own reads (the fetch ahead's header, index and tags, and start)
/// apart from the rest (connections kept open, subtitles, preview stills).
/// Plans and pages are not counted.
enum AheadTaken {
    enum Part { case open, rest }

    private struct Taken {
        var reads = 0
        var bytes: Int64 = 0
    }

    private static let taken = Locked([String: [Part: Taken]]())

    static func note(_ itemId: String, _ part: Part, bytes: Int) {
        taken.mutate {
            $0[itemId, default: [:]][part, default: Taken()].reads += 1
            $0[itemId, default: [:]][part, default: Taken()].bytes += Int64(bytes)
        }
    }

    static func readout(_ itemId: String) -> String {
        let parts = taken.value[itemId] ?? [:]
        func said(_ part: Part) -> String {
            let one = parts[part] ?? Taken()
            return String(format: "%.2f MB in %d read%@", Double(one.bytes) / 1e6, one.reads, one.reads == 1 ? "" : "s")
        }
        return "took ahead: open \(said(.open)), rest \(said(.rest))"
    }

    /// Emby's addresses for a title's files name it after "Videos".
    static func itemId(in address: URL) -> String? {
        let parts = address.pathComponents
        guard let videos = parts.firstIndex(of: "Videos"), videos + 1 < parts.count else { return nil }
        return parts[videos + 1]
    }
}
#endif

import Foundation

/// What's been fetched of one file, kept in a sparse temporary file (only
/// the bytes written take space), up to 1 GB; past that, the bytes
/// farthest from the newest are let go, but never those fetched ahead.
final class ByteCache: @unchecked Sendable {
    private static let folder = FileManager.default.temporaryDirectory.appending(path: "relay-cache")
    static let limit: Int64 = 1 << 30

    private let limit: Int64
    private let lock = NSLock()
    private let path: URL
    private let handle: FileHandle
    private var ranges: [Range<Int64>] = []
    private var fetchedAhead: [Range<Int64>] = []
    private var stored: Int64 = 0
    private(set) var total: Int64?
    private(set) var contentType: String?

    init?(limit: Int64 = ByteCache.limit) {
        self.limit = limit
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        path = Self.folder.appending(path: UUID().uuidString)
        guard FileManager.default.createFile(atPath: path.path(), contents: nil),
              let handle = try? FileHandle(forUpdating: path) else { return nil }
        self.handle = handle
    }

    deinit {
        try? handle.close()
        try? FileManager.default.removeItem(at: path)
    }

    /// Files left from a run that ended without cleaning up.
    static func removeLeftovers() {
        try? FileManager.default.removeItem(at: folder)
    }

    func noteFile(total: Int64, contentType: String?) {
        lock.withLock {
            if self.total == nil { self.total = total }
            if self.contentType == nil { self.contentType = contentType }
        }
    }

    /// How many bytes are kept from `offset` on, in one run.
    func available(from offset: Int64) -> Int64 {
        lock.withLock { ranges.first { $0.contains(offset) }.map { $0.upperBound - offset } ?? 0 }
    }

    func read(_ offset: Int64, _ count: Int) -> Data? {
        lock.withLock {
            guard let range = ranges.first(where: { $0.contains(offset) }), offset + Int64(count) <= range.upperBound else { return nil }
            try? handle.seek(toOffset: UInt64(offset))
            guard let data = try? handle.read(upToCount: count), data.count == count else { return nil }
            return data
        }
    }

    /// Whether the file's index is still to be fetched (true once).
    func claimIndex() -> Bool {
        lock.withLock {
            defer { indexClaimed = true }
            return !indexClaimed
        }
    }
    private var indexClaimed = false

    /// `evicting`: may let the bytes farthest from these go to make room.
    /// `false`, fetched ahead (the file's start, its index and tags, where it
    /// resumes): lets nothing go, as the index is far from where the film
    /// plays, and is never let go itself.
    func store(_ data: Data, at offset: Int64, evicting: Bool = true) {
        let end = offset + Int64(data.count)
        lock.withLock {
            if evicting { makeRoom(for: Int64(data.count), near: offset) }
            guard stored + Int64(data.count) <= limit else { return }
            do {
                try handle.seek(toOffset: UInt64(offset))
                try handle.write(contentsOf: data)
            } catch { return }
            ranges = Self.adding(offset..<end, to: ranges)
            stored = ranges.reduce(0) { $0 + Int64($1.count) }
            if !evicting { fetchedAhead = Self.adding(offset..<end, to: fetchedAhead) }
        }
    }

    /// Merges a run of bytes with those it touches.
    private static func adding(_ new: Range<Int64>, to ranges: [Range<Int64>]) -> [Range<Int64>] {
        var merged = new
        var kept: [Range<Int64>] = []
        for range in ranges {
            if range.upperBound < merged.lowerBound || range.lowerBound > merged.upperBound {
                kept.append(range)
            } else {
                merged = min(range.lowerBound, merged.lowerBound)..<max(range.upperBound, merged.upperBound)
            }
        }
        kept.append(merged)
        return kept.sorted { $0.lowerBound < $1.lowerBound }
    }

    private static func removing(_ cut: Range<Int64>, from ranges: [Range<Int64>]) -> [Range<Int64>] {
        ranges.flatMap { [$0.clamped(to: Int64.min..<cut.lowerBound), $0.clamped(to: cut.upperBound..<Int64.max)] }.filter { !$0.isEmpty }
    }

    /// mpv reads again from ten seconds back for a track it hasn't been
    /// reading, so the bytes near `offset` stay.
    private func makeRoom(for count: Int64, near offset: Int64) {
        #if DEBUG
        if Self.oldRule { return oldMakeRoom(for: count, near: offset) }
        #endif
        let step: Int64 = 1 << 20
        while stored + count > limit {
            let free = fetchedAhead.reduce(ranges) { Self.removing($1, from: $0) }
            guard let first = free.first, let last = free.last else { return }
            let excess = stored + count - limit
            let cut = offset - first.lowerBound >= last.upperBound - offset
                ? first.lowerBound..<min(first.upperBound, (first.lowerBound + excess + step - 1) / step * step)
                : max(last.lowerBound, (last.upperBound - excess) / step * step)..<last.upperBound
            punch(cut)
            ranges = Self.removing(cut, from: ranges)
            stored = ranges.reduce(0) { $0 + Int64($1.count) }
        }
    }

    /// Gives these bytes' disk space back: whole blocks only, the file
    /// system frees no part of one.
    private func punch(_ bytes: Range<Int64>) {
        let block: Int64 = 4096
        let from = (bytes.lowerBound + block - 1) / block * block, to = bytes.upperBound / block * block
        guard to > from else { return }
        var hole = fpunchhole_t(fp_flags: 0, reserved: 0, fp_offset: off_t(from), fp_length: off_t(to - from))
        _ = fcntl(handle.fileDescriptor, F_PUNCHHOLE, &hole)
    }

    #if DEBUG
    /// The rule before (-oldRelayCache YES, a real run before and after):
    /// only runs ending 64 MB before `offset` went. A film read straight
    /// through is one run, so full, it kept nothing new until the player was
    /// 64 MB further, then let all of it go.
    private static let oldRule = UserDefaults.standard.bool(forKey: "oldRelayCache")

    private func oldMakeRoom(for count: Int64, near offset: Int64) {
        guard stored + count > limit else { return }
        for range in ranges where range.upperBound <= offset - (64 << 20) { punch(range) }
        ranges.removeAll { $0.upperBound <= offset - (64 << 20) }
        stored = ranges.reduce(0) { $0 + Int64($1.count) }
    }
    #endif
}

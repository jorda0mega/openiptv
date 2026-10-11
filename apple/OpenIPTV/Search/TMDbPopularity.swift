import Foundation

/// How popular every movie and show is right now, from TMDb's public daily
/// exports (`movie_ids_…json.gz` and `tv_series_ids_…json.gz`, no account or
/// key). TMDb's popularity follows what people are watching and looking up
/// this week, so an older film that's trending again rises too. Downloaded
/// at most weekly (about 33 MB) and kept as a small memory-mapped file of
/// the titles scoring 1 or more, looked up by binary search.
struct TMDbPopularity: Sendable {
    enum Kind { case movie, show }

    private static let file = "tmdb-popularity.bin"
    private static let magic: [UInt8] = Array("TMP1".utf8)
    /// TMDb id, popularity.
    private static let recordSize = 8

    private let data: Data
    private let movies: Int
    private let shows: Int

    private init?(data: Data) {
        guard data.count >= 12, Array(data.prefix(4)) == Self.magic else { return nil }
        let movies = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian })
        let shows = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian })
        guard data.count == 12 + (movies + shows) * Self.recordSize else { return nil }
        self.data = data
        self.movies = movies
        self.shows = shows
    }

    /// TMDb's popularity score (1 is obscure, 7.5 is about the top 5,000
    /// films, 50 the top 100), or nil when below 1 or unknown.
    func popularity(_ id: Int?, _ kind: Kind) -> Double? {
        guard let id, id > 0, id <= Int(UInt32.max) else { return nil }
        let first = kind == .movie ? 0 : movies
        let count = kind == .movie ? movies : shows
        let target = UInt32(id)
        return data.withUnsafeBytes { raw -> Double? in
            var low = 0, high = count - 1
            while low <= high {
                let mid = (low + high) / 2
                let at = 12 + (first + mid) * Self.recordSize
                let found = raw.loadUnaligned(fromByteOffset: at, as: UInt32.self).littleEndian
                if found == target {
                    return Double(Float(bitPattern: raw.loadUnaligned(fromByteOffset: at + 4, as: UInt32.self).littleEndian))
                }
                if found < target { low = mid + 1 } else { high = mid - 1 }
            }
            return nil
        }
    }

    func popularity(_ entry: LibraryEntry) -> Double? {
        popularity(entry.tmdb, entry.kind == "Series" ? .show : .movie)
    }

    // MARK: On disk

    private static var url: URL { AppCache.directory.appending(path: file) }

    static func cached() -> TMDbPopularity? {
        (try? Data(contentsOf: url, options: .alwaysMapped)).flatMap(TMDbPopularity.init(data:))
    }

    static func age() -> TimeInterval? {
        guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
        return Date().timeIntervalSince(date)
    }

    /// Downloads the latest exports and replaces the copy on the device.
    static func download() async throws -> TMDbPopularity {
        async let movies = table("movie_ids")
        async let shows = table("tv_series_ids")
        let (m, s) = try await (movies, shows)
        var out = Data(magic)
        out.reserveCapacity(12 + (m.count + s.count) * recordSize)
        for count in [m.count, s.count] {
            withUnsafeBytes(of: UInt32(count).littleEndian) { out.append(contentsOf: $0) }
        }
        for value in m + s {
            withUnsafeBytes(of: UInt32(value >> 32).littleEndian) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt32(value & 0xFFFF_FFFF).littleEndian) { out.append(contentsOf: $0) }
        }
        try out.write(to: url, options: [.atomic])
        guard let popularity = cached() else { throw URLError(.cannotDecodeContentData) }
        return popularity
    }

    /// One export as sorted (id << 32 | popularity bits). TMDb publishes
    /// each day's file in the morning (UTC), so try yesterday's, then the
    /// day before.
    private static func table(_ name: String) async throws -> [UInt64] {
        var lastError: Error = URLError(.fileDoesNotExist)
        for daysAgo in 1...2 {
            let day = Date().addingTimeInterval(-Double(daysAgo) * 86_400)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            let stamp = String(format: "%02d_%02d_%04d", parts.month ?? 1, parts.day ?? 1, parts.year ?? 2000)
            let source = URL(string: "https://files.tmdb.org/p/exports/\(name)_\(stamp).json.gz")!
            do {
                let (temporary, response) = try await URLSession.shared.download(from: source)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.fileDoesNotExist) }
                return try parse(Data(contentsOf: temporary, options: .alwaysMapped))
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// `{"adult":false,"id":238,"original_title":"…","popularity":59.01,…}`
    /// per line; keeps titles scoring 1 or more, leaves out adult ones.
    private static func parse(_ gzip: Data) throws -> [UInt64] {
        let idKey = Array("\"id\":".utf8), popularityKey = Array("\"popularity\":".utf8)
        let adult = Array("\"adult\":true".utf8)
        var out: [UInt64] = []
        out.reserveCapacity(300_000)
        try Gzip.lines(gzip) { line in
            guard let idAt = find(idKey, in: line), let popularityAt = find(popularityKey, in: line),
                  find(adult, in: line) == nil else { return }
            var i = idAt, id: UInt32 = 0
            while i < line.count, line[i] >= 48, line[i] <= 57 { id = id &* 10 &+ UInt32(line[i] - 48); i += 1 }
            var j = popularityAt
            while j < line.count, line[j] == 45 || line[j] == 46 || line[j] == 101 || line[j] == 69 || line[j] == 43
                    || (line[j] >= 48 && line[j] <= 57) { j += 1 }
            guard id > 0, let popularity = Float(String(decoding: line[popularityAt..<j], as: UTF8.self)),
                  popularity >= 1 else { return }
            out.append(UInt64(id) << 32 | UInt64(popularity.bitPattern))
        }
        guard out.count > 10_000 else { throw URLError(.cannotDecodeContentData) }
        out.sort()
        return out
    }

    /// Index just past `needle` in `line`.
    private static func find(_ needle: [UInt8], in line: [UInt8]) -> Int? {
        let n = needle.count
        guard line.count >= n else { return nil }
        var i = 0
        while i <= line.count - n {
            if line[i] == needle[0] {
                var k = 1
                while k < n, line[i + k] == needle[k] { k += 1 }
                if k == n { return i + n }
            }
            i += 1
        }
        return nil
    }
}

import Foundation

/// IMDb's rating and vote count for every title with at least ten votes,
/// from IMDb's public dataset (`title.ratings.tsv.gz`, which IMDb updates
/// daily). Downloaded at most weekly and kept on the device as a compact
/// file that's memory-mapped, not loaded: 1.4 million titles, looked up by
/// binary search. Ranks search by popularity and shows IMDb scores.
///
/// IMDb's datasets are for personal, non-commercial use, credited in
/// Settings ("Information courtesy of IMDb").
struct IMDbRatings: Sendable {
    struct Rating: Sendable, Hashable {
        /// Out of ten, one decimal.
        let score: Double
        let votes: Int
    }

    private static let source = URL(string: "https://datasets.imdbws.com/title.ratings.tsv.gz")!
    private static let file = "imdb-ratings.bin"
    private static let magic: [UInt8] = Array("IMR1".utf8)
    /// Title number (tt0076759 → 76759), votes, score × 10.
    private static let recordSize = 9

    private let data: Data
    private let count: Int

    private init?(data: Data) {
        guard data.count >= 8, Array(data.prefix(4)) == Self.magic else { return nil }
        let count = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian })
        guard data.count == 8 + count * Self.recordSize else { return nil }
        self.data = data
        self.count = count
    }

    func rating(_ imdbId: String?) -> Rating? {
        guard let imdbId, let number = Self.number(imdbId) else { return nil }
        return rating(number: number)
    }

    /// By title number (tt0076759 → 76759).
    func rating(number: UInt32) -> Rating? {
        data.withUnsafeBytes { raw -> Rating? in
            func id(_ i: Int) -> UInt32 { raw.loadUnaligned(fromByteOffset: 8 + i * Self.recordSize, as: UInt32.self).littleEndian }
            var low = 0, high = count - 1
            while low <= high {
                let mid = (low + high) / 2
                let found = id(mid)
                if found == number {
                    let at = 8 + mid * Self.recordSize
                    let votes = raw.loadUnaligned(fromByteOffset: at + 4, as: UInt32.self).littleEndian
                    return Rating(score: Double(raw[at + 8]) / 10, votes: Int(votes))
                }
                if found < number { low = mid + 1 } else { high = mid - 1 }
            }
            return nil
        }
    }

    /// 0–650: how much a title is being watched. Half lasting fame (all its
    /// votes), half how fast it gathered them (votes per year since it came
    /// out), so this year's hit can outrank an older title with more votes
    /// in total. Titles IMDb doesn't know about get a modest 200.
    func popularity(_ imdbId: String?, year: Int?, currentYear: Int) -> Int {
        guard let rating = rating(imdbId) else { return 200 }
        let votes = Double(rating.votes)
        let years = max(0.5, Double(currentYear - (year ?? currentYear)) + 0.5)
        let fame = log10(1 + votes), heat = log10(1 + votes / years)
        return min(650, max(0, Int((0.4 * fame + 0.6 * heat) / 6.5 * 650)))
    }

    /// "IMDb 7.4"
    static func label(_ rating: Rating) -> String {
        "IMDb " + rating.score.formatted(.number.precision(.fractionLength(1)))
    }

    /// "IMDb 7.4 · 345K ratings"
    static func detail(_ rating: Rating) -> String {
        label(rating) + " · " + rating.votes.formatted(.number.notation(.compactName)) + " ratings"
    }

    static func number(_ imdbId: String) -> UInt32? {
        let digits = imdbId.hasPrefix("tt") ? imdbId.dropFirst(2) : imdbId[...]
        return UInt32(digits)
    }

    // MARK: On disk

    private static var url: URL { AppCache.directory.appending(path: file) }

    /// The copy on the device, if any.
    static func cached() -> IMDbRatings? {
        (try? Data(contentsOf: url, options: .alwaysMapped)).flatMap(IMDbRatings.init(data:))
    }

    /// How long ago the copy on the device was downloaded.
    static func age() -> TimeInterval? {
        guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
        return Date().timeIntervalSince(date)
    }

    /// Downloads today's dataset (about 9 MB) and replaces the copy on the
    /// device.
    static func download() async throws -> IMDbRatings {
        let (temporary, response) = try await URLSession.shared.download(from: source)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        let compressed = try Data(contentsOf: temporary, options: .alwaysMapped)
        let records = try convert(gzip: compressed)
        try records.write(to: url, options: [.atomic])
        guard let ratings = cached() else { throw URLError(.cannotDecodeContentData) }
        return ratings
    }

    /// The TSV (`tt0000001\t5.7\t2232` per line) to fixed-size records
    /// sorted by title number, decompressing as it goes. (IMDb sorts as
    /// text, so tt10000000 comes before tt1000001.)
    private static func convert(gzip: Data) throws -> Data {
        // Title number, score and votes packed so sorting orders by title.
        var packed: [UInt64] = []
        packed.reserveCapacity(1_500_000)
        try Gzip.lines(gzip) { line in
            // "tt" digits TAB score TAB votes
            guard line.count > 6, line[0] == 116, line[1] == 116 else { return }
            var i = 2, id: UInt32 = 0
            while i < line.count, line[i] != 9 { id = id &* 10 &+ UInt32(line[i] &- 48); i += 1 }
            i += 1
            var score: UInt32 = 0
            while i < line.count, line[i] != 9 {
                if line[i] != 46 { score = score * 10 + UInt32(line[i] &- 48) }
                i += 1
            }
            i += 1
            var votes: UInt32 = 0
            while i < line.count, line[i] >= 48, line[i] <= 57 { votes = votes &* 10 &+ UInt32(line[i] - 48); i += 1 }
            guard votes >= 10, score <= 100 else { return }
            packed.append(UInt64(id) << 32 | UInt64(score) << 24 | UInt64(min(votes, 0xFF_FFFF)))
        }
        guard packed.count > 100_000 else { throw URLError(.cannotDecodeContentData) }
        packed.sort()

        var out = Data(magic)
        out.reserveCapacity(8 + packed.count * recordSize)
        withUnsafeBytes(of: UInt32(packed.count).littleEndian) { out.append(contentsOf: $0) }
        for value in packed {
            withUnsafeBytes(of: UInt32(value >> 32).littleEndian) { out.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt32(value & 0xFF_FFFF).littleEndian) { out.append(contentsOf: $0) }
            out.append(UInt8(value >> 24 & 0xFF))
        }
        return out
    }
}

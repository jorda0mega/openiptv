import Foundation

/// IMDb's genres, first year and makers (directors and writers) for the
/// titles in this library, from IMDb's public datasets (`title.basics` and
/// `title.crew`), kept to just those titles: what "Top picks for you" and
/// "More like this" match on. The datasets are large (about 300 MB
/// together), so they're fetched on Wi-Fi about monthly (sooner when many
/// of the library's titles are missing), read as they decompress, and only
/// the library's few thousand titles are kept.
///
/// IMDb's datasets are for personal, non-commercial use, credited in
/// Settings ("Information courtesy of IMDb").
struct IMDbCatalog: Codable, Sendable {
    struct Title: Codable, Sendable {
        var genres: [String] = []
        var year: Int?
        var series = false
        var directors: [UInt32] = []
        var writers: [UInt32] = []
    }

    /// By title number (tt0076759 → 76759).
    let titles: [UInt32: Title]
    /// The title numbers it was made for (the library's at the time).
    let asked: Set<UInt32>
    let builtAt: Date

    private static let file = "imdb-catalog.json"
    private static let basics = URL(string: "https://datasets.imdbws.com/title.basics.tsv.gz")!
    private static let crew = URL(string: "https://datasets.imdbws.com/title.crew.tsv.gz")!

    func title(_ imdbId: String?) -> Title? {
        imdbId.flatMap(IMDbRatings.number).flatMap { titles[$0] }
    }

    /// The share of these title numbers it was made for (titles added to
    /// the library since are missing; a title IMDb doesn't list stays
    /// missing however often it's fetched).
    func coverage(of wanted: Set<UInt32>) -> Double {
        guard !wanted.isEmpty else { return 1 }
        return Double(wanted.intersection(asked).count) / Double(wanted.count)
    }

    // MARK: On disk

    static func cached() -> IMDbCatalog? { AppCache.read(file) }

    /// Downloads both datasets and keeps these titles (by number). Stops
    /// (CancellationError) when cancelled or something starts playing,
    /// downloading or reading: the stream gets the connection and the
    /// processor; a dataset already downloaded is kept for next time.
    static func build(for wanted: Set<UInt32>) async throws -> IMDbCatalog {
        var titles: [UInt32: Title] = [:]
        titles.reserveCapacity(wanted.count)
        // tconst titleType primaryTitle originalTitle isAdult startYear endYear runtimeMinutes genres
        try await read(basics, keeping: wanted.contains) { id, fields in
            guard fields.count >= 9 else { return }
            let type = String(decoding: fields[1], as: UTF8.self)
            titles[id] = Title(genres: list(fields[8]).map { String(decoding: $0, as: UTF8.self) },
                               year: Int(String(decoding: fields[5], as: UTF8.self)),
                               series: type == "tvSeries" || type == "tvMiniSeries")
        }
        // tconst directors writers
        try await read(crew, keeping: { titles[$0] != nil }) { id, fields in
            guard fields.count >= 3 else { return }
            titles[id]?.directors = list(fields[1]).compactMap(number)
            titles[id]?.writers = list(fields[2]).compactMap(number)
        }
        for url in [basics, crew] { try? FileManager.default.removeItem(at: local(url)) }
        guard !titles.isEmpty else { throw URLError(.cannotDecodeContentData) }
        let catalog = IMDbCatalog(titles: titles, asked: wanted, builtAt: Date())
        AppCache.save(file, catalog)
        return catalog
    }

    /// Where a dataset is kept until the catalog is made from it: one copy,
    /// used again if the app closed while reading it (rather than
    /// downloaded again, or left behind in the temporary folder).
    private static func local(_ url: URL) -> URL {
        AppCache.directory.appending(path: "imdb-" + url.lastPathComponent)
    }

    /// Downloads a dataset to a temporary file and reads it line by line as
    /// it decompresses: the lines of the titles kept (by number), split at
    /// their tabs (only those: the datasets have millions of lines).
    private static func read(_ url: URL, keeping keep: (UInt32) -> Bool,
                             _ each: (UInt32, [ArraySlice<UInt8>]) -> Void) async throws {
        let file = local(url)
        let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            .map { Date().timeIntervalSince($0) }
        if age.map({ $0 > 7 * 24 * 3600 }) ?? true {
            let download = Task { try await URLSession.shared.download(from: url) }
            // Something starts playing: the download stops at once.
            let watch = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    if PlaybackActivity.isPlaying { return download.cancel() }
                }
            }
            defer { watch.cancel() }
            let (temporary, response) = try await withTaskCancellationHandler {
                try await download.value
            } onCancel: {
                download.cancel()
            }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                try? FileManager.default.removeItem(at: temporary)
                throw URLError(.badServerResponse)
            }
            try? FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: temporary, to: file)
        }
        do {
            let compressed = try Data(contentsOf: file, options: .alwaysMapped)
            try Gzip.lines(compressed, stop: { Task.isCancelled || PlaybackActivity.isPlaying }) { line in
                // Only data lines ("tt…"), not the header.
                guard line.count > 2, line[0] == 116, line[1] == 116,
                      let id = number(line[..<(line.firstIndex(of: 9) ?? line.endIndex)]), keep(id) else { return }
                each(id, line[...].split(separator: 9, omittingEmptySubsequences: false))
            }
        } catch is CancellationError {
            // Stopped: the file is fine, and read again next time.
            throw CancellationError()
        } catch {
            // Damaged: downloaded again next time.
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    /// "tt0076759" or "nm0000184" → 76759 / 184.
    private static func number(_ field: ArraySlice<UInt8>) -> UInt32? {
        guard field.count > 2 else { return nil }
        var value: UInt32 = 0
        for byte in field.dropFirst(2) {
            guard byte >= 48, byte <= 57 else { return nil }
            value = value &* 10 &+ UInt32(byte - 48)
        }
        return value
    }

    /// A comma-separated field ("\N" is none).
    private static func list(_ field: ArraySlice<UInt8>) -> [ArraySlice<UInt8>] {
        guard !(field.count == 2 && field.first == 92) else { return [] }
        return field.split(separator: 44)
    }
}

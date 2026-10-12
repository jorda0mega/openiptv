import Foundation

/// The library index on the device, compactly: a small JSON header, then
/// every title as length-prefixed fields, read with a cursor over the
/// mapped file. It's read at every launch before search and Home's refresh
/// can use it; for a library of 129,000 titles JSON decoding took about
/// 350 ms on a Mac (more on an Apple TV).
enum LibraryIndexFile {
    struct Header: Codable {
        var version: Int?
        let server: String
        let syncedAt: Date?
        let fullSyncAt: Date?
        let total: Int?
        /// Each page's start and number of titles, in order.
        let pages: [[Int]]
    }

    private static let magic: [UInt8] = Array("LIX1".utf8)
    /// The fewest bytes a title takes (empty strings, no genres): a page
    /// claiming more titles than the rest of the file could hold is damage.
    private static let smallestEntry = 31

    static func encode(_ header: Header, pages: [Int: [LibraryEntry]]) -> Data? {
        guard let head = try? JSONEncoder().encode(header) else { return nil }
        var out: [UInt8] = []
        out.reserveCapacity(head.count + pages.values.reduce(0) { $0 + $1.count } * 160)
        out += magic
        put32(UInt32(head.count), &out)
        out += head
        for page in header.pages {
            for entry in pages[page[0]] ?? [] {
                put(entry.id, &out)
                put(entry.name, &out)
                put(entry.kind, &out)
                put32(entry.year.map { UInt32(bitPattern: Int32(clamping: $0)) } ?? .max, &out)
                put(entry.imageTag, &out)
                put64(entry.aspect.map(\.bitPattern) ?? Double.nan.bitPattern, &out)
                put(entry.imdb, &out)
                put64(entry.tmdb.map { UInt64(bitPattern: Int64($0)) } ?? .max, &out)
                if let genres = entry.genres {
                    out.append(UInt8(min(genres.count, 254)))
                    for genre in genres.prefix(254) { put(genre, &out) }
                } else {
                    out.append(255)
                }
            }
        }
        return Data(out)
    }

    static func decode(_ data: Data) -> (Header, [Int: [LibraryEntry]])? {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> (Header, [Int: [LibraryEntry]])? in
            var reader = Reader(bytes: raw)
            guard raw.count > 8, Array(raw.prefix(4)) == magic else { return nil }
            reader.at = 4
            guard let headLength = reader.u32(), let headBytes = reader.bytes(Int(headLength)),
                  let header = try? JSONDecoder().decode(Header.self, from: Data(headBytes)) else { return nil }
            var pages: [Int: [LibraryEntry]] = [:]
            pages.reserveCapacity(header.pages.count)
            for page in header.pages {
                guard page.count == 2, page[0] >= 0, page[1] >= 0, pages[page[0]] == nil,
                      page[1] <= (raw.count - reader.at) / smallestEntry else { return nil }
                var entries: [LibraryEntry] = []
                entries.reserveCapacity(page[1])
                for _ in 0..<page[1] {
                    guard let id = reader.string() ?? nil, let name = reader.string() ?? nil, let kind = reader.string() ?? nil,
                          let year = reader.u32(), let imageTag = reader.string(), let aspect = reader.u64(),
                          let imdb = reader.string(), let tmdb = reader.u64(), let genreCount = reader.u8() else { return nil }
                    var genres: [String]?
                    if genreCount != 255 {
                        var list: [String] = []
                        list.reserveCapacity(Int(genreCount))
                        for _ in 0..<genreCount {
                            guard let genre = reader.string() ?? nil else { return nil }
                            list.append(genre)
                        }
                        genres = list
                    }
                    let ratio = Double(bitPattern: aspect)
                    entries.append(LibraryEntry(id: id, name: name, kind: kind,
                                                year: year == .max ? nil : Int(Int32(bitPattern: year)),
                                                imageTag: imageTag, aspect: ratio.isNaN ? nil : ratio, imdb: imdb,
                                                tmdb: tmdb == .max ? nil : Int(Int64(bitPattern: tmdb)), genres: genres))
                }
                pages[page[0]] = entries
            }
            return (header, pages)
        }
    }

    // MARK: Fields

    /// A string as its UTF-8 length (two bytes; 0xFFFF: none) and bytes.
    private static func put(_ text: String?, _ out: inout [UInt8]) {
        guard let text else { return put16(.max, &out) }
        var utf8 = Array(text.utf8)
        if utf8.count >= Int(UInt16.max) { utf8 = Array(utf8.prefix(Int(UInt16.max) - 1)) }
        put16(UInt16(utf8.count), &out)
        out += utf8
    }

    private static func put16(_ value: UInt16, _ out: inout [UInt8]) {
        withUnsafeBytes(of: value.littleEndian) { out += $0 }
    }

    private static func put32(_ value: UInt32, _ out: inout [UInt8]) {
        withUnsafeBytes(of: value.littleEndian) { out += $0 }
    }

    private static func put64(_ value: UInt64, _ out: inout [UInt8]) {
        withUnsafeBytes(of: value.littleEndian) { out += $0 }
    }

    private struct Reader {
        let bytes: UnsafeRawBufferPointer
        var at = 0

        mutating func bytes(_ count: Int) -> UnsafeRawBufferPointer? {
            guard count >= 0, at + count <= bytes.count else { return nil }
            defer { at += count }
            return UnsafeRawBufferPointer(rebasing: bytes[at..<at + count])
        }

        mutating func u8() -> UInt8? { bytes(1).map { $0[0] } }
        mutating func u16() -> UInt16? { bytes(2).map { UInt16(littleEndian: $0.loadUnaligned(as: UInt16.self)) } }
        mutating func u32() -> UInt32? { bytes(4).map { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) } }
        mutating func u64() -> UInt64? { bytes(8).map { UInt64(littleEndian: $0.loadUnaligned(as: UInt64.self)) } }

        /// nil: the file ends early; .some(nil): no string here.
        mutating func string() -> String?? {
            guard let length = u16() else { return nil }
            if length == .max { return .some(nil) }
            guard let utf8 = bytes(Int(length)) else { return nil }
            return .some(String(decoding: utf8, as: UTF8.self))
        }
    }
}

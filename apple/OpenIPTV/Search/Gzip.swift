import Compression
import Foundation

/// Reads a gzip file line by line while decompressing, so a large dataset
/// never has to sit in memory uncompressed.
enum Gzip {
    static func lines(_ gzip: Data, _ each: ([UInt8]) -> Void) throws {
        var offset = try deflateStart(gzip)
        let filter = try InputFilter(.decompress, using: .zlib, bufferCapacity: 1 << 16) { (length: Int) -> Data? in
            let end = min(offset + length, gzip.count)
            defer { offset = end }
            return end > offset ? gzip.subdata(in: offset..<end) : nil
        }
        var line: [UInt8] = []
        line.reserveCapacity(256)
        while let chunk = try filter.readData(ofLength: 1 << 20), !chunk.isEmpty {
            for byte in chunk {
                if byte == 10 {
                    each(line)
                    line.removeAll(keepingCapacity: true)
                } else {
                    line.append(byte)
                }
            }
        }
        if !line.isEmpty { each(line) }
    }

    /// Where the compressed data starts after the gzip header.
    private static func deflateStart(_ gzip: Data) throws -> Int {
        let bytes = [UInt8](gzip.prefix(10))
        guard bytes.count == 10, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { throw URLError(.cannotDecodeContentData) }
        let flags = bytes[3]
        var at = 10
        if flags & 4 != 0, gzip.count > at + 2 {
            at += 2 + Int(gzip[gzip.startIndex + at]) + Int(gzip[gzip.startIndex + at + 1]) << 8
        }
        for flag: UInt8 in [8, 16] where flags & flag != 0 {
            while at < gzip.count, gzip[gzip.startIndex + at] != 0 { at += 1 }
            at += 1
        }
        if flags & 2 != 0 { at += 2 }
        guard at < gzip.count else { throw URLError(.cannotDecodeContentData) }
        return at
    }
}

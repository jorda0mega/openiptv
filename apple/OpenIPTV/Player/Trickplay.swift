import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Scrubbing thumbnails from Emby's `index.bif` (the Roku "BIF" format:
/// a small index of timestamps and offsets, then one JPEG per interval).
struct TrickplayImages: Sendable {
    private let data: Data
    /// Start time (seconds) and byte range of each image, in order.
    private let entries: [(time: Double, range: Range<Int>)]

    var count: Int { entries.count }

    init?(bif data: Data) {
        let magic: [UInt8] = [0x89, 0x42, 0x49, 0x46, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count > 64, Array(data.prefix(8)) == magic else { return nil }
        func u32(_ at: Int) -> UInt32 {
            data.withUnsafeBytes { raw in
                UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: at, as: UInt32.self))
            }
        }
        let count = Int(u32(12))
        let separation = Double(u32(16) == 0 ? 1000 : u32(16)) / 1000
        guard count > 0, 64 + (count + 1) * 8 <= data.count else { return nil }
        var entries: [(Double, Range<Int>)] = []
        entries.reserveCapacity(count)
        for i in 0..<count {
            let start = Int(u32(64 + i * 8 + 4)), end = Int(u32(64 + (i + 1) * 8 + 4))
            guard start < end, end <= data.count else { continue }
            entries.append((Double(u32(64 + i * 8)) * separation, start..<end))
        }
        guard !entries.isEmpty else { return nil }
        self.data = data
        self.entries = entries
    }

    #if canImport(UIKit)
    /// The thumbnail showing `seconds` into the video.
    func image(at seconds: Double) -> UIImage? {
        // Last entry starting at or before `seconds` (binary search).
        var low = 0, high = entries.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if entries[mid].time <= seconds { low = mid } else { high = mid - 1 }
        }
        return UIImage(data: data.subdata(in: entries[low].range))
    }
    #endif
}

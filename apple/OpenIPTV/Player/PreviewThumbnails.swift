import UIKit

/// Emby's preview thumbnails (Roku's BIF format: small JPEG stills every
/// few seconds through a film), when the library has them made. While
/// choosing where to jump, the still for that moment stands in for the
/// picture, full-screen, until the player has the frame itself: scrubbing
/// answers at once whatever the connection.
final class PreviewThumbnails: @unchecked Sendable {
    private let data: Data
    /// When each still is, in seconds, and where its JPEG starts (one more
    /// offset than stills: the end of the last).
    private let times: [Double]
    private let offsets: [Int]
    private var last: (index: Int, image: UIImage)?

    var count: Int { times.count }

    init?(_ data: Data) {
        let magic: [UInt8] = [0x89, 0x42, 0x49, 0x46, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count > 64, Array(data.prefix(8)) == magic else { return nil }
        func word(_ at: Int) -> Int {
            data.withUnsafeBytes { Int(UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt32.self))) }
        }
        let count = word(12)
        let unit = Double(word(16) == 0 ? 1000 : word(16)) / 1000
        guard count > 0, data.count >= 64 + (count + 1) * 8 else { return nil }
        var times: [Double] = []
        var offsets: [Int] = []
        times.reserveCapacity(count)
        offsets.reserveCapacity(count + 1)
        for i in 0...count {
            let entry = 64 + i * 8
            if i < count { times.append(Double(word(entry)) * unit) }
            offsets.append(word(entry + 4))
        }
        guard offsets.allSatisfy({ $0 <= data.count }) else { return nil }
        self.data = data
        self.times = times
        self.offsets = offsets
    }

    /// The still at or just before `seconds`.
    @MainActor func image(near seconds: Double) -> UIImage? {
        var lo = 0, hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] <= seconds { lo = mid + 1 } else { hi = mid }
        }
        let index = max(0, lo - 1)
        if let last, last.index == index { return last.image }
        guard offsets[index] < offsets[index + 1],
              let image = UIImage(data: data.subdata(in: offsets[index]..<offsets[index + 1])) else { return nil }
        last = (index, image)
        return image
    }
}

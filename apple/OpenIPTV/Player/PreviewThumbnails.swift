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
    /// Stills decoded ahead, off the main thread, around where the viewer
    /// is choosing (a window of about 60: 14 MB for 320-wide stills).
    private let decoded = NSCache<NSNumber, UIImage>()
    private let decoder = DispatchQueue(label: "openiptv.preview-stills", qos: .userInitiated)
    private let lock = NSLock()
    private var queued = Set<Int>()

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
        decoded.countLimit = 90
    }

    /// Decodes the stills around `seconds` in the background (more ahead
    /// than behind), so each is ready to show the moment it's chosen.
    func warm(around seconds: Double) {
        let center = index(near: seconds)
        let wanted = (max(0, center - 15)...min(times.count - 1, center + 45)).filter { decoded.object(forKey: $0 as NSNumber) == nil }
        let fresh = lock.withLock { wanted.filter { queued.insert($0).inserted } }
        guard !fresh.isEmpty else { return }
        // Nearest first.
        for index in fresh.sorted(by: { abs($0 - center) < abs($1 - center) }) {
            decoder.async { [self] in
                defer { lock.withLock { _ = queued.remove(index) } }
                guard decoded.object(forKey: index as NSNumber) == nil, let image = still(index) else { return }
                decoded.setObject(image.preparingForDisplay() ?? image, forKey: index as NSNumber)
            }
        }
    }

    private func index(near seconds: Double) -> Int {
        var lo = 0, hi = times.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if times[mid] <= seconds { lo = mid + 1 } else { hi = mid }
        }
        return max(0, lo - 1)
    }

    private func still(_ index: Int) -> UIImage? {
        guard offsets[index] < offsets[index + 1] else { return nil }
        return UIImage(data: data.subdata(in: offsets[index]..<offsets[index + 1]))
    }

    /// The still at or just before `seconds`: decoded ahead when it can
    /// be (and the ones around it are started).
    @MainActor func image(near seconds: Double) -> UIImage? {
        let index = index(near: seconds)
        if let last, last.index == index { return last.image }
        warm(around: seconds)
        guard let image = decoded.object(forKey: index as NSNumber) ?? still(index) else { return nil }
        last = (index, image)
        return image
    }
}

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
    /// Where the viewer is choosing now (the window follows it), whether
    /// the decoder is running, and stills that wouldn't decode.
    private var target: Int?
    private var working = false
    private var broken = Set<Int>()

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
    /// than behind), so each is ready to show the moment it's chosen. One
    /// worker, nearest the latest position first: a new position replaces
    /// the window at once rather than queueing behind the old one.
    func warm(around seconds: Double) {
        let center = index(near: seconds)
        let start = lock.withLock { () -> Bool in
            target = center
            guard !working else { return false }
            working = true
            return true
        }
        if start { decoder.async { [self] in decodeWindow() } }
    }

    private func decodeWindow() {
        while let index = nextToDecode() {
            if let image = still(index) {
                decoded.setObject(image.preparingForDisplay() ?? image, forKey: index as NSNumber)
            } else {
                lock.withLock { _ = broken.insert(index) }
            }
        }
    }

    /// The undecoded still nearest the target in its window; nil (and the
    /// worker stops) when the window is ready.
    private func nextToDecode() -> Int? {
        lock.withLock {
            guard let center = target, !times.isEmpty else {
                working = false
                return nil
            }
            let low = max(0, center - 15), high = min(times.count - 1, center + 45)
            for distance in 0...max(center - low, high - center) {
                for index in [center + distance, center - distance] where index >= low && index <= high {
                    if !broken.contains(index), decoded.object(forKey: index as NSNumber) == nil { return index }
                }
            }
            target = nil
            working = false
            return nil
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

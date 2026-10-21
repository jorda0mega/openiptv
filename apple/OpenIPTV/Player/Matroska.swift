import Foundation

/// Just enough of Matroska (EBML) to find a file's index.
enum Matroska {
    private static let ebmlID: UInt32 = 0x1A45DFA3
    private static let segmentID: UInt32 = 0x18538067
    private static let seekHeadID: UInt32 = 0x114D9B74
    private static let seekID: UInt32 = 0x4DBB
    private static let seekTargetID: UInt32 = 0x53AB
    private static let seekPositionID: UInt32 = 0x53AC
    private static let clusterID: UInt32 = 0x1F43B675
    static let cuesID: UInt32 = 0x1C53BB6B

    private static let infoID: UInt32 = 0x1549A966
    private static let timecodeScaleID: UInt32 = 0x2AD7B1
    private static let cuePointID: UInt32 = 0xBB
    private static let cueTimeID: UInt32 = 0xB3
    private static let cueTrackPositionsID: UInt32 = 0xB7
    private static let cueClusterPositionID: UInt32 = 0xF1

    struct Layout {
        let segmentStart: Int64
        let firstCluster: Int64?
        let cues: Int64?
        /// Earliest SeekHead offset after the clusters. libmpv reads that tail on open.
        let pastClusters: Int64?
        let timecodeScale: UInt64
    }

    static func layout(in d: [UInt8]) -> Layout? {
        guard let (ebml, il) = id(d, 0), ebml == ebmlID, let (headerSize, sl) = self.size(d, il), let header = headerSize else { return nil }
        var i = il + sl + Int(header)
        guard let (segment, gl) = id(d, i), segment == segmentID, let (_, zl) = self.size(d, i + gl) else { return nil }
        let segmentStart = i + gl + zl
        i = segmentStart
        var listed: [(UInt32, UInt64)]?
        var firstCluster: Int64?
        var scale: UInt64 = 1_000_000
        while let (element, el) = id(d, i) {
            if element == clusterID {
                firstCluster = Int64(i)
                break
            }
            guard let (length, ll) = self.size(d, i + el), let length, length < 1 << 31 else { break }
            let body = i + el + ll
            if element == seekHeadID, listed == nil { listed = seeks(d, from: body, to: min(body + Int(length), d.count)) }
            if element == infoID {
                for (child, value) in children(d, from: body, to: min(body + Int(length), d.count)) where child == timecodeScaleID {
                    if let unit = uint(value), unit > 0 { scale = unit }
                }
            }
            i = body + Int(length)
        }
        let positions = (listed ?? []).map { (target: $0.0, at: Int64(segmentStart) + Int64($0.1)) }
        let pastClusters = firstCluster.flatMap { first in
            positions.filter { $0.target != clusterID && $0.at > first }.map(\.at).min()
        }
        return Layout(segmentStart: Int64(segmentStart), firstCluster: firstCluster, cues: positions.first { $0.target == cuesID }?.at,
                      pastClusters: pastClusters, timecodeScale: scale)
    }

    /// libmpv's CueClusterPosition for `seconds`, counted from the segment:
    /// the last keyframe at or before it, else the next.
    static func clusterPosition(in d: [UInt8], at seconds: Double, scale: UInt64) -> Int64? {
        guard let (element, el) = id(d, 0), element == cuesID, let (length, sl) = size(d, el), let length else { return nil }
        let target = UInt64(max(0, seconds) * 1_000_000_000 / Double(scale))
        var before: (time: UInt64, position: UInt64)?, after: (time: UInt64, position: UInt64)?
        for (child, point) in children(d, from: el + sl, to: min(d.count, el + sl + Int(length))) where child == cuePointID {
            let fields = children(d, from: point.startIndex, to: point.endIndex)
            guard let time = fields.first(where: { $0.0 == cueTimeID }).flatMap({ uint($0.1) }),
                  let positions = fields.first(where: { $0.0 == cueTrackPositionsID }),
                  let position = children(d, from: positions.1.startIndex, to: positions.1.endIndex)
                      .first(where: { $0.0 == cueClusterPositionID }).flatMap({ uint($0.1) })
            else { continue }
            if time <= target, before.map({ time >= $0.time }) ?? true { before = (time, position) }
            if time > target, after.map({ time < $0.time }) ?? true { after = (time, position) }
        }
        return (before ?? after).map { Int64($0.position) }
    }

    /// The elements inside `from..<to`, each with its contents.
    private static func children(_ d: [UInt8], from: Int, to end: Int) -> [(UInt32, ArraySlice<UInt8>)] {
        var found: [(UInt32, ArraySlice<UInt8>)] = []
        var j = from
        while j < end, let (element, el) = id(d, j), let (length, ll) = size(d, j + el), let length, length < 1 << 31 {
            let body = j + el + ll
            guard body + Int(length) <= d.count else { break }
            found.append((element, d[body..<body + Int(length)]))
            j = body + Int(length)
        }
        return found
    }

    private static func uint(_ value: ArraySlice<UInt8>) -> UInt64? {
        guard !value.isEmpty, value.count <= 8 else { return nil }
        return value.reduce(0) { $0 << 8 | UInt64($1) }
    }

    /// Where the Cues start in the file, from the SeekHead at its start.
    static func cuesOffset(in d: [UInt8]) -> Int64? {
        guard let (ebml, il) = id(d, 0), ebml == ebmlID, let (headerSize, sl) = self.size(d, il), let header = headerSize else { return nil }
        var i = il + sl + Int(header)
        guard let (segment, gl) = id(d, i), segment == segmentID, let (_, zl) = self.size(d, i + gl) else { return nil }
        let segmentStart = i + gl + zl
        i = segmentStart
        while let (element, el) = id(d, i), let (length, ll) = self.size(d, i + el), let length, length < 1 << 31 {
            let body = i + el + ll
            if element == clusterID { return nil }
            if element == seekHeadID {
                for (target, position) in seeks(d, from: body, to: min(body + Int(length), d.count)) where target == cuesID {
                    return Int64(segmentStart) + Int64(position)
                }
                return nil
            }
            i = body + Int(length)
        }
        return nil
    }

    /// The SeekHead's entries: an element's ID and where it is.
    private static func seeks(_ d: [UInt8], from: Int, to end: Int) -> [(UInt32, UInt64)] {
        var found: [(UInt32, UInt64)] = []
        var j = from
        while j < end, let (element, el) = id(d, j), let (length, ll) = size(d, j + el), let length, length < 1 << 16 {
            let body = j + el + ll
            if element == seekID {
                var target: UInt32?, position: UInt64?
                var k = body
                let stop = min(body + Int(length), d.count)
                while k < stop, let (child, cl) = id(d, k), let (size, sl) = self.size(d, k + cl), let size, size <= 8 {
                    let value = k + cl + sl
                    guard value + Int(size) <= d.count else { break }
                    if child == seekTargetID { target = d[value..<value + Int(size)].reduce(0) { $0 << 8 | UInt32($1) } }
                    if child == seekPositionID { position = d[value..<value + Int(size)].reduce(0) { $0 << 8 | UInt64($1) } }
                    k = value + Int(size)
                }
                if let target, let position { found.append((target, position)) }
            }
            j = body + Int(length)
        }
        return found
    }

    private static let largest: Int64 = 32 << 20

    static func fetchStart(at seconds: Double, fetch: (Int64, Int64) async -> (data: Data, total: Int64)?) async -> Bool {
        let first = StreamRelay.firstRead
        guard let (head, total) = await fetch(0, first), let layout = layout(in: [UInt8](head)), let cues = layout.cues, cues < total
        else { return false }
        var header = min(first, total)
        if let cluster = layout.firstCluster, cluster < largest {
            let to = min(cluster + first, total)
            if to > header {
                guard await fetch(header, to - header) != nil else { return false }
                header = to
            }
        }
        let tailAt = layout.pastClusters.flatMap { total - $0 <= largest ? $0 : nil } ?? total
        var tail: Data?
        if tailAt < total {
            guard let fetched = await fetch(tailAt, total - tailAt) else { return false }
            tail = fetched.data
        }
        let index: [UInt8]
        if let tail, cues >= tailAt {
            index = [UInt8](tail.dropFirst(Int(cues - tailAt)))
        } else {
            guard let probe = await fetch(cues, min(1 << 16, total - cues)), let length = elementLength([UInt8](probe.data.prefix(16))),
                  let whole = await fetch(cues, min(length, min(largest, total - cues))) else { return false }
            index = [UInt8](whole.data)
        }
        guard let cluster = clusterPosition(in: index, at: seconds, scale: layout.timecodeScale) else { return false }
        let at = layout.segmentStart + cluster
        let from = max(at, header), to = min(at + first + StreamRelay.readSize, tailAt)
        guard from < to else { return true }
        return await fetch(from, to - from) != nil
    }

    #if DEBUG
    /// The old ranges, but the cluster is the new choice. A film from the
    /// start gets its first cluster, which the old fetch skipped.
    static func fetchStartAsBefore(at seconds: Double, fetch: (Int64, Int64) async -> (data: Data, total: Int64)?) async -> Bool {
        guard let (head, total) = await fetch(0, 1 << 18), let layout = layout(in: [UInt8](head)), let cues = layout.cues, cues < total,
              let first = await fetch(cues, min(1 << 16, total - cues)), let length = elementLength([UInt8](first.data.prefix(16))),
              let index = await fetch(cues, min(length, min(largest, total - cues))),
              let cluster = clusterPosition(in: [UInt8](index.data), at: seconds, scale: layout.timecodeScale)
        else { return false }
        let at = layout.segmentStart + cluster
        guard at < total else { return false }
        return await fetch(at, min(StreamRelay.readSize, total - at)) != nil
    }
    #endif

    /// The whole length (header and contents) of the element at the start.
    static func elementLength(_ d: [UInt8]) -> Int64? {
        guard let (element, el) = id(d, 0), element == cuesID, let (contents, sl) = self.size(d, el), let contents else { return nil }
        return Int64(el + sl) + Int64(contents)
    }

    /// An element ID (1-4 bytes, its length marker kept) and its length.
    private static func id(_ d: [UInt8], _ i: Int) -> (UInt32, Int)? {
        guard i >= 0, i < d.count, d[i] != 0 else { return nil }
        let length = d[i].leadingZeroBitCount + 1
        guard length <= 4, i + length <= d.count else { return nil }
        return (d[i..<i + length].reduce(0) { $0 << 8 | UInt32($1) }, length)
    }

    /// A size (1-8 bytes, its marker removed; nil: unknown) and its length.
    private static func size(_ d: [UInt8], _ i: Int) -> (UInt64?, Int)? {
        guard i >= 0, i < d.count, d[i] != 0 else { return nil }
        let length = d[i].leadingZeroBitCount + 1
        guard i + length <= d.count else { return nil }
        let marker = UInt8(0x80) >> (length - 1)
        var value = UInt64(d[i] & (marker &- 1))
        var unknown = value == UInt64(marker &- 1)
        for k in 1..<length {
            value = value << 8 | UInt64(d[i + k])
            unknown = unknown && d[i + k] == 0xFF
        }
        return (unknown ? nil : value, length)
    }
}

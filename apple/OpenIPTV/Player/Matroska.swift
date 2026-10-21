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
    private static let cueTrackID: UInt32 = 0xF7
    private static let cueDurationID: UInt32 = 0xB2
    private static let tracksID: UInt32 = 0x1654AE6B
    private static let trackEntryID: UInt32 = 0xAE
    private static let trackNumberID: UInt32 = 0xD7
    private static let trackTypeID: UInt32 = 0x83

    struct Layout {
        let segmentStart: Int64
        let total: Int64
        let firstCluster: Int64?
        let continueAt: Int64?
        let cues: Int64?
        /// Earliest SeekHead offset after the clusters. libmpv reads that tail on open.
        let pastClusters: Int64?
        let timecodeScale: UInt64
        let videoTrack: UInt64?

        /// What libmpv reads after the clusters on open, to 32 MB.
        var tail: Range<Int64> {
            let at = pastClusters ?? total
            return at..<min(total, at + Matroska.largest)
        }
    }

    static func layout(in d: [UInt8], total: Int64) -> Layout? {
        guard let (ebml, il) = id(d, 0), ebml == ebmlID, let (headerSize, sl) = self.size(d, il), let header = headerSize else { return nil }
        var i = il + sl + Int(header)
        guard let (segment, gl) = id(d, i), segment == segmentID, let (_, zl) = self.size(d, i + gl) else { return nil }
        let segmentStart = i + gl + zl
        i = segmentStart
        var listed: [(UInt32, UInt64)]?
        var firstCluster: Int64?
        var scale: UInt64 = 1_000_000
        var videoTrack: UInt64?
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
            if element == tracksID, videoTrack == nil {
                videoTrack = children(d, from: body, to: min(body + Int(length), d.count)).lazy
                    .filter { $0.0 == trackEntryID }
                    .map { children(d, from: $0.1.startIndex, to: $0.1.endIndex) }
                    .first { value(trackTypeID, in: $0) == 1 }
                    .flatMap { value(trackNumberID, in: $0) }
            }
            i = body + Int(length)
        }
        let positions = (listed ?? []).compactMap { entry in
            inFile(entry.1, from: Int64(segmentStart), total: total).map { (target: entry.0, at: $0) }
        }
        let pastClusters = firstCluster.flatMap { first in
            positions.filter { $0.target != clusterID && $0.at > first }.map(\.at).min()
        }
        let continueAt = firstCluster == nil && i + 12 > d.count ? Int64(i) : nil
        return Layout(segmentStart: Int64(segmentStart), total: total, firstCluster: firstCluster, continueAt: continueAt,
                      cues: positions.first { $0.target == cuesID }?.at, pastClusters: pastClusters, timecodeScale: scale, videoTrack: videoTrack)
    }

    /// Counted from the segment's start. Nil when it does not fit in the file.
    private static func inFile(_ position: UInt64, from segmentStart: Int64, total: Int64) -> Int64? {
        guard let position = Int64(exactly: position) else { return nil }
        let (at, overflow) = segmentStart.addingReportingOverflow(position)
        return overflow || at >= total ? nil : at
    }

    private static func start(in d: [UInt8], at seconds: Double, subtitlePreroll: Double, layout: Layout) -> (reads: Int64, keyframe: Int64)? {
        let all = cues(in: d, layout: layout)
        // As demux_mkv.c's demux_mkv_seek and seek_with_cues: by the video
        // track's cue entries, else by all of them, 5 ms past what it is
        // told, in nanoseconds.
        let video = all.filter { $0.track == layout.videoTrack }
        let seekable = video.isEmpty ? all : video
        let target = UInt64(min(max(0, seconds + 0.005) * 1e9 + 0.5, 9e18))
        guard let keyframe = keyframe(in: seekable, at: target, scale: layout.timecodeScale) else { return nil }
        // With a subtitle on and cue durations, from the earliest cluster
        // since the last keyframe `subtitlePreroll` back that holds a
        // subtitle still on at the keyframe.
        guard subtitlePreroll > 0, all.contains(where: { $0.duration != nil }) else { return (keyframe.position, keyframe.position) }
        let back = UInt64(min(subtitlePreroll * 1e9 / Double(layout.timecodeScale), 9e18))
        let backTo = keyframe.time > back ? keyframe.time - back : 0
        var since: (time: UInt64, position: Int64) = (0, 0)
        for cue in seekable where cue.time <= backTo && cue.time >= since.time { since = (cue.time, cue.position) }
        let reads = all.filter { cue in
            guard case (let end, false) = cue.time.addingReportingOverflow(cue.duration ?? 0) else { return false }
            return cue.time <= keyframe.time && end > keyframe.time && cue.position >= since.position && cue.position < keyframe.position
        }.map(\.position).min()
        return (reads ?? keyframe.position, keyframe.position)
    }

    private struct Cue {
        let track: UInt64?
        let time: UInt64
        let position: Int64
        let duration: UInt64?
    }

    private static func cues(in d: [UInt8], layout: Layout) -> [Cue] {
        guard let (element, el) = id(d, 0), element == cuesID, let (length, sl) = size(d, el), let length else { return [] }
        var found: [Cue] = []
        for (child, point) in children(d, from: el + sl, to: min(d.count, el + sl + Int(length))) where child == cuePointID {
            let fields = children(d, from: point.startIndex, to: point.endIndex)
            guard let time = value(cueTimeID, in: fields) else { continue }
            for (field, positions) in fields where field == cueTrackPositionsID {
                let values = children(d, from: positions.startIndex, to: positions.endIndex)
                guard let position = value(cueClusterPositionID, in: values).flatMap({ inFile($0, from: layout.segmentStart, total: layout.total) })
                else { continue }
                found.append(Cue(track: value(cueTrackID, in: values), time: time, position: position,
                                 duration: values.first { $0.0 == cueDurationID }.map { uint($0.1) ?? 0 }))
            }
        }
        return found
    }

    /// The closest cue at or before `target` nanoseconds, else the closest
    /// after; the first of equals (demux_mkv.c, seek_with_cues).
    private static func keyframe(in cues: [Cue], at target: UInt64, scale: UInt64) -> Cue? {
        var best: (cue: Cue, diff: Int64)?
        for cue in cues {
            guard case (let nanoseconds, false) = cue.time.multipliedReportingOverflow(by: scale), let time = Int64(exactly: nanoseconds)
            else { continue }
            let diff = time - Int64(target)
            if let best, diff <= 0 ? best.diff <= 0 && diff <= best.diff : diff >= best.diff { continue }
            best = (cue, diff)
        }
        return best?.cue
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

    private static func value(_ id: UInt32, in fields: [(UInt32, ArraySlice<UInt8>)]) -> UInt64? {
        fields.first { $0.0 == id }.flatMap { uint($0.1) }
    }

    private static func uint(_ value: ArraySlice<UInt8>) -> UInt64? {
        guard !value.isEmpty, value.count <= 8 else { return nil }
        return value.reduce(0) { $0 << 8 | UInt64($1) }
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

    typealias Fetch = (Int64, Int64) async -> (data: Data, total: Int64)?

    static func fetchStart(at seconds: Double, subtitlePreroll: Double, fetch: Fetch) async -> Bool {
        let first = StreamRelay.firstRead
        guard let (data, total) = await fetch(0, first) else { return false }
        var head = [UInt8](data)
        guard var layout = layout(in: head, total: total) else { return false }
        // Fonts and cover art (Attachments) can push it past the first read.
        while layout.firstCluster == nil, let continueAt = layout.continueAt, head.count < largest {
            let from = Int64(head.count), to = min(continueAt + (1 << 16), total, largest)
            guard from < to, let next = await fetch(from, to - from), let longer = Self.layout(in: head + next.data, total: total) else { return false }
            head += next.data
            layout = longer
        }
        guard let cluster = layout.firstCluster, let cues = layout.cues else { return false }
        var header = Int64(head.count)
        let headerEnd = min(cluster + first, total)
        if headerEnd > header {
            guard await fetch(header, headerEnd - header) != nil else { return false }
            header = headerEnd
        }
        let tailAt = layout.tail.lowerBound
        var tail = Data()
        if !layout.tail.isEmpty {
            guard let fetched = await fetch(tailAt, Int64(layout.tail.count)) else { return false }
            tail = fetched.data
        }
        let index: [UInt8]
        let inTail = cues >= tailAt ? [UInt8](tail.dropFirst(Int(cues - tailAt))) : []
        if let length = elementLength([UInt8](inTail.prefix(16))), length <= inTail.count {
            index = inTail
        } else {
            guard let fetched = await fetchIndex(at: cues, total: total, fetch: fetch) else { return false }
            index = fetched
        }
        guard let opening = start(in: index, at: seconds, subtitlePreroll: subtitlePreroll, layout: layout) else { return false }
        let from = max(opening.reads, header)
        let to = min(opening.keyframe + first + StreamRelay.readSize, opening.reads + largest, tailAt)
        guard from < to else { return true }
        return await fetch(from, to - from) != nil
    }

    #if DEBUG
    /// The old fetch, for -oldReadyStart.
    static func fetchStartAsBefore(at seconds: Double, fetch: Fetch) async -> Bool {
        guard let (head, total) = await fetch(0, 1 << 18), let layout = layout(in: [UInt8](head), total: total), let cues = layout.cues,
              let probe = await fetch(cues, min(1 << 16, total - cues)), let length = elementLength([UInt8](probe.data.prefix(16))),
              let index = await fetch(cues, min(length, largest, total - cues)),
              let at = clusterPositionAsBefore(in: [UInt8](index.data), at: seconds, layout: layout)
        else { return false }
        return await fetch(at, min(StreamRelay.readSize, total - at)) != nil
    }

    /// The old choice: the first entry of the last cue point at or before
    /// `seconds` by the index's tick, none before the first.
    private static func clusterPositionAsBefore(in d: [UInt8], at seconds: Double, layout: Layout) -> Int64? {
        guard let (element, el) = id(d, 0), element == cuesID, let (_, sl) = size(d, el) else { return nil }
        let target = UInt64(max(0, seconds) * 1_000_000_000 / Double(layout.timecodeScale))
        var best: (time: UInt64, position: Int64)?
        for (child, point) in children(d, from: el + sl, to: d.count) where child == cuePointID {
            let fields = children(d, from: point.startIndex, to: point.endIndex)
            guard let time = value(cueTimeID, in: fields), time <= target,
                  let positions = fields.first(where: { $0.0 == cueTrackPositionsID }),
                  let position = value(cueClusterPositionID, in: children(d, from: positions.1.startIndex, to: positions.1.endIndex))
                      .flatMap({ inFile($0, from: layout.segmentStart, total: layout.total) })
            else { continue }
            if best.map({ time >= $0.time }) ?? true { best = (time, position) }
        }
        return best?.position
    }
    #endif

    static func fetchIndex(at cues: Int64, total: Int64, fetch: Fetch) async -> [UInt8]? {
        guard cues < total, let probe = await fetch(cues, min(1 << 16, total - cues)),
              let length = elementLength([UInt8](probe.data.prefix(16))) else { return nil }
        let end = min(cues + min(length, largest), total), next = cues + Int64(probe.data.count)
        guard end > next else { return [UInt8](probe.data.prefix(Int(end - cues))) }
        guard let rest = await fetch(next, end - next) else { return nil }
        return [UInt8](probe.data + rest.data)
    }

    /// The whole length (header and contents) of the element at the start.
    private static func elementLength(_ d: [UInt8]) -> Int64? {
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

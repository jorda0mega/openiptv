import XCTest
@testable import OpenIPTV

final class FilmStartTests: XCTestCase {
    /// A film laid out as mkvmerge writes one: its header, a cluster every
    /// 3.5 MB (14 Mbit/s), each starting on a keyframe every 2.002 s (23.976
    /// frames a second, the first 21 ms in), for two hours, its index (Cues,
    /// past the first 64 KB read of it), then its tags at the very end.
    private struct Film {
        static let firstCluster: Int64 = 4096
        static let clusterSize: Int64 = 3_500_000
        static let clusters = 3600
        let parts: [(at: Int64, bytes: [UInt8])]
        let cues: Range<Int64>
        let tags: Range<Int64>

        init() {
            let ebml = Self.element(0x1A45DFA3, Self.element(0x4282, Array("matroska".utf8)))
            let segmentStart = Int64(ebml.count + 12)
            let cuesAt = Self.firstCluster + Int64(Self.clusters) * Self.clusterSize
            let points = (0..<Self.clusters).flatMap { n in
                Self.element(0xBB, Self.element(0xB3, Self.uint(UInt64(Self.keyframe(n))))
                    + Self.element(0xB7, Self.element(0xF7, [1])
                        + Self.element(0xF1, Self.uint(UInt64(Self.firstCluster - segmentStart + Int64(n) * Self.clusterSize)))))
            }
            let index = Self.element(0x1C53BB6B, points)
            let tagsAt = cuesAt + Int64(index.count)
            let tagged = Self.element(0x1254C367, Self.element(0x7373, Self.element(0x67C8, Self.element(0x45A3, Array("BPS".utf8))
                + Self.element(0x4487, Array("14000000".utf8)))))
            let total = tagsAt + Int64(tagged.count)
            func seek(_ id: UInt32, _ at: Int64) -> [UInt8] {
                Self.element(0x4DBB, Self.element(0x53AB, Self.uint(UInt64(id))) + Self.element(0x53AC, Self.uint(UInt64(at - segmentStart))))
            }
            var head = ebml + [0x18, 0x53, 0x80, 0x67] + Self.size(Int(total - segmentStart))
            head += Self.element(0x114D9B74, seek(0x1C53BB6B, cuesAt) + seek(0x1254C367, tagsAt))
            head += Self.element(0x1549A966, Self.element(0x2AD7B1, Self.uint(1_000_000))) + Self.element(0x1654AE6B, [])
            head += Self.element(0xEC, [UInt8](repeating: 0, count: Int(Self.firstCluster) - head.count - 9))
            head += [0x1F, 0x43, 0xB6, 0x75] + Self.size(Int(Self.clusterSize) - 12)
            parts = [(0, head), (cuesAt, index), (tagsAt, tagged)]
            cues = cuesAt..<tagsAt
            tags = tagsAt..<total
        }

        var total: Int64 { tags.upperBound }

        /// The keyframe's time (ms) that cluster `n` starts with.
        static func keyframe(_ n: Int) -> Int { 21 + n * 2002 }

        /// Where the cluster mpv resumes in starts: the one whose keyframe
        /// is the last at or before `seconds`, else the first.
        func cluster(at seconds: Double) -> Int64 {
            let n = (0..<Self.clusters).last { Double(Self.keyframe($0)) <= seconds * 1000 } ?? 0
            return Self.firstCluster + Int64(n) * Self.clusterSize
        }

        func bytes(_ from: Int64, _ count: Int64) -> Data {
            var data = Data(count: Int(min(count, total - from)))
            for part in parts {
                let start = max(from, part.at), end = min(from + Int64(data.count), part.at + Int64(part.bytes.count))
                guard start < end else { continue }
                data.replaceSubrange(Int(start - from)..<Int(end - from), with: part.bytes[Int(start - part.at)..<Int(end - part.at)])
            }
            return data
        }

        private static func element(_ id: UInt32, _ body: [UInt8]) -> [UInt8] {
            uint(UInt64(id)) + size(body.count) + body
        }

        private static func size(_ count: Int) -> [UInt8] {
            [0x01] + withUnsafeBytes(of: UInt64(count).bigEndian, Array.init).dropFirst()
        }

        private static func uint(_ value: UInt64) -> [UInt8] {
            let bytes = withUnsafeBytes(of: value.bigEndian, Array.init).drop { $0 == 0 }
            return bytes.isEmpty ? [0] : Array(bytes)
        }
    }

    /// What libmpv reads opening the film to start at `seconds` (nil: from
    /// the beginning), before its first frame, as the relay saw it on the
    /// test server: its first 512 KB; its index and its tags, in one read
    /// from the index on; 512 KB again from its first cluster; then, where
    /// it starts, 512 KB and 8 MB after them (each jump opens a new request,
    /// whose first read is 512 KB).
    private func opening(_ film: Film, at seconds: Double?) -> [(String, Range<Int64>)] {
        let first = StreamRelay.firstRead, resume = film.cluster(at: seconds ?? 0)
        return [("first read", 0..<first), ("index and tags", film.cues.lowerBound..<film.total),
                ("read from the first cluster", Film.firstCluster..<Film.firstCluster + first),
                ("start", resume..<resume + first + StreamRelay.readSize)]
    }

    private func fetchedAhead(_ film: Film, for playback: EmbyPlayback) async -> (ok: Bool, ranges: [Range<Int64>]) {
        var fetched: [Range<Int64>] = []
        let ok = await Matroska.fetchStart(at: FileStart(playback).seconds) { from, count in
            let data = film.bytes(from, count)
            fetched.append(from..<from + Int64(data.count))
            return (data, film.total)
        }
        return (ok, fetched)
    }

    private func assertAllFetched(_ reads: [(String, Range<Int64>)], _ fetched: [Range<Int64>], file: StaticString = #filePath,
                                  line: UInt = #line) {
        let sorted = fetched.sorted { $0.lowerBound < $1.lowerBound }
        for (name, read) in reads {
            let covered = sorted.reduce(read.lowerBound) { reached, range in
                range.lowerBound <= reached ? max(reached, range.upperBound) : reached
            }
            XCTAssertGreaterThanOrEqual(covered, read.upperBound, "the \(name) wasn't all fetched ahead: \(read.upperBound - covered) bytes missing",
                                        file: file, line: line)
        }
        let needed = reads.map(\.1).sorted { $0.lowerBound < $1.lowerBound }.reduce(into: [Range<Int64>]()) { merged, read in
            if let last = merged.last, read.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, read.upperBound)
            } else {
                merged.append(read)
            }
        }
        XCTAssertLessThanOrEqual(fetched.reduce(0) { $0 + $1.count }, needed.reduce(0) { $0 + $1.count },
                                 "fetched more than opening it reads", file: file, line: line)
    }

    private func playback(at seconds: Double?) -> EmbyPlayback {
        EmbyPlayback(itemId: "m1", title: "Film", subtitle: nil, url: URL(string: "http://server/Videos/m1/stream.mkv")!,
                     startSeconds: seconds, durationSeconds: 480)
    }

    /// Resumed 300.46 s in (the player is told 300.5, a keyframe 0.2 s
    /// before), everything opening it reads comes from the device once its
    /// start was fetched ahead. Regression: the first read was half fetched,
    /// the tags not at all, the read from the first cluster only in part,
    /// the cluster where it resumes from the keyframe before the whole
    /// second (300, 2 s earlier), and 8 MB of it where the player reads 8.5,
    /// so a ready start still waited for the server.
    func testOpeningAResumedFilmReadsOnlyWhatWasFetchedAhead() async {
        let film = Film()
        let (ok, fetched) = await fetchedAhead(film, for: playback(at: 300.46))
        XCTAssertTrue(ok, "the film's start wasn't fetched")
        assertAllFetched(opening(film, at: 300.5), fetched)
    }

    /// A film started from its beginning, whose first keyframe is a moment
    /// in (21 ms), gets its first 8.5 MB fetched ahead too. Regression: no
    /// keyframe at or before 0 s, so nothing past the header was.
    func testOpeningAFilmFromItsBeginningReadsOnlyWhatWasFetchedAhead() async {
        let film = Film()
        let (ok, fetched) = await fetchedAhead(film, for: playback(at: nil))
        XCTAssertTrue(ok, "the film's start wasn't fetched")
        assertAllFetched(opening(film, at: nil), fetched)
    }
}

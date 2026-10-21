import XCTest
@testable import OpenIPTV

final class FilmStartTests: XCTestCase {
    private struct Film {
        static let clusterSize: Int64 = 3_500_000 // 14 Mbit/s across one keyframe gap
        static let video: UInt64 = 1
        static let subtitles: UInt64 = 3
        /// Two hours at 23.976 fps: a keyframe every 48 frames from half a
        /// frame in, so 0 s is before the first. The Cues then exceed a 64 KB read.
        static let keyframesMS = (0..<3600).map { 21 + $0 * 2002 }

        struct Position {
            var track = Film.video
            let cluster: Int
            var into: Int64 = 0
            var durationMS: Int?
            /// A CueClusterPosition written as is.
            var raw: UInt64?
        }

        struct Point {
            let ms: Int
            var positions: [Position]
        }

        static func points(_ keyframesMS: [Int] = keyframesMS) -> [Point] {
            keyframesMS.enumerated().map { Point(ms: $1, positions: [Position(cluster: $0)]) }
        }

        let firstCluster: Int64
        let parts: [(at: Int64, bytes: [UInt8])]
        let cues: Range<Int64>
        let tags: Range<Int64>

        init(points: [Point] = Film.points(), seeks extra: [(id: UInt32, position: UInt64)] = []) {
            let firstCluster: Int64 = 4096
            let ebml = Self.element(0x1A45DFA3, Self.element(0x4282, Array("matroska".utf8)))
            let segmentStart = Int64(ebml.count + 12)
            let clusters = (points.flatMap(\.positions).map(\.cluster).max() ?? 0) + 1
            let cuesAt = firstCluster + Int64(clusters) * Self.clusterSize
            let index = Self.element(0x1C53BB6B, points.flatMap { point in
                Self.element(0xBB, Self.element(0xB3, Self.uint(UInt64(point.ms))) + point.positions.flatMap { position in
                    let at = firstCluster + Int64(position.cluster) * Self.clusterSize + position.into - segmentStart
                    return Self.element(0xB7, Self.element(0xF7, Self.uint(position.track)) + Self.element(0xF1, Self.uint(position.raw ?? UInt64(at)))
                        + (position.durationMS.map { Self.element(0xB2, Self.uint(UInt64($0))) } ?? []))
                })
            })
            let tagsAt = cuesAt + Int64(index.count)
            let tagged = Self.element(0x1254C367, Self.element(0x7373, Self.element(0x67C8, Self.element(0x45A3, Array("BPS".utf8))
                + Self.element(0x4487, Array("14000000".utf8)))))
            let total = tagsAt + Int64(tagged.count)
            func seek(_ id: UInt32, _ position: UInt64) -> [UInt8] {
                Self.element(0x4DBB, Self.element(0x53AB, Self.uint(UInt64(id))) + Self.element(0x53AC, Self.uint(position)))
            }
            var head = ebml + [0x18, 0x53, 0x80, 0x67] + Self.size(Int(total - segmentStart))
            head += Self.element(0x114D9B74, seek(0x1C53BB6B, UInt64(cuesAt - segmentStart)) + seek(0x1254C367, UInt64(tagsAt - segmentStart))
                + extra.flatMap { seek($0.id, $0.position) })
            head += Self.element(0x1549A966, Self.element(0x2AD7B1, Self.uint(1_000_000)))
            head += Self.element(0x1654AE6B, Self.track(Self.video, type: 1) + Self.track(Self.subtitles, type: 0x11))
            head += Self.element(0xEC, [UInt8](repeating: 0, count: Int(firstCluster) - head.count - 9))
            head += [0x1F, 0x43, 0xB6, 0x75] + Self.size(Int(Self.clusterSize) - 12)
            // Tags follow the Cues, as mkvmerge writes them.
            self.firstCluster = firstCluster
            parts = [(0, head), (cuesAt, index), (tagsAt, tagged)]
            cues = cuesAt..<tagsAt
            tags = tagsAt..<total
        }

        var total: Int64 { tags.upperBound }

        func cluster(_ n: Int) -> Int64 { firstCluster + Int64(n) * Self.clusterSize }

        func cluster(at seconds: Double) -> Int64 {
            cluster(Self.keyframesMS.lastIndex { Double($0) <= seconds * 1000 } ?? 0)
        }

        func bytes(_ from: Int64, _ count: Int64) -> Data {
            var data = Data(count: Int(max(0, min(count, total - from))))
            for part in parts {
                let start = max(from, part.at), end = min(from + Int64(data.count), part.at + Int64(part.bytes.count))
                guard start < end else { continue }
                data.replaceSubrange(Int(start - from)..<Int(end - from), with: part.bytes[Int(start - part.at)..<Int(end - part.at)])
            }
            return data
        }

        private static func track(_ number: UInt64, type: UInt64) -> [UInt8] {
            element(0xAE, element(0xD7, uint(number)) + element(0x83, uint(type)))
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

    /// A jump opens a new request, so its first read is `firstRead` again.
    /// mpv starts reading at `start` and reads on past the keyframe it
    /// starts at.
    private func opening(_ film: Film, start: Int64, keyframe: Int64? = nil) -> [(String, Range<Int64>)] {
        let first = StreamRelay.firstRead
        return [("first read", 0..<first), ("index and tags", film.cues.lowerBound..<film.total),
                ("read from the first cluster", film.firstCluster..<film.firstCluster + first),
                ("start", start..<(keyframe ?? start) + first + StreamRelay.readSize)]
    }

    private func fetchedAhead(_ film: Film, for playback: EmbyPlayback) async -> (ok: Bool, ranges: [Range<Int64>]) {
        var fetched: [Range<Int64>] = []
        let ok = await FileStart(playback).fetch { from, count in
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

    func testOpeningAResumedFilmReadsOnlyWhatWasFetchedAhead() async {
        let film = Film()
        let item = playback(at: 300.46)
        let told = FileStart(item).seconds
        XCTAssertEqual(told, 300.5)
        let (ok, fetched) = await fetchedAhead(film, for: item)
        XCTAssertTrue(ok, "the film's start wasn't fetched")
        assertAllFetched(opening(film, start: film.cluster(at: told)), fetched)
    }

    func testOpeningAFilmFromItsBeginningReadsOnlyWhatWasFetchedAhead() async {
        let film = Film()
        let (ok, fetched) = await fetchedAhead(film, for: playback(at: nil))
        XCTAssertTrue(ok, "the film's start wasn't fetched")
        assertAllFetched(opening(film, start: film.cluster(at: 0)), fetched)
    }

    func testOffsetsPastAnyFileAreLeftOutAndTheStartIsStillFetched() async {
        var points = Film.points()
        points.insert(Film.Point(ms: 300_400, positions: [Film.Position(cluster: 150, raw: .max)]), at: 151)
        let film = Film(points: points, seeks: [(0x1043A770, 1 << 63), (0x1941A469, UInt64(Int64.max))])
        let (ok, fetched) = await fetchedAhead(film, for: playback(at: 300.5))
        XCTAssertTrue(ok, "the film's start wasn't fetched")
        assertAllFetched(opening(film, start: film.cluster(150)), fetched)
    }

    func testATenthOfASecondStartsAtTheKeyframeMpvPicks() async {
        // mpv seeks to 5 ms past what it is told (demux_mkv.c, demux_mkv_seek).
        var keyframes = (0..<3600).map { $0 * 2050 }
        keyframes[3] = 6204
        let film = Film(points: Film.points(keyframes))
        for (seconds, keyframe) in [(4.1, 2), (6.2, 3)] {
            let (ok, fetched) = await fetchedAhead(film, for: playback(at: seconds))
            XCTAssertTrue(ok, "the film's start wasn't fetched")
            assertAllFetched(opening(film, start: film.cluster(keyframe)), fetched)
        }
    }

    func testTheStartIsTheVideosKeyframeWhateverOtherTracksTheIndexLists() async {
        let subtitle = { (n: Int) in Film.Position(track: Film.subtitles, cluster: n, into: 1_000_000) }
        var points = Film.points()
        points[170].positions.insert(subtitle(170), at: 0)
        points.insert(Film.Point(ms: Film.keyframesMS[160], positions: [subtitle(160)]), at: 161)
        points.insert(Film.Point(ms: 300_400, positions: [subtitle(150)]), at: 151)
        let film = Film(points: points)
        for (seconds, keyframe) in [(300.5, 150), (320.4, 160), (340.4, 170)] {
            let (ok, fetched) = await fetchedAhead(film, for: playback(at: seconds))
            XCTAssertTrue(ok, "the film's start wasn't fetched")
            assertAllFetched(opening(film, start: film.cluster(keyframe)), fetched)
        }
    }
}

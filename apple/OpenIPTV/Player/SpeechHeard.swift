import Foundation
import SoundAnalysis

/// What's spoken in stretches of a film, heard by Apple's sound classifier
/// in the server's audio-only conversion of each: for putting a subtitle
/// file in time when the film has no subtitle track of its own to match it
/// against (SubtitleSync.fit(_:toSpeech:)). Asterix and Cleopatra's English
/// file came out 6.45 s early this way, in step all through the film.
enum SpeechHeard {
    /// The length of a stretch (seconds).
    static let seconds = 60.0

    /// Every stretch heard (two at a time); those the server didn't give
    /// are left out.
    static func listen(_ stretches: [EmbyPlayback.SpeechStretch]) async -> [SubtitleSync.Speech] {
        await withTaskGroup(of: SubtitleSync.Speech?.self) { group in
            var heard: [SubtitleSync.Speech] = []
            var queue = stretches[...]
            for _ in 0..<2 {
                guard let next = queue.popFirst() else { break }
                group.addTask { await hear(next) }
            }
            for await speech in group {
                if let speech { heard.append(speech) }
                if let next = queue.popFirst() { group.addTask { await hear(next) } }
            }
            return heard.sorted { $0.start < $1.start }
        }
    }

    private static func hear(_ stretch: EmbyPlayback.SpeechStretch) async -> SubtitleSync.Speech? {
        guard !Task.isCancelled, let file = await fetch(stretch.url) else { return nil }
        defer { try? FileManager.default.removeItem(at: file) }
        return classify(file, start: stretch.start)
    }

    /// The server converts for as long as it's read: a stretch's worth is
    /// read (64 kb/s), then the request ends.
    private static func fetch(_ url: URL) async -> URL? {
        let wanted = Int(seconds * 64_000 / 8)
        guard let (bytes, response) = try? await HTTP.patient.bytes(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        defer { bytes.task.cancel() }
        var data = Data()
        data.reserveCapacity(wanted + 16_384)
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= wanted { break }
            }
        } catch {
            // Ended early (the film's end): what came is still heard.
        }
        guard data.count > wanted / 4 else { return nil }
        let file = FileManager.default.temporaryDirectory.appending(path: "speech-\(UUID().uuidString).mp3")
        return (try? data.write(to: file)) != nil ? file : nil
    }

    /// How sure the classifier is that someone speaks, every 0.05 s (from
    /// one-second windows, a new one every quarter second).
    private static func classify(_ file: URL, start: Double) -> SubtitleSync.Speech? {
        guard let analyzer = try? SNAudioFileAnalyzer(url: file),
              let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return nil }
        request.windowDuration = CMTime(seconds: 1, preferredTimescale: 48_000)
        request.overlapFactor = 0.75
        let listener = Listener()
        guard (try? analyzer.add(request, withObserver: listener)) != nil else { return nil }
        analyzer.analyze()
        let points = listener.points
        guard let last = points.last, points.count > 4 else { return nil }
        let step = SubtitleSync.speechStep
        var confidence: [Float] = []
        var i = 0
        var t = 0.0
        while t <= last.time {
            while i + 1 < points.count, points[i + 1].time <= t { i += 1 }
            let a = points[i], b = points[min(i + 1, points.count - 1)]
            let f = b.time > a.time ? min(1, max(0, (t - a.time) / (b.time - a.time))) : 0
            confidence.append(Float(a.speech + (b.speech - a.speech) * f))
            t += step
        }
        return .init(start: start, confidence: confidence)
    }

    private final class Listener: NSObject, SNResultsObserving, @unchecked Sendable {
        private let lock = NSLock()
        private var found: [(time: Double, speech: Double)] = []
        var points: [(time: Double, speech: Double)] { lock.withLock { found } }

        func request(_ request: SNRequest, didProduce result: SNResult) {
            guard let result = result as? SNClassificationResult else { return }
            let speech = result.classification(forIdentifier: "speech")?.confidence ?? 0
            let time = result.timeRange.start.seconds + result.timeRange.duration.seconds / 2
            lock.withLock { found.append((time, speech)) }
        }
    }
}

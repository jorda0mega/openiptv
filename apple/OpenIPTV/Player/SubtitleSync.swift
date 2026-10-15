import Accelerate
import Foundation

/// Puts a subtitle file in time with the film, with nothing for the viewer
/// to move: its lines are matched against a reference already in time —
/// another subtitle track of the film, in any language (people speak at
/// the same moments whatever the language), fetched as text from the
/// server — and the shift, with a frame-rate stretch when the file was made
/// for another release (23.976 ↔ 25 ↔ 24 frames a second), that lines them
/// up best is applied by the player.
enum SubtitleSync {
    struct Cue: Equatable {
        let start: Double
        let end: Double
    }

    /// What to do to the file's times: times × speed + delay.
    struct Fit: Equatable {
        let delay: Double
        let speed: Double
        /// How much of the file's speech lands on the reference's (0-1).
        let score: Double
    }

    /// Steps of the speech signals (seconds).
    private static let step = 0.05
    /// The stretches tried: none, and between the usual frame rates.
    private static let speeds: [Double] = [1, 25 / 23.976, 23.976 / 25, 24 / 23.976, 23.976 / 24, 25 / 24, 24 / 25]
    /// The furthest shift looked for (seconds).
    private static let reach = 600.0

    /// The best shift and stretch of `file` onto `reference`; nil when they
    /// don't match well enough to trust (another cut, another film).
    static func fit(_ file: [Cue], to reference: [Cue]) -> Fit? {
        guard file.count >= 10, reference.count >= 10 else { return nil }
        var best: (fit: Fit, lift: Double)?
        for speed in speeds {
            let stretched = file.map { Cue(start: $0.start * speed, end: $0.end * speed) }
            guard let (delay, score, typical) = shift(stretched, onto: reference) else { continue }
            if score > (best?.fit.score ?? 0) + 0.02 { best = (Fit(delay: delay, speed: speed, score: score), score - typical) }
        }
        // Lined up, most of the speech meets; at a random shift, much less.
        // (Another film's lines meet as often at one shift as at another.)
        guard let best, best.fit.score >= 0.55, best.lift >= 0.3 else { return nil }
        return best.fit
    }

    /// The shift of `file` that lands most of its speech on `reference`'s,
    /// and how much does (by cross-correlation of the two, through FFTs).
    /// Also how much meets at a typical shift.
    private static func shift(_ file: [Cue], onto reference: [Cue]) -> (Double, Double, Double)? {
        let end = max(file.map(\.end).max() ?? 0, reference.map(\.end).max() ?? 0) + reach
        let samples = Int(end / step) + 1
        guard samples > 1, samples < 1 << 22 else { return nil }
        let a = signal(reference, samples), b = signal(file, samples)
        let speechA = a.reduce(0, +), speechB = b.reduce(0, +)
        guard speechA > 0, speechB > 0 else { return nil }
        let correlation = crossCorrelation(a, b)
        // correlation[k]: overlap with the file moved k steps later
        // (negative k at the end of the array, wrapped).
        let lags = Int(reach / step)
        var bestLag = 0
        var bestValue = -Float.greatestFiniteMagnitude
        var all: [Float] = []
        all.reserveCapacity(2 * lags + 1)
        for k in -lags...lags {
            let value = correlation[(k + correlation.count) % correlation.count]
            all.append(value)
            if value > bestValue { bestValue = value; bestLag = k }
        }
        let typical = all.sorted()[all.count / 2]
        let speech = Double(min(speechA, speechB))
        return (Double(bestLag) * step, Double(bestValue) / speech, Double(typical) / speech)
    }

    /// 1 where a line is on screen, 0 elsewhere, one value per step.
    private static func signal(_ cues: [Cue], _ samples: Int) -> [Float] {
        var out = [Float](repeating: 0, count: samples)
        for cue in cues where cue.end > cue.start {
            let from = max(0, Int(cue.start / step)), to = min(samples, Int(cue.end / step))
            if from < to { for i in from..<to { out[i] = 1 } }
        }
        return out
    }

    /// For each lag k (mod n): Σ a[i + k] · b[i], by FFTs.
    private static func crossCorrelation(_ a: [Float], _ b: [Float]) -> [Float] {
        let n = 1 << Int(ceil(log2(Double(2 * a.count))))
        let log2n = vDSP_Length(log2(Double(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        func transform(_ x: [Float]) -> ([Float], [Float]) {
            var real = x + [Float](repeating: 0, count: n - x.count)
            var imaginary = [Float](repeating: 0, count: n)
            real.withUnsafeMutableBufferPointer { r in
                imaginary.withUnsafeMutableBufferPointer { i in
                    var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                    vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
            return (real, imaginary)
        }
        let (ar, ai) = transform(a), (br, bi) = transform(b)
        // A · conj(B), then back.
        var real = [Float](repeating: 0, count: n), imaginary = [Float](repeating: 0, count: n)
        for k in 0..<n {
            real[k] = ar[k] * br[k] + ai[k] * bi[k]
            imaginary[k] = ai[k] * br[k] - ar[k] * bi[k]
        }
        real.withUnsafeMutableBufferPointer { r in
            imaginary.withUnsafeMutableBufferPointer { i in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: i.baseAddress!)
                vDSP_fft_zip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
            }
        }
        var scale = 1 / Float(n)
        vDSP_vsmul(real, 1, &scale, &real, 1, vDSP_Length(n))
        return real
    }

    // MARK: Speech heard in the film

    /// Speech heard in a stretch of the film: from `start` (the film's
    /// seconds), how sure the sound classifier is that someone speaks, one
    /// value (0-1) per `step` (0.05 s).
    struct Speech: Equatable {
        let start: Double
        let confidence: [Float]
    }

    static var speechStep: Double { step }

    /// The furthest shift looked for against speech (seconds). Files from
    /// other releases measured up to 56 s off; a wider search finds chance
    /// matches as good as the real one.
    private static let speechReach = 120.0
    /// How far the best shift's match must stand above the others (in
    /// standard deviations) to be trusted. With eight one-minute stretches
    /// of two Asterix films, their own files measured 4.9-6.5; 108 files
    /// of other films, 3.8 at most.
    static let speechTrust = 4.5

    /// The shift and stretch of `file` that lines its lines up with the
    /// speech heard in the film, for a film with no subtitle track of its
    /// own to match against; nil when none stands out (too little speech,
    /// another film). Its score is how far the match stands out.
    static func fit(_ file: [Cue], toSpeech heard: [Speech]) -> Fit? {
        let heard = heard.filter { $0.confidence.count > 20 }
        guard file.count >= 10, !heard.isEmpty else { return nil }
        let lags = Int(speechReach / step)
        let shifts = 2 * lags + 1
        var best: Fit?
        for speed in speeds {
            var total = [Float](repeating: 0, count: shifts)
            for stretch in heard {
                let n = stretch.confidence.count
                // The file's lines from reach before the stretch to reach
                // after it, matched against what was heard at each shift.
                let from = stretch.start - speechReach
                let lines = centred(signal(file.map { Cue(start: $0.start * speed - from, end: $0.end * speed - from) }, n + 2 * lags))
                let spoken = centred(stretch.confidence)
                var match = [Float](repeating: 0, count: shifts)
                vDSP_conv(lines, 1, spoken, 1, &match, 1, vDSP_Length(shifts), vDSP_Length(n))
                vDSP_vadd(total, 1, match, 1, &total, 1, vDSP_Length(shifts))
            }
            var mean: Float = 0, deviation: Float = 0
            var normalised = [Float](repeating: 0, count: shifts)
            vDSP_normalize(total, 1, &normalised, 1, &mean, &deviation, vDSP_Length(shifts))
            guard deviation > 0, let top = normalised.indices.max(by: { normalised[$0] < normalised[$1] }) else { continue }
            // match[k]: the file's lines k steps after `from` against the
            // stretch, so a line at t (stretched) was heard at t + reach - k·step.
            let fit = Fit(delay: speechReach - Double(top) * step, speed: speed, score: Double(normalised[top]))
            if fit.score > (best?.score ?? -.infinity) { best = fit }
        }
        guard let best, best.score >= speechTrust else { return nil }
        return best
    }

    private static func centred(_ x: [Float]) -> [Float] {
        var mean: Float = 0
        vDSP_meanv(x, 1, &mean, vDSP_Length(x.count))
        var shift = -mean
        var out = [Float](repeating: 0, count: x.count)
        vDSP_vsadd(x, 1, &shift, &out, 1, vDSP_Length(x.count))
        return out
    }

    // MARK: Reading subtitle files

    /// The lines' times of an SRT, WebVTT or ASS/SSA file.
    static func cues(_ text: String) -> [Cue] {
        text.contains("[Events]") ? assCues(text) : srtCues(text)
    }

    /// The lines someone speaks: not those that only describe a sound or
    /// music ("(rires)", "[door slams]", "♪ …"), which a hearing-impaired
    /// file has many of and nobody says.
    static func spokenCues(_ text: String) -> [Cue] {
        guard !text.contains("[Events]") else { return assCues(text) }
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        return blocks.compactMap { block in
            let lines = block.split(whereSeparator: \.isNewline).map(String.init)
            guard let at = lines.firstIndex(where: { $0.contains("-->") }), let cue = srtCues(lines[at]).first else { return nil }
            let words = lines[(at + 1)...].map(plain).filter { !$0.isEmpty }
            return words.isEmpty || words.allSatisfy(describesASound) ? nil : cue
        }
    }

    /// A line without its markup ("<i>…</i>", "{\\an8}") or a speaker's dash.
    private static func plain(_ line: String) -> String {
        var out = line
        for (open, close) in [("<", ">"), ("{", "}")] {
            while let a = out.range(of: open), let b = out.range(of: close, range: a.upperBound..<out.endIndex) {
                out.removeSubrange(a.lowerBound..<b.upperBound)
            }
        }
        return out.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "-–")))
    }

    private static func describesASound(_ line: String) -> Bool {
        (line.hasPrefix("(") && line.hasSuffix(")")) || (line.hasPrefix("[") && line.hasSuffix("]"))
            || line.hasPrefix("♪") || line.hasPrefix("♫") || line.hasSuffix("♪") || line.hasSuffix("♫")
    }

    /// "00:01:02,345 --> 00:01:04,000" (SRT) or "00:01:02.345 --> …" (VTT).
    private static func srtCues(_ text: String) -> [Cue] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.components(separatedBy: "-->")
            guard parts.count == 2, let start = clock(parts[0]), let end = clock(parts[1].split(separator: " ").first.map(String.init) ?? "")
            else { return nil }
            return Cue(start: start, end: end)
        }
    }

    /// "Dialogue: 0,0:01:02.34,0:01:04.00,…" lines.
    private static func assCues(_ text: String) -> [Cue] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            guard line.hasPrefix("Dialogue:") else { return nil }
            let fields = line.dropFirst(9).split(separator: ",", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count >= 3, let start = clock(String(fields[1])), let end = clock(String(fields[2])) else { return nil }
            return Cue(start: start, end: end)
        }
    }

    /// "01:02:03,456", "1:02:03.45", "02:03.456" → seconds.
    private static func clock(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var seconds = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            seconds = seconds * 60 + value
        }
        return seconds
    }
}

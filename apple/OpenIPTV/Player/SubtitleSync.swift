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
        // Lined up, most of the speech meets; at a random shift, much less.
        // (Another film's lines meet as often at one shift as at another.)
        guard let best = closest(file, to: reference), best.fit.score >= referenceScore, best.lift >= referenceLift else { return nil }
        return best.fit
    }

    /// What `fit(_:to:)` trusts: this much of the speech meeting, this much
    /// more than at a typical shift.
    private static let referenceScore = 0.55
    private static let referenceLift = 0.3

    /// The best shift and stretch of `file` onto `reference`, trusted or
    /// not, and how far it stands above a typical shift.
    private static func closest(_ file: [Cue], to reference: [Cue]) -> (fit: Fit, lift: Double)? {
        guard file.count >= 10, reference.count >= 10 else { return nil }
        var best: (fit: Fit, lift: Double)?
        for speed in speeds {
            let stretched = file.map { Cue(start: $0.start * speed, end: $0.end * speed) }
            guard let (delay, score, typical) = shift(stretched, onto: reference) else { continue }
            if score > (best?.fit.score ?? 0) + 0.02 { best = (Fit(delay: delay, speed: speed, score: score), score - typical) }
        }
        return best
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
        guard let best = closest(file, toSpeech: heard), best.score >= speechTrust else { return nil }
        return best
    }

    /// The best shift and stretch of `file` against the speech heard,
    /// trusted or not.
    private static func closest(_ file: [Cue], toSpeech heard: [Speech]) -> Fit? {
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
            // Another speed than the film's own only when it's clearly better:
            // over a few minutes of speech a slight stretch (24/23.976) fits
            // about as well, and was chosen for a file that only needed a
            // shift (6.2 s × 1.001 for 6.5 s).
            let bar = speed == 1 || best?.speed != 1 ? (best?.score ?? -.infinity) : (best?.score ?? -.infinity) * speechSpeedMargin
            if fit.score > bar { best = fit }
        }
        return best
    }

    /// How much better (as a share) another speed's match must be than the
    /// film's own speed's to be chosen.
    private static let speechSpeedMargin = 1.05

    private static func centred(_ x: [Float]) -> [Float] {
        var mean: Float = 0
        vDSP_meanv(x, 1, &mean, vDSP_Length(x.count))
        var shift = -mean
        var out = [Float](repeating: 0, count: x.count)
        vDSP_vsadd(x, 1, &shift, &out, 1, vDSP_Length(x.count))
        return out
    }

    // MARK: Part by part

    /// A file made for another cut of the film (a scene a little longer, a
    /// logo shorter) is off by different amounts in different parts.
    /// Asterix and Cleopatra's English file: 0.7 s early for its first ten
    /// minutes, 6.5 s until the fortieth, 7.2 s after; one shift for the
    /// whole film (6.45 s) put its opening 6 s late.

    /// From `from` (the file's own time) on, its lines need time × speed +
    /// delay.
    struct Section: Equatable, Codable, Sendable {
        let from: Double
        let delay: Double
        let speed: Double
    }

    /// A subtitle track of the film to put files in time with: its own
    /// (in time with it by definition), or another file (trusted once the
    /// speech heard, or another file, agrees it's in time).
    struct Reference {
        let cues: [Cue]
        let own: Bool
    }

    /// How well a subtitle file fits the film, and how to put it in time.
    struct Match: Comparable, Sendable, Codable {
        let sections: [Section]
        /// How clearly it matches, as a multiple of what's trusted (1 and
        /// up: trusted), on the same scale for speech and for references.
        let score: Double
        /// The share of the film's measured parts that agree with
        /// `sections` (0-1).
        let evenness: Double

        var isGoodEnough: Bool { score >= 1 && evenness >= 0.7 }

        /// Where a line at `time` (the file's own) belongs in the film.
        func film(_ time: Double) -> Double {
            let section = sections.last { $0.from <= time } ?? sections[0]
            return time * section.speed + section.delay
        }

        /// Good enough first, then the clearer and more even.
        static func < (a: Match, b: Match) -> Bool {
            if a.isGoodEnough != b.isGoodEnough { return !a.isGoodEnough }
            return a.score * a.evenness < b.score * b.evenness
        }
    }

    /// A part measured on its own: this many lines (a film's opening has few
    /// lines, credits and music, so a part is lines, not minutes).
    private static let partLines = 20
    /// How far a part may differ from the whole file's shift (seconds).
    private static let partReach = 12.0
    /// A part's own best shift counts when it stands out this much
    /// (standard deviations above the part's other shifts).
    private static let partTrust: Float = 1.5
    /// What a new section costs: a part's disagreement with its section is
    /// its clarity × the gap (seconds), the gap counted up to
    /// `strayGap`. So a stray part never makes a section on its own, while
    /// a few parts that agree do.
    private static let newSection = 6.0
    private static let strayGap = 2.0
    /// A section among others needs this many measurements at its shift
    /// (within `sameShift`), and more than half of its measurements: a
    /// part's best shift is the best of 481, so by chance alone it stands
    /// out as much as a real one (by 2-4.5) now and then. Chicks' speech
    /// made one minute 7 s off on its own; three of twenty parts of a file
    /// for another cut agreed by chance.
    private static let sectionParts = 2
    /// Shifts within this of each other (seconds) are one section.
    private static let sameShift = 0.5

    /// `text`, put in time part by part: the whole file's shift and stretch
    /// first (by the clearest of the trusted references and the speech);
    /// then each run of `partLines` lines' own best shift near it (within
    /// `partReach`), against the same; then the parts grouped into the
    /// sections that fit them best, each at its parts' weighted median,
    /// where a section costs `newSection` (dynamic programming). A new
    /// section starts at the longest pause between lines where the shift
    /// changes: films are cut where nobody speaks. Nil when nothing to
    /// match against was given.
    static func match(_ text: String, speech: [Speech], references: [Reference]) -> Match? {
        let all = cues(text), spoken = spokenCues(text)
        guard all.count >= 10 else { return nil }
        let heard = speech.filter { $0.confidence.count > 20 }
        let trusted = trustedReferences(references, heard: heard)
        // The whole file.
        var whole: (fit: Fit, score: Double)?
        for reference in trusted {
            guard let best = closest(all, to: reference) else { continue }
            let score = min(best.fit.score / referenceScore, best.lift / referenceLift)
            if score > (whole?.score ?? -.infinity) { whole = (best.fit, score) }
        }
        if let best = closest(spoken, toSpeech: heard) {
            let score = best.score / speechTrust
            if score > (whole?.score ?? -.infinity) { whole = (best, score) }
        }
        guard let whole else { return nil }
        let speed = whole.fit.speed, delay = whole.fit.delay
        let placed = all.map { Cue(start: $0.start * speed + delay, end: $0.end * speed + delay) }
        let placedSpoken = spoken.map { Cue(start: $0.start * speed + delay, end: $0.end * speed + delay) }
        // Each part: its lines' span, and its own best shift and how clearly.
        var parts: [(from: Double, to: Double, shift: Double?, clarity: Double)] = []
        var i = 0
        while i < placed.count {
            var j = min(placed.count, i + partLines)
            // The few lines left at the end go with the part before.
            if placed.count - j < partLines / 2 { j = placed.count }
            let from = max(0, placed[i].start), to = placed[i..<j].map(\.end).max() ?? from
            var shift: Double?, clarity = 0.0
            if let curve = partCurve(placed, placedSpoken, from: from, length: max(to - from, step), references: trusted, heard: heard),
               let top = curve.indices.max(by: { curve[$0] < curve[$1] }), top > 0, top < curve.count - 1, curve[top] >= partTrust {
                shift = Double(top) * step - partReach
                clarity = Double(curve[top])
            }
            parts.append((from, to, shift, clarity))
            i = j
        }
        // The measured parts grouped into sections: best[k] is the least
        // cost of the first k, with each group at its weighted median.
        let points = parts.indices.filter { parts[$0].shift != nil }
        func cost(_ range: Range<Int>) -> (Double, Double) {
            let level = weightedMedian(range.map { (parts[points[$0]].shift!, parts[points[$0]].clarity) })
            let spread = range.reduce(0.0) { $0 + parts[points[$1]].clarity * min(strayGap, abs(parts[points[$1]].shift! - level)) }
            return (spread, level)
        }
        // A section among others: enough measurements at its shift, and
        // most. (Parts measured by the same speech alone, the same stretch,
        // measure the same: one measurement.)
        func holds(_ range: Range<Int>, _ level: Double) -> Bool {
            let measured = Set(range.map { SIMD2(parts[points[$0]].shift!, parts[points[$0]].clarity) })
            let agreeing = measured.filter { abs($0.x - level) <= sameShift }.count
            return agreeing >= sectionParts && 2 * agreeing > measured.count
        }
        var best = [0.0] + [Double](repeating: .infinity, count: points.count)
        var start = [Int](repeating: 0, count: points.count + 1)
        if !points.isEmpty {
            for k in 1...points.count {
                for first in 0..<k {
                    let (spread, level) = cost(first..<k)
                    if first > 0 || k < points.count, !holds(first..<k, level) { continue }
                    let total = best[first] + spread + (first > 0 ? newSection : 0)
                    if total < best[k] { best[k] = total; start[k] = first }
                }
            }
        }
        var groups: [Range<Int>] = []
        var end = points.count
        while end > 0 { groups.insert(start[end]..<end, at: 0); end = start[end] }
        // Agreement: the share of the measured parts' weight within
        // sameShift of their section.
        var weight = 0.0, agreeing = 0.0
        for group in groups {
            let level = cost(group).1
            for k in group {
                weight += parts[points[k]].clarity
                if abs(parts[points[k]].shift! - level) <= sameShift { agreeing += parts[points[k]].clarity }
            }
        }
        let evenness = weight == 0 ? 1 : agreeing / weight
        // Runs of parts: each group from its first measured part (the
        // unmeasured ones before go with it).
        let runs: [(first: Int, last: Int, residual: Double)] = groups.map { (points[$0.lowerBound], points[$0.upperBound - 1], cost($0).1) }
        guard !runs.isEmpty else {
            return Match(sections: [Section(from: 0, delay: delay, speed: speed)], score: whole.score, evenness: evenness)
        }
        var sections: [Section] = []
        for (n, run) in runs.enumerated() {
            let shift = delay + run.residual
            guard n > 0 else {
                sections.append(Section(from: 0, delay: shift, speed: speed))
                continue
            }
            // Somewhere from the previous run's last part to this run's
            // first (the file's own times): the pause that splits the lines
            // best. (The parts are where the whole file's shift put them.)
            let previous = sections[n - 1], next = Section(from: 0, delay: shift, speed: speed)
            let lower = max(previous.from, (parts[runs[n - 1].last].from - delay) / speed), upper = (parts[run.first].to - delay) / speed
            let at = cut(all, between: lower, and: upper, from: previous, to: next, references: trusted, heard: heard)
            sections.append(Section(from: at, delay: shift, speed: speed))
        }
        return Match(sections: sections, score: whole.score, evenness: evenness)
    }

    /// Where between two sections the file changes: the pause between
    /// lines that splits them best, those before lining up with the
    /// references and the speech at the first section's shift, those after
    /// at the second's (the file's own times).
    private static func cut(_ lines: [Cue], between lower: Double, and upper: Double, from a: Section, to b: Section,
                            references: [[Cue]], heard: [Speech]) -> Double {
        let region = lines.filter { $0.end >= lower && $0.start <= upper }.sorted { $0.start < $1.start }
        guard region.count >= 2 else { return (lower + upper) / 2 }
        let sorted = references.map { $0.sorted { $0.start < $1.start } }
        func evidence(_ line: Cue, _ section: Section) -> Double {
            let start = line.start * section.speed + section.delay, end = line.end * section.speed + section.delay
            let length = max(end - start, step)
            var total = 0.0
            for reference in sorted {
                var low = 0, high = reference.count
                while low < high { let mid = (low + high) / 2; if reference[mid].end <= start { low = mid + 1 } else { high = mid } }
                var k = low, covered = 0.0
                while k < reference.count, reference[k].start < end {
                    covered += max(0, min(end, reference[k].end) - max(start, reference[k].start))
                    k += 1
                }
                total += covered / length
            }
            for stretch in heard {
                let i = Int((start - stretch.start) / step), j = Int((end - stretch.start) / step)
                guard i >= 0, j <= stretch.confidence.count, j > i else { continue }
                // How much surer of speech than usual in that stretch.
                let usual = stretch.confidence.reduce(0, +) / Float(stretch.confidence.count)
                total += Double(stretch.confidence[i..<j].reduce(0, +) / Float(j - i) - usual)
            }
            return total
        }
        let before = region.map { evidence($0, a) }, after = region.map { evidence($0, b) }
        var best = 1, bestValue = -Double.infinity
        var first = 0.0, rest = after.reduce(0, +)
        for k in 1..<region.count {
            first += before[k - 1]
            rest -= after[k - 1]
            if first + rest > bestValue { bestValue = first + rest; best = k }
        }
        return (region[best - 1].end + region[best].start) / 2
    }

    /// The references to trust: the film's own; another file when the
    /// speech heard puts it in time (within half a second, unstretched), or
    /// when another reference already trusted, or another file, lines up
    /// with it as it is. (A file for another release, off by a minute at
    /// another frame rate, would put everything wrong.) Copies of one file
    /// (the same times) are one file: they agree whatever the film, and
    /// only one is kept. Each file other than the film's own is then kept
    /// only where it's in time (`kept(_:own:heard:)`). At most eight, the
    /// film's own first.
    private static func trustedReferences(_ references: [Reference], heard: [Speech]) -> [[Cue]] {
        let own = references.filter(\.own).map(\.cues)
        var others = references.filter { !$0.own }.map(\.cues).filter { $0.count >= 10 }.prefix(8).map { $0 }
        func inTime(_ fit: Fit?) -> Bool { fit.map { abs($0.delay) <= 0.5 && $0.speed == 1 } ?? false }
        var trusted: [[Cue]] = []
        var undecided: [[Cue]] = []
        for other in others {
            if own.contains(where: { inTime(fit(other, to: $0)) }) || (!heard.isEmpty && inTime(fit(other, toSpeech: heard))) {
                trusted.append(other)
            } else {
                undecided.append(other)
            }
        }
        // Two files that agree with each other as they are.
        others = undecided
        var agreed = Set<Int>()
        for i in others.indices {
            for j in others.indices where j > i && !sameTimes(others[i], others[j]) && inTime(fit(others[i], to: others[j])) {
                agreed.insert(i)
                agreed.insert(j)
            }
        }
        trusted += agreed.sorted().map { others[$0] }
        trusted = trusted.map { kept($0, own: own, heard: heard) }.filter { $0.count >= 10 }
        var distinct: [[Cue]] = []
        for reference in own + trusted where !distinct.contains(where: { sameTimes(reference, $0) }) { distinct.append(reference) }
        return Array(distinct.prefix(8))
    }

    /// Whether most of `a`'s lines start when one of `b`'s does (within
    /// 0.02 s): copies of one file, or translations on its times.
    private static func sameTimes(_ a: [Cue], _ b: [Cue]) -> Bool {
        let starts = b.map(\.start).sorted()
        guard !a.isEmpty, !starts.isEmpty else { return false }
        let same = a.filter { line in
            var low = 0, high = starts.count
            while low < high { let mid = (low + high) / 2; if starts[mid] < line.start - 0.02 { low = mid + 1 } else { high = mid } }
            return low < starts.count && starts[low] <= line.start + 0.02
        }.count
        return Double(same) / Double(a.count) >= 0.8
    }

    /// `file` (another subtitle file, trusted as a whole) kept only where
    /// it's in time as it is. Judged by each stretch of speech heard and
    /// each `judgeLength` of the film's own track: in time where no shift
    /// fits clearly better than none (within `judgeMargin`), out where one
    /// does. Kept from the film's start to its end except where a judge
    /// finds it out, up to the nearest judges either side that find it in
    /// time. Whole when no judge can tell. A file for another cut is in
    /// time only up to the first cut: two of Barrio Brawler's files (one
    /// file twice) were in time for its first 45 minutes, then off by
    /// 3-12 s, and split its third, in time all through, into eight
    /// sections between −5 and +10 s.
    private static func kept(_ file: [Cue], own: [[Cue]], heard: [Speech]) -> [Cue] {
        var verdicts: [(from: Double, to: Double, inTime: Bool)] = []
        func judge(from: Double, length: Double, references: [[Cue]], heard: [Speech]) {
            guard let curve = partCurve(file, file, from: from, length: length, references: references, heard: heard),
                  let top = curve.indices.max(by: { curve[$0] < curve[$1] }), curve[top] >= partTrust else { return }
            verdicts.append((from, from + length, curve[top] - curve[curve.count / 2] <= judgeMargin))
        }
        for stretch in heard {
            judge(from: stretch.start, length: Double(stretch.confidence.count) * step, references: [], heard: [stretch])
        }
        for reference in own {
            var from = reference.map(\.start).min() ?? 0
            let last = reference.map(\.end).max() ?? 0
            while from < last {
                judge(from: from, length: judgeLength, references: [reference], heard: [])
                from += judgeLength
            }
        }
        verdicts.sort { $0.from < $1.from }
        var out: [(from: Double, to: Double)] = []
        for (k, verdict) in verdicts.enumerated() where !verdict.inTime {
            let before = verdicts[..<k].last { $0.inTime }?.to ?? -.infinity
            let after = verdicts[(k + 1)...].first { $0.inTime }?.from ?? .infinity
            out.append((before, after))
        }
        return file.filter { line in !out.contains { line.start >= $0.from && line.start < $0.to } }
    }

    /// What a judge of `kept(_:own:heard:)` covers of the film's own track
    /// (seconds).
    private static let judgeLength = 300.0
    /// How much better (in standard deviations) another shift must fit than
    /// none for a judge to find a file out of time. Barrio Brawler's parts
    /// in time measured up to 0.9 better elsewhere by chance; against its
    /// two files where they were off, 1.1-4.5.
    private static let judgeMargin: Float = 1

    /// For the part of the film from `from` (`length` long): how well each
    /// shift within `partReach` lines `file` (already placed by the whole
    /// file's shift) up with the references and the speech heard there, in
    /// standard deviations above the part's typical shift (index k: moved
    /// k·step − reach later). Nil when there's nothing there to measure.
    private static func partCurve(_ file: [Cue], _ spoken: [Cue], from: Double, length: Double, references: [[Cue]],
                                  heard: [Speech]) -> [Float]? {
        let lags = Int(partReach / step), shifts = 2 * lags + 1
        let n = Int(length / step)
        guard n > 0 else { return nil }
        var total = [Float](repeating: 0, count: shifts)
        var sources = 0
        func add(_ curve: [Float], reversed: Bool) {
            var mean: Float = 0, deviation: Float = 0
            var normalised = [Float](repeating: 0, count: shifts)
            vDSP_normalize(curve, 1, &normalised, 1, &mean, &deviation, vDSP_Length(shifts))
            guard deviation > 0 else { return }
            vDSP_vadd(total, 1, reversed ? normalised.reversed() : normalised, 1, &total, 1, vDSP_Length(shifts))
            sources += 1
        }
        let lines = centred(signal(file.map { Cue(start: $0.start - from, end: $0.end - from) }, n))
        guard lines.contains(where: { $0 > 0 }) else { return nil }
        for reference in references {
            // The reference from reach before the part to reach after it;
            // curve[k]: the file moved k·step − reach later.
            let around = centred(signal(reference.map { Cue(start: $0.start - from + partReach, end: $0.end - from + partReach) }, n + 2 * lags))
            var curve = [Float](repeating: 0, count: shifts)
            vDSP_conv(around, 1, lines, 1, &curve, 1, vDSP_Length(shifts), vDSP_Length(n))
            add(curve, reversed: false)
        }
        for stretch in heard where stretch.start + Double(stretch.confidence.count) * step > from && stretch.start < from + length {
            // As in fit(_:toSpeech:): curve[k] is the file moved reach − k·step.
            let m = stretch.confidence.count
            let near = centred(signal(spoken.map { Cue(start: $0.start - stretch.start + partReach, end: $0.end - stretch.start + partReach) }, m + 2 * lags))
            var curve = [Float](repeating: 0, count: shifts)
            vDSP_conv(near, 1, centred(stretch.confidence), 1, &curve, 1, vDSP_Length(shifts), vDSP_Length(m))
            add(curve, reversed: true)
        }
        guard sources > 0 else { return nil }
        var scale = 1 / Float(Double(sources).squareRoot())
        vDSP_vsmul(total, 1, &scale, &total, 1, vDSP_Length(shifts))
        return total
    }

    /// The value that half the weight is at or below.
    private static func weightedMedian(_ values: [(value: Double, weight: Double)]) -> Double {
        let sorted = values.sorted { $0.value < $1.value }
        let half = sorted.reduce(0) { $0 + $1.weight } / 2
        var sum = 0.0
        for item in sorted {
            sum += item.weight
            if sum >= half { return item.value }
        }
        return sorted.last?.value ?? 0
    }

    /// `text` (SRT, WebVTT or ASS/SSA) with every line's times moved where
    /// `match` puts them: each line by the section its start is in.
    static func retimed(_ text: String, by match: Match) -> String {
        let ass = text.contains("[Events]")
        var lines = text.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() {
            if ass {
                guard line.hasPrefix("Dialogue:") else { continue }
                var fields = line.split(separator: ",", maxSplits: 3, omittingEmptySubsequences: false).map(String.init)
                guard fields.count >= 4, let start = clock(fields[1]), let end = clock(fields[2]) else { continue }
                let (a, b) = moved(start, end, match)
                fields[1] = assClock(a)
                fields[2] = assClock(b)
                lines[i] = fields.joined(separator: ",")
            } else {
                let parts = line.components(separatedBy: "-->")
                guard parts.count == 2, let start = clock(parts[0]) else { continue }
                let rest = parts[1].trimmingCharacters(in: .whitespaces)
                let endText = String(rest.split(separator: " ", maxSplits: 1).first ?? "")
                guard let end = clock(endText) else { continue }
                let tail = rest.dropFirst(endText.count)
                let comma = parts[0].contains(",")
                let (a, b) = moved(start, end, match)
                lines[i] = srtClock(a, comma: comma) + " --> " + srtClock(b, comma: comma) + tail
            }
        }
        return lines.joined(separator: "\n")
    }

    /// A line's times moved by the section its start is in.
    private static func moved(_ start: Double, _ end: Double, _ match: Match) -> (Double, Double) {
        let section = match.sections.last { $0.from <= start } ?? match.sections[0]
        return (max(0, start * section.speed + section.delay), max(0, end * section.speed + section.delay))
    }

    /// "01:02:03,456" (SRT) or "01:02:03.456" (WebVTT).
    private static func srtClock(_ seconds: Double, comma: Bool) -> String {
        let ms = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, comma ? "," : ".", ms % 1000)
    }

    /// "1:02:03.45" (ASS).
    private static func assClock(_ seconds: Double) -> String {
        let cs = Int((seconds * 100).rounded())
        return String(format: "%d:%02d:%02d.%02d", cs / 360_000, cs / 6000 % 60, cs / 100 % 60, cs % 100)
    }

    /// 0, 8, 4, 12, 2, 6, 10, 14, 1, 3, … of sixteen: the first half (and
    /// quarter) spread across them all; the order SpeechHeard asks for the
    /// film's stretches in.
    static func spread<T>(_ items: [T]) -> [T] {
        var order: [Int] = []
        var step = 1
        while step < items.count { step *= 2 }
        var stride = step
        while stride >= 1 {
            for i in Swift.stride(from: 0, to: step, by: stride) where i < items.count && !order.contains(i) { order.append(i) }
            stride /= 2
        }
        return order.map { items[$0] }
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

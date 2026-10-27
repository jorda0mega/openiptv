#if DEBUG
import Foundation

/// Every named measurement: the eval suite's lines (perf/eval.sh), the best
/// table (perf/best.json) and, later, usage reports use these names and no
/// others. perf/perf.py reads this file for them.
enum PerfMetric: String, CaseIterable {
    case filmFirstTap = "film.start.first_tap"
    case filmLaunchTap = "film.start.launch_tap"
    case filmPrepared = "film.start.prepared"
    case filmResumeOther = "film.start.resume_other"
    case filmJumpForward10s = "film.jump.forward_10s"
    case filmJumpBack10s = "film.jump.back_10s"
    case filmJumpForward5min = "film.jump.forward_5min"
    case filmJumpLoadingShown = "film.jump.loading_shown"
    case filmPauses = "film.play.pauses_120s"
    case subtitleFirstLine = "film.subtitles.first_line"
    case subtitlePeakSDR = "film.subtitles.peak_sdr"
    case subtitlePeakHDR = "film.subtitles.peak_hdr"
    case subtitleScale = "film.subtitles.scale"
    case pipStartPicture = "pip.start.picture_gap"
    case pipStartSound = "pip.start.sound_gap"
    case pipReturnPicture = "pip.return.picture_gap"
    case pipReturnSound = "pip.return.sound_gap"
    case liveStart = "live.start"
    case liveSwitch = "live.switch"

    enum Unit: String { case seconds = "s", milliseconds = "ms", count, ratio }

    var unit: Unit {
        switch self {
        case .filmFirstTap, .filmLaunchTap, .filmPrepared, .filmResumeOther: .seconds
        case .filmJumpLoadingShown, .filmPauses: .count
        case .subtitlePeakSDR, .subtitlePeakHDR, .subtitleScale: .ratio
        default: .milliseconds
        }
    }

    /// The eval line for one sample: `METRIC film.jump.back_10s 412 ms`.
    func line(_ value: Double) -> String {
        "METRIC \(rawValue) \(String(format: unit == .seconds || unit == .ratio ? "%.2f" : "%.0f", value)) \(unit.rawValue)"
    }
}
#endif

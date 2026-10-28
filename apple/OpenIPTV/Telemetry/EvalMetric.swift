#if DEBUG
extension Metric {
    /// Measurements only the eval suite takes (perf/eval.sh), beside the ones the app also sends (Name).
    /// perf/perf.py reads both lists from this folder, and the best table (perf/best.json) uses no other names.
    enum EvalName: String, CaseIterable, Sendable {
        case filmStartUnprepared = "film.start.unprepared"
        case filmJumpLoadingShown = "film.jump.loading_shown"
        case filmPauses = "film.play.pauses_120s"
        case subtitleFirstLine = "film.subtitles.first_line"
        case subtitlePeakSDR = "film.subtitles.peak_sdr"
        case subtitlePeakHDR = "film.subtitles.peak_hdr"
        case subtitleScale = "film.subtitles.scale"
        case pipStartSoundGap = "film.pip.start_sound_gap"
        case pipReturnSoundGap = "film.pip.return_sound_gap"
    }
}
#endif

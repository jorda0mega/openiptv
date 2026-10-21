import Foundation

/// What a film's player plays, and so where its clock starts. It goes
/// wherever the player goes (Picture in Picture, kept after closing):
/// apart from it, a jump back after Picture in Picture stopped at a lower
/// quality's first segment.
enum FilmStream: Sendable {
    /// The file, or a converted version as Emby lists it: the whole film,
    /// the player's clock the film's.
    case whole
    /// A converted version listed from the segment starting at `clockStart`
    /// (see ConvertedPlaylist), where the player's clock starts.
    case listed(URL, ConvertedPlaylist, clockStart: Double)

    var clockStart: Double {
        guard case let .listed(_, _, clockStart) = self else { return 0 }
        return clockStart
    }

    #if DEBUG
    /// UI tests (-oldConvertedStart YES): the converted version as Emby
    /// lists it, the whole film from 0:00.
    static var oldConvertedStart: Bool { UserDefaults.standard.bool(forKey: "oldConvertedStart") }
    #else
    static let oldConvertedStart = false
    #endif
}

extension MPVPlayer {
    /// The film's converted version from its `second`, listed from the
    /// segment holding it when Emby's playlist allows; else as Emby lists
    /// it. What plays now.
    func openConverted(_ url: URL, _ list: ConvertedPlaylist?, at second: Double, for playback: EmbyPlayback) -> FilmStream {
        if let list, case let listed = list.listed(from: second), let local = StreamRelay.shared.localURL(serving: listed.playlist) {
            // From the segment's start, at most a segment before `second`: a
            // jump to `second` read the segment again for a keyframe in it.
            load(local, headers: playback.fallbackHeaders, file: false, converting: true, tracks: playback.tracks,
                 sameFilm: listed.clockStart)
            return .listed(url, list, clockStart: listed.clockStart)
        }
        load(url, headers: playback.fallbackHeaders, start: second, file: false, converting: !FilmStream.oldConvertedStart,
             tracks: playback.tracks, sameFilm: 0)
        return .whole
    }

    /// Every jump to the film's `second`: `seek` there by the stream's own
    /// clock or, before a listed version's first segment, the version opened
    /// again from there (Emby converts from there either way). What plays now.
    func jump(in stream: FilmStream, to second: Double, for playback: EmbyPlayback, seek: (Double) -> Void) -> FilmStream {
        guard case let .listed(url, list, clockStart) = stream, second < clockStart else {
            seek(max(0, second - stream.clockStart))
            return stream
        }
        #if DEBUG
        askedForConverted()
        #endif
        return openConverted(url, list, at: second, for: playback)
    }
}

import Foundation

enum FilmStream: Sendable {
    case whole
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

    /// Before its first segment, open the listed version again. Emby converts from the second asked either way.
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

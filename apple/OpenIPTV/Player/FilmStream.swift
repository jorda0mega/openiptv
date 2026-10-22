import Foundation

enum FilmStream: Sendable {
    case whole
    case listed(URL, ConvertedPlaylist, clockStart: Double)

    var clockStart: Double {
        guard case let .listed(_, _, clockStart) = self else { return 0 }
        return clockStart
    }

    /// The original file: kept on closing, and adapted from its full quality.
    var isOriginal: Bool {
        guard case .whole = self else { return false }
        return true
    }

    #if DEBUG
    /// UI tests (-oldConvertedStart YES): the converted version as Emby
    /// lists it, the whole film from 0:00.
    static var oldConvertedStart: Bool { UserDefaults.standard.bool(forKey: "oldConvertedStart") }
    #else
    static let oldConvertedStart = false
    #endif

    /// What the player opens for a converted version from `second`: nil
    /// when the relay can't serve its list. The relay alone asks the server,
    /// with `headers`.
    static func converted(_ url: URL, _ list: ConvertedPlaylist, at second: Double, headers: [String], old: Bool = oldConvertedStart,
                          serve: (ConvertedPlaylist.Listed, [String], URL) -> URL? = StreamRelay.shared.localURL(serving:headers:given:))
        -> (address: URL, headers: [String], start: Double?, stream: FilmStream)? {
        // From the segment's start, at most a segment before `second`: a
        // jump to `second` read the segment again for a keyframe in it.
        let listed = list.listed(from: old ? 0 : second)
        guard let local = serve(listed, headers, url) else { return nil }
        return (local, [], old ? second : nil, .listed(url, list, clockStart: listed.clockStart))
    }
}

#if canImport(UIKit)
extension MPVPlayer {
    func openConverted(_ url: URL, _ list: ConvertedPlaylist, at second: Double, for playback: EmbyPlayback) -> FilmStream? {
        guard let opening = FilmStream.converted(url, list, at: second, headers: playback.fallbackHeaders) else { return nil }
        load(opening.address, headers: opening.headers, start: opening.start, file: false, converting: !FilmStream.oldConvertedStart,
             tracks: playback.tracks, sameFilm: opening.stream.clockStart)
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "debugRedirectCounts") {
            let (headers, from) = (playback.fallbackHeaders, opening.stream.clockStart)
            Task.detached { await ConvertedPlaylist.countRedirects(list, from: from, headers: headers, given: url) }
        }
        #endif
        return opening.stream
    }

    /// Before its first segment, open the listed version again. Emby converts from the second asked either way.
    func jump(in stream: FilmStream, to second: Double, for playback: EmbyPlayback, seek: (Double) -> Void) -> FilmStream {
        if case let .listed(url, list, clockStart) = stream, second < clockStart {
            #if DEBUG
            askedForConverted()
            #endif
            if let reopened = openConverted(url, list, at: second, for: playback) { return reopened }
        }
        seek(max(0, second - stream.clockStart))
        return stream
    }
}
#endif

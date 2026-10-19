import Foundation
import Libavutil

/// ffmpeg's warnings, for the class of a stream's failure (its HTTP status,
/// a reset). libmpv hands ffmpeg's lines only to the first player made in
/// the app, often a film warming up, and puts ffmpeg's own printer (stderr)
/// back when that player closes: the hook is set again after every player
/// opens or closes. A line can hold the stream's address, and with it the
/// login: it is matched and dropped.
enum FFmpegLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var last: (failure: StreamFailure, at: CFAbsoluteTime)?

    static func listen() {
        av_log_set_callback { _, level, format, arguments in
            guard level & 0xff <= AV_LOG_WARNING, let format, let arguments else { return }
            var text = [CChar](repeating: 0, count: 512)
            vsnprintf(&text, text.count, format, arguments)
            guard let failure = text.withUnsafeBufferPointer({ StreamFailure(logged: String(cString: $0.baseAddress!)) }) else { return }
            FFmpegLog.lock.withLock { FFmpegLog.last = (failure, CFAbsoluteTimeGetCurrent()) }
        }
    }

    static func failure(since time: CFAbsoluteTime) -> StreamFailure? {
        guard let last = lock.withLock({ last }), last.at >= time else { return nil }
        return last.failure
    }
}

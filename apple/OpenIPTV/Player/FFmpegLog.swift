import Foundation
import Libavutil

/// ffmpeg's warnings, for the class of a stream's failure (its HTTP status,
/// a reset). libmpv hands ffmpeg's lines only to the first player made in
/// the app, often a film warming up, and puts ffmpeg's own printer (stderr)
/// back when that player closes: the hook is set again after every player
/// opens or closes. A line can hold the stream's address, and with it the
/// login: it is matched and dropped. The lines say nothing of which player
/// they're from (see FailureLedger).
enum FFmpegLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var ledger = FailureLedger()

    static func listen() {
        av_log_set_callback { _, level, format, arguments in
            guard level & 0xff <= AV_LOG_WARNING, let format, StreamFailure.worthReading(format: format), let arguments else { return }
            var text = [CChar](repeating: 0, count: 512)
            vsnprintf(&text, text.count, format, arguments)
            guard let failure = text.withUnsafeBufferPointer({ StreamFailure(logged: String(cString: $0.baseAddress!)) }) else { return }
            let now = CFAbsoluteTimeGetCurrent()
            FFmpegLog.lock.withLock { FFmpegLog.ledger.record(failure, at: now) }
        }
    }

    static func began(_ load: FailureLedger.Load) {
        lock.withLock { ledger.began(load) }
    }

    static func ended(_ load: FailureLedger.Load) {
        lock.withLock { ledger.ended(load) }
    }

    static func started(_ load: FailureLedger.Load) {
        lock.withLock { ledger.started(load) }
    }

    static func closed(player: Int) {
        lock.withLock { ledger.closed(player: player) }
    }

    static func failure(of load: FailureLedger.Load, since time: CFAbsoluteTime) -> StreamFailure? {
        lock.withLock { ledger.failure(of: load, since: time) }
    }
}

import Foundation

/// Why a live stream failed, read from ffmpeg's and libmpv's warnings. Only
/// the class is kept: a warning can hold the stream's address, and with it
/// the login.
enum StreamFailure: String, CaseIterable {
    case http_401, http_403, http_404, http_429, http_5xx, http_other
    case refused, reset, timeout, dns, tls, redirect_loop, probe_failed, decode
    case no_data, no_frame, eof_before_frame, unknown
    case offline

    private static let patterns: [(String, StreamFailure)] = [
        ("Connection refused", .refused),
        ("Connection reset", .reset),
        ("timed out", .timeout),
        ("Failed to resolve hostname|nodename nor servname", .dns),
        ("TLS|SSL|certificate", .tls),
        ("Too many redirects|Redirect loop", .redirect_loop),
        ("Invalid data found|could not find codec parameters", .probe_failed),
        ("Failed to initialize a decoder|Could not open codec", .decode),
    ]

    init?(logged text: String) {
        if let status = text.firstMatch(of: #/(?:HTTP error|Server returned) ([1-5][0-9X]{2})/#)?.1 {
            self = switch status {
            case "401": .http_401
            case "403": .http_403
            case "404": .http_404
            case "429": .http_429
            case _ where status.hasPrefix("5"): .http_5xx
            default: .http_other
            }
            return
        }
        guard let match = Self.patterns.first(where: { text.range(of: $0.0, options: .regularExpression) != nil }) else { return nil }
        self = match.1
    }

    enum Step: Equatable {
        case nextCopy
        case sameCopy(after: Double)
        case reconnect
        case stop
    }

    /// `played`: the copy showed a picture. `sinceSwitch`: seconds since
    /// another stream was let go, which a provider allowing one stream at a
    /// time can still count for a moment.
    func step(played: Bool, triedAgain: Bool, sinceSwitch: TimeInterval) -> Step {
        switch self {
        case .http_429:
            .stop
        case _ where played:
            .reconnect
        case .offline, .dns, .refused, .tls:
            .stop
        case .http_401, .http_403:
            !triedAgain && sinceSwitch < 3 ? .sameCopy(after: 1.5) : .stop
        case .http_5xx, .timeout, .reset:
            triedAgain ? .nextCopy : .sameCopy(after: 1)
        case .http_404, .http_other, .redirect_loop, .probe_failed, .decode, .no_data, .no_frame, .eof_before_frame, .unknown:
            .nextCopy
        }
    }
}

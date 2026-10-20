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

    init?(lookup error: SourceError) {
        switch error {
        case .cancelled: return nil
        case .offline: self = .offline
        case .rejected: self = .http_401
        case let .http(code):
            self = switch code {
            case 401: .http_401
            case 403: .http_403
            case 404: .http_404
            case 429: .http_429
            case 500..<600: .http_5xx
            default: .http_other
            }
        case let .network(_, code):
            self = switch code {
            case .timedOut?: .timeout
            case .cannotFindHost?, .dnsLookupFailed?: .dns
            case .cannotConnectToHost?: .refused
            case .secureConnectionFailed?, .serverCertificateUntrusted?, .serverCertificateHasBadDate?, .serverCertificateNotYetValid?,
                 .serverCertificateHasUnknownRoot?, .clientCertificateRejected?: .tls
            default: .unknown
            }
        case .unexpected: self = .unknown
        }
    }

    /// The words of the warnings classed here, in ffmpeg's format strings:
    /// its decoders warn hundreds of times a second on a damaged stream, and
    /// those lines are dropped before they're written out.
    private static let formatWords: [StaticString] = [
        "HTTP error", "Server returned", "Connection to", "Connection reset", "Failed to resolve", "timed out",
        "TLS", "SSL", "certificate", "edirect", "codec parameters", "Could not open codec", "Failed to initialize",
        "Invalid data",
    ]

    static func worthReading(format: UnsafePointer<CChar>) -> Bool {
        let length = strlen(format)
        return formatWords.contains { memmem(format, length, $0.utf8Start, $0.utf8CodeUnitCount) != nil }
    }

    enum Kind: Equatable {
        case gone, flaky, turnedAway, tooMany, unreachable, offline
    }

    var kind: Kind {
        switch self {
        case .http_429: .tooMany
        case .offline: .offline
        case .dns, .refused, .tls: .unreachable
        case .http_401, .http_403: .turnedAway
        case .http_5xx, .timeout, .reset: .flaky
        case .http_404, .http_other, .redirect_loop, .probe_failed, .decode, .no_data, .no_frame, .eof_before_frame, .unknown: .gone
        }
    }
}

/// ffmpeg's warnings come from every player and every load at once, with
/// nothing saying whose: one counts for a load only while that load alone
/// is open.
struct FailureLedger {
    struct Load: Hashable {
        let player: Int
        let attempt: Int
    }

    private var open: Set<Load> = []
    private var found: [Load: (failure: StreamFailure, at: Double)] = [:]

    mutating func began(_ load: Load) {
        open.insert(load)
    }

    mutating func ended(_ load: Load) {
        open.remove(load)
    }

    mutating func closed(player: Int) {
        open = open.filter { $0.player != player }
        found = found.filter { $0.key.player != player }
    }

    mutating func record(_ failure: StreamFailure, at time: Double) {
        guard open.count == 1, let load = open.first else { return }
        found[load] = (failure, time)
    }

    func failure(of load: Load, since time: Double) -> StreamFailure? {
        guard let last = found[load], last.at >= time else { return nil }
        return last.failure
    }
}

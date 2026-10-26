import Foundation

/// What the player shows while a film or channel starts, or while its
/// picture is gone during play. The players say where the start is; this
/// says what to draw: the ring alone for the first second (a quick start
/// flashes no words), then the step, from 8 s what is slow, and in the end
/// why it didn't start.
struct LoadProgress: Equatable {
    enum Subject: Equatable {
        case film(String)
        case channel(String)
    }

    enum Wait: Equatable {
        /// From the tap (or Try again).
        case start
        /// The stream dropped during play, and a new one is on its way.
        case reconnect
        /// The stream is open, and its data stopped coming.
        case stall
    }

    /// The three dashes. Films: the server's plan, the file, the first
    /// picture. Channels: the stream's address and answer, its first data,
    /// the first picture.
    enum Stage: Int, Equatable, CaseIterable {
        case asking, fetching, starting
    }

    /// Who the wait is on.
    enum Cause: Equatable {
        /// The Emby server, or the TV provider.
        case server
        /// The channel's stream.
        case channel
        /// This device's own connection.
        case connection
        case offline
    }

    struct Failure: Equatable {
        enum Kind: Equatable {
            case noPicture
            case ended
            /// What the server or provider answered.
            case refused(String)
        }

        var kind: Kind
        var tries: Int
        var seconds: Double
        /// Another channel has the same event.
        var otherChannels = false
    }

    var subject: Subject
    var wait = Wait.start
    var stage = Stage.asking
    /// Channels, fetching: what has arrived of what the start needs.
    var received: Double?
    var cause: Cause
    /// The tap, Try again, or the moment the picture went.
    var began: Date
    var failure: Failure?

    static let wordsAfter = 1.0
    static let dropShownAfter = 3.0
    static let slowAfter = 8.0

    struct Shown: Equatable {
        /// How full the ring is; none once it has given up.
        var ring: Double?
        var line: String?
        var details: [String] = []
        /// Steps reached, of three.
        var dashes: Int?
        var tryAgain = false
        var otherChannels = false
    }

    func shown(at now: Date) -> Shown? {
        if let failure { return failed(failure) }
        let elapsed = now.timeIntervalSince(began)
        let line: String?
        switch wait {
        case .start:
            guard elapsed >= Self.wordsAfter else { return Shown(ring: fill) }
            line = stageLine
        case .reconnect:
            guard elapsed >= Self.dropShownAfter else { return nil }
            line = reconnectLine
        case .stall:
            guard elapsed >= Self.dropShownAfter else { return nil }
            line = nil
        }
        guard elapsed >= Self.slowAfter else {
            return Shown(ring: fill, line: line, dashes: wait == .start ? stage.rawValue + 1 : nil)
        }
        return Shown(ring: fill, line: line, details: ["\(slowLine) · \(Int(elapsed)) s"], tryAgain: true)
    }

    private var fill: Double {
        switch (wait, stage) {
        case (.stall, _): 0.25
        case (_, .asking): 0.15
        case (_, .fetching): (1 + min(max(received ?? 0, 0), 1)) / 3
        case (_, .starting): 0.85
        }
    }

    private var stageLine: String {
        switch (subject, stage) {
        case (.film, .asking): "Asking your server"
        case (.film, .fetching): "Opening the film"
        case let (.channel(name), .asking): "Connecting to \(name)"
        case (.channel, .fetching): received.map { "Getting the picture · \(Self.percent($0))%" } ?? "Getting the picture"
        case (_, .starting): "Starting"
        }
    }

    private var reconnectLine: String {
        switch subject {
        case let .channel(name): "Reconnecting to \(name)…"
        case .film: stageLine
        }
    }

    private var slowLine: String {
        switch (cause, subject) {
        case (.server, .film): wait == .start && stage != .starting ? "Your server is slow to answer" : "Your server is slow to send the film"
        case (.server, .channel): "Your TV provider is slow to answer"
        case (.channel, _): "The channel is slow to send"
        case (.connection, _): "Your connection is slow"
        case (.offline, _): "No internet connection"
        }
    }

    private func failed(_ failure: Failure) -> Shown {
        let headline: String
        var details: [String] = []
        switch (failure.kind, subject) {
        case let (.noPicture, .channel(name)): headline = "\(name) isn’t sending a picture"
        case let (.noPicture, .film(title)): headline = "Your server isn’t sending \(title)"
        case let (.ended, .channel(name)), let (.ended, .film(name)): headline = "\(name) stopped before it started"
        case let (.refused(why), .channel(name)), let (.refused(why), .film(name)):
            headline = "\(name) didn’t open"
            details.append(why)
        }
        let seconds = max(1, Int(failure.seconds.rounded()))
        details.append("The app tried \(failure.tries == 1 ? "once" : "\(failure.tries) times") in \(seconds) s.")
        let others: Bool
        if case .channel = subject { others = failure.otherChannels } else { others = false }
        return Shown(line: headline, details: details, tryAgain: true, otherChannels: others)
    }

    /// Rounded down: 100% is the picture.
    private static func percent(_ received: Double) -> Int {
        Int((min(max(received, 0), 1) * 100).rounded(.down))
    }
}

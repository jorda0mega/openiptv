import Foundation

struct LoadProgress: Equatable {
    enum Wait: Equatable {
        case start
        case reconnect
    }

    enum Stage: Int, Equatable, CaseIterable {
        case asking, fetching, starting
    }

    enum Cause: Equatable {
        case server
        case channel
        case connection
        case offline
    }

    struct Failure: Equatable {
        enum Kind: Equatable {
            case noPicture
            case ended
            case refused(String)
        }

        var kind: Kind
        var tries: Int
        var seconds: Double
        var otherChannels = false
    }

    var channel: String
    var wait = Wait.start
    var stage = Stage.asking
    var cause: Cause
    var began: Date
    /// When the picture went (a freeze, or the loss itself): the notice
    /// counts its 3 s from there, the request's own wait from `began`.
    var pictureLost: Date?
    var failure: Failure?
    /// A start's first picture: the ring, once shown, stays a moment.
    var endedAt: Date?

    static let ringAfter = 1.0
    static let ringHeld = 0.5
    static let dropShownAfter = 3.0
    static let slowAfter = 8.0
    static let ring = 0.25

    var deadline: Date? {
        guard failure == nil, endedAt == nil, !StartPatience.off else { return nil }
        return (pictureLost ?? began).addingTimeInterval(StartPatience.failAfter / .seconds(1))
    }

    func overdue(at now: Date) -> Bool {
        deadline.map { now >= $0 } ?? false
    }

    /// A channel's wait: its start, or a drop (a reopen, offline, a frozen
    /// picture), each saying Reconnecting from when the picture went.
    static func channel(_ name: String, track: LoadTrack, loading: Bool, hasPicture: Bool, cause: Cause,
                        failure: Failure? = nil) -> LoadProgress? {
        if let failure { return LoadProgress(channel: name, cause: .channel, began: track.began, failure: failure) }
        if loading {
            return LoadProgress(channel: name, wait: hasPicture ? .reconnect : .start, stage: track.stage, cause: cause,
                                began: track.began, pictureLost: hasPicture ? track.pictureLost : nil)
        }
        if hasPicture, let since = track.stalledSince {
            return LoadProgress(channel: name, wait: .reconnect, stage: track.stage, cause: cause, began: since, pictureLost: since)
        }
        guard hasPicture, let ended = track.startEndedAt else { return nil }
        return LoadProgress(channel: name, cause: cause, began: track.began, endedAt: ended)
    }

    enum Button: Equatable {
        case tryAgain, otherChannels
    }

    struct Shown: Equatable {
        var ring: Double?
        var line: String?
        var details: [String] = []
        var tryAgain = false
        var otherChannels = false

        var buttons: [Button] {
            (tryAgain ? [.tryAgain] : []) + (otherChannels ? [.otherChannels] : [])
        }
    }

    /// Nil: nothing of the wait's (a drop's first seconds, a start done).
    func shown(at now: Date) -> Shown? {
        if let failure { return failed(failure) }
        let elapsed = now.timeIntervalSince(began)
        if let endedAt {
            let ringShown = endedAt.timeIntervalSince(began) >= Self.ringAfter
            return ringShown && elapsed < Self.ringAfter + Self.ringHeld ? Shown(ring: Self.ring) : nil
        }
        let line: String?
        switch wait {
        case .start:
            guard elapsed >= Self.ringAfter else { return Shown() }
            line = nil
        case .reconnect:
            guard now.timeIntervalSince(pictureLost ?? began) >= Self.dropShownAfter else { return nil }
            line = "Reconnecting to \(channel)…"
        }
        guard elapsed >= Self.slowAfter else { return Shown(ring: Self.ring, line: line) }
        return Shown(ring: Self.ring, line: line, details: ["\(slowLine) · \(Int(elapsed)) s"], tryAgain: true)
    }

    private var slowLine: String {
        switch cause {
        case .server: "Your TV provider is slow to answer"
        case .channel: "The channel is slow to send"
        case .connection: "Your connection is slow"
        case .offline: "No internet connection"
        }
    }

    private func failed(_ failure: Failure) -> Shown {
        let headline: String
        var details: [String] = []
        switch failure.kind {
        case .noPicture: headline = "\(channel) isn’t sending a picture"
        case .ended: headline = "\(channel) stopped before it started"
        case let .refused(why):
            headline = "\(channel) didn’t open"
            details.append(why)
        }
        let seconds = max(1, Int(failure.seconds.rounded()))
        details.append("The app tried \(failure.tries == 1 ? "once" : "\(failure.tries) times") in \(seconds) s.")
        return Shown(line: headline, details: details, tryAgain: true, otherChannels: failure.otherChannels)
    }
}

struct LoadTrack: Equatable {
    private(set) var began: Date
    private(set) var tries = 0
    private(set) var stage = LoadProgress.Stage.asking
    private(set) var addressed = false
    private(set) var dropped = false
    private(set) var stalledSince: Date?
    private(set) var pictureLost: Date?
    /// The first picture of a start (not of a drop).
    private(set) var startEndedAt: Date?
    private var failedAt: Date?
    private var pictureOn = false

    init(began: Date) {
        self.began = began
    }

    mutating func asked(at now: Date) {
        lost(at: now)
        tries += 1
        stage = .asking
        addressed = false
        failedAt = nil
    }

    mutating func gotAddress() {
        addressed = true
    }

    mutating func opened() {
        stage = stage == .asking ? .fetching : .starting
    }

    mutating func pictured(at now: Date) {
        startEndedAt = dropped ? nil : now
        pictureOn = true
        dropped = false
        stalledSince = nil
        pictureLost = nil
    }

    mutating func lost(at now: Date) {
        guard pictureOn else { return }
        pictureOn = false
        startEndedAt = nil
        dropped = true
        began = now
        pictureLost = stalledSince ?? now
        tries = 0
    }

    mutating func stalled(at now: Date) {
        if stalledSince == nil { stalledSince = now }
    }

    mutating func flowing() {
        stalledSince = nil
    }

    mutating func failed(at now: Date) {
        if failedAt == nil { failedAt = now }
    }

    func failure(_ kind: LoadProgress.Failure.Kind, otherChannels: Bool = false) -> LoadProgress.Failure {
        .init(kind: kind, tries: max(tries, 1), seconds: (failedAt ?? began).timeIntervalSince(began), otherChannels: otherChannels)
    }
}

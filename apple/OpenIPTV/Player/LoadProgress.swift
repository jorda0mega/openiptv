import Foundation

struct LoadProgress: Equatable {
    enum Subject: Equatable {
        case film(String)
        case channel(String)
    }

    enum Wait: Equatable {
        case start
        case reconnect
        case stall
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
            case cutOff
            case refused(String)
        }

        var kind: Kind
        var tries: Int
        var seconds: Double
        var otherChannels = false
    }

    var subject: Subject
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
        let subject = Subject.channel(name)
        if let failure { return LoadProgress(subject: subject, cause: .channel, began: track.began, failure: failure) }
        if loading {
            return LoadProgress(subject: subject, wait: hasPicture ? .reconnect : .start, stage: track.stage, cause: cause,
                                began: track.began, pictureLost: hasPicture ? track.pictureLost : nil)
        }
        if hasPicture, let since = track.stalledSince {
            return LoadProgress(subject: subject, wait: .reconnect, stage: track.stage, cause: cause, began: since, pictureLost: since)
        }
        guard hasPicture, let ended = track.startEndedAt else { return nil }
        return LoadProgress(subject: subject, cause: cause, began: track.began, endedAt: ended)
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
            line = reconnectLine
        case .stall:
            guard elapsed >= Self.dropShownAfter else { return nil }
            line = nil
        }
        guard elapsed >= Self.slowAfter else { return Shown(ring: Self.ring, line: line) }
        return Shown(ring: Self.ring, line: line, details: ["\(slowLine) · \(Int(elapsed)) s"], tryAgain: true)
    }

    private var reconnectLine: String? {
        guard case let .channel(name) = subject else { return nil }
        return "Reconnecting to \(name)…"
    }

    private var slowLine: String {
        switch (cause, subject) {
        case (.server, .film):
            wait == .start && stage != .starting
                ? "Your server is slow to answer"
                : "Your server is slow to send the film"
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
        case let (.cutOff, .film(title)): headline = "Your server stopped sending \(title)"
        case let (.cutOff, .channel(name)): headline = "\(name) stopped sending"
        case let (.refused(why), .channel(name)), let (.refused(why), .film(name)):
            headline = "\(name) didn’t open"
            details.append(why)
        }
        let seconds = max(1, Int(failure.seconds.rounded()))
        details.append("The app tried \(failure.tries == 1 ? "once" : "\(failure.tries) times") in \(seconds) s.")
        let others = if case .channel = subject { failure.otherChannels } else { false }
        return Shown(line: headline, details: details, tryAgain: true, otherChannels: others)
    }
}

struct LoadTrack: Equatable {
    private(set) var began: Date
    private(set) var tries = 0
    private(set) var stage: LoadProgress.Stage
    private(set) var addressed = false
    private(set) var dropped = false
    /// The picture waiting: for data that stopped, or for a jump to land;
    /// from the earlier of the two.
    var stalledSince: Date? { [dataStoppedAt, jumpAskedAt].compactMap { $0 }.min() }
    private var dataStoppedAt: Date?
    private var jumpAskedAt: Date?
    private var landedJumpAsked: Date?
    private var landedAt: Date?
    private var playerSeeking = false
    private(set) var pictureLost: Date?
    /// The first picture of a start (not of a drop).
    private(set) var startEndedAt: Date?
    private(set) var attempt: Int
    private var failedAt: Date?
    private var pictureOn = false
    private let firstStage: LoadProgress.Stage

    init(began: Date, stage: LoadProgress.Stage = .asking, attempt: Int = 0) {
        self.began = began
        self.stage = stage
        self.attempt = attempt
        firstStage = stage
    }

    @discardableResult
    mutating func asked(_ stage: LoadProgress.Stage = .asking, at now: Date) -> Int {
        lost(at: now)
        tries += 1
        self.stage = stage
        addressed = false
        failedAt = nil
        return nextAttempt()
    }

    /// A load that isn't a try of its own (another quality during play).
    mutating func nextAttempt() -> Int {
        attempt += 1
        return attempt
    }

    func isCurrent(_ attempt: Int) -> Bool {
        attempt == self.attempt
    }

    func stillFailed(_ attempt: Int) -> Bool {
        isCurrent(attempt) && failedAt != nil
    }

    /// Try again: the wait starts over, the attempts keep counting.
    mutating func restart(at now: Date) {
        self = LoadTrack(began: now, stage: firstStage, attempt: attempt)
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
        dataStoppedAt = nil
        jumpAskedAt = nil
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
        if dataStoppedAt == nil { dataStoppedAt = now }
    }

    mutating func flowing() {
        dataStoppedAt = nil
    }

    mutating func jumping(at now: Date) {
        if jumpAskedAt == nil { jumpAskedAt = now }
    }

    /// At a read's end the player calls its jump landed a moment before
    /// the end itself.
    mutating func landed(at now: Date) {
        if let jumpAskedAt {
            landedJumpAsked = jumpAskedAt
            landedAt = now
        }
        jumpAskedAt = nil
    }

    /// The player on its way to a jump, or done seeking (landed only once
    /// the picture is back: `landed(at:)`). While choosing where to
    /// jump its previews don't wait; a jump still on its way once the
    /// choice ends does, from then.
    mutating func seeking(_ on: Bool, choosing: Bool, at now: Date) {
        playerSeeking = on
        if on, !choosing { jumping(at: now) }
    }

    mutating func choosingEnded(at now: Date) {
        if playerSeeking { jumping(at: now) }
    }

    mutating func failed(at now: Date) {
        if failedAt == nil { failedAt = now }
    }

    func end(at position: Double, of total: Double) -> FilmEnd {
        let cutOff = stalledSince != nil || (total > 0 && total - position > Self.endSlack)
        return FilmEnd(cutOff: cutOff, place: cutOff ? position : total)
    }

    mutating func cutOff(at now: Date) {
        let justLanded = landedAt.map { now.timeIntervalSince($0) < 1 } == true ? landedJumpAsked : nil
        let since = stalledSince ?? justLanded ?? now
        lost(at: since)
        failed(at: now)
    }

    static let endSlack = 10.0

    func failure(_ kind: LoadProgress.Failure.Kind, otherChannels: Bool = false) -> LoadProgress.Failure {
        .init(kind: kind, tries: max(tries, 1), seconds: (failedAt ?? began).timeIntervalSince(began), otherChannels: otherChannels)
    }
}

struct FilmEnd: Equatable {
    var cutOff: Bool
    var place: Double
}

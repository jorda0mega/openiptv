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
    var received: Double?
    var cause: Cause
    var began: Date
    /// When the picture went (a freeze, or the loss itself): the notice
    /// counts its 3 s from there, the request's own wait from `began`.
    var pictureLost: Date?
    var failure: Failure?

    static let wordsAfter = 1.0
    static let dropShownAfter = 3.0
    static let slowAfter = 8.0

    var deadline: Date? {
        guard failure == nil, !StartPatience.off else { return nil }
        return began.addingTimeInterval(StartPatience.failAfter / .seconds(1))
    }

    func overdue(at now: Date) -> Bool {
        deadline.map { now >= $0 } ?? false
    }

    enum Button: Equatable {
        case tryAgain, otherChannels
    }

    struct Shown: Equatable {
        var ring: Double?
        var line: String?
        var details: [String] = []
        var dashes: Int?
        var tryAgain = false
        var otherChannels = false

        var buttons: [Button] {
            (tryAgain ? [.tryAgain] : []) + (otherChannels ? [.otherChannels] : [])
        }
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
            guard now.timeIntervalSince(pictureLost ?? began) >= Self.dropShownAfter else { return nil }
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
        case (.channel, .fetching):
            received.map { "Getting the picture · \(Self.percent($0))%" } ?? "Getting the picture"
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
        case let (.refused(why), .channel(name)), let (.refused(why), .film(name)):
            headline = "\(name) didn’t open"
            details.append(why)
        }
        let seconds = max(1, Int(failure.seconds.rounded()))
        details.append("The app tried \(failure.tries == 1 ? "once" : "\(failure.tries) times") in \(seconds) s.")
        let others = if case .channel = subject { failure.otherChannels } else { false }
        return Shown(line: headline, details: details, tryAgain: true, otherChannels: others)
    }

    private static func percent(_ received: Double) -> Int {
        Int((min(max(received, 0), 1) * 100).rounded(.down))
    }
}

struct LoadTrack: Equatable {
    private(set) var began: Date
    private(set) var tries = 0
    private(set) var stage: LoadProgress.Stage
    private(set) var received: Double?
    private(set) var addressed = false
    private(set) var dropped = false
    private(set) var stalledSince: Date?
    private(set) var pictureLost: Date?
    private var failedAt: Date?
    private var pictureOn = false

    init(began: Date, stage: LoadProgress.Stage = .asking) {
        self.began = began
        self.stage = stage
    }

    mutating func asked(_ stage: LoadProgress.Stage = .asking, at now: Date) {
        lost(at: now)
        tries += 1
        self.stage = stage
        received = nil
        addressed = false
        failedAt = nil
    }

    mutating func gotAddress() {
        addressed = true
    }

    mutating func opened() {
        if stage == .asking {
            stage = .fetching
            received = 0
        } else {
            stage = .starting
        }
    }

    mutating func received(_ have: Double, of need: Double) {
        guard stage == .fetching else { return }
        received = have / need
        if have >= need { stage = .starting }
    }

    mutating func pictured() {
        pictureOn = true
        dropped = false
        stalledSince = nil
        pictureLost = nil
    }

    mutating func lost(at now: Date) {
        guard pictureOn else { return }
        pictureOn = false
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

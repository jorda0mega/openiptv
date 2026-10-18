import Foundation

/// One source's record of being asked for its lineup: when it last
/// answered, when it was last asked, and why the last ask failed. Only an
/// answer moves `answeredAt`, so a failed check can't make old games look
/// current.
struct LineupCheck: Sendable {
    /// When the provider last returned its lineup; saved with the lineup
    /// and restored at launch.
    private(set) var answeredAt: Date?
    /// When it was last asked this session (nil until the first ask ends:
    /// the saved `answeredAt` decides).
    private(set) var askedAt: Date?
    /// Why the last ask failed, until one succeeds.
    private(set) var problem: SourceError?

    init(answeredAt: Date? = nil) {
        self.answeredAt = answeredAt
    }

    mutating func record(_ result: Result<Void, SourceError>, at now: Date) {
        askedAt = now
        switch result {
        case .success:
            answeredAt = now
            problem = nil
        case let .failure(error):
            problem = error
        }
    }

    /// When to ask next, for a page that wants its lineup no older than
    /// `maxAge`. With no connection the provider was never reached, so
    /// within a minute; anything else (a 429, a 5xx, a rejected login, a
    /// timeout) waits the whole interval: a busy provider isn't asked again
    /// and again.
    func nextAsk(maxAge: TimeInterval) -> Date {
        guard let last = askedAt ?? answeredAt else { return .distantPast }
        if case .offline = problem { return last + min(maxAge, 60) }
        return last + maxAge
    }
}

/// What Sports says about how current its games are.
enum GamesNotice: Equatable {
    /// The games as listed, or "Nothing on right now".
    case current
    /// Not checked yet this session, and a check running: "Checking for
    /// games…" instead of "Nothing on right now".
    case checking
    /// The last check failed: said above the games, or in place of
    /// "Nothing on right now".
    case couldNotUpdate(lastUpdated: Date?, reason: String)
}

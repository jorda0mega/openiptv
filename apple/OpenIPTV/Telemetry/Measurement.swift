import Foundation

enum Metric {
    enum Name: String, CaseIterable, Sendable {
        case filmStartFirstTap = "film.start.first_tap"
        case filmStartPrepared = "film.start.prepared"
        case filmStartResume = "film.start.resume"
        case filmStartFromBeginning = "film.start.from_beginning"
        case filmJumpForward10s = "film.jump.forward_10s"
        case filmJumpBack10s = "film.jump.back_10s"
        case filmJumpForward5min = "film.jump.forward_5min"
        case pipStartGap = "film.pip.start_gap"
        case pipReturnGap = "film.pip.return_gap"
        case liveStart = "live.start"
        case liveSwitch = "live.switch"
    }

    enum Key: String, CaseIterable, Sendable {
        case platform, network, picture, prepared, resumed
        case loadingShown = "loading_shown"

        var values: Set<String> {
            switch self {
            case .platform: Set(Platform.allCases.map(\.rawValue))
            case .network: Set(Network.allCases.map(\.rawValue))
            case .picture: Set(Picture.allCases.map(\.rawValue))
            case .prepared, .resumed, .loadingShown: [Self.yes, Self.no]
            }
        }

        static let yes = "yes"
        static let no = "no"
    }

    enum Platform: String, CaseIterable, Sendable { case iphone, ipad, appletv, mac }

    enum Network: String, CaseIterable, Sendable {
        case wifi, phone, unknown
        case lowData = "low_data"

        init(_ network: Conditions.Network) {
            switch network {
            case .unmetered: self = .wifi
            case .expensive: self = .phone
            case .constrained: self = .lowData
            case .unknown: self = .unknown
            }
        }
    }

    enum Picture: String, CaseIterable, Sendable {
        case gpu, software

        init(drawsFrames: Bool) { self = drawsFrames ? .software : .gpu }
    }

    enum PipEdge: Sendable { case start, `return` }
    enum LiveOpen: Sendable { case start, `switch` }

    enum Reading: Sendable {
        case filmStarted(prepared: Bool, resumes: Bool, picture: Picture, seconds: Double)
        case filmJumped(by: Double, picture: Picture, seconds: Double)
        case pipGap(PipEdge, seconds: Double)
        case liveOpened(LiveOpen, seconds: Double)
    }

    struct Sample: Equatable, Sendable {
        let name: Name
        let seconds: Double
        let states: [Key: String]
    }

    struct Recorder: Sendable {
        let platform: Platform
        private var filmStarted = false

        init(platform: Platform) {
            self.platform = platform
        }

        mutating func sample(_ reading: Reading, network: Network) -> Sample? {
            nil
        }
    }

    struct FrameGap: Equatable, Sendable {
        let began: Double

        init(began: Double) {
            self.began = began
        }

        mutating func frame(at time: Double) {}

        mutating func held() {}

        func longest(until end: Double) -> Double? {
            nil
        }
    }
}

enum Problem: Equatable, Sendable {
    case filmDidNotStart(StreamFailure)
    case filmStopped(StreamFailure)
    case liveDidNotStart(StreamFailure)
    case liveStopped(StreamFailure)

    enum Kind: String, CaseIterable, Sendable {
        case filmDidNotStart = "film.did_not_start"
        case filmStopped = "film.stopped"
        case liveDidNotStart = "live.did_not_start"
        case liveStopped = "live.stopped"
    }

    var kind: Kind { .filmStopped }
    var reason: StreamFailure { .unknown }
}

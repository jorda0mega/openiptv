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
            case .prepared, .resumed, .loadingShown: [Self.word(true), Self.word(false)]
            }
        }

        static func word(_ on: Bool) -> String { on ? "yes" : "no" }
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
        case filmStarted(firstTap: Bool, prepared: Bool, resumes: Bool, picture: Picture, seconds: Double)
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

        func sample(_ reading: Reading, network: Network) -> Sample? {
            var states: [Key: String] = [.platform: platform.rawValue, .network: network.rawValue]
            switch reading {
            case let .filmStarted(firstTap, prepared, resumes, picture, seconds):
                states[.picture] = picture.rawValue
                states[.prepared] = Key.word(prepared)
                states[.resumed] = Key.word(resumes)
                states[.loadingShown] = Key.word(seconds >= LoadProgress.ringAfter)
                return Sample(name: Self.filmStartName(firstTap: firstTap, prepared: prepared, resumes: resumes),
                              seconds: seconds, states: states)
            case let .filmJumped(by, picture, seconds):
                guard let name = Self.jumpName(by) else { return nil }
                states[.picture] = picture.rawValue
                states[.loadingShown] = Key.word(seconds >= LoadProgress.dropShownAfter)
                return Sample(name: name, seconds: seconds, states: states)
            case let .pipGap(edge, seconds):
                states[.picture] = Picture.software.rawValue
                return Sample(name: edge == .start ? .pipStartGap : .pipReturnGap, seconds: seconds, states: states)
            case let .liveOpened(open, seconds):
                states[.picture] = Picture.gpu.rawValue
                states[.loadingShown] = Key.word(seconds >= LoadProgress.ringAfter)
                return Sample(name: open == .start ? .liveStart : .liveSwitch, seconds: seconds, states: states)
            }
        }

        private static func filmStartName(firstTap: Bool, prepared: Bool, resumes: Bool) -> Name {
            if firstTap { return .filmStartFirstTap }
            if prepared { return .filmStartPrepared }
            return resumes ? .filmStartResume : .filmStartFromBeginning
        }

        private static func jumpName(_ seconds: Double) -> Name? {
            switch seconds {
            case 10: .filmJumpForward10s
            case -10: .filmJumpBack10s
            case 300: .filmJumpForward5min
            default: nil
            }
        }
    }

    struct FrameGap: Equatable, Sendable {
        let began: Double
        private var last: Double
        private var longest = 0.0
        private var wasHeld = false

        init(began: Double) {
            self.began = began
            last = began
        }

        mutating func frame(at time: Double) {
            guard time >= last else { return }
            longest = max(longest, time - last)
            last = time
        }

        mutating func held() {
            wasHeld = true
        }

        func longest(until end: Double) -> Double? {
            wasHeld ? nil : max(longest, end - last)
        }
    }
}

enum Problem: Equatable, Sendable {
    case filmDidNotStart(StreamFailure)
    case filmStopped(StreamFailure)
    case liveDidNotStart(StreamFailure)
    case liveStopped(StreamFailure)

    enum Kind: String, CaseIterable, Sendable {
        case filmDidNotStart = "film_did_not_start"
        case filmStopped = "film_stopped"
        case liveDidNotStart = "live_did_not_start"
        case liveStopped = "live_stopped"
    }

    var kind: Kind {
        switch self {
        case .filmDidNotStart: .filmDidNotStart
        case .filmStopped: .filmStopped
        case .liveDidNotStart: .liveDidNotStart
        case .liveStopped: .liveStopped
        }
    }

    var reason: StreamFailure {
        switch self {
        case let .filmDidNotStart(reason), let .filmStopped(reason), let .liveDidNotStart(reason), let .liveStopped(reason): reason
        }
    }

    var reasonWord: String {
        reason.rawValue.replacingOccurrences(of: "http_", with: "status_")
    }
}

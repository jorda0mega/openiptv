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

    struct FilmTap: Hashable, Sendable {
        let first: Bool
        let prepared: Bool
    }

    enum PipEdge: Sendable { case start, `return` }
    enum LiveOpen: Sendable { case start, `switch` }

    enum Reading: Sendable {
        case filmStarted(FilmTap, resumes: Bool, picture: Picture, seconds: Double)
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
            case let .filmStarted(tap, resumes, picture, seconds):
                states[.picture] = picture.rawValue
                states[.prepared] = Key.word(tap.prepared)
                states[.resumed] = Key.word(resumes)
                states[.loadingShown] = Key.word(seconds >= LoadProgress.ringAfter)
                return Sample(name: Self.filmStartName(tap, resumes: resumes), seconds: seconds, states: states)
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

        private static func filmStartName(_ tap: FilmTap, resumes: Bool) -> Name {
            if tap.first { return .filmStartFirstTap }
            if tap.prepared { return .filmStartPrepared }
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

struct Problem: Equatable, Sendable {
    enum Subject: String, CaseIterable, Sendable { case film, live }

    let subject: Subject
    let started: Bool
    let reason: StreamFailure

    var kind: String { Self.kind(subject, started: started) }

    var reasonWord: String {
        reason.rawValue.replacingOccurrences(of: "http_", with: "status_")
    }

    static var kinds: [String] {
        Subject.allCases.flatMap { [kind($0, started: false), kind($0, started: true)] }
    }

    private static func kind(_ subject: Subject, started: Bool) -> String {
        subject.rawValue + (started ? "_stopped" : "_did_not_start")
    }
}

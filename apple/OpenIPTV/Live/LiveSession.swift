import Foundation

/// One live screen's stream: the copy asked for, what became of it, and
/// what to do next. The screen feeds it what happens and runs the actions
/// it returns. Every load has an attempt number; an input from an older
/// attempt changes nothing.
struct LiveSession<Copy: Identifiable & Equatable> where Copy.ID == String {
    typealias Attempt = Int

    enum Phase: Equatable {
        case idle
        case opening(Copy)
        case playing(Copy)
        case reopening(Copy)
        case cutWhilePaused(Copy)
        case offline(Copy, hadPicture: Bool)
        case away(Copy)
        case recording(started: Bool)
        case failed(Failure)
    }

    enum Failure: Equatable {
        case notPlaying
        case ended
        case message(String)
    }

    enum Input {
        case play(Copy, feeds: [[Copy]], after: Double, startLimit: Double)
        case recording
        case opening(Attempt)
        case started(Attempt)
        case failed(Attempt, StreamFailure, shown: Failure)
        case ended(Attempt, StreamFailure)
        case online
        case paused(Bool)
        case away(keepsStream: Bool)
        case back
    }

    enum Action: Equatable {
        case load(Copy, Attempt, after: Double)
        case loadRecording(Attempt)
        case stop
        case deadline(Attempt, after: Double)
        case waitForNetwork
        case clearTimeline
        case unpause
        case picture
        case goLive
        case markFailed(Copy)
        case markNotPlaying
        case played(Copy)
        case switching(from: Copy)
        case switched(from: Copy, to: Copy)
    }

    /// A provider allowing one stream at a time can still count the stream
    /// let go for a moment, and refuse the next.
    static var refusalWindow: TimeInterval { 3 }

    /// On an Apple TV, AirPlay is its own speakers.
    static func keepsStreamAway(airPlay: Bool, onTV: Bool) -> Bool {
        airPlay && !onTV
    }

    private(set) var phase = Phase.idle
    private(set) var attempt: Attempt = 0
    private(set) var copy: Copy?
    private var picked: Copy?
    private var feeds: [[Copy]] = []
    private var tried: Set<String> = []
    private var triedAgain: Set<String> = []
    private var cueing = false
    private var cuts = LiveCuts()
    private var paused = false
    private var releasedAt = Date.distantPast
    private var startLimit: Double = 15

    var triedCount: Int { tried.count }

    var hasPicture: Bool {
        switch phase {
        case .playing, .reopening, .cutWhilePaused, .away: true
        case let .offline(_, hadPicture): hadPicture
        case let .recording(started): started
        case .idle, .opening, .failed: false
        }
    }

    var isLoading: Bool {
        switch phase {
        case .opening, .reopening, .offline: true
        case let .recording(started): !started
        case .idle, .playing, .cutWhilePaused, .away, .failed: false
        }
    }

    var failure: Failure? {
        guard case let .failed(failure) = phase else { return nil }
        return failure
    }

    var readout: String {
        switch phase {
        case .idle, .opening: "starting"
        case .playing, .cutWhilePaused: "playing"
        case .reopening: "reopening"
        case .offline: "waiting"
        case .away: "away"
        case let .recording(started): started ? "playing" : "starting"
        case .failed: "failed"
        }
    }

    mutating func handle(_ input: Input, now: Date = Date()) -> [Action] {
        switch input {
        case let .play(first, feeds, after, startLimit):
            picked = first
            self.feeds = feeds
            self.startLimit = startLimit
            tried = [first.id]
            triedAgain = []
            cueing = false
            cuts = LiveCuts()
            return [.unpause] + open(first, after: after)
        case .recording:
            cueing = false
            attempt += 1
            phase = .recording(started: false)
            return [.clearTimeline, .unpause, .loadRecording(attempt)]
        case let .opening(at):
            guard at == attempt else { return [] }
            releasedAt = now
            switch phase {
            case .opening, .reopening: return [.deadline(at, after: startLimit)]
            default: return []
            }
        case let .started(at):
            guard at == attempt else { return [] }
            return started(now)
        case let .failed(at, failure, shown):
            guard at == attempt else { return [] }
            return failed(failure, shown, now)
        case let .ended(at, failure):
            guard at == attempt else { return [] }
            if case .recording(started: true) = phase { return [.goLive] }
            return failed(failure, .ended, now)
        case .online:
            guard case let .offline(copy, hadPicture) = phase else { return [] }
            attempt += 1
            phase = hadPicture ? .reopening(copy) : .opening(copy)
            return [.clearTimeline, .load(copy, attempt, after: 0)]
        case let .paused(isPaused):
            paused = isPaused
            guard !isPaused, case let .cutWhilePaused(copy) = phase else { return [] }
            return cut(copy, now)
        case let .away(keepsStream):
            guard paused, !keepsStream else { return [] }
            switch phase {
            case let .playing(copy), let .cutWhilePaused(copy):
                attempt += 1
                releasedAt = now
                phase = .away(copy)
                return [.stop]
            default:
                return []
            }
        case .back:
            guard case let .away(copy) = phase else { return [] }
            triedAgain = []
            return [.unpause] + open(copy, after: 0)
        }
    }

    private mutating func started(_ now: Date) -> [Action] {
        switch phase {
        case let .opening(copy), let .reopening(copy):
            phase = .playing(copy)
            cuts.played(copy.id, at: now)
            guard cueing, let picked else { return [.picture, .played(copy)] }
            cueing = false
            return [.picture, .played(copy), .switched(from: picked, to: copy)]
        case .recording(started: false):
            phase = .recording(started: true)
            return [.picture]
        default:
            return []
        }
    }

    private mutating func failed(_ failure: StreamFailure, _ shown: Failure, _ now: Date) -> [Action] {
        switch phase {
        case let .playing(copy):
            switch failure.kind {
            case .tooMany:
                return stop(shown, now)
            case .offline:
                return waitForNetwork(copy, hadPicture: true, now)
            case .gone, .flaky, .turnedAway, .unreachable:
                guard !paused else {
                    attempt += 1
                    phase = .cutWhilePaused(copy)
                    return []
                }
                return cut(copy, now)
            }
        case let .opening(copy):
            return failedStart(copy, failure, shown, hadPicture: false, now)
        case let .reopening(copy):
            return failedStart(copy, failure, shown, hadPicture: true, now)
        case .recording:
            return stop(shown, now)
        case .idle, .cutWhilePaused, .offline, .away, .failed:
            return []
        }
    }

    private mutating func failedStart(_ copy: Copy, _ failure: StreamFailure, _ shown: Failure, hadPicture: Bool, _ now: Date) -> [Action] {
        switch failure.kind {
        case .gone:
            return nextCopy(after: copy, marking: true, failure, shown, now)
        case .flaky:
            guard !triedAgain.contains(copy.id) else { return nextCopy(after: copy, marking: true, failure, shown, now) }
            return again(copy, after: 1)
        case .turnedAway:
            let released = now.timeIntervalSince(releasedAt)
            guard !triedAgain.contains(copy.id), released < Self.refusalWindow else { return stop(shown, now) }
            return again(copy, after: max(1.5, Self.refusalWindow - released))
        case .tooMany, .unreachable:
            return stop(shown, now)
        case .offline:
            return waitForNetwork(copy, hadPicture: hadPicture, now)
        }
    }

    private mutating func again(_ copy: Copy, after wait: Double) -> [Action] {
        triedAgain.insert(copy.id)
        attempt += 1
        return [.load(copy, attempt, after: wait)]
    }

    private mutating func nextCopy(after copy: Copy, marking: Bool, _ failure: StreamFailure, _ shown: Failure, _ now: Date) -> [Action] {
        let marks: [Action] = marking ? [.markFailed(copy)] : []
        guard let picked, let next = WatchOn.next(after: picked.id, feeds: feeds, tried: tried) else {
            return marks + (failure == .no_data ? [.markNotPlaying] : []) + stop(shown, now)
        }
        tried.insert(next.id)
        let cue: [Action] = cueing ? [] : [.switching(from: picked)]
        cueing = true
        return marks + cue + open(next, after: 0)
    }

    private mutating func cut(_ copy: Copy, _ now: Date) -> [Action] {
        switch cuts.cut(copy.id, at: now) {
        case let .reopen(after: wait):
            attempt += 1
            phase = .reopening(copy)
            return [.clearTimeline, .load(copy, attempt, after: wait)]
        case .giveUp:
            return nextCopy(after: copy, marking: false, .unknown, .notPlaying, now)
        }
    }

    private mutating func open(_ copy: Copy, after: Double) -> [Action] {
        attempt += 1
        self.copy = copy
        phase = .opening(copy)
        return [.clearTimeline, .load(copy, attempt, after: after)]
    }

    private mutating func waitForNetwork(_ copy: Copy, hadPicture: Bool, _ now: Date) -> [Action] {
        attempt += 1
        releasedAt = now
        phase = .offline(copy, hadPicture: hadPicture)
        return [.stop, .waitForNetwork]
    }

    private mutating func stop(_ shown: Failure, _ now: Date) -> [Action] {
        attempt += 1
        releasedAt = now
        phase = .failed(shown)
        return [.stop]
    }
}

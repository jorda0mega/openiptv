#if DEBUG
import CryptoKit
import Foundation
import Libmpv
import Network

protocol LivePerfWord: RawRepresentable<String> {}

extension StreamFailure: LivePerfWord {}

/// `PERF live` lines: numbers and fixed words only, never a URL, host,
/// name or mpv's own text (stream URLs carry the login).
enum LivePerf {
    enum Line: String { case open, fail, stall, net, end, path, codec, mpv }

    enum NoFailure: String, LivePerfWord { case none }

    enum Phase: String, LivePerfWord { case open, play }
    enum End: String, LivePerfWord { case eof, error, closed }
    enum Via: String, LivePerfWord { case wifi, cellular, wired, other, offline }
    enum Decoder: String, LivePerfWord { case videotoolbox, no, other }
    enum Agent: String, LivePerfWord { case mpv, lavf, other }
    enum Video: String, LivePerfWord { case h264, hevc, mpeg2video, av1, vp9, other }
    enum Audio: String, LivePerfWord { case aac, ac3, eac3, mp2, mp3, opus, other }

    /// The Xtream stream id, or the first 8 hex of SHA256 of the channel's id.
    struct Token {
        let text: String

        init(_ channel: LiveChannel) {
            if case let .xtream(streamId) = channel.stream {
                text = String(streamId)
            } else {
                text = SHA256.hash(data: Data(channel.id.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined()
            }
        }
    }

    enum Value {
        case count(Int)
        case decimal(Double, places: Int)
        case word(any LivePerfWord)
        case token(Token)

        static func ms(_ seconds: Double?) -> Value { .count(seconds.map { Int(($0 * 1000).rounded()) } ?? -1) }
        static func failure(_ failure: StreamFailure?) -> Value { failure.map { .word($0) } ?? .word(NoFailure.none) }
        static func flag(_ on: Bool) -> Value { .count(on ? 1 : 0) }

        var text: String {
            switch self {
            case let .count(n): String(n)
            case let .decimal(x, places): String(format: "%.\(places)f", x)
            case let .word(word): word.rawValue
            case let .token(token): token.text
            }
        }
    }

    static func say(_ line: Line, _ fields: KeyValuePairs<StaticString, Value>) {
        let text = (["PERF", "live", line.rawValue] + fields.map { "\($0.key)=\($0.value.text)" }).joined(separator: " ")
        guard safe(text) else { return assertionFailure("PERF live line refused") }
        NSLog("%@", text)
    }

    /// Letters, digits, space and `_=.-` only (no `/`, `:`, `@`), words of
    /// at most 32 characters, and a dot only in a decimal number after `=`
    /// (no host name or IP address).
    static func safe(_ line: String) -> Bool {
        let alphabet = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_=.- ")
        guard line.unicodeScalars.allSatisfy(alphabet.contains) else { return false }
        return line.split(separator: " ").allSatisfy { word in
            word.count <= 32 && (!word.contains(".") || word.wholeMatch(of: #/[A-Za-z0-9_]+=-?[0-9]+\.[0-9]+/#) != nil)
        }
    }

    enum Mark: String { case channel, game }

    static func sayMarkCleared(_ kind: Mark, _ mark: LiveFailures.Mark, now: Date = Date()) {
        let age = Int(now.timeIntervalSince(mark.noted).rounded())
        let text = "PERF mark cleared kind=\(kind.rawValue) age=\(age) before_kickoff=\(mark.beforeKickoff ? 1 : 0)"
        guard safe(text) else { return assertionFailure("PERF mark line refused") }
        NSLog("%@", text)
    }

    static func sayPath(_ path: NWPath) {
        let via: Via = path.status != .satisfied ? .offline
            : path.usesInterfaceType(.wifi) ? .wifi
            : path.usesInterfaceType(.cellular) ? .cellular
            : path.usesInterfaceType(.wiredEthernet) ? .wired : .other
        say(.path, ["via": .word(via), "expensive": .flag(path.isExpensive), "constrained": .flag(path.isConstrained)])
    }

    static func sayConfig(_ mpv: OpaquePointer) {
        let agent = string(mpv, "user-agent") ?? ""
        let ua: Agent = agent.isEmpty || agent.hasPrefix("Lavf") ? .lavf : agent.lowercased().contains("mpv") ? .mpv : .other
        say(.mpv, ["timeout": .decimal(string(mpv, "network-timeout").flatMap(Double.init) ?? -1, places: 1), "ua": .word(ua)])
    }

    static func sayCodec(_ mpv: OpaquePointer) {
        let hwdec = string(mpv, "hwdec-current") ?? "no"
        let decoder: Decoder = hwdec.hasPrefix("videotoolbox") ? .videotoolbox : hwdec == "no" ? .no : .other
        func number(_ name: String) -> Double { string(mpv, name).flatMap(Double.init) ?? -1 }
        say(.codec, [
            "v": .word(string(mpv, "current-tracks/video/codec").flatMap(Video.init(rawValue:)) ?? .other),
            "hw": .word(decoder),
            "w": .count(Int(number("video-params/w"))),
            "h": .count(Int(number("video-params/h"))),
            "fps": .decimal(number("container-fps"), places: 2),
            "kbps": .count(Int(number("video-bitrate") / 1000)),
            "a": .word(string(mpv, "current-tracks/audio/codec").flatMap(Audio.init(rawValue:)) ?? .other),
        ])
    }

    private static func string(_ mpv: OpaquePointer, _ name: String) -> String? {
        guard let value = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(value) }
        return String(cString: value)
    }

    /// The player's side of one open, in ms since `loadfile` (-1: not yet).
    struct Opening {
        var setup = -1
        var closeWait = -1
        var loadfile: CFAbsoluteTime?
        var opened = -1
        var failure: StreamFailure?
        var warnings = 0
        var drops = 0
    }

    /// One live screen's opens, stalls and ends, told by its events.
    @MainActor @Observable
    final class Watch {
        private(set) var failure: StreamFailure?
        @ObservationIgnored weak var player: MPVPlayer?
        @ObservationIgnored private var beganAt = CFAbsoluteTimeGetCurrent()
        @ObservationIgnored private var copy: Copy?

        private struct Copy {
            let token: Token
            let n: Int
            let of: Int
            let delay: Double
            var address: Double?
            var frameAt: CFAbsoluteTime?
            var stalls = 0
            var stalled = 0.0
            var stallBegan: CFAbsoluteTime?
            var lastNet: CFAbsoluteTime = 0
            var buffer = 0.0
            var mbps = 0.0
            var codecSaid = false
        }

        func began() {
            beganAt = CFAbsoluteTimeGetCurrent()
        }

        func opening(_ channel: LiveChannel, n: Int, of: Int, delay: Double) {
            closed()
            copy = Copy(token: Token(channel), n: n, of: of, delay: delay)
        }

        func addressed(in seconds: Double) {
            copy?.address = seconds
        }

        func started(frame seconds: Double) {
            guard let current = copy else { return }
            let now = CFAbsoluteTimeGetCurrent()
            copy?.frameAt = now
            copy?.lastNet = now
            sayOpen(current, player?.livePerf ?? Opening(), frame: seconds, tap: now - beganAt)
        }

        func failed() {
            finish { current, opening, now in
                self.fail(current, opening, now, or: .unknown)
                if current.frameAt != nil { self.end(current, opening, now, .error) }
            }
        }

        func ended() {
            finish { current, opening, now in
                if current.frameAt == nil {
                    self.fail(current, opening, now, or: .eof_before_frame)
                } else {
                    self.end(current, opening, now, .eof)
                }
            }
        }

        func timedOut() {
            guard copy?.frameAt == nil else { return }
            finish { current, opening, now in self.fail(current, opening, now, or: opening.opened < 0 ? .no_data : .no_frame) }
        }

        func closed() {
            finish { current, opening, now in
                if current.frameAt == nil { self.sayOpen(current, opening, frame: nil, tap: nil) }
                self.end(current, opening, now, .closed)
            }
        }

        func buffering(_ on: Bool) {
            guard var current = copy, current.frameAt != nil else { return }
            let now = CFAbsoluteTimeGetCurrent()
            if on, current.stallBegan == nil {
                current.stallBegan = now
                current.stalls += 1
            } else if !on, let began = current.stallBegan, let frameAt = current.frameAt {
                current.stallBegan = nil
                current.stalled += now - began
                say(.stall, ["tok": .token(current.token), "n": .count(current.stalls), "dur": .decimal(now - began, places: 1),
                             "at": .decimal(began - frameAt, places: 1), "buffer": .decimal(current.buffer, places: 1),
                             "Mbps": .decimal(current.mbps, places: 2)])
            }
            copy = current
        }

        func network(buffer: Double, bytesPerSecond: Double, gap: Double) {
            guard var current = copy, current.frameAt != nil else { return }
            current.buffer = buffer
            current.mbps = bytesPerSecond * 8 / 1_000_000
            let now = CFAbsoluteTimeGetCurrent()
            if now - current.lastNet >= 5 {
                current.lastNet = now
                say(.net, ["tok": .token(current.token), "Mbps": .decimal(current.mbps, places: 2), "buffer": .decimal(buffer, places: 1),
                           "gap": .decimal(gap, places: 1), "drops": .count(player?.livePerf.drops ?? -1)])
                if !current.codecSaid {
                    current.codecSaid = true
                    player?.sayLiveCodec()
                }
            }
            copy = current
        }

        /// libmpv hands over its warnings after the end of the file, so the
        /// lines are written once the player's queue has read them.
        private func finish(_ write: @escaping @MainActor (Copy, Opening, CFAbsoluteTime) -> Void) {
            guard let current = copy else { return }
            copy = nil
            let now = CFAbsoluteTimeGetCurrent()
            guard let player else { return write(current, Opening(), now) }
            player.withLivePerf { write(current, $0, now) }
        }

        private func sayOpen(_ current: Copy, _ opening: Opening, frame: Double?, tap: Double?) {
            say(.open, ["tok": .token(current.token), "copy": .count(current.n), "of": .count(current.of),
                        "setup": .count(opening.setup), "address": .ms(current.address), "delay": .ms(current.delay),
                        "closewait": .count(opening.closeWait), "opened": .count(opening.opened), "frame": .ms(frame), "tap": .ms(tap)])
        }

        private func fail(_ current: Copy, _ opening: Opening, _ now: CFAbsoluteTime, or otherwise: StreamFailure) {
            let phase: Phase = current.frameAt == nil ? .open : .play
            failure = opening.failure ?? otherwise
            if phase == .open { sayOpen(current, opening, frame: nil, tap: nil) }
            let since = phase == .open ? opening.loadfile : current.frameAt
            say(.fail, ["tok": .token(current.token), "copy": .count(current.n), "class": .failure(failure), "phase": .word(phase),
                        "at": .ms(since.map { now - $0 }), "warnings": .count(opening.warnings)])
        }

        private func end(_ current: Copy, _ opening: Opening, _ now: CFAbsoluteTime, _ reason: End) {
            let stalled = current.stalled + (current.stallBegan.map { now - $0 } ?? 0)
            if let failure = opening.failure { self.failure = failure }
            say(.end, ["tok": .token(current.token), "reason": .word(reason), "watched": .decimal(current.frameAt.map { now - $0 } ?? -1, places: 1),
                       "stalls": .count(current.stalls), "stalled": .decimal(stalled, places: 1), "class": .failure(opening.failure),
                       "warnings": .count(opening.warnings)])
        }
    }
}
#endif

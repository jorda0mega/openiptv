import Foundation

struct PlanKey: Hashable, Sendable {
    let itemId: String
    let kind: String?
    let versions: [String]

    static func == (a: PlanKey, b: PlanKey) -> Bool { a.itemId == b.itemId && a.versions == b.versions }

    func hash(into hasher: inout Hasher) {
        hasher.combine(itemId)
        hasher.combine(versions)
    }
}

extension Lane {
    static let emby = Lane(.light, atOnce: 4, conditions: Conditions.current)
}

@MainActor
enum Plans {
    static func shelf(lane: Lane? = nil, now: @escaping @Sendable () -> Date = { Date() },
                      fetch: @escaping @Sendable (PlanKey) async throws -> EmbyPlayback) -> Shelf<PlanKey, EmbyPlayback> {
        Shelf(.init(lane: lane ?? .emby, lifetime: .seconds(180), failureKept: .zero), now: now, fetch: fetch)
    }

    static func forecast(_ keys: [PlanKey], on shelf: Shelf<PlanKey, EmbyPlayback>) async {}
}

#if DEBUG
/// Debug builds: where a plan's time went, request by request: the copy it
/// was for, when it was sent against the tap, how many of the app's other
/// requests to the server were under way then, and its wait for a
/// connection, the server's wait and the answer's transfer. Counts and
/// times only, never an id or an address.
final class PlanClock: Sendable {
    @TaskLocal static var current: PlanClock?
    /// The app's requests to the server under way (HTTP.data), and the library's pages among them.
    static let underWay = Locked(0)
    static let pagesUnderWay = Locked(0)

    struct Request: Sendable {
        let copy: Int?
        let info: Bool
        let sent: Date
        let others: Int
        let pages: Int
        var answered: Date?
        var times: RequestTimes?
    }

    let asked = Date()
    private let copies: [String]
    private let requests = Locked<[Request]>([])

    init(copies: [String]) { self.copies = copies }

    var sent: [Request] { requests.value }

    func sending(_ request: URLRequest) -> Recorder {
        let parts = request.url?.pathComponents ?? []
        let info = parts.last == "PlaybackInfo"
        let id = info ? parts.dropLast().last : parts.last
        let copy = id.flatMap(copies.firstIndex(of:)).map { $0 + 1 }
        var index = 0
        requests.mutate {
            $0.append(Request(copy: copy, info: info, sent: Date(), others: Self.underWay.value, pages: Self.pagesUnderWay.value))
            index = $0.count - 1
        }
        return Recorder(clock: self, index: index)
    }

    func readout(tap: Date) -> String {
        func line(_ request: Request) -> String {
            let name = request.copy.map { "copy \($0) \(request.info ? "info" : "item")" } ?? "other"
            let took = request.answered.map {
                String(format: request.times == nil ? "no answer in %.2f s" : "%.2f s", $0.timeIntervalSince(request.sent))
            } ?? "no answer"
            let times = request.times.map {
                String(format: ", queued %.2f, connect %.2f, wait %.2f, transfer %.2f", $0.queued, $0.connect, $0.wait, $0.transfer)
            } ?? ""
            return "\(name) \(took) [sent " + String(format: "%+.2f s", request.sent.timeIntervalSince(tap))
                + "\(times), \(request.others) under way, \(request.pages) pages]"
        }
        let byCopy = sent.sorted { ($0.copy ?? .max, $0.info ? 1 : 0) < ($1.copy ?? .max, $1.info ? 1 : 0) }
        return "\(copies.count) \(copies.count == 1 ? "copy" : "copies"); " + byCopy.map(line).joined(separator: "; ")
    }

    final class Recorder: NSObject, URLSessionTaskDelegate, Sendable {
        private let clock: PlanClock
        private let index: Int

        init(clock: PlanClock, index: Int) {
            self.clock = clock
            self.index = index
        }

        func answered() {
            clock.requests.mutate { $0[index].answered = $0[index].answered ?? Date() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            guard let times = RequestTimes(metrics) else { return }
            clock.requests.mutate { $0[index].times = $0[index].times ?? times }
        }
    }
}
#endif

import Foundation

/// HTTP/2 sends every request at once over one connection, so the connections per server cap nothing there:
/// what's fetched ahead takes a turn here instead.
final class ServerTurns: @unchecked Sendable {
    enum Rank: Int, Comparable {
        case soon, ahead, later

        static func < (a: Rank, b: Rank) -> Bool { a.rawValue < b.rawValue }

        static var current: Rank { Task.currentPriority < .utility ? .later : .ahead }
    }

    /// Work fetched ahead (a shelf's job, the library's load), and every request made for it, those from tasks of its
    /// own too: soon, they go first; now (a tap takes it, Search waits on it), they go at once, a start or not.
    final class Fetch: @unchecked Sendable {
        enum Need: Int, Comparable {
            case ahead, soon, now

            static func < (a: Need, b: Need) -> Bool { a.rawValue < b.rawValue }
        }

        private let lock = NSLock()
        private var need = Need.ahead
        private var watchers: [@Sendable (Need) -> Void] = []
        private var whenUnderWay: (@Sendable () -> Void)?

        init(whenUnderWay: (@Sendable () -> Void)? = nil) {
            self.whenUnderWay = whenUnderWay
        }

        func raise(to raised: Need) {
            let told: [@Sendable (Need) -> Void] = lock.withLock {
                guard raised > need else { return [] }
                need = raised
                return watchers
            }
            told.forEach { $0(raised) }
        }

        fileprivate func watch(_ told: @escaping @Sendable (Need) -> Void) -> Need {
            lock.withLock {
                watchers.append(told)
                return need
            }
        }

        fileprivate func underWay() {
            let told = lock.withLock {
                defer { whenUnderWay = nil }
                return whenUnderWay
            }
            told?()
        }
    }

    @TaskLocal static var fetch: Fetch?

    static func atOnce<T>(_ work: () async throws -> T) async rethrows -> T {
        let mine = Fetch()
        mine.raise(to: .now)
        return try await $fetch.withValue(mine, operation: work)
    }

    private enum Turn {
        case now
        case taken(Rank)
    }

    private struct Waiter {
        let id: UInt64
        let server: String
        let owner: Int?
        var rank: Rank
        let go: CheckedContinuation<Turn, Error>
    }

    private let atOnce: Int
    private let lock = NSLock()
    private var underWay: [String: [Rank: Int]] = [:]
    private var holds = 0
    private var waiting: [Waiter] = []
    private var numbered: UInt64 = 0

    init(atOnce: Int) {
        self.atOnce = atOnce
    }

    #if DEBUG
    /// UI tests: `-noServerTurns YES` sends what's fetched ahead at once, and holds none of it for a start or a film (the start before).
    private static var off: Bool { UserDefaults.standard.bool(forKey: "noServerTurns") }
    #else
    private static let off = false
    #endif

    static func server(of url: URL?) -> String {
        "\(url?.host() ?? ""):\(url?.port ?? 0)"
    }

    /// `owner`: the account the request is for (its key's hash), so its waiting requests go nowhere once it closes.
    func taking<T>(_ rank: Rank, at server: String, owner: Int?, _ work: (_ now: Bool) async throws -> T) async throws -> T {
        if Self.off {
            Self.fetch?.underWay()
            return try await work(false)
        }
        let turn = try await turn(rank, at: server, owner: owner)
        Self.fetch?.underWay()
        switch turn {
        case .now:
            return try await work(true)
        case let .taken(rank):
            defer { finished(rank, at: server) }
            return try await work(false)
        }
    }

    var isHeld: Bool { lock.withLock { holds > 0 } }

    func hold() {
        guard !Self.off else { return }
        lock.withLock { holds += 1 }
    }

    func release() {
        guard !Self.off else { return }
        lock.withLock { holds = max(0, holds - 1) }
        admit()
    }

    func whileStarting() async {
        hold()
        while (try? await Task.sleep(for: .seconds(3600))) != nil {}
        release()
    }

    func drop(owner: Int) {
        let dropped: [Waiter] = lock.withLock {
            defer { waiting.removeAll { $0.owner == owner } }
            return waiting.filter { $0.owner == owner }
        }
        dropped.forEach { $0.go.resume(throwing: CancellationError()) }
    }

    private func turn(_ rank: Rank, at server: String, owner: Int?) async throws -> Turn {
        let id = lock.withLock {
            numbered += 1
            return numbered
        }
        return try await withTaskPriorityEscalationHandler {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (go: CheckedContinuation<Turn, Error>) in
                    let cancelled = lock.withLock {
                        if Task.isCancelled { return true }
                        waiting.append(Waiter(id: id, server: server, owner: owner, rank: rank, go: go))
                        return false
                    }
                    if cancelled {
                        go.resume(throwing: CancellationError())
                    } else if Task.currentPriority > .utility {
                        goNow(id)
                    } else {
                        let need = Self.fetch?.watch { [self] need in raised(id, to: need) } ?? .ahead
                        raised(id, to: need)
                    }
                }
            } onCancel: {
                waiter(id)?.go.resume(throwing: CancellationError())
            }
        } onPriorityEscalated: { _, now in
            if now > .utility { self.goNow(id) }
        }
    }

    private func raised(_ id: UInt64, to need: Fetch.Need) {
        switch need {
        case .now:
            goNow(id)
        case .soon:
            lock.withLock {
                if let index = waiting.firstIndex(where: { $0.id == id }) { waiting[index].rank = .soon }
            }
            admit()
        case .ahead:
            admit()
        }
    }

    private func waiter(_ id: UInt64) -> Waiter? {
        lock.withLock { waiting.firstIndex { $0.id == id }.map { waiting.remove(at: $0) } }
    }

    private func goNow(_ id: UInt64) {
        waiter(id)?.go.resume(returning: .now)
    }

    private func finished(_ rank: Rank, at server: String) {
        lock.withLock { underWay[server, default: [:]][rank, default: 0] -= 1 }
        admit()
    }

    /// Up to `atOnce` per server, the soonest first, and beside them one piece of later work, so it never starves.
    private func admit() {
        let going: [Waiter] = lock.withLock {
            var going: [Waiter] = []
            func fits(_ waiter: Waiter) -> Bool {
                let busy = underWay[waiter.server, default: [:]]
                if waiter.rank == .later { return busy[.later, default: 0] == 0 }
                return busy.filter { $0.key != .later }.values.reduce(0, +) < atOnce
            }
            while holds == 0, let next = waiting.indices.filter({ fits(waiting[$0]) }).min(by: { waiting[$0].rank < waiting[$1].rank }) {
                let waiter = waiting.remove(at: next)
                underWay[waiter.server, default: [:]][waiter.rank, default: 0] += 1
                going.append(waiter)
            }
            return going
        }
        going.forEach { $0.go.resume(returning: .taken($0.rank)) }
    }
}

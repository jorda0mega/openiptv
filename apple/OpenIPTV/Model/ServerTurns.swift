import Foundation

/// HTTP/2 sends every request at once over one connection, so the connections per server cap nothing there:
/// what's fetched ahead takes a turn here instead.
final class ServerTurns: @unchecked Sendable {
    enum Rank: Int, Comparable {
        case ahead, later

        static func < (a: Rank, b: Rank) -> Bool { a.rawValue < b.rawValue }

        static var current: Rank { Task.currentPriority < .utility ? .later : .ahead }
    }

    private struct Waiter {
        let id: UInt64
        let server: String
        let rank: Rank
        let go: CheckedContinuation<Bool, Error>
    }

    private let atOnce: Int
    private let lock = NSLock()
    private var underWay: [String: [Rank: Int]] = [:]
    private var starts = 0
    private var waiting: [Waiter] = []
    private var numbered: UInt64 = 0

    init(atOnce: Int) {
        self.atOnce = atOnce
    }

    #if DEBUG
    /// UI tests: `-noServerTurns YES` sends what's fetched ahead at once, and holds none of it for a start (the start before).
    private static var off: Bool { UserDefaults.standard.bool(forKey: "noServerTurns") }
    #else
    private static let off = false
    #endif

    static func server(of url: URL?) -> String {
        "\(url?.host() ?? ""):\(url?.port ?? 0)"
    }

    func taking<T>(_ rank: Rank, at server: String, _ work: (_ wanted: Bool) async throws -> T) async throws -> T {
        if Self.off { return try await work(false) }
        if try await turn(rank, at: server) { return try await work(true) }
        defer { finished(rank, at: server) }
        return try await work(false)
    }

    func whileStarting() async {
        guard !Self.off else { return }
        lock.withLock { starts += 1 }
        while (try? await Task.sleep(for: .seconds(3600))) != nil {}
        lock.withLock { starts -= 1 }
        admit()
    }

    private func turn(_ rank: Rank, at server: String) async throws -> Bool {
        let id = lock.withLock {
            numbered += 1
            return numbered
        }
        return try await withTaskPriorityEscalationHandler {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (go: CheckedContinuation<Bool, Error>) in
                    let cancelled = lock.withLock {
                        if Task.isCancelled { return true }
                        waiting.append(Waiter(id: id, server: server, rank: rank, go: go))
                        return false
                    }
                    if cancelled { go.resume(throwing: CancellationError()) } else if Task.currentPriority > .utility { wanted(id) } else { admit() }
                }
            } onCancel: {
                waiter(id)?.go.resume(throwing: CancellationError())
            }
        } onPriorityEscalated: { _, now in
            if now > .utility { self.wanted(id) }
        }
    }

    private func waiter(_ id: UInt64) -> Waiter? {
        lock.withLock { waiting.firstIndex { $0.id == id }.map { waiting.remove(at: $0) } }
    }

    private func wanted(_ id: UInt64) {
        waiter(id)?.go.resume(returning: true)
    }

    private func finished(_ rank: Rank, at server: String) {
        lock.withLock { underWay[server, default: [:]][rank, default: 0] -= 1 }
        admit()
    }

    private func admit() {
        let going: [Waiter] = lock.withLock {
            var going: [Waiter] = []
            func fits(_ waiter: Waiter) -> Bool {
                let busy = underWay[waiter.server, default: [:]]
                return busy.values.reduce(0, +) < atOnce && (waiter.rank == .ahead || busy[.later, default: 0] == 0)
            }
            while starts == 0, let next = waiting.indices.filter({ fits(waiting[$0]) }).min(by: { waiting[$0].rank < waiting[$1].rank }) {
                let waiter = waiting.remove(at: next)
                underWay[waiter.server, default: [:]][waiter.rank, default: 0] += 1
                going.append(waiter)
            }
            return going
        }
        going.forEach { $0.go.resume(returning: false) }
    }
}

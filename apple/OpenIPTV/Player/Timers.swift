import Foundation

enum Timers {
    static func sleep(until date: Date, now: () -> Date = Date.init,
                      sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) async throws {
        var left = date.timeIntervalSince(now())
        while left > 0 {
            try await sleep(left)
            left = date.timeIntervalSince(now())
        }
    }

    static func value<T: Sendable>(of task: Task<T, Error>) async throws -> T {
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

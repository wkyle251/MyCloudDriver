import Foundation

/// A backoff has a maximum delay, not a maximum number of attempts. Callers
/// own cancellation and must recheck user intent and account identity after
/// every suspension before retrying work.
enum AutomaticRecovery {
    static let delays: [TimeInterval] = [5, 15, 30, 60, 120, 300]

    static func delay(attempt: Int, schedule: [TimeInterval] = delays) -> TimeInterval {
        guard !schedule.isEmpty else { return 300 }
        let value = schedule[min(max(0, attempt), schedule.count - 1)]
        return value.isFinite ? max(0, value) : 300
    }

    static func nextAttempt(_ attempt: Int) -> Int { min(max(0, attempt), 1_000_000) + 1 }

    /// For reads/materialization with cancellation owned by the calling task.
    /// Mutations must use their operation's receipt/checkpoint reconciliation.
    /// Status callbacks update observable UI state. Hop to the main actor
    /// before publishing; a synchronous callback on this generic executor can
    /// deadlock Combine against a simultaneous main-thread preview update.
    static func read<T>(backoff: [TimeInterval] = delays,
                        onRetry: @MainActor (Error, TimeInterval) -> Void = { _, _ in },
                        _ operation: () async throws -> T) async throws -> T {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            do { return try await operation() }
            catch {
                try Task.checkCancellation()
                guard TransferFailure.isRetryable(error) else { throw error }
                let seconds = delay(attempt: attempt, schedule: backoff)
                attempt = nextAttempt(attempt)
                await onRetry(error, seconds)
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }
}

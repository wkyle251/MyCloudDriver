import Foundation

@main @MainActor struct PreviewProgressTests {
    nonisolated static func snapshot(_ bytes: Int64, total: Int64 = 1_000_000) -> PreviewResourceCacheSnapshot {
        .init(cachedBytes: bytes, contentLength: total, ranges: [0..<bytes])
    }

    static func main() async throws {
        var delivered: [PreviewResourceCacheSnapshot] = []
        var deliveryTimes: [TimeInterval] = []
        let publisher = PreviewCacheProgressPublisher { value in
            MainActor.assertIsolated()
            delivered.append(value)
            deliveryTimes.append(ProcessInfo.processInfo.systemUptime)
        }

        // Keep the main actor occupied while multiple producers flood progress.
        // A task per event would retain the entire backlog and delay the UI.
        DispatchQueue.concurrentPerform(iterations: 4) { worker in
            for value in 1...250_000 {
                publisher.publish(snapshot(Int64(value + worker)))
            }
        }
        let complete = snapshot(1_000_000)
        publisher.publish(complete)
        precondition(delivered.isEmpty)
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(delivered == [complete], "Deliver only the newest snapshot after a blocked UI")

        for _ in 0..<1_000_000 { publisher.publish(complete) }
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(delivered.count == 1, "Repeated reads of a complete cache must not invalidate SwiftUI")

        // Sustained progress still updates, at a bounded rate, and delivers the
        // final value even if the source goes quiet immediately afterwards.
        for value in 1...50 {
            publisher.publish(snapshot(Int64(value), total: 50))
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(delivered.last == snapshot(50, total: 50))
        for pair in zip(deliveryTimes, deliveryTimes.dropFirst()) {
            precondition(pair.1 - pair.0 >= 0.23, "Burst/completion updates must respect the UI rate limit")
        }
        let count = delivered.count
        publisher.publish(snapshot(25, total: 50))
        publisher.invalidate()
        publisher.publish(snapshot(30, total: 50))
        try await Task.sleep(nanoseconds: 300_000_000)
        precondition(delivered.count == count, "Closing a preview must discard pending and future events")

        weak var released: PreviewCacheProgressPublisher?
        do {
            let temporary = PreviewCacheProgressPublisher { _ in preconditionFailure("Stale preview callback") }
            released = temporary
            temporary.publish(complete)
        }
        precondition(released == nil, "A queued update must not retain a closed preview")
        print("PASS preview progress: two million events, latest value, duplicate suppression, rate limit, cancellation and release")
    }
}

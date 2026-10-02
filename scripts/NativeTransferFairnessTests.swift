import Foundation

private final class NativeTransferTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return storage }
    func increment() { lock.lock(); storage += 1; lock.unlock() }
}

@main struct NativeTransferFairnessTests {
    @MainActor static func wait(_ condition: () -> Bool, seconds: Double = 3) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition(), Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(condition(), "Expected transfer state was not reached")
    }

    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-transfer-fairness-\(UUID())")
        try CloudDriveFiles.privateDirectory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let admission = NativeTransferAdmission(limit: 1)
        let first = NativeDriveModel(kind: .icloud, temporaryRoot: root.appendingPathComponent("first"), transferAdmission: admission)
        let second = NativeDriveModel(kind: .icloud, temporaryRoot: root.appendingPathComponent("second"), transferAdmission: admission)
        let provider = ICloudDriveProvider(rootURL: root)
        first.connect(provider); second.connect(provider)
        defer { first.close(); second.close() }
        var ticks = 0
        let long = first.run("Long download", transferDirection: 0) { _, _ in
            while true {
                try await NativeTransferControl.current?.wait()
                ticks += 1
                try await Task.sleep(nanoseconds: 15_000_000)
            }
        }!
        try await wait { ticks > 0 }
        var otherStarted = false, finishOther = false
        let other = second.run("Healthy download", transferDirection: 0) { _, _ in
            otherStarted = true
            while !finishOther {
                try await NativeTransferControl.current?.wait()
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            return nil
        }!
        first.pauseTransfer(long)
        try await wait { otherStarted }
        let pausedTicks = ticks
        first.resumeTransfer(long)
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(ticks == pausedTicks, "Resume must acquire a slot before restarting I/O")
        finishOther = true
        try await wait { second.activity.records.first(where: { $0.id == other })?.state == "Completed" && ticks > pausedTicks }
        let edit = first.run("New folder", mutating: true) { provider, _ in
            try await provider.createContainer("While downloading", in: provider.root)
        }!
        try await wait { first.activity.records.first(where: { $0.id == edit })?.state == "Completed" }
        precondition(!first.isMutating, "An active transfer must not lock unrelated file actions")
        // Rapid changes leave at most the one permitted operation active.
        for _ in 0..<30 { first.pauseTransfer(long); first.resumeTransfer(long) }
        try await Task.sleep(nanoseconds: 150_000_000)
        let activeAfterRapidChanges = await admission.activeCount
        precondition(activeAfterRapidChanges <= 1)
        first.cancel(long)
        try await wait { first.activity.records.first(where: { $0.id == long })?.state == "Cancelled" }

        var attempts = 0, healthyFinished = false
        let failing = first.run("Retrying upload", transferDirection: 1) { _, _ in
            attempts += 1
            throw URLError(.networkConnectionLost)
        }!
        try await wait { attempts == 1 && first.activity.records.first(where: { $0.id == failing })?.state == "Retrying" }
        _ = second.run("Healthy upload", transferDirection: 1) { _, _ in healthyFinished = true; return nil }
        try await wait({ healthyFinished }, seconds: 0.6)
        first.cancel(failing)
        try await wait { first.activity.records.first(where: { $0.id == failing })?.state == "Cancelled" }
        precondition(attempts == 1, "Cancellation must prevent the next retry")

        var permanentAttempts = 0
        let permanent = first.run("Destination exists", transferDirection: 0) { _, _ in
            permanentAttempts += 1
            throw CocoaError(.fileWriteFileExists)
        }!
        try await wait { first.activity.records.first(where: { $0.id == permanent })?.state == "Failed" }
        try await Task.sleep(nanoseconds: 1_100_000_000)
        precondition(permanentAttempts == 1, "Permanent filesystem errors must not loop forever")
        precondition(TransferFailure.isRetryable(CocoaError(.fileWriteOutOfSpace)))
        precondition(TransferFailure.isRetryable(CocoaError(.fileReadNoPermission)))
        var interruptedAttempts = 0
        let interrupted = first.run("Provider interruption", transferDirection: 0) { _, _ in
            interruptedAttempts += 1
            if interruptedAttempts == 1 { throw CancellationError() }
            return nil
        }!
        try await wait { first.activity.records.first(where: { $0.id == interrupted })?.state == "Completed" }
        precondition(interruptedAttempts == 2, "A provider interruption must retry when the user did not cancel")

        var pausedQueuedStarted = false, followingFinished = false
        let queued = first.run("Paused queue", transferDirection: 0) { _, _ in pausedQueuedStarted = true; return nil }!
        first.pauseTransfer(queued)
        _ = second.run("Following queue", transferDirection: 0) { _, _ in followingFinished = true; return nil }
        try await wait { followingFinished }
        precondition(!pausedQueuedStarted)
        first.cancel(queued)
        try await wait { first.activity.records.first(where: { $0.id == queued })?.state == "Cancelled" }
        try await Task.sleep(nanoseconds: 80_000_000)
        let activeAtEnd = await admission.activeCount
        precondition(activeAtEnd == 0, "All leases must be released after cancellation/completion")
        try await testBlockingFileExecutor()
        print("PASS native transfer fairness: permanent errors stop; pause/backoff release slots, resume reacquires, healthy jobs and file actions proceed, rapid controls/cancel do not leak leases")
    }

    @MainActor private static func testBlockingFileExecutor() async throws {
        // More paused synchronous copies than CPU cores must not consume the
        // cooperative executor needed by the actors that resume/cancel them.
        let count = min(32, ProcessInfo.processInfo.activeProcessorCount + 2)
        let entered = NativeTransferTestCounter()
        let gates = (0..<count).map { _ in NativeTransferControl() }
        gates.forEach { $0.pause() }
        let jobs = gates.map { gate in
            Task {
                try await NativeTransferControl.$current.withValue(gate) {
                    try await CloudDriveFiles.detached {
                        entered.increment()
                        try NativeTransferControl.current?.check()
                    }
                }
            }
        }
        try await wait({ entered.value == count }, seconds: 5)
        let heartbeat = await Task.detached { 42 }.value
        precondition(heartbeat == 42, "Paused copies must leave Swift executor threads available")
        jobs.forEach { $0.cancel() }
        for job in jobs {
            do { try await job.value; preconditionFailure("Cancellation must reach blocked file work") }
            catch is CancellationError {}
        }

        // Directory scans have no transfer gate; cancellation must still be
        // forwarded to synchronous work after moving it onto the GCD queue.
        let scanEntered = NativeTransferTestCounter()
        let scan = Task {
            try await CloudDriveFiles.detached {
                scanEntered.increment()
                while true {
                    try CloudDriveFiles.checkCancellation()
                    Thread.sleep(forTimeInterval: 0.01)
                }
            }
        }
        try await wait { scanEntered.value == 1 }
        scan.cancel()
        do { try await scan.value; preconditionFailure("Cancellation must reach non-transfer file work") }
        catch is CancellationError {}
        print("PASS native filesystem executor: \(count) paused copies leave actors responsive; task cancellation reaches both transfer and scan work")
    }
}

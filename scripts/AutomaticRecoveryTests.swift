import Foundation

@main struct AutomaticRecoveryTests {
    @MainActor static func main() async throws {
        precondition(AutomaticRecovery.delay(attempt: Int.max) == 300)
        precondition(AutomaticRecovery.delay(attempt: -1) == 5)
        precondition(AutomaticRecovery.delay(attempt: 10, schedule: []) == 300)
        precondition(AutomaticRecovery.nextAttempt(Int.max) == 1_000_001)
        var attempts = 0
        let result: Int = try await AutomaticRecovery.read(backoff: [0, 0, 0]) {
            attempts += 1
            if attempts < 10 { throw URLError(.networkConnectionLost) }
            return 42
        }
        precondition(result == 42 && attempts == 10, "An outage must outlast the backoff schedule without losing the request")

        var cancelledAttempts = 0
        let cancelled = Task { @MainActor in
            try await AutomaticRecovery.read(backoff: [0.1]) { () async throws -> Int in
                cancelledAttempts += 1
                throw CancellationError() // The provider, not the owner, interrupted.
            }
        }
        while cancelledAttempts == 0 { await Task.yield() }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Cancelled read completed") }
        catch is CancellationError { }
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(cancelledAttempts == 1, "Explicit cancellation must prevent the next attempt")
        let wrappedDisk = NSError(domain: "Fixture", code: 1, userInfo: [NSUnderlyingErrorKey: CocoaError(.fileWriteOutOfSpace)])
        precondition(TransferFailure.isRetryable(wrappedDisk))
        precondition(TransferFailure.isRetryable(CloudDriveError.waiting("Disk disconnected")))
        precondition(TransferFailure.isRetryable(PikPakManagementError.api(status: 503, code: nil, message: "Unavailable")))
        precondition(TransferFailure.isRetryable(NSError(domain: "PHPhotosErrorDomain", code: 3301)))
        precondition(TransferFailure.isRetryable(NSError(domain: "PHPhotosErrorDomain", code: 3169)))
        precondition(!TransferFailure.isRetryable(NSError(domain: "PHPhotosErrorDomain", code: 3072)))
        precondition(!TransferFailure.isRetryable(CocoaError(.fileReadCorruptFile)))
        precondition(!TransferFailure.isRetryable(PikPakManagementError.api(status: 403, code: nil, message: "Permission denied")))

        let batch = SavedUploadBatch(id: UUID(), sources: ["/synthetic/input"], destination: .root,
                                     workers: 1, createdAt: Date(), automaticallyResume: false)
        let paused = SavedTransfers(version: 1, accountID: "fixture", downloads: [], uploads: [batch],
                                    downloadsPaused: true, pausedDownloadIDs: ["file"], pausedPendingDownloadIDs: [UUID()], pausedUploadIDs: ["upload"])
        let restored = try JSONDecoder().decode(SavedTransfers.self, from: JSONEncoder().encode(paused))
        precondition(restored.downloadsPaused == true && restored.uploads[0].automaticallyResume == false)
        precondition(restored.pausedDownloadIDs == paused.pausedDownloadIDs && restored.pausedPendingDownloadIDs == paused.pausedPendingDownloadIDs)
        let legacy = SavedTransfers(version: 1, accountID: "fixture", downloads: [], uploads: [])
        let restoredLegacy = try JSONDecoder().decode(SavedTransfers.self, from: JSONEncoder().encode(legacy))
        precondition(restoredLegacy.downloadsPaused == nil)
        print("PASS automatic recovery: prolonged outage, capped backoff, cancellation, disk recovery and durable pause intent")
        try await DownloaderModel.testAutomaticTransferControls()
    }
}

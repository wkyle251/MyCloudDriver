import Foundation

@main
struct DownloadRecoveryTests {
    @MainActor
    static func main() async throws {
        setbuf(stdout, nil)
        try DownloaderModel.testDownloadSleepPreventionLifecycle()
        try DownloaderModel.testDownloadDestinationRecovery()
        try DownloaderModel.testDownloadDestinationReplacement()
        try DownloaderModel.testDownloadVerificationProgress()
        try await DownloaderModel.testDownloadCancellationClearsQueue()
        try DownloaderModel.testDownloadCancellationAdmissionAndProgress()
        try await DownloaderModel.testDownloadCancellationOverlap()
        try await DownloaderModel.testDownloadCleanupResponsiveness()
        try await DownloaderModel.testDownloadResumePreemptsCleanup()
        try DownloaderModel.testDownloadDestinationRecoveryBackoff()
        try DownloaderModel.testDownloadPausedPlanRecovery()
        try DownloaderModel.testRestoredDownloadRetryLineage()
        try DownloaderModel.testDownloadCompletedOutputPath()
        try DownloaderModel.testDownloadProgressBatchResponsiveness()
        try DownloaderModel.testDownloadRAMProgressAndSettings()
        try await DownloaderModel.testDownloadQuitWaitsForDrainAndPreservesResumeIntent()
        try await DownloaderModel.testDownloadPauseKeepsHelperAndQuitRestoresPausedQueue()
        try DownloaderModel.testDownloadSpeedMonitorPausesWithDownloads()
        try DownloaderModel.testDownloadSpeedWaitsForPayload()
        try DownloaderModel.testDownloadRetryWaitingPresentation()
        try DownloaderModel.testDownloadDiscoveryProgressTotals()
        try await DownloaderModel.testAutomaticFailedDownloadRecovery()
        try DownloaderModel.testAutomaticFailedChildrenBeforeFolderFinishes()
        try DownloaderModel.testLargeDownloadRestoreProgress()
        try DownloaderModel.testLargeDownloadPausePresentation()
        try DownloaderModel.testLargeDownloadRetryPresentation()
    }
}

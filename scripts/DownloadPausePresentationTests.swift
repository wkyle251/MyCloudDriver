import Foundation

@main
struct DownloadPausePresentationTests {
    @MainActor
    static func main() async throws {
        setbuf(stdout, nil)
        try DownloaderModel.testLargeDownloadPausePresentation()
        try DownloaderModel.testLargeDownloadRetryPresentation()
        try DownloaderModel.testDownloadPausedPlanRecovery()
        try DownloaderModel.testRestoredDownloadRetryLineage()
        try DownloaderModel.testLargeDownloadRestoreProgress()
        try DownloaderModel.testDownloadSpeedWaitsForPayload()
        try DownloaderModel.testDownloadSpeedMonitorPausesWithDownloads()
        try DownloaderModel.testDownloadRAMProgressAndSettings()
        try DownloaderModel.testDownloadSleepPreventionLifecycle()
        DownloadSpeedHistory.testSessionHistory()
        try DownloaderModel.testDownloadRetryWaitingPresentation()
        try await DownloaderModel.testAutomaticFailedDownloadRecovery()
        try DownloaderModel.testAutomaticFailedChildrenBeforeFolderFinishes()
    }
}

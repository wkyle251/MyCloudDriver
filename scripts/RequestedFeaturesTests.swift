import AppKit
import Foundation

@main struct RequestedFeaturesTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let suite = "com.wky.RequestedFeaturesTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        DownloadSpeedHistory.testSessionHistory()
        try await DownloaderModel.testConcurrentFolderMeasurements(defaults: defaults)
        try CrossDriveDuplicatePolicy.testCrossDriveRecommendations()
        try DownloaderModel.testFinderWorkspace(defaults: defaults)
        try DownloaderModel.testSharedFolderNavigation(defaults: defaults)
        try DownloaderModel.testLiveDownloadQueue()
        try DownloaderModel.testLiveDownloadCheckpointPolicy()
        try DownloaderModel.testDownloadRetries()
        try DownloaderModel.testPermanentDownloadFailures()
        try DownloaderModel.testQueuedDownloadSizeEstimate()
        try DownloaderModel.testDownloadPausedPlanRecovery()
        try DownloaderModel.testDownloadRetryRowsFollowCurrentAttempt()
        try DownloaderModel.testDownloadFinishedReport()
        print("All requested feature native tests passed; no credentials or network used.")
    }
}

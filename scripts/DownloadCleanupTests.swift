import Foundation

@main struct DownloadCleanupTests {
    @MainActor static func main() async throws {
        try DownloaderModel.testDownloadCleanupOptionAndOutcomes()
        try DownloaderModel.testLiveDownloadQueue()
        try DownloaderModel.testDownloadCompletedOutputPath()
        try DownloaderModel.testDownloadRetries()
        try DownloaderModel.testRestoredDownloadRetryLineage()
        try await DownloaderModel.testDownloadCancellationClearsQueue()
        try DownloaderModel.testDownloadDestinationRecovery()
        print("All download cleanup native tests passed; generated files and no account access.")
    }
}

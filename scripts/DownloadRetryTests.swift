import Foundation

@main struct DownloadRetryTests {
    @MainActor static func main() throws {
        try DownloaderModel.testLiveDownloadQueue()
        try DownloaderModel.testDownloadRetries()
    }
}

import Foundation

/// Isolated state and generated files only. No account or network is opened.
@main struct DownloadCheckpointTests {
    @MainActor static func main() throws {
        try DownloaderModel.testLiveDownloadCheckpointPolicy()
        print("All continuous download checkpoint tests passed.")
    }
}

import Foundation

@main
struct TransferDynamicModeTests {
    @MainActor
    static func main() throws {
        try DownloaderModel.testTransferDownloadDynamicMode()
        try DownloaderModel.testGuestMode()
        try DownloaderModel.testLiveDownloadQueue()
        try DownloaderModel.testDownloadRetries()
    }
}

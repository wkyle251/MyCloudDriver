import Foundation

@main struct GuestModeTests {
    @MainActor static func main() throws {
        try DownloaderModel.testGuestMode()
        try DownloaderModel.testLiveDownloadQueue()
        try DownloaderModel.testDownloadRetries()
    }
}

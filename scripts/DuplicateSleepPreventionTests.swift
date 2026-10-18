import Foundation

@main struct DuplicateSleepPreventionTests {
    @MainActor static func main() throws {
        try DownloaderModel.testDuplicateSleepPreventionLifecycle()
    }
}

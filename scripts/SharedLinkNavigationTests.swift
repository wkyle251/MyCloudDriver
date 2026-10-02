import AppKit
import Foundation

@main struct SharedLinkNavigationTests {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let suite = "com.wky.SharedLinkNavigationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try DownloaderModel.testSharedFolderNavigation(defaults: defaults)
        DownloaderModel.testSharedSelection(defaults: defaults)
        try DownloaderModel.testFinderWorkspace(defaults: defaults)
        try DownloaderModel.testWorkspacePresentation()
        try await DownloaderModel.testFolderThumbnailSelection(defaults: defaults)
        print("All Links navigation tests passed; no credentials or network used.")
    }
}

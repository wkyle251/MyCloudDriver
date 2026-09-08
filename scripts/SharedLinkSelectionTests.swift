import AppKit
import Foundation

@main struct SharedLinkSelectionTests {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        let suite = "com.wky.PikPakSharedSelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        DownloaderModel.testSharedSelection(defaults: defaults)
        try DownloaderModel.testFinderWorkspace(defaults: defaults)
    }
}

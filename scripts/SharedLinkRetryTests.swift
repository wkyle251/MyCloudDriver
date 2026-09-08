import AppKit
import Foundation

@main struct SharedLinkRetryTests {
    @MainActor static func main() throws {
        setbuf(stdout, nil)
        let suite = "com.wky.PikPakSharedLinkRetryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        DownloaderModel.testSharedLinkRetries(defaults: defaults)
        DownloaderModel.testSharedSelection(defaults: defaults)
    }
}

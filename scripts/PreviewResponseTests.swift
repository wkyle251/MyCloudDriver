import Foundation

@main
struct PreviewResponseTests {
    @MainActor
    static func main() throws {
        let suite = "com.wky.PreviewResponseTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try DownloaderModel.testPreviewResponseURLs(defaults: defaults)
    }
}

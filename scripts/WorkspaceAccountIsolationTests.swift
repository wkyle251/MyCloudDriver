import Foundation

@main struct WorkspaceAccountIsolationTests {
    @MainActor static func main() async throws {
        try await DownloaderModel.testWorkspaceAccountIsolation()
        try await DownloaderModel.testAccountManagement()
    }
}

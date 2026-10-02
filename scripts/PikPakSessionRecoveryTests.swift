import Foundation

@main struct PikPakSessionRecoveryTests {
    @MainActor static func main() async throws {
        try await DownloaderModel.testSessionRecovery()
        try await DownloaderModel.testAccountManagement()
        try await DownloaderModel.testWorkspaceAccountIsolation()
    }
}

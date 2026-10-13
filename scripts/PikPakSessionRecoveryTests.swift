import Foundation

@main struct PikPakSessionRecoveryTests {
    @MainActor static func main() async throws {
        try DownloaderModel.testWindowAccountInheritance()
        try DownloaderModel.testAccountLoginPreparationContext()
        try await DownloaderModel.testSessionRecovery()
        try await DownloaderModel.testAccountManagement()
        try await DownloaderModel.testWorkspaceAccountIsolation()
    }
}

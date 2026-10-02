import Foundation

@main struct PersonalAccessTokenTests {
    static func require(_ condition: Bool, _ message: String = "PAT invariant failed") { precondition(condition, message) }
    @MainActor static func main() async throws {
        let token = "eyJmaXh0dXJlIjoxfQ.eyJzdWIiOiJmaXh0dXJlIn0.fixture-signature"
        require(try CredentialParser.personalAccessToken(from: "  Bearer \(token)\n") == token)
        for invalid in ["", "short", "\(token)\nextra", "{\"refresh_token\":\"\(token)\"}"] {
            do { _ = try CredentialParser.personalAccessToken(from: invalid); preconditionFailure("invalid PAT input accepted") }
            catch CredentialParserError.invalidPersonalAccessToken { }
        }
        do { _ = try CredentialParser.refreshToken(from: token); preconditionFailure("PAT routed as refresh token") }
        catch CredentialParserError.accessToken { }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pat-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PikPakAccountStore(directory: root)
        let files = try store.stage(token: token, deviceID: String(repeating: "f", count: 32), credentialKind: .personalAccessToken)
        precondition(files.tokenURL.lastPathComponent == "personal-access-token")
        for (url, mode) in [(root, 0o700), (files.directory, 0o700), (files.tokenURL, 0o600)] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == mode)
        }
        precondition(!FileManager.default.fileExists(atPath: files.directory.appendingPathComponent("refresh-token").path))
        try FileManager.default.removeItem(at: files.tokenURL)
        let sentinel = root.appendingPathComponent("sentinel")
        try Data(token.utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: files.tokenURL, withDestinationURL: sentinel)
        do { _ = try files.load(); preconditionFailure("symlink accepted") }
        catch PikPakAccountError.invalidStorage { }
        print("PASS PAT parser and storage: JWTs supported, invalid input rejected, private files and symlink protection")
        try await DownloaderModel.testPersonalAccessTokenConnection()
        try await DownloaderModel.testAccountManagement()
        try DownloaderModel.testGuestMode()
    }
}

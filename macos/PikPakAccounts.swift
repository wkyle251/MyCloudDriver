import Foundation

struct PikPakAccountProfile: Codable, Equatable {
    let sub: String
    let name: String?

    var displayName: String? {
        let value = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? nil : value
    }
}

struct SavedPikPakAccount: Codable, Equatable, Identifiable {
    let id: UUID
    var profile: PikPakAccountProfile?
    var needsSignIn: Bool
    var lastChecked: Date?

    var displayName: String { profile?.displayName ?? "PikPak account" }
    var accountIdentifier: String? { profile?.sub }
}

struct PikPakAccountsDocument: Codable, Equatable {
    var version = 1
    var activeID: UUID?
    var accounts: [SavedPikPakAccount] = []
}

enum PikPakAccountError: LocalizedError, Equatable {
    case invalidStorage, missingSession, invalidProfile, accountMismatch, needsSignIn, unavailable, cancelled

    var errorDescription: String? {
        switch self {
        case .invalidStorage: return "Saved accounts could not be read or updated. Your existing account files have been kept."
        case .missingSession, .needsSignIn: return "This account needs you to sign in again."
        case .invalidProfile, .unavailable: return "Could not check your account with PikPak. Check your connection and try again."
        case .accountMismatch: return "That is a different account. Use Add Account to connect it, or sign in with the selected account."
        case .cancelled: return "Account check cancelled."
        }
    }
}

/// Workers receive these immutable, account-specific paths. A token rotation
/// can never overwrite another account's session, even across an app restart.
struct PikPakAccountSessionFiles {
    let id: UUID
    let directory: URL
    var tokenURL: URL { directory.appendingPathComponent("refresh-token") }
    var lockURL: URL { directory.appendingPathComponent("refresh-token.lock") }

    func load() throws -> (token: String, deviceID: String) {
        do { return try loadSavedSession() }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            throw PikPakAccountError.missingSession
        }
    }

    private func loadSavedSession() throws -> (token: String, deviceID: String) {
        try PikPakAccountStore.validateDirectory(directory)
        let marker = try PikPakAccountStore.readPrivateFile(directory.appendingPathComponent("desktop-oauth-profile-v3"))
        guard String(data: marker, encoding: .utf8) == "3" else { throw PikPakAccountError.missingSession }
        guard let rawToken = String(data: try PikPakAccountStore.readPrivateFile(tokenURL), encoding: .utf8),
              let deviceID = String(data: try PikPakAccountStore.readPrivateFile(directory.appendingPathComponent("device-id")), encoding: .utf8)
        else { throw PikPakAccountError.missingSession }
        let token = try CredentialParser.refreshToken(from: rawToken)
        guard Self.validDeviceID(deviceID) else { throw PikPakAccountError.missingSession }
        return (token, deviceID)
    }

    static func validDeviceID(_ value: String) -> Bool {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-:"))
        return (16...256).contains(value.count) && value.unicodeScalars.allSatisfy(allowed.contains)
    }
}

/// The index contains display metadata only. A new login is staged in its own
/// private directory, verified, and then committed with one atomic index write.
/// Failed or cancelled logins leave the previously active account untouched.
final class PikPakAccountStore {
    let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("accounts.json") }

    init(directory: URL) throws {
        self.directory = directory
        try Self.prepareDirectory(directory)
        let document = try load()
        let retained = Set(document.accounts.filter { !$0.needsSignIn }.map(\.id))
        // Recover interrupted staging/logout after a crash, before workers start.
        for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if let id = UUID(uuidString: child.lastPathComponent), !retained.contains(id) {
                try? discard(files(for: id))
            }
        }
    }

    func load() throws -> PikPakAccountsDocument {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return PikPakAccountsDocument() }
        let document = try JSONDecoder().decode(PikPakAccountsDocument.self, from: Self.readPrivateFile(indexURL))
        let ids = Set(document.accounts.map(\.id))
        guard document.version == 1, ids.count == document.accounts.count,
              document.activeID.map(ids.contains) ?? true else { throw PikPakAccountError.invalidStorage }
        return document
    }

    func files(for id: UUID) -> PikPakAccountSessionFiles {
        PikPakAccountSessionFiles(id: id, directory: directory.appendingPathComponent(id.uuidString, isDirectory: true))
    }

    func stage(token: String, deviceID: String) throws -> PikPakAccountSessionFiles {
        let token = try CredentialParser.refreshToken(from: token)
        guard PikPakAccountSessionFiles.validDeviceID(deviceID) else { throw PikPakAccountError.missingSession }
        let files = files(for: UUID())
        do {
            try Self.prepareDirectory(files.directory)
            try Self.writePrivateFile(Data(token.utf8), to: files.tokenURL)
            try Self.writePrivateFile(Data(deviceID.utf8), to: files.directory.appendingPathComponent("device-id"))
            try Self.writePrivateFile(Data("3".utf8), to: files.directory.appendingPathComponent("desktop-oauth-profile-v3"))
            return files
        } catch {
            try? discard(files)
            throw error
        }
    }

    @discardableResult
    func commit(_ files: PikPakAccountSessionFiles, profile: PikPakAccountProfile?, checkedAt: Date? = nil) throws -> PikPakAccountsDocument {
        guard files.directory == self.files(for: files.id).directory else { throw PikPakAccountError.invalidStorage }
        _ = try files.load()
        if let profile, profile.sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw PikPakAccountError.invalidProfile }
        var document = try load()
        let replaced = document.accounts.filter { $0.id != files.id && profile != nil && $0.profile?.sub == profile?.sub }
        document.accounts.removeAll { old in old.id == files.id || replaced.contains(where: { $0.id == old.id }) }
        document.accounts.append(.init(id: files.id, profile: profile, needsSignIn: false, lastChecked: checkedAt))
        document.activeID = files.id
        try save(document)
        // Only unreferenced directories are removed, after the new session is committed.
        for old in replaced { try? discard(self.files(for: old.id)) }
        return document
    }

    @discardableResult
    func updateProfile(_ profile: PikPakAccountProfile, for id: UUID, checkedAt: Date = Date()) throws -> PikPakAccountsDocument {
        guard !profile.sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PikPakAccountError.invalidProfile }
        var document = try load()
        guard let index = document.accounts.firstIndex(where: { $0.id == id }) else { throw PikPakAccountError.missingSession }
        if let expected = document.accounts[index].profile?.sub, expected != profile.sub { throw PikPakAccountError.accountMismatch }
        document.accounts[index].profile = profile
        document.accounts[index].lastChecked = checkedAt
        document.accounts[index].needsSignIn = false
        try save(document)
        return document
    }

    @discardableResult
    func activate(_ id: UUID) throws -> PikPakAccountsDocument {
        var document = try load()
        guard let account = document.accounts.first(where: { $0.id == id }), !account.needsSignIn else { throw PikPakAccountError.missingSession }
        _ = try files(for: id).load()
        document.activeID = id
        try save(document)
        return document
    }

    @discardableResult
    func logOut(_ id: UUID, deactivate: Bool = true) throws -> PikPakAccountsDocument {
        var document = try load()
        guard let index = document.accounts.firstIndex(where: { $0.id == id }) else { throw PikPakAccountError.missingSession }
        document.accounts[index].needsSignIn = true
        document.accounts[index].lastChecked = nil
        if deactivate && document.activeID == id { document.activeID = nil }
        // Revoke local eligibility first. A partially failed removal is never loaded.
        try save(document)
        try discard(files(for: id))
        return document
    }

    func discard(_ files: PikPakAccountSessionFiles) throws {
        guard files.directory == self.files(for: files.id).directory else { throw PikPakAccountError.invalidStorage }
        guard FileManager.default.fileExists(atPath: files.directory.path) else { return }
        try Self.validateDirectory(files.directory)
        try FileManager.default.removeItem(at: files.directory)
    }

    /// Runs once, before any helper starts. Never migrate an untrusted Web token.
    func migrateLegacySession(_ session: StoredSession) throws -> PikPakAccountsDocument {
        if FileManager.default.fileExists(atPath: indexURL.path) { return try load() }
        guard let token = session.token, !session.requiresDedicatedSignIn else {
            let empty = PikPakAccountsDocument()
            try save(empty)
            return empty
        }
        let staged = try stage(token: token, deviceID: session.deviceID)
        do { return try commit(staged, profile: nil) }
        catch { try? discard(staged); throw error }
    }

    private func save(_ document: PikPakAccountsDocument) throws {
        try Self.writePrivateFile(JSONEncoder().encode(document), to: indexURL)
    }

    static func validateDirectory(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw PikPakAccountError.invalidStorage }
    }

    private static func prepareDirectory(_ url: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) { try validateDirectory(url) }
        else { try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func readPrivateFile(_ url: URL) throws -> Data {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 1_048_576 else { throw PikPakAccountError.invalidStorage }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return try Data(contentsOf: url)
    }

    static func writePrivateFile(_ data: Data, to url: URL) throws {
        try validateDirectory(url.deletingLastPathComponent())
        if FileManager.default.fileExists(atPath: url.path) { _ = try readPrivateFile(url) }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var target = url
        try target.setResourceValues(values)
    }
}

enum PikPakLoginStatus: Equatable {
    case signedOut, unverified, checking, signedIn, needsSignIn, unavailable

    var title: String {
        switch self {
        case .signedOut: return "Not signed in"
        case .unverified: return "Ready to check"
        case .checking: return "Checking login status…"
        case .signedIn: return "Signed in"
        case .needsSignIn: return "Sign-in required"
        case .unavailable: return "Could not check status"
        }
    }
}

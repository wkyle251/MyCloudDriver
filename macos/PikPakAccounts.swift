import Foundation

enum PikPakCredentialKind: String, Codable, CaseIterable, Identifiable {
    case desktopOAuth = "desktop-oauth"
    case personalAccessToken = "personal-access-token"

    var title: String { self == .personalAccessToken ? "Personal Access Token" : "PikPak sign-in" }
    var id: String { rawValue }
    var loginTitle: String { self == .personalAccessToken ? "Token login" : "Normal login" }
    var symbol: String { self == .personalAccessToken ? "key.fill" : "person.crop.circle" }
    var quotaTitle: String { self == .personalAccessToken ? "Connected Apps" : "Full account" }
    var quotaExplanation: String {
        self == .personalAccessToken ? "Shared by all Connected Apps · 25% of the account allowance" : "Account-wide usage and allowance"
    }
    func parse(_ token: String) throws -> String {
        try self == .personalAccessToken ? CredentialParser.personalAccessToken(from: token) : CredentialParser.refreshToken(from: token)
    }
}

struct PikPakAccountSession {
    let token: String
    let deviceID: String
    var credentialKind: PikPakCredentialKind = .desktopOAuth
}

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
    var credentialKind: PikPakCredentialKind?

    var displayName: String { profile?.displayName ?? "PikPak account" }
    var accountIdentifier: String? { profile?.sub }
    var connectionKind: PikPakCredentialKind { credentialKind ?? .desktopOAuth }
    var groupID: String { profile?.sub ?? id.uuidString }
}

/// One visible user can have both connection methods. Legacy indexes still
/// decode; credentials remain in independent private session directories.
struct PikPakAccountGroup: Identifiable {
    let id: String
    let connections: [SavedPikPakAccount]
    var displayName: String { connections.first?.displayName ?? "PikPak account" }
    func connection(_ kind: PikPakCredentialKind) -> SavedPikPakAccount? {
        connections.first { $0.connectionKind == kind }
    }
    static func grouped(_ accounts: [SavedPikPakAccount]) -> [Self] {
        var seen = Set<String>()
        return accounts.compactMap { account in
            guard seen.insert(account.groupID).inserted else { return nil }
            return Self(id: account.groupID, connections: accounts.filter { $0.groupID == account.groupID })
        }
    }
}

struct PikPakAccountsDocument: Codable, Equatable {
    var version = 1
    var activeID: UUID?
    var accounts: [SavedPikPakAccount] = []
    // Optional so existing account indexes decode without a migration pass.
    var workspaceSelections: [String: PikPakWorkspaceAccountSelection]?

    func activeID(for workspaceSessionID: String) -> UUID? {
        if workspaceSessionID == "primary" { return activeID }
        if let selection = workspaceSelections?[workspaceSessionID] { return selection.activeID }
        // A new workspace initially offers the primary account.
        return activeID
    }

    mutating func select(_ id: UUID?, for workspaceSessionID: String) {
        if workspaceSessionID == "primary" { activeID = id }
        else {
            if workspaceSelections == nil { workspaceSelections = [:] }
            workspaceSelections?[workspaceSessionID] = .init(activeID: id)
        }
    }
}

struct PikPakWorkspaceAccountSelection: Codable, Equatable { var activeID: UUID? }

enum PikPakWorkspaceStorage {
    static func sessionID(for slot: Int) -> String {
        precondition(slot > 0)
        switch slot {
        case 1: return "primary"
        case 2: return "secondary"
        default: return "workspace-\(slot)"
        }
    }

    static func isValidSessionID(_ id: String) -> Bool {
        if id == "primary" || id == "secondary" { return true }
        guard id.hasPrefix("workspace-"), let slot = Int(id.dropFirst("workspace-".count)), slot >= 3 else { return false }
        return id == sessionID(for: slot)
    }

    static func directory(_ base: URL, workspaceSessionID: String) -> URL {
        precondition(isValidSessionID(workspaceSessionID), "Invalid workspace storage identifier")
        guard workspaceSessionID != "primary" else { return base }
        return base.appendingPathComponent("Sessions", isDirectory: true)
            .appendingPathComponent(workspaceSessionID, isDirectory: true)
    }
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
    var tokenURL: URL { credentialURL(for: (try? credentialKind()) ?? .desktopOAuth) }
    var lockURL: URL { directory.appendingPathComponent("refresh-token.lock") }

    func credentialURL(for kind: PikPakCredentialKind) -> URL {
        directory.appendingPathComponent(kind == .personalAccessToken ? "personal-access-token" : "refresh-token")
    }

    func credentialKind() throws -> PikPakCredentialKind {
        let marker = directory.appendingPathComponent("credential-kind")
        guard FileManager.default.fileExists(atPath: marker.path) else { return .desktopOAuth }
        guard let value = String(data: try PikPakAccountStore.readPrivateFile(marker), encoding: .utf8),
              let kind = PikPakCredentialKind(rawValue: value) else { throw PikPakAccountError.invalidStorage }
        return kind
    }

    func load() throws -> PikPakAccountSession {
        do { return try loadSavedSession() }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
            throw PikPakAccountError.missingSession
        }
    }

    private func loadSavedSession() throws -> PikPakAccountSession {
        try PikPakAccountStore.validateDirectory(directory)
        let kind = try credentialKind()
        if kind == .desktopOAuth {
            let marker = try PikPakAccountStore.readPrivateFile(directory.appendingPathComponent("desktop-oauth-profile-v3"))
            guard String(data: marker, encoding: .utf8) == "3" else { throw PikPakAccountError.missingSession }
        }
        guard let rawToken = String(data: try PikPakAccountStore.readPrivateFile(credentialURL(for: kind)), encoding: .utf8),
              let deviceID = String(data: try PikPakAccountStore.readPrivateFile(directory.appendingPathComponent("device-id")), encoding: .utf8)
        else { throw PikPakAccountError.missingSession }
        let token = try kind.parse(rawToken)
        guard Self.validDeviceID(deviceID) else { throw PikPakAccountError.missingSession }
        return PikPakAccountSession(token: token, deviceID: deviceID, credentialKind: kind)
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
    // Store mutations are synchronous and performed on the app's main actor.
    // Protect unfinished logins from cleanup when a second workspace opens.
    private static var stagedSessionPaths = Set<String>()
    static let didChange = Notification.Name("MyCloudDriver.PikPakAccountsDidChange")
    let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("accounts.json") }

    init(directory: URL) throws {
        self.directory = directory
        try Self.prepareDirectory(directory)
        let document = try load()
        let retained = Set(document.accounts.filter { !$0.needsSignIn }.map(\.id))
        // Recover interrupted staging/logout after a crash, before workers start.
        for child in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            if let id = UUID(uuidString: child.lastPathComponent), !retained.contains(id),
               !Self.stagedSessionPaths.contains(child.standardizedFileURL.path) {
                try? discard(files(for: id))
            }
        }
    }

    func load() throws -> PikPakAccountsDocument {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return PikPakAccountsDocument() }
        let document = try JSONDecoder().decode(PikPakAccountsDocument.self, from: Self.readPrivateFile(indexURL))
        let ids = Set(document.accounts.map(\.id))
        guard document.version == 1, ids.count == document.accounts.count,
              document.activeID.map(ids.contains) ?? true,
              document.workspaceSelections?.values.allSatisfy({ $0.activeID.map(ids.contains) ?? true }) ?? true
        else { throw PikPakAccountError.invalidStorage }
        return document
    }

    func files(for id: UUID) -> PikPakAccountSessionFiles {
        PikPakAccountSessionFiles(id: id, directory: directory.appendingPathComponent(id.uuidString, isDirectory: true))
    }

    /// Snapshot the starting account once. Later primary-window switches must
    /// not change another existing workspace's selection implicitly.
    @discardableResult
    func registerWorkspace(_ workspaceSessionID: String) throws -> PikPakAccountsDocument {
        var document = try load()
        if workspaceSessionID != "primary", document.workspaceSelections?[workspaceSessionID] == nil {
            document.select(document.activeID, for: workspaceSessionID)
            try save(document)
        }
        return document
    }

    func stage(token: String, deviceID: String, credentialKind: PikPakCredentialKind = .desktopOAuth) throws -> PikPakAccountSessionFiles {
        let token = try credentialKind.parse(token)
        guard PikPakAccountSessionFiles.validDeviceID(deviceID) else { throw PikPakAccountError.missingSession }
        let files = files(for: UUID())
        Self.stagedSessionPaths.insert(files.directory.standardizedFileURL.path)
        do {
            try Self.prepareDirectory(files.directory)
            try Self.writePrivateFile(Data(token.utf8), to: files.credentialURL(for: credentialKind))
            try Self.writePrivateFile(Data(deviceID.utf8), to: files.directory.appendingPathComponent("device-id"))
            if credentialKind == .desktopOAuth {
                try Self.writePrivateFile(Data("3".utf8), to: files.directory.appendingPathComponent("desktop-oauth-profile-v3"))
            }
            try Self.writePrivateFile(Data(credentialKind.rawValue.utf8), to: files.directory.appendingPathComponent("credential-kind"))
            return files
        } catch {
            try? discard(files)
            throw error
        }
    }

    @discardableResult
    func commit(_ files: PikPakAccountSessionFiles, profile: PikPakAccountProfile?, checkedAt: Date? = nil,
                workspaceSessionID: String = "primary") throws -> PikPakAccountsDocument {
        guard files.directory == self.files(for: files.id).directory else { throw PikPakAccountError.invalidStorage }
        let session = try files.load()
        if let profile, profile.sub.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw PikPakAccountError.invalidProfile }
        var document = try load()
        let replaced = document.accounts.filter {
            $0.id != files.id && profile != nil && $0.profile?.sub == profile?.sub
                && $0.connectionKind == session.credentialKind
        }
        document.accounts.removeAll { old in old.id == files.id || replaced.contains(where: { $0.id == old.id }) }
        document.accounts.append(.init(id: files.id, profile: profile, needsSignIn: false, lastChecked: checkedAt, credentialKind: session.credentialKind))
        // Reauthentication follows the same connection in other workspaces;
        // adding another method or user changes only the initiating workspace.
        let replacedIDs = Set(replaced.map(\.id))
        if let current = document.activeID, replacedIDs.contains(current) { document.activeID = files.id }
        for key in Array(document.workspaceSelections?.keys ?? Dictionary<String, PikPakWorkspaceAccountSelection>().keys) {
            if let selected = document.workspaceSelections?[key]?.activeID, replacedIDs.contains(selected) {
                document.workspaceSelections?[key] = .init(activeID: files.id)
            }
        }
        document.select(files.id, for: workspaceSessionID)
        try save(document)
        Self.stagedSessionPaths.remove(files.directory.standardizedFileURL.path)
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
    func activate(_ id: UUID, workspaceSessionID: String = "primary") throws -> PikPakAccountsDocument {
        var document = try load()
        guard let account = document.accounts.first(where: { $0.id == id }), !account.needsSignIn else { throw PikPakAccountError.missingSession }
        _ = try files(for: id).load()
        document.select(id, for: workspaceSessionID)
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
        if deactivate {
            for key in Array(document.workspaceSelections?.keys ?? Dictionary<String, PikPakWorkspaceAccountSelection>().keys)
                where document.workspaceSelections?[key]?.activeID == id {
                document.workspaceSelections?[key] = .init(activeID: nil)
            }
        }
        // Revoke local eligibility first. A partially failed removal is never loaded.
        try save(document)
        try discard(files(for: id))
        return document
    }

    func discard(_ files: PikPakAccountSessionFiles) throws {
        guard files.directory == self.files(for: files.id).directory else { throw PikPakAccountError.invalidStorage }
        Self.stagedSessionPaths.remove(files.directory.standardizedFileURL.path)
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
        NotificationCenter.default.post(name: Self.didChange, object: self)
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

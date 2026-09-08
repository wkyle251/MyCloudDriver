import Foundation

enum LocalCredentialStoreError: LocalizedError {
    case applicationSupportUnavailable
    case invalidStorageLocation
    case invalidData
    case untrustedSession

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            return "The user Application Support folder is unavailable."
        case .invalidStorageLocation:
            return "The local session storage path is not a regular private file."
        case .invalidData:
            return "The saved local session is not valid UTF-8."
        case .untrustedSession:
            return "The saved session is not a verified independent desktop session."
        }
    }
}

enum LocalCredentialStore {
    static let displayPath = "~/Library/Application Support/My PikPak for Mac/Session/refresh-token"
    static let applicationSupportDirectoryName = "My PikPak for Mac"
    private static let legacyApplicationSupportDirectoryName = "PikPak Downloader"
    private static let tokenFilename = "refresh-token"
    private static let deviceIDFilename = "device-id"
    private static let sessionProfileFilename = "desktop-oauth-profile-v3"
    private static let legacySessionProfileFilename = "app-login-profile-v2"
    private static let refreshLockFilename = "refresh-token.lock"

    static func loadToken() throws -> String? {
        let fileManager = FileManager.default
        let url = try tokenFileURL()
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw LocalCredentialStoreError.invalidStorageLocation
        }

        try protectTokenFile(at: url)
        let data = try Data(contentsOf: url)
        guard let token = String(data: data, encoding: .utf8) else {
            throw LocalCredentialStoreError.invalidData
        }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func saveToken(_ token: String) throws {
        let normalized = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw LocalCredentialStoreError.invalidData
        }

        let fileManager = FileManager.default
        let directory = try sessionDirectoryURL()
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw LocalCredentialStoreError.invalidStorageLocation
            }
        } else {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )

        let url = directory.appendingPathComponent(tokenFilename, isDirectory: false)
        if fileManager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw LocalCredentialStoreError.invalidStorageLocation
            }
        }

        // Atomic replacement keeps the previous valid token intact if a write
        // is interrupted. The owner-only directory prevents access while the
        // replacement file's final mode is being applied.
        try Data(normalized.utf8).write(to: url, options: .atomic)
        try protectTokenFile(at: url)
    }

    static func deleteToken() throws {
        let fileManager = FileManager.default
        let url = try tokenFileURL()
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    static func tokenFileURL() throws -> URL {
        try sessionDirectoryURL().appendingPathComponent(tokenFilename, isDirectory: false)
    }

    static func refreshLockFileURL() throws -> URL {
        try sessionDirectoryURL().appendingPathComponent(refreshLockFilename, isDirectory: false)
    }

    static func loadOrCreateDeviceID() throws -> String {
        if let stored = try loadPrivateString(named: deviceIDFilename) {
            return try normalizedDeviceID(stored)
        }
        let generated = UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        try saveDeviceID(generated)
        return generated
    }

    static func saveDeviceID(_ deviceID: String) throws {
        try savePrivateString(
            try normalizedDeviceID(deviceID),
            named: deviceIDFilename
        )
    }

    static func hasDedicatedAppLoginProfile() throws -> Bool {
        // Version 3 is the first profile whose token was issued to PikPak's
        // desktop OAuth client. Version 2 used the Web client and could still
        // contend with Safari's refresh-token family.
        try loadPrivateString(named: sessionProfileFilename) == "3"
    }

    static func markDedicatedAppLoginProfile() throws {
        try savePrivateString("3", named: sessionProfileFilename)
    }

    static func clearDedicatedAppLoginProfile() throws {
        try removePrivateFile(named: sessionProfileFilename)
    }

    static func clearLegacyAppLoginProfile() throws {
        try removePrivateFile(named: legacySessionProfileFilename)
    }

    private static func removePrivateFile(named filename: String) throws {
        let url = try sessionDirectoryURL()
            .appendingPathComponent(filename, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    /// Builds before 1.17 could leave per-process copies behind when the app
    /// was force-quit. They are no longer used now that the engine coordinates
    /// directly through the shared session file.
    static func removeLegacyCredentialExchangeFiles() {
        guard let applicationSupport = try? applicationSupportDirectoryURL() else { return }
        let directory = applicationSupport
            .appendingPathComponent("Credential Exchange", isDirectory: true)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let prefixes = [
            "token-input-",
            "token-output-",
            "duplicate-token-input-",
            "duplicate-token-output-",
            "upload-inputs-",
        ]
        for url in contents where prefixes.contains(where: url.lastPathComponent.hasPrefix) {
            guard
                let values = try? url.resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
                ),
                values.isRegularFile == true,
                values.isSymbolicLink != true
            else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func loadPrivateString(named filename: String) throws -> String? {
        let url = try sessionDirectoryURL().appendingPathComponent(filename, isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw LocalCredentialStoreError.invalidStorageLocation
        }
        try protectTokenFile(at: url)
        let data = try Data(contentsOf: url)
        guard let value = String(data: data, encoding: .utf8) else {
            throw LocalCredentialStoreError.invalidData
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func savePrivateString(_ value: String, named filename: String) throws {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw LocalCredentialStoreError.invalidData }
        let directory = try sessionDirectoryURL()
        try ensurePrivateDirectory(directory)
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw LocalCredentialStoreError.invalidStorageLocation
            }
        }
        try Data(normalized.utf8).write(to: url, options: .atomic)
        try protectTokenFile(at: url)
    }

    private static func normalizedDeviceID(_ deviceID: String) throws -> String {
        let normalized = deviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let permitted = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-:"))
        guard
            (16...256).contains(normalized.count),
            normalized.unicodeScalars.allSatisfy(permitted.contains)
        else {
            throw LocalCredentialStoreError.invalidData
        }
        return normalized
    }

    private static func protectTokenFile(at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(resourceValues)
    }

    private static func sessionDirectoryURL() throws -> URL {
        let directory = try applicationSupportDirectoryURL()
            .appendingPathComponent("Session", isDirectory: true)
        try ensurePrivateDirectory(directory)
        return directory
    }

    static func applicationSupportDirectoryURL() throws -> URL {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw LocalCredentialStoreError.applicationSupportUnavailable
        }
        let directory = applicationSupport.appendingPathComponent(
            applicationSupportDirectoryName,
            isDirectory: true
        )
        try migrateLegacyApplicationSupportDirectoryIfNeeded(
            from: applicationSupport.appendingPathComponent(
                legacyApplicationSupportDirectoryName,
                isDirectory: true
            ),
            to: directory
        )
        try ensurePrivateDirectory(directory)
        return directory
    }

    private static func migrateLegacyApplicationSupportDirectoryIfNeeded(
        from legacyDirectory: URL,
        to currentDirectory: URL
    ) throws {
        let fileManager = FileManager.default
        var currentIsDirectory: ObjCBool = false
        if fileManager.fileExists(
            atPath: currentDirectory.path,
            isDirectory: &currentIsDirectory
        ) {
            let values = try currentDirectory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard currentIsDirectory.boolValue, values.isSymbolicLink != true else {
                throw LocalCredentialStoreError.invalidStorageLocation
            }
            return
        }

        var legacyIsDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: legacyDirectory.path,
            isDirectory: &legacyIsDirectory
        ) else { return }
        let legacyValues = try legacyDirectory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard legacyIsDirectory.boolValue, legacyValues.isSymbolicLink != true else {
            throw LocalCredentialStoreError.invalidStorageLocation
        }
        try fileManager.moveItem(at: legacyDirectory, to: currentDirectory)
    }

    private static func ensurePrivateDirectory(_ directory: URL) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw LocalCredentialStoreError.invalidStorageLocation
            }
        } else {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
    }
}

struct StoredSession {
    let token: String?
    let deviceID: String
    let removedUntrustedCredential: Bool
    let requiresDedicatedSignIn: Bool
}

enum SessionStore {
    /// Loads only a session issued to this app's desktop OAuth profile.
    /// Web-client tokens left by older builds or copied from a browser are
    /// deliberately discarded instead of being adopted into the desktop
    /// token-rotation chain.
    static func loadIsolatedSession() throws -> StoredSession {
        let localToken = try LocalCredentialStore.loadToken()
        let legacyToken = try LegacyKeychainStore.loadToken()
        let hasDedicatedProfile = try LocalCredentialStore.hasDedicatedAppLoginProfile()
        try LocalCredentialStore.clearLegacyAppLoginProfile()
        let trustedToken = hasDedicatedProfile ? localToken : nil
        let hasUntrustedLocalToken = localToken != nil && !hasDedicatedProfile
        let requiresDedicatedSignIn = trustedToken == nil
            && (localToken != nil || legacyToken != nil)

        // A Keychain token predates desktop authorization and may be the same
        // Web token Safari uses. Never copy it into the active local session.
        if legacyToken != nil {
            try LegacyKeychainStore.deleteToken()
        }
        if hasUntrustedLocalToken {
            try LocalCredentialStore.deleteToken()
        }
        if trustedToken == nil && hasDedicatedProfile {
            // A marker without its matching token is not a usable session.
            try LocalCredentialStore.clearDedicatedAppLoginProfile()
        }

        let deviceID = try LocalCredentialStore.loadOrCreateDeviceID()
        return StoredSession(
            token: trustedToken,
            deviceID: deviceID,
            removedUntrustedCredential: legacyToken != nil || hasUntrustedLocalToken,
            requiresDedicatedSignIn: requiresDedicatedSignIn
        )
    }

    static func saveDedicatedSession(token: String, deviceID: String) throws {
        // The trust marker is committed last. If any preceding write fails,
        // the next launch refuses the partial session instead of using it.
        try LocalCredentialStore.clearDedicatedAppLoginProfile()
        try LocalCredentialStore.clearLegacyAppLoginProfile()
        do {
            try LocalCredentialStore.saveDeviceID(deviceID)
            try LocalCredentialStore.saveToken(token)
            try LegacyKeychainStore.deleteToken()
            try LocalCredentialStore.markDedicatedAppLoginProfile()
        } catch {
            try? LocalCredentialStore.clearDedicatedAppLoginProfile()
            throw error
        }
    }

    static func deleteToken() throws {
        // Clear trust first so a partial deletion can never leave a token that
        // the next launch mistakes for a valid app-owned session.
        try LocalCredentialStore.clearDedicatedAppLoginProfile()
        try LocalCredentialStore.clearLegacyAppLoginProfile()
        try LocalCredentialStore.deleteToken()
        try LegacyKeychainStore.deleteToken()
    }
}

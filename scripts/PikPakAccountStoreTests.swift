import Foundation

@main
struct PikPakAccountStoreTests {
    static func require(_ condition: Bool) { precondition(condition) }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pikpak-account-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PikPakAccountStore(directory: root)
        let deviceA = String(repeating: "a", count: 32), deviceB = String(repeating: "b", count: 32)
        let legacy = StoredSession(token: "token-a", deviceID: deviceA, removedUntrustedCredential: false, requiresDedicatedSignIn: false)
        let migrated = try store.migrateLegacySession(legacy)
        let idA = migrated.activeID!
        let filesA = store.files(for: idA)
        require(try filesA.load().token == "token-a")
        let profileA = PikPakAccountProfile(sub: "account-a", name: "Taylor Chen")
        _ = try store.updateProfile(profileA, for: idA)
        let again = try store.migrateLegacySession(StoredSession(token: "must-not-reimport", deviceID: deviceA,
            removedUntrustedCredential: false, requiresDedicatedSignIn: false))
        require(again.accounts.count == 1 && again.activeID == idA)
        let index = try String(contentsOf: root.appendingPathComponent("accounts.json"), encoding: .utf8)
        require(!index.contains("token-a") && !index.contains(deviceA))
        for (url, mode) in [(root, 0o700), (filesA.directory, 0o700), (filesA.tokenURL, 0o600), (root.appendingPathComponent("accounts.json"), 0o600)] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            require((attributes[.posixPermissions] as? NSNumber)?.intValue == mode)
        }
        print("PASS migration: trusted token preserved once, private directories/files, no credentials in account metadata")

        let cancelled = try store.stage(token: "discarded", deviceID: deviceB)
        try store.discard(cancelled)
        require(try store.load() == again)
        let filesB = try store.stage(token: "token-b", deviceID: deviceB)
        let profileB = PikPakAccountProfile(sub: "account-b", name: "Jordan Lee")
        _ = try store.commit(filesB, profile: profileB, checkedAt: Date())
        require(filesA.tokenURL != filesB.tokenURL && filesA.lockURL != filesB.lockURL)
        try PikPakAccountStore.writePrivateFile(Data("rotated-b".utf8), to: filesB.tokenURL)
        require(try filesA.load().token == "token-a")
        require(try filesB.load().token == "rotated-b")
        _ = try store.activate(idA)
        require(try store.load().activeID == idA)
        _ = try store.activate(filesB.id)
        require(try store.files(for: store.load().activeID!).load().token == "rotated-b")
        print("PASS sessions: cancelled staging, independent device/token/lock files, refreshed token reused when switching")

        let renewed = try store.stage(token: "renewed-a", deviceID: deviceB)
        let updated = try store.commit(renewed, profile: profileA)
        require(updated.accounts.count == 2 && updated.activeID == renewed.id)
        require(!FileManager.default.fileExists(atPath: filesA.directory.path))
        let loggedOut = try store.logOut(renewed.id)
        require(loggedOut.activeID == nil && loggedOut.accounts.first(where: { $0.id == renewed.id })?.needsSignIn == true)
        require(!FileManager.default.fileExists(atPath: renewed.directory.path))
        require(try filesB.load().token == "rotated-b")
        do { _ = try store.activate(renewed.id); preconditionFailure("signed-out account activated") }
        catch PikPakAccountError.missingSession { }
        _ = try store.activate(filesB.id)
        do { _ = try store.updateProfile(profileA, for: filesB.id); preconditionFailure("wrong account accepted") }
        catch PikPakAccountError.accountMismatch { }
        print("PASS accounts: duplicate sign-in replaces the same account, logout removes only its credentials, identity mismatch rejected")

        let sentinel = root.appendingPathComponent("sentinel")
        try Data("unchanged".utf8).write(to: sentinel)
        try FileManager.default.removeItem(at: filesB.tokenURL)
        do { _ = try filesB.load(); preconditionFailure("missing token accepted") }
        catch PikPakAccountError.missingSession { }
        try FileManager.default.createSymbolicLink(at: filesB.tokenURL, withDestinationURL: sentinel)
        do { _ = try filesB.load(); preconditionFailure("symlink token accepted") }
        catch PikPakAccountError.invalidStorage { }
        require(try String(contentsOf: sentinel, encoding: .utf8) == "unchanged")
        let untrusted = try PikPakAccountStore(directory: root.appendingPathComponent("untrusted"))
        let empty = try untrusted.migrateLegacySession(StoredSession(token: "web-token", deviceID: deviceA,
            removedUntrustedCredential: true, requiresDedicatedSignIn: true))
        require(empty.accounts.isEmpty && empty.activeID == nil)
        print("PASS storage validation: symlinks and untrusted legacy sessions rejected without changing other files")
    }
}

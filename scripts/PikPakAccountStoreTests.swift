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
        try workspaceIsolation(at: root.appendingPathComponent("workspaces"))
        try loginMethods(at: root.appendingPathComponent("login-methods"))
    }

    static func loginMethods(at root: URL) throws {
        let store = try PikPakAccountStore(directory: root)
        let profile = PikPakAccountProfile(sub: "same-user", name: "Both methods")
        let device = String(repeating: "a", count: 32)
        let oauth = try store.stage(token: "normal-login", deviceID: device)
        _ = try store.commit(oauth, profile: profile)
        _ = try store.registerWorkspace("secondary")
        let token = "eyJmaXh0dXJlIjoxfQ.eyJzdWIiOiJmaXh0dXJlIn0.fixture-signature"
        let pat = try store.stage(token: token, deviceID: device, credentialKind: .personalAccessToken)
        var document = try store.commit(pat, profile: profile, workspaceSessionID: "secondary")
        require(document.accounts.count == 2 && document.activeID == oauth.id && document.activeID(for: "secondary") == pat.id)
        require(try oauth.load().token == "normal-login")
        require(PikPakAccountGroup.grouped(document.accounts).count == 1)
        let pat2 = try store.stage(token: token, deviceID: device, credentialKind: .personalAccessToken)
        document = try store.commit(pat2, profile: profile, workspaceSessionID: "secondary")
        require(document.accounts.count == 2 && document.activeID == oauth.id && document.activeID(for: "secondary") == pat2.id)
        require(!FileManager.default.fileExists(atPath: pat.directory.path))
        let oauth2 = try store.stage(token: "renewed-normal", deviceID: device)
        document = try store.commit(oauth2, profile: profile)
        require(document.accounts.count == 2 && document.activeID == oauth2.id && document.activeID(for: "secondary") == pat2.id)
        let reopened = try PikPakAccountStore(directory: root)
        require(try reopened.files(for: pat2.id).load().token == token)
        _ = try reopened.logOut(pat2.id)
        require(try reopened.files(for: oauth2.id).load().token == "renewed-normal")
        require(try reopened.load().activeID == oauth2.id && reopened.load().activeID(for: "secondary") == nil)
        print("PASS login methods: grouped user, separate saved methods, renewal follows only the same method, independent workspace selection and logout")
    }

    static func workspaceIsolation(at root: URL) throws {
        let primary = try PikPakAccountStore(directory: root)
        let a = try primary.stage(token: "workspace-token-a", deviceID: String(repeating: "a", count: 32))
        let profileA = PikPakAccountProfile(sub: "workspace-a", name: "Account A")
        _ = try primary.commit(a, profile: profileA)
        let b = try primary.stage(token: "workspace-token-b", deviceID: String(repeating: "b", count: 32))
        let profileB = PikPakAccountProfile(sub: "workspace-b", name: "Account B")
        _ = try primary.commit(b, profile: profileB)
        _ = try primary.activate(a.id)
        let pending = try primary.stage(token: "pending-login", deviceID: String(repeating: "c", count: 32))
        let secondary = try PikPakAccountStore(directory: root)
        require(try pending.load().token == "pending-login")
        _ = try secondary.registerWorkspace("secondary")
        _ = try secondary.activate(b.id, workspaceSessionID: "secondary")
        var snapshot = try primary.updateProfile(profileA, for: a.id)
        require(snapshot.activeID == a.id && snapshot.activeID(for: "secondary") == b.id)
        _ = try primary.activate(b.id)
        _ = try primary.activate(a.id)
        snapshot = try secondary.updateProfile(profileB, for: b.id)
        require(snapshot.activeID == a.id && snapshot.activeID(for: "secondary") == b.id)
        let reopened = try PikPakAccountStore(directory: root)
        require(try reopened.load().activeID(for: "secondary") == b.id)
        require(primary.files(for: a.id).tokenURL == secondary.files(for: a.id).tokenURL)
        require(primary.files(for: a.id).lockURL == secondary.files(for: a.id).lockURL)
        require(primary.files(for: a.id).tokenURL != secondary.files(for: b.id).tokenURL)
        require(primary.files(for: a.id).lockURL != secondary.files(for: b.id).lockURL)
        _ = try secondary.logOut(b.id)
        snapshot = try primary.load()
        require(snapshot.activeID == a.id && snapshot.activeID(for: "secondary") == nil)
        require(try primary.files(for: a.id).load().token == "workspace-token-a")
        let c = try secondary.stage(token: "workspace-token-c", deviceID: String(repeating: "d", count: 32))
        _ = try secondary.commit(c, profile: .init(sub: "workspace-c", name: "Account C"), workspaceSessionID: "secondary")
        snapshot = try primary.load()
        require(snapshot.activeID == a.id && snapshot.activeID(for: "secondary") == c.id)
        try primary.discard(pending)
        let base = root.appendingPathComponent("Transfers")
        require(PikPakWorkspaceStorage.directory(base, workspaceSessionID: "primary") == base)
        require(PikPakWorkspaceStorage.directory(base, workspaceSessionID: "secondary") == base.appendingPathComponent("Sessions/secondary", isDirectory: true))
        var paths: Set<URL> = [base, PikPakWorkspaceStorage.directory(base, workspaceSessionID: "secondary")]
        for slot in 3...128 {
            let id = PikPakWorkspaceStorage.sessionID(for: slot)
            require(PikPakWorkspaceStorage.isValidSessionID(id))
            require(paths.insert(PikPakWorkspaceStorage.directory(base, workspaceSessionID: id)).inserted)
        }
        for invalid in ["", "../primary", "workspace-../../", "workspace-2", "workspace-03", "workspace-+3", "workspace--3", "workspace-3/extra"] {
            require(!PikPakWorkspaceStorage.isValidSessionID(invalid))
        }
        for slot in 3...12 {
            let id = PikPakWorkspaceStorage.sessionID(for: slot)
            let windowStore = try PikPakAccountStore(directory: root)
            _ = try windowStore.registerWorkspace(id)
            _ = try windowStore.activate(slot.isMultiple(of: 2) ? a.id : c.id, workspaceSessionID: id)
        }
        snapshot = try primary.load()
        require(snapshot.activeID == a.id && snapshot.activeID(for: "secondary") == c.id)
        for slot in 3...12 {
            require(snapshot.activeID(for: PikPakWorkspaceStorage.sessionID(for: slot)) == (slot.isMultiple(of: 2) ? a.id : c.id))
        }
        print("PASS workspace isolation: 12 persisted account selections, 128 unique queue paths, legacy path compatibility, safe identifiers, shared account locks and staging preserved")
    }
}

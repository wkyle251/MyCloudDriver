import Foundation

@main
struct WorkspaceAccountSelectionTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("workspace-account-selection-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try PikPakAccountStore(directory: root)
        let first = try store.stage(token: "synthetic-first-account", deviceID: String(repeating: "a", count: 32))
        _ = try store.commit(first, profile: .init(sub: "synthetic-first", name: "First"))
        let second = try store.stage(token: "synthetic-second-account", deviceID: String(repeating: "b", count: 32))
        _ = try store.commit(second, profile: .init(sub: "synthetic-second", name: "Second"))
        _ = try store.activate(first.id)
        let sourceID = PikPakWorkspaceStorage.newSessionID()
        let targetID = PikPakWorkspaceStorage.newSessionID()
        _ = try store.selectWorkspaceAccount(second.id, workspaceSessionID: sourceID)
        var document = try store.selectWorkspaceAccount(second.id, workspaceSessionID: targetID)
        precondition(document.activeID == first.id && document.activeID(for: sourceID) == second.id)
        precondition(document.activeID(for: targetID) == second.id)
        let emptyID = PikPakWorkspaceStorage.newSessionID()
        document = try store.selectWorkspaceAccount(nil, workspaceSessionID: emptyID)
        precondition(document.workspaceSelections?[emptyID] != nil && document.activeID(for: emptyID) == nil)
        precondition(document.activeID == first.id && document.activeID(for: targetID) == second.id)
        // A new window may inherit a sign-in-required choice without attempting
        // verification or loading the deliberately removed synthetic session.
        _ = try store.logOut(second.id, deactivate: false)
        let disconnectedID = PikPakWorkspaceStorage.newSessionID()
        document = try store.selectWorkspaceAccount(second.id, workspaceSessionID: disconnectedID)
        precondition(document.activeID(for: disconnectedID) == second.id)
        precondition(document.accounts.first { $0.id == second.id }!.needsSignIn)
        let firstSession = try first.load()
        precondition(firstSession.token == "synthetic-first-account")
        let before = try store.load()
        do {
            _ = try store.selectWorkspaceAccount(first.id, workspaceSessionID: "../primary")
            preconditionFailure("Invalid window identifier accepted")
        } catch PikPakAccountError.invalidStorage { }
        do {
            _ = try store.selectWorkspaceAccount(UUID(), workspaceSessionID: PikPakWorkspaceStorage.newSessionID())
            preconditionFailure("Missing account accepted")
        } catch PikPakAccountError.missingSession { }
        let after = try store.load()
        precondition(after == before, "Rejected selection must leave all account metadata intact")
        print("PASS workspace account copying: independent selected accounts, explicit nil, sign-in-required choices, unchanged credentials, invalid-ID/account rejection")
    }
}

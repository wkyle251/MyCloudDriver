import Foundation

@MainActor private final class WindowRelayFixtureEngine: LocalTorrentDriving {
    var running = false
    var calls = 0
    func start() async throws { calls += 1; preconditionFailure("Unexpected fixture engine start") }
    func addMagnet(_ magnet: String, directory: URL) async throws -> String { calls += 1; preconditionFailure("Unexpected fixture metadata") }
    func addTorrent(_ data: Data, directory: URL, selection: [Int]?) async throws -> String { calls += 1; preconditionFailure("Unexpected fixture download") }
    func status(_ id: String, files: Bool) async throws -> LocalTorrentStatus { calls += 1; preconditionFailure("Unexpected fixture poll") }
    func begin(_ id: String, directory: URL, selection: [Int]) async throws { calls += 1; preconditionFailure("Unexpected fixture download") }
    func reselect(_ id: String, selection: [Int]) async throws { calls += 1; preconditionFailure("Unexpected fixture selection") }
    func pause(_ id: String) async throws { calls += 1; preconditionFailure("Unexpected fixture pause") }
    func remove(_ id: String) async throws { calls += 1; preconditionFailure("Unexpected fixture removal") }
    func stop() { running = false }
}

@main struct WindowTorrentRelayTests {
    @MainActor static func main() throws {
        func require(_ value: Bool, _ message: String = "Window relay fixture assertion failed") { precondition(value, message) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("window-relay-fixture-\(UUID().uuidString)")
        let engine = WindowRelayFixtureEngine()
        let relay = LocalTorrentModel(dnsProbe: { _ in .clean }, directory: root, engine: engine)
        let first = DownloaderModel.finderWorkspaceFixture()
        let other = DownloaderModel.finderWorkspaceFixture(workspaceSessionID: "secondary")
        let same = DownloaderModel.finderWorkspaceFixture(workspaceSessionID: "workspace-3")
        defer {
            first.stopForWindowClose(); other.stopForWindowClose(); same.stopForWindowClose()
            relay.shutdown(); try? FileManager.default.removeItem(at: root)
        }
        func context(_ account: String, kind: PikPakCredentialKind = .desktopOAuth) -> PikPakManagementContext {
            .init(identity: UUID(), accountID: account, engineURL: URL(fileURLWithPath: "/synthetic-helper"), environment: [:], credentialKind: kind)
        }
        func configure(_ window: DownloaderModel, _ value: PikPakManagementContext) {
            window.pikpakManagement.fixture = { _ in preconditionFailure("Unexpected fixture cloud request") }
            window.pikpakManagement.configure(value)
            relay.configureRelayAccount(window)
        }
        func state(_ value: PikPakManagementContext) -> TorrentRelayState {
            .init(identity: value.identity, accountID: value.accountID, credentialKind: value.credentialKind,
                  accountName: value.accountID, parentID: "destination", parentName: "Destination", rootName: "Generated",
                  memoryBytes: 256 * 1024 * 1024, batches: [[1]])
        }
        let original = context("synthetic-a"), different = context("synthetic-b")
        configure(first, original); configure(other, different)
        let transfer = state(original)
        require(try relay.relayContext(transfer).identity == original.identity,
                     "Opening another account must preserve an existing relay's credentials")
        require(relay.relayContextProvider?()?.identity == different.identity,
                     "New drafts follow the latest usable window")

        var firstRefreshes = 0, otherRefreshes = 0, sameRefreshes = 0, fixtureRefreshes = 0
        first.pikpakManagement.onFilesChanged = { firstRefreshes += 1 }
        other.pikpakManagement.onFilesChanged = { otherRefreshes += 1 }
        same.pikpakManagement.onFilesChanged = { sameRefreshes += 1 }
        relay.relayFilesChanged = { fixtureRefreshes += 1 }
        relay.notifyRelayFilesChanged(accountID: original.accountID)
        require(firstRefreshes == 1 && otherRefreshes == 0 && fixtureRefreshes == 1,
                     "Upload notifications refresh the owning account only")

        let token = context(original.accountID, kind: .personalAccessToken)
        configure(same, token)
        require(try relay.relayContext(transfer).credentialKind == .personalAccessToken)
        let changedLogin = context(original.accountID)
        same.pikpakManagement.configure(changedLogin)
        require(try relay.relayContext(transfer).identity == changedLogin.identity,
                     "Registered windows must follow refreshed credentials and changed login methods")
        relay.notifyRelayFilesChanged(accountID: original.accountID)
        require(firstRefreshes == 2 && sameRefreshes == 1 && otherRefreshes == 0)

        var job = LocalTorrentJob(id: UUID(), name: "Generated relay", phase: .paused)
        job.relay = transfer; relay.jobs = [job]
        require(!relay.needsRelayAccount(first) && !relay.needsRelayAccount(same),
                     "Another usable window can own the same account")
        same.stopForWindowClose()
        require(try relay.relayContext(transfer).identity == original.identity,
                     "Closing the newest same-account window must fall back to a live window")
        require(relay.needsRelayAccount(first) && !relay.needsRelayAccount(other),
                     "The last eligible owner must remain available for a paused relay's Resume")
        other.stopForWindowClose()
        require(relay.relayContextProvider?()?.identity == original.identity)

        var transient: DownloaderModel? = DownloaderModel.finderWorkspaceFixture(workspaceSessionID: "workspace-4")
        configure(transient!, context("synthetic-c"))
        let candidate = relay.relayAccountCandidates.first { $0.identity == ObjectIdentifier(transient!) }!
        transient = nil
        require(candidate.account == nil, "The relay registry must not retain Browser windows")
        require(relay.relayContextProvider?()?.identity == original.identity)

        relay.relayContextProvider = { different }
        relay.configureRelayAccount(first)
        require(relay.relayContextProvider?()?.identity == different.identity,
                     "Registering windows must preserve an explicitly injected context provider")
        do { _ = try relay.relayContext(transfer); preconditionFailure("Injected wrong account was accepted") }
        catch {}
        relay.relayContextProvider = { nil }
        do { _ = try relay.relayContext(transfer); preconditionFailure("Injected unavailable login was ignored") }
        catch {}
        relay.relayContextProvider = nil
        require(try relay.relayContext(transfer).identity == original.identity)
        relay.edit(job.id) { $0.phase = .completed }
        require(!relay.needsRelayAccount(first))
        relay.edit(job.id) { $0.phase = .stopped }
        require(!relay.needsRelayAccount(first))
        first.stopForWindowClose()
        require(relay.relayContextProvider?() == nil)
        do { _ = try relay.relayContext(transfer); preconditionFailure("Closed window supplied stale credentials") }
        catch {}
        require(engine.calls == 0)
        print("PASS window relay credentials: account routing, live-window fallback, login changes, weak ownership, last-owner retention, account refreshes and fixture overrides")
    }
}

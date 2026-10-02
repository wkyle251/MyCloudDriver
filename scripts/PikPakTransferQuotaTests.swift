import AppKit
import SwiftUI

@main
struct PikPakTransferQuotaTests {
    @MainActor
    static func main() async throws {
        if CommandLine.arguments.contains("--ui") { launchUI(); return }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let snapshot = try decoder.decode(PikPakQuotaSnapshot.self, from: Data(#"{"account_id":"a","total":1000,"used":100,"transfer":{"cloudDownload":{"total":40000,"used":142},"downstream":{"total":4000,"used":4040},"upload":{"total":1000,"used":72}}}"#.utf8))
        precondition(snapshot.transfer.downstream?.remaining == 0)
        precondition(snapshot.transfer.downstream?.used == 4040 && snapshot.transfer.downstream?.usedFraction == 1)
        let missing = try decoder.decode(PikPakQuotaSnapshot.self, from: Data(#"{"account_id":"a","total":1000,"used":100,"transfer":{"upload":{"total":1000,"used":0}}}"#.utf8))
        precondition(missing.transfer.downstream == nil && missing.transfer.cloudDownload == nil)
        precondition(missing.transfer.upload?.used == 0)
        precondition(missing.transfer.counters(for: .personalAccessToken) == .unavailable,
                     "Missing Connected Apps counters must not fall back to full-account counters")
        let separate = try decoder.decode(PikPakQuotaSnapshot.self, from: Data(#"{"account_id":"a","total":1000,"used":100,"transfer":{"downstream":{"total":4000,"used":4040},"connectedApps":{"cloudDownload":{"total":10000,"used":0},"downstream":{"total":1033,"used":0},"upload":{"total":250,"used":72},"dailyDownstream":{"total":5,"used":6}}}}"#.utf8))
        precondition(separate.transfer.counters(for: .desktopOAuth).downstream?.total == 4000)
        precondition(separate.transfer.counters(for: .personalAccessToken).downstream?.total == 1033)
        precondition(separate.transfer.counters(for: .personalAccessToken).downstream?.used == 0)
        precondition(separate.transfer.counters(for: .personalAccessToken).dailyDownstream?.remaining == 0)
        precondition(pikpakTrafficBytes(1099511627776) == "1 TB" && pikpakTrafficBytes(274877906944) == "256 GB")
        print("PASS traffic decoding: account identity, overages, missing counters and genuine zero usage")

        var now = Date(timeIntervalSince1970: 1_000)
        let monitor = PikPakTransferQuotaMonitor(now: { now })
        var calls = 0
        await monitor.refresh(accountID: "a") { calls += 1; return snapshot }
        let updated = monitor.updatedAt
        await monitor.refresh(accountID: "a") { calls += 1; return snapshot }
        precondition(calls == 1, "multiple windows must share one refresh interval")
        now.addTimeInterval(60)
        await monitor.refresh(accountID: "a") { calls += 1; throw URLError(.notConnectedToInternet) }
        precondition(calls == 2 && monitor.error != nil && monitor.updatedAt == updated && monitor.snapshot == snapshot)
        await monitor.refresh(accountID: "a", force: true) { calls += 1; return missing }
        precondition(calls == 3 && monitor.error == nil && monitor.snapshot == missing && monitor.updatedAt == now)
        let other = PikPakQuotaSnapshot(accountId: "b", total: 2000, used: 10, transfer: snapshot.transfer)
        await monitor.refresh(accountID: "a", force: true) { other }
        precondition(monitor.snapshot == missing && monitor.error != nil, "wrong-account reply must be rejected")
        await monitor.refresh(accountID: "b") { throw URLError(.notConnectedToInternet) }
        precondition(monitor.snapshot == nil && monitor.updatedAt == nil, "an account switch must clear old counters")
        print("PASS traffic refresh: minute polling, deduplication, manual retry, stale data and identity checks")

        monitor.clear()
        var finishOld: CheckedContinuation<PikPakQuotaSnapshot, Never>?
        let old = Task {
            await monitor.refresh(accountID: "a") {
                await withCheckedContinuation { finishOld = $0 }
            }
        }
        while finishOld == nil { await Task.yield() }
        precondition(monitor.isRefreshing)
        await monitor.refresh(accountID: "a", force: true) { preconditionFailure("must not duplicate an active read") }
        await monitor.refresh(accountID: "b") { other }
        finishOld?.resume(returning: snapshot)
        _ = await old.value
        precondition(monitor.snapshot == other && !monitor.isRefreshing)
        monitor.clear()
        let cancelled = Task {
            await monitor.refresh(accountID: "a") {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return snapshot
            }
        }
        while !monitor.isRefreshing { await Task.yield() }
        cancelled.cancel()
        _ = await cancelled.value
        precondition(monitor.snapshot == nil && !monitor.isRefreshing && monitor.error == nil)
        print("PASS traffic lifecycle: late replies, overlapping windows and cancellation")

        monitor.clear()
        let normalID = UUID(), tokenID = UUID()
        var finishNormal: CheckedContinuation<PikPakQuotaSnapshot, Never>?
        let normalRequest = Task {
            await monitor.refresh(accountID: "a", connectionID: normalID) {
                await withCheckedContinuation { finishNormal = $0 }
            }
        }
        while finishNormal == nil { await Task.yield() }
        await monitor.refresh(accountID: "a", connectionID: tokenID) { separate }
        finishNormal?.resume(returning: snapshot)
        _ = await normalRequest.value
        precondition(monitor.snapshot == separate && !monitor.isRefreshing, "Old normal-login reply must not replace token-login quotas for the same user")
        await monitor.refresh(accountID: "a", connectionID: normalID) { throw URLError(.notConnectedToInternet) }
        precondition(monitor.snapshot == nil && monitor.updatedAt == nil, "Changing methods must clear cached usage even for the same account")
        print("PASS login quota scopes: exact server counters, binary units, unavailable app counters and stale replies across same-user login changes")

        try await DownloaderModel.testPersonalAccessTokenConnection()
        try await DownloaderModel.testAccountManagement()
        try await DownloaderModel.testWorkspaceAccountIsolation()
        try DownloaderModel.testGuestMode()

        if CommandLine.arguments.count > 1 {
            let engine = URL(fileURLWithPath: CommandLine.arguments[1])
            let live = PikPakTransferQuotaMonitor()
            await live.refresh(engineURL: engine, environment: [:], accountID: "offline-fixture")
            precondition(live.snapshot?.transfer.downstream?.used == 4040 && live.processIdentifier == nil)
            await live.refresh(engineURL: engine, environment: ["ACCOUNT_FIXTURE_MODE": "offline"], accountID: "offline-fixture", force: true)
            precondition(live.error != nil && live.snapshot?.transfer.downstream?.used == 4040 && live.processIdentifier == nil)
            print("PASS real quota helper: arguments, JSON delivery, failed refresh and process cleanup")
        }
    }

    @MainActor static func launchUI() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let window = NSWindow(contentRect: NSRect(x: 130, y: 120, width: 1150, height: 790),
                              styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "PikPak login modes · Offline fixture"
        window.contentView = NSHostingView(rootView: PikPakLoginQuotaFixture())
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}

@MainActor private struct PikPakLoginQuotaFixture: View {
    @StateObject private var model = try! DownloaderModel.finderConnectionsFixture()

    var body: some View {
        ContentView().environmentObject(model).environmentObject(model.finderSettings)
            .task(id: model.activeAccountID) {
                guard let accountID = model.accountProfile?.sub else { return }
                await model.transferQuotaMonitor.refresh(accountID: accountID, connectionID: model.activeAccountID, force: true) {
                    PikPakQuotaSnapshot(accountId: accountID, total: 10995116277760, used: 9434371735620,
                        transfer: .init(cloudDownload: .init(total: 43980465111040, used: 152720035987),
                            downstream: .init(total: 4398046511104, used: 4475785804855),
                            upload: .init(total: 1099511627776, used: 78226191465),
                            connectedApps: .init(cloudDownload: .init(total: 10995116277760, used: 0),
                                downstream: .init(total: 1099511627776, used: 0), upload: .init(total: 274877906944, used: 0))))
                }
            }
    }
}

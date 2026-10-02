import SwiftUI

/// The production sidebar and quota panel with synthetic counters; no engine.
@main
struct PikPakTransferQuotaUITestApp: App {
    @StateObject private var model = DownloaderModel.finderWorkspaceFixture()

    var body: some Scene {
        WindowGroup("MyCloudDriver · Quota Test") {
            ContentView().environmentObject(model).environmentObject(model.finderSettings)
                .task { await loadFixture() }
        }
        .defaultSize(width: 1100, height: 760)
        .commands {
            CommandMenu("Quota Fixture") {
                Button("Over Limit") { Task { await loadFixture() } }
                Button("Refresh Failure") {
                    Task { await model.transferQuotaMonitor.refresh(accountID: "offline-account", force: true) { throw URLError(.notConnectedToInternet) } }
                }
                Button("Missing Counters") {
                    Task {
                        await model.transferQuotaMonitor.refresh(accountID: "offline-account", force: true) {
                            PikPakQuotaSnapshot(accountId: "offline-account", total: 1000, used: 100,
                                transfer: PikPakTransferQuota(cloudDownload: nil, downstream: nil, upload: nil))
                        }
                    }
                }
            }
        }
    }

    @MainActor
    private func loadFixture() async {
        await model.transferQuotaMonitor.refresh(accountID: "offline-account", force: true) {
            PikPakQuotaSnapshot(accountId: "offline-account", total: 10995116277760, used: 9434371735620,
                transfer: PikPakTransferQuota(
                    cloudDownload: StorageQuota(total: 43980465111040, used: 152720035987),
                    downstream: StorageQuota(total: 4398046511104, used: 4449698404042),
                    upload: StorageQuota(total: 1099511627776, used: 78226191465)))
        }
    }
}

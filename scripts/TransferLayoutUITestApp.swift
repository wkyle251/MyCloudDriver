import AppKit
import SwiftUI

/// Production transfer panes, isolated preferences and synthetic transfer data.
/// Window presets change only this fixture's window; no downloaded file is read.
@main @MainActor struct TransferLayoutUITestApp: App {
    @StateObject private var hub: CloudDriveHub
    @State private var dark = false
    private let preferences: UserDefaults

    init() {
        let suite = "com.wky.MyCloudDriver.TransferLayoutFixture.preferences"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(1, forKey: "selectedTransferMode")
        preferences = defaults
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TransferLayoutUI-\(UUID().uuidString)")
        let model = DownloaderModel.downloadRetryFixture(defaults: defaults, directory: directory)
        let hub = CloudDriveHub(pikpak: model, defaults: defaults, restoreConnections: false)
        hub.open(.pikpak); hub.pikpakNavigation.showImmediately(1)
        _hub = StateObject(wrappedValue: hub)
    }

    var body: some Scene {
        WindowGroup("MyCloudDriver · Transfer Layout Fixture") {
            MyCloudDriverRootView(hub: hub, settings: hub.pikpak.finderSettings)
                .defaultAppStorage(preferences).preferredColorScheme(dark ? .dark : .light)
        }.defaultSize(width: 720, height: 850)
        .commands {
            FinderCommands(settings: hub.pikpak.finderSettings)
            CommandMenu("Fixture") {
                Button("Uploads") { preferences.set(1, forKey: "selectedTransferMode") }
                Button("Downloads") { preferences.set(0, forKey: "selectedTransferMode") }
                Button("Show Download Progress") {
                    preferences.set(0, forKey: "selectedTransferMode")
                    hub.pikpak.retryFailedDownloads()
                    hub.pikpak.showDownloadRetryFixtureProgress()
                }
                Divider()
                Button("Window 600 × 850") { resize(width: 600, height: 850) }
                Button("Window 720 × 850") { resize(width: 720, height: 850) }
                Button("Window 1100 × 850") { resize(width: 1_100, height: 850) }
                Button("Window 1400 × 1000") { resize(width: 1_400, height: 1_000) }
                Button("Toggle Appearance") { dark.toggle() }
            }
        }
    }

    private func resize(width: CGFloat, height: CGFloat) {
        guard let window = NSApp.windows.first(where: { $0.title.contains("Transfer Layout Fixture") }) else { return }
        window.setContentSize(.init(width: width, height: height))
    }
}

import AppKit
import SwiftUI

/// Production transfer UI with an isolated account and a held synthetic engine.
@main @MainActor struct DownloadRetryUITestApp: App {
    @StateObject private var hub: CloudDriveHub
    @State private var dark = false
    private let preferences: UserDefaults
    init() {
        let suite = "com.wky.MyCloudDriver.DownloadRetryFixture.preferences"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(0, forKey: "selectedTransferMode")
        preferences = defaults
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadRetryUI-\(UUID().uuidString)")
        let model = DownloaderModel.downloadRetryFixture(defaults: defaults, directory: directory)
        let hub = CloudDriveHub(pikpak: model, defaults: defaults, restoreConnections: false)
        hub.open(.pikpak); hub.pikpakNavigation.showImmediately(1)
        _hub = StateObject(wrappedValue: hub)
    }
    var body: some Scene {
        WindowGroup("MyCloudDriver · Download Retry Fixture") {
            MyCloudDriverRootView(hub: hub, settings: hub.pikpak.finderSettings)
                .defaultAppStorage(preferences).preferredColorScheme(dark ? .dark : .light)
        }.defaultSize(width: 1240, height: 900)
        .commands {
            FinderCommands(settings: hub.pikpak.finderSettings)
            CommandMenu("Fixture") {
                Button("Show Download Progress") { hub.pikpak.showDownloadRetryFixtureProgress() }
                Button("Simulate Stop") { hub.pikpak.stopDownloadRetryFixture() }
                Button("Toggle Appearance") { dark.toggle() }
            }
        }
    }
}

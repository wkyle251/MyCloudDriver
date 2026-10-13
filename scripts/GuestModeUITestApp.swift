import AppKit
import SwiftUI

/// Production navigation with isolated preferences, generated files and no
/// account credentials, cloud requests or Photos-library access.
@main @MainActor struct GuestModeUITestApp: App {
    @StateObject private var hub: CloudDriveHub
    private let preferences: UserDefaults
    private let fixtureDirectory: URL

    init() {
        let defaults = UserDefaults(suiteName: "MyCloudDriver-NavigationControls-UI-Fixture-\(UUID().uuidString)")!
        preferences = defaults
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MyCloudDriverNavigationFixture-\(UUID().uuidString)", isDirectory: true)
        fixtureDirectory = root
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let hub = CloudDriveHub(pikpak: DownloaderModel.finderWorkspaceFixture(defaults: defaults),
            defaults: defaults, restoreConnections: false,
            photosAccess: .init(status: { .denied }, request: { .denied }, provider: { PhotosDriveProvider() }),
            localRootURL: root)
        hub.open(.pikpak)
        _hub = StateObject(wrappedValue: hub)
    }

    var body: some Scene {
        WindowGroup("MyCloudDriver · Navigation Test") {
            MyCloudDriverRootView(hub: hub, settings: hub.pikpak.finderSettings)
                .defaultAppStorage(preferences)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    hub.close(); hub.pikpak.stopForWindowClose(); try? FileManager.default.removeItem(at: fixtureDirectory)
                }
        }
        .defaultSize(width: 1240, height: 820)
        .commands { FinderCommands(settings: hub.pikpak.finderSettings) }
        Settings {
            FinderSettingsView(settings: hub.pikpak.finderSettings, model: hub.pikpak, hub: hub)
        }
    }
}

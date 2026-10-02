import SwiftUI

/// Production navigation with isolated preferences, generated files and no
/// account credentials, cloud requests or Photos-library access.
@main @MainActor struct GuestModeUITestApp: App {
    @StateObject private var hub: CloudDriveHub
    private let preferences: UserDefaults

    init() {
        let defaults = UserDefaults(suiteName: "MyCloudDriver-NavigationControls-UI-Fixture")!
        preferences = defaults
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyCloudDriverNavigationFixture", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
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
        }
        .defaultSize(width: 1240, height: 820)
        .commands { FinderCommands(settings: hub.pikpak.finderSettings) }
        Settings {
            FinderSettingsView(settings: hub.pikpak.finderSettings, model: hub.pikpak, hub: hub)
        }
    }
}

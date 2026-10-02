// Offline harness for the shipping search commands and workspace lifecycle.
// Root search shows its configuration error because no cloud helper is bundled.
import AppKit
import SwiftUI

@main struct WorkspaceSearchUITestApp: App {
    @StateObject private var sessions = makeSessions()

    @MainActor private static func makeSessions() -> WorkspaceSessionManager {
        let defaults = UserDefaults(suiteName: "com.wky.MyCloudDriver.SearchCommandsQA.fixtures")!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyCloudSearchCommandsQA-files")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func hub(_ id: String = "primary", settings: FinderSettings? = nil) -> CloudDriveHub {
            CloudDriveHub(pikpak: DownloaderModel.finderWorkspaceFixture(defaults: defaults, workspaceSessionID: id, settings: settings),
                defaults: defaults, restoreConnections: false,
                photosAccess: .init(status: { .denied }, request: { .denied }, provider: { PhotosDriveProvider() }),
                localRootURL: root)
        }
        return WorkspaceSessionManager(initialHub: hub(), makeHub: { hub($0, settings: $1) })
    }

    var body: some Scene {
        Window("Search Commands QA", id: "main") {
            WorkspaceSessionRoot(hub: sessions.initialHub, manager: sessions)
        }
        .defaultSize(width: 1100, height: 800)
        .commands {
            FinderCommands(settings: sessions.settings, sessions: sessions)
            FinderSearchCommands(sessions: sessions)
        }
    }
}

import AppKit
import SwiftUI

/// Isolated Home/Settings UI with a synthetic task label and bounded CPU helper.
/// The GPU panel reads the real device counter. No account credentials are used.
@MainActor final class ResourcesHomeQAModel: ObservableObject {
    let sessions: WorkspaceSessionManager
    private var child: Process?
    private let fixtureDirectory: URL
    init() {
        let defaults = UserDefaults(suiteName: "MyCloudResourcesHomeQA-\(UUID().uuidString)")!
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MyCloudResourcesHomeQA-\(UUID().uuidString)")
        fixtureDirectory = root
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        func makeHub(_ id: String = "primary", settings: FinderSettings? = nil) -> CloudDriveHub {
            CloudDriveHub(pikpak: DownloaderModel.finderWorkspaceFixture(defaults: defaults, workspaceSessionID: id, settings: settings),
                defaults: defaults, restoreConnections: false,
                photosAccess: .init(status: { .denied }, request: { .denied }, provider: { PhotosDriveProvider() }), localRootURL: root)
        }
        sessions = WorkspaceSessionManager(initialHub: makeHub(), makeHub: { makeHub($0, settings: $1) })
    }
    func start() {
        guard child == nil, let executable = Bundle.main.url(forResource: "resource-fixture", withExtension: nil) else { return }
        let child = Process(); child.executableURL = executable
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        do { try child.run() } catch { return }
        self.child = child
        sessions.initialHub.pikpak.additionalResourceActivities = { [weak child] in
            guard let child, child.isRunning else { return [:] }
            return [child.processIdentifier: .init(name: "Finding similar files · PikPak", detail: "Sample library\nFinding and analysing files…",
                symbol: "doc.text.magnifyingglass", processing: .init(backend: .coreml, activeJobs: 2, jobLimit: 2))]
        }
    }
    func close() {
        if child?.isRunning == true { child?.terminate() }; child = nil
        sessions.closeAll(); try? FileManager.default.removeItem(at: fixtureDirectory)
    }
    deinit { if child?.isRunning == true { child?.terminate() }; try? FileManager.default.removeItem(at: fixtureDirectory) }
}

@main struct ResourcesHomeUITestApp: App {
    @StateObject private var qa = ResourcesHomeQAModel()
    var body: some Scene {
        Window("Resources and Home QA", id: "main") {
            WorkspaceSessionRoot(hub: qa.sessions.initialHub, manager: qa.sessions).task { qa.start() }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in qa.close() }
        }
        .defaultSize(width: 1240, height: 900)
        .commands { FinderCommands(settings: qa.sessions.settings, sessions: qa.sessions) }
        Settings {
            FinderSettingsView(settings: qa.sessions.settings, model: qa.sessions.activeHub.pikpak, initialPane: 1, hub: qa.sessions.activeHub)
        }
    }
}

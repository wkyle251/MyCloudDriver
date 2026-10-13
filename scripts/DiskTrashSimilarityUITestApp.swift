import AppKit
import SwiftUI

/// Production workspace and commands, isolated defaults, generated files only.
@MainActor final class DiskTrashSimilarityQA: ObservableObject {
    let suite = "com.wky.MyCloudDriver.FeatureQA.\(UUID())"
    let root: URL
    let files: URL
    let defaults: UserDefaults
    let hub: CloudDriveHub
    let sessions: WorkspaceSessionManager
    private var held = true
    private var waiter: CheckedContinuation<Void, Never>?
    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MyCloudDriverFeatureQA-\(UUID())").resolvingSymlinksInPath()
        files = root.appendingPathComponent("Files")
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(0, forKey: "browserViewMode"); defaults.set(false, forKey: "showsPreviewPane")
        try! FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
        let garden = String(repeating: "A garden with trees, a lawn and colourful flowers. ", count: 30)
        for name in ["Garden.txt", "Garden copy.txt", "Seaside.txt"] {
            try! (name == "Seaside.txt" ? String(repeating: "The sea and beach under a blue sky. ", count: 30) : garden)
                .write(to: files.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        hub = CloudDriveHub(pikpak: DownloaderModel.finderWorkspaceFixture(defaults: defaults), defaults: defaults,
                           restoreConnections: false, localRootURL: files)
        hub.local.connect(ICloudDriveProvider(rootURL: files, kind: .local, diskTrashRootURL: root))
        hub.open(.local)
        sessions = WorkspaceSessionManager(initialHub: hub)
        hub.local.similarity.configuration = { _ in
            let resources = URL(fileURLWithPath: "/Users/wky/Work/PikPakDownloader/dist/AppBuild.noindex/MyCloudDriver.app/Contents/Resources")
            return SimilarityConfiguration(executable: resources.appendingPathComponent("pikpak"), models: resources.appendingPathComponent("FileTwinModels"),
                worker: resources.appendingPathComponent("filetwin-worker"), dataDirectory: self.root.appendingPathComponent("data"),
                temporaryDirectory: self.root.appendingPathComponent("temp"), environment: [:])
        }
    }
    func showSimilarity() {
        guard !hub.local.similarity.local.isRunning else { hub.local.similarity.present(source: .local); return }
        hub.local.findSimilar([], presentWindow: false)
        let scan = hub.local.similarity.local
        scan.families = ["text"]
        let inventory = scan.streamExternalSources!
        scan.streamExternalSources = { emit in
            var count = 0
            try await inventory { source in
                count += 1
                if count == 3 && self.held { await withCheckedContinuation { self.waiter = $0 } }
                try Task.checkCancellation()
                try await emit(source)
            }
        }
        hub.local.similarity.present(source: .local)
    }
    func release() { held = false; waiter?.resume(); waiter = nil }
    func close() {
        release(); sessions.closeAll(); defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor final class DiskTrashSimilarityQADelegate: NSObject, NSApplicationDelegate {
    weak var fixture: DiskTrashSimilarityQA?
    func applicationWillTerminate(_ notification: Notification) { fixture?.close() }
}

@main struct DiskTrashSimilarityUITestApp: App {
    @NSApplicationDelegateAdaptor(DiskTrashSimilarityQADelegate.self) private var delegate
    @StateObject private var fixture = DiskTrashSimilarityQA()
    var body: some Scene {
        Window("Trash and Similarity · Generated Files Only", id: "main") {
            VStack(spacing: 0) {
                HStack {
                    Text("Generated files only").font(.headline)
                    Spacer()
                    Button("Find Similar (Fixture)") { fixture.showSimilarity() }
                    Button("Release Remaining Files") { fixture.release() }
                }.padding(10)
                WorkspaceSessionRoot(hub: fixture.hub, manager: fixture.sessions)
            }.defaultAppStorage(fixture.defaults).onAppear { delegate.fixture = fixture }
        }.defaultSize(width: 1200, height: 850)
        .commands {
            FinderCommands(settings: fixture.sessions.settings, sessions: fixture.sessions)
            FinderSearchCommands(sessions: fixture.sessions)
        }
    }
}

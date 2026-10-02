import AppKit
import SwiftUI

/// Native menus/keyboard verification with isolated synthetic cloud IDs.
@main struct FileUndoUITestApp: App {
    @StateObject private var model: DownloaderModel
    @StateObject private var sessions: WorkspaceSessionManager
    @State private var text = ""
    init() {
        let suite = "com.wky.PikPakUndoUI.fixture"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = DownloaderModel.finderWorkspaceFixture(defaults: defaults)
        model.configureFileUndoFixture()
        _model = StateObject(wrappedValue: model)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyCloudDriverUndoUI-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let hub = CloudDriveHub(pikpak: model, defaults: defaults, restoreConnections: false,
            photosAccess: .init(status: { .denied }, request: { .denied }, provider: { PhotosDriveProvider() }), localRootURL: root)
        _sessions = StateObject(wrappedValue: WorkspaceSessionManager(initialHub: hub))
    }
    var body: some Scene {
        WindowGroup("My PikPak · Undo Test") {
            VStack(spacing: 0) {
                HStack {
                    ForEach(["trash", "trash-folder", "trash-batch", "move", "upload", "rename", "folder"], id: \.self) { scenario in
                        Button("Test \(scenario)") { model.configureFileUndoFixture(scenario) }
                    }
                    TextField("Type here to test text undo", text: $text).textFieldStyle(.roundedBorder)
                }.padding(10)
                ContentView().environmentObject(model).environmentObject(model.finderSettings)
            }

        }
        .defaultSize(width: 1240, height: 800)
        .commands { FinderCommands(settings: model.finderSettings, sessions: sessions) }
        Settings { FinderSettingsView(settings: model.finderSettings, model: model) }
    }

}

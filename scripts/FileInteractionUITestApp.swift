import AppKit
import SwiftUI

/// Real file menus and the system Quick Look panel, using local sample text.
/// No PikPak engine, credentials or network are available in this bundle.
@main
struct FileInteractionUITestApp: App {
    @StateObject private var model: DownloaderModel
    private let directory: URL
    private let loadsMetadata: Bool

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PikPak-FileUI-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let suite = (Bundle.main.bundleIdentifier ?? "com.wky.PikPakFileUI") + ".fixture"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = DownloaderModel.finderWorkspaceFixture(defaults: defaults)
        let navigation = Bundle.main.object(forInfoDictionaryKey: "QuickLookNavigation") as? Bool == true
        loadsMetadata = !navigation && Bundle.main.object(forInfoDictionaryKey: "FileInteractionLoading") as? Bool == true
        if navigation { try! model.configureQuickLookNavigationFixture(directory: directory) }
        else { try! model.configureFileInteractionFixture(directory: directory, metadataLoading: loadsMetadata) }
        _model = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        WindowGroup("My PikPak · File Interaction Test") {
            ContentView().environmentObject(model).environmentObject(model.finderSettings)
                .task {
                    if loadsMetadata {
                        while !model.isPreparingQuickLook && !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: 50_000_000)
                        }
                        try? await Task.sleep(nanoseconds: 20_000_000_000)
                        if !Task.isCancelled { model.finishFileInteractionPreviewFixture() }
                    }
                }
                .onDisappear {
                    model.stopForWindowClose()
                    try? FileManager.default.removeItem(at: directory)
                }
        }
        .defaultSize(width: 1240, height: 800)
        .commands { FinderCommands(settings: model.finderSettings) }
        Settings { FinderSettingsView(settings: model.finderSettings, model: model) }
    }
}

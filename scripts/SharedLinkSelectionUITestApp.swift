import AppKit
import SwiftUI

/// The production Links view with two synthetic shares and in-memory saves.
/// No account files, live credentials, cloud operations or engine are used.
@main struct SharedLinkSelectionUITestApp: App {
    @StateObject private var model: DownloaderModel
    init() {
        let suite = "com.wky.PikPakSharedSelectionUI.fixture"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        _model = StateObject(wrappedValue: DownloaderModel.sharedSelectionFixture(defaults: defaults))
    }
    var body: some Scene {
        WindowGroup("My PikPak · Links Selection Test") {
            ContentView().environmentObject(model).environmentObject(model.finderSettings)
        }
        .defaultSize(width: 1240, height: 820)
        .commands { FinderCommands(settings: model.finderSettings) }
        Settings { FinderSettingsView(settings: model.finderSettings, model: model) }
    }
}

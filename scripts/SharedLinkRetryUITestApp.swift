import AppKit
import SwiftUI

/// Production Links controls with synthetic failures and delayed local replies.
/// No bundled engine, account files, credentials or network access are used.
@main struct SharedLinkRetryUITestApp: App {
    @StateObject private var model: DownloaderModel
    init() {
        let suite = "com.wky.PikPakSharedLinkRetryUI.fixture"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        _model = StateObject(wrappedValue: DownloaderModel.sharedLinkRetryFixture(defaults: defaults, automatic: true))
    }
    var body: some Scene {
        WindowGroup("My PikPak · Retry Links Test") {
            ContentView().environmentObject(model).environmentObject(model.finderSettings)
        }
        .defaultSize(width: 1240, height: 820)
        .commands { FinderCommands(settings: model.finderSettings) }
    }
}

import AppKit
import SwiftUI

/// Production Browser/Links with synthetic folder trees and isolated settings.
@main struct SharedLinkNavigationUITestApp: App {
    @StateObject private var model: DownloaderModel
    @StateObject private var navigation: FinderWorkspaceNavigation
    private let defaults: UserDefaults
    init() {
        let suite = "com.wky.SharedLinkNavigationUI.fixture"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        self.defaults = defaults
        let model = DownloaderModel.sharedSelectionFixture(defaults: defaults)
        _model = StateObject(wrappedValue: model)
        let navigation = FinderWorkspaceNavigation()
        navigation.showImmediately(3)
        _navigation = StateObject(wrappedValue: navigation)
    }
    var body: some Scene {
        WindowGroup("Links navigation · offline test") {
            ContentView(navigation: navigation).environmentObject(model).environmentObject(model.finderSettings)
                .defaultAppStorage(defaults)
        }
        .defaultSize(width: 1_240, height: 820)
        .commands { FinderCommands(settings: model.finderSettings) }
    }
}

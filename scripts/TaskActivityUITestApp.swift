import AppKit
import SwiftUI

/// Native File menu, Browser, status and duplicate review with synthetic data.
/// This bundle has no engine, saved sessions or network access.
@main
struct TaskActivityUITestApp: App {
    @StateObject private var model: DownloaderModel
    private let scenario: String

    init() {
        let suite = (Bundle.main.bundleIdentifier ?? "com.wky.PikPakTaskActivityUI") + ".fixture"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = DownloaderModel.finderWorkspaceFixture(defaults: defaults)
        model.finderSettings.showsPreviewPane = false
        scenario = Bundle.main.object(forInfoDictionaryKey: "TaskActivityScenario") as? String ?? "running"
        model.configureTaskActivityInspection(scenario)
        _model = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        WindowGroup("My PikPak · Status Test") {
            ContentView().environmentObject(model).environmentObject(model.finderSettings)
                .preferredColorScheme(Bundle.main.object(forInfoDictionaryKey: "TaskActivityDark") as? Bool == true ? .dark : .light)
                .task {
                    if scenario == "results" { model.taskActivity.showsDuplicateResults = true }
                    else if scenario != "ready" {
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        model.taskActivity.showsDetails = true
                    }
                }
        }
        .defaultSize(width: Bundle.main.object(forInfoDictionaryKey: "TaskActivityWidth") as? Double ?? 1240, height: 760)
        .commands { FinderCommands(settings: model.finderSettings) }
    }
}

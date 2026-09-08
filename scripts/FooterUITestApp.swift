import AppKit
import SwiftUI

/// Real workspace/footer with synthetic data. Bundle metadata selects a stable
/// scenario for native screenshots; no engine, credentials or network calls.
@main
struct FooterUITestApp: App {
    @StateObject private var model: DownloaderModel

    init() {
        let suite = (Bundle.main.bundleIdentifier ?? "com.wky.PikPakFooterTest") + ".fixture"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let model = DownloaderModel.finderWorkspaceFixture(defaults: defaults)
        model.finderSettings.showsPreviewPane = false
        model.configureFooterInspection(Bundle.main.object(forInfoDictionaryKey: "FooterInspectionScenario") as? String ?? "ready")
        _model = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        WindowGroup("My PikPak · Footer Test") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.finderSettings)
                .preferredColorScheme(
                    Bundle.main.object(forInfoDictionaryKey: "FooterInspectionDark") as? Bool == true ? .dark : .light
                )
                .task {
                    if let section = Bundle.main.object(forInfoDictionaryKey: "FooterInspectionSection") as? Int {
                        NotificationCenter.default.post(name: .init("PikPakSwitchBenchmark"), object: section)
                    }
                }
        }
        .defaultSize(
            width: Bundle.main.object(forInfoDictionaryKey: "FooterInspectionWidth") as? Double ?? 1240,
            height: 720
        )
        .commands { FinderCommands(settings: model.finderSettings) }
    }
}

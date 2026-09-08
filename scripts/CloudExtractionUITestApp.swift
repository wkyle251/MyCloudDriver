import AppKit
import SwiftUI

/// The real Browser, footer and password sheet with synthetic archives only.
/// Bundle metadata chooses a stable activity/password/narrow/dark UI scenario.
@main
struct CloudExtractionUITestApp: App {
    @StateObject private var model: DownloaderModel
    private let directory: URL
    private let defaults: UserDefaults
    private let scenario: String

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("PikPak-ExtractionUI-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let model = DownloaderModel(archiveTestEngineURL: Bundle.main.url(forResource: "extraction-fixture", withExtension: nil)!, directory: directory)
        defaults = UserDefaults(suiteName: (Bundle.main.bundleIdentifier ?? "com.wky.PikPakExtractionUI") + ".fixture")!
        defaults.removePersistentDomain(forName: (Bundle.main.bundleIdentifier ?? "com.wky.PikPakExtractionUI") + ".fixture")
        scenario = Bundle.main.object(forInfoDictionaryKey: "ExtractionInspectionScenario") as? String ?? "activity"
        model.finderSettings.showsPreviewPane = false
        model.setArchiveTestBrowserItems([
            Self.item("photos", "Holiday Photos.zip"), Self.item("documents", "Project Documents.7z"),
            Self.item("protected-demo", "Personal Backup.zip")], selectedIDs: [])
        if scenario != "password" && scenario != "retry" {
            var active = CloudExtractionTask(id: UUID(), item: Self.item("photos", "Holiday Photos.zip"), parentFolderID: "")
            active.isExtracting = true; active.progress = 42; active.hasReportedProgress = true; active.phase = "Extracting in PikPak"
            var queued = CloudExtractionTask(id: UUID(), item: Self.item("documents", "Project Documents.7z"), parentFolderID: "")
            queued.queuedAction = .extract
            var waiting = CloudExtractionTask(id: UUID(), item: Self.item("protected-demo", "Personal Backup.zip"), parentFolderID: "")
            waiting.inspection = ArchiveInspection(title: waiting.item.name, status: "PASSWORD_REQUIRED", statusText: "Password required", ready: false, requiredPassword: true, entries: [])
            waiting.passwordPromptDeferred = true
            var failed = CloudExtractionTask(id: UUID(), item: Self.item("unavailable", "Unavailable Archive.rar"), parentFolderID: "")
            failed.error = AppErrorDiagnostic(source: "PikPak", code: "HTTP 503", message: "The service is temporarily unavailable. Try again.", context: nil)
            var complete = CloudExtractionTask(id: UUID(), item: Self.item("completed", "Finished Backup.zip"), parentFolderID: "")
            complete.result = ArchiveExtractionResult(archiveFileId: "completed", outputFileId: "output", progress: 100, phase: "Complete")
            model.extractionActivity.tasks = [active, queued, waiting, failed, complete]
        }
        _model = StateObject(wrappedValue: model)
    }

    var body: some Scene {
        WindowGroup("My PikPak · Extraction Test") {
            ContentView().environmentObject(model).environmentObject(model.finderSettings)
                .defaultAppStorage(defaults)
                .preferredColorScheme(Bundle.main.object(forInfoDictionaryKey: "ExtractionInspectionDark") as? Bool == true ? .dark : .light)
                .task {
                    if scenario == "password" || scenario == "retry" {
                        model.openArchiveExtraction(Self.item("protected-demo", "Personal Backup.zip"))
                        if scenario == "retry" {
                            while model.extractionActivity.passwordRequest == nil { try? await Task.sleep(nanoseconds: 20_000_000) }
                            if let request = model.extractionActivity.passwordRequest {
                                model.submitArchivePassword("incorrect", for: request)
                                model.archivePasswordSheetDidDismiss()
                            }
                        }
                    } else if scenario != "footer" {
                        try? await Task.sleep(nanoseconds: 350_000_000)
                        model.extractionActivity.showsActivity = true
                    }
                }
                .onDisappear {
                    model.stopArchiveTestHelpers()
                    try? FileManager.default.removeItem(at: directory)
                }
        }
        .defaultSize(width: Bundle.main.object(forInfoDictionaryKey: "ExtractionInspectionWidth") as? Double ?? 1240, height: 820)
        .commands { FinderCommands(settings: model.finderSettings) }
        Settings { FinderSettingsView(settings: model.finderSettings, model: model) }
    }

    private static func item(_ id: String, _ name: String) -> BrowserItem {
        BrowserItem(id: id, name: name, size: 12_288, kind: .file, parentId: "", mimeType: "application/zip",
            createdTime: nil, modifiedTime: nil, fileExtension: (name as NSString).pathExtension,
            iconLink: nil, thumbnailLink: nil, fileCategory: nil, hash: "gcid-\(id)", md5Checksum: nil)
    }
}

import AppKit
import SwiftUI

/// Records only generated update counts and the fixture's own toolbar geometry.
@MainActor enum SettingsIconRenderProbe {
    static var renders = 0
    static func navigationRendered() { renders += 1 }
}

@MainActor final class SettingsIconStress: ObservableObject {
    func run(model: DownloaderModel) async {
        let run = Bundle.main.object(forInfoDictionaryKey: "SettingsIconRunName") as? String ?? "sample"
        let report = FileManager.default.temporaryDirectory.appendingPathComponent("MyCloudSettingsIcons-\(run).jsonl")
        FileManager.default.createFile(atPath: report.path, contents: nil)
        guard let output = try? FileHandle(forWritingTo: report) else { return }
        defer { try? output.close() }
        var updates = 0
        while !Task.isCancelled {
            model.status = "Generated background progress \(updates)"
            updates += 1
            if updates % 20 == 0 {
                let toolbar = NSApp.windows.first { $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" }?.toolbar
                var tabs: [[String: Any]] = []
                for item in toolbar?.items ?? [] {
                    var tab: [String: Any] = ["label": item.label]
                    if let image = item.image {
                        tab["bitmap"] = !image.representations.isEmpty && image.representations.allSatisfy { $0 is NSBitmapImageRep }
                        tab["width"] = Double(image.size.width)
                        tab["height"] = Double(image.size.height)
                    }
                    tabs.append(tab)
                }
                let entry: [String: Any] = ["updates": updates, "navigation_renders": SettingsIconRenderProbe.renders, "tabs": tabs]
                if let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) {
                    try? output.write(contentsOf: data + Data([10]))
                }
            }
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
        }
    }
}

/// The real Settings scene under 20 synthetic progress updates per second.
/// No user preferences, account credentials, cloud requests or Photos access.
@main @MainActor struct SettingsIconStabilityUITestApp: App {
    @StateObject private var hub: CloudDriveHub
    @StateObject private var stress = SettingsIconStress()
    private let fixtureDirectory: URL
    init() {
        let defaults = UserDefaults(suiteName: "MyCloudDriver-SettingsIcons-UI-Fixture-\(UUID().uuidString)")!
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("MyCloudSettingsIconsFixture-\(UUID().uuidString)", isDirectory: true)
        fixtureDirectory = root
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        _hub = StateObject(wrappedValue: CloudDriveHub(
            pikpak: DownloaderModel.finderWorkspaceFixture(defaults: defaults), defaults: defaults,
            restoreConnections: false,
            photosAccess: .init(status: { .denied }, request: { .denied }, provider: { PhotosDriveProvider() }),
            localRootURL: root))
    }
    var body: some Scene {
        WindowGroup("Settings Icon Test") {
            VStack(spacing: 16) {
                Text("Settings icon stability").font(.headline)
                Text("Generated progress updates · no cloud access")
                FinderSettingsButton()
            }.padding(30)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    hub.close(); hub.pikpak.stopForWindowClose(); try? FileManager.default.removeItem(at: fixtureDirectory)
                }
        }.defaultSize(width: 420, height: 180)
        Settings {
            FinderSettingsView(settings: hub.pikpak.finderSettings, model: hub.pikpak, hub: hub)
                .task { await stress.run(model: hub.pikpak) }
        }
    }
}

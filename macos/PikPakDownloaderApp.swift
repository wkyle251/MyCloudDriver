import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var transfers: DownloaderModel?
    weak var fileSearch: FileSearchModel?
    weak var drives: CloudDriveHub?

    func applicationWillTerminate(_ notification: Notification) {
        transfers?.stopForWindowClose()
        fileSearch?.close()
        drives?.close()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct PikPakDownloaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var hub: CloudDriveHub
    private var model: DownloaderModel { hub.pikpak }

    init() {
        _hub = StateObject(wrappedValue: CloudDriveHub(pikpak: DownloaderModel()))
    }

    var body: some Scene {
        WindowGroup {
            MyCloudDriverRootView(hub: hub, settings: model.finderSettings)
                .onAppear {
                    appDelegate.transfers = model
                    appDelegate.fileSearch = model.fileSearch
                    appDelegate.drives = hub
                }
        }
        .defaultSize(width: 1240, height: 900)
        .commands {
            FinderCommands(settings: model.finderSettings)
            CommandGroup(after: .textEditing) {
                Button(hub.selected == .pikpak ? "Find in Expanded Items…" : "Find in This Drive…") {
                    if hub.selected == .pikpak { model.presentFileSearch(scope: .expanded) }
                    else { NotificationCenter.default.post(name: .init("MyCloudDriverFind"), object: nil) }
                }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(hub.selected == nil || model.isLoginPresented)
                Button("Find from PikPak Root…") { model.presentFileSearch(scope: .root) }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(hub.selected != .pikpak || model.isLoginPresented)
            }
        }

        Settings {
            FinderSettingsView(settings: model.finderSettings, model: model,
                connections: AnyView(CloudDriveConnectionsView(hub: hub)))
        }
    }
}

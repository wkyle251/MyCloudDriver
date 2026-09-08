import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var transfers: DownloaderModel?
    weak var fileSearch: FileSearchModel?

    func applicationWillTerminate(_ notification: Notification) {
        transfers?.stopForWindowClose()
        fileSearch?.close()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
struct PikPakDownloaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = DownloaderModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.finderSettings)
                .onAppear {
                    appDelegate.transfers = model
                    appDelegate.fileSearch = model.fileSearch
                }
        }
        .defaultSize(width: 1240, height: 900)
        .commands {
            FinderCommands(settings: model.finderSettings)
            CommandGroup(after: .textEditing) {
                Button("Find in Expanded Items…") { model.presentFileSearch(scope: .expanded) }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(model.isLoginPresented)
                Button("Find from PikPak Root…") { model.presentFileSearch(scope: .root) }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(model.isLoginPresented)
            }
        }

        Settings {
            FinderSettingsView(settings: model.finderSettings, model: model)
        }
    }
}

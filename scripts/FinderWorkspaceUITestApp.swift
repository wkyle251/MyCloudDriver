import AppKit
import SwiftUI

/// Real ContentView, commands and Settings, synthetic account/link state only.
/// This bundle deliberately contains no PikPak engine or user credentials.
@main
struct FinderWorkspaceUITestApp: App {
    #if FINDER_ACCOUNTS_TESTS
    @StateObject private var model = try! DownloaderModel.finderAccountsFixture()
    #else
    @StateObject private var model = DownloaderModel.finderWorkspaceFixture()
    #endif
    #if FINDER_APPEARANCE_TESTS
    @State private var darkAppearance = false
    @State private var cursorIsHand = false
    #endif
    var body: some Scene {
        WindowGroup("My PikPak · Offline Finder Test") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.finderSettings)
                #if FINDER_RESOURCE_TESTS
                .task {
                    guard let executable = Bundle.main.url(forResource: "resource-fixture", withExtension: nil) else { return }
                    let child = Process()
                    child.executableURL = executable
                    child.standardOutput = FileHandle.nullDevice
                    child.standardError = FileHandle.nullDevice
                    do {
                        try child.run()
                        defer { if child.isRunning { child.terminate() } }
                        var checked = 1200
                        while !Task.isCancelled && child.isRunning {
                            model.setResourceScanFixture(child, files: checked, folders: checked / 30,
                                                         path: "/Projects/Research/Reports")
                            checked += 150
                            try await Task.sleep(nanoseconds: 2_000_000_000)
                        }
                    } catch { /* Closing the fixture cancels its bounded synthetic task. */ }
                }
                #endif
                #if FINDER_APPEARANCE_TESTS
                .preferredColorScheme(darkAppearance ? .dark : .light)
                .overlay(alignment: .topTrailing) {
                    Text(cursorIsHand ? "Cursor: pointing hand" : "Cursor: arrow")
                        .font(.caption2).padding(4).background(.regularMaterial)
                        .allowsHitTesting(false)
                }
                .onReceive(Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()) { _ in
                    cursorIsHand = NSCursor.current == .pointingHand
                }
                #endif
        }
        .defaultSize(width: 1240, height: 820)
        .commands {
            FinderCommands(settings: model.finderSettings)
            #if FINDER_APPEARANCE_TESTS
            CommandMenu("Fixture") {
                Button("Toggle Appearance") { darkAppearance.toggle() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
            #endif
        }
        Settings {
            #if FINDER_ACCOUNTS_TESTS
            FinderSettingsView(settings: model.finderSettings, model: model, initialPane: 2)
            #elseif FINDER_RESOURCE_TESTS
            FinderSettingsView(settings: model.finderSettings, model: model, initialPane: 1)
            #else
            FinderSettingsView(settings: model.finderSettings, model: model)
            #endif
        }
    }
}

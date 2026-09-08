// Offline UI harness. No account/session files or network APIs are read.
import AppKit
import SwiftUI

@main
struct FileSearchUITestApp: App {
    @StateObject private var search = FileSearchModel()
    @State private var opened = "No search result opened"
    var body: some Scene {
        WindowGroup("PikPak Search UI Test") {
            VStack(alignment: .leading, spacing: 18) {
                Text("My PikPak · Search test").font(.title2.bold())
                Text("⌘F: current expanded sample items · ⌘⇧F: all sample files from root")
                Text(opened).accessibilityIdentifier("openedSearchResult")
                Spacer()
                Text("Isolated test · does not access your PikPak account").foregroundStyle(.secondary)
            }
            .padding(28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay {
                FileSearchOverlay(search: search) { opened = "Revealed: " + $0.match.fullPath }
            }
            .onDisappear { search.close() }
        }
        .defaultSize(width: 920, height: 700)
        .commands {
            CommandGroup(after: .textEditing) {
                Button("Find in Expanded Items…") {
                    search.present(scope: .expanded, expandedItems: [
                        FileSearchMatch(item: .init(id: "reports", name: "Reports", kind: "drive#folder", size: 0,
                                                   mimeType: nil, modifiedTime: nil), ancestors: [], score: 0),
                        FileSearchMatch(item: .init(id: "report-0", name: "Report 000.txt", kind: "drive#file", size: 128,
                                                   mimeType: nil, modifiedTime: nil),
                                        ancestors: [.init(id: "reports", name: "Reports")], score: 0)
                    ], contextName: "Browser · offline fixture")
                }.keyboardShortcut("f", modifiers: .command)
                Button("Find from PikPak Root…") {
                    search.present(configuration: FileSearchConfiguration(
                        executable: Bundle.main.url(forResource: "search-fixture", withExtension: nil)!,
                        directory: FileManager.default.temporaryDirectory,
                        environment: [:]))
                }.keyboardShortcut("f", modifiers: [.command, .shift])
            }
        }
    }
}

// Compile with HEADER_LAYOUT_TESTS + ARCHIVE_TASK_TESTS. Only the actual
// sidebar is mounted; no credentials, account requests or transfers are used.
import AppKit
import SwiftUI

@main
struct HeaderLayoutUITestApp: App {
    @StateObject private var model = DownloaderModel(
        archiveTestEngineURL: URL(fileURLWithPath: "/private/tmp/unused-header-fixture"),
        directory: FileManager.default.temporaryDirectory)

    var body: some Scene {
        WindowGroup("PikPak Header Layout Test") {
            VStack(alignment: .leading, spacing: 24) {
                Text("Sidebar labels · isolated layout test").font(.title2.bold())
                Text("All workspace names remain full labels in the sidebar.")
                    .foregroundStyle(.secondary)
                ForEach([360, 780, 1240], id: \.self) { width in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(width) pt workspace").font(.caption)
                        ContentView()
                            .environmentObject(model)
                            .environmentObject(model.finderSettings)
                            .frame(width: CGFloat(width), height: 340)
                    }
                }
                Spacer()
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .defaultSize(width: 1300, height: 1200)
    }
}

// Isolated native UI harness; mutation boundaries are stubbed by BROWSER_DROP_TESTS.
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct BrowserDragDropUITestApp: App {
    @StateObject private var model = DownloaderModel.browserDropUIFixture()
    @State private var transferTab = "Browser"
    private let fixtureURL: URL = {
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("pikpak-ui-drop-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("fixture.txt")
        try? Data("Offline drag and drop fixture. No upload is performed.".utf8).write(to: url)
        return url
    }()

    var body: some Scene {
        WindowGroup("PikPak · Offline Drag Test") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Finder-style drag test").font(.title2.bold())
                Text("No real account, network, uploads, or moves. Test folder rows and blank space.")
                    .foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Local file source").font(.headline)
                        Label("Fixture.txt", systemImage: "doc.text")
                            .padding(14).frame(width: 175, alignment: .leading)
                            .background(Color.gray.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                            .onDrag { NSItemProvider(object: fixtureURL as NSURL) }
                        Text("Drag this local URL, or drag the fixture file from Finder.")
                            .font(.caption).frame(width: 185).fixedSize(horizontal: false, vertical: true)
                        Text(fixtureURL.path).font(.caption2).textSelection(.enabled).frame(width: 185)
                        Button("Reset Test") {
                            model.isRunning = false
                            model.cancelBrowserDrag()
                            model.status = "Ready"
                            transferTab = "Browser"
                        }.keyboardShortcut("r", modifiers: .command)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text("PikPak").font(.headline).padding(12)
                        Divider()
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(model.browserTreeEntries) { entry in
                                    HStack(spacing: 10) {
                                        if entry.item.isFolder {
                                            Button {
                                                model.toggleBrowserFolderExpansion(entry.item)
                                            } label: {
                                                Image(systemName: model.isBrowserFolderExpanded(entry.id) ? "chevron.down" : "chevron.right")
                                            }.buttonStyle(.plain).frame(width: 16)
                                        } else { Color.clear.frame(width: 16, height: 1) }
                                        Button { model.toggleBrowserCheckbox(entry.item) } label: {
                                            Image(systemName: model.isBrowserItemSelected(entry.id) ? "checkmark.square.fill" : "square")
                                        }.buttonStyle(.plain)
                                        Label(entry.item.name, systemImage: entry.item.isFolder ? "folder.fill" : "doc")
                                            .foregroundStyle(entry.item.isFolder ? Color.accentColor : .primary)
                                        Spacer()
                                        Text(entry.item.isFolder ? "Folder" : "File").foregroundStyle(.secondary)
                                    }
                                    .padding(.leading, 12 + CGFloat(entry.depth) * 20).padding(.trailing, 14)
                                    .frame(height: 38).frame(maxWidth: .infinity)
                                    .background(model.isBrowserItemSelected(entry.id) ? Color.accentColor.opacity(0.15) : Color.gray.opacity(0.035))
                                    .contentShape(Rectangle())
                                    .onTapGesture { model.selectBrowserItem(entry.item) }
                                    .modifier(BrowserMoveDragSourceModifier(model: model, item: entry.item))
                                    .browserDropRegion(id: entry.id, destination: model.browserDropDestination(for: entry.item), isFolder: entry.item.isFolder)
                                }
                            }.frame(maxWidth: .infinity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .browserDropCanvas(model: model, destination: .root, springLoadsFolders: true) {
                        transferTab = "Transfers / Uploads"
                    }
                }
                Text("Tab: \(transferTab)").font(.headline)
                Text(model.status).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12).background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }.padding(24)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    model.stopForWindowClose(); try? FileManager.default.removeItem(at: fixtureURL.deletingLastPathComponent())
                }
        }.defaultSize(width: 980, height: 620)
    }
}

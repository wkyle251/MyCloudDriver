import AppKit
import SwiftUI

/// Offline native-menu fixture: no account, files, engine or preferences.
@main
struct BrowserFolderExpansionUITestApp: App {
    var body: some Scene {
        WindowGroup("PikPak · Expansion Menu Test") {
            ExpansionMenuTestView()
        }
        .defaultSize(width: 560, height: 300)
    }
}

private struct ExpansionMenuTestView: View {
    @State private var result = "No expansion requested"
    @State private var nativeMenu: NSMenu?
    @State private var rowFontSize: CGFloat = 13
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Folder expansion · offline menu test").font(.headline)
            Text("Right-click the folder. Click Expand Folder for one level, or hover to choose 2 Levels and deeper.")
                .fixedSize(horizontal: false, vertical: true)
            Button {} label: { Label("Example Folder", systemImage: "folder.fill") }
                .buttonStyle(.plain)
                .font(.system(size: rowFontSize))
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.blue.opacity(isHovered ? 0.14 : 0.08))
                        .animation(.easeOut(duration: 0.1), value: isHovered)
                }
                .onHover { isHovered = $0 }
                .contextMenu { folderMenu }
            Button("Open Folder Menu ⌘M") { openNativeMenu() }
                .keyboardShortcut("m", modifiers: .command)
            Button("Toggle row size ⌘L") { rowFontSize = rowFontSize == 13 ? 23 : 13 }
                .keyboardShortcut("l", modifiers: .command)
            Text(result).accessibilityIdentifier("expansion-result")
            Text("No cloud data or network is used.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(width: 560, height: 350)
    }

    private func expand(_ levels: Int?) {
        result = levels.map { "Requested: \($0) levels" } ?? "Requested: all levels"
    }

    @ViewBuilder
    private var folderMenu: some View {
        BrowserFolderExpansionMenu(onExpand: expand)
        Button {} label: { BrowserContextMenuStyle.label("Open Folder", systemImage: "folder") }
        Button {} label: { BrowserContextMenuStyle.label("New Folder Inside…", systemImage: "folder.badge.plus") }
        Button {} label: { BrowserContextMenuStyle.label("Recalculate Folder Size", systemImage: "sum") }
        Button {} label: { BrowserContextMenuStyle.label("Rename…", systemImage: "pencil") }
        Divider()
        Button {} label: { BrowserContextMenuStyle.label("Add Folder to Queue", systemImage: "arrow.down.circle") }
        Divider()
        Button(role: .destructive) {} label: { BrowserContextMenuStyle.label("Move to Trash", systemImage: "trash") }
    }

    private func openNativeMenu() {
        if #available(macOS 14.4, *), let view = NSApp.keyWindow?.contentView {
            let menu = NSHostingMenu(rootView: folderMenu)
            nativeMenu = menu
            menu.popUp(positioning: nil, at: NSPoint(x: 40, y: view.bounds.height - 120), in: view)
        }
    }
}

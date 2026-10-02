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
    @State private var stressUpdates = false
    @State private var ticks = 0
    private let timer = Timer.publish(every: 0.15, on: .main, in: .common).autoconnect()
    private let trackingLog = ExpansionMenuTrackingLog.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Folder expansion · offline menu test").font(.headline)
            Text("Right-click the folder, then choose Expand All Levels to open every nested folder.")
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
                .browserContextMenu(nativeMenu: makeNativeMenu) { folderMenu }
            Button("Open Folder Menu ⌘M") { openNativeMenu() }
                .keyboardShortcut("m", modifiers: .command)
            Button("Toggle row size ⌘L") { rowFontSize = rowFontSize == 13 ? 23 : 13 }
                .keyboardShortcut("l", modifiers: .command)
            Toggle("Simulate background progress updates", isOn: $stressUpdates)
            Text("Background updates: \(ticks)").font(.caption).monospacedDigit()
            Text(result).accessibilityIdentifier("expansion-result")
            Text("No cloud data or network is used.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .buttonStyle(FinderButtonStyle())
        .frame(width: 560, height: 410)
        .onReceive(timer) { _ in if stressUpdates { ticks += 1 } }
    }

    private func expand(_ levels: Int?) {
        result = levels.map { "Requested: \($0) levels" } ?? "Requested: all levels"
    }

    @ViewBuilder
    private var folderMenu: some View {
        BrowserFolderExpansionAction(onExpand: expand)
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
        if let view = NSApp.keyWindow?.contentView {
            let menu = makeNativeMenu()
            nativeMenu = menu
            menu.popUp(positioning: nil, at: NSPoint(x: 40, y: view.bounds.height - 120), in: view)
        }
    }

    private func makeNativeMenu() -> NSMenu {
        let menu = BrowserNativeMenu()
        BrowserFolderExpansionAction.add(to: menu, onExpand: expand)
        menu.addAction("Open Folder", symbol: "folder") {}
        menu.addAction("New Folder Inside…", symbol: "folder.badge.plus") {}
        menu.addAction("Recalculate Folder Size", symbol: "sum") {}
        menu.addAction("Rename…", symbol: "pencil") {}
        menu.addItem(.separator())
        menu.addAction("Add Folder to Queue", symbol: "arrow.down.circle") {}
        menu.addItem(.separator())
        menu.addAction("Move to Trash", symbol: "trash") {}
        return menu
    }
}

/// Log only this synthetic fixture's native menu events, without publishing
/// observation state back into the menu being measured.
private final class ExpansionMenuTrackingLog {
    static let shared = ExpansionMenuTrackingLog()
    private var observers: [NSObjectProtocol] = []
    private var depth = 0
    private let url = URL(fileURLWithPath: "/private/tmp/myclouddriver-folder-menu-tracking.log")
    private init() {
        try? Data().write(to: url)
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification,
                     NSMenu.didAddItemNotification, NSMenu.didRemoveItemNotification, NSMenu.didChangeItemNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                self?.record(notification)
            })
        }
    }
    private func record(_ notification: Notification) {
        if notification.name == NSMenu.didBeginTrackingNotification { depth += 1 }
        if depth > 0, let handle = try? FileHandle(forWritingTo: url) {
            let line = "\(notification.name.rawValue) \((notification.object as? NSMenu)?.title ?? "")\n"
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: Data(line.utf8)); try? handle.close()
        }
        if notification.name == NSMenu.didEndTrackingNotification { depth = max(0, depth - 1) }
    }
}

import SwiftUI

struct FinderWindowActions {
    var section: Int
    var viewMode: Int
    var zoom: Double
    var undoTitle: String
    var redoTitle: String
    var canUndo: Bool
    var canRedo: Bool
    var undo: () -> Void
    var redo: () -> Void
    var canRefresh: Bool
    var canGoBack: Bool
    var canUpload: Bool
    var canDownload: Bool
    var canCreateFolder: Bool
    var canTrash: Bool
    var canCheckDuplicates: Bool
    var canReviewDuplicates: Bool
    var canRemoveEmptyFolders: Bool
    var canRemoveDSStoreFiles: Bool
    var canMergeFolders: Bool
    var checkDuplicates: () -> Void
    var reviewDuplicates: () -> Void
    var removeEmptyFolders: () -> Void
    var removeDSStoreFiles: () -> Void
    var mergeFolders: () -> Void
    var showStatus: () -> Void
    var selectSection: (Int) -> Void
    var setViewMode: (Int) -> Void
    var adjustZoom: (Double) -> Void
    var resetZoom: () -> Void
    var refresh: () -> Void
    var goBack: () -> Void
    var upload: () -> Void
    var download: () -> Void
    var newFolder: () -> Void
    var trash: () -> Void
    var isFileWorkspace: Bool { section == 0 || section == 3 }
}

private struct FinderWindowActionsKey: FocusedValueKey {
    typealias Value = FinderWindowActions
}

extension FocusedValues {
    var finderWindowActions: FinderWindowActions? {
        get { self[FinderWindowActionsKey.self] }
        set { self[FinderWindowActionsKey.self] = newValue }
    }
}

struct FinderCommands: Commands {
    @FocusedValue(\.finderWindowActions) private var actions
    @ObservedObject var settings: FinderSettings
    @StateObject private var undoFocus = FinderUndoCommandFocus()

    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            Button(undoFocus.editor != nil ? undoFocus.editor?.undoManager?.undoMenuItemTitle ?? "Undo" : actions?.undoTitle ?? "Undo") {
                if let editor = undoFocus.editor { editor.undoManager?.undo() }
                else if undoFocus.allowsFileActions { actions?.undo() }
            }
            .keyboardShortcut("z", modifiers: .command)
            .disabled(undoFocus.editor != nil ? undoFocus.editor?.undoManager?.canUndo != true
                      : !undoFocus.allowsFileActions || actions?.canUndo != true)
            Button(undoFocus.editor != nil ? undoFocus.editor?.undoManager?.redoMenuItemTitle ?? "Redo" : actions?.redoTitle ?? "Redo") {
                if let editor = undoFocus.editor { editor.undoManager?.redo() }
                else if undoFocus.allowsFileActions { actions?.redo() }
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(undoFocus.editor != nil ? undoFocus.editor?.undoManager?.canRedo != true
                      : !undoFocus.allowsFileActions || actions?.canRedo != true)
        }
        CommandGroup(replacing: .newItem) {
            Button("New Folder…") { actions?.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(actions?.canCreateFolder != true)
            Button("Upload Files or Folders…") { actions?.upload() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(actions?.canUpload != true)
            Button("Add Selected Items to Download Queue") { actions?.download() }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(actions?.canDownload != true)
            Button("Move Selected Items to Trash") { actions?.trash() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(actions?.canTrash != true)
            Divider()
            Button("Check for Duplicates") { actions?.checkDuplicates() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(actions?.canCheckDuplicates != true)
            Button("Review Duplicate Results…") { actions?.reviewDuplicates() }
                .disabled(actions?.canReviewDuplicates != true)
            Button("Remove Empty Folders…") { actions?.removeEmptyFolders() }
                .disabled(actions?.canRemoveEmptyFolders != true)
            Button("Remove .DS_Store Files…") { actions?.removeDSStoreFiles() }
                .disabled(actions?.canRemoveDSStoreFiles != true)
            Button("Merge Selected Folders…") { actions?.mergeFolders() }
                .disabled(actions?.canMergeFolders != true)
            Divider()
            Button("Show Status") { actions?.showStatus() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(actions == nil)
        }
        CommandGroup(after: .appSettings) {
            Button("Refresh") { actions?.refresh() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(actions?.canRefresh != true)
        }
        CommandGroup(before: .toolbar) {
            Picker("Display", selection: Binding(get: { actions?.viewMode ?? 0 }, set: { actions?.setViewMode($0) })) {
                Text("as List").tag(0).keyboardShortcut("1", modifiers: .command)
                Text("as Thumbnails").tag(1).keyboardShortcut("2", modifiers: .command)
            }
            .pickerStyle(.inline)
            .disabled(actions?.isFileWorkspace != true)
            Divider()
            Button("Make Items Larger") { actions?.adjustZoom(0.15) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(actions?.isFileWorkspace != true || (actions?.zoom ?? 1) >= 1.8)
            Button("Make Items Smaller") { actions?.adjustZoom(-0.15) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(actions?.isFileWorkspace != true || (actions?.zoom ?? 1) <= 0.75)
            Button("Actual Size") { actions?.resetZoom() }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(actions?.isFileWorkspace != true)
            Divider()
            Button(settings.showsPreviewPane ? "Hide Preview" : "Show Preview") {
                settings.showsPreviewPane.toggle()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            Button(settings.autoHideSidebar ? "Show Sidebar" : "Automatically Hide Sidebar") {
                settings.autoHideSidebar.toggle()
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            Divider()
        }
        CommandMenu("Go") {
            Button("Back") { actions?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(actions?.canGoBack != true)
            Divider()
            ForEach(FinderWorkspaceSection.allCases) { section in
                Button(section.title) { actions?.selectSection(section.rawValue) }
                    .keyboardShortcut(KeyEquivalent(Character(String(section.shortcut))), modifiers: [.command, .control])
                    .disabled(actions == nil)
            }
        }
    }
}

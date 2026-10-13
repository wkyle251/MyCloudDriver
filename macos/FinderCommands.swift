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
    var findSimilarFiles: () -> Void
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
    var containerTitle = "New Folder…"
    var importTitle = "Upload Files or Folders…"
    var exportTitle = "Add Selected Items to Download Queue"
    var trashTitle = "Move Selected Items to Trash"
    var emptyTitle = "Remove Empty Folders…"
    var mergeTitle = "Merge Selected Folders…"
    var supportsPikPakManagement = false
    var supportsDiskTrash = false
    var workspaceSections: [FinderWorkspaceSection] {
        supportsPikPakManagement ? FinderWorkspaceSection.allCases
            : supportsDiskTrash ? FinderWorkspaceSection.standard + [.trash] : FinderWorkspaceSection.standard
    }
    var canToggleFolder = false
    var toggleFolderTitle = "Expand or Collapse Folder"
    var toggleFolder: () -> Void = {}
    var isFileWorkspace: Bool { section == 0 || section == 3 || section == FinderWorkspaceSection.bookmarks.rawValue }
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

/// Observe drive/login changes as well as window focus. Reading these through
/// App's session manager alone leaves shortcuts disabled after Home → drive.
struct FinderSearchCommands: Commands {
    @ObservedObject private var sessions: WorkspaceSessionManager
    @ObservedObject private var hub: CloudDriveHub
    @ObservedObject private var model: DownloaderModel
    @ObservedObject private var similarity: FileSimilarityCoordinator

    init(sessions: WorkspaceSessionManager) {
        self.sessions = sessions
        hub = sessions.activeHub
        model = sessions.activeHub.pikpak
        similarity = sessions.activeHub.pikpak.fileSimilarity
    }

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button(sessions.searchDrive == .pikpak ? "Find in Expanded Items…" : "Find in This Drive…") {
                sessions.presentSearch(scope: .expanded)
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(sessions.searchDrive == nil || model.isLoginPresented)
            Button("Find from PikPak Root…") { sessions.presentSearch(scope: .root) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(sessions.searchDrive != .pikpak || model.isLoginPresented)
        }
    }
}

struct FinderCommands: Commands {
    @FocusedValue(\.finderWindowActions) private var focusedActions
    @ObservedObject private var router = FinderCommandRouter.shared
    private var actions: FinderWindowActions? { WorkspaceSessionManager.current == nil ? focusedActions : router.actions }
    @ObservedObject var settings: FinderSettings
    var sessions: WorkspaceSessionManager? = nil
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
            if let sessions {
                Button("New Window") { sessions.newWindow() }
                    .keyboardShortcut("n", modifiers: .command)
                Divider()
            }
            Button(actions?.containerTitle ?? "New Folder…") { actions?.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(actions?.canCreateFolder != true)
            Button(actions?.importTitle ?? "Import Files or Folders…") { actions?.upload() }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(actions?.canUpload != true)
            Button(actions?.exportTitle ?? "Export Selected Items…") { actions?.download() }
                .keyboardShortcut("d", modifiers: [.command, .option])
                .disabled(actions?.canDownload != true)
            Button(actions?.trashTitle ?? "Move Selected Items to Trash") { actions?.trash() }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(actions?.canTrash != true)
            Divider()
            Button("Find Similar Files…") {
                if let actions { actions.findSimilarFiles() }
                else { sessions?.presentSimilarity() }
            }
                .disabled(actions == nil && sessions?.canPresentSimilarity != true)
            Button("Check Duplicates Across Drives…") { sessions?.activeHub.presentCrossDriveDuplicates() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(sessions?.activeHub.pikpak.canCheckCrossDriveDuplicates != true)
            Button(actions?.emptyTitle ?? "Remove Empty Folders…") { actions?.removeEmptyFolders() }
                .disabled(actions?.canRemoveEmptyFolders != true)
            Button("Remove .DS_Store Files…") { actions?.removeDSStoreFiles() }
                .disabled(actions?.canRemoveDSStoreFiles != true)
            Button(actions?.mergeTitle ?? "Merge Selected Folders…") { actions?.mergeFolders() }
                .disabled(actions?.canMergeFolders != true)
            Divider()
            Button("Show Transfers") { actions?.selectSection(1) }
                .keyboardShortcut("t", modifiers: [.command, .shift]).disabled(actions == nil)
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
            Button(actions?.toggleFolderTitle ?? "Expand or Collapse Folder") {
                if undoFocus.allowsFileActions { actions?.toggleFolder() }
            }
            .keyboardShortcut(.return, modifiers: [.command, .option])
            .disabled(!undoFocus.allowsFileActions || actions?.canToggleFolder != true)
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
            Button("All Drives") { NotificationCenter.default.post(name: .init("MyCloudDriverAllDrives"), object: sessions?.activeHub) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Divider()
            Button("Back") { actions?.goBack() }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(actions?.canGoBack != true)
            Divider()
            ForEach(actions?.workspaceSections ?? FinderWorkspaceSection.standard) { section in
                Button(section.title) { actions?.selectSection(section.rawValue) }
                    .keyboardShortcut(KeyEquivalent(Character(String(section.shortcut))), modifiers: [.command, .control])
                    .disabled(actions == nil)
            }
        }
    }
}

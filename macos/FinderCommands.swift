import SwiftUI
import Combine

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
    struct Presentation: Equatable {
        let section: Int
        let viewMode: Int
        let zoom: Double
        let titles: [String]
        let availability: [Bool]
    }
    var presentation: Presentation {
        .init(section: section, viewMode: viewMode, zoom: zoom,
            titles: [undoTitle, redoTitle, containerTitle, importTitle, exportTitle, trashTitle,
                     emptyTitle, mergeTitle, toggleFolderTitle],
            availability: [canUndo, canRedo, canRefresh, canGoBack, canUpload, canDownload,
                canCreateFolder, canTrash, canCheckDuplicates, canReviewDuplicates,
                canRemoveEmptyFolders, canRemoveDSStoreFiles, canMergeFolders,
                supportsPikPakManagement, supportsDiskTrash, canToggleFolder])
    }
}

/// Project command validation out of high-frequency transfer/preview models.
/// Unrelated model updates must not invalidate an open View submenu.
@MainActor final class FinderSearchCommandState: ObservableObject {
    struct Snapshot: Equatable {
        let drive: CloudDriveKind?
        let isLoginPresented: Bool
    }
    @Published private(set) var snapshot: Snapshot
    private let sessions: WorkspaceSessionManager
    private var sessionObservation: AnyCancellable?
    private var focusObservation: AnyCancellable?
    private var hubObservations: [AnyCancellable] = []
    private weak var observedHub: CloudDriveHub?
    private lazy var publication = FinderCommandPublication { [weak self] in self?.refresh() }

    init(sessions: WorkspaceSessionManager) {
        self.sessions = sessions
        snapshot = .init(drive: sessions.searchDrive, isLoginPresented: sessions.activeHub.pikpak.isLoginPresented)
        _ = publication
        sessionObservation = sessions.objectWillChange.sink { [weak self] in self?.publication.request() }
        focusObservation = NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)
            .sink { [weak self] _ in self?.publication.request() }
        observeHub()
    }
    private func observeHub() {
        let hub = sessions.activeHub
        observedHub = hub
        hubObservations = [hub.objectWillChange, hub.pikpak.objectWillChange, hub.pikpak.fileSimilarity.objectWillChange]
            .map { publisher in publisher.sink { [weak self] in self?.publication.request() } }
    }
    private func refresh() {
        if observedHub !== sessions.activeHub { observeHub() }
        let next = Snapshot(drive: sessions.searchDrive, isLoginPresented: sessions.activeHub.pikpak.isLoginPresented)
        if snapshot != next { snapshot = next }
    }
}

struct FinderSearchCommands: Commands {
    private let sessions: WorkspaceSessionManager
    @StateObject private var state: FinderSearchCommandState

    init(sessions: WorkspaceSessionManager) {
        self.sessions = sessions
        _state = StateObject(wrappedValue: FinderSearchCommandState(sessions: sessions))
    }

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button(state.snapshot.drive == .photos ? "Find in This Drive…" : "Find in Expanded Items…") {
                sessions.presentSearch(scope: .expanded)
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(state.snapshot.drive == nil || state.snapshot.isLoginPresented)
            Button("Find from \(state.snapshot.drive?.title ?? "Drive") Root…") { sessions.presentSearch(scope: .root) }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(state.snapshot.drive == nil || state.snapshot.drive == .photos || state.snapshot.isLoginPresented)
        }
    }
}

struct FinderCommands: Commands {
    @ObservedObject private var router = FinderCommandRouter.shared
    private var actions: FinderWindowActions? { router.actions }
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
            Button("Find Similarity Across Drives…") {
                if let sessions { sessions.activeHub.presentAcrossDriveSimilarity() }
                else { actions?.findSimilarFiles() }
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
            Picker("Preview Placement", selection: $settings.previewPlacement) {
                ForEach(FinderPreviewPlacement.allCases) { Text($0.title).tag($0) }
            }.pickerStyle(.menu)
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

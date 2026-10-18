import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NativeDriveWorkspace: View {
    @ObservedObject var model: NativeDriveModel
    @ObservedObject var hub: CloudDriveHub
    @ObservedObject var settings: FinderSettings
    @ObservedObject private var navigation: FinderWorkspaceNavigation
    @ObservedObject private var sharedBookmarks = FinderBookmarkStore.shared
    @Environment(\.finderBookmarkStore) private var injectedBookmarks
    private var bookmarks: FinderBookmarkStore { injectedBookmarks ?? sharedBookmarks }
    @AppStorage("browserViewMode") private var browserViewMode = 0
    @AppStorage("browserListItemZoom") private var listZoom = 1.0
    @AppStorage("browserThumbnailItemZoom") private var thumbnailZoom = 1.0
    @AppStorage("selectedTransferMode") private var transferDirection = 0
    @State private var showsSearch = false
    @State private var previewExpanded = false
    @State private var bookmarkBrowserIsOpen = false
    @AppStorage("bookmarkViewMode") private var bookmarkViewMode = 0
    @AppStorage("bookmarkItemZoom") private var bookmarkZoom = 1.0

    init(model: NativeDriveModel, hub: CloudDriveHub, settings: FinderSettings) {
        self.model = model; self.hub = hub; self.settings = settings
        self.navigation = hub.pikpakNavigation
    }
    private var zoom: Double { browserViewMode == 1 ? thumbnailZoom : listZoom }
    private func setZoom(_ value: Double) {
        let value = min(1.8, max(0.75, value))
        if browserViewMode == 1 { thumbnailZoom = value } else { listZoom = value }
        model.zoom = value
    }
    private func selectSection(_ section: Int) {
        if section == FinderWorkspaceSection.bookmarks.rawValue { bookmarkBrowserIsOpen = false }
        navigation.showImmediately(section)
        model.section = navigation.section
    }

    @State private var prompt: NativeNamePrompt?
    @State private var pendingDelete: [CloudDriveItem] = []
    @State private var showsDelete = false
    @State private var showsStatus = false
    @State private var albumDestination: NativeAlbumDestination?
    @State private var dropTarget = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        FinderSidebarLayout(automaticallyHidden: settings.autoHideSidebar) {
            sidebar
        } workspace: {
            FinderWorkspaceBody {
                switch navigation.section {
                case FinderWorkspaceSection.trash.rawValue where model.usesDiskTrash:
                    NativeDiskTrashView(model: model)
                case 1:
                    NativeDriveTransfers(model: model, store: model.activity, direction: $transferDirection,
                        showBrowser: { selectSection(0) }, showStatus: { showsStatus = true }, pikpak: hub.pikpak)
                case FinderWorkspaceSection.bookmarks.rawValue:
                    if bookmarkBrowserIsOpen {
                        VStack(spacing: 10) {
                            HStack {
                                Button { bookmarkBrowserIsOpen = false; model.closePreview(); model.mediaPreview.clear() } label: {
                                    Label("Bookmarks", systemImage: "chevron.left")
                                }.help("Back to bookmarked files and folders")
                                Spacer()
                            }
                            browser
                        }
                    } else { FinderBookmarksWorkspace(store: bookmarks, provider: model.kind.rawValue, scope: model.bookmarkScope,
                        sourceTitle: model.kind.title, canOpen: model.isConnected && !model.isMutating,
                        open: { bookmark in
                            if model.openBookmark(bookmark, store: bookmarks) { bookmarkBrowserIsOpen = true }
                        }, showBrowser: { selectSection(0) }) }
                default:
                    browser
                }
            } footer: {
                NativeDriveFooter(model: model, store: model.activity, scan: model.similarity.local,
                    section: navigation.section, bookmarkCount: bookmarkBrowserIsOpen ? nil : bookmarks.items(provider: model.kind.rawValue, scope: model.bookmarkScope).count, showsStatus: $showsStatus)
            }
        }
        .focusedSceneValue(\.finderWindowActions, actions)
        .background(FinderWindowActionRegistration(actions: actions))
        .overlay { FileSearchOverlay(search: model.fileSearch, onReveal: model.revealFileSearch) }
        .onChange(of: model.query) { _ in if model.kind == .photos { model.reload() } }
        .onChange(of: model.selection) { _ in
            if model.selection.isEmpty { previewExpanded = false }
        }
        .onChange(of: model.inspectorPreviewIdentity) { _ in model.selectionChanged() }
        .onAppear {
            model.section = navigation.section; model.viewMode = browserViewMode; model.zoom = zoom
            model.setThumbnailPrefetchActive(navigation.section == 0 || (navigation.section == 7 && bookmarkBrowserIsOpen))
        }
        .onChange(of: navigation.section) { value in
            model.section = value
            let browsing = value == 0 || (value == 7 && bookmarkBrowserIsOpen)
            model.setThumbnailPrefetchActive(browsing)
            if !browsing { model.closePreview(); model.mediaPreview.clear() }
        }
        .onChange(of: bookmarkBrowserIsOpen) { open in model.setThumbnailPrefetchActive(navigation.section == 0 || (navigation.section == 7 && open)) }
        .onChange(of: model.bookmarkScope) { _ in bookmarkBrowserIsOpen = false }
        .onChange(of: model.section) { value in
            if navigation.section != value { navigation.showImmediately(value) }
        }
        .onChange(of: settings.showsPreviewPane) { if !$0 { model.mediaPreview.clear() } }
        .onChange(of: model.isBusy) { busy in
            if !busy && model.kind == .icloud && model.isConnected { hub.icloudStorage.refresh(force: true) }
            if !busy && model.kind == .local && model.isConnected { hub.localStorage.refresh(for: model.provider?.root.url) }
        }
        .onChange(of: browserViewMode) { model.viewMode = $0; model.zoom = zoom }
        .onChange(of: listZoom) { _ in model.zoom = zoom }
        .onChange(of: thumbnailZoom) { _ in model.zoom = zoom }
        .onChange(of: settings.layoutResetRevision) { _ in previewExpanded = false }
        .onReceive(NotificationCenter.default.publisher(for: .init("MyCloudDriverFind"))) { note in
            guard let target = note.object as? CloudDriveHub, target === hub else { return }
            selectSection(0)
            if !model.presentFileSearch() { showsSearch = true; searchFocused = true }
        }
        .onDisappear { model.fileSearch.close(); model.closePreview(); model.mediaPreview.clear(); model.setThumbnailPrefetchActive(false) }
        .sheet(item: $prompt) { prompt in
            NativeNameSheet(prompt: prompt) { name in
                if let item = prompt.item { model.rename(item, name: name) }
                else { model.newContainer(name) }
            }
        }
        .sheet(item: $albumDestination) { request in
            NativeAlbumPicker(model: model, request: request)
        }
        .confirmationDialog(model.kind == .photos ? "Delete from Apple Photos?" : "Move to Trash?", isPresented: $showsDelete, titleVisibility: .visible) {
            Button(model.kind == .photos ? "Delete from Photos" : "Move to Trash", role: .destructive) { model.delete(pendingDelete); pendingDelete = [] }
            Button("Cancel", role: .cancel) { pendingDelete = [] }
        } message: {
            Text(model.kind == .photos
                 ? "Delete \(pendingDelete.count) selected item(s)? Deleting an album keeps its media in the library. Deleted photos and videos can be restored in Photos → Recently Deleted."
                 : model.usesDiskTrash
                    ? "Move \(pendingDelete.count) selected item(s) to the Trash folder on this disk? Use Put Back in the Trash tab or Command-Z to restore them."
                    : "Move \(pendingDelete.count) selected item(s) to Finder’s Trash? \(model.kind == .icloud ? "This change will sync to iCloud. " : "")You can undo it with Command-Z.")
        }
        .alert("\(model.kind.title)", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private var sidebar: some View {
        FinderDriveSidebar(navigation: navigation, settings: settings,
            accountSubtitle: model.kind == .local ? hub.selectedDriveTitle : model.kind.title, accountPane: 3,
            sections: model.workspaceSections, select: selectSection) {
            if model.kind == .icloud {
                FinderICloudStorage(storage: hub.icloudStorage, connected: model.isConnected)
            } else if model.kind == .local {
                FinderLocalStorage(storage: hub.localStorage, rootURL: model.provider?.root.url, connected: model.isConnected,
                    message: model.availabilityMessage, busy: model.isBusy) { hub.connectLocal() }
            } else { VStack(alignment: .leading, spacing: 6) {
                Text("Storage").font(.caption.weight(.semibold))
                Text("Managed by Apple Photos").font(.caption2).foregroundStyle(.secondary)
                Text(model.availabilityMessage ?? (model.isConnected ? "Available" : "Connect to get started"))
                    .font(.caption2).foregroundStyle(.secondary)
            }.padding(12) }
        }
    }
    private var connection: some View {
        VStack(spacing: 14) {
            FinderDriveConnection(kind: model.kind, busy: model.kind == .photos && hub.connectingPhotos) {
                if model.kind == .photos { hub.connectPhotos() } else if model.kind == .local { hub.connectLocal() } else { hub.connectICloud() }
            }
            if let message = model.availabilityMessage {
                Text(message).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Check Again") { model.refreshAvailability() }
            }
            if model.kind == .photos {
                PhotosConnectionFeedbackView(hub: hub)
                if hub.photosFeedback?.isError == true {
                    Button("Photos Privacy Settings…", action: openPhotosPrivacySettings)
                }
            }
        }
    }
    private var browser: some View {
        VStack(spacing: 12) {
            toolbar
            if !model.isConnected { connection }
            else {
                FinderBrowserSplit(showsPreview: settings.showsPreviewPane,
                    expanded: previewExpanded && !model.selection.isEmpty,
                    resetRevision: settings.layoutResetRevision) {
                VStack(spacing: 0) {
                    if model.fileTypeFilter.isActive {
                        BrowserFileFilterBar(filter: $model.fileTypeFilter, count: model.visibleFileCount, hiddenFolders: model.visibleHiddenFolderCount)
                        Divider()
                    }
                    if model.viewMode == 0 { table }
                    else if model.visibleRows.isEmpty { emptyState }
                    else { thumbnails }
                    if model.nextOffset != nil {
                        HStack {
                            Text(model.query.isEmpty ? "\(model.items.count.formatted()) of \(model.total.formatted()) items loaded"
                                 : "\(model.items.count.formatted()) matching items loaded").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Load More") { model.reload(append: true) }.disabled(model.isLoading)
                        }.padding(10)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(alignment: .topTrailing) {
                    if model.isLoading && !model.items.isEmpty {
                        ProgressView("Updating…").controlSize(.small).padding(10).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)).padding(10)
                    }
                }
                } preview: {
                    NativeDriveInspector(model: model, mediaPreview: model.mediaPreview,
                        expanded: $previewExpanded, resetRevision: settings.layoutResetRevision)
                }
            .background(NativeDriveKeys(model: model))
            .onDrop(of: [.fileURL], isTargeted: $dropTarget) { providers in
                guard !model.isMutating else { return false }
                let destination = model.location, rootID = model.provider?.root.id
                LocalUploadFileURLLoader.loadResult(providers) { result in
                    Task { @MainActor in
                        guard model.provider?.root.id == rootID else { model.error = "The connected folder changed. Drop the files again."; return }
                        switch result { case .success(let urls): model.importFiles(urls, into: destination)
                        case .failure(let error): model.error = error.localizedDescription }
                    }
                }
                return true
            }
            .overlay {
                if dropTarget {
                    RoundedRectangle(cornerRadius: 10).strokeBorder(FinderAppearance.accent, lineWidth: 3)
                        .background(FinderAppearance.accent.opacity(0.07))
                        .overlay { Label("Release to import into \(model.location.title)", systemImage: "square.and.arrow.down")
                            .font(.headline).padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
                        .allowsHitTesting(false)
                }
            }
            }
        }
    }
    private var toolbar: some View {
        FinderBrowserToolbar(viewMode: $browserViewMode, zoom: zoom,
            connected: model.isConnected, canGoBack: model.history.count > 1,
            canImport: model.isConnected && !model.isMutating,
            canExport: model.isConnected && !model.selection.isEmpty,
            canTrash: model.isConnected && !model.isMutating && !model.selection.isEmpty && model.selectedItems.allSatisfy(\.canDelete),
            canCreate: model.isConnected && !model.isMutating,
            merge: { model.reviewMerge(model.selectedItems) }, canMerge: actions.canMergeFolders,
            containerName: model.kind.containerName,
            importHelp: model.kind == .photos ? "Import images or videos into this album or library" : "Copy files or folders into this \(model.kind.title) location",
            exportHelp: "Export selected originals to a folder on this Mac",
            trashHelp: model.kind == .photos ? "Delete selected items from Photos" : model.usesDiskTrash ? "Move selected items to this disk’s Trash" : "Move selected items to Finder’s Trash",
            fileTypeFilter: $model.fileTypeFilter, fileExtensions: model.availableFileExtensions,
            hidesEmptyFolders: $model.hidesEmptyFolders,
            back: { model.back() }, search: {
                if !model.presentFileSearch() { showsSearch = true; searchFocused = true }
            },
            importFiles: { transferDirection = 1; model.chooseImport() },
            exportFiles: { transferDirection = 0; model.chooseExport(model.selectedItems) },
            trash: { requestDelete(model.selectedItems) }, create: newContainer,
            refresh: { model.reload() }, adjustZoom: { setZoom(zoom + $0) }, resetZoom: { setZoom(1) },
            sort: model.toggleSort) {
                Menu {
                    ForEach(model.history) { location in
                        Button(location.title) { model.navigate(to: location) }
                    }
                } label: { Text(model.location.title).font(.callout).lineLimit(1).truncationMode(.middle) }
                    .menuStyle(.borderlessButton).disabled(!model.isConnected)
                    .help(model.location.url?.path ?? model.location.title)
            }
            .popover(isPresented: $showsSearch, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Find in \(model.location.title)").font(.headline)
                    TextField("Search files and folders", text: $model.query)
                        .textFieldStyle(.roundedBorder).focused($searchFocused)
                    HStack { Button("Clear") { model.query = "" }; Spacer(); Button("Done") { showsSearch = false } }
                }.padding(16).frame(width: 320)
            }
            .onReceive(NotificationCenter.default.publisher(for: FinderPopover.dismissAllNotification)) { _ in showsSearch = false }
    }
    private var table: some View {
        NativeDriveFileList(model: model, resetRevision: settings.layoutResetRevision, menu: contextMenu,
            nativeFileMenu: nativeFileMenu, empty: { emptyState })
    }
    private var thumbnails: some View {
        NativeDriveFileGrid(model: model, menu: contextMenu, nativeFileMenu: nativeFileMenu)
    }
    private var emptyState: some View {
        VStack(spacing: 14) {
            if model.isLoading { ProgressView("Loading \(model.location.title)…") }
            else if model.fileTypeFilter.isActive {
                BrowserFileFilterEmptyState(filter: $model.fileTypeFilter, hasMore: model.nextOffset != nil)
            }
            else if model.visibleHiddenFolderCount > 0 {
                BrowserEmptyFoldersEmptyState(hidesEmptyFolders: $model.hidesEmptyFolders)
            }
            else {
                Image(systemName: model.query.isEmpty ? "folder" : "magnifyingglass").font(.system(size: 38)).foregroundStyle(.tertiary)
                Text(model.query.isEmpty ? "This \(model.kind.containerName.lowercased()) is empty" : "No matching items").font(.headline)
                Text(model.query.isEmpty ? "Import files or create a \(model.kind.containerName.lowercased()) to get started." : "Try a different filename.").foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    @ViewBuilder private func contextMenu(_ selected: [CloudDriveItem]) -> some View {
        if let first = selected.first {
            let removingBookmarks = selected.allSatisfy { bookmarks.contains(provider: model.kind.rawValue, scope: model.bookmarkScope, itemID: $0.id) }
            Button(removingBookmarks ? "Remove from Bookmarks" : "Add to Bookmarks") {
                model.toggleBookmarks(selected, store: bookmarks)
            }.disabled(model.bookmarkScope == nil)
            Divider()
            if selected.count == 1 {
                if first.isFolder {
                    if browserViewMode == 0 {
                        Button(model.isExpanded(first) ? "Collapse \(model.kind.containerName)" : "Expand \(model.kind.containerName)") { model.toggleExpansion(first) }
                        expandAllLevelsEntry([first])
                    }
                    Button("Open \(model.kind.containerName)") { model.enter(first) }
                }
                else {
                    FinderFileOpenMenu(item: first.browserItem, enabled: true, open: { model.open(first, application: $0) },
                        chooseApplication: { FinderFileApplications.chooseApplication(for: first.name) { model.open(first, application: $0) } })
                    Button("Quick Look") { model.selection = [first.id]; model.togglePreview(in: NSApp.keyWindow) }
                }
                Button("Rename…") { prompt = .init(title: "Rename \(model.kind.containerName.lowercased())", name: first.name, item: first) }
                    .disabled(!first.canRename || model.isMutating)
            } else {
                expandAllLevelsEntry(selected.filter(\.isFolder))
            }
            Divider()
            Button("Export \(selected.count == 1 ? "Item" : "\(selected.count) Items")…") { model.chooseExport(selected) }
            if model.kind == .local {
                Button("Upload to PikPak") { model.sendToPikPak(selected) }
                    .disabled(!model.isConnected || !hub.pikpak.canUploadFiles)
                    .help("Upload to \(hub.pikpak.effectiveUploadDestination.path)")
            }
            Button(model.kind == .photos ? "Add to Album…" : "Copy to Folder…") { chooseDestination(selected, copy: true) }
                .disabled(model.isMutating || (model.kind == .photos && selected.contains(where: \.isFolder)))
            Button(model.kind == .photos ? "Move to Album…" : "Move to Folder…") { chooseDestination(selected, copy: false) }
                .disabled(model.isMutating || (model.kind == .photos && (!model.location.id.hasPrefix("album:") || selected.contains(where: \.isFolder))))
            if selected.contains(where: \.isFolder) {
                Button("Merge Selected \(model.kind == .photos ? "Albums" : "Folders")…") { model.reviewMerge(selected) }
                    .disabled(model.isMutating || selected.count < 2 || !selected.allSatisfy(\.isFolder))
            }
            Divider()
            Button("Find Similar Files…") { model.findSimilar(selected) }
            Button("Check for Duplicates…") { model.findSimilar(selected, exactOnly: true) }
            Button(model.kind == .photos ? "Calculate Original Size" : "Recalculate Folder Size") { model.measure(selected) }
            if selected.count == 1, let file = selected.first, model.kind != .photos, file.browserItem.isCloudExtractableArchive {
                Button("Extract Archive…") { model.extract(file) }
            }
            Divider()
            Button(model.kind == .photos ? "Delete from Photos…" : "Move to Trash…", role: .destructive) { requestDelete(selected) }
                .disabled(model.isMutating || !selected.allSatisfy(\.canDelete))
        } else {
            Button("New \(model.kind.containerName)…") { newContainer() }.disabled(model.isMutating)
            Button("Import…") { model.chooseImport() }.disabled(model.isMutating)
            Button("Find Similar Files…") { model.findSimilar() }
        }
    }
    private func nativeFileMenu(_ item: CloudDriveItem) -> NSMenu {
        let menu = BrowserNativeMenu(title: "File actions")
        let selected = [item]
        menu.addAction(bookmarks.contains(provider: model.kind.rawValue, scope: model.bookmarkScope, itemID: item.id)
            ? "Remove from Bookmarks" : "Add to Bookmarks", symbol: "bookmark", enabled: model.bookmarkScope != nil) {
            model.toggleBookmarks(selected, store: bookmarks)
        }
        menu.addItem(.separator())
        FinderFileApplications.addOpenActions(to: menu, item: item.browserItem, enabled: !model.isMutating,
            open: { model.open(item, application: $0) },
            chooseApplication: { FinderFileApplications.chooseApplication(for: item.name) { model.open(item, application: $0) } })
        menu.addAction("Quick Look", symbol: "eye") { model.selection = [item.id]; model.togglePreview(in: NSApp.keyWindow) }
        menu.addAction("Rename…", symbol: "pencil", enabled: item.canRename && !model.isMutating) {
            prompt = .init(title: "Rename \(model.kind.containerName.lowercased())", name: item.name, item: item)
        }
        menu.addItem(.separator())
        menu.addAction("Export Item…") { model.chooseExport(selected) }
        if model.kind == .local {
            menu.addAction("Upload to PikPak", enabled: model.isConnected && hub.pikpak.canUploadFiles) { model.sendToPikPak(selected) }
        }
        menu.addAction(model.kind == .photos ? "Add to Album…" : "Copy to Folder…", enabled: !model.isMutating) {
            chooseDestination(selected, copy: true)
        }
        menu.addAction(model.kind == .photos ? "Move to Album…" : "Move to Folder…",
            enabled: !model.isMutating && (model.kind != .photos || model.location.id.hasPrefix("album:"))) {
            chooseDestination(selected, copy: false)
        }
        menu.addItem(.separator())
        menu.addAction("Find Similar Files…") { model.findSimilar(selected) }
        menu.addAction("Check for Duplicates…") { model.findSimilar(selected, exactOnly: true) }
        menu.addAction(model.kind == .photos ? "Calculate Original Size" : "Recalculate Folder Size") { model.measure(selected) }
        if model.kind != .photos, item.browserItem.isCloudExtractableArchive {
            menu.addAction("Extract Archive…") { model.extract(item) }
        }
        menu.addItem(.separator())
        menu.addAction(model.kind == .photos ? "Delete from Photos…" : "Move to Trash…", symbol: "trash",
            enabled: !model.isMutating && item.canDelete) { requestDelete(selected) }
        return menu
    }

    /// Local Disk, external disks and network shares are one model, so they share this entry. Over a
    /// selection it opens every selected folder; files in the selection are left alone.
    @ViewBuilder private func expandAllLevelsEntry(_ folders: [CloudDriveItem]) -> some View {
        if model.kind == .local, browserViewMode == 0, !folders.isEmpty {
            if model.isExpandingAllLevels(folders) {
                Button("Stop Expanding All Levels") { model.stopExpandingAllLevels() }
            } else {
                Button(BrowserFolderExpansionAction.title(folderCount: folders.count)) { model.expandAllLevels(folders) }
                    .disabled(!model.canExpandAllLevels || model.isMutating)
                    .help(folders.count > 1 ? "Expand every selected folder and all of their nested subfolders."
                                            : "Expand this folder and every nested subfolder.")
            }
        }
    }
    private func newContainer() { prompt = .init(title: "New \(model.kind.containerName)", name: "", item: nil) }
    private func requestDelete(_ items: [CloudDriveItem]) { pendingDelete = items; showsDelete = !items.isEmpty }
    private func chooseDestination(_ items: [CloudDriveItem], copy: Bool) {
        if model.kind == .photos { albumDestination = .init(items: items, source: model.location, copy: copy); return }
        let source = model.location
        let panel = NSOpenPanel(); panel.title = copy ? "Copy to Folder" : "Move to Folder"; panel.prompt = "Choose"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.directoryURL = model.provider?.root.url
        panel.message = "Choose a destination inside the connected \(model.kind.title) folder."
        panel.begin { result in
            if result == .OK, let url = panel.url { model.relocate(items, from: source, to: .init(id: url.absoluteString, title: url.lastPathComponent, url: url), copy: copy) }
        }
    }
    private var actions: FinderWindowActions {
        let isBookmarkRoot = navigation.section == 7 && !bookmarkBrowserIsOpen
        let selected = model.selectedItems, connected = model.isConnected && (navigation.section == 0 || (navigation.section == 7 && bookmarkBrowserIsOpen)), available = connected && !model.isMutating
        return .init(section: navigation.section, viewMode: isBookmarkRoot ? bookmarkViewMode : browserViewMode, zoom: isBookmarkRoot ? bookmarkZoom : zoom,
            undoTitle: model.undoStack.last.map { "Undo \($0.title)" } ?? "Undo",
            redoTitle: model.redoStack.last.map { "Redo \($0.title)" } ?? "Redo",
            canUndo: model.isConnected && !model.isMutating && !model.undoStack.isEmpty,
            canRedo: model.isConnected && !model.isMutating && !model.redoStack.isEmpty,
            undo: { model.undo() }, redo: { model.undo(redo: true) },
            canRefresh: connected || (navigation.section == 6 && model.usesDiskTrash), canGoBack: connected && model.history.count > 1, canUpload: available,
            canDownload: connected && !selected.isEmpty, canCreateFolder: available,
            canTrash: available && !selected.isEmpty && selected.allSatisfy(\.canDelete),
            canCheckDuplicates: connected, canReviewDuplicates: model.similarity.local.report != nil,
            canRemoveEmptyFolders: available, canRemoveDSStoreFiles: available && model.kind != .photos,
            canMergeFolders: available && selected.count > 1 && selected.allSatisfy(\.isFolder),
            checkDuplicates: { model.findSimilar(exactOnly: true) }, findSimilarFiles: { model.findSimilar() },
            reviewDuplicates: { model.similarity.present(source: .local) },
            removeEmptyFolders: { model.reviewCleanup(empty: true) }, removeDSStoreFiles: { model.reviewCleanup(empty: false) },
            mergeFolders: { model.reviewMerge(selected) }, showStatus: { showsStatus = true },
            selectSection: selectSection, setViewMode: { if isBookmarkRoot { bookmarkViewMode = $0 } else { browserViewMode = $0 } },
            adjustZoom: { if isBookmarkRoot { bookmarkZoom = min(1.8, max(0.75, bookmarkZoom + $0)) } else { setZoom(zoom + $0) } },
            resetZoom: { if isBookmarkRoot { bookmarkZoom = 1 } else { setZoom(1) } },
            refresh: { if navigation.section == 6 && model.usesDiskTrash { model.refreshDiskTrash(prepare: true) } else { model.reload() } }, goBack: { model.back() }, upload: { model.chooseImport() },
            download: { model.chooseExport(selected) }, newFolder: newContainer, trash: { requestDelete(selected) },
            containerTitle: "New \(model.kind.containerName)…", importTitle: "Import Files or Folders…", exportTitle: "Export Selected Items…",
            trashTitle: model.kind == .photos ? "Delete Selected Items from Photos…" : "Move Selected Items to Trash",
            emptyTitle: "Remove Empty \(model.kind == .photos ? "Albums" : "Folders")…",
            mergeTitle: "Merge Selected \(model.kind == .photos ? "Albums" : "Folders")…",
            supportsDiskTrash: model.usesDiskTrash,
            canToggleFolder: connected && model.canToggleFocusedFolder,
            toggleFolderTitle: model.focusedFolderToggleTitle,
            toggleFolder: { model.toggleFocusedFolder() })
    }
}

private struct NativeNamePrompt: Identifiable {
    let id = UUID()
    let title: String
    var name: String
    let item: CloudDriveItem?
}
private struct NativeNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let prompt: NativeNamePrompt
    let submit: (String) -> Void
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(prompt.title).font(.headline)
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).onSubmit { save() }
            HStack { Spacer(); Button("Cancel", role: .cancel) { dismiss() }; Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled((try? CloudDriveFiles.validName(name)) == nil) }
        }.padding(24).frame(width: 390).onAppear { name = prompt.name }
    }
    private func save() { guard (try? CloudDriveFiles.validName(name)) != nil else { return }; submit(name); dismiss() }
}

private struct NativeAlbumDestination: Identifiable { let id = UUID(); let items: [CloudDriveItem]; let source: CloudDriveLocation; let copy: Bool }
private struct NativeAlbumPicker: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: NativeDriveModel
    let request: NativeAlbumDestination
    @State private var albums: [CloudDriveItem] = []
    @State private var selected: String?
    @State private var loading = true
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(request.copy ? "Add to Album" : "Move to Album").font(.headline)
            Text("Choose an album for \(request.items.count) selected item(s).").foregroundStyle(.secondary)
            if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if albums.isEmpty { Text(error ?? "Create an album in Browser first.").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else { List(albums, selection: $selected) { Label($0.name, systemImage: "rectangle.stack").tag($0.id) } }
            HStack {
                Spacer(); Button("Cancel", role: .cancel) { dismiss() }
                Button(request.copy ? "Add" : "Move") {
                    if let album = albums.first(where: { $0.id == selected }) { model.relocate(request.items, from: request.source, to: album.location, copy: request.copy); dismiss() }
                }.keyboardShortcut(.defaultAction).disabled(selected == nil)
            }
        }.padding(22).frame(width: 430, height: 420)
            .task {
                defer { loading = false }; guard let provider = model.provider else { return }
                do { albums = try await provider.list(provider.root, offset: 0, search: "").items.filter { $0.id.hasPrefix("album:") && $0.id != model.location.id } }
                catch { self.error = error.localizedDescription }
            }
    }
}

private struct NativeDriveInspector: View {
    @ObservedObject var model: NativeDriveModel
    @ObservedObject var mediaPreview: NativeMediaPreviewModel
    @Binding var expanded: Bool
    let resetRevision: Int
    var body: some View {
        if let item = model.inspectorItem {
            FinderPreviewPane(resetRevision: resetRevision,
                mediaPlayback: previewPlayback(for: item),
                onPreviewMove: { model.moveSelection($0) }) {
                HStack(spacing: 11) {
                    Image(systemName: item.symbol).font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(FinderAppearance.accent).frame(width: 38, height: 38)
                        .background(FinderAppearance.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name).font(.headline).lineLimit(2).help(item.name)
                        Text(item.isFolder ? model.kind.containerName : item.kindLabel).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Text(item.sizeLabel).font(.caption).foregroundStyle(.secondary)
                    if !item.isFolder {
                        Button { expanded.toggle() } label: {
                            Image(systemName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                                .frame(width: 24, height: 24)
                        }.buttonStyle(.borderless).help(expanded ? "Restore Split View" : "Expand Preview")
                    }
                }.padding(10).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
            } media: {
                if model.bookmarkRevealedItemID == item.id {
                    VStack(spacing: 12) {
                        Image(systemName: item.symbol).font(.system(size: 42)).foregroundStyle(.secondary)
                        Button("Show Preview") { model.showBookmarkPreview() }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !item.isFolder, item.mediaType == "video" || item.mediaType == "audio", let provider = model.provider {
                    NativeMediaPreview(item: item, provider: provider, model: model.mediaPreview, thumbnailCache: model.thumbnailCache)
                } else {
                    NativeMediaThumbnail(item: item, kind: model.kind, rootID: model.provider?.root.id, cache: model.thumbnailCache)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } details: {
                VStack(alignment: .leading, spacing: 12) {
                    if model.selection.count > 1 { Text("\(model.selection.count) items selected").font(.callout) }
                    LabeledContent("Kind", value: item.isFolder ? model.kind.containerName : item.kindLabel).font(.caption)
                    LabeledContent("Size", value: item.sizeLabel).font(.caption)
                    if let date = item.modified { LabeledContent("Date Modified", value: date.formatted()).font(.caption) }
                    HStack {
                        if item.isFolder { Button("Open \(model.kind.containerName)") { model.enter(item) } }
                        else {
                            Button("Quick Look") { model.togglePreview(in: NSApp.keyWindow) }.help("Preview · Space")
                            Button("Open") { model.open(item) }
                        }
                        Spacer()
                        Button("Download") { model.chooseExport(model.selectedItems) }.buttonStyle(.borderedProminent)
                    }
                }
            }
        } else { FinderPreviewEmptyState() }
    }
    private func previewPlayback(for item: CloudDriveItem) -> MediaPlaybackController? {
        guard item.mediaType == "video" || item.mediaType == "audio", let provider = model.provider,
              mediaPreview.matches(item, provider: provider) else { return nil }
        return mediaPreview.playback
    }
}

struct NativeDriveActivities: View {
    @ObservedObject var model: NativeDriveModel
    @ObservedObject var store: CloudDriveActivityStore
    @ObservedObject var scan: SimilarityScanModel
    var compact = false
    var close: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(compact ? "Status" : "Transfers & Activity").font(.headline)
                Spacer()
                if let close {
                    Button(action: close) { Image(systemName: "xmark") }.buttonStyle(.borderless)
                        .help("Close status details").accessibilityLabel("Close status details")
                } else { Text(model.kind.title).font(.caption).foregroundStyle(.secondary) }
            }
            if scan.isRunning || scan.isPaused || scan.report != nil || !scan.recoverableSessions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text("File similarity").fontWeight(.medium); Spacer(); Button("View…") { model.similarity.present(source: .local) } }
                    Text(scan.message).font(.callout)
                    if scan.isRunning { ProgressView(value: scan.progress.fraction) }
                    Text(scan.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    HStack {
                        Spacer()
                        if scan.isRunning {
                            if scan.canPause { Button("Pause") { scan.pause() } }
                            Button("Clear") { scan.clearSession() }.disabled(scan.isCancelling)
                            Button("Cancel Scan") { scan.cancel() }.disabled(scan.isCancelling)
                        }
                        else if scan.isPaused {
                            Button("Resume") { model.similarity.resume(scan) }
                            Button("Clear") { scan.clearSession() }
                            Button("Cancel Scan") { scan.cancel() }
                        }
                        else {
                            Button("Clear") {
                                scan.clearSession(); scan.activity.dismiss(scan.source.taskKind)
                                model.similarity.preview.close(); model.similarity.duplicatesOnly = false
                            }.help("Clear this scan and its results")
                        }
                    }.font(.caption)
                }.padding(14).background(FinderAppearance.accent.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            }
            if store.records.isEmpty && !scan.isRunning {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle").font(.system(size: 30)).foregroundStyle(.secondary)
                    Text("No transfers in progress").font(.headline)
                    Text("Imports, exports and background work appear here.").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(store.records.reversed()) { record in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: record.state == "Failed" ? "exclamationmark.circle" : record.active ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                                        .foregroundStyle(record.state == "Failed" ? Color.red : FinderAppearance.accent)
                                    Text(record.title).fontWeight(.medium).lineLimit(1)
                                    Spacer()
                                    if record.active {
                                        if record.transferDirection != nil {
                                            Button(record.state == "Paused" ? "Resume" : "Pause") {
                                                if record.state == "Paused" { model.resumeTransfer(record.id) }
                                                else { model.pauseTransfer(record.id) }
                                            }.disabled(record.state == "Stopping")
                                        }
                                        Button("Cancel") { model.cancel(record.id) }.disabled(record.state == "Stopping")
                                            .help(record.transferDirection == nil ? "Cancel this operation" : "Cancel and remove incomplete copies")
                                    }
                                    else { Text(record.state).font(.caption).foregroundStyle(.secondary) }
                                }
                                Text(record.progress.message).font(.callout).foregroundStyle(.secondary).lineLimit(compact ? 2 : 4).textSelection(.enabled)
                                if record.active {
                                    if let fraction = record.progress.fraction { ProgressView(value: min(1, max(0, fraction))) }
                                    else if record.progress.total > 0 { ProgressView(value: Double(record.progress.completed), total: Double(record.progress.total)) }
                                    else { ProgressView().controlSize(.small) }
                                }
                                if record.progress.total > 0 || (record.active && record.progress.folderSize?.fraction != nil) {
                                    HStack {
                                        if record.progress.total > 0 { Text("\(record.progress.completed.formatted()) of \(record.progress.total.formatted()) items") }
                                        Spacer(minLength: 0)
                                        if record.active, let fraction = record.progress.folderSize?.fraction {
                                            Text("≈ \(fraction.formatted(.percent.precision(.fractionLength(0))))")
                                                .help(FolderSizeProgress.diskUsageHelp)
                                        }
                                    }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                                if record.active, let size = record.progress.folderSize {
                                    ViewThatFits(in: .horizontal) {
                                        HStack {
                                            Text(size.speedSummary).help(FolderSizeProgress.speedHelp)
                                            Spacer(minLength: 12)
                                            Text(size.timeRemainingSummary)
                                        }
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(size.speedSummary).help(FolderSizeProgress.speedHelp)
                                            Text(size.timeRemainingSummary)
                                        }
                                    }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
                                }
                            }.padding(14).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
        }.padding(compact ? 18 : 24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear { model.similarity.refreshRecovery() }
    }
}

private struct NativeDriveFooter: View {
    @ObservedObject var model: NativeDriveModel
    @ObservedObject var store: CloudDriveActivityStore
    @ObservedObject var scan: SimilarityScanModel
    let section: Int
    var bookmarkCount: Int? = nil
    @Binding var showsStatus: Bool
    private var message: String {
        model.error ?? (scan.isRunning || scan.isPaused ? scan.message : store.latest?.progress.message ??
            (model.tree.isLoading ? "Loading folder contents…" : model.isConnected ? "Ready" : "Connect to get started"))
    }
    private var hasError: Bool { model.error != nil || (store.active.isEmpty && store.latest?.state == "Failed") }
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 10) {
                if section != 1 {
                    Menu {
                        ForEach(model.history) { location in Button(location.title) { model.navigate(to: location) } }
                    } label: {
                        Label(section == 6 ? "Trash" : section == 7 && bookmarkCount != nil ? "Bookmarks" : model.location.title,
                              systemImage: section == 6 ? "trash" : section == 7 && bookmarkCount != nil ? "bookmark" : "folder")
                            .lineLimit(1).truncationMode(.middle)
                    }.menuStyle(.borderlessButton).frame(maxWidth: .infinity, alignment: .leading)
                        .disabled(!model.isConnected || section == 6 || (section == 7 && bookmarkCount != nil))
                    Text(section == 6 ? "\(model.diskTrashItems.count.formatted()) items" : section == 7 && bookmarkCount != nil ? "\(bookmarkCount!) bookmarks" : model.selection.isEmpty ? "\(model.visibleRows.count.formatted()) shown" : "\(model.selection.count.formatted()) selected")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).layoutPriority(1)
                    Divider().frame(height: 14)
                }
                Button { showsStatus.toggle() } label: {
                    HStack(spacing: 6) {
                        if !store.active.isEmpty || scan.isRunning || model.isLoading || model.tree.isLoading { ProgressView().controlSize(.mini) }
                        else { Image(systemName: hasError ? "exclamationmark.circle" : "checkmark.circle").foregroundStyle(hasError ? Color.red : .secondary) }
                        if geometry.size.width >= 880 || section == 1 || !store.active.isEmpty || scan.isRunning {
                            Text(message).lineLimit(1).foregroundStyle(hasError ? Color.red : .secondary)
                        }
                    }.font(.caption).frame(minHeight: 24).padding(.horizontal, 6).contentShape(Rectangle())
                }.buttonStyle(.plain).pointingHandCursor().help("View progress, results and recent activity")
                    .accessibilityElement(children: .ignore).accessibilityAddTraits(.isButton)
                    .accessibilityLabel("Status: \(message)")
                if section == 1 { Spacer(minLength: 8) }
                Button { showsStatus.toggle() } label: { Image(systemName: "list.bullet.rectangle") }
                    .buttonStyle(.borderless).help("Activity details")
            }.padding(.horizontal, 10).frame(width: geometry.size.width, height: geometry.size.height)
        }.finderFooterSurface()
            .popover(isPresented: $showsStatus, arrowEdge: .top) {
                NativeDriveActivities(model: model, store: store, scan: scan, compact: true,
                    close: { showsStatus = false }).frame(width: 560, height: 540)
            }
            .onReceive(NotificationCenter.default.publisher(for: FinderPopover.dismissAllNotification)) { _ in showsStatus = false }
    }
}

private struct NativeDriveKeys: NSViewRepresentable {
    let model: NativeDriveModel
    func makeNSView(context: Context) -> KeyView { let view = KeyView(); view.model = model; return view }
    func updateNSView(_ view: KeyView, context: Context) { view.model = model }
    static func dismantleNSView(_ view: KeyView, coordinator: ()) { view.stop() }
    final class KeyView: NSView {
        weak var model: NativeDriveModel?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if MediaPreviewKeyView.handle(event) { return nil }
                guard let self, let model = self.model, let window = self.window,
                      NSApp.keyWindow === window, event.window === window, window.attachedSheet == nil,
                      !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField),
                      !(window.firstResponder is MediaSliderControl && PreviewKeyRouting.sliderOwns(keyCode: event.keyCode)) else { return event }
                let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
                if modifiers.isEmpty || modifiers == .shift {
                    if event.keyCode == 125 || event.keyCode == 126 {
                        let step = model.viewMode == 1 ? max(1, model.gridColumnCount) : 1
                        model.moveSelection(event.keyCode == 125 ? step : -step, extending: modifiers == .shift); return nil
                    }
                    if model.viewMode == 1 && (event.keyCode == 123 || event.keyCode == 124) {
                        model.moveSelection(event.keyCode == 124 ? 1 : -1, extending: modifiers == .shift); return nil
                    }
                }
                if modifiers.isEmpty {
                    if event.keyCode == 49, !model.selection.isEmpty { if !event.isARepeat { model.togglePreview(in: window) }; return nil }
                    if event.keyCode == 53 { model.closePreview() }
                    if event.keyCode == 36, let item = model.focusedItem, item.isFolder {
                        model.enter(item, rowID: model.focusedRowID); return nil
                    }
                    if model.viewMode == 0 && event.keyCode == 124 { model.expandSelection(); return nil }
                    if model.viewMode == 0 && event.keyCode == 123 { model.collapseSelection(); return nil }
                }
                if event.charactersIgnoringModifiers == "a", event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command {
                    model.selection = Set(model.visibleRows.map { $0.item.id }); return nil
                }
                return event
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
}

extension CloudDriveItem {
    var browserItem: BrowserItem {
        .init(id: id, name: name, size: bytes ?? 0, kind: isFolder ? .folder : .file, parentId: nil,
            mimeType: UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType,
            createdTime: nil, modifiedTime: modified?.ISO8601Format(), fileExtension: (name as NSString).pathExtension,
            iconLink: nil, thumbnailLink: nil, fileCategory: nil, hash: nil, md5Checksum: nil)
    }
}

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NativeDriveWorkspace: View {
    @ObservedObject var model: NativeDriveModel
    @ObservedObject var hub: CloudDriveHub
    @ObservedObject var settings: FinderSettings
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
            VStack(spacing: 0) {
                if !model.isConnected { connection }
                else if model.section == 1 {
                    NativeDriveActivities(model: model, store: model.activity, scan: model.similarity.local)
                } else { browser }
                Divider()
                NativeDriveFooter(model: model, store: model.activity, scan: model.similarity.local, showsStatus: $showsStatus)
            }
        }
        .focusedSceneValue(\.finderWindowActions, actions)
        .onChange(of: model.query) { _ in model.reload() }
        .onChange(of: model.selection) { _ in model.selectionChanged() }
        .onReceive(NotificationCenter.default.publisher(for: .init("MyCloudDriverFind"))) { _ in model.section = 0; searchFocused = true }
        .onDisappear { model.closePreview() }
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
                 : "Move \(pendingDelete.count) selected item(s) to Finder’s Trash? This change will sync to iCloud. You can undo it with Command-Z.")
        }
        .alert("\(model.kind.title)", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 27, height: 27)
                Text("MyCloudDriver").font(.headline)
            }.padding(.horizontal, 12).padding(.top, 18).padding(.bottom, 14)
            Text("WORKSPACE").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 12)
            FinderSidebarTab(title: "Browser", symbol: model.kind.symbol, selected: model.section == 0) { model.section = 0 }
            FinderSidebarTab(title: "Transfers", symbol: "arrow.up.arrow.down", selected: model.section == 1) { model.section = 1 }
            Divider().padding(.vertical, 5)
            FinderSettingsButton()
                .padding(.horizontal, 12)
            Spacer()
            Label(model.kind.title, systemImage: model.kind.symbol).font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.bottom, 14)
        }.padding(.horizontal, 8).frame(maxHeight: .infinity).background(FinderAppearance.sidebarBackground)
    }
    private var connection: some View {
        VStack(spacing: 20) {
            Image(systemName: model.kind.symbol).font(.system(size: 48)).foregroundStyle(FinderAppearance.accent)
                .frame(width: 104, height: 104).background(FinderAppearance.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 24))
            Text("Connect \(model.kind.title)").font(.title.weight(.semibold))
            Text(model.kind == .photos
                 ? "Browse your photos, videos and albums. Originals stored in iCloud Photos download when you preview, export or scan them."
                 : "Choose iCloud Drive or a folder within it. Files stored in the cloud download when needed, and file changes sync through macOS.")
                .font(.body).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 470)
            Button(model.kind == .photos ? "Allow Photos Access…" : "Choose iCloud Drive Folder…") {
                if model.kind == .photos { hub.connectPhotos() } else { hub.connectICloud() }
            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(hub.connectingPhotos)
            if hub.connectingPhotos { ProgressView("Waiting for Photos access…").controlSize(.small) }
            Text("Uses the Apple Account already signed in on this Mac.").font(.caption).foregroundStyle(.secondary)
        }.padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private var browser: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    if model.items.isEmpty {
                        emptyState
                    } else if model.viewMode == 0 { table }
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
                if settings.showsPreviewPane {
                    Divider()
                    NativeDriveInspector(model: model).frame(width: 224)
                }
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
    private var toolbar: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button { model.back() } label: { Image(systemName: "chevron.left") }.disabled(model.history.count < 2).help("Back")
                Menu {
                    Button(model.kind.title) { model.root() }
                    if let path = model.location.url { Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([path]) } }
                } label: { Label(model.location.title, systemImage: model.kind == .photos ? "rectangle.stack" : "folder").font(.headline).lineLimit(1) }
                .menuStyle(.borderlessButton).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search \(model.kind == .photos ? "media" : "this folder")", text: $model.query)
                        .textFieldStyle(.plain).focused($searchFocused)
                    if !model.query.isEmpty { Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).help("Clear search") }
                }.padding(7).background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 7)).frame(width: 210)
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
            }
            HStack(spacing: 10) {
                Button { model.chooseImport() } label: { Label("Import…", systemImage: "square.and.arrow.down") }.disabled(model.isMutating)
                    .help(model.kind == .photos ? "Import images or videos into Photos" : "Copy files or folders into this location")
                Button { model.chooseExport(model.selectedItems) } label: { Label("Export…", systemImage: "square.and.arrow.up") }.disabled(model.selection.isEmpty)
                    .help("Save selected items to a folder on this Mac")
                Menu {
                    Button("New \(model.kind.containerName)…") { newContainer() }.disabled(model.isMutating)
                    Button("Find Similar Files…") { model.findSimilar() }
                    Button("Check for Duplicates…") { model.findSimilar(exactOnly: true) }
                    Divider()
                    Button(model.kind == .photos ? "Remove Empty Albums…" : "Remove Empty Folders…") { model.reviewCleanup(empty: true) }.disabled(model.isMutating)
                    if model.kind == .icloud {
                        Button("Remove .DS_Store Files…") { model.reviewCleanup(empty: false) }.disabled(model.isMutating)
                    }
                } label: { Image(systemName: "ellipsis.circle") }.help("More actions")
                Spacer()
                Menu {
                    Button("Name") { model.sort(by: 0) }
                    Button("Date Modified") { model.sort(by: 1) }
                    Button("Size") { model.sort(by: 2) }
                } label: { Image(systemName: "arrow.up.arrow.down") }.help("Sort items")
                Picker("Display", selection: $model.viewMode) {
                    Image(systemName: "list.bullet").tag(0)
                    Image(systemName: "square.grid.2x2").tag(1)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 72).help("List or thumbnails")
            }
        }.padding(12).background(Color(nsColor: .controlBackgroundColor))
    }
    private var table: some View {
        Table(model.items, selection: $model.selection) {
            TableColumn("Name") { item in
                HStack(spacing: 8) {
                    Image(systemName: item.symbol).foregroundStyle(FinderAppearance.accent).frame(width: 20)
                    Text(item.name).lineLimit(1).font(.system(size: 12 * model.zoom))
                    if !item.isDownloaded { Image(systemName: "icloud.and.arrow.down").font(.caption).foregroundStyle(.secondary).help("Stored in iCloud; downloads when opened") }
                }
            }.width(min: 160, ideal: 360)
            TableColumn("Size") { item in Text(item.sizeLabel).foregroundStyle(.secondary).font(.caption).monospacedDigit() }.width(70)
            TableColumn(model.kind == .photos ? "Created" : "Modified") { item in
                Text(item.modified?.formatted(date: .abbreviated, time: .omitted) ?? "—").foregroundStyle(.secondary).font(.caption)
            }.width(95)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            contextMenu(model.contextSelection(ids))
        } primaryAction: { ids in
            if let item = model.contextSelection(ids).first { model.enter(item) }
        }
    }
    private var thumbnails: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 138 * model.zoom), spacing: 12)], spacing: 14) {
                ForEach(model.items) { item in
                    VStack(spacing: 8) {
                        NativeMediaThumbnail(item: item, kind: model.kind).frame(height: 88 * model.zoom)
                        Text(item.name).font(.system(size: 12 * model.zoom)).lineLimit(2).frame(height: 34 * model.zoom)
                        Text(item.isFolder ? model.kind.containerName : item.sizeLabel).font(.caption).foregroundStyle(.secondary)
                    }.padding(10).frame(maxWidth: .infinity)
                        .background(model.selection.contains(item.id) ? FinderAppearance.accent.opacity(0.13) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                        .contentShape(RoundedRectangle(cornerRadius: 10))
                        .onTapGesture(count: 2) { model.enter(item) }
                        .onTapGesture { model.select(item, extending: NSEvent.modifierFlags.contains(.shift), toggling: NSEvent.modifierFlags.contains(.command)) }
                        .contextMenu { contextMenu(model.selection.contains(item.id) ? model.selectedItems : [item]) }
                        .accessibilityElement(children: .ignore).accessibilityLabel(item.name)
                        .accessibilityValue(item.isFolder ? model.kind.containerName : item.sizeLabel)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAddTraits(model.selection.contains(item.id) ? .isSelected : [])
                        .accessibilityAction { model.select(item, extending: false, toggling: false) }
                        .accessibilityAction(named: Text("Open")) { model.enter(item) }
                }
            }.padding(16)
        }
    }
    private var emptyState: some View {
        VStack(spacing: 14) {
            if model.isLoading { ProgressView("Loading \(model.location.title)…") }
            else {
                Image(systemName: model.query.isEmpty ? "folder" : "magnifyingglass").font(.system(size: 38)).foregroundStyle(.tertiary)
                Text(model.query.isEmpty ? "This \(model.kind.containerName.lowercased()) is empty" : "No matching items").font(.headline)
                Text(model.query.isEmpty ? "Import files or create a \(model.kind.containerName.lowercased()) to get started." : "Try a different filename.").foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    @ViewBuilder private func contextMenu(_ selected: [CloudDriveItem]) -> some View {
        if let first = selected.first {
            if selected.count == 1 {
                if first.isFolder { Button("Open \(model.kind.containerName)") { model.enter(first) } }
                else {
                    FinderFileOpenMenu(item: first.browserItem, enabled: true, open: { model.open(first, application: $0) },
                        chooseApplication: { FinderFileApplications.chooseApplication(for: first.name) { model.open(first, application: $0) } })
                    Button("Quick Look") { model.selection = [first.id]; model.togglePreview(in: NSApp.keyWindow) }
                }
                Button("Rename…") { prompt = .init(title: "Rename \(model.kind.containerName.lowercased())", name: first.name, item: first) }
                    .disabled(!first.canRename || model.isMutating)
            }
            Divider()
            Button("Export \(selected.count == 1 ? "Item" : "\(selected.count) Items")…") { model.chooseExport(selected) }
            Button(model.kind == .photos ? "Add to Album…" : "Copy to Folder…") { chooseDestination(selected, copy: true) }
                .disabled(model.isMutating || (model.kind == .photos && selected.contains(where: \.isFolder)))
            Button(model.kind == .photos ? "Move to Album…" : "Move to Folder…") { chooseDestination(selected, copy: false) }
                .disabled(model.isMutating || (model.kind == .photos && (!model.location.id.hasPrefix("album:") || selected.contains(where: \.isFolder))))
            if selected.allSatisfy(\.isFolder), selected.count > 1 {
                Button("Merge \(model.kind == .photos ? "Albums" : "Folders")…") { model.reviewMerge(selected) }.disabled(model.isMutating)
            }
            Divider()
            Button("Find Similar Files…") { model.findSimilar(selected) }
            Button("Check for Duplicates…") { model.findSimilar(selected, exactOnly: true) }
            Button(model.kind == .photos ? "Calculate Original Size" : "Recalculate Folder Size") { model.measure(selected) }
            if selected.count == 1, let file = selected.first, model.kind == .icloud, file.browserItem.isCloudExtractableArchive {
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
    private func newContainer() { prompt = .init(title: "New \(model.kind.containerName)", name: "", item: nil) }
    private func requestDelete(_ items: [CloudDriveItem]) { pendingDelete = items; showsDelete = !items.isEmpty }
    private func chooseDestination(_ items: [CloudDriveItem], copy: Bool) {
        if model.kind == .photos { albumDestination = .init(items: items, source: model.location, copy: copy); return }
        let source = model.location
        let panel = NSOpenPanel(); panel.title = copy ? "Copy to Folder" : "Move to Folder"; panel.prompt = "Choose"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.directoryURL = model.provider?.root.url
        panel.message = "Choose a destination inside the connected iCloud Drive folder."
        panel.begin { result in
            if result == .OK, let url = panel.url { model.relocate(items, from: source, to: .init(id: url.absoluteString, title: url.lastPathComponent, url: url), copy: copy) }
        }
    }
    private var actions: FinderWindowActions {
        let selected = model.selectedItems, connected = model.isConnected, available = connected && !model.isMutating
        return .init(section: model.section, viewMode: model.viewMode, zoom: model.zoom,
            undoTitle: model.undoStack.last.map { "Undo \($0.title)" } ?? "Undo",
            redoTitle: model.redoStack.last.map { "Redo \($0.title)" } ?? "Redo",
            canUndo: available && !model.undoStack.isEmpty, canRedo: available && !model.redoStack.isEmpty,
            undo: { model.undo() }, redo: { model.undo(redo: true) },
            canRefresh: connected, canGoBack: model.history.count > 1, canUpload: available,
            canDownload: connected && !selected.isEmpty, canCreateFolder: available,
            canTrash: available && !selected.isEmpty && selected.allSatisfy(\.canDelete),
            canCheckDuplicates: connected, canReviewDuplicates: model.similarity.local.report != nil,
            canRemoveEmptyFolders: available, canRemoveDSStoreFiles: available && model.kind == .icloud,
            canMergeFolders: available && selected.count > 1 && selected.allSatisfy(\.isFolder),
            checkDuplicates: { model.findSimilar(exactOnly: true) }, findSimilarFiles: { model.findSimilar() },
            reviewDuplicates: { model.similarity.present(source: .local) },
            removeEmptyFolders: { model.reviewCleanup(empty: true) }, removeDSStoreFiles: { model.reviewCleanup(empty: false) },
            mergeFolders: { model.reviewMerge(selected) }, showStatus: { showsStatus = true },
            selectSection: { if $0 == 0 || $0 == 1 { model.section = $0 } }, setViewMode: { model.viewMode = $0 },
            adjustZoom: { model.zoom = min(1.8, max(0.75, model.zoom + $0)) }, resetZoom: { model.zoom = 1 },
            refresh: { model.reload() }, goBack: { model.back() }, upload: { model.chooseImport() },
            download: { model.chooseExport(selected) }, newFolder: newContainer, trash: { requestDelete(selected) },
            containerTitle: "New \(model.kind.containerName)…", importTitle: "Import Files or Folders…", exportTitle: "Export Selected Items…",
            trashTitle: model.kind == .photos ? "Delete Selected Items from Photos…" : "Move Selected Items to Trash",
            emptyTitle: "Remove Empty \(model.kind == .photos ? "Albums" : "Folders")…",
            mergeTitle: "Merge Selected \(model.kind == .photos ? "Albums" : "Folders")…", supportsLinks: false)
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
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let item = model.selectedItems.first {
                    NativeMediaThumbnail(item: item, kind: model.kind).frame(maxWidth: .infinity).frame(height: 170)
                    Text(item.name).font(.headline).textSelection(.enabled)
                    if model.selection.count > 1 { Text("\(model.selection.count) items selected").foregroundStyle(.secondary) }
                    LabeledContent("Kind", value: item.isFolder ? model.kind.containerName : item.kindLabel).font(.caption)
                    LabeledContent("Size", value: item.sizeLabel).font(.caption)
                    if let date = item.modified { Text(date.formatted()).font(.caption).foregroundStyle(.secondary) }
                    if !item.isFolder {
                        Button("Quick Look") { model.togglePreview(in: NSApp.keyWindow) }.help("Preview · Space")
                        Button("Open") { model.open(item) }
                        if model.kind == .photos { Text("Open and Export use the original media. Changes to an exported copy do not alter your Photos library.").font(.caption).foregroundStyle(.secondary) }
                    } else { Button("Open \(model.kind.containerName)") { model.enter(item) } }
                } else {
                    Image(systemName: "doc.viewfinder").font(.system(size: 34)).frame(maxWidth: .infinity).foregroundStyle(.tertiary).padding(.top, 70)
                    Text("Select an item to preview").font(.callout).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    Text("Press Space for Quick Look.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }.padding(18)
        }.background(Color(nsColor: .controlBackgroundColor))
    }
}

struct NativeDriveActivities: View {
    @ObservedObject var model: NativeDriveModel
    @ObservedObject var store: CloudDriveActivityStore
    @ObservedObject var scan: SimilarityScanModel
    var compact = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Label(compact ? "Status" : "Transfers & Activity", systemImage: "arrow.up.arrow.down").font(.headline); Spacer(); Text(model.kind.title).font(.caption).foregroundStyle(.secondary) }
            if scan.isRunning || scan.report != nil {
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text("File similarity").fontWeight(.medium); Spacer(); Button("View…") { model.similarity.present(source: .local) } }
                    Text(scan.message).font(.callout)
                    if scan.isRunning { ProgressView(value: scan.progress.fraction) }
                    Text(scan.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
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
                                    if record.active { Button("Cancel") { model.cancel(record.id) }.disabled(record.state == "Stopping") }
                                    else { Text(record.state).font(.caption).foregroundStyle(.secondary) }
                                }
                                Text(record.progress.message).font(.callout).foregroundStyle(.secondary).lineLimit(compact ? 2 : 4).textSelection(.enabled)
                                if record.active {
                                    if let fraction = record.progress.fraction { ProgressView(value: min(1, max(0, fraction))) }
                                    else if record.progress.total > 0 { ProgressView(value: Double(record.progress.completed), total: Double(record.progress.total)) }
                                    else { ProgressView().controlSize(.small) }
                                }
                                if record.progress.total > 0 { Text("\(record.progress.completed.formatted()) of \(record.progress.total.formatted()) items").font(.caption).foregroundStyle(.secondary).monospacedDigit() }
                            }.padding(14).background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
        }.padding(compact ? 18 : 24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct NativeDriveFooter: View {
    @ObservedObject var model: NativeDriveModel
    @ObservedObject var store: CloudDriveActivityStore
    @ObservedObject var scan: SimilarityScanModel
    @Binding var showsStatus: Bool
    var body: some View {
        HStack(spacing: 12) {
            Text(model.selection.isEmpty ? "\(model.items.count.formatted()) shown" : "\(model.selection.count.formatted()) selected").font(.caption).foregroundStyle(.secondary)
            Divider().frame(height: 14)
            Button { showsStatus.toggle() } label: {
                HStack(spacing: 7) {
                    if !store.active.isEmpty || scan.isRunning || model.isLoading { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "checkmark.circle").foregroundStyle(.secondary) }
                    Text(scan.isRunning ? scan.message : store.latest?.progress.message ?? (model.isConnected ? "Ready" : "Connect to get started"))
                        .font(.caption).lineLimit(1).foregroundStyle(.secondary)
                }
            }.buttonStyle(.plain).pointingHandCursor().help("View progress and recent activity")
            Spacer(minLength: 8)
            Button { showsStatus.toggle() } label: { Image(systemName: "list.bullet.rectangle") }.buttonStyle(.borderless).help("Activity details")
        }.padding(.horizontal, 14).padding(.vertical, 10)
            .popover(isPresented: $showsStatus, arrowEdge: .top) {
                NativeDriveActivities(model: model, store: store, scan: scan, compact: true).frame(width: 480, height: 380)
            }
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
                guard let self, let model = self.model, let window = self.window,
                      NSApp.keyWindow === window, event.window === window, window.attachedSheet == nil,
                      !(window.firstResponder is NSTextView), !(window.firstResponder is NSTextField) else { return event }
                if event.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty {
                    if event.keyCode == 49, !model.selection.isEmpty { if !event.isARepeat { model.togglePreview(in: window) }; return nil }
                    if event.keyCode == 53 { model.closePreview() }
                    if model.viewMode == 1 && (event.keyCode == 125 || event.keyCode == 126) { model.moveSelection(event.keyCode == 125 ? 1 : -1); return nil }
                }
                if event.charactersIgnoringModifiers == "a", event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command {
                    model.selection = Set(model.items.map(\.id)); return nil
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
            createdTime: nil, modifiedTime: nil, fileExtension: (name as NSString).pathExtension,
            iconLink: nil, thumbnailLink: nil, fileCategory: nil, hash: nil, md5Checksum: nil)
    }
}

import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

struct CloudDriveActivityRecord: Identifiable {
    let id: UUID
    let title: String
    var progress: CloudDriveProgress
    var state = "Running"
    var transferDirection: Int? = nil
    var active: Bool { state == "Running" || state == "Stopping" || state == "Paused" || state == "Retrying" || state == "Queued" }
}

@MainActor final class CloudDriveActivityStore: ObservableObject {
    @Published var records: [CloudDriveActivityRecord] = []
    var active: [CloudDriveActivityRecord] { records.filter(\.active) }
    var latest: CloudDriveActivityRecord? { active.last ?? records.last }
    func begin(_ title: String, transferDirection: Int? = nil) -> UUID {
        let id = UUID(); records.append(.init(id: id, title: title, progress: .init(message: title), transferDirection: transferDirection))
        if records.count > 200 { records.removeAll { !$0.active && $0.id != id } }
        return id
    }
    func update(_ id: UUID, _ progress: CloudDriveProgress) {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].active else { return }
        records[index].progress = progress
    }
    func finish(_ id: UUID, error: Error? = nil) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].state = error is CancellationError ? "Cancelled" : error == nil ? "Completed" : "Failed"
        if let error { records[index].progress.message = error is CancellationError ? "Cancelled" : error.localizedDescription }
    }
}

@MainActor private final class NativeExportCheckpoint { var ids = Set<String>() }

/// Original metadata stays off AppKit and is shared by cached root searches
/// and fresh visible-row searches for one captured provider connection.
private actor NativeSearchSource {
    nonisolated let provider: any NativeCloudDrive
    nonisolated let root: CloudDriveLocation
    private var items: [String: CloudDriveItem] = [:]
    private var runToken: UUID?
    private var seen = Set<String>()
    init(provider: any NativeCloudDrive) { self.provider = provider; root = provider.root }
    func record(_ values: [CloudDriveItem]) { for item in values { items[item.id] = item } }
    func page(folderID: String, offset: Int, token: UUID) async throws -> NativeFileSearchPage {
        try Task.checkCancellation()
        if folderID == root.id && offset == 0 { runToken = token; seen.removeAll(keepingCapacity: true) }
        guard runToken == token else { throw CancellationError() }
        let location: CloudDriveLocation
        if folderID == root.id { location = root }
        else {
            guard let folder = items[folderID], folder.isFolder else { throw CloudDriveError.message("This search folder is no longer available.") }
            location = folder.location
        }
        let page = try await provider.searchPage(location, offset: offset)
        try Task.checkCancellation()
        guard runToken == token else { throw CancellationError() }
        record(page.items)
        seen.formUnion(page.items.map(\.id))
        return .init(items: page.items.map(Self.searchItem), nextOffset: page.nextOffset)
    }
    func finish(token: UUID) {
        guard runToken == token else { return }
        items = items.filter { seen.contains($0.key) }
    }
    func navigation(_ navigation: FileSearchNavigation) throws -> (CloudDriveItem, [CloudDriveItem], [CloudDriveItem]) {
        guard let target = items[navigation.match.item.id] else { throw CloudDriveError.message("This search result is no longer available. Scan again.") }
        let ancestors = try navigation.ancestors.map { ancestor -> CloudDriveItem in
            guard let item = items[ancestor.id], item.isFolder else { throw CloudDriveError.message("This result's original folder is no longer available. Scan again.") }
            return item
        }
        let siblings = try navigation.items.map { value -> CloudDriveItem in
            guard let item = items[value.id] else { throw CloudDriveError.message("This folder's cached listing is incomplete. Scan again.") }
            return item
        }
        return (target, ancestors, siblings)
    }
    nonisolated static func searchItem(_ item: CloudDriveItem) -> FileSearchItem {
        .init(id: item.id, name: item.name, kind: item.isFolder ? "drive#folder" : "drive#file",
            size: item.bytes ?? 0, mimeType: nil, modifiedTime: nil)
    }
}

/// Delay the terminal callback until metadata pruning and the corresponding
/// finished event have both reached the index's serial worker.
private final class NativeSearchCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    func store(_ task: Task<Void, Never>) { lock.lock(); self.task = task; lock.unlock() }
    private func pending() -> Task<Void, Never>? { lock.lock(); defer { lock.unlock() }; return task }
    func wait() async { await pending()?.value }
}

@MainActor final class NativeDriveModel: ObservableObject {
    private static let checkingAvailabilityMessage = "Checking drive access…"
    let kind: CloudDriveKind
    let activity = CloudDriveActivityStore()
    let tree = NativeDriveTree()
    let mediaPreview: NativeMediaPreviewModel
    let thumbnailCache: NativeThumbnailCache
    private lazy var folderThumbnails = NativeFolderThumbnailPrefetcher(cache: thumbnailCache)
    private var thumbnailPrefetchEnabled = true
    let similarity = FileSimilarityCoordinator(activity: FinderTaskActivityStore())
    let fileSearch = FileSearchModel()
    private var searchContext = UUID()
    private var searchSource: NativeSearchSource?
    private var searchExpandedRows: [String: NativeDriveRowID] = [:]
    private var searchRevealTask: Task<Void, Never>?
    private var searchRevealID = UUID()
    private var searchRevealLoadingID: UUID?
    @Published private(set) var provider: (any NativeCloudDrive)? { didSet { resetFileSearch() } }
    @Published private(set) var history: [CloudDriveLocation] = []
    @Published private(set) var items: [CloudDriveItem] = []
    @Published var selection: Set<String> = [] {
        didSet {
            deletedSelection = nil
            if oldValue != selection { pendingDeletedSelection = nil }
            selectedItemsCache = nil
            if let remembered = collapsedFolderFocus, selection != [remembered.folderID.itemID] {
                collapsedFolderFocus = nil
            }
        }
    }
    @Published var query = "" { didSet { if oldValue != query { deletedSelection = nil; pendingDeletedSelection = nil } } }
    @Published var section = 0
    @Published var viewMode = 0 { didSet { if oldValue != viewMode { collapsedFolderFocus = nil; invalidateRowCaches(); reconcileSelection() } } }
    @Published var fileTypeFilter: BrowserFileFilter = .all {
        didSet {
            guard oldValue != fileTypeFilter else { return }
            deletedSelection = nil; pendingDeletedSelection = nil
            collapsedFolderFocus = nil
            invalidateRowCaches()
            let previousSelection = selection
            let previousFocus = selectionCursor
            reconcileSelection()
            if previousFocus != selectionCursor || (!previousSelection.isEmpty && selection.isEmpty) {
                closePreview(); mediaPreview.clear()
            }
        }
    }
    /// Hide folders a type filter has left with nothing to show. Only folders already known to be empty go.
    @Published var hidesEmptyFolders = true {
        didSet {
            guard oldValue != hidesEmptyFolders else { return }
            BrowserEmptyFolders.setPreference(hidesEmptyFolders, in: preferences)
            collapsedFolderFocus = nil
            invalidateRowCaches()
            let previousSelection = selection
            let previousFocus = selectionCursor
            reconcileSelection()
            if previousFocus != selectionCursor || (!previousSelection.isEmpty && selection.isEmpty) {
                closePreview(); mediaPreview.clear()
            }
        }
    }
    @Published var zoom = 1.0
    @Published private(set) var isLoading = false
    @Published private(set) var isCheckingAvailability = false
    @Published private(set) var isMutating = false
    @Published private(set) var total = 0
    @Published private(set) var nextOffset: Int?
    @Published private(set) var lastExportDestination: URL?
    @Published var error: String?
    @Published private(set) var bookmarkRevealedItemID: String?
    @Published private(set) var undoStack: [CloudDriveUndo] = []
    @Published private(set) var redoStack: [CloudDriveUndo] = []
    @Published private(set) var diskTrashItems: [DiskTrashItem] = []
    @Published var diskTrashSelection: Set<UUID> = []
    @Published private(set) var diskTrashLoading = false
    @Published private(set) var diskTrashReady = false
    @Published private(set) var diskTrashError: String?
    private var diskTrashLoad: Task<Void, Never>?
    private var diskTrashLoadID = UUID()
    var diskTrash: DiskTrash? { (provider as? ICloudDriveProvider)?.diskTrash }
    var usesDiskTrash: Bool { diskTrash != nil }
    var workspaceSections: [FinderWorkspaceSection] {
        usesDiskTrash ? FinderWorkspaceSection.standard + [.trash] : FinderWorkspaceSection.standard
    }
    /// Folders a size calculation is walking now, with a count because two can overlap.
    @Published private(set) var measuringIDs: [String: Int] = [:]
    var location: CloudDriveLocation { history.last ?? .init(id: "", title: kind.title) }
    /// The toolbar, menus, inspector and window actions each ask on every
    /// render; derive it once per change of rows or selection.
    var selectedItems: [CloudDriveItem] {
        if let selectedItemsCache { return selectedItemsCache }
        let items = contextSelection(selection)
        selectedItemsCache = items
        return items
    }
    private var filteredRowsCache: [NativeDriveRow]?
    private var filteredRowIndices: [NativeDriveRowID: Int]?
    /// Folders the current type filter has left empty, and how many rows that removed. Built with `filteredRowsCache`.
    private var hiddenFolderIDs = Set<String>()
    private var hiddenFolderCount = 0
    private var selectedItemsCache: [CloudDriveItem]?
    private var fileExtensionsCache: [String]?
    private func invalidateRowCaches() {
        filteredRowsCache = nil; filteredRowIndices = nil; selectedItemsCache = nil; fileExtensionsCache = nil
    }
    private let preferences: UserDefaults
    /// Same answer as `visibleRows.contains { $0.id == id }` without scanning.
    private func isVisibleRow(_ id: NativeDriveRowID) -> Bool {
        guard let row = tree.rowByID[id], viewMode == 0 || id.path.count == 1 else { return false }
        guard fileTypeFilter.matches(row.item) else { return false }
        // A file or a folder whose complete contents are not known cannot be
        // removed by Hide Empty Folders. Avoid building an entire filtered
        // listing to answer selection/focus for those common cases.
        guard hidesEmptyFolders, row.item.isFolder, tree.completeFolderIDs.contains(row.item.id) else { return true }
        _ = visibleRows
        return !hiddenFolderIDs.contains(row.item.id)
    }
    private func visibleRow(forItemID id: String) -> NativeDriveRow? {
        let rowID = viewMode == 0 ? tree.firstRowIDs[id] : NativeDriveRowID(path: [id])
        guard let rowID, isVisibleRow(rowID) else { return nil }
        return tree.rowByID[rowID]
    }
    private func visibleIndex(of id: NativeDriveRowID) -> Int? {
        let rows = visibleRows, unfiltered = viewMode == 0 ? tree.rows : tree.rootRows
        if rows.count == unfiltered.count { return (viewMode == 0 ? tree.rowIndices : tree.rootRowIndices)[id] }
        if filteredRowIndices == nil {
            filteredRowIndices = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($0.element.id, $0.offset) })
        }
        return filteredRowIndices?[id]
    }
    var visibleRows: [NativeDriveRow] {
        let rows = viewMode == 0 ? tree.rows : tree.rootRows
        guard fileTypeFilter.isActive || hidesEmptyFolders else { return rows }
        if let filteredRowsCache { return filteredRowsCache }
        let matched = fileTypeFilter.isActive ? rows.filter { fileTypeFilter.matches($0.item) } : rows
        // Folders the filter left empty: judged from listings already read, including collapsed folders'.
        let empty = hidesEmptyFolders
            ? BrowserEmptyFolders.emptyFolderIDs(among: (viewMode == 0 ? tree.folderIDs : tree.rootFolderIDs).intersection(tree.completeFolderIDs),
                children: { [tree] in tree.knownChildren(ofFolderID: $0) }, id: \.id, isFolder: \.isFolder,
                matches: { [fileTypeFilter] in fileTypeFilter.matches($0) })
            : []
        let filtered = empty.isEmpty ? matched : matched.filter { !($0.item.isFolder && empty.contains($0.item.id)) }
        hiddenFolderIDs = empty; hiddenFolderCount = matched.count - filtered.count
        filteredRowsCache = filtered
        return filtered
    }
    /// How many folder rows the type filter and "Hide Empty Folders" removed from what is on screen.
    var visibleHiddenFolderCount: Int {
        guard fileTypeFilter.isActive || hidesEmptyFolders else { return 0 }
        _ = visibleRows
        return hiddenFolderCount
    }
    var visibleFileCount: Int { visibleRows.lazy.filter { !$0.item.isFolder }.count }
    var availableFileExtensions: [String] {
        if let fileExtensionsCache { return fileExtensionsCache }
        let rows = viewMode == 0 ? tree.rows : tree.rootRows
        let extensions = Array(Set(rows.filter { !$0.item.isFolder }.map { BrowserFileFilter.extensionOf($0.item.name) })).sorted()
        fileExtensionsCache = extensions
        return extensions
    }
    @Published private(set) var availabilityMessage: String?
    var isConnected: Bool { provider != nil && availabilityMessage == nil }
    private var volumeObservers: [NSObjectProtocol] = []
    var isBusy: Bool { isMutating || !jobs.isEmpty || similarity.local.isRunning || similarity.local.isPausing || similarity.local.retainsOriginalsInRAM }
    var scanConfiguration: (() throws -> SimilarityConfiguration)?
    var presentAcrossDriveSimilarity: (([CloudDriveItem], any NativeCloudDrive, CloudDriveLocation) -> Void)?
    var onSendToPikPak: (([URL]) -> Void)?
    private var loadTask: Task<Void, Never>?
    private var loadID = UUID()
    private var closed = false
    private var availabilityTask: Task<Void, Error>?
    private var availabilityRefresh: Task<Void, Never>?
    private var availabilityID = UUID()
    private let availabilityValidation: @Sendable (ICloudDriveProvider) throws -> Void
    private let availabilityTimeout: TimeInterval
    private var bookmarkTask: Task<Void, Never>?
    private var bookmarkRequest = UUID()
    var bookmarkWriteTask: Task<Void, Never>?
    var bookmarkWriteRequest = UUID()
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var transferControls: [UUID: NativeTransferControl] = [:]
    private enum TransferPhase { case waiting, running, retrying }
    private var transferPhases: [UUID: TransferPhase] = [:]
    private var transferPermits: [UUID: UUID] = [:]
    private var transferPermitReleases: [UUID: Task<Void, Never>] = [:]
    private var transferResumeTasks: [UUID: Task<Void, Never>] = [:]
    private var transferResumeGenerations: [UUID: UUID] = [:]
    private let transferAdmission: NativeTransferAdmission
    private let quickLook = QuickLookPreviewCoordinator()
    private var previewTask: Task<Void, Never>?
    private var previewID = UUID()
    private var scanItemsByPath: [String: CloudDriveItem] = [:]
    private var scanItemsByID: [String: CloudDriveItem] = [:]
    private var similarityProvider: (any NativeCloudDrive)?
    private var similarityScopeProvider: (any NativeCloudDrive)?
    private var preparationIssues: [SimilarityIssue] = []
    private var scanDirectory: URL?
    private var pendingSimilarityRevealID: String?
    private var previewCache: [NativeMediaSourceIdentity: URL] = [:]
    private var previewOrder: [NativeMediaSourceIdentity] = []
    private var openCache: [NativeMediaSourceIdentity: URL] = [:]
    private var sortMode = 0
    private var sortRequest = UUID()
    @Published private(set) var browserSortColumn: BrowserSortColumn = .name
    @Published private(set) var browserSortDirection: BrowserSortDirection = .ascending
    private var selectionAnchor: NativeDriveRowID?
    private var deletedSelection: DeletedBrowserSelection<NativeDriveRowID>?
    private var pendingDeletedSelection: (focus: NativeDriveRowID, navigation: DeletedBrowserSelection<NativeDriveRowID>)?
    @Published private var selectionCursor: NativeDriveRowID?
    private var collapsedFolderFocus: (folderID: NativeDriveRowID, itemID: NativeDriveRowID, reopening: Bool)?
    var gridColumnCount = 1
    var focusedRowID: NativeDriveRowID? {
        if let selectionCursor, selection.contains(selectionCursor.itemID),
           isVisibleRow(selectionCursor) { return selectionCursor }
        return selection.compactMap { visibleRow(forItemID: $0) }.min {
            (tree.rowIndices[$0.id] ?? Int.max) < (tree.rowIndices[$1.id] ?? Int.max)
        }?.id
    }
    var focusedItemID: String? { focusedRowID?.itemID }
    var focusedItem: CloudDriveItem? { focusedRowID.flatMap { tree.rowByID[$0]?.item } }
    var inspectorItem: CloudDriveItem? { focusedItem ?? selectedItems.first }
    var inspectorPreviewIdentity: NativeMediaSourceIdentity? {
        guard let item = inspectorItem, let provider else { return nil }
        return .init(item: item, kind: provider.kind, rootID: provider.root.id)
    }
    private let temporaryRoot: URL

    init(kind: CloudDriveKind, temporaryRoot: URL? = nil, playbackSettings: MediaPlaybackSettings? = nil,
         transferAdmission: NativeTransferAdmission = .shared, thumbnailCache: NativeThumbnailCache? = nil,
         preferences: UserDefaults = .standard,
         availabilityTimeout: TimeInterval = 30,
         availabilityValidation: @escaping @Sendable (ICloudDriveProvider) throws -> Void = { try $0.validateAccess() }) {
        self.kind = kind
        self.preferences = preferences
        self.availabilityTimeout = availabilityTimeout
        self.availabilityValidation = availabilityValidation
        hidesEmptyFolders = BrowserEmptyFolders.preference(in: preferences)
        self.transferAdmission = transferAdmission
        self.thumbnailCache = thumbnailCache ?? .shared
        mediaPreview = NativeMediaPreviewModel(settings: playbackSettings ?? MediaPlaybackSettings())
        self.temporaryRoot = temporaryRoot ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("MyCloudDriver-\(kind.rawValue)-\(UUID().uuidString)", isDirectory: true)
        tree.onChange = { [weak self] in
            self?.invalidateRowCaches()
            self?.objectWillChange.send(); self?.reconcileSelection()
            self?.restoreCollapsedFolderFocus()
        }
        similarity.externalTitle = kind.title; similarity.externalSymbol = kind.symbol
        similarity.source = .local; similarity.local.externalTitle = kind.title
        if kind == .local {
            similarity.chooseFolderScope = { [weak self] in self?.chooseSimilarityFolder() }
        } else {
            similarity.scopePickerButtonTitle = kind == .photos ? "Choose Album or Library…" : "Choose Folder…"
            similarity.chooseFolderScope = { [weak self] in self?.chooseSimilarityDriveFolder() }
        }
        similarity.local.onRunningChanged = { [weak self] in self?.objectWillChange.send() }
        similarity.local.onSessionReset = { [weak self] in
            guard let self else { return }
            self.scanItemsByPath = [:]; self.scanItemsByID = [:]; self.preparationIssues = []
            self.similarityProvider = nil
            self.similarityScopeProvider = nil
            if let directory = self.scanDirectory { try? FileManager.default.removeItem(at: directory) }
            self.scanDirectory = nil
        }
        similarity.configuration = { [weak self] _ in
            guard let self, let configuration = self.scanConfiguration else { throw CocoaError(.fileNoSuchFile) }
            return try configuration()
        }
        similarity.restoreNativeScope = { [weak self] scope in
            guard let self, scope.drive == self.kind else { throw CloudDriveError.message("Open the original drive to resume this scan.") }
            let restored: any NativeCloudDrive
            if self.kind == .local, let url=scope.providerRoot.url {
                var stale=false
                let restoredURL=scope.bookmark.flatMap { try? URL(resolvingBookmarkData:$0,options:.withSecurityScope,relativeTo:nil,bookmarkDataIsStale:&stale) } ?? url
                restored=ICloudDriveProvider(rootURL:restoredURL,kind:.local)
            } else {
                guard let provider=self.provider, provider.kind == scope.drive else { throw CloudDriveError.message("Connect this drive, then resume the saved scan.") }
                restored=provider
            }
            self.configureSimilarity(scope.selection,provider:restored,location:scope.location,exactOnly:false,presentWindow:false,photosUsePreviews:scope.photosUsePreviews ?? false)
        }
        similarity.openExternalFile = { [weak self] file in
            guard let self else { return }
            self.open(self.similarityItem(file), using: self.similarityProvider)
        }
        similarity.moveToTrash = { [weak self] file in
            guard let self else { throw CancellationError() }
            try await self.trashSimilarityFile(file)
        }
        similarity.keepSmallest = { [weak self] plan in
            guard let self else { throw CancellationError() }
            return try await self.keepSmallestSimilarityFiles(plan)
        }
        similarity.preparePreview = { [weak self] file, directory in
            guard let self, let provider = self.similarityProvider ?? self.provider else {
                throw CloudDriveError.message("This item is no longer available in the connected drive.")
            }
            return try await provider.materialize(self.similarityItem(file), directory: directory, progress: { _ in })
        }
        if kind != .photos {
            let center = NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
                volumeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.refreshAvailability() }
                })
            }
        }
        quickLook.onClose = { [weak self] in self?.closePreview() }
        quickLook.onMove = { [weak self] offset in self?.movePreview(offset) }
        quickLook.onRetry = { [weak self] in self?.previewSelection() }
    }
    func connect(_ provider: any NativeCloudDrive) {
        guard !isBusy else { error = "Finish or cancel this drive’s active work before reconnecting."; return }
        cancelAvailability(); cancelBookmarkNavigation(); cancelBookmarkWrites()
        folderThumbnails.cancel()
        similarity.local.detachPausedForRecovery()
        closePreview(); mediaPreview.clear(); self.provider = provider; history = [provider.root]; query = ""; undoStack = []; redoStack = []
        fileTypeFilter = .all
        items = []; selection = []; total = 0; nextOffset = nil
        tree.reset(provider: provider); selectionAnchor = nil; selectionCursor = nil
        scanItemsByPath = [:]; scanItemsByID = [:]
        diskTrashItems = []; diskTrashSelection = []; diskTrashReady = false
        refreshDiskTrash(prepare: true)
        availabilityMessage = provider is ICloudDriveProvider ? Self.checkingAvailabilityMessage : nil
        reload()
    }

    /// Mark asynchronous provider construction as part of connecting, before
    /// the Hub schedules its worker. Keep an existing connection usable.
    func beginConnectionCheck() {
        cancelSearchReveal()
        loadTask?.cancel(); loadTask = nil; loadID = UUID()
        cancelAvailability(); cancelBookmarkNavigation(); cancelBookmarkWrites()
        isLoading = true; isCheckingAvailability = true; error = nil
    }

    func finishConnectionCheck(error: Error? = nil) {
        isLoading = false; isCheckingAvailability = false
        if let error {
            self.error = error.localizedDescription
            if provider == nil { availabilityMessage = error.localizedDescription }
        }
        // A second connection attempt can cancel the first provider's initial
        // validation. If it fails, do not leave that retained provider stuck
        // behind a checking marker with no worker left to complete it.
        if !closed, provider != nil, availabilityMessage == Self.checkingAvailabilityMessage { reload() }
    }

    private func cancelAvailability() {
        availabilityTask?.cancel(); availabilityTask = nil
        availabilityRefresh?.cancel(); availabilityRefresh = nil
        availabilityID = UUID(); isCheckingAvailability = false
    }

    /// All root identity and metadata validation stays on the bounded file
    /// worker. Concurrent reload/mount notifications share the pending check.
    private func checkAvailability(_ disk: ICloudDriveProvider) async throws {
        while true {
            try Task.checkCancellation()
            guard (provider as? ICloudDriveProvider) === disk else { throw CancellationError() }
            let request: UUID, work: Task<Void, Error>
            if let pending = availabilityTask { request = availabilityID; work = pending }
            else {
                request = UUID(); availabilityID = request; isCheckingAvailability = true
                let validate = availabilityValidation, timeout = availabilityTimeout
                work = Task { try await NativeFileWork.run(timeout: timeout) { try validate(disk) } }
                availabilityTask = work
            }
            let result = await work.result
            guard (provider as? ICloudDriveProvider) === disk else { throw CancellationError() }
            // Another waiter may have completed this check and a new reload
            // started the next one while we resumed. Follow that check rather
            // than treating a newer request as a canceled drive connection.
            guard availabilityID == request else { try Task.checkCancellation(); continue }
            availabilityTask = nil; isCheckingAvailability = false
            try Task.checkCancellation()
            switch result {
            case .success:
                availabilityMessage = nil
                return
            case .failure(let error):
                if !(error is CancellationError) {
                    availabilityMessage = error.localizedDescription
                    folderThumbnails.cancel(); closePreview(); mediaPreview.clear()
                    items = []; selection = []; total = 0; nextOffset = nil
                    tree.reset(provider: provider); selectionAnchor = nil; selectionCursor = nil
                }
                throw error
            }
        }
    }

    func refreshAvailability(reloadWhenAvailable: Bool = true) {
        guard let disk = provider as? ICloudDriveProvider else { availabilityMessage = nil; return }
        let previous = availabilityMessage
        availabilityRefresh?.cancel()
        availabilityRefresh = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.checkAvailability(disk)
                if previous != nil && reloadWhenAvailable && !self.isLoading { self.reload() }
            } catch {
                guard !(error is CancellationError), !Task.isCancelled, (self.provider as? ICloudDriveProvider) === disk else { return }
                self.loadTask?.cancel(); self.loadTask = nil; self.loadID = UUID(); self.isLoading = false
            }
        }
    }

    func sendToPikPak(_ items: [CloudDriveItem]) {
        guard kind == .local, let disk = provider as? ICloudDriveProvider, let onSendToPikPak else { return }
        do { onSendToPikPak(try disk.uploadSources(operationItems(items))) }
        catch { self.error = error.localizedDescription; refreshAvailability() }
    }

    private func similarityItem(_ file: SimilarityFile) -> CloudDriveItem {
        if let item = scanItemsByID[file.id] { return item }
        let path = file.localPath ?? (file.path.hasPrefix("/") ? file.path : nil)
        return CloudDriveItem(id:file.id,name:file.name,isFolder:false,bytes:file.bytes,
            url:kind == .photos ? nil : path.map { URL(fileURLWithPath: $0, isDirectory: false) },
            mediaType:file.family,canRename:kind != .photos,revision:file.nativeRevision)
    }

    func disconnect() {
        guard !isBusy else { error = "Finish or cancel this drive’s active work before disconnecting."; return }
        folderThumbnails.cancel()
        cancelAvailability(); cancelBookmarkNavigation(); cancelBookmarkWrites()
        similarity.local.detachPausedForRecovery()
        loadTask?.cancel(); loadTask = nil; loadID = UUID(); isLoading = false
        closePreview(); mediaPreview.clear(); availabilityMessage = nil; provider = nil; history = []; items = []; selection = []; query = ""
        tree.reset(provider: nil)
        selectionAnchor = nil; selectionCursor = nil; error = nil
        total = 0; nextOffset = nil; undoStack = []; redoStack = []
        scanItemsByPath = [:]; scanItemsByID = [:]
        diskTrashLoad?.cancel(); diskTrashLoad = nil; diskTrashLoadID = UUID()
        diskTrashItems = []; diskTrashSelection = []; diskTrashReady = false; diskTrashLoading = false; diskTrashError = nil
    }
    func reload(append: Bool = false) {
        guard let provider else { return }
        cancelSearchReveal()
        cancelBookmarkNavigation()
        if !append { folderThumbnails.cancel() }
        loadTask?.cancel(); let id = UUID(); loadID = id
        let location = location, query = query, offset = append ? nextOffset ?? 0 : 0
        if tree.search != query { items = []; tree.reset(provider: provider, search: query) }
        isLoading = true; error = nil
        loadTask = Task { [weak self] in
            do {
                if let disk = provider as? ICloudDriveProvider {
                    guard let self else { return }
                    try await self.checkAvailability(disk)
                }
                try Task.checkCancellation()
                if !query.isEmpty { try await Task.sleep(nanoseconds: 180_000_000) }
                let page = try await AutomaticRecovery.read(onRetry: { [weak self] failure, delay in
                    guard self?.loadID == id else { return }
                    self?.error = "Retrying in \(Int(delay))s. \(failure.localizedDescription)"
                }) { try await provider.list(location, offset: offset, search: query) }
                try Task.checkCancellation()
                guard let self, self.loadID == id else { return }
                let previous = append ? self.items : []
                let merged = await Task.detached(priority: .userInitiated) {
                    var seen = Set<String>()
                    return (previous + page.items).filter { seen.insert($0.id).inserted }
                }.value
                while true {
                    let mode = self.sortMode, direction = self.browserSortDirection
                    let sorted = await Task.detached(priority: .userInitiated) { NativeDriveTree.sorted(merged, by: mode, direction: direction) }.value
                    try Task.checkCancellation()
                    guard self.loadID == id else { return }
                    if mode != self.sortMode || direction != self.browserSortDirection { continue }
                    self.sortRequest = UUID()
                    let published = await self.tree.replaceRootsPrepared(sorted, refreshChildren: !append) {
                        self.loadID == id && self.sortMode == mode && self.browserSortDirection == direction
                    }
                    guard self.loadID == id, !Task.isCancelled else { return }
                    if mode != self.sortMode || direction != self.browserSortDirection { continue }
                    if !published { continue }
                    self.items = sorted
                    break
                }
                self.total = page.total; self.nextOffset = page.nextOffset; self.isLoading = false; self.error = nil
                self.prefetchThumbnails()
                if let target = self.pendingSimilarityRevealID {
                    if let row = self.visibleRows.first(where: { $0.item.id == target }) {
                        self.pendingSimilarityRevealID = nil
                        self.select(row, extending: false, toggling: false, requestsPreview: self.bookmarkRevealedItemID != target)
                    } else if page.nextOffset != nil { self.reload(append: true) }
                    else { self.pendingSimilarityRevealID = nil; self.error = "This file is no longer in its original folder." }
                }
            } catch {
                guard let self, self.loadID == id, !Task.isCancelled else { return }
                self.error = error.localizedDescription; self.isLoading = false
            }
        }
    }
    func enter(_ item: CloudDriveItem, rowID: NativeDriveRowID? = nil) {
        guard item.isFolder else { open(item); return }
        let rowID = rowID ?? visibleRows.first(where: { $0.item.id == item.id })?.id
        if let rowID {
            // Opening an indented folder keeps its ancestors in the breadcrumb.
            for count in 1..<rowID.path.count {
                if let ancestor = tree.rowByID[.init(path: Array(rowID.path.prefix(count)))] {
                    history.append(ancestor.item.location)
                }
            }
        }
        history.append(item.location); resetLocation()
    }
    func back() { guard history.count > 1 else { return }; history.removeLast(); resetLocation() }
    func navigate(to location: CloudDriveLocation) {
        guard let index = history.firstIndex(of: location) else { return }
        history = Array(history.prefix(index + 1)); resetLocation()
    }
    func root() { guard let root = provider?.root else { return }; history = [root]; resetLocation() }

    private struct BookmarkNavigation {
        let route: [CloudDriveLocation]
        let targetID: String
        let updated: FinderBookmark?
    }

    private func cancelBookmarkNavigation() {
        if bookmarkTask != nil { isLoading = false }
        bookmarkTask?.cancel(); bookmarkTask = nil; bookmarkRequest = UUID()
    }

    /// True means the request was accepted. Disk/bookmark resolution completes
    /// asynchronously, so a disconnected share cannot stop keyboard input.
    @discardableResult
    func openBookmark(_ bookmark: FinderBookmark, store requestedStore: FinderBookmarkStore? = nil) -> Bool {
        guard let provider, isConnected, !isMutating, bookmark.provider == kind.rawValue,
              bookmark.scope == bookmarkScope else { return false }
        let store = requestedStore ?? .shared
        cancelSearchReveal()
        cancelBookmarkNavigation()
        loadTask?.cancel(); loadTask = nil; loadID = UUID()
        let request = UUID(); bookmarkRequest = request
        isLoading = true; error = nil
        bookmarkTask = Task { [weak self] in
            do {
                let navigation: BookmarkNavigation
                if let disk = provider as? ICloudDriveProvider {
                    navigation = try await NativeFileWork.run {
                        // Recheck the mounted disk's identity rather than trust
                        // a path retained from the previous connection.
                        try disk.validateAccess()
                        var stale = false
                        let resolved = bookmark.fileBookmark.flatMap {
                            try? URL(resolvingBookmarkData: $0, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale)
                        } ?? bookmark.url
                        guard let resolved, let root = provider.root.url else { throw CloudDriveError.message("This bookmark has no folder location.") }
                        let url = resolved.standardizedFileURL.resolvingSymlinksInPath()
                        let prefix = root.path == "/" ? "/" : root.path + "/"
                        guard url.path == root.path || url.path.hasPrefix(prefix) else {
                            throw CloudDriveError.message("This bookmarked item has moved outside the connected folder. Connect its new folder to open it.")
                        }
                        var isDirectory = ObjCBool(false)
                        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue == bookmark.isFolder else {
                            throw CloudDriveError.message("This bookmarked item is no longer available. Reconnect its disk or remove it from Bookmarks.")
                        }
                        let folder = bookmark.isFolder ? url : url.deletingLastPathComponent()
                        let suffix = folder.path == root.path ? "" : String(folder.path.dropFirst(prefix.count))
                        var route = [provider.root], cursor = root
                        for component in suffix.split(separator: "/") {
                            cursor.appendPathComponent(String(component), isDirectory: true)
                            route.append(.init(id: cursor.absoluteString, title: String(component), url: cursor))
                        }
                        let updated: FinderBookmark?
                        if url != bookmark.url || stale {
                            updated = FinderBookmark(provider: bookmark.provider, scope: bookmark.scope, itemID: url.absoluteString,
                                name: url.lastPathComponent, isFolder: bookmark.isFolder,
                                parents: (bookmark.isFolder ? Array(route.dropLast()) : route).map { .init(id: $0.id, name: $0.title, path: $0.url?.path ?? $0.title, url: $0.url) },
                                url: url, fileBookmark: try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil), addedAt: bookmark.addedAt)
                        } else { updated = nil }
                        return BookmarkNavigation(route: route, targetID: url.absoluteString, updated: updated)
                    }
                } else {
                    var route = [provider.root] + bookmark.parents.filter { $0.id != provider.root.id }.map {
                        CloudDriveLocation(id: $0.id, title: $0.name, url: $0.url)
                    }
                    if bookmark.isFolder { route.append(.init(id: bookmark.itemID, title: bookmark.name)) }
                    navigation = BookmarkNavigation(route: route, targetID: bookmark.itemID, updated: nil)
                }
                try Task.checkCancellation()
                guard let self, self.bookmarkRequest == request, self.provider === provider else { return }
                self.bookmarkTask = nil
                if let updated = navigation.updated, store.bookmarks.contains(bookmark) {
                    store.remove(bookmark); store.add(updated)
                }
                self.history = navigation.route; self.fileTypeFilter = .all
                self.resetLocation(); self.mediaPreview.clear()
                if !bookmark.isFolder {
                    self.pendingSimilarityRevealID = navigation.targetID; self.bookmarkRevealedItemID = navigation.targetID
                }
            } catch {
                guard let self, !Task.isCancelled, self.bookmarkRequest == request, self.provider === provider else { return }
                self.bookmarkTask = nil; self.error = error.localizedDescription; self.isLoading = false
            }
        }
        return true
    }
    private func resetLocation() {
        cancelBookmarkNavigation()
        folderThumbnails.cancel()
        bookmarkRevealedItemID = nil
        collapsedFolderFocus = nil
        pendingSimilarityRevealID = nil
        closePreview(); query = ""; items = []; selection = []; selectionAnchor = nil; selectionCursor = nil
        tree.reset(provider: provider); reload()
    }
    func contextSelection(_ ids: Set<String>) -> [CloudDriveItem] {
        guard !ids.isEmpty else { return [] }
        return ids.compactMap { visibleRow(forItemID: $0) }.sorted {
            (tree.rowIndices[$0.id] ?? Int.max) < (tree.rowIndices[$1.id] ?? Int.max)
        }.map(\.item)
    }

    private func reconcileSelection() {
        if let deleted = pendingDeletedSelection, !isVisibleRow(deleted.focus) {
            pendingDeletedSelection = nil
            selection = []; selectionCursor = nil; selectionAnchor = nil
            collapsedFolderFocus = nil
            deletedSelection = deleted.navigation
            return
        }
        if !selection.isEmpty { selection = selection.filter { visibleRow(forItemID: $0) != nil } }
        if let cursor = selectionCursor, !isVisibleRow(cursor) {
            var parent = cursor.parent
            while let candidate = parent {
                if isVisibleRow(candidate), let row = tree.rowByID[candidate] {
                    selection.insert(row.item.id); selectionCursor = row.id; selectionAnchor = row.id
                    return
                }
                parent = candidate.parent
            }
            selectionCursor = nil; selectionAnchor = nil
        }
    }

    private var focusedToggleFolder: NativeDriveRow? {
        guard isConnected, viewMode == 0, let focusedRowID, let row = tree.rowByID[focusedRowID] else { return nil }
        if row.item.isFolder { return row }
        guard let parentID = focusedRowID.parent, tree.expanded.contains(parentID), isVisibleRow(parentID) else { return nil }
        return tree.rowByID[parentID]
    }
    var canToggleFocusedFolder: Bool { focusedToggleFolder != nil }
    var focusedFolderToggleTitle: String {
        guard let folder = focusedToggleFolder else { return "Expand or Collapse Folder" }
        let container = kind == .photos ? "Album" : "Folder"
        return (tree.expanded.contains(folder.id) ? "Collapse " : "Expand ") + container
    }
    func toggleFocusedFolder() {
        guard let folder = focusedToggleFolder else { return }
        toggleExpansion(folder)
    }
    private func restoreCollapsedFolderFocus() {
        guard let remembered = collapsedFolderFocus, remembered.reopening else { return }
        guard focusedRowID == remembered.folderID, tree.expanded.contains(remembered.folderID) else {
            collapsedFolderFocus = nil
            return
        }
        if let row = visibleRows.first(where: { $0.id == remembered.itemID }) {
            // A refresh retains old rows while it reloads expanded branches.
            // Wait for the file's full path to be confirmed before selecting it.
            for count in remembered.folderID.path.count..<remembered.itemID.path.count {
                let parentID = NativeDriveRowID(path: Array(remembered.itemID.path.prefix(count)))
                guard let parent = tree.rowByID[parentID], tree.branch(for: parent.item).loaded else { return }
            }
            select(row, extending: false, toggling: false)
        } else if let folder = tree.rowByID[remembered.folderID], tree.branch(for: folder.item).loaded,
                  tree.rowByID[remembered.itemID] == nil, !tree.isLoading {
            collapsedFolderFocus = nil
        }
    }
    func toggleExpansion(_ row: NativeDriveRow) {
        guard row.item.isFolder, tree.rowByID[row.id] != nil else { return }
        if tree.expanded.contains(row.id) {
            let child = focusedRowID.flatMap { id in
                id.path.count > row.id.path.count && id.path.starts(with: row.id.path) ? id : nil
            }
            collapsedFolderFocus = nil
            tree.toggle(row)
            if let child {
                select(row, extending: false, toggling: false)
                collapsedFolderFocus = (row.id, child, false)
            }
        } else {
            if collapsedFolderFocus?.folderID == row.id { collapsedFolderFocus?.reopening = true }
            else { collapsedFolderFocus = nil }
            tree.toggle(row)
            restoreCollapsedFolderFocus()
        }
    }
    func toggleExpansion(_ item: CloudDriveItem) {
        if let row = visibleRows.first(where: { $0.item.id == item.id }) { toggleExpansion(row) }
    }
    func isExpanded(_ item: CloudDriveItem) -> Bool {
        // Every folder row's menu asks; few folders are expanded, so check
        // those before scanning the rows.
        guard tree.expanded.contains(where: { $0.itemID == item.id }) else { return false }
        return visibleRows.first(where: { $0.item.id == item.id }).map { tree.expanded.contains($0.id) } ?? false
    }
    /// One rule for every Local Disk location. This Mac, an external disk and a network share are all
    /// the same `.local` model and workspace, so none of them has a separate setting.
    var canExpandAllLevels: Bool { kind == .local && isConnected && viewMode == 0 }
    func expandAllLevels(_ item: CloudDriveItem) { expandAllLevels([item]) }
    /// Expands every selected folder as one pass; files in the selection are ignored.
    func expandAllLevels(_ items: [CloudDriveItem]) {
        guard canExpandAllLevels else { return }
        var wanted = Set(items.filter(\.isFolder).map(\.id))
        let rows = visibleRows.filter { wanted.remove($0.item.id) != nil }
        guard !rows.isEmpty else { return }
        collapsedFolderFocus = nil
        tree.expandAllLevels(rows)
    }
    func isExpandingAllLevels(_ item: CloudDriveItem) -> Bool { isExpandingAllLevels([item]) }
    func isExpandingAllLevels(_ items: [CloudDriveItem]) -> Bool {
        guard !tree.expandingAllRoots.isEmpty else { return false }
        let ids = Set(items.map(\.id))
        return visibleRows.contains { ids.contains($0.item.id) && tree.isExpandingAll($0.id) }
    }
    func stopExpandingAllLevels() { tree.cancelExpandAll() }
    func expandSelection() {
        guard let id = focusedRowID, let row = tree.rowByID[id], row.item.isFolder else { return }
        if !tree.expanded.contains(id) { tree.toggle(row) }
        else if let child = tree.rows.first(where: { $0.id.parent == id }) { select(child, extending: false, toggling: false) }
    }
    func collapseSelection() {
        guard let id = focusedRowID, let row = tree.rowByID[id] else { return }
        if row.item.isFolder && tree.expanded.contains(id) { tree.toggle(row) }
        else if let parent = id.parent.flatMap({ tree.rowByID[$0] }) { select(parent, extending: false, toggling: false) }
    }

    func sort(by mode: Int) {
        deletedSelection = nil; pendingDeletedSelection = nil
        sortMode = mode
        browserSortColumn = mode == 1 ? .modified : mode == 2 ? .size : mode == 3 ? .kind : .name
        browserSortDirection = mode == 1 || mode == 2 ? .descending : .ascending
        applySort()
    }
    func toggleSort(_ column: BrowserSortColumn) {
        deletedSelection = nil; pendingDeletedSelection = nil
        browserSortDirection = browserSortColumn == column && browserSortDirection == .ascending ? .descending : .ascending
        browserSortColumn = column
        sortMode = column == .modified ? 1 : column == .size ? 2 : column == .kind ? 3 : 0
        applySort()
    }
    private func applySort() {
        let current = items, generation = loadID, mode = sortMode, direction = browserSortDirection, request = UUID()
        sortRequest = request
        tree.setSort(mode: mode, direction: direction)
        Task {
            let sorted = await Task.detached(priority: .userInitiated) { NativeDriveTree.sorted(current, by: mode, direction: direction) }.value
            guard provider != nil, loadID == generation, sortRequest == request else { return }
            guard await tree.replaceRootsPrepared(sorted, isCurrent: {
                self.provider != nil && self.loadID == generation && self.sortRequest == request
            }), provider != nil, loadID == generation, sortRequest == request else { return }
            items = sorted
        }
    }
    func select(_ item: CloudDriveItem, extending: Bool, toggling: Bool) {
        if let row = visibleRow(forItemID: item.id) { select(row, extending: extending, toggling: toggling) }
    }
    func select(_ row: NativeDriveRow, extending: Bool, toggling: Bool, requestsPreview: Bool = true) {
        let item = row.item
        guard isVisibleRow(row.id) else { return }
        // A row chosen while a disk bookmark is still resolving supersedes
        // that request. Programmatic bookmark reveal runs after its task ends.
        cancelBookmarkNavigation()
        if requestsPreview { bookmarkRevealedItemID = nil }
        collapsedFolderFocus = nil
        if extending, let anchor = selectionAnchor, let a = visibleIndex(of: anchor), let b = visibleIndex(of: row.id) {
            let rows = visibleRows
            selection = Set(rows[min(a, b)...max(a, b)].map { $0.item.id })
        } else if toggling {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }; selectionAnchor = row.id
        } else { selection = [item.id]; selectionAnchor = row.id }
        selectionCursor = row.id
        if requestsPreview && selection.contains(item.id) { prefetchThumbnails(for: row) }
    }
    /// Use the selected row's actual parent for an expanded outline; a file
    /// several folders below the breadcrumb must warm its own siblings.
    func prefetchThumbnails(for row: NativeDriveRow? = nil) {
        guard thumbnailPrefetchEnabled, isConnected, let provider else { folderThumbnails.cancel(); return }
        let folder: CloudDriveLocation, siblings: [CloudDriveItem], offset: Int?
        if let parentID = row?.id.parent, let parent = tree.rowByID[parentID] {
            folder = parent.item.location
            let branch = tree.branch(for: parent.item)
            siblings = branch.items; offset = branch.nextOffset
        } else {
            folder = location; siblings = items; offset = nextOffset
        }
        let context = NativeFolderThumbnailPrefetcher.Context(kind: kind, rootID: provider.root.id,
            folderID: folder.id, query: query)
        // A selection in the same folder does not restart its prefetch. Check
        // before touching the full sibling array, including on every arrow.
        guard folderThumbnails.context != context else { return }
        folderThumbnails.start(context: context, items: siblings, nextOffset: offset,
                               startingAt: row?.item.id, preferred: row?.item) { offset in
            let page = try await provider.list(folder, offset: offset, search: context.query)
            try Task.checkCancellation()
            return .init(items: page.items, nextOffset: page.nextOffset)
        }
    }
    func setThumbnailPrefetchActive(_ active: Bool) {
        thumbnailPrefetchEnabled = active
        if active { prefetchThumbnails(for: focusedRowID.flatMap { tree.rowByID[$0] }) }
        else { folderThumbnails.cancel() }
    }
    func showBookmarkPreview() { bookmarkRevealedItemID = nil }
    func moveSelection(_ offset: Int, extending: Bool = false) {
        let rows = visibleRows
        guard offset != 0, !rows.isEmpty else { return }
        let currentID = focusedRowID
        if currentID == nil, let deletedSelection {
            guard let index = deletedSelection.targetIndex(in: rows.map(\.id), offset: offset) else { return }
            select(rows[index], extending: false, toggling: false)
            return
        }
        let current = currentID.flatMap { visibleIndex(of: $0) } ?? -1
        let target = rows[min(rows.count - 1, max(0, current + offset))]
        if extending, selectionAnchor == nil || !selection.contains(selectionAnchor!.itemID) {
            selectionAnchor = currentID ?? target.id
        }
        select(target, extending: extending, toggling: false)
    }

    @discardableResult
    func run(_ title: String, mutating: Bool = false, transferDirection: Int? = nil,
             using alternateProvider: (any NativeCloudDrive)? = nil,
             completion: ((Result<Void, Error>) -> Void)? = nil,
             _ operation: @escaping (any NativeCloudDrive, @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo?) -> UUID? {
        guard let provider = alternateProvider ?? provider else {
            completion?(.failure(CloudDriveError.message("Reconnect this drive before changing files."))); return nil
        }
        let locksBrowser = mutating && transferDirection == nil
        guard !locksBrowser || !isMutating else {
            error = "Wait for the current file change to finish."
            completion?(.failure(CloudDriveError.message(error!))); return nil
        }
        let id = activity.begin(title, transferDirection: transferDirection)
        let control = transferDirection == nil ? nil : NativeTransferControl()
        transferControls[id] = control
        if control != nil, let index = activity.records.firstIndex(where: { $0.id == id }) { activity.records[index].state = "Queued" }
        objectWillChange.send()
        if locksBrowser { isMutating = true }
        let handler: CloudDriveProgressHandler = { [weak activity] value in Task { @MainActor in activity?.update(id, value) } }
        jobs[id] = Task { [weak self] in
            guard let self else { completion?(.failure(CancellationError())); return }
            defer {
                self.transferResumeTasks[id]?.cancel(); self.transferResumeTasks[id] = nil
                self.transferResumeGenerations[id] = nil; self.transferPhases[id] = nil
                self.releaseTransferPermit(id)
                self.transferPermitReleases[id] = nil
                self.objectWillChange.send(); self.jobs[id] = nil; self.transferControls[id] = nil
                if locksBrowser { self.isMutating = false }
                if mutating { self.reload(); self.refreshDiskTrash() }
            }
            var attempt = 0
            while true {
                do {
                    if let control {
                        self.transferPhases[id] = .waiting
                        try await self.acquireTransferPermit(id, control: control)
                        self.transferPhases[id] = .running
                        if let index = self.activity.records.firstIndex(where: { $0.id == id }) { self.activity.records[index].state = "Running" }
                    }
                    let undo = try await NativeTransferControl.$current.withValue(control) { try await operation(provider, handler) }
                    if let undo { self.undoStack.append(undo); self.redoStack = [] }
                    self.activity.finish(id); completion?(.success(())); break
                } catch {
                    if Task.isCancelled || control?.isCancelled == true || (control == nil && error is CancellationError) {
                        self.activity.finish(id, error: CancellationError()); completion?(.failure(CancellationError())); break
                    }
                    guard let control, TransferFailure.isRetryable(error) else {
                        self.activity.finish(id, error: error)
                        if completion == nil { self.error = error.localizedDescription }
                        completion?(.failure(error)); break
                    }
                    self.transferPhases[id] = .retrying
                    self.transferResumeTasks[id]?.cancel(); self.transferResumeTasks[id] = nil
                    self.transferResumeGenerations[id] = nil
                    self.releaseTransferPermit(id)
                    attempt = min(attempt + 1, 7)
                    let delay = min(60, 1 << (attempt - 1))
                    if let index = self.activity.records.firstIndex(where: { $0.id == id }) {
                        if self.activity.records[index].state != "Paused" { self.activity.records[index].state = "Retrying" }
                        self.activity.records[index].progress.message = "Retrying in \(delay)s · \(error.localizedDescription)"
                    }
                    do { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000); try await control.wait() }
                    catch { self.activity.finish(id, error: CancellationError()); completion?(.failure(CancellationError())); break }
                }
            }
        }
        return id
    }
    func pauseTransfer(_ id: UUID) {
        guard let control = transferControls[id] else { return }
        control.pause()
        transferResumeTasks[id]?.cancel(); transferResumeTasks[id] = nil
        transferResumeGenerations[id] = nil
        releaseTransferPermit(id)
        if let index = activity.records.firstIndex(where: { $0.id == id && $0.active }) { activity.records[index].state = "Paused" }
    }
    func resumeTransfer(_ id: UUID) {
        guard let control = transferControls[id] else { return }
        guard transferPhases[id] == .running else {
            // Queued and backoff jobs acquire normally at their next attempt.
            control.resume()
            if let index = activity.records.firstIndex(where: { $0.id == id && $0.active }) {
                activity.records[index].state = transferPhases[id] == .retrying ? "Retrying" : "Queued"
            }
            return
        }
        guard transferPermits[id] == nil, transferResumeTasks[id] == nil else { return }
        let generation = UUID(); transferResumeGenerations[id] = generation
        if let index = activity.records.firstIndex(where: { $0.id == id && $0.active }) { activity.records[index].state = "Queued" }
        transferResumeTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.transferResumeGenerations[id] == generation {
                    self.transferResumeTasks[id] = nil; self.transferResumeGenerations[id] = nil
                }
            }
            await self.transferPermitReleases[id]?.value
            do {
                let permit = try await self.transferAdmission.acquire(control: control, ignoringPause: true)
                guard !Task.isCancelled, self.jobs[id] != nil, self.transferPhases[id] == .running,
                      self.transferResumeGenerations[id] == generation, self.transferPermits[id] == nil else {
                    await self.transferAdmission.release(permit); return
                }
                self.transferPermits[id] = permit
                control.resume()
                if let index = self.activity.records.firstIndex(where: { $0.id == id && $0.active }) { self.activity.records[index].state = "Running" }
            } catch { /* A newer pause/cancel or completed job owns the visible state. */ }
        }
    }

    private func acquireTransferPermit(_ id: UUID, control: NativeTransferControl) async throws {
        while true {
            try await control.wait()
            await transferPermitReleases[id]?.value
            let permit = try await transferAdmission.acquire(control: control)
            // Pause can arrive while the actor hands a permit back to AppKit.
            if control.isPaused || Task.isCancelled {
                await transferAdmission.release(permit)
                try Task.checkCancellation()
                continue
            }
            transferPermits[id] = permit
            return
        }
    }

    private func releaseTransferPermit(_ id: UUID) {
        guard let permit = transferPermits.removeValue(forKey: id) else { return }
        let priorRelease = transferPermitReleases[id]
        let admission = transferAdmission
        transferPermitReleases[id] = Task {
            await priorRelease?.value
            await admission.release(permit)
        }
    }
    func cancel(_ id: UUID) {
        if let index = activity.records.firstIndex(where: { $0.id == id && $0.active }) { activity.records[index].state = "Stopping" }
        transferControls[id]?.cancel()
        transferResumeTasks[id]?.cancel(); transferResumeTasks[id] = nil
        transferResumeGenerations[id] = nil
        jobs[id]?.cancel()
    }
    func undo(redo: Bool = false) {
        deletedSelection = nil; pendingDeletedSelection = nil
        guard !isMutating, let operation = redo ? redoStack.last : undoStack.last else { return }
        let id = activity.begin((redo ? "Redo " : "Undo ") + operation.title); isMutating = true
        jobs[id] = Task {
            defer { jobs[id] = nil; isMutating = false; reload(); refreshDiskTrash() }
            do {
                let reverse = try await operation.apply()
                if redo { redoStack.removeAll { $0.id == operation.id }; undoStack.append(reverse) }
                else { undoStack.removeAll { $0.id == operation.id }; redoStack.append(reverse) }
                activity.finish(id)
            } catch { activity.finish(id, error: error); self.error = error.localizedDescription }
        }
    }
    func newContainer(_ name: String) {
        let location = location
        run("New \(kind.containerName)", mutating: true) { provider, _ in try await provider.createContainer(name, in: location) }
    }
    func rename(_ item: CloudDriveItem, name: String) { run("Rename", mutating: true) { provider, _ in try await provider.rename(item, to: name) } }
    /// Selecting an expanded folder and its children must perform a recursive
    /// iCloud operation once, not move/delete/export the same file twice.
    func operationItems(_ items: [CloudDriveItem]) -> [CloudDriveItem] {
        var seen = Set<String>()
        let unique = items.filter { seen.insert($0.id).inserted }
        guard kind != .photos else { return unique }
        let folders = Set(unique.filter(\.isFolder).compactMap { $0.url?.standardizedFileURL.path })
        return unique.filter { item in
            guard var parent = item.url?.standardizedFileURL.deletingLastPathComponent() else { return true }
            while parent.path != "/" {
                if folders.contains(parent.path) { return false }
                parent.deleteLastPathComponent()
            }
            return true
        }
    }
    func delete(_ items: [CloudDriveItem]) {
        let items = operationItems(items)
        let focus = focusedRowID
        let removedIDs = Set(items.map(\.id))
        let removesFocus = focus.map { !removedIDs.isDisjoint(with: $0.path) } ?? false
        let navigation = DeletedBrowserSelection(visibleIDs: visibleRows.map(\.id), selectedID: removesFocus ? focus : nil)
        let locationID = location.id, rootID = provider?.root.id, query = query
        closePreview()
        run(kind == .photos ? "Delete from Photos" : "Move to Trash", mutating: true, completion: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                guard self.location.id == locationID, self.provider?.root.id == rootID, self.query == query,
                      self.focusedRowID == focus, let focus, let navigation else { return }
                self.pendingDeletedSelection = (focus, navigation)
            case .failure(let error):
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }) { provider, progress in try await provider.delete(items, progress: progress) }
    }
    func refreshDiskTrash(prepare: Bool = false) {
        diskTrashLoad?.cancel(); diskTrashLoad = nil
        let id = UUID(); diskTrashLoadID = id
        guard let store = diskTrash else {
            diskTrashItems = []; diskTrashSelection = []; diskTrashLoading = false; diskTrashReady = false; diskTrashError = nil
            return
        }
        diskTrashLoading = true; diskTrashError = nil
        diskTrashLoad = Task { [weak self] in
            var preparationError: String?
            var migrated = false
            if prepare {
                do { migrated = try await store.prepare() }
                catch { preparationError = error.localizedDescription }
            }
            do {
                let items = try await store.list()
                guard let self, !Task.isCancelled, self.diskTrashLoadID == id, self.diskTrash === store else { return }
                self.diskTrashItems = items
                self.diskTrashSelection.formIntersection(Set(items.map(\.id)))
                self.diskTrashReady = preparationError == nil
                self.diskTrashError = preparationError
                if migrated { self.reload() }
                let available = Set(items.map(\.id))
                self.undoStack.removeAll { !$0.diskTrashEntryIDs.isEmpty && !$0.diskTrashEntryIDs.isSubset(of: available) }
                self.redoStack.removeAll { !$0.diskTrashEntryIDs.isEmpty && !$0.diskTrashEntryIDs.isSubset(of: available) }
                self.diskTrashLoading = false; self.diskTrashLoad = nil
            } catch {
                guard let self, !Task.isCancelled, self.diskTrashLoadID == id, self.diskTrash === store else { return }
                self.diskTrashError = preparationError ?? error.localizedDescription
                self.diskTrashReady = false; self.diskTrashLoading = false; self.diskTrashLoad = nil
            }
        }
    }
    func putBackFromDiskTrash(_ ids: Set<UUID>) {
        guard let store = diskTrash, !ids.isEmpty else { return }
        run("Put Back", mutating: true) { _, _ in try await store.putBack(Array(ids)) }
    }
    func emptyDiskTrash(_ ids: Set<UUID>) {
        guard let store = diskTrash, !ids.isEmpty else { return }
        run("Empty Trash", mutating: true) { _, progress in
            try await store.empty(Array(ids), progress: progress)
            return nil
        }
    }
    func trashSimilarityFile(_ file: SimilarityFile) async throws {
        guard similarity.local.results.index?.byID[file.id] != nil else {
            throw CloudDriveError.message("This result no longer belongs to the current scan. Scan the folder again.")
        }
        // Use the provider captured by the scan. A later folder choice, browser
        // navigation or another window must not change the deletion target.
        guard let provider = similarityProvider ?? provider else {
            throw CloudDriveError.message("Reconnect \(kind.title) before moving this file to Trash.")
        }
        let item: CloudDriveItem
        if let scanned = scanItemsByID[file.id] { item = scanned }
        else if kind != .photos, let path = file.localPath { item = try ICloudDriveProvider.item(URL(fileURLWithPath: path)) }
        else { throw CloudDriveError.message("This file is no longer available in the scan’s drive.") }
        guard !item.isFolder, item.canDelete else { throw CloudDriveError.message("This file cannot be moved to Trash.") }
        let results = similarity.local.results, session = results.sessionToken
        closePreview(); similarity.preview.close()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            run(kind == .photos ? "Move to Recently Deleted" : "Move to Trash", mutating: true, using: provider,
                completion: { continuation.resume(with: $0) }) { provider, progress in
                let undo = try await provider.delete([item], progress: progress)
                return undo.map { Self.similarityUndo($0, fileIDs: [file.id], results: results, session: session, restoring: true) }
            }
        }
    }
    func keepSmallestSimilarityFiles(_ plan: SimilarityKeepSmallestPlan) async throws -> Set<String> {
        let results = similarity.local.results
        try results.validateKeepSmallest(plan)
        guard let provider = similarityProvider ?? provider else {
            throw CloudDriveError.message("Reconnect the scan’s drive before changing files.")
        }
        func item(_ file: SimilarityFile) throws -> CloudDriveItem {
            if let scanned = scanItemsByID[file.id] { return scanned }
            if kind != .photos, let path = file.localPath { return try ICloudDriveProvider.item(URL(fileURLWithPath: path)) }
            throw CloudDriveError.message("A file is no longer available in the scan’s drive. No files were moved to Trash.")
        }
        func verifiedItem(_ file: SimilarityFile) throws -> CloudDriveItem {
            var value = try item(file)
            guard let revision = file.nativeRevision ?? scanItemsByID[file.id]?.revision else {
                throw CloudDriveError.message("This saved comparison cannot verify file changes. Scan the group again before using \(plan.actionTitle).")
            }
            value.revision = revision
            return value
        }
        let keepers = try plan.keepers.map(verifiedItem), removals = try plan.removals.map(verifiedItem)
        guard removals.allSatisfy({ !$0.isFolder && $0.canDelete }),
              Set(keepers.map(\.id)).isDisjoint(with: Set(removals.map(\.id))) else {
            throw CloudDriveError.message("These files cannot be safely moved to Trash. Review the group and try again.")
        }
        closePreview(); similarity.preview.close()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            run(plan.actionTitle, mutating: true, using: provider, completion: { continuation.resume(with: $0) }) { provider, progress in
                let candidates = keepers + removals
                let fresh = try await provider.refreshedItems(candidates)
                guard fresh.count == candidates.count, zip(fresh, candidates).allSatisfy({
                    $0.id == $1.id && !$0.isFolder && $0.revision != nil && $0.revision == $1.revision && ($0.bytes == nil || $0.bytes == $1.bytes)
                }) else {
                    throw CloudDriveError.message("A compared file is missing or has changed. No files were moved to Trash. Scan this group again.")
                }
                try await MainActor.run { try results.validateKeepSmallest(plan) }
                try Task.checkCancellation()
                let undo = try await provider.deleteVerified(removals, progress: progress)
                return undo.map { Self.similarityUndo($0, fileIDs: plan.removalIDs, results: results, session: plan.session, restoring: true) }
            }
        }
        return plan.removalIDs
    }
    /// Cross-drive callers capture a provider and decode its original IDs.
    /// Never resolve these files through this model's current browser or scan.
    @discardableResult
    func preflightSimilarityFiles(_ files: [SimilarityFile], provider: any NativeCloudDrive) async throws -> [CloudDriveItem] {
        guard !closed, provider.kind == kind, Set(files.map(\.id)).count == files.count else {
            throw CloudDriveError.message("The compared files no longer belong to this drive. Scan the group again.")
        }
        let candidates = try files.map { file -> CloudDriveItem in
            guard file.cloudId == nil, let revision = file.nativeRevision else {
                throw CloudDriveError.message("This saved comparison cannot verify file changes. Scan the group again.")
            }
            let url = file.localPath.map { URL(fileURLWithPath: $0) }
            guard kind == .photos || url != nil else {
                throw CloudDriveError.message("An original file is no longer available in the scan's drive.")
            }
            return CloudDriveItem(id: file.id, name: file.name, isFolder: false, bytes: file.bytes,
                url: kind == .photos ? nil : url, mediaType: file.family, canRename: kind != .photos, revision: revision)
        }
        try Task.checkCancellation()
        let fresh = try await provider.refreshedItems(candidates)
        guard !closed, fresh.count == candidates.count, zip(fresh, candidates).allSatisfy({
            $0.id == $1.id && !$0.isFolder && $0.revision != nil && $0.revision == $1.revision
                && ($0.bytes == nil || $0.bytes == $1.bytes)
        }) else {
            throw CloudDriveError.message("A compared file is missing or has changed. No files were moved to Trash. Scan the group again.")
        }
        try Task.checkCancellation()
        return fresh
    }
    func trashCrossDriveSimilarityFiles(_ removals: [SimilarityFile], keeping keepers: [SimilarityFile],
                                       provider: any NativeCloudDrive, results: SimilarityResultsModel,
                                       session: UUID, resultIDs: Set<String>) async throws -> Set<String> {
        func validateRows() throws {
            guard !closed, results.sessionToken == session, !removals.isEmpty,
                  Set(removals.map(\.id)).count == removals.count,
                  resultIDs == Set(removals.map { SimilarityAcrossDrives.fileID(drive: kind, originalID: $0.id) }),
                  removals.allSatisfy({ file in
                      let id = SimilarityAcrossDrives.fileID(drive: kind, originalID: file.id)
                      guard let stored = results.index?.byID[id] else { return false }
                      return !results.trashedIDs.contains(id) && stored.bytes == file.bytes && stored.cloudId == nil
                          && stored.nativeRevision == file.nativeRevision
                          && stored.localPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
                              == file.localPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
                  }), Set(keepers.map(\.id)).isDisjoint(with: Set(removals.map(\.id))) else {
                throw CloudDriveError.message("These files no longer belong to the reviewed scan. Review the group and try again.")
            }
        }
        try validateRows()
        closePreview(); similarity.preview.close()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            run(kind == .photos ? "Move to Recently Deleted" : "Move to Trash", mutating: true, using: provider,
                completion: { continuation.resume(with: $0) }) { provider, progress in
                let fresh = try await self.preflightSimilarityFiles(keepers + removals, provider: provider)
                try validateRows()
                let targets = Array(fresh.suffix(removals.count))
                guard targets.allSatisfy({ $0.canDelete }) else { throw CloudDriveError.message("A compared file cannot be moved to Trash.") }
                try Task.checkCancellation()
                let undo = try await provider.deleteVerified(targets, progress: progress)
                return undo.map { Self.similarityUndo($0, fileIDs: resultIDs, results: results, session: session, restoring: true) }
            }
        }
        return resultIDs
    }
    private static func similarityUndo(_ undo: CloudDriveUndo, fileIDs: Set<String>, results: SimilarityResultsModel,
                                       session: UUID, restoring: Bool) -> CloudDriveUndo {
        .init(title: undo.title, diskTrashEntryIDs: undo.diskTrashEntryIDs) {
            let reverse = try await undo.apply()
            return await MainActor.run {
                if results.sessionToken == session { results.setTrashedIDs(fileIDs, !restoring) }
                return Self.similarityUndo(reverse, fileIDs: fileIDs, results: results, session: session, restoring: !restoring)
            }
        }
    }
    func relocate(_ items: [CloudDriveItem], from source: CloudDriveLocation? = nil, to destination: CloudDriveLocation, copy: Bool) {
        let source = source ?? location, items = operationItems(items)
        run(copy ? "Copy" : "Move", mutating: true) { provider, progress in try await provider.relocate(items, from: source, to: destination, copy: copy, progress: progress) }
    }
    func importFiles(_ urls: [URL], into destination: CloudDriveLocation? = nil) {
        guard provider != nil else { return }
        let location = destination ?? location
        for url in urls {
            run("Import \(url.lastPathComponent)", mutating: true, transferDirection: 1) { provider, progress in
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                return try await provider.importFiles([url], into: location, progress: progress)
            }
        }
    }
    func chooseImport() {
        let destination = location, rootID = provider?.root.id
        let panel = NSOpenPanel(); panel.title = "Import into \(kind.title)"
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            if response == .OK { Task { @MainActor in
                guard let self, self.provider?.root.id == rootID else { return }
                self.importFiles(panel.urls, into: destination)
            } }
        }
    }
    func export(_ items: [CloudDriveItem], to destination: URL) {
        let items = operationItems(items)
        guard provider != nil, !items.isEmpty else { return }
        let access = LocalFileAccessLease([destination])
        do {
            if let disk = provider as? ICloudDriveProvider { try disk.validateAccess() }
            try LocalFileAccess.validate(destination, directory: true, writing: true)
        } catch { self.error = error.localizedDescription; refreshAvailability(); return }
        lastExportDestination = destination
        let volumeID = LocalFileAccess.volumeID(destination)
        for item in items { exportOne(item, to: destination, access: access, volumeID: volumeID) }
    }
    private func exportOne(_ item: CloudDriveItem, to destination: URL, access: LocalFileAccessLease, volumeID: String?) {
        let items = [item]
        let location = location, temp = temporaryRoot.appendingPathComponent("Exports/\(UUID().uuidString)")
        let completed = NativeExportCheckpoint()
        run("Export \(item.name)", transferDirection: 0) { provider, progress in
            defer { withExtendedLifetime(access) {}; try? FileManager.default.removeItem(at: temp) }
            try LocalFileAccess.validate(destination, volumeID: volumeID, directory: true, writing: true)
            if provider.kind != .photos {
                for (index, item) in items.enumerated() {
                    let url = try await provider.materialize(item, directory: temp, progress: progress)
                    try await CloudDriveFiles.detached { try ICloudDriveProvider.copy(url, to: destination.appendingPathComponent(item.name), progress: progress, destinationVolumeID: volumeID) }
                    progress(.init(message: "Exporting files", completed: index + 1, total: items.count))
                }
            } else {
                let files = try await provider.scanItems(items, location: location, progress: progress)
                for (index, file) in files.enumerated() {
                    if completed.ids.contains(file.id) { continue }
                    try await NativeTransferControl.current?.wait()
                    try Task.checkCancellation()
                    let url = try await provider.materialize(file, directory: temp, progress: progress)
                    try await CloudDriveFiles.detached {
                        let target = CloudDriveFiles.availableName(file.name, in: destination)
                        try ICloudDriveProvider.copy(url, to: target, progress: progress, destinationVolumeID: volumeID)
                    }
                    completed.ids.insert(file.id)
                    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                    progress(.init(message: "Exporting originals", completed: index + 1, total: files.count))
                }
            }
            return nil
        }
    }
    func chooseExport(_ items: [CloudDriveItem]) {
        let panel = NSOpenPanel(); panel.title = "Export Selected Items"; panel.prompt = "Export Here"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.begin { [weak self] response in if response == .OK, let url = panel.url { Task { @MainActor in self?.export(items, to: url) } } }
    }
    func open(_ item: CloudDriveItem, application: URL? = nil, using alternateProvider: (any NativeCloudDrive)? = nil) {
        if item.isFolder { enter(item); return }
        // Copies handed to another app survive exit, like the PikPak Open flow.
        let directory = ((try? LocalCredentialStore.applicationSupportDirectoryURL()) ?? temporaryRoot)
            .appendingPathComponent("OpenFiles/\(kind.rawValue)")
        run("Open \(item.name)", using: alternateProvider) { [weak self] provider, progress in
            let identity = NativeMediaSourceIdentity(item: item, kind: provider.kind, rootID: provider.root.id)
            let url: URL
            if let cached = self?.openCache[identity], FileManager.default.fileExists(atPath: cached.path) { url = cached }
            else {
                url = try await provider.materialize(item, directory: directory, progress: progress)
                if provider.kind == .photos { self?.openCache[identity] = url }
            }
            if let application { _ = try await NSWorkspace.shared.open([url], withApplicationAt: application, configuration: .init()) }
            else { _ = try await NSWorkspace.shared.open(url, configuration: .init()) }
            return nil
        }
    }
    func togglePreview(in window: NSWindow?) {
        if quickLook.isVisible { closePreview() }
        else { quickLook.prepare(in: window); previewSelection() }
    }
    func selectionChanged() {
        if let item = inspectorItem, let provider {
            if !mediaPreview.matches(item, provider: provider) { mediaPreview.clear() }
        } else { mediaPreview.clear() }
        if quickLook.isActive { previewSelection() }
    }
    private func previewSelection() {
        guard let item = focusedItem, let provider else { closePreview(); return }
        let identity = NativeMediaSourceIdentity(item: item, kind: provider.kind, rootID: provider.root.id)
        previewTask?.cancel(); let generation = UUID(); previewID = generation
        if item.isFolder { quickLook.showFolder(fileID: item.id, name: item.name); return }
        if let cached = previewCache[identity], FileManager.default.fileExists(atPath: cached.path) {
            _ = quickLook.present(cached, name: item.name); return
        }
        _ = quickLook.showLoading(fileID: item.id, name: item.name)
        let folder = temporaryRoot.appendingPathComponent("QuickLook")
        previewTask = Task { [weak self] in
            do {
                let url = try await AutomaticRecovery.read(onRetry: { [weak self] failure, delay in
                    guard self?.previewID == generation, self?.inspectorPreviewIdentity == identity else { return }
                    self?.quickLook.showFailure("Retrying in \(Int(delay))s. \(failure.localizedDescription)")
                }) { try await provider.materialize(item, directory: folder, progress: { _ in }) }
                guard let self, self.previewID == generation, self.inspectorPreviewIdentity == identity, !Task.isCancelled else {
                    if provider.kind == .photos { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                    return
                }
                if provider.kind == .photos {
                    self.previewCache[identity] = url; self.previewOrder.removeAll { $0 == identity }; self.previewOrder.append(identity)
                    while self.previewOrder.count > 8 {
                        let oldest = self.previewOrder.removeFirst()
                        if let old = self.previewCache.removeValue(forKey: oldest) { try? FileManager.default.removeItem(at: old.deletingLastPathComponent()) }
                    }
                }
                _ = self.quickLook.present(url, name: item.name)
            } catch {
                guard let self, self.previewID == generation, self.inspectorPreviewIdentity == identity, !Task.isCancelled else { return }
                self.quickLook.showFailure(error.localizedDescription)
            }
        }
    }
    private func movePreview(_ offset: Int) {
        moveSelection(offset); previewSelection()
    }
    func closePreview() {
        previewID = UUID(); previewTask?.cancel(); previewTask = nil; quickLook.dismiss()
        if kind == .photos {
            for url in previewCache.values { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            previewCache = [:]; previewOrder = []
        }
    }

    var usesFileSearchPalette: Bool { kind != .photos && provider?.root.url != nil }
    private func cancelSearchReveal() {
        searchRevealID = UUID()
        searchRevealTask?.cancel(); searchRevealTask = nil
        if searchRevealLoadingID != nil {
            searchRevealLoadingID = nil; isLoading = false
        }
    }
    private func finishSearchReveal(_ request: UUID) {
        guard searchRevealID == request else { return }
        searchRevealTask = nil
        if searchRevealLoadingID == request {
            searchRevealLoadingID = nil; isLoading = false
        }
    }
    private func resetFileSearch() {
        searchContext = UUID(); cancelSearchReveal()
        searchSource = nil; searchExpandedRows = [:]; fileSearch.reset()
    }
    @discardableResult
    func presentFileSearch(scope: FileSearchScope = .expanded) -> Bool {
        guard !closed, kind != .photos else { return false }
        guard let provider else {
            fileSearch.presentNative(scope: scope, contextID: searchContext.uuidString, contextName: "Disconnected drive",
                sourceName: kind.title, symbol: kind.symbol, failure: "Reconnect \(kind.title) before searching its file and folder names.")
            return true
        }
        guard usesFileSearchPalette else { return false }
        let source = searchSource ?? NativeSearchSource(provider: provider)
        searchSource = source
        let rows = scope == .expanded ? visibleRows : []
        let base = history.dropFirst().map { FileSearchAncestor(id: $0.id, name: $0.title) }
        var matches: [FileSearchMatch] = []
        searchExpandedRows = [:]
        if scope == .expanded {
            matches = rows.map { row in
                searchExpandedRows[row.item.id] = row.id
                var ancestors = base
                for count in 1..<row.id.path.count {
                    if let parent = tree.rowByID[.init(path: Array(row.id.path.prefix(count)))] {
                        ancestors.append(.init(id: parent.item.id, name: parent.item.name))
                    }
                }
                return .init(item: NativeSearchSource.searchItem(row.item), ancestors: ancestors, score: 0, sourceName: kind.title)
            }
        }
        let factory: FileSearchScanFactory = { onEvent, onFinish in
            let token = UUID(), completion = NativeSearchCompletion()
            let scan = NativeFileSearch.scanFactory(rootID: provider.root.id) { folderID, offset in
                try await source.page(folderID: folderID, offset: offset, token: token)
            }
            return scan({ event in
                if event.event == "finished" && event.progress.failedFolders == 0 {
                    completion.store(Task { await source.finish(token: token); onEvent(event) })
                } else { onEvent(event) }
            }, { code, diagnostic in
                Task { await completion.wait(); onFinish(code, diagnostic) }
            })
        }
        closePreview()
        fileSearch.presentNative(scope: scope, contextID: searchContext.uuidString,
            contextName: scope == .expanded ? "Browser · \(location.url?.path ?? location.title)" : provider.root.url?.path ?? provider.root.title,
            sourceName: kind.title, symbol: kind.symbol, expandedItems: matches, scanFactory: factory)
        return true
    }
    func revealFileSearch(_ navigation: FileSearchNavigation) {
        guard !closed, let source = searchSource, let provider, source.provider === provider else { return }
        cancelSearchReveal()
        if navigation.scope == .expanded {
            guard let id = searchExpandedRows[navigation.match.item.id], let row = tree.rowByID[id], visibleIndex(of: id) != nil else {
                error = "This item is no longer visible. Search the current expanded items again."; return
            }
            section = 0; select(row, extending: false, toggling: false, requestsPreview: false)
            return
        }
        let context = searchContext, request = UUID(); searchRevealID = request
        searchRevealTask = Task { [weak self] in
            guard let self else { return }
            defer { self.finishSearchReveal(request) }
            do {
                let (target, ancestors, siblings) = try await source.navigation(navigation)
                if let disk = provider as? ICloudDriveProvider { try await self.checkAvailability(disk) }
                try Task.checkCancellation()
                guard !self.closed, self.searchContext == context, self.searchRevealID == request, self.provider === provider else { return }
                self.cancelBookmarkNavigation(); self.folderThumbnails.cancel(); self.closePreview()
                self.loadTask?.cancel(); self.loadID = UUID()
                self.query = ""; self.fileTypeFilter = .all; self.section = 0
                self.history = [provider.root] + ancestors.map(\.location)
                self.items = []; self.selection = []; self.selectionAnchor = nil; self.selectionCursor = nil
                self.tree.reset(provider: provider)
                if !navigation.hasLoadedDirectory {
                    self.finishSearchReveal(request)
                    self.pendingSimilarityRevealID = target.id; self.reload(); return
                }
                self.searchRevealLoadingID = request; self.isLoading = true
                while true {
                    let mode = self.sortMode, direction = self.browserSortDirection
                    let sorted = await Task.detached(priority: .userInitiated) { NativeDriveTree.sorted(siblings, by: mode, direction: direction) }.value
                    try Task.checkCancellation()
                    guard !self.closed, self.searchContext == context, self.searchRevealID == request, self.provider === provider else { return }
                    if mode != self.sortMode || direction != self.browserSortDirection { continue }
                    let published = await self.tree.replaceRootsPrepared(sorted) {
                        self.searchContext == context && self.searchRevealID == request && self.provider === provider
                            && self.sortMode == mode && self.browserSortDirection == direction
                    }
                    guard self.searchContext == context, self.searchRevealID == request, self.provider === provider else { return }
                    if mode != self.sortMode || direction != self.browserSortDirection { continue }
                    guard published else { return }
                    self.items = sorted; self.total = sorted.count
                    break
                }
                self.nextOffset = navigation.nextPageToken.flatMap(Int.init); self.error = nil
                self.finishSearchReveal(request)
                if let row = self.visibleRows.first(where: { $0.item.id == target.id }) {
                    self.select(row, extending: false, toggling: false, requestsPreview: false)
                } else { self.pendingSimilarityRevealID = target.id; self.reload(append: self.nextOffset != nil) }
            } catch {
                guard self.searchContext == context, self.searchRevealID == request, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
    }

    /// Navigate to the file’s original container, then select it after all
    /// needed pages arrive. Photos uses the complete library collection.
    @discardableResult
    func revealSimilarityFile(_ file: SimilarityFile, using capturedProvider: (any NativeCloudDrive)? = nil,
                              scannedItem: CloudDriveItem? = nil) -> Bool {
        guard !closed else { error = "This drive window has closed."; return false }
        guard var provider = capturedProvider ?? provider ?? (kind == .local ? similarityProvider : nil) else {
            error = "Reconnect \(kind.title) to browse this file."; return false
        }
        do {
            let item: CloudDriveItem
            if capturedProvider != nil || scannedItem != nil {
                guard capturedProvider != nil, let scannedItem, provider.kind == kind, file.cloudId == nil,
                      scannedItem.id == file.id, !scannedItem.isFolder,
                      scannedItem.bytes == nil || scannedItem.bytes == file.bytes,
                      file.nativeRevision == nil || scannedItem.revision == file.nativeRevision else {
                    throw CloudDriveError.message("This original no longer matches the reviewed result. Scan its location again.")
                }
                if kind == .photos {
                    guard scannedItem.url == nil, file.localPath == nil else {
                        throw CloudDriveError.message("This original no longer matches the reviewed result. Scan its location again.")
                    }
                } else {
                    guard let expected = file.localPath.map({ URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() }),
                          scannedItem.url?.standardizedFileURL.resolvingSymlinksInPath() == expected else {
                        throw CloudDriveError.message("This original no longer matches the reviewed result. Scan its location again.")
                    }
                }
                item = scannedItem
            } else if let known = scanItemsByID[file.id] { item = known }
            else if kind != .photos, let path = file.localPath {
                item = try ICloudDriveProvider.item(URL(fileURLWithPath: path))
            } else { throw CloudDriveError.message("This file is no longer available in this scan’s drive.") }
            if kind != .photos && capturedProvider == nil {
                // The folder picker can scan another disk without reconnecting
                // Browser. Only navigate there when a result is explicitly revealed.
                if kind == .local, scanItemsByID[file.id] != nil,
                   let scanProvider = similarityProvider, let folder = item.url?.deletingLastPathComponent(),
                   let scanRoot = scanProvider.root.url,
                   folder == scanRoot || folder.path.hasPrefix(scanRoot.path == "/" ? "/" : scanRoot.path + "/") {
                    let isWithinBrowser = provider.root.url.map {
                        folder == $0 || folder.path.hasPrefix($0.path == "/" ? "/" : $0.path + "/")
                    } ?? false
                    if self.provider == nil || !isWithinBrowser {
                        provider = scanProvider
                    }
                }
            }
            func sameRoot(_ first: any NativeCloudDrive, _ second: any NativeCloudDrive) -> Bool {
                guard first.kind == second.kind else { return false }
                if let firstURL = first.root.url, let secondURL = second.root.url {
                    return firstURL.standardizedFileURL.resolvingSymlinksInPath() == secondURL.standardizedFileURL.resolvingSymlinksInPath()
                }
                return first.root.url == nil && second.root.url == nil && first.root.id == second.root.id
            }
            let changesRoot = self.provider.map { !sameRoot($0, provider) } ?? true
            guard !changesRoot || !isBusy else {
                throw CloudDriveError.message("Finish or cancel this drive’s active work before browsing another scan location.")
            }
            if !changesRoot, let current = self.provider { provider = current }
            let locations: [CloudDriveLocation]
            if kind == .photos {
                locations = [provider.root, .init(id: "photos:all", title: "All Photos & Videos")]
            } else {
                guard let folder = item.url?.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath(),
                      let root = provider.root.url?.standardizedFileURL.resolvingSymlinksInPath() else { throw CloudDriveError.message("This file has no containing folder.") }
                let prefix = root.path == "/" ? "/" : root.path + "/"
                guard folder == root || folder.path.hasPrefix(prefix) else {
                    throw CloudDriveError.message("This file is outside the selected folder. Choose its disk or parent folder first.")
                }
                var route = [provider.root], cursor = root
                let suffix = folder == root ? "" : String(folder.path.dropFirst(prefix.count))
                for component in suffix.split(separator: "/") {
                    cursor.appendPathComponent(String(component), isDirectory: true)
                    route.append(.init(id: cursor.absoluteString, title: String(component), url: cursor))
                }
                locations = route
            }
            if changesRoot {
                cancelAvailability(); cancelBookmarkNavigation(); cancelBookmarkWrites()
                folderThumbnails.cancel(); closePreview(); mediaPreview.clear()
                self.provider = provider
            }
            fileTypeFilter = .all; history = locations
            section = 0; resetLocation(); pendingSimilarityRevealID = item.id
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func findSimilar(_ selected: [CloudDriveItem]? = nil, exactOnly: Bool = false, presentWindow: Bool = true) {
        guard let provider else { return }
        let selected = selected ?? selectedItems
        if !exactOnly, presentWindow, let presentAcrossDriveSimilarity {
            presentAcrossDriveSimilarity(selected, provider, location); return
        }
        configureSimilarity(selected, provider: provider, location: location,
                            exactOnly: exactOnly, presentWindow: presentWindow)
    }

    private func chooseSimilarityDriveFolder() {
        guard !similarityScopeIsLocked else { return }
        guard let provider else { similarity.local.error = "Connect \(kind.title) in Settings → Drives to choose a scan location."; return }
        let session = similarity.local.sessionID
        similarity.scopePicker = SimilarityScopePicker(title: kind == .photos ? "Choose an Album or Library" : "Choose an iCloud Folder",
            prompt: kind == .photos ? "Use Location" : "Use Folder", root: provider.root,
            load: { folder, token in
                if provider.kind == .photos && folder.id != provider.root.id { return .init(folders: []) }
                let page = try await provider.list(folder, offset: token.flatMap(Int.init) ?? 0, search: "")
                return .init(folders: page.items.filter { $0.isFolder && !$0.name.hasPrefix(".") }.map(\.location),
                             nextPage: page.nextOffset.map(String.init))
            }, accept: { [weak self] route in
                guard let self, !self.similarityScopeIsLocked, self.similarity.local.sessionID == session, let folder = route.last else { return }
                self.configureSimilarity([], provider: provider, location: folder, exactOnly: self.similarity.duplicatesOnly, presentWindow: false)
                self.similarity.local.error = nil
            })
    }

    private func chooseSimilarityFolder() {
        guard kind == .local, !similarityScopeIsLocked else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder to Scan"; panel.prompt = "Use Folder"
        panel.message = "Compare files in this folder and its subfolders. Your Browser location stays the same."
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = similarityScopeProvider?.root.url ?? location.url
        let sessionID = similarity.local.sessionID
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                guard let self, self.similarity.local.sessionID == sessionID else { return }
                self.useSimilarityFolder(url)
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    /// Apply only an accepted picker choice. A nil/cancelled choice is a no-op.
    func useSimilarityFolder(_ url: URL?) {
        guard kind == .local, !similarityScopeIsLocked, let url else { return }
        do {
            guard url.isFileURL else { throw CloudDriveError.message("Choose a folder on this Mac or an external disk.") }
            let scanProvider = ICloudDriveProvider(rootURL: url, kind: .local)
            guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw CloudDriveError.message("Choose a folder to scan.")
            }
            configureSimilarity([], provider: scanProvider, location: scanProvider.root,
                                exactOnly: similarity.duplicatesOnly, presentWindow: false)
            similarity.local.error = nil
        } catch { similarity.local.error = error.localizedDescription }
    }

    private func configureSimilarity(_ selected: [CloudDriveItem], provider: any NativeCloudDrive,
                                     location: CloudDriveLocation, exactOnly: Bool, presentWindow: Bool, photosUsePreviews: Bool = true) {
        guard !similarityScopeIsLocked else { if presentWindow { similarity.present(source: .local) }; return }
        similarityScopeProvider = provider
        similarity.local.nativeScope = SimilarityNativeScope(drive:provider.kind,providerRoot:provider.root,
            location:location,selection:selected,bookmark:provider.root.url.flatMap { try? $0.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil) })
        similarity.local.externalScopeNames = selected.isEmpty ? [location.url?.path ?? location.title]
            : selected.map { $0.url?.path ?? $0.name }
        similarity.local.exactDuplicates = true
        similarity.duplicatesOnly = exactOnly
        similarity.local.externalDuplicatesOnly = exactOnly
        similarity.local.configurePhotosPreviews(supported: provider.supportsSimilarityPreviews && SimilarityScanModel.visualSimilarityAvailable, enabled: photosUsePreviews)
        similarity.local.exactDuplicates = !similarity.local.usesPhotosPreviews
        similarity.local.inventoryExternalSources = nil
        similarity.local.streamExternalSources = nil
        similarity.local.resolveExternalSource = nil
        similarity.local.resolveExternalMemorySource = nil
        if !exactOnly {
            similarity.local.prepareExternalScope = nil
            similarity.local.streamExternalSources = { [weak self] emit in
                guard let self else { throw CancellationError() }
                self.similarityProvider = provider
                self.preparationIssues = []
                var lastProgress = Date(), seen = Set<String>()
                for try await item in provider.scanItemStream(selected, location: location, progress: { _ in }) {
                    try Task.checkCancellation()
                    guard !item.name.hasPrefix("."), seen.insert(item.id).inserted else { continue }
                    self.scanItemsByID[item.id] = item
                    if let url = item.url { self.scanItemsByPath[url.standardizedFileURL.path] = item }
                    try await emit(.init(id: item.id, name: item.name,
                        path: item.url?.path ?? "\(provider.kind.title)/\(location.title)/\(item.name)",
                        size: item.bytes ?? 0, localPath: provider.kind == .photos ? nil : item.url?.path,
                        revision:item.revision,
                        contentKind:self.similarity.local.usesPhotosPreviews ? PhotosSimilarityPreview.contentKind : nil))
                    if seen.count == 1 || Date().timeIntervalSince(lastProgress) > 0.25 {
                        self.similarity.local.recordDiscovery(found: seen.count)
                        lastProgress = Date()
                    }
                }
                self.scanItemsByID = self.scanItemsByID.filter { seen.contains($0.key) }
                self.scanItemsByPath = self.scanItemsByPath.filter { seen.contains($0.value.id) }
                self.similarity.local.recordDiscovery(found: seen.count, complete: true)
            }
            similarity.local.inventoryExternalSources = { [weak self] in
                guard let self else { throw CancellationError() }
                self.similarityProvider = provider
                self.scanItemsByPath = [:]; self.scanItemsByID = [:]; self.preparationIssues = []
                let handler: CloudDriveProgressHandler = { [weak self] value in
                    Task { @MainActor in self?.similarity.local.externalProgress(value) }
                }
                let items = try await provider.scanItems(selected, location: location, progress: handler)
                    .filter { !$0.name.hasPrefix(".") }
                try Task.checkCancellation()
                var sources: [SimilarityExternalSource] = []
                for item in items where self.scanItemsByID[item.id] == nil {
                    self.scanItemsByID[item.id] = item
                    if let url = item.url { self.scanItemsByPath[url.standardizedFileURL.path] = item }
                    sources.append(.init(id: item.id, name: item.name,
                        path: item.url?.path ?? "\(provider.kind.title)/\(location.title)/\(item.name)",
                        size: item.bytes ?? 0, localPath: provider.kind == .photos ? nil : item.url?.path,
                        revision:item.revision,
                        contentKind:self.similarity.local.usesPhotosPreviews ? PhotosSimilarityPreview.contentKind : nil))
                }
                return sources
            }
            // The captured scan mode chooses the Photos representation. All
            // Photos content uses the RAM pipe and retains its original asset ID.
            similarity.local.resolveExternalMemorySource = { [weak self] id, pipe, capacity, progress in
                guard let self, let item = self.scanItemsByID[id] else { throw CancellationError() }
                if self.similarity.local.usesPhotosPreviews {
                    let bytes = try await provider.previewForSimilarity(item, progress: progress)
                    guard bytes.count <= PhotosSimilarityPreview.maximumBytes else { throw CocoaError(.fileReadTooLarge) }
                    guard UInt64(bytes.count) <= capacity else { throw PhotosMemoryCapacityExceeded(requiredBytes: UInt64(bytes.count)) }
                    try await CloudDriveFiles.detached {
                        let handle = try SimilarityMemoryPipe.open(pipe)
                        defer { try? handle.close() }
                        try SimilarityMemoryPipe.write(bytes, to: handle)
                    }
                    return pipe
                }
                return try await provider.streamForSimilarity(item, pipe: pipe, capacity: capacity, progress: progress)
            }
            similarity.local.resolveExternalSource = { [weak self] id, directory, progress in
                guard let self, let item = self.scanItemsByID[id] else { throw CancellationError() }
                try Task.checkCancellation()
                return try await provider.materialize(item, directory: directory, progress: progress)
            }
        } else {
        similarity.local.prepareExternalScope = { [weak self] in
            guard let self else { throw CancellationError() }
            self.similarityProvider = provider
            let directory = self.temporaryRoot.appendingPathComponent("Scan/\(UUID().uuidString)")
            try CloudDriveFiles.privateDirectory(directory); self.scanDirectory = directory
            self.scanItemsByPath = [:]; self.scanItemsByID = [:]; self.preparationIssues = []
            let handler: CloudDriveProgressHandler = { [weak self] value in Task { @MainActor in self?.similarity.local.externalProgress(value) } }
            // Filter original names before Photos exports/renames an asset or
            // iCloud downloads its contents for analysis.
            let items = try await provider.scanItems(selected, location: location, progress: handler)
                .filter { !$0.name.hasPrefix(".") }
            for (index, item) in items.enumerated() {
                try Task.checkCancellation()
                let total = items.count
                let fileProgress: CloudDriveProgressHandler = { [weak self] value in
                    Task { @MainActor in
                        self?.similarity.local.externalProgress(.init(message: item.name, completed: index, total: total,
                            bytes: value.bytes, fileSize: item.bytes ?? 0))
                    }
                }
                self.similarity.local.externalProgress(.init(message: item.name, completed: index, total: total))
                do {
                    let url = try await provider.materialize(item, directory: directory, progress: fileProgress)
                    let path = url.standardizedFileURL.resolvingSymlinksInPath().path
                    self.scanItemsByPath[path] = item; self.scanItemsByPath[url.standardizedFileURL.path] = item; self.scanItemsByID[item.id] = item
                } catch {
                    if Task.isCancelled || error is CancellationError { throw CancellationError() }
                    self.preparationIssues.append(.init(path: item.name, reason: error.localizedDescription))
                }
                self.similarity.local.externalProgress(.init(message: item.name, completed: index + 1, total: total))
            }
            // Scan a directory root for Photos, even for very large albums.
            if provider.kind == .photos {
                guard items.isEmpty || !self.scanItemsByID.isEmpty else { throw CloudDriveError.message("No originals could be prepared. \(self.preparationIssues.first?.reason ?? "Choose a different scope.")") }
                return [directory]
            }
            return selected.isEmpty ? [location.url].compactMap { $0 } : selected.compactMap(\.url)
        }
        }
        similarity.local.transformExternalReport = { [weak self] report in
            guard let self else { return report }
            for file in report.files ?? [] where self.scanItemsByID[file.id] == nil {
                self.scanItemsByID[file.id] = self.similarityItem(file)
            }
            let itemsByPath = self.scanItemsByPath, itemsByID = self.scanItemsByID, kind = self.kind
            var mappedFiles: [String: SimilarityFile] = [:]
            func mapped(_ file: SimilarityFile) -> SimilarityFile {
                if let cached = mappedFiles[file.id] { return cached }
                let item = itemsByID[file.id] ?? itemsByPath[URL(fileURLWithPath: file.localPath ?? file.path, isDirectory: false).standardizedFileURL.path]
                guard let item else { return file }
                let mapped = SimilarityFile(id: item.id, name: item.name, path: item.url?.path ?? "\(kind.title)/\(location.title)/\(item.name)", bytes: file.bytes,
                    family: file.family, localPath: kind != .photos ? item.url?.path : nil, cloudId: nil, ancestors: [],
                    engineIndex: file.engineIndex, engineId: file.scoreID, state: file.state, nativeRevision: file.nativeRevision ?? item.revision)
                mappedFiles[file.id] = mapped
                return mapped
            }
            let groups = report.groups.filter { !exactOnly || $0.isExact }.map { group in
                SimilarityGroup(id: group.id, matchKind: group.matchKind, family: group.family, minimumScore: group.minimumScore,
                    memberCount: group.memberCount, members: group.members.map(mapped))
            }
            let issues = self.preparationIssues + report.issues.map { issue in
                let path = URL(fileURLWithPath: issue.path).standardizedFileURL.resolvingSymlinksInPath().path
                return SimilarityIssue(path: self.scanItemsByPath[path]?.name ?? (self.kind == .photos ? "Photos asset" : issue.path), reason: issue.reason)
            }
            var summary = report.issueSummary
            if summary != nil {
                for issue in self.preparationIssues {
                    if let index = summary!.firstIndex(where: { $0.category == "failed" && $0.reason == issue.reason }) {
                        let previous = summary![index]
                        summary![index] = SimilarityIssueSummary(category: "failed", reason: previous.reason, count: previous.count + 1)
                    } else { summary!.append(SimilarityIssueSummary(category: "failed", reason: issue.reason, count: 1)) }
                }
            }
            return SimilarityReport(source: report.source, scope: self.similarity.local.externalScopeNames, status: self.preparationIssues.isEmpty || ["cancelled", "finished"].contains(report.status) ? report.status : "partial",
                threshold: report.threshold, scannedFiles: max(report.scannedFiles, self.similarity.local.progress.foundFiles), analysedFiles: report.analysedFiles,
                skippedFiles: report.skippedFiles + UInt64(self.preparationIssues.count), downloadedBytes: report.downloadedBytes,
                totalGroups: report.totalGroups, groups: groups,
                issues: Array(issues.prefix(500)), truncated: report.truncated || issues.count > 500,
                coverage: (self.preparationIssues.isEmpty ? "" : "Some originals could not be prepared. ") + report.coverage, elapsedSeconds: report.elapsedSeconds,
                files: report.files?.map(mapped), runId: report.runId, resultRevision: report.resultRevision, scoresRetained: report.scoresRetained,
                unsupportedFiles: report.unsupportedFiles, failedFiles: report.failedFiles.map { $0 + UInt64(self.preparationIssues.count) }, issueSummary: summary)
        }
        similarity.local.takeExternalScopeCleanup = { [weak self] in
            guard let directory = self?.scanDirectory else { return nil }
            self?.scanDirectory = nil
            return { try? FileManager.default.removeItem(at: directory) }
        }
        if presentWindow { similarity.present(source: .local) }
    }
    private var similarityScopeIsLocked: Bool {
        similarity.local.isRunning || similarity.local.isPausing || similarity.local.retainsOriginalsInRAM
    }
    /// A folder shows a spinner while it is measured, and so does any unsized folder below it,
    /// because the same walk is about to size them.
    func isMeasuringSize(_ row: NativeDriveRow) -> Bool {
        guard row.item.isFolder, !measuringIDs.isEmpty else { return false }
        if measuringIDs[row.item.id] != nil { return true }
        return row.item.bytes == nil && row.id.path.dropLast().contains { measuringIDs[$0] != nil }
    }
    func measure(_ items: [CloudDriveItem]) {
        let items = operationItems(items), location = location, directory = temporaryRoot.appendingPathComponent("Measure/\(UUID().uuidString)")
        let ids = items.map(\.id)
        for id in ids { measuringIDs[id, default: 0] += 1 }
        // A completion handler replaces run's own error banner, so failures are reported here.
        run("Recalculate size", completion: { [weak self] result in
            guard let self else { return }
            for id in ids {
                if let count = self.measuringIDs[id], count > 1 { self.measuringIDs[id] = count - 1 } else { self.measuringIDs[id] = nil }
            }
            if case .failure(let error) = result, !(error is CancellationError) { self.error = error.localizedDescription }
        }) { [weak self] provider, progress in
            defer { try? FileManager.default.removeItem(at: directory) }
            // The provider walks and sums off the main actor; only the totals return here.
            let total = try await provider.measureFiles(items, location: location, directory: directory, progress: progress)
            if let self {
                var sizes = total.folders
                // Drives without folders report one total, which belongs to the single selected item.
                if items.count == 1, sizes[items[0].id] == nil { sizes[items[0].id] = total.bytes }
                for index in self.items.indices { if let bytes = sizes[self.items[index].id] { self.items[index].bytes = bytes } }
                self.tree.updateSizes(sizes); self.tree.replaceRoots(self.items)
            }
            progress(.init(message: "\(total.files.formatted()) files · \(SimilarityScanProgress.bytes(total.bytes))",
                           completed: total.files, total: total.files))
            return nil
        }
    }
    var resourceActivities: [Int32: TaskResourceActivity] {
        guard let pid = similarity.local.processIdentifier else { return [:] }
        return [pid: .init(name: "Finding similar files · \(kind.title)", detail: similarity.local.message + "\n" + similarity.local.detail,
            symbol: "doc.text.magnifyingglass", processing: similarity.local.resourceProcessing)]
    }
    func close() {
        closed = true; isLoading = false
        resetFileSearch()
        cancelAvailability(); cancelBookmarkNavigation(); cancelBookmarkWrites()
        diskTrashLoad?.cancel(); diskTrashLoad = nil; diskTrashLoadID = UUID()
        folderThumbnails.cancel()
        for observer in volumeObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        volumeObservers = []
        loadTask?.cancel(); loadID = UUID(); tree.reset(provider: nil)
        transferControls.values.forEach { $0.cancel() }
        jobs.values.forEach { $0.cancel() }; closePreview(); mediaPreview.clear(); similarity.close(preservingScans:true)
        // Operations remove their staging area after cancellation. Do not remove
        // a directory underneath a writer that has not stopped yet.
    }
}

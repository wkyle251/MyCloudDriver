import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

struct CloudDriveActivityRecord: Identifiable {
    let id: UUID
    let title: String
    var progress: CloudDriveProgress
    var state = "Running"
    var active: Bool { state == "Running" || state == "Stopping" }
}

@MainActor final class CloudDriveActivityStore: ObservableObject {
    @Published var records: [CloudDriveActivityRecord] = []
    var active: [CloudDriveActivityRecord] { records.filter(\.active) }
    var latest: CloudDriveActivityRecord? { active.last ?? records.last }
    func begin(_ title: String) -> UUID {
        let id = UUID(); records.append(.init(id: id, title: title, progress: .init(message: title)))
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

@MainActor final class NativeDriveModel: ObservableObject {
    let kind: CloudDriveKind
    let activity = CloudDriveActivityStore()
    let similarity = FileSimilarityCoordinator(activity: FinderTaskActivityStore())
    @Published private(set) var provider: (any NativeCloudDrive)?
    @Published private(set) var history: [CloudDriveLocation] = []
    @Published private(set) var items: [CloudDriveItem] = []
    @Published var selection: Set<String> = []
    @Published var query = ""
    @Published var section = 0
    @Published var viewMode = 0
    @Published var zoom = 1.0
    @Published private(set) var isLoading = false
    @Published private(set) var isMutating = false
    @Published private(set) var total = 0
    @Published private(set) var nextOffset: Int?
    @Published var error: String?
    @Published private(set) var undoStack: [CloudDriveUndo] = []
    @Published private(set) var redoStack: [CloudDriveUndo] = []
    var location: CloudDriveLocation { history.last ?? .init(id: "", title: kind.title) }
    var selectedItems: [CloudDriveItem] { items.filter { selection.contains($0.id) } }
    var isConnected: Bool { provider != nil }
    var isBusy: Bool { isMutating || !jobs.isEmpty || similarity.local.isRunning }
    var scanConfiguration: (() throws -> SimilarityConfiguration)?
    var onSendToPikPak: (([URL]) -> Void)?
    private var loadTask: Task<Void, Never>?
    private var loadID = UUID()
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private let quickLook = QuickLookPreviewCoordinator()
    private var previewTask: Task<Void, Never>?
    private var previewID = UUID()
    private var scanItemsByPath: [String: CloudDriveItem] = [:]
    private var scanItemsByID: [String: CloudDriveItem] = [:]
    private var preparationIssues: [SimilarityIssue] = []
    private var scanDirectory: URL?
    private var previewCache: [String: URL] = [:]
    private var previewOrder: [String] = []
    private var openCache: [String: URL] = [:]
    private var sortMode = 0
    private var selectionAnchor: String?
    private let temporaryRoot: URL

    init(kind: CloudDriveKind, temporaryRoot: URL? = nil) {
        self.kind = kind
        self.temporaryRoot = temporaryRoot ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("MyCloudDriver-\(kind.rawValue)-\(UUID().uuidString)", isDirectory: true)
        similarity.externalTitle = kind.title; similarity.externalSymbol = kind.symbol
        similarity.source = .local; similarity.local.externalTitle = kind.title
        similarity.local.onRunningChanged = { [weak self] in self?.objectWillChange.send() }
        similarity.configuration = { [weak self] _ in
            guard let self, let configuration = self.scanConfiguration else { throw CocoaError(.fileNoSuchFile) }
            return try configuration()
        }
        similarity.openExternalFile = { [weak self] file in
            guard let self, let item = self.scanItemsByID[file.id] else { return }
            self.open(item)
        }
        similarity.preparePreview = { [weak self] file, directory in
            guard let self, let provider = self.provider, let item = self.scanItemsByID[file.id] else {
                throw CloudDriveError.message("This item is no longer available in the connected drive.")
            }
            return try await provider.materialize(item, directory: directory, progress: { _ in })
        }
        quickLook.onClose = { [weak self] in self?.closePreview() }
        quickLook.onMove = { [weak self] offset in self?.movePreview(offset) }
        quickLook.onRetry = { [weak self] in self?.previewSelection() }
    }
    func connect(_ provider: any NativeCloudDrive) {
        guard !isBusy else { error = "Finish or cancel this drive’s active work before reconnecting."; return }
        closePreview(); self.provider = provider; history = [provider.root]; query = ""; undoStack = []; redoStack = []
        items = []; selection = []; total = 0; nextOffset = nil
        similarity.local.clearAccount(); similarity.local.localURLs = []; similarity.local.externalScopeNames = []
        scanItemsByPath = [:]; scanItemsByID = [:]
        reload()
    }
    func disconnect() {
        guard !isBusy else { error = "Finish or cancel this drive’s active work before disconnecting."; return }
        loadTask?.cancel(); closePreview(); provider = nil; history = []; items = []; selection = []
        total = 0; nextOffset = nil; undoStack = []; redoStack = []
        similarity.local.clearAccount(); similarity.local.localURLs = []; similarity.local.externalScopeNames = []
        scanItemsByPath = [:]; scanItemsByID = [:]
    }
    func reload(append: Bool = false) {
        guard let provider else { return }
        loadTask?.cancel(); let id = UUID(); loadID = id
        let location = location, query = query, offset = append ? nextOffset ?? 0 : 0
        isLoading = true; error = nil
        loadTask = Task { [weak self] in
            do {
                if !query.isEmpty { try await Task.sleep(nanoseconds: 180_000_000) }
                let page = try await provider.list(location, offset: offset, search: query)
                try Task.checkCancellation()
                guard let self, self.loadID == id else { return }
                if append {
                    let existing = Set(self.items.map(\.id)); self.items.append(contentsOf: page.items.filter { !existing.contains($0.id) })
                } else { self.items = page.items }
                if self.sortMode != 0 { self.sort(by: self.sortMode) }
                self.selection.formIntersection(Set(self.items.map(\.id)))
                self.total = page.total; self.nextOffset = page.nextOffset; self.isLoading = false
            } catch {
                guard let self, self.loadID == id, !Task.isCancelled else { return }
                self.error = error.localizedDescription; self.isLoading = false
            }
        }
    }
    func enter(_ item: CloudDriveItem) {
        guard item.isFolder else { open(item); return }
        closePreview(); history.append(item.location); selection = []; query = ""; items = []; reload()
    }
    func back() { guard history.count > 1 else { return }; closePreview(); history.removeLast(); query = ""; items = []; selection = []; reload() }
    func root() { guard let root = provider?.root else { return }; history = [root]; query = ""; items = []; selection = []; reload() }
    func contextSelection(_ ids: Set<String>) -> [CloudDriveItem] { items.filter { ids.contains($0.id) } }

    func sort(by mode: Int) {
        sortMode = mode
        let current = items, generation = loadID
        Task {
            let sorted = await Task.detached(priority: .userInitiated) { Self.sorted(current, by: mode) }.value
            guard loadID == generation, sortMode == mode else { return }; items = sorted
        }
    }
    private nonisolated static func sorted(_ items: [CloudDriveItem], by mode: Int) -> [CloudDriveItem] {
        items.sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            if mode == 1, $0.modified != $1.modified { return ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
            if mode == 2, $0.bytes != $1.bytes { return ($0.bytes ?? 0) > ($1.bytes ?? 0) }
            return $0.name == $1.name ? $0.id < $1.id : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
    func select(_ item: CloudDriveItem, extending: Bool, toggling: Bool) {
        if extending, let anchor = selectionAnchor, let a = items.firstIndex(where: { $0.id == anchor }), let b = items.firstIndex(where: { $0.id == item.id }) {
            selection = Set(items[min(a, b)...max(a, b)].map(\.id))
        } else if toggling {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }; selectionAnchor = item.id
        } else { selection = [item.id]; selectionAnchor = item.id }
    }
    func moveSelection(_ offset: Int) {
        guard !items.isEmpty else { return }
        let current = selectedItems.first.flatMap { selected in items.firstIndex(where: { $0.id == selected.id }) } ?? -1
        selection = [items[min(items.count - 1, max(0, current + offset))].id]
    }

    @discardableResult
    func run(_ title: String, mutating: Bool = false, _ operation: @escaping (any NativeCloudDrive, @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo?) -> UUID? {
        guard let provider else { return nil }
        guard !mutating || !isMutating else { error = "Wait for the current file change to finish."; return nil }
        let id = activity.begin(title)
        objectWillChange.send()
        if mutating { isMutating = true }
        let handler: CloudDriveProgressHandler = { [weak activity] value in Task { @MainActor in activity?.update(id, value) } }
        jobs[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.objectWillChange.send(); self.jobs[id] = nil; if mutating { self.isMutating = false; self.reload() } }
            do {
                let undo = try await operation(provider, handler)
                if let undo { self.undoStack.append(undo); self.redoStack = [] }
                self.activity.finish(id)
            } catch {
                self.activity.finish(id, error: error)
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
        return id
    }
    func cancel(_ id: UUID) {
        if let index = activity.records.firstIndex(where: { $0.id == id && $0.active }) { activity.records[index].state = "Stopping" }
        jobs[id]?.cancel()
    }
    func undo(redo: Bool = false) {
        guard !isMutating, let operation = redo ? redoStack.last : undoStack.last else { return }
        let id = activity.begin((redo ? "Redo " : "Undo ") + operation.title); isMutating = true
        jobs[id] = Task {
            defer { jobs[id] = nil; isMutating = false; reload() }
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
    func delete(_ items: [CloudDriveItem]) {
        closePreview(); run(kind == .photos ? "Delete from Photos" : "Move to Trash", mutating: true) { provider, progress in try await provider.delete(items, progress: progress) }
    }
    func relocate(_ items: [CloudDriveItem], from source: CloudDriveLocation? = nil, to destination: CloudDriveLocation, copy: Bool) {
        let source = source ?? location
        run(copy ? "Copy" : "Move", mutating: true) { provider, progress in try await provider.relocate(items, from: source, to: destination, copy: copy, progress: progress) }
    }
    func importFiles(_ urls: [URL], into destination: CloudDriveLocation? = nil) {
        guard provider != nil, !isMutating else { error = "Wait for the current file change to finish."; return }
        let location = destination ?? location
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        run("Import files", mutating: true) { provider, progress in
            defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
            return try await provider.importFiles(urls, into: location, progress: progress)
        }
    }
    func chooseImport() {
        let destination = location, rootID = provider?.root.id
        let panel = NSOpenPanel(); panel.title = kind == .photos ? "Import into Apple Photos" : "Import into iCloud Drive"
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            if response == .OK { Task { @MainActor in
                guard let self, self.provider?.root.id == rootID else { return }
                self.importFiles(panel.urls, into: destination)
            } }
        }
    }
    func export(_ items: [CloudDriveItem], to destination: URL) {
        let location = location, temp = temporaryRoot.appendingPathComponent("Exports/\(UUID().uuidString)")
        run("Export files") { provider, progress in
            let scoped = destination.startAccessingSecurityScopedResource(); defer { if scoped { destination.stopAccessingSecurityScopedResource() }; try? FileManager.default.removeItem(at: temp) }
            if provider.kind == .icloud {
                for (index, item) in items.enumerated() {
                    guard let url = item.url else { continue }
                    try await CloudDriveFiles.detached { try ICloudDriveProvider.copy(url, to: destination.appendingPathComponent(item.name), progress: progress) }
                    progress(.init(message: "Exporting files", completed: index + 1, total: items.count))
                }
            } else {
                let files = try await provider.scanItems(items, location: location, progress: progress)
                for (index, file) in files.enumerated() {
                    try Task.checkCancellation()
                    let url = try await provider.materialize(file, directory: temp, progress: progress)
                    try await CloudDriveFiles.detached {
                        let target = CloudDriveFiles.availableName(file.name, in: destination)
                        try ICloudDriveProvider.copy(url, to: target, progress: progress)
                    }
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
    func open(_ item: CloudDriveItem, application: URL? = nil) {
        if item.isFolder { enter(item); return }
        // Copies handed to another app survive exit, like the PikPak Open flow.
        let directory = ((try? LocalCredentialStore.applicationSupportDirectoryURL()) ?? temporaryRoot)
            .appendingPathComponent("OpenFiles/\(kind.rawValue)")
        run("Open \(item.name)") { [weak self] provider, progress in
            let url: URL
            if let cached = self?.openCache[item.id], FileManager.default.fileExists(atPath: cached.path) { url = cached }
            else {
                url = try await provider.materialize(item, directory: directory, progress: progress)
                if provider.kind == .photos { self?.openCache[item.id] = url }
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
    func selectionChanged() { if quickLook.isActive { previewSelection() } }
    private func previewSelection() {
        guard let item = selectedItems.first, let provider else { closePreview(); return }
        previewTask?.cancel(); let generation = UUID(); previewID = generation
        if item.isFolder { quickLook.showFolder(fileID: item.id, name: item.name); return }
        if let cached = previewCache[item.id], FileManager.default.fileExists(atPath: cached.path) {
            _ = quickLook.present(cached, name: item.name); return
        }
        _ = quickLook.showLoading(fileID: item.id, name: item.name)
        let folder = temporaryRoot.appendingPathComponent("QuickLook")
        previewTask = Task { [weak self] in
            do {
                let url = try await provider.materialize(item, directory: folder, progress: { _ in })
                guard let self, self.previewID == generation, !Task.isCancelled else {
                    if provider.kind == .photos { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                    return
                }
                if provider.kind == .photos {
                    self.previewCache[item.id] = url; self.previewOrder.removeAll { $0 == item.id }; self.previewOrder.append(item.id)
                    while self.previewOrder.count > 8 {
                        let oldest = self.previewOrder.removeFirst()
                        if let old = self.previewCache.removeValue(forKey: oldest) { try? FileManager.default.removeItem(at: old.deletingLastPathComponent()) }
                    }
                }
                _ = self.quickLook.present(url, name: item.name)
            } catch {
                guard let self, self.previewID == generation, !Task.isCancelled else { return }
                self.quickLook.showFailure(error.localizedDescription)
            }
        }
    }
    private func movePreview(_ offset: Int) {
        guard let id = selectedItems.first?.id, let index = items.firstIndex(where: { $0.id == id }) else { return }
        let next = min(max(index + offset, 0), items.count - 1)
        selection = [items[next].id]; previewSelection()
    }
    func closePreview() {
        previewID = UUID(); previewTask?.cancel(); previewTask = nil; quickLook.dismiss()
        if kind == .photos {
            for url in previewCache.values { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            previewCache = [:]; previewOrder = []
        }
    }

    func findSimilar(_ selected: [CloudDriveItem]? = nil, exactOnly: Bool = false, presentWindow: Bool = true) {
        guard let provider else { return }
        guard !similarity.local.isRunning else { if presentWindow { similarity.present(source: .local) }; return }
        let selected = selected ?? selectedItems, location = location
        similarity.local.externalScopeNames = selected.isEmpty ? [location.title] : selected.map(\.name)
        similarity.local.exactDuplicates = true
        similarity.local.includeHidden = false
        similarity.duplicatesOnly = exactOnly
        similarity.local.externalDuplicatesOnly = exactOnly
        similarity.local.prepareExternalScope = { [weak self] in
            guard let self else { throw CancellationError() }
            let directory = self.temporaryRoot.appendingPathComponent("Scan/\(UUID().uuidString)")
            try CloudDriveFiles.privateDirectory(directory); self.scanDirectory = directory
            self.scanItemsByPath = [:]; self.scanItemsByID = [:]; self.preparationIssues = []
            let handler: CloudDriveProgressHandler = { [weak self] value in Task { @MainActor in self?.similarity.local.externalProgress(value) } }
            let items = try await provider.scanItems(selected, location: location, progress: handler)
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
                guard !self.scanItemsByID.isEmpty else { throw CloudDriveError.message("No originals could be prepared. \(self.preparationIssues.first?.reason ?? "Choose a different scope.")") }
                return [directory]
            }
            return selected.isEmpty ? [location.url].compactMap { $0 } : selected.compactMap(\.url)
        }
        similarity.local.transformExternalReport = { [weak self] report in
            guard let self else { return report }
            let itemsByPath = self.scanItemsByPath, kind = self.kind
            func mapped(_ file: SimilarityFile) -> SimilarityFile {
                let path = URL(fileURLWithPath: file.localPath ?? file.path).standardizedFileURL.path
                guard let item = itemsByPath[path] else { return file }
                return SimilarityFile(id: item.id, name: item.name, path: item.url?.path ?? "\(kind.title)/\(location.title)/\(item.name)", bytes: file.bytes,
                    family: file.family, localPath: kind == .icloud ? item.url?.path : nil, cloudId: nil, ancestors: [],
                    engineIndex: file.engineIndex, engineId: file.scoreID, state: file.state)
            }
            let groups = report.groups.filter { !exactOnly || $0.isExact }.map { group in
                SimilarityGroup(id: group.id, matchKind: group.matchKind, family: group.family, minimumScore: group.minimumScore,
                    memberCount: group.memberCount, members: group.members.map(mapped))
            }
            let issues = self.preparationIssues + report.issues.map { issue in
                let path = URL(fileURLWithPath: issue.path).standardizedFileURL.resolvingSymlinksInPath().path
                return SimilarityIssue(path: self.scanItemsByPath[path]?.name ?? (self.kind == .photos ? "Photos asset" : issue.path), reason: issue.reason)
            }
            return SimilarityReport(source: report.source, scope: self.similarity.local.externalScopeNames, status: self.preparationIssues.isEmpty ? report.status : "partial",
                threshold: report.threshold, scannedFiles: report.scannedFiles, analysedFiles: report.analysedFiles,
                skippedFiles: report.skippedFiles + UInt64(self.preparationIssues.count), downloadedBytes: report.downloadedBytes,
                totalGroups: report.totalGroups, groups: groups,
                issues: Array(issues.prefix(500)), truncated: report.truncated || issues.count > 500,
                coverage: (self.preparationIssues.isEmpty ? "" : "Some originals could not be prepared. ") + report.coverage, elapsedSeconds: report.elapsedSeconds,
                files: report.files?.map(mapped), runId: report.runId, resultRevision: report.resultRevision, scoresRetained: report.scoresRetained)
        }
        similarity.local.cleanupExternalScope = { [weak self] in
            if let directory = self?.scanDirectory { try? FileManager.default.removeItem(at: directory); self?.scanDirectory = nil }
        }
        if presentWindow { similarity.present(source: .local) }
    }
    func measure(_ items: [CloudDriveItem]) {
        let location = location, directory = temporaryRoot.appendingPathComponent("Measure/\(UUID().uuidString)")
        run("Recalculate size") { [weak self] provider, progress in
            defer { try? FileManager.default.removeItem(at: directory) }
            let files = try await provider.scanItems(items, location: location, progress: progress)
            var size: UInt64 = 0
            for (index, file) in files.enumerated() {
                try Task.checkCancellation()
                if let bytes = file.bytes { size += bytes }
                else {
                    let url = try await provider.materialize(file, directory: directory, progress: progress)
                    size += UInt64(max(0, try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
                    if provider.kind == .photos { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                }
                progress(.init(message: "Calculating original size", completed: index + 1, total: files.count))
            }
            if items.count == 1, let index = self?.items.firstIndex(where: { $0.id == items[0].id }) { self?.items[index].bytes = size }
            progress(.init(message: "\(files.count.formatted()) files · \(SimilarityScanProgress.bytes(size))", completed: files.count, total: files.count))
            return nil
        }
    }
    var resourceActivities: [Int32: TaskResourceActivity] {
        guard let pid = similarity.local.processIdentifier else { return [:] }
        return [pid: .init(name: "Finding similar files · \(kind.title)", detail: similarity.local.message + "\n" + similarity.local.detail, symbol: "doc.text.magnifyingglass")]
    }
    func close() {
        loadTask?.cancel(); jobs.values.forEach { $0.cancel() }; closePreview(); similarity.close()
        // Operations remove their staging area after cancellation. Do not remove
        // a directory underneath a writer that has not stopped yet.
    }
}

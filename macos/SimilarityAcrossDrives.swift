import AppKit
import Combine
import SwiftUI

struct SimilarityAcrossDriveScope: Codable, Identifiable {
    let id: String
    let drive: CloudDriveKind
    let native: SimilarityNativeScope?
    let cloudRoots: [SimilarityCloudRoot]
    let accountID: UUID?

    var title: String {
        if let native {
            if !native.selection.isEmpty { return native.selection.map { $0.url?.path ?? $0.name }.joined(separator: ", ") }
            return native.location.url?.path ?? native.location.title
        }
        return cloudRoots.map { $0.path == "/" ? "All PikPak files" : $0.path }.joined(separator: ", ")
    }
}

/// Owns an immutable provider snapshot for each run. Browser navigation and a
/// later scope choice cannot redirect an existing result or its file actions.
@MainActor final class SimilarityAcrossDrives: ObservableObject {
    static let driveID = "across"
    let coordinator: FileSimilarityCoordinator
    @Published private(set) var scopes: [SimilarityAcrossDriveScope] = []
    private weak var hub: CloudDriveHub?
    private var runScopes: [SimilarityAcrossDriveScope] = []
    private var providers: [String: any NativeCloudDrive] = [:]
    private struct Binding {
        let scope: SimilarityAcrossDriveScope
        let provider: any NativeCloudDrive
        let item: CloudDriveItem
    }
    private var bindings: [String: Binding] = [:]
    private var inventorySeen = Set<String>()
    private var accountObservation: AnyCancellable?
    private var closed = false
    var model: SimilarityScanModel { coordinator.local }
    var canEdit: Bool { !closed && !model.isRunning && !model.isPaused && !model.isPausing && model.results.trashingIDs.isEmpty }
    var includesPhotos: Bool { runScopes.contains { $0.drive == .photos } }
    var cleanupDestination: String {
        if !includesPhotos { return "Trash" }
        return runScopes.allSatisfy { $0.drive == .photos } ? "Recently Deleted" : "Trash / Recently Deleted"
    }

    init(hub: CloudDriveHub) {
        self.hub = hub
        coordinator = FileSimilarityCoordinator(activity: FinderTaskActivityStore())
        coordinator.source = .local
        coordinator.preferredDriveID = Self.driveID
        coordinator.externalTitle = "Across Drives"
        coordinator.externalSymbol = "square.stack.3d.up"
        coordinator.acrossDrives = self
        coordinator.prepareScan = { [weak self] _ in try self?.prepare() }
        coordinator.restoreAcrossDriveScopes = { [weak self] scopes in
            guard let self else { throw CancellationError() }
            self.scopes = scopes; try self.prepare()
        }
        coordinator.configuration = { [weak self] _ in
            guard let self, let hub = self.hub else { throw CancellationError() }
            let cloud = self.runScopes.isEmpty ? self.scopes.contains { $0.drive == .pikpak } : self.runScopes.contains { $0.drive == .pikpak }
            let base = try hub.pikpak.fileSimilarity.configuration(cloud ? .cloud : .local)
            let localBase = try hub.pikpak.fileSimilarity.configuration(.local)
            // Scope-independent, account-isolated cache, including when a
            // PikPak location is added to a previously native-only selection.
            let cache = localBase.dataDirectory.deletingLastPathComponent()
                .appendingPathComponent("AcrossDrives", isDirectory: true)
                .appendingPathComponent(hub.pikpak.activeAccountID?.uuidString ?? "Local", isDirectory: true)
            return SimilarityConfiguration(executable: base.executable, models: base.models, worker: base.worker,
                dataDirectory: cache,
                temporaryDirectory: base.temporaryDirectory.appendingPathComponent("AcrossDrives", isDirectory: true),
                environment: base.environment)
        }
        coordinator.preparePreview = { [weak self] file, directory in
            guard let self, let hub = self.hub else { throw CancellationError() }
            try self.validateAccount()
            if file.cloudId != nil {
                guard let preview = hub.pikpak.fileSimilarity.preparePreview else { throw CancellationError() }
                return try await preview(file, directory)
            }
            let binding = try self.binding(for: file)
            return try await binding.provider.materialize(binding.item, directory: directory, progress: { _ in })
        }
        coordinator.openExternalFile = { [weak self] file in
            guard let self, let hub = self.hub else { return }
            do {
                try self.validateAccount()
                if file.cloudId != nil { hub.pikpak.fileSimilarity.openCloudFile(file) }
                else {
                    let binding = try self.binding(for: file)
                    hub.nativeDrive(for: binding.scope.drive)?.open(binding.item, using: binding.provider)
                }
            } catch { self.model.results.fileActionError = error.localizedDescription }
        }
        coordinator.revealInBrowser = { [weak self] _, file in
            guard let self, let hub = self.hub else { return }
            do {
                try self.validateAccount()
                if file.cloudId != nil { hub.pikpak.fileSimilarity.revealInBrowser?(.cloud, file) }
                else {
                    let binding = try self.binding(for: file)
                    try hub.revealAcrossSimilarityFile(self.original(file, binding: binding), provider: binding.provider, item: binding.item)
                }
            } catch { self.model.results.fileActionError = error.localizedDescription }
        }
        coordinator.moveToTrash = { [weak self] file in
            guard let self else { throw CancellationError() }
            let acknowledged = try await self.remove([file], keeping: [], session: self.model.results.sessionToken)
            guard acknowledged.contains(file.id) else { throw CloudDriveError.message("The drive did not confirm this file change.") }
        }
        coordinator.keepSmallest = { [weak self] plan in
            guard let self else { throw CancellationError() }
            try self.model.results.validateKeepSmallest(plan)
            return try await self.remove(plan.removals, keeping: plan.keepers, session: plan.session, validate: {
                try self.model.results.validateKeepSmallest(plan)
            })
        }
        model.onSessionReset = { [weak self] in
            guard let self else { return }
            self.runScopes = []; self.bindings = [:]; self.providers = [:]
            self.updateScopeLabel()
        }
        accountObservation = hub.pikpak.$activeAccountID.dropFirst().sink { [weak self] account in
            guard let self, self.runScopes.contains(where: { $0.drive == .pikpak && $0.accountID != account }) else { return }
            self.coordinator.preview.close()
            if self.model.isRunning { self.model.pause(reason: "Switch back to the PikPak account that started this scan, then resume.") }
        }
        updateScopeLabel()
    }

    static func fileID(drive: CloudDriveKind, originalID: String) -> String {
        // Stable across folder selections and runs, unlike a scope UUID.
        "cross-native:\(drive.rawValue):" + Data(originalID.utf8).base64EncodedString()
    }
    static func origin(_ file: SimilarityFile) -> (CloudDriveKind, String)? {
        let parts = file.id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "cross-native", let kind = CloudDriveKind(rawValue: String(parts[1])), kind != .pikpak,
              let data = Data(base64Encoded: String(parts[2])), let id = String(data: data, encoding: .utf8), !id.isEmpty else { return nil }
        return (kind, id)
    }
    func removeScope(_ id: String) {
        guard canEdit else { return }
        scopes.removeAll { $0.id == id }; providers.removeValue(forKey: id); updateScopeLabel()
    }
    func removeCloudRoot(scopeID: String, rootID: String) {
        guard canEdit, let index = scopes.firstIndex(where: { $0.id == scopeID && $0.drive == .pikpak }) else { return }
        let scope = scopes[index], roots = scope.cloudRoots.filter { $0.id != rootID }
        guard roots.count != scope.cloudRoots.count else { return }
        if roots.isEmpty { scopes.remove(at: index) }
        else {
            scopes[index] = .init(id: scope.id, drive: scope.drive, native: scope.native,
                cloudRoots: roots, accountID: scope.accountID)
        }
        updateScopeLabel()
    }
    private func updateScopeLabel() {
        model.externalTitle = "Across Drives"
        model.externalScopeNames = scopes.map { "\($0.drive.title): \($0.title)" }
    }
    func addNativeScope(_ native: SimilarityNativeScope, provider: any NativeCloudDrive) {
        guard canEdit, native.drive != .pikpak, native.drive == provider.kind else { return }
        guard !scopes.contains(where: { $0.drive == native.drive && $0.native?.location == native.location && $0.native?.selection == native.selection }) else { return }
        let scope = SimilarityAcrossDriveScope(id: UUID().uuidString, drive: native.drive, native: native, cloudRoots: [], accountID: nil)
        scopes.append(scope); providers[scope.id] = provider; updateScopeLabel()
    }
    func addCloudScope(_ roots: [SimilarityCloudRoot]) {
        guard canEdit, let hub, !roots.isEmpty else { return }
        var seen = Set(scopes.flatMap(\.cloudRoots).map(\.id))
        let roots = roots.filter { seen.insert($0.id).inserted }
        guard !roots.isEmpty else { return }
        scopes.append(.init(id: UUID().uuidString, drive: .pikpak, native: nil, cloudRoots: roots, accountID: hub.pikpak.activeAccountID))
        updateScopeLabel()
    }
    func choose(_ kind: CloudDriveKind) {
        guard canEdit, let hub else { return }
        model.error = nil
        if kind == .local {
            let panel = NSOpenPanel(); panel.title = "Add Folders or Disks to Compare"; panel.prompt = "Add to Scan"
            panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
            panel.begin { [weak self] response in
                guard response == .OK else { return }
                Task { @MainActor in
                    guard let self, self.canEdit else { return }
                    for url in panel.urls {
                        let provider = ICloudDriveProvider(rootURL: url, kind: .local)
                        self.addNativeScope(.init(drive: .local, providerRoot: provider.root, location: provider.root, selection: [],
                            bookmark: try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)), provider: provider)
                    }
                }
            }
        } else if kind == .pikpak {
            do {
                coordinator.scopePicker = try hub.pikpak.makeSimilarityCloudFolderPicker { [weak self] roots in self?.addCloudScope(roots) }
            } catch { model.error = error.localizedDescription }
        } else {
            guard let drive = hub.nativeDrive(for: kind), drive.isConnected, let provider = drive.provider else {
                model.error = "Connect \(kind.title) in Settings → Drives, then add a scan location."; return
            }
            coordinator.scopePicker = SimilarityScopePicker(title: kind == .photos ? "Add a Photos Album or Library" : "Add an iCloud Folder",
                root: provider.root, load: { folder, token in
                    if kind == .photos && folder.id != provider.root.id { return .init(folders: []) }
                    let page = try await provider.list(folder, offset: token.flatMap(Int.init) ?? 0, search: "")
                    return .init(folders: page.items.filter { $0.isFolder && !$0.name.hasPrefix(".") }.map(\.location), nextPage: page.nextOffset.map(String.init))
                }, accept: { [weak self] route in
                    guard let self, self.canEdit, let location = route.last else { return }
                    self.addNativeScope(.init(drive: kind, providerRoot: provider.root, location: location, selection: [],
                        bookmark: provider.root.url.flatMap { try? $0.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) },
                        photosUsePreviews: false), provider: provider)
                })
        }
    }

    private func validateAccount(selected scopesToCheck: [SimilarityAcrossDriveScope]? = nil) throws {
        guard !closed, let hub else { throw CancellationError() }
        let selected = scopesToCheck ?? (runScopes.isEmpty ? scopes : runScopes)
        guard selected.filter({ $0.drive == .pikpak }).allSatisfy({ $0.accountID == hub.pikpak.activeAccountID }),
              !selected.contains(where: { $0.drive == .pikpak }) || hub.pikpak.canProvidePikPakRelayContext else {
            throw CloudDriveError.message("Switch back to the PikPak account that owns this scan before continuing.")
        }
    }
    private func prepare() throws {
        guard !closed, !model.isRunning, !model.isPausing, !model.retainsOriginalsInRAM, model.results.trashingIDs.isEmpty else {
            throw CloudDriveError.message("Finish the current scan or file change before starting another scan.")
        }
        guard !scopes.isEmpty else { throw CloudDriveError.message("Add a folder or drive location to compare its files.") }
        try validateAccount(selected: scopes)
        var capturedProviders = providers
        for scope in scopes where scope.drive != .pikpak {
            guard let native = scope.native else { throw CloudDriveError.message("This saved scan is missing a drive location.") }
            guard native.drive == scope.drive, scope.cloudRoots.isEmpty else { throw CloudDriveError.message("This saved scan has inconsistent drive locations.") }
            if let existing = capturedProviders[scope.id] {
                guard existing.kind == scope.drive, existing.root.id == native.providerRoot.id,
                      existing.root.url?.standardizedFileURL.resolvingSymlinksInPath() == native.providerRoot.url?.standardizedFileURL.resolvingSymlinksInPath() else {
                    throw CloudDriveError.message("The original scan’s drive connection changed. Choose its location again.")
                }
            } else if scope.drive == .photos {
                guard let provider = hub?.photos.provider else { throw CloudDriveError.message("Reconnect Apple Photos to resume this scan.") }
                capturedProviders[scope.id] = provider
            } else {
                guard let url = native.providerRoot.url else { throw CloudDriveError.message("Reconnect this scan’s original disk or folder.") }
                var stale = false
                let restored = native.bookmark.flatMap { try? URL(resolvingBookmarkData: $0, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) } ?? url
                capturedProviders[scope.id] = ICloudDriveProvider(rootURL: restored, kind: scope.drive)
            }
            if scope.drive != .photos {
                guard let root = capturedProviders[scope.id]?.root.url?.standardizedFileURL.resolvingSymlinksInPath(),
                      let location = native.location.url?.standardizedFileURL.resolvingSymlinksInPath(),
                      location == root || location.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") else {
                    throw CloudDriveError.message("A saved scan location is outside its original drive.")
                }
            }
        }
        runScopes = scopes; providers = capturedProviders.filter { entry in runScopes.contains { $0.id == entry.key } }
        bindings = [:]
        model.nativeScope = nil; model.acrossDriveScopes = runScopes
        model.cloudRoots = runScopes.flatMap(\.cloudRoots)
        model.localURLs = []; model.externalDuplicatesOnly = false
        model.configurePhotosPreviews(supported: false, enabled: false)
        model.externalTitle = "Across Drives"
        model.externalScopeNames = runScopes.map { "\($0.drive.title): \($0.title)" }
        model.prepareExternalScope = nil; model.inventoryExternalSources = nil
        model.streamExternalSources = { [weak self] emit in
            guard let self else { throw CancellationError() }
            try await self.inventory(emit)
        }
        model.resolveExternalSource = { [weak self] id, directory, progress in
            try Task.checkCancellation()
            guard let self else { throw CancellationError() }
            try self.validateAccount()
            guard let binding = self.bindings[id] else { throw CloudDriveError.message("The scan’s original file is unavailable.") }
            return try await binding.provider.materialize(binding.item, directory: directory, progress: progress)
        }
        model.resolveExternalMemorySource = { [weak self] id, pipe, capacity, progress in
            try Task.checkCancellation()
            guard let self else { throw CancellationError() }
            try self.validateAccount()
            guard let binding = self.bindings[id] else { throw CloudDriveError.message("The scan’s original file is unavailable.") }
            return try await binding.provider.streamForSimilarity(binding.item, pipe: pipe, capacity: capacity, progress: progress)
        }
        model.transformExternalReport = { [weak self] report in self?.transform(report) ?? report }
    }

    private func inventory(_ emit: @escaping (SimilarityExternalSource) async throws -> Void) async throws {
        try validateAccount()
        inventorySeen = []
        try await withThrowingTaskGroup(of: Void.self) { tasks in
            for scope in runScopes {
                guard let native = scope.native, let provider = providers[scope.id] else { continue }
                tasks.addTask { [weak self] in
                    for try await item in provider.scanItemStream(native.selection, location: native.location, progress: { _ in }) {
                        try Task.checkCancellation()
                        guard !item.name.hasPrefix("."), !item.isFolder, let self else { continue }
                        try await self.discovered(item, scope: scope, provider: provider, emit: emit)
                    }
                }
            }
            try await tasks.waitForAll()
        }
        try validateAccount()
    }
    private func discovered(_ item: CloudDriveItem, scope: SimilarityAcrossDriveScope, provider: any NativeCloudDrive,
                            emit: (SimilarityExternalSource) async throws -> Void) async throws {
        // Local and iCloud can overlap. Select the same owner before emitting,
        // regardless of which concurrent enumerator reaches the file first.
        if let path = item.url?.standardizedFileURL.resolvingSymlinksInPath().path {
            let candidates = runScopes.filter { candidate in
                guard candidate.drive == .local || candidate.drive == .icloud, let native = candidate.native,
                      let location = native.location.url?.standardizedFileURL.resolvingSymlinksInPath().path,
                      path == location || path.hasPrefix(location == "/" ? "/" : location + "/") else { return false }
                return native.selection.isEmpty || native.selection.contains { selected in
                    guard let url = selected.url?.standardizedFileURL.resolvingSymlinksInPath() else { return false }
                    return path == url.path || selected.isFolder && path.hasPrefix(url.path == "/" ? "/" : url.path + "/")
                }
            }.sorted {
                if $0.drive != $1.drive { return $0.drive == .local }
                let left = $0.native!.location.url!.standardizedFileURL.path
                let right = $1.native!.location.url!.standardizedFileURL.path
                return left == right ? $0.id < $1.id : left < right
            }
            guard candidates.first?.id == scope.id else { return }
        }
        let identity = item.url.map { "path:" + $0.standardizedFileURL.resolvingSymlinksInPath().path } ?? "\(scope.drive.rawValue):\(item.id)"
        guard inventorySeen.insert(identity).inserted else { return }
        let id = Self.fileID(drive: scope.drive, originalID: item.id)
        bindings[id] = .init(scope: scope, provider: provider, item: item)
        try await emit(.init(id: id, name: item.name, path: "\(scope.drive.title)/\(item.url?.path ?? item.name)", size: item.bytes ?? 0,
            localPath: scope.drive == .photos ? nil : item.url?.path, revision: item.revision, provider: scope.drive.rawValue))
    }
    private func binding(for file: SimilarityFile) throws -> Binding {
        if let binding = bindings[file.id] { return binding }
        guard let (kind, originalID) = Self.origin(file), let scope = runScopes.first(where: { scope in
            guard scope.drive == kind, let native = scope.native else { return false }
            if let capturedScope = file.nativeScopeID, scope.id != capturedScope { return false }
            if kind == .photos { return file.nativeScopeID != nil || native.selection.isEmpty || native.selection.contains { $0.id == originalID } }
            guard let path = file.localPath, let location = native.location.url?.standardizedFileURL.resolvingSymlinksInPath().path,
                  path == location || path.hasPrefix(location == "/" ? "/" : location + "/") else { return false }
            return native.selection.isEmpty || native.selection.contains { selected in
                guard let url = selected.url?.standardizedFileURL.resolvingSymlinksInPath() else { return false }
                return path == url.path || selected.isFolder && path.hasPrefix(url.path == "/" ? "/" : url.path + "/")
            }
        }), let provider = providers[scope.id] else { throw CloudDriveError.message("Reconnect this result’s original drive and scan location.") }
        let item = CloudDriveItem(id: originalID, name: file.name, isFolder: false, bytes: file.bytes,
            url: file.localPath.map { URL(fileURLWithPath: $0) }, mediaType: file.family,
            canRename: kind != .photos, revision: file.nativeRevision)
        let binding = Binding(scope: scope, provider: provider, item: item)
        bindings[file.id] = binding
        return binding
    }
    private func original(_ file: SimilarityFile, binding: Binding) -> SimilarityFile {
        SimilarityFile(id: binding.item.id, name: file.name, path: binding.item.url?.path ?? file.path, bytes: file.bytes,
            family: file.family, localPath: binding.item.url?.path, cloudId: nil, ancestors: [], engineIndex: file.engineIndex,
            engineId: file.scoreID, state: file.state, nativeRevision: file.nativeRevision ?? binding.item.revision)
    }
    private func transform(_ input: SimilarityReport) -> SimilarityReport {
        func mapped(_ file: SimilarityFile) -> SimilarityFile {
            var file = file
            if let binding = bindings[file.id] {
                file.nativeRevision = binding.item.revision; file.nativeScopeID = binding.scope.id
            }
            return file
        }
        return SimilarityReport(source: input.source, scope: model.externalScopeNames, status: input.status, threshold: input.threshold,
            scannedFiles: input.scannedFiles, analysedFiles: input.analysedFiles, skippedFiles: input.skippedFiles,
            downloadedBytes: input.downloadedBytes, totalGroups: input.totalGroups,
            groups: input.groups.map { .init(id: $0.id, matchKind: $0.matchKind, family: $0.family, minimumScore: $0.minimumScore,
                memberCount: $0.memberCount, members: $0.members.map(mapped)) }, issues: input.issues, truncated: input.truncated,
            coverage: input.coverage, elapsedSeconds: input.elapsedSeconds, files: input.files?.map(mapped), runId: input.runId,
            resultRevision: input.resultRevision, scoresRetained: input.scoresRetained, unsupportedFiles: input.unsupportedFiles,
            failedFiles: input.failedFiles, issueSummary: input.issueSummary)
    }

    private func remove(_ removals: [SimilarityFile], keeping keepers: [SimilarityFile], session: UUID,
                        validate: () throws -> Void = {}) async throws -> Set<String> {
        guard let hub else { throw CancellationError() }
        let results = model.results
        func validateOwner(plan: Bool = false) throws {
            try validateAccount()
            guard results.sessionToken == session, (keepers + removals).allSatisfy({ file in
                guard let current = results.index?.byID[file.id] else { return false }
                return current.bytes == file.bytes && current.cloudId == file.cloudId && current.nativeRevision == file.nativeRevision
                    && SimilarityKeepSmallestPlan.originalID(current) == SimilarityKeepSmallestPlan.originalID(file)
            }) else {
                throw CloudDriveError.message("These results have changed. Review the current groups before changing files.")
            }
            if plan { try validate() }
        }
        try validateOwner(plan: true)
        let cloud = (keepers + removals).filter { $0.cloudId != nil }
        if !cloud.isEmpty {
            try await hub.pikpak.preflightCrossDriveSimilarityFiles(cloud, accountID: hub.pikpak.activeAccountID)
        }
        var native: [String: (Binding, keepers: [SimilarityFile], removals: [SimilarityFile], resultIDs: Set<String>)] = [:]
        for (files, keeping) in [(keepers, true), (removals, false)] {
            for file in files where file.cloudId == nil {
                let binding = try binding(for: file), key = binding.scope.id
                if native[key] == nil { native[key] = (binding, [], [], []) }
                if keeping { native[key]!.keepers.append(original(file, binding: binding)) }
                else { native[key]!.removals.append(original(file, binding: binding)); native[key]!.resultIDs.insert(file.id) }
            }
        }
        // No provider is changed until every retained and selected file passes.
        for (_, batch) in native {
            guard let drive = hub.nativeDrive(for: batch.0.scope.drive) else { throw CancellationError() }
            try await drive.preflightSimilarityFiles(batch.keepers + batch.removals, provider: batch.0.provider)
        }
        try validateOwner(plan: true)
        var acknowledged = Set<String>()
        func recheckKeepers() async throws {
            try validateOwner()
            let cloudKeepers = keepers.filter { $0.cloudId != nil }
            if !cloudKeepers.isEmpty { try await hub.pikpak.preflightCrossDriveSimilarityFiles(cloudKeepers, accountID: hub.pikpak.activeAccountID) }
            for (_, batch) in native where !batch.keepers.isEmpty {
                guard let drive = hub.nativeDrive(for: batch.0.scope.drive) else { throw CancellationError() }
                try await drive.preflightSimilarityFiles(batch.keepers, provider: batch.0.provider)
            }
            try validateOwner()
        }
        do {
            let cloudRemovals = removals.filter { $0.cloudId != nil }
            if !cloudRemovals.isEmpty {
                acknowledged.formUnion(try await hub.pikpak.trashCrossDriveSimilarityFiles(cloudRemovals, keeping: keepers.filter { $0.cloudId != nil },
                    results: results, session: session, accountID: hub.pikpak.activeAccountID))
                if !Set(cloudRemovals.map(\.id)).isSubset(of: acknowledged) { return acknowledged }
            }
            for key in native.keys.sorted() {
                guard let batch = native[key], !batch.removals.isEmpty, let drive = hub.nativeDrive(for: batch.0.scope.drive) else { continue }
                try await recheckKeepers()
                acknowledged.formUnion(try await drive.trashCrossDriveSimilarityFiles(batch.removals, keeping: batch.keepers,
                    provider: batch.0.provider, results: results, session: session, resultIDs: batch.resultIDs))
            }
        } catch {
            // Cross-provider changes cannot be atomic. Preserve confirmed work
            // and its Undo entries; never imply an unconfirmed file was removed.
            if !acknowledged.isEmpty {
                if results.sessionToken == session { results.setTrashedIDs(acknowledged, true) }
                throw CloudDriveError.message("Moved \(acknowledged.count) of \(removals.count) files to \(cleanupDestination) before the operation stopped. Review the remaining files before trying again.")
            }
            throw error
        }
        return acknowledged
    }
    func close() {
        closed = true; accountObservation?.cancel(); accountObservation = nil
        coordinator.close(preservingScans: true)
    }
}

struct SimilarityAcrossDriveScopeView: View {
    @ObservedObject var across: SimilarityAcrossDrives
    private var locationCount: Int {
        across.scopes.reduce(0) { $0 + ($1.drive == .pikpak ? $1.cloudRoots.count : 1) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Locations", systemImage: "folder").font(.headline)
                Text("\(locationCount) selected").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("Includes subfolders · Reuses cached analysis")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).layoutPriority(-1)
                Menu {
                    Button("Add PikPak Folder…") { across.choose(.pikpak) }
                        .accessibilityIdentifier("similarity-add-pikpak-folder")
                    Button("Add Disk Folders…") { across.choose(.local) }
                        .help("Choose folders on this Mac, connected network disks or external disks")
                        .accessibilityIdentifier("similarity-add-disk-folders")
                    Button("Add iCloud Folder…") { across.choose(.icloud) }
                        .accessibilityIdentifier("similarity-add-icloud-folder")
                    Button("Add Photos Album or Library…") { across.choose(.photos) }
                        .help("Uses Apple Photos originals for accurate comparisons")
                        .accessibilityIdentifier("similarity-add-photos-location")
                } label: { Label("Add…", systemImage: "plus") }
                    .disabled(!across.canEdit).accessibilityIdentifier("similarity-add-location")
                    .help("Add a location to compare with the selected folders")
            }
            if locationCount == 0 {
                Text("Add folders or drive locations to compare.")
                    .font(.callout).foregroundStyle(.secondary).lineLimit(1)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(across.scopes) { scope in
                            if scope.drive == .pikpak {
                                ForEach(scope.cloudRoots) { root in
                                    scopeRow(root.path == "/" ? "All PikPak files" : root.path, kind: scope.drive) {
                                        across.removeCloudRoot(scopeID: scope.id, rootID: root.id)
                                    }.accessibilityIdentifier("similarity-scope-row-\(scope.id)-\(root.id)")
                                }
                            } else {
                                scopeRow(scope.title, kind: scope.drive) { across.removeScope(scope.id) }
                                    .accessibilityIdentifier("similarity-scope-row-\(scope.id)")
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: min(CGFloat(locationCount) * 28, 84))
                    .accessibilityIdentifier("similarity-scope-list")
            }
        }.padding(12).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.08)))
            .accessibilityElement(children: .contain).accessibilityIdentifier("similarity-scope-card")
    }

    private func scopeRow(_ title: String, kind: CloudDriveKind, remove: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: kind.symbol).foregroundStyle(FinderAppearance.accent).frame(width: 18)
            Text(title).lineLimit(1).truncationMode(.middle).help("\(kind.title): \(title)")
            Spacer(minLength: 8)
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless).disabled(!across.canEdit)
                .help("Remove this \(kind.title) location from the next scan").accessibilityLabel("Remove \(title)")
        }.padding(.horizontal, 3).frame(height: 26).accessibilityElement(children: .contain)
    }
}

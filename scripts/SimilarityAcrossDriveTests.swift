import AppKit
import Combine
import Foundation

/// Metadata-only providers and generated local originals; no real accounts,
/// Photos libraries, cloud content or user directories are read.
private final class AcrossFixtureDrive: NativeCloudDrive, @unchecked Sendable {
    let kind: CloudDriveKind
    let root: CloudDriveLocation
    let items: [CloudDriveItem]
    var changed = false
    var onRefresh: (@MainActor () -> Void)?
    var scanDelay: UInt64 = 0
    private(set) var deleteCalls = 0
    private(set) var materializeCalls = 0
    init(kind: CloudDriveKind, rootURL: URL, id: String = "same-original", bytes: UInt64 = 100) {
        self.kind = kind
        root = .init(id: "fixture-root-" + kind.rawValue, title: "Generated", url: rootURL)
        items = [.init(id: id, name: "generated.txt", isFolder: false, bytes: bytes,
            url: kind == .photos ? nil : rootURL.appendingPathComponent("generated.txt"), revision: "revision-1")]
    }
    func list(_ location: CloudDriveLocation, offset: Int, search: String) async throws -> CloudDrivePage { .init(items: items, total: items.count) }
    func scanItems(_ selected: [CloudDriveItem], location: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> [CloudDriveItem] {
        if scanDelay > 0 { try await Task.sleep(nanoseconds: scanDelay) }
        return items
    }
    func refreshedItems(_ selected: [CloudDriveItem]) async throws -> [CloudDriveItem] {
        if let onRefresh { await onRefresh() }
        return selected.map { value in var value = value; if changed { value.revision = "revision-2" }; return value }
    }
    func delete(_ selected: [CloudDriveItem], progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? {
        deleteCalls += 1; return nil
    }
    func materialize(_ item: CloudDriveItem, directory: URL, progress: @escaping CloudDriveProgressHandler) async throws -> URL {
        materializeCalls += 1
        throw CocoaError(.featureUnsupported)
    }
    func createContainer(_ name: String, in location: CloudDriveLocation) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
    func rename(_ item: CloudDriveItem, to name: String) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
    func relocate(_ items: [CloudDriveItem], from: CloudDriveLocation, to: CloudDriveLocation, copy: Bool, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
    func importFiles(_ urls: [URL], into location: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
}

private actor AcrossSourceCollector {
    private var files: [SimilarityExternalSource] = []
    func append(_ file: SimilarityExternalSource) { files.append(file) }
    func all() -> [SimilarityExternalSource] { files }
}

@main struct SimilarityAcrossDriveTests {
    @MainActor static func until(_ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(10)
        while !condition() && Date() < end { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(condition(), "Generated cross-drive operation timed out")
    }
    @MainActor static func sources(_ across: SimilarityAcrossDrives) async throws -> [SimilarityExternalSource] {
        try across.coordinator.prepareScan!(across.model)
        let collector = AcrossSourceCollector()
        try await across.model.streamExternalSources! { await collector.append($0) }
        return await collector.all()
    }
    static func native(_ provider: any NativeCloudDrive) -> SimilarityNativeScope {
        .init(drive: provider.kind, providerRoot: provider.root, location: provider.root, selection: [], photosUsePreviews: false)
    }
    @MainActor static func report(_ sources: [SimilarityExternalSource], across: SimilarityAcrossDrives) -> SimilarityReport {
        let files = sources.map { source in SimilarityFile(id: source.id, name: source.name, path: source.path,
            bytes: source.size, family: "text", localPath: source.localPath, cloudId: nil, ancestors: [], nativeRevision: source.revision) }
        return report(files: files, across: across)
    }
    @MainActor static func report(files: [SimilarityFile], across: SimilarityAcrossDrives) -> SimilarityReport {
        let report = SimilarityReport(source: .local, scope: ["Generated scopes"], status: "completed", threshold: 0.9,
            scannedFiles: UInt64(files.count), analysedFiles: UInt64(files.count), skippedFiles: 0, downloadedBytes: 0,
            totalGroups: 1, groups: [.init(id: "generated-group", matchKind: "similar", family: "text", minimumScore: 0.99,
                memberCount: UInt64(files.count), members: files)], issues: [], truncated: false, coverage: "Generated", elapsedSeconds: 1,
            files: files, scoresRetained: UInt64(files.count * (files.count - 1) / 2))
        return across.model.transformExternalReport?(report) ?? report
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        let fm = FileManager.default, root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("AcrossDriveFixtures-\(UUID())")
        let suite = "AcrossDriveFixtures-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { defaults.removePersistentDomain(forName: suite); try? fm.removeItem(at: root) }
        let account = DownloaderModel.finderWorkspaceFixture(defaults: defaults)
        let hub = CloudDriveHub(pikpak: account, defaults: defaults, restoreConnections: false,
            photosAccess: .init(status: { .denied }, request: { .denied }, provider: { PhotosDriveProvider() }), localRootURL: root)
        defer { hub.close(); account.stopForWindowClose() }
        let folders = ["a", "b", "c"].map { root.appendingPathComponent($0) }
        for (index, folder) in folders.enumerated() {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: UInt8(65 + index), count: 100 + index * 200).write(to: folder.appendingPathComponent("generated.txt"))
        }
        let providers = folders.map { ICloudDriveProvider(rootURL: $0, kind: .local) }
        let single = SimilarityAcrossDrives(hub: hub)
        precondition(!single.model.canStart, "An empty location list must not enable Start Scan")
        do {
            try single.coordinator.prepareScan!(single.model)
            preconditionFailure("An empty location list must not prepare a scan")
        } catch { }
        let singleRoot = root.appendingPathComponent("single-scope", isDirectory: true)
        let singleNested = singleRoot.appendingPathComponent("nested/descendant", isDirectory: true)
        try fm.createDirectory(at: singleNested, withIntermediateDirectories: true)
        try Data(repeating: 70, count: 71).write(to: singleRoot.appendingPathComponent("generated-first.txt"))
        try Data(repeating: 70, count: 71).write(to: singleNested.appendingPathComponent("generated-copy.txt"))
        let singleProvider = ICloudDriveProvider(rootURL: singleRoot, kind: .local)
        single.addNativeScope(native(singleProvider), provider: singleProvider)
        precondition(single.scopes.count == 1 && single.model.canStart,
                     "One selected folder must enable scanning its contents without requiring another location")
        let singleSources = try await sources(single)
        precondition(singleSources.count == 2 && Set(singleSources.map(\.id)).count == 2
                     && singleSources.contains { $0.localPath?.hasPrefix(singleNested.path + "/") == true },
                     "A single selected location must inventory all descendants for comparison")
        single.addNativeScope(native(providers[1]), provider: providers[1])
        let extendedSources = try await sources(single)
        precondition(single.model.canStart && extendedSources.count == 3
                     && Set(singleSources.map(\.id)).isSubset(of: Set(extendedSources.map(\.id))),
                     "Adding a second location must keep the first location's stable file identities")
        for id in single.scopes.map(\.id) { single.removeScope(id) }
        precondition(single.scopes.isEmpty && !single.model.canStart,
                     "Removing the last location must disable Start Scan immediately")
        do {
            try single.coordinator.prepareScan!(single.model)
            preconditionFailure("Removing every location must make preparation invalid")
        } catch { }

        let singleICloud = SimilarityAcrossDrives(hub: hub)
        let singleICloudProvider = AcrossFixtureDrive(kind: .icloud, rootURL: root.appendingPathComponent("generated-single-icloud"))
        singleICloud.addNativeScope(native(singleICloudProvider), provider: singleICloudProvider)
        precondition(singleICloud.model.canStart)
        let singleICloudSources = try await sources(singleICloud)
        precondition(singleICloudSources.count == 1 && singleICloudSources[0].provider == "icloud",
                     "One native provider location must remain a valid scan scope")

        let cloudRoot = SimilarityCloudRoot(id: "generated-one-cloud-folder", name: "Generated One", path: "/Generated One",
            isFolder: true, size: 0, ancestors: [])
        let otherCloudRoot = SimilarityCloudRoot(id: "generated-other-cloud-folder", name: "Generated Other", path: "/Generated Other",
            isFolder: true, size: 0, ancestors: [])
        let singleCloud = SimilarityAcrossDrives(hub: hub)
        singleCloud.addCloudScope([cloudRoot])
        precondition(singleCloud.scopes.count == 1 && singleCloud.model.canStart,
                     "One PikPak folder must enable Start Scan")
        let cloudNativeSources = try await sources(singleCloud)
        precondition(cloudNativeSources.isEmpty && singleCloud.model.cloudRoots.map(\.id) == [cloudRoot.id]
                     && singleCloud.model.streamExternalSources != nil,
                     "A cloud-only location must prepare its cloud root plus an empty native stream without network access")
        let cloudGranular = SimilarityAcrossDrives(hub: hub)
        cloudGranular.addCloudScope([cloudRoot,cloudRoot,otherCloudRoot])
        precondition(cloudGranular.scopes[0].cloudRoots.map(\.id) == [cloudRoot.id,otherCloudRoot.id],
                     "Repeated folders within the same picker result must appear only once")
        let cloudScopeID = cloudGranular.scopes[0].id
        cloudGranular.removeCloudRoot(scopeID: cloudScopeID, rootID: cloudRoot.id)
        precondition(cloudGranular.scopes.count == 1 && cloudGranular.scopes[0].id == cloudScopeID
                     && cloudGranular.scopes[0].cloudRoots.map(\.id) == [otherCloudRoot.id] && cloudGranular.model.canStart,
                     "Removing one selected PikPak folder must preserve the other folder and enable a single-location scan")
        let remainingNativeSources = try await sources(cloudGranular)
        precondition(remainingNativeSources.isEmpty && cloudGranular.model.cloudRoots.map(\.id) == [otherCloudRoot.id])
        cloudGranular.removeCloudRoot(scopeID: cloudScopeID, rootID: otherCloudRoot.id)
        precondition(cloudGranular.scopes.isEmpty && !cloudGranular.model.canStart,
                     "Removing the last PikPak folder must remove its empty scope and disable Start Scan")
        print("PASS one-location scan readiness: recursive local contents, native/cloud-only preparation, second location, empty rejection and folder-granular cloud removal")

        // Presentation must not consult installed engines, saved user scans or
        // account directories. Only generated empty recovery locations exist.
        let host = account.fileSimilarity
        let defaultAcross = hub.similarityAcrossDrives
        for (index, coordinator) in ([host,defaultAcross.coordinator] + [hub.local.similarity,hub.icloud.similarity,hub.photos.similarity]).enumerated() {
            let generatedConfiguration = SimilarityConfiguration(executable: root.appendingPathComponent("unused-generated-engine"),
                models: root.appendingPathComponent("unused-generated-models"), worker: root.appendingPathComponent("unused-generated-worker"),
                dataDirectory: root.appendingPathComponent("generated-entry-cache-\(index)"),
                temporaryDirectory: root.appendingPathComponent("generated-entry-temp-\(index)"), environment: [:])
            coordinator.configuration = { _ in generatedConfiguration }
        }
        host.presentDrive(CloudDriveKind.local.rawValue)
        let sharedWindow = host.presentedWindow
        precondition(sharedWindow != nil && host.selectedDriveID == CloudDriveKind.local.rawValue
                     && host.activeModel === hub.local.similarity.local)
        hub.presentSimilarity()
        precondition(host.selectedDriveID == SimilarityAcrossDrives.driveID
                     && host.activeCoordinator === defaultAcross.coordinator && host.activeModel === defaultAcross.model
                     && host.presentedWindow === sharedWindow,
                     "Default similarity must replace a reused host's Local coordinator with Across Drives")
        host.selectDrive(CloudDriveKind.local.rawValue)
        host.presentNewScan()
        precondition(host.selectedDriveID == SimilarityAcrossDrives.driveID
                     && host.activeModel === defaultAcross.model && host.presentedWindow === sharedWindow,
                     "A generic new-scan action must return a reused shared window to Across Drives")
        try await until { hub.local.provider != nil }
        let contextProvider = hub.local.provider!, contextLocation = hub.local.location
        let contextItem = try ICloudDriveProvider.item(folders[0].appendingPathComponent("generated.txt"))
        let otherContextItem = try ICloudDriveProvider.item(folders[1].appendingPathComponent("generated.txt"))
        hub.local.findSimilar([contextItem])
        precondition(host.selectedDriveID == SimilarityAcrossDrives.driveID && host.activeModel === defaultAcross.model
                     && defaultAcross.scopes.count == 1 && defaultAcross.model.canStart,
                     "A native new-similarity action must seed and open the Across Drives controller")
        let capturedNative = defaultAcross.scopes[0].native!
        precondition(capturedNative.providerRoot == contextProvider.root && capturedNative.location == contextLocation
                     && capturedNative.selection.map(\.id) == [contextItem.id],
                     "A native new-similarity action must capture the selected original and its provider/location")
        precondition(defaultAcross.scopes[0].title == contextItem.url?.path,
                     "A selected-file scope must display the captured selection instead of implying its whole parent folder is scanned")
        hub.local.findSimilar([otherContextItem], exactOnly: false, presentWindow: false)
        precondition(hub.local.similarity.local.nativeScope?.selection.map(\.id) == [otherContextItem.id]
                     && !hub.local.similarity.duplicatesOnly && host.selectedDriveID == SimilarityAcrossDrives.driveID
                     && defaultAcross.scopes.count == 1 && defaultAcross.scopes[0].native?.selection.map(\.id) == [contextItem.id],
                     "Configuring a legacy nonpresented scope must not redirect or mutate the captured Across selection")
        hub.local.findSimilar([otherContextItem], exactOnly: true)
        precondition(hub.local.similarity.duplicatesOnly && hub.local.similarity.local.externalDuplicatesOnly
                     && hub.local.similarity.local.nativeScope?.selection.map(\.id) == [otherContextItem.id]
                     && host.selectedDriveID == CloudDriveKind.local.rawValue && host.activeModel === hub.local.similarity.local
                     && defaultAcross.scopes.count == 1 && defaultAcross.scopes[0].native?.selection.map(\.id) == [contextItem.id],
                     "Explicit exact-copy review must retain its legacy controller without changing Across selection")
        host.presentNewScan()
        precondition(host.selectedDriveID == SimilarityAcrossDrives.driveID && host.activeModel === defaultAcross.model
                     && host.presentedWindow === sharedWindow && !defaultAcross.model.isRunning,
                     "Returning from exact-copy review must select Across without starting a scan")
        host.presentedWindow?.close()
        print("PASS default Across entry: reused host/new-scan routing, captured native selection and isolated legacy exact/nonpresented configuration")

        let across = SimilarityAcrossDrives(hub: hub)
        var readinessChanges = 0
        let readinessObserver = across.model.objectWillChange.sink { readinessChanges += 1 }
        precondition(!across.model.canStart)
        let emptyScopeChanges = readinessChanges
        across.addNativeScope(native(providers[0]), provider: providers[0])
        let oneScopeChanges = readinessChanges
        precondition(across.model.canStart && readinessChanges > emptyScopeChanges,
                     "Adding the first scope must notify the scan model observer and enable Start Scan")
        across.addNativeScope(native(providers[1]), provider: providers[1])
        precondition(across.model.canStart && readinessChanges > oneScopeChanges,
                     "Adding the second scope must keep Start Scan enabled and notify the scan model observer")
        readinessObserver.cancel()
        let ab = try await sources(across)
        precondition(ab.count == 2 && Set(ab.map(\.size)) == [100,300])
        let aID = ab.first { $0.size == 100 }!.id
        across.removeScope(across.scopes.first { $0.native?.providerRoot == providers[1].root }!.id)
        across.addNativeScope(native(providers[2]), provider: providers[2])
        let ac = try await sources(across)
        precondition(ac.count == 2 && ac.first { $0.size == 100 }!.id == aID && Set(ac.map(\.size)) == [100,500],
                     "A+B to A+C must preserve A's stable feature-cache identity")
        let saved = try JSONDecoder().decode([SimilarityAcrossDriveScope].self, from: JSONEncoder().encode(across.scopes))
        let restored = SimilarityAcrossDrives(hub: hub)
        try restored.coordinator.restoreAcrossDriveScopes!(saved)
        let resumed = try await sources(restored)
        precondition(Set(resumed.map(\.id)) == Set(ac.map(\.id)), "Saved scopes must restore the same original identities")
        let rendered = report(resumed, across: restored)
        precondition(rendered.files!.allSatisfy { $0.nativeRevision != nil && $0.nativeScopeID != nil },
                     "Saved result rows must retain their exact provider-scope binding")
        let foreignCloud = SimilarityAcrossDriveScope(id: UUID().uuidString, drive: .pikpak, native: nil,
            cloudRoots: [.init(id: "generated-cloud", name: "Generated", path: "/Generated", isFolder: true, size: 0, ancestors: [])], accountID: UUID())
        do {
            try restored.coordinator.restoreAcrossDriveScopes!([saved[0],foreignCloud])
            preconditionFailure("A saved cloud scope must remain bound to its original account")
        } catch { }
        let inconsistent = SimilarityAcrossDriveScope(id: UUID().uuidString, drive: .icloud, native: saved[0].native, cloudRoots: [], accountID: nil)
        do {
            try restored.coordinator.restoreAcrossDriveScopes!([saved[0],inconsistent])
            preconditionFailure("A saved scope's provider kind must match its descriptor")
        } catch { }
        print("PASS generated scope inventory: A+B to A+C stable IDs, saved metadata roundtrip, exact scope provenance and wrong-account/kind rejection")

        let collision = SimilarityAcrossDrives(hub: hub)
        let fakeLocal = AcrossFixtureDrive(kind: .local, rootURL: root.appendingPathComponent("fake-local"))
        let fakeCloud = AcrossFixtureDrive(kind: .icloud, rootURL: root.appendingPathComponent("fake-icloud"))
        collision.addNativeScope(native(fakeLocal), provider: fakeLocal)
        collision.addNativeScope(native(fakeCloud), provider: fakeCloud)
        let collided = try await sources(collision)
        precondition(collided.count == 2 && Set(collided.map(\.id)).count == 2)
        precondition(Set(collided.compactMap { SimilarityAcrossDrives.origin(.init(id: $0.id, name: $0.name,
            path: $0.path, bytes: $0.size, family: "text", localPath: $0.localPath, cloudId: nil, ancestors: []))?.0 }) == [.local,.icloud])
        fakeCloud.changed = true
        let collisionReport = report(collided, across: collision)
        collision.model.results.load(collisionReport, configuration: nil)
        try await until { !collision.model.results.isIndexing }
        let group = SimilarityResultGroup(id: "generated-collision", members: collisionReport.files!, minimumScore: 0.99, identical: false)
        collision.model.results.setFixtureGroups([group], at: 0.9)
        let blocked = collision.model.results.keepLargestPlan()!
        do {
            _ = try await collision.coordinator.keepSmallest!(blocked)
            preconditionFailure("A changed keeper/removal on any provider must prevent every mutation")
        } catch { }
        precondition(fakeLocal.deleteCalls == 0 && fakeCloud.deleteCalls == 0)
        print("PASS provider ID collisions stay distinct and cross-provider revision preflight prevents every deletion")

        let overlapRoot = root.appendingPathComponent("overlap")
        try fm.createDirectory(at: overlapRoot, withIntermediateDirectories: true)
        let overlap = SimilarityAcrossDrives(hub: hub)
        let overlapLocal = AcrossFixtureDrive(kind: .local, rootURL: overlapRoot)
        let overlapCloud = AcrossFixtureDrive(kind: .icloud, rootURL: overlapRoot)
        overlap.addNativeScope(native(overlapLocal), provider: overlapLocal)
        overlap.addNativeScope(native(overlapCloud), provider: overlapCloud)
        overlapLocal.scanDelay = 50_000_000
        let cloudFirst = try await sources(overlap)
        let cloudFirstRows = report(cloudFirst, across: overlap).files!
        overlapLocal.scanDelay = 0; overlapCloud.scanDelay = 50_000_000
        let localFirst = try await sources(overlap)
        let localFirstRows = report(localFirst, across: overlap).files!
        let expectedID = SimilarityAcrossDrives.fileID(drive: .local, originalID: "same-original")
        precondition(cloudFirstRows.count == 1 && localFirstRows.count == 1
                     && cloudFirstRows[0].id == expectedID && localFirstRows[0].id == expectedID
                     && cloudFirstRows[0].nativeScopeID == localFirstRows[0].nativeScopeID,
                     "Overlapping Local/iCloud ownership must not depend on which provider enumerates first")
        let resolver = overlap.model.resolveExternalSource!, memoryResolver = overlap.model.resolveExternalMemorySource!
        overlap.close()
        do {
            _ = try await resolver(expectedID, root.appendingPathComponent("unused-resolver-output"), { _ in })
            preconditionFailure("A captured source resolver must reject requests after owner shutdown")
        } catch { }
        do {
            _ = try await memoryResolver(expectedID, root.appendingPathComponent("unused-resolver.pipe"), 1_024, { _ in })
            preconditionFailure("A captured RAM resolver must reject requests after owner shutdown")
        } catch { }
        precondition(overlapLocal.materializeCalls == 0 && overlapCloud.materializeCalls == 0,
                     "Rejected late source requests must never access original provider content")
        print("PASS overlap delay reversal preserves one Local row and scope; captured resolvers perform no provider I/O after close")

        let hybrid = SimilarityAcrossDrives(hub: hub)
        let hybridRemoval = AcrossFixtureDrive(kind: .local, rootURL: root.appendingPathComponent("hybrid-local"), bytes: 100)
        let hybridKeeper = AcrossFixtureDrive(kind: .icloud, rootURL: root.appendingPathComponent("hybrid-icloud"), bytes: 500)
        hybrid.addNativeScope(native(hybridRemoval), provider: hybridRemoval)
        hybrid.addNativeScope(native(hybridKeeper), provider: hybridKeeper)
        hybrid.addCloudScope([.init(id: "generated-cloud-root", name: "Generated", path: "/Generated", isFolder: true, size: 0, ancestors: [])])
        let hybridSources = try await sources(hybrid)
        let nativeRows = report(hybridSources, across: hybrid).files!
        let cloudRows = [200,250].enumerated().map { index, bytes in SimilarityFile(id: "generated-cloud-row-\(index)",
            name: "generated-\(index).txt", path: "/Generated/generated-\(index).txt", bytes: UInt64(bytes), family: "text",
            localPath: nil, cloudId: "generated-cloud-id-\(index)", ancestors: []) }
        let hybridReport = report(files: nativeRows + cloudRows, across: hybrid)
        let hybridResults = hybrid.model.results
        hybridResults.load(hybridReport, configuration: nil)
        try await until { !hybridResults.isIndexing }
        hybridResults.setFixtureGroups([.init(id: "hybrid-group", members: hybridReport.files!, minimumScore: 0.99, identical: false)], at: 0.9)
        account.similarityTrashFixtureResponse = (1, "{\"trashed_ids\":[\"generated-cloud-id-0\"]}", "Generated partial acknowledgement")
        let partial = try await hybrid.coordinator.keepSmallest!(hybridResults.keepLargestPlan()!)
        precondition(partial == [cloudRows[0].id] && hybridRemoval.deleteCalls == 0 && hybridKeeper.deleteCalls == 0,
                     "Partial cloud acknowledgement must stop before native mutations")
        account.performFileUndo(redo: false)
        precondition(hybridResults.trashedIDs.isEmpty)
        account.similarityTrashFixtureResponse = nil
        hybridKeeper.onRefresh = {
            if account.canUndoFileAction { hybridKeeper.changed = true }
        }
        do {
            _ = try await hybrid.coordinator.keepSmallest!(hybridResults.keepLargestPlan()!)
            preconditionFailure("A keeper changed after cloud acknowledgement must block later native batches")
        } catch { }
        precondition(hybridRemoval.deleteCalls == 0 && hybridKeeper.deleteCalls == 0
                     && hybridResults.trashedIDs == Set(cloudRows.map(\.id)) && account.canUndoFileAction,
                     "Earlier cloud acknowledgements and their Undo must survive a later keeper failure")
        account.performFileUndo(redo: false)
        precondition(hybridResults.trashedIDs.isEmpty)
        hybridKeeper.onRefresh = nil; hybridKeeper.changed = false
        let mixedPlan = hybridResults.keepLargestPlan()!
        let complete = try await hybrid.coordinator.keepSmallest!(mixedPlan)
        precondition(complete == mixedPlan.removalIDs && hybridRemoval.deleteCalls == 1 && hybridKeeper.deleteCalls == 0,
                     "Cloud acknowledgement must not invalidate execution of the remaining native partition")
        print("PASS mixed cloud/native cleanup: partial cloud stop, keeper recheck between providers, earlier receipts/Undo preserved and complete multi-provider acknowledgements")

        let result = report(ac, across: across)
        across.model.results.load(result, configuration: nil)
        try await until { !across.model.results.isIndexing }
        across.model.results.setFixtureGroups([.init(id: "generated-cross-group", members: result.files!, minimumScore: 0.99, identical: false)], at: 0.9)
        let largest = across.model.results.keepLargestPlan()!
        precondition(largest.keepers.first?.bytes == 500 && largest.removals.first?.bytes == 100)
        across.model.results.keepSmallest(largest, using: across.coordinator.keepSmallest!)
        try await until { across.model.results.trashingIDs.isEmpty && !hub.local.isMutating }
        precondition(across.model.results.fileActionError == nil && !fm.fileExists(atPath: folders[0].appendingPathComponent("generated.txt").path)
                     && fm.fileExists(atPath: folders[2].appendingPathComponent("generated.txt").path))
        hub.local.undo(); try await until { !hub.local.isMutating }
        let restoredBytes = try Data(contentsOf: folders[0].appendingPathComponent("generated.txt"))
        precondition(restoredBytes == Data(repeating: 65, count: 100) && across.model.results.trashedIDs.isEmpty)
        print("PASS real generated cross-folder largest action keeps the other provider's 500-byte original and Undo restores 100-byte content plus combined row IDs")
    }
}

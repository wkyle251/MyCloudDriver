import AppKit
import Foundation

/// Records provider operations without touching a real cloud account or Trash.
private final class SimilarityActionDrive: NativeCloudDrive, @unchecked Sendable {
    let kind: CloudDriveKind
    let root: CloudDriveLocation
    let items: [CloudDriveItem]
    var item: CloudDriveItem { items[0] }
    var keeperMissing = false
    var keeperSizeChanged = false
    var changedRemoval = false
    var changedKeeperRevision = false
    private(set) var deleteCalls = 0
    private let lock = NSLock()
    private var removed = false
    var isTrashed: Bool { lock.lock(); defer { lock.unlock() }; return removed }
    init(_ kind: CloudDriveKind, batch: Bool = false) {
        self.kind = kind
        root = .init(id: "test-root", title: "Synthetic Drive", url: URL(fileURLWithPath: "/synthetic-drive"))
        let folder = root.url!
        items = (batch ? ["original-asset", "copy-b", "copy-c"] : ["original-asset"]).enumerated().map { index, id in
            .init(id: id, name: id + ".jpg", isFolder: false, bytes: UInt64(100 + index * 100),
                  url: kind == .photos ? nil : folder.appendingPathComponent(id + ".jpg"), revision: "scanned-" + id)
        }
    }
    private func setTrashed(_ value: Bool) { lock.lock(); removed = value; lock.unlock() }
    private func undo(restoring: Bool) -> CloudDriveUndo {
        .init(title: "Move to Trash") { self.setTrashed(!restoring); return self.undo(restoring: !restoring) }
    }
    func list(_ location: CloudDriveLocation, offset: Int, search: String) async throws -> CloudDrivePage {
        .init(items: isTrashed ? [] : items, total: isTrashed ? 0 : items.count)
    }
    func scanItems(_ items: [CloudDriveItem], location: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> [CloudDriveItem] { self.items }
    func delete(_ items: [CloudDriveItem], progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? {
        let expected = self.items.count > 1 ? Array(self.items.dropFirst()).map(\.id) : [item.id]
        precondition(Set(items.map(\.id)) == Set(expected), "Must trash only original non-keepers, never temporary previews")
        deleteCalls += 1
        try await Task.sleep(nanoseconds: 30_000_000)
        setTrashed(true)
        return kind == .photos ? nil : undo(restoring: true)
    }
    func refreshedItems(_ items: [CloudDriveItem]) async throws -> [CloudDriveItem] {
        if keeperMissing { throw CloudDriveError.message("Synthetic keeper is missing") }
        return items.map { item in
            var copy = item
            if keeperSizeChanged { copy.bytes = 999 }
            if (changedRemoval && item.id == "copy-b") || (changedKeeperRevision && item.id == "original-asset") {
                copy.revision = "edited-with-the-same-size"
            }
            return copy
        }
    }
    func materialize(_ item: CloudDriveItem, directory: URL, progress: @escaping CloudDriveProgressHandler) async throws -> URL { throw CocoaError(.featureUnsupported) }
    func createContainer(_ name: String, in location: CloudDriveLocation) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
    func rename(_ item: CloudDriveItem, to name: String) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
    func relocate(_ items: [CloudDriveItem], from: CloudDriveLocation, to: CloudDriveLocation, copy: Bool, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
    func importFiles(_ urls: [URL], into: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
}

@main struct SimilarityFileActionTests {
    @MainActor static func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(predicate(), "File action did not finish")
    }
    static func file(_ id: String, cloud: Bool = false, bytes: UInt64 = 100) -> SimilarityFile {
        .init(id: id, name: "\(id).jpg", path: "/Folder/\(id).jpg", bytes: bytes, family: "image", localPath: nil,
              cloudId: cloud ? id : nil, ancestors: [.init(id: "folder", name: "Folder")])
    }
    static func report(_ files: [SimilarityFile], source: SimilaritySource = .local) -> SimilarityReport {
        .init(source: source, scope: ["Synthetic"], status: "completed", threshold: 0.9,
              scannedFiles: UInt64(files.count), analysedFiles: UInt64(files.count), skippedFiles: 0, downloadedBytes: 0,
              totalGroups: 1, groups: [.init(id: "copies", matchKind: "byte_identical", family: "image", minimumScore: nil,
                                           memberCount: UInt64(files.count), members: files)],
              issues: [], truncated: false, coverage: "Synthetic", elapsedSeconds: 1, files: files, scoresRetained: 3)
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil); _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        try await testResultActions()
        try await testNativeTrash()
        try await testOutsideBrowserRoot()
        try await testPikPakTrash()
        try await testKeepSmallestPlanning()
        try await testNativeKeepSmallest()
        try await testLocalKeepSmallest()
        try await testPikPakKeepSmallest()
    }
    @MainActor static func testResultActions() async throws {
        let files = [file("a"), file("b"), file("c")], results = SimilarityResultsModel()
        results.load(report(files), configuration: nil)
        try await wait { !results.isIndexing }
        results.select("a")
        results.moveToTrash(files[1]) { _ in throw CloudDriveError.message("Synthetic provider failure") }
        try await wait { results.trashingIDs.isEmpty }
        precondition(results.fileActionError == "Synthetic provider failure" && results.visibleFileCount == 3 && results.related.count == 2)
        var calls = 0
        results.moveToTrash(files[1]) { _ in calls += 1; try await Task.sleep(nanoseconds: 40_000_000) }
        results.moveToTrash(files[1]) { _ in preconditionFailure("Double click must not delete twice") }
        try await wait { results.trashingIDs.isEmpty }
        precondition(calls == 1 && results.visibleFileCount == 2 && results.related.map(\.id) == ["c"])
        precondition(results.groups.first?.members.count == 2 && results.index?.files.count == 3, "Saved matrix inventory stays intact")
        results.setFixtureRow(.init(fileId: "a", entries: [.init(fileId: "b", score: 1), .init(fileId: "c", score: 0.99)], unavailable: [:], omitted: 0))
        results.retry(); try await wait { !results.isLoading }
        precondition(!results.related.contains { $0.id == "b" }, "Late saved rows cannot resurrect a trashed match")
        results.minimumScore = 0.05
        precondition(results.groups.first?.members.count == 2, "Regrouping must exclude trashed files")
        results.showAllFiles(); results.query = "Folder"
        try await Task.sleep(nanoseconds: 220_000_000)
        func ids(_ nodes: [SimilarityTreeNode]) -> [String] { nodes.flatMap { $0.file.map { [$0.id] } ?? ids($0.children) } }
        precondition(!ids(results.roots).contains("b"), "Folder search cannot restore hidden children")
        results.setTrashed("b", false)
        precondition(results.visibleFileCount == 3 && results.related.count == 2)
        results.setTrashed("a", true)
        precondition(results.selectedID == nil && results.related.isEmpty)
        print("PASS results: confirmed Trash only, duplicate clicks, late rows, grouping, folder search and Undo visibility")

        var complete: (() -> Void)?
        results.moveToTrash(files[2]) { _ in await withCheckedContinuation { continuation in complete = { continuation.resume() } } }
        try await wait { complete != nil }
        results.load(report(files), configuration: nil)
        complete?()
        try await wait { !results.isIndexing }
        precondition(results.trashedIDs.isEmpty && results.fileActionMessage == nil && results.trashingIDs.isEmpty)
        print("PASS closing/resetting results rejects late file-action feedback from the old session")
    }
    @MainActor static func testNativeTrash() async throws {
        for kind in [CloudDriveKind.local, .icloud, .photos] {
            let drive = SimilarityActionDrive(kind), model = NativeDriveModel(kind: kind)
            defer { model.close() }
            model.connect(drive); model.findSimilar([], presentWindow: false)
            let sources = try await model.similarity.local.inventoryExternalSources!()
            let source = sources[0]
            let original = SimilarityFile(id: source.id, name: source.name, path: source.path, bytes: source.size,
                                          family: "image", localPath: source.localPath, cloudId: nil, ancestors: [])
            let results = model.similarity.local.results
            results.load(report([original]), configuration: nil)
            try await wait { !results.isIndexing }
            results.moveToTrash(original, using: model.similarity.moveToTrash!)
            try await wait { results.trashingIDs.isEmpty }
            precondition(drive.isTrashed && results.visibleFileCount == 0 && results.fileActionError == nil)
            if kind != .photos {
                precondition(model.undoStack.count == 1)
                model.undo(); try await wait { !model.isMutating }
                precondition(!drive.isTrashed && results.visibleFileCount == 1)
                model.undo(redo: true); try await wait { !model.isMutating }
                precondition(drive.isTrashed && results.visibleFileCount == 0)
            } else { precondition(model.undoStack.isEmpty, "Photos assets restore in Recently Deleted, not PhotoKit Undo") }
        }
        print("PASS local/iCloud/Photos actions target original provider items, with correct Undo/Redo availability")
    }
    @MainActor static func testOutsideBrowserRoot() async throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("SimilarityTrash-\(UUID())")
        let browser = directory.appendingPathComponent("Browser"), scanned = directory.appendingPathComponent("Scanned")
        try fm.createDirectory(at: browser, withIntermediateDirectories: true)
        try fm.createDirectory(at: scanned, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let url = scanned.appendingPathComponent("Synthetic.txt")
        try Data("Synthetic test file".utf8).write(to: url)
        let model = NativeDriveModel(kind: .local); defer { model.close() }
        model.connect(ICloudDriveProvider(rootURL: browser, kind: .local)); model.useSimilarityFolder(scanned)
        let source = try await model.similarity.local.inventoryExternalSources!()[0]
        let original = SimilarityFile(id: source.id, name: source.name, path: source.path, bytes: source.size,
                                      family: "text", localPath: source.localPath, cloudId: nil, ancestors: [])
        model.similarity.local.results.load(report([original]), configuration: nil)
        try await wait { !model.similarity.local.results.isIndexing }
        // Picking the next scan's scope must not replace the old result's provider.
        model.useSimilarityFolder(browser)
        try await model.trashSimilarityFile(original)
        let removed = !fm.fileExists(atPath: url.path)
        let browserUnchanged = model.provider?.root.url?.path == browser.path
        model.undo(); try await wait { !model.isMutating }
        let restored = try Data(contentsOf: url)
        precondition(removed && browserUnchanged && fm.fileExists(atPath: url.path) && restored == Data("Synthetic test file".utf8))
        print("PASS an outside-root scan trashes the original local file and restores it intact without navigating Browser")
    }
    @MainActor static func testKeepSmallestPlanning() async throws {
        let a = file("a", bytes: 0), b = file("b", bytes: 0), c = file("c", bytes: 400), d = file("d", bytes: 500)
        func group(_ id: String, _ files: [SimilarityFile]) -> SimilarityResultGroup {
            .init(id: id, members: files, minimumScore: 0.95, identical: false)
        }
        let results = SimilarityResultsModel()
        results.load(report([a,b,c,d]), configuration: nil)
        try await wait { !results.isIndexing && !results.isGrouping }
        results.setFixtureGroups([group("one", [c,b,a]), group("two", [b,d])], at: 0.9)
        results.query = "a.jpg" // Search must not silently change group-action scope.
        let all = results.keepSmallestPlan()!
        precondition(Set(all.keepers.map(\.id)) == ["a","b"] && all.removalIDs == ["c","d"])
        precondition(all.bytesToRemove == 900, "Overlapping groups preserve every keeper; zero-byte ties keep one deterministically")
        let one = results.keepSmallestPlan(groupID: "one")!
        precondition(one.keepers.map(\.id) == ["a"] && one.removalIDs == ["b","c"])
        var calls = 0
        results.keepSmallest(one) { _ in calls += 1; try await Task.sleep(nanoseconds: 30_000_000); return ["c"] }
        results.keepSmallest(one) { _ in preconditionFailure("Must reject duplicate batch click") }
        try await wait { results.trashingIDs.isEmpty }
        precondition(calls == 1 && results.trashedIDs == ["c"] && results.fileActionError != nil)
        results.setTrashed("c", false)
        let stale = results.keepSmallestPlan()!
        results.minimumScore = 0.91
        results.keepSmallest(stale) { _ in preconditionFailure("Must reject stale grouping snapshot") }
        precondition(results.trashedIDs.isEmpty)
        results.minimumScore = 0.9
        let finish = results.keepSmallestPlan(groupID: "one")!
        results.keepSmallest(finish) { $0.removalIDs }
        try await wait { results.trashingIDs.isEmpty }
        precondition(results.selectedID == "a" && !results.browseGroups && results.query.isEmpty)
        precondition(results.trashedIDs == ["b","c"] && results.index?.files.count == 4)
        results.reset(); results.load(report([a,b,c]), configuration: nil)
        try await wait { !results.isIndexing }
        var complete: (() -> Void)?
        let old = results.keepSmallestPlan()!
        results.keepSmallest(old) { plan in
            await withCheckedContinuation { continuation in complete = { continuation.resume() } }
            return plan.removalIDs
        }
        try await wait { complete != nil }
        results.load(report([a,b,c]), configuration: nil); complete?()
        try await wait { !results.isIndexing }
        precondition(results.trashedIDs.isEmpty && results.fileActionMessage == nil)
        print("PASS smallest planning: zero bytes, deterministic ties, overlapping groups, search scope, partial acknowledgement, double click, stale groups and new-session isolation")
    }
    @MainActor static func testNativeKeepSmallest() async throws {
        for kind in [CloudDriveKind.local, .icloud, .photos] {
            let drive = SimilarityActionDrive(kind, batch: true), model = NativeDriveModel(kind: kind)
            defer { model.close() }
            model.connect(drive); model.findSimilar([], presentWindow: false)
            let sources = try await model.similarity.local.inventoryExternalSources!()
            let files = sources.map { source in SimilarityFile(id: source.id, name: source.name, path: source.path,
                bytes: source.size, family: "image", localPath: source.localPath, cloudId: nil, ancestors: []) }
            let results = model.similarity.local.results
            results.load(report(files), configuration: nil)
            try await wait { !results.isIndexing && !results.isGrouping }
            let plan = results.keepSmallestPlan()!
            for missing in [true, false] {
                drive.keeperMissing = missing; drive.keeperSizeChanged = !missing
                results.keepSmallest(plan, using: model.similarity.keepSmallest!)
                try await wait { results.trashingIDs.isEmpty }
                precondition(drive.deleteCalls == 0 && results.trashedIDs.isEmpty && results.fileActionError != nil)
            }
            drive.keeperSizeChanged = false
            for changesKeeper in [false, true] {
                drive.changedRemoval = !changesKeeper; drive.changedKeeperRevision = changesKeeper
                results.keepSmallest(plan, using: model.similarity.keepSmallest!)
                try await wait { results.trashingIDs.isEmpty }
                precondition(drive.deleteCalls == 0 && results.trashedIDs.isEmpty && results.fileActionError != nil,
                             "Same-size edits to either removals or keepers must require a rescan, including Photos")
            }
            drive.changedRemoval = false; drive.changedKeeperRevision = false
            results.keepSmallest(plan, using: model.similarity.keepSmallest!)
            try await wait { results.trashingIDs.isEmpty && !model.isMutating }
            precondition(drive.deleteCalls == 1 && results.visibleFileCount == 1 && results.fileActionError == nil)
            if kind != .photos {
                precondition(model.undoStack.count == 1, "The whole batch must have one Undo")
                model.undo(); try await wait { !model.isMutating }
                precondition(results.visibleFileCount == 3 && !drive.isTrashed)
                model.undo(redo: true); try await wait { !model.isMutating }
                precondition(results.visibleFileCount == 1 && drive.isTrashed)
            } else { precondition(model.undoStack.isEmpty) }
        }
        print("PASS native keep-smallest: verifies retained original, blocks missing/changed keepers, uses one provider batch and one Undo/Redo")
    }
    @MainActor static func testLocalKeepSmallest() async throws {
        let fm = FileManager.default, directory = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("KeepSmallest-\(UUID())")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        let urls = ["small.txt", "medium.txt", "large.txt"].map { directory.appendingPathComponent($0) }
        for (index, url) in urls.enumerated() { try Data(repeating: UInt8(65 + index), count: (index + 1) * 100).write(to: url) }
        let model = NativeDriveModel(kind: .local); defer { model.close() }
        model.connect(ICloudDriveProvider(rootURL: directory, kind: .local)); model.findSimilar([], presentWindow: false)
        let sources = try await model.similarity.local.inventoryExternalSources!()
        let files = sources.map { source in SimilarityFile(id: source.id, name: source.name, path: source.path,
            bytes: source.size, family: "text", localPath: source.localPath, cloudId: nil, ancestors: []) }
        let results = model.similarity.local.results
        results.load(report(files), configuration: nil); try await wait { !results.isIndexing }
        results.keepSmallest(results.keepSmallestPlan()!, using: model.similarity.keepSmallest!)
        try await wait { results.trashingIDs.isEmpty && !model.isMutating }
        precondition(results.fileActionError == nil && fm.fileExists(atPath: urls[0].path)
                     && !fm.fileExists(atPath: urls[1].path) && !fm.fileExists(atPath: urls[2].path))
        model.undo(); try await wait { !model.isMutating }
        for (index, url) in urls.enumerated() {
            let data = try Data(contentsOf: url)
            precondition(data == Data(repeating: UInt8(65 + index), count: (index + 1) * 100))
        }
        print("PASS real synthetic Local Disk batch: keeps smallest original, trashes the others, restores every byte with one Undo")
    }
    @MainActor static func testPikPakKeepSmallest() async throws {
        let suite = "SimilarityKeepSmallest-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = DownloaderModel.finderWorkspaceFixture(defaults: defaults)
        defer { account.stopForWindowClose() }
        let files = [file("keeper", cloud: true, bytes: 10), file("copy1", cloud: true, bytes: 20), file("copy2", cloud: true, bytes: 30)]
        let results = account.fileSimilarity.cloud.results
        results.load(report(files, source: .cloud), configuration: nil)
        try await wait { !results.isIndexing }
        account.similarityTrashFixtureResponse = (1, "{\"trashed_ids\":[\"copy1\"]}", "Synthetic second batch failed")
        results.keepSmallest(results.keepSmallestPlan()!, using: account.fileSimilarity.keepSmallest!)
        try await wait { results.trashingIDs.isEmpty }
        precondition(results.trashedIDs == ["copy1"] && results.fileActionError != nil && account.canUndoFileAction)
        account.performFileUndo(redo: false)
        precondition(results.trashedIDs.isEmpty)
        account.similarityTrashFixtureResponse = nil
        account.activateSharedLink(account.sharedLinks[0].id)
        let shared = account.browserItems.map(\.id), selection = account.selectedBrowserItemIDs
        results.keepSmallest(results.keepSmallestPlan()!, using: account.fileSimilarity.keepSmallest!)
        try await wait { results.trashingIDs.isEmpty }
        precondition(results.trashedIDs == ["copy1","copy2"] && results.fileActionError == nil)
        precondition(account.browserItems.map(\.id) == shared && account.selectedBrowserItemIDs == selection)
        account.performFileUndo(redo: false)
        precondition(results.trashedIDs.isEmpty, "One Undo restores the complete acknowledged batch")
        print("PASS PikPak smallest batch: partial acknowledgement, retained keeper, account-owned batch Undo, shared-link isolation")
    }
    @MainActor static func testPikPakTrash() async throws {
        let suite = "SimilarityPikPakActions-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = DownloaderModel.finderWorkspaceFixture(defaults: defaults)
        let other = DownloaderModel.finderWorkspaceFixture(defaults: defaults, workspaceSessionID: "secondary")
        defer { account.stopForWindowClose(); other.stopForWindowClose() }
        let item = account.browserItems.first { !$0.isFolder }!
        let original = SimilarityFile(id: item.id, name: item.name, path: "/\(item.name)", bytes: item.size,
            family: "text", localPath: nil, cloudId: item.id, ancestors: [])
        let results = account.fileSimilarity.cloud.results
        results.load(report([original], source: .cloud), configuration: nil)
        try await wait { !results.isIndexing }
        for response: (Int32, String, String) in [(0, "{\"trashed_ids\":[]}", ""), (1, "", "Synthetic network failure")] {
            account.similarityTrashFixtureResponse = response
            do { try await account.trashSimilarityFile(original); preconditionFailure("An unconfirmed Trash must fail") } catch { }
            precondition(results.trashedIDs.isEmpty && !account.canUndoFileAction)
        }
        account.similarityTrashFixtureResponse = nil
        account.activateSharedLink(account.sharedLinks[0].id)
        precondition(account.isBrowsingSharedLink)
        let sharedItems = account.browserItems.map(\.id), sharedSelection = account.selectedBrowserItemIDs
        account.isUploading = true
        try await account.trashSimilarityFile(original)
        account.isUploading = false
        precondition(account.isBrowsingSharedLink && account.browserItems.map(\.id) == sharedItems
                     && account.selectedBrowserItemIDs == sharedSelection, "A result action must leave the visible shared-link workspace alone")
        _ = account.activateAccountBrowser()
        precondition(!account.browserItems.contains { $0.id == original.cloudId }, "The saved account Browser must reflect confirmed Trash")
        precondition(results.trashedIDs.contains(original.id) && account.canUndoFileAction && !other.canUndoFileAction)
        do { try await other.trashSimilarityFile(original); preconditionFailure("Must reject another window's result") } catch { }
        account.performFileUndo(redo: false)
        precondition(results.trashedIDs.isEmpty)
        account.performFileUndo(redo: true)
        precondition(results.trashedIDs.contains(original.id))
        account.fileSimilarity.cloud.clearAccount()
        do { try await account.trashSimilarityFile(original); preconditionFailure("An old-account result must not be deleted") } catch { }
        print("PASS PikPak rejects unconfirmed Trash, retains account-owned Undo/Redo and rejects stale or foreign results")
    }
}

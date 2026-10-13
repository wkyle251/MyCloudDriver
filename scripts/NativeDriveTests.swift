import AppKit
import Foundation
import Photos

private final class SyntheticPhotosDrive: NativeCloudDrive, @unchecked Sendable {
    let kind = CloudDriveKind.photos
    let root = CloudDriveLocation(id: "photos:root", title: "Synthetic Photos", isLibrary: true)
    let files: [URL]
    let delay: UInt64
    let afterFirst: (@Sendable () async throws -> Void)?
    private let lock = NSLock()
    private var requested: [String] = []
    var fetchedIDs: [String] { lock.lock(); defer { lock.unlock() }; return requested }
    private func record(_ id: String) { lock.lock(); requested.append(id); lock.unlock() }
    init(files: [URL], delay: UInt64 = 0, afterFirst: (@Sendable () async throws -> Void)? = nil) {
        self.files = files; self.delay = delay; self.afterFirst = afterFirst
    }
    func list(_ location: CloudDriveLocation, offset: Int, search: String) async throws -> CloudDrivePage {
        let items = files.enumerated().map { index, url in CloudDriveItem(id: "asset:synthetic-\(index)", name: url.lastPathComponent, isFolder: false, canRename: false) }
        return .init(items: items.filter { search.isEmpty || $0.name.contains(search) }, total: items.count)
    }
    func materialize(_ item: CloudDriveItem, directory: URL, progress: @escaping CloudDriveProgressHandler) async throws -> URL {
        record(item.id)
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        let index = Int(item.id.split(separator: "-").last!)!
        let folder = directory.appendingPathComponent("asset-\(index)")
        try CloudDriveFiles.privateDirectory(folder)
        let target = folder.appendingPathComponent(item.name)
        try await CloudDriveFiles.detached { try FileManager.default.copyItem(at: self.files[index], to: target) }
        return target
    }
    func scanItems(_ items: [CloudDriveItem], location: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> [CloudDriveItem] {
        items.isEmpty ? try await list(root, offset: 0, search: "").items : items
    }
    func discoverItems(_ items: [CloudDriveItem], location: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler,
                       found: @escaping @Sendable (CloudDriveItem) -> Void) async throws {
        for (index, item) in try await scanItems(items, location: location, progress: progress).enumerated() {
            try Task.checkCancellation()
            found(item)
            if index == 0 { try await afterFirst?() }
        }
    }
    func createContainer(_ name: String, in location: CloudDriveLocation) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
    func rename(_ item: CloudDriveItem, to name: String) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
    func relocate(_ items: [CloudDriveItem], from: CloudDriveLocation, to: CloudDriveLocation, copy: Bool, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
    func importFiles(_ urls: [URL], into: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
    func delete(_ items: [CloudDriveItem], progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
}

@main struct NativeDriveTests {
    @MainActor static func wait(_ condition: () -> Bool, seconds: Double = 30) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(condition(), "Operation did not finish")
    }
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func increment() { lock.lock(); count += 1; lock.unlock() }
    }

    /// The size walk sums prefetched attributes instead of building items; it
    /// must still count exactly the files a full item scan finds.
    static func measurementTests(in root: URL) async throws {
        let manager = FileManager.default
        let folder = root.appendingPathComponent("Measure"), outside = root.appendingPathComponent("MeasureOutside")
        for directory in [folder.appendingPathComponent("A/B"), folder.appendingPathComponent("Many"),
                          folder.appendingPathComponent(".hidden-folder"), outside] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for (index, path) in ["one.txt", "A/two.bin", "A/B/three.dat", "A/B/four.dat"].enumerated() {
            try Data(repeating: UInt8(index), count: 1_000 * (index + 1)).write(to: folder.appendingPathComponent(path))
        }
        for index in 0..<1_500 { try Data([1]).write(to: folder.appendingPathComponent("Many/\(index).txt")) }
        for name in ["Ünïcode e\u{301}.txt", "%20 #1.txt"] { try Data([1]).write(to: folder.appendingPathComponent(name)) }
        try Data(count: 50_000).write(to: folder.appendingPathComponent(".hidden.txt"))
        try Data(count: 70_000).write(to: folder.appendingPathComponent(".hidden-folder/inside.txt"))
        try Data(count: 90_000).write(to: outside.appendingPathComponent("linked.txt"))
        try manager.createSymbolicLink(at: folder.appendingPathComponent("A/Link"), withDestinationURL: outside)
        let unused = root.appendingPathComponent("MeasureStaging")
        for kind in [CloudDriveKind.local, .icloud] {
            let provider = ICloudDriveProvider(rootURL: folder, kind: kind), updates = Counter()
            var started = Date()
            let whole = try await provider.measureFiles([], location: provider.root, directory: unused) { _ in updates.increment() }
            let walkTime = Date().timeIntervalSince(started)
            started = Date()
            let scanned = try await provider.scanItems([], location: provider.root) { _ in }
            let scanTime = Date().timeIntervalSince(started)
            precondition(whole == CloudDriveMeasurement(files: 1_506, bytes: 11_502), "\(kind): \(whole)")
            precondition(whole == CloudDriveMeasurement(files: scanned.count, bytes: scanned.reduce(0) { $0 + ($1.bytes ?? 0) }),
                         "size walk and item scan disagree")
            precondition(updates.value <= 10, "progress is throttled, not sent per file (\(updates.value))")
            let a = try ICloudDriveProvider.item(folder.appendingPathComponent("A"))
            let b = try ICloudDriveProvider.item(folder.appendingPathComponent("A/B"))
            // Listed items are built from their resolved folder plus their name;
            // they must keep the identity a full item scan gives the same file.
            let page = try await provider.list(provider.root, offset: 0, search: "")
            let scannedIDs = Set(scanned.map(\.id))
            let unmatched = page.items.filter { !$0.isFolder && !scannedIDs.contains($0.id) }.map(\.id)
            precondition(page.items.count == 5 && unmatched.isEmpty,
                         "listing and scan disagree on file identity: \(page.items.count) items, unmatched \(unmatched)")
            for listed in page.items {
                let resolved = try ICloudDriveProvider.item(listed.url!)
                precondition(listed.id == resolved.id && listed.url == resolved.url && listed.name == resolved.name
                             && listed.isFolder == resolved.isFolder && listed.bytes == resolved.bytes, "\(listed.id)")
            }
            let overlapping = try await provider.measureFiles([a, b], location: provider.root, directory: unused) { _ in }
            precondition(overlapping == CloudDriveMeasurement(files: 3, bytes: 9_000), "a folder and its subfolder count once")
            // The same walk reports every folder's own total, so Calculate on a
            // parent can size all of its subfolders without another pass.
            let expected: [String: UInt64] = [
                ICloudDriveProvider.folderID(folder.resolvingSymlinksInPath()): 11_502, a.id: 9_000, b.id: 7_000,
                try ICloudDriveProvider.item(folder.appendingPathComponent("Many")).id: 1_500,
            ]
            precondition(whole.folders == expected, "\(kind): folder totals \(whole.folders) != \(expected)")
            let base = folder.resolvingSymlinksInPath().path
            let scannedFolders = scanned.reduce(into: [String: UInt64]()) { result, file in
                var parent = file.url!.deletingLastPathComponent()
                while parent.path.hasPrefix(base) {
                    result[ICloudDriveProvider.folderID(parent), default: 0] += file.bytes ?? 0
                    parent.deleteLastPathComponent()
                }
            }
            for (id, bytes) in whole.folders { precondition(scannedFolders[id] == bytes, "\(kind): \(id) disagrees with item scan") }
            let listedFolders = Set(page.items.filter(\.isFolder).map(\.id)).union([a.id])
            precondition(listedFolders.isSubset(of: Set(whole.folders.keys)), "every listed folder id must have a total")
            precondition(overlapping.folders == [a.id: 9_000, b.id: 7_000],
                         "\(kind): a folder includes its measured subfolder: \(overlapping.folders)")
            print("  \(kind): size walk \(String(format: "%.3f", walkTime))s, item scan \(String(format: "%.3f", scanTime))s")
        }
        print("PASS Local Disk and iCloud size walks match item scans without hidden items, symbolic links or double counting")
    }

    static func rejects(_ action: () async throws -> Void) async {
        do { try await action(); preconditionFailure("Unsafe operation unexpectedly succeeded") }
        catch { }
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("MyCloudDriverTests-\(UUID().uuidString)")
        try CloudDriveFiles.privateDirectory(root)
        defer { try? manager.removeItem(at: root) }
        let drive = root.appendingPathComponent("Drive"), outside = root.appendingPathComponent("Outside")
        try manager.createDirectory(at: drive, withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        let provider = ICloudDriveProvider(rootURL: drive), progress: CloudDriveProgressHandler = { _ in }
        let text = Data(String(repeating: "Synthetic garden notes, oak trees and flowers. ", count: 60).utf8)
        let externalFile = outside.appendingPathComponent("Garden.txt")
        try text.write(to: externalFile)
        for name in [".", "..", "../outside", "a/b", "a:b", " ", "a\n"] {
            if name == "a\n" { continue } // trailing whitespace is deliberately trimmed
            precondition((try? CloudDriveFiles.validName(name)) == nil)
        }
        await rejects { _ = try await provider.list(.init(id: "outside", title: "Outside", url: outside), offset: 0, search: "") }
        try manager.createSymbolicLink(at: drive.appendingPathComponent("Link"), withDestinationURL: outside)
        let page = try await provider.list(provider.root, offset: 0, search: "")
        precondition(page.items.isEmpty)
        await rejects { _ = try await provider.list(.init(id: "link", title: "Link", url: drive.appendingPathComponent("Link")), offset: 0, search: "") }
        await rejects { _ = try await provider.rename(try ICloudDriveProvider.item(drive), to: "OtherDrive") }
        print("PASS root boundaries, symbolic-link exclusion and name validation")
        try await measurementTests(in: root)

        let imported = try await provider.importFiles([externalFile], into: provider.root, progress: progress)!
        let localFile = drive.appendingPathComponent("Garden.txt")
        precondition(manager.contents(atPath: localFile.path) == text)
        await rejects { _ = try await provider.importFiles([externalFile], into: provider.root, progress: progress) }
        precondition((try? Data(contentsOf: localFile)) == text)
        let item = try ICloudDriveProvider.item(localFile)
        let rename = try await provider.rename(item, to: "Notes.txt")!
        let renameRedo = try await rename.apply(); _ = try await renameRedo.apply(); _ = try await rename.apply()
        precondition(manager.fileExists(atPath: localFile.path))
        _ = try await provider.createContainer("Destination", in: provider.root)
        let folder = drive.appendingPathComponent("Destination")
        let move = try await provider.relocate([item], from: provider.root, to: .init(id: folder.absoluteString, title: "Destination", url: folder), copy: false, progress: progress)!
        precondition(!manager.fileExists(atPath: localFile.path))
        _ = try await move.apply()
        let trash = try await provider.delete([item], progress: progress)!
        let redoTrash = try await trash.apply(); let restore = try await redoTrash.apply(); _ = try await restore.apply()
        precondition((try? Data(contentsOf: localFile)) == text)
        let restoreImport = try await imported.apply(); _ = try await restoreImport.apply()
        print("PASS import collision safety, rename/move and repeated Trash Undo/Redo")

        let nested = outside.appendingPathComponent("Nested")
        try manager.createDirectory(at: nested.appendingPathComponent("Child"), withIntermediateDirectories: true)
        try text.write(to: nested.appendingPathComponent("Child/Copy.txt"))
        _ = try await provider.importFiles([nested], into: provider.root, progress: progress)
        precondition((try? Data(contentsOf: drive.appendingPathComponent("Nested/Child/Copy.txt"))) == text)
        let duplicateBatch = outside.appendingPathComponent("Batch.txt"); try text.write(to: duplicateBatch)
        await rejects { _ = try await provider.importFiles([duplicateBatch, externalFile], into: provider.root, progress: progress) }
        precondition(!manager.fileExists(atPath: drive.appendingPathComponent("Batch.txt").path))
        print("PASS recursive folder copying and batch rollback")

        try manager.createDirectory(at: drive.appendingPathComponent("Empty/Child"), withIntermediateDirectories: true)
        try Data().write(to: drive.appendingPathComponent(".DS_Store"))
        var empty = try await provider.cleanupCandidates(in: provider.root, empty: true, progress: progress)
        precondition(empty.contains(where: { $0.name == "Empty" }) && !empty.contains(where: { $0.name == "Child" }))
        let chosen = empty.first(where: { $0.name == "Empty" })!
        let arrived = drive.appendingPathComponent("Empty/Arrived.txt"); try text.write(to: arrived)
        await rejects { _ = try await provider.cleanup([chosen], empty: true, progress: progress) }
        precondition(manager.fileExists(atPath: arrived.path))
        try manager.removeItem(at: arrived)
        empty = try await provider.cleanupCandidates(in: provider.root, empty: true, progress: progress)
        let cleanup = try await provider.cleanup(empty, empty: true, progress: progress)!
        _ = try await cleanup.apply()
        let stores = try await provider.cleanupCandidates(in: provider.root, empty: false, progress: progress)
        precondition(stores.count == 1)
        _ = try await (try await provider.cleanup(stores, empty: false, progress: progress)!).apply()
        print("PASS recursive cleanup, review revalidation and Undo")

        for name in ["MergeA", "MergeB"] { try manager.createDirectory(at: drive.appendingPathComponent(name), withIntermediateDirectories: true) }
        try text.write(to: drive.appendingPathComponent("MergeB/Other.txt"))
        let merges = try ["MergeA", "MergeB"].map { try ICloudDriveProvider.item(drive.appendingPathComponent($0)) }
        let merge = try await provider.merge(merges, progress: progress)!
        precondition(manager.fileExists(atPath: drive.appendingPathComponent("MergeA/Other.txt").path))
        let mergeRedo = try await merge.apply(); let mergeUndo = try await mergeRedo.apply(); _ = try await mergeUndo.apply()
        precondition(manager.fileExists(atPath: drive.appendingPathComponent("MergeB/Other.txt").path))
        print("PASS merging folders and compound Undo/Redo")

        let plan = PhotosAlbumMembershipPlan(selected: ["a", "b", "outside"], source: ["a", "b", "c"], destination: ["a", "d"], move: true, sameAlbum: false)
        precondition(plan.added == ["b", "outside"] && plan.removed == ["a", "b"])
        let same = PhotosAlbumMembershipPlan(selected: ["a"], source: ["a"], destination: ["a"], move: true, sameAlbum: true)
        precondition(same.added.isEmpty && same.removed.isEmpty)
        print("PASS Photos album deltas preserve existing membership and unrelated assets")

        // Exercise permission and app connection independently, without touching
        // the user's Photos permission, account or library.
        let connectionPreferencesName = "MyCloudDriver.PhotosConnectionTests.\(UUID().uuidString)"
        let connectionPreferences = UserDefaults(suiteName: connectionPreferencesName)!
        defer { connectionPreferences.removePersistentDomain(forName: connectionPreferencesName) }
        var authorization = PHAuthorizationStatus.authorized
        var permissionRequests = 0, providerCreations = 0
        let access = PhotosAccessClient(status: { authorization }, request: {
            permissionRequests += 1
            try? await Task.sleep(nanoseconds: 60_000_000)
            authorization = .authorized; return authorization
        }, provider: {
            providerCreations += 1; return SyntheticPhotosDrive(files: [externalFile])
        })
        func connectionHub() -> CloudDriveHub {
            CloudDriveHub(pikpak: DownloaderModel.finderWorkspaceFixture(defaults: connectionPreferences),
                defaults: connectionPreferences, photosAccess: access, localRootURL: drive)
        }
        let connections = connectionHub()
        try await wait { !connections.photos.isLoading }
        precondition(connections.photos.isConnected && providerCreations == 1)
        connections.photos.enter(.init(id: "album:test", name: "Test Album", isFolder: true))
        try await wait { !connections.photos.isLoading }
        connections.photos.selection = Set(connections.photos.items.map(\.id))
        let checkedLocation = connections.photos.location, checkedSelection = connections.photos.selection
        _ = connections.photos.run("Synthetic undo") { _, _ in
            CloudDriveUndo(title: "Preserve this undo") { throw CocoaError(.featureUnsupported) }
        }
        try await wait { !connections.photos.isBusy }
        let checkedUndo = connections.photos.undoStack.map(\.id)
        let ongoing = connections.photos.run("Synthetic transfer", transferDirection: 0) { _, _ in
            try await Task.sleep(nanoseconds: 100_000_000); return nil
        }!
        connections.disconnectPhotos()
        precondition(connections.photos.isConnected && connections.photosFeedback?.isError == true)
        let check = connections.connectPhotos()
        precondition(connections.connectingPhotos, "A pending check must be visible immediately")
        await check?.value
        precondition(!connections.connectingPhotos && connections.photosLastChecked != nil && connections.photosFeedback?.isError == false)
        precondition(providerCreations == 1 && permissionRequests == 0, "Checking existing access must not reset or re-request the library")
        precondition(connections.photos.location == checkedLocation && connections.photos.selection == checkedSelection)
        precondition(connections.photos.undoStack.map(\.id) == checkedUndo)
        try await wait { !connections.photos.isBusy }
        precondition(connections.photos.activity.records.first { $0.id == ongoing }?.state == "Completed")
        connections.photos.reload(); connections.disconnectPhotos()
        precondition(!connections.photos.isConnected && !connections.photos.isLoading && connections.hasPhotosPermission)
        precondition(connections.photosConnectionTitle == "Disconnected")
        let relaunched = connectionHub()
        precondition(!relaunched.photos.isConnected && providerCreations == 1, "Explicit disconnect must survive relaunch")
        relaunched.refreshPhotosAuthorization()
        precondition(!relaunched.photos.isConnected, "Refreshing macOS permission must not reconnect a disconnected library")
        await relaunched.connectPhotos()?.value
        precondition(relaunched.photos.isConnected && providerCreations == 2)
        let reconnectedLaunch = connectionHub()
        precondition(reconnectedLaunch.photos.isConnected && providerCreations == 3)
        reconnectedLaunch.close(); relaunched.disconnectPhotos()
        for denied in [PHAuthorizationStatus.denied, .restricted] {
            authorization = denied
            await relaunched.connectPhotos()?.value
            precondition(!relaunched.photos.isConnected && relaunched.photosFeedback?.isError == true && permissionRequests == 0)
        }
        authorization = .limited
        await relaunched.connectPhotos()?.value
        precondition(relaunched.photos.isConnected && relaunched.photosPermissionTitle.contains("Limited"))
        authorization = .denied; relaunched.refreshPhotosAuthorization()
        precondition(!relaunched.photos.isConnected && !relaunched.hasPhotosPermission)
        authorization = .notDetermined
        let permission = relaunched.connectPhotos()
        _ = relaunched.connectPhotos() // A repeated click must share the pending check.
        await permission?.value
        precondition(relaunched.photos.isConnected && permissionRequests == 1)
        relaunched.disconnectPhotos(); authorization = .notDetermined
        let cancelledConnection = relaunched.connectPhotos()
        try await Task.sleep(nanoseconds: 10_000_000)
        let creationsBeforeClose = providerCreations
        relaunched.close(); await cancelledConnection?.value
        precondition(!relaunched.photos.isConnected && !relaunched.connectingPhotos && providerCreations == creationsBeforeClose,
            "A late permission response must not reconnect a closed app")
        connections.close()
        print("PASS Photos check feedback, retained selection/Undo/transfer, persistent disconnect, denied/limited access, permission changes and late-response cancellation")

        let model = NativeDriveModel(kind: .icloud, temporaryRoot: root.appendingPathComponent("iCloudTemp"))
        model.connect(provider); try await wait { !model.isLoading }
        // The provider canonicalizes /var to /private/var. Select the actual
        // listed ID, not the earlier fixture URL alias, and verify resolution.
        let listedItem = model.items.first { $0.name == item.name }!
        model.selection = [listedItem.id]; model.sort(by: 2); try await Task.sleep(nanoseconds: 40_000_000)
        precondition(model.selection == [listedItem.id] && model.selectedItems.map(\.id) == [listedItem.id])
        model.query = "Garden"; model.reload(); model.query = "Other"; model.reload()
        try await wait { !model.isLoading }; precondition(model.items.isEmpty)
        model.query = ""; model.reload(); try await wait { !model.isLoading }
        print("PASS asynchronous listing, stale search cancellation and selection preservation")
        model.toggleSort(.name); model.disconnect()
        try await Task.sleep(nanoseconds: 40_000_000)
        precondition(model.items.isEmpty, "A pending sort must not restore files from a disconnected drive")
        model.connect(provider); try await wait { !model.isLoading }

        let preferencesName = "MyCloudDriver.WorkspaceTests.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: preferencesName)!
        defer { preferences.removePersistentDomain(forName: preferencesName) }
        let hub = CloudDriveHub(pikpak: DownloaderModel.finderWorkspaceFixture(defaults: preferences),
            defaults: preferences, restoreConnections: false, localRootURL: drive)
        hub.photos.connect(SyntheticPhotosDrive(files: Array(repeating: externalFile, count: 4)))
        try await wait { !hub.photos.isLoading }
        let photoItems = hub.photos.items
        hub.photos.select(photoItems[0], extending: false, toggling: false)
        hub.photos.moveSelection(1, extending: true); hub.photos.moveSelection(1, extending: true)
        precondition(hub.photos.selection == Set(photoItems.prefix(3).map(\.id)))
        hub.photos.moveSelection(-1, extending: true)
        precondition(hub.photos.selection == Set(photoItems.prefix(2).map(\.id)))
        hub.photos.moveSelection(1)
        precondition(hub.photos.selection == [photoItems[2].id] && hub.photos.focusedItemID == photoItems[2].id)
        hub.icloud.connect(provider); try await wait { !hub.icloud.isLoading }
        hub.icloud.selection = Set(hub.icloud.items.prefix(1).map(\.id))
        let retainedSelection = hub.icloud.selection
        let transfer = hub.icloud.run("Same display title", transferDirection: 0) { _, progress in
            progress(.init(message: "Downloading", completed: 1, total: 2))
            try await Task.sleep(nanoseconds: 120_000_000)
            return nil
        }!
        hub.pikpakNavigation.showImmediately(1)
        for kind in CloudDriveKind.allCases {
            hub.open(kind)
            precondition(hub.pikpakNavigation.section == 0, "Entering a drive must open Browser")
        }
        var stalePreparationRan = false
        hub.pikpakNavigation.select(3, needsLoading: true) { stalePreparationRan = true; return true }
        hub.open(.icloud)
        await hub.pikpakNavigation.waitForPreparation()
        precondition(!stalePreparationRan && hub.pikpakNavigation.section == 0 && !hub.pikpakNavigation.isSwitching)
        try await wait { !hub.icloud.isBusy }
        precondition(hub.icloud.activity.records.first { $0.id == transfer }?.state == "Completed",
            "Drive switches must not cancel a running transfer")
        precondition(hub.icloud.selection == retainedSelection && hub.icloud.location == provider.root)
        let uploadID = hub.icloud.activity.begin("Same display title", transferDirection: 1)
        hub.icloud.activity.update(uploadID, .init(message: "Preparing", fraction: .nan))
        _ = hub.icloud.activity.begin("Export files") // A maintenance title must not imply a direction.
        let downloads = NativeTransferSnapshot(records: hub.icloud.activity.records, direction: 0)
        let uploads = NativeTransferSnapshot(records: hub.icloud.activity.records, direction: 1)
        precondition(downloads.records.count == 1 && downloads.completed.count == 1 && downloads.fraction == 1)
        precondition(uploads.records.count == 1 && uploads.active.count == 1 && uploads.fraction == nil)
        hub.icloud.activity.update(uploadID, .init(message: "Uploading", completed: 3, total: 4))
        precondition(NativeTransferSnapshot(records: hub.icloud.activity.records, direction: 1).fraction == 0.75)
        hub.icloud.activity.finish(uploadID, error: CancellationError())
        let cancelled = NativeTransferSnapshot(records: hub.icloud.activity.records, direction: 1)
        precondition(cancelled.active.isEmpty && cancelled.failed.count == 1 && cancelled.fraction == nil)
        precondition(NativeTransferSnapshot(records: hub.photos.activity.records, direction: 0).records.isEmpty)
        hub.close()
        print("PASS Browser entry navigation, pending-switch cancellation, retained selection, uninterrupted transfers and independent direction/status counters")

        guard CommandLine.arguments.count > 1 else { model.close(); print("PASS native drive model tests (pass app Resources for engine integration)"); return }
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let scans = root.appendingPathComponent("ScanFiles"); try manager.createDirectory(at: scans, withIntermediateDirectories: true)
        for name in ["one.txt", "two.txt"] { try text.write(to: scans.appendingPathComponent(name)) }
        for name in [".gitignore", ".DS_Store"] { try text.write(to: scans.appendingPathComponent(name)) }
        try manager.createDirectory(at: scans.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try text.write(to: scans.appendingPathComponent(".git/ignored.txt"))
        let photo = NativeDriveModel(kind: .photos, temporaryRoot: root.appendingPathComponent("PhotosTemp"))
        photo.connect(SyntheticPhotosDrive(files: [scans.appendingPathComponent("one.txt"), scans.appendingPathComponent("two.txt"),
            scans.appendingPathComponent(".gitignore"), scans.appendingPathComponent(".DS_Store"), scans.appendingPathComponent(".unavailable.jpg")]))
        model.connect(ICloudDriveProvider(rootURL: scans))
        for current in [model, photo] {
            let kind = current.kind.rawValue
            current.scanConfiguration = {
                .init(executable: resources.appendingPathComponent("pikpak"), models: resources.appendingPathComponent("FileTwinModels"), worker: resources.appendingPathComponent("filetwin-worker"),
                    dataDirectory: root.appendingPathComponent("Catalog/\(kind)"), temporaryDirectory: root.appendingPathComponent("Engine/\(kind)"), environment: [:])
            }
            current.findSimilar(presentWindow: false); current.similarity.local.families = ["text"]; current.similarity.local.threshold = 0.05
            current.similarity.start(current.similarity.local)
        }
        precondition(model.similarity.local.isRunning && photo.similarity.local.isRunning)
        try await wait({ !model.similarity.local.isRunning && !photo.similarity.local.isRunning }, seconds: 60)
        for current in [model, photo] {
            precondition(current.similarity.local.error == nil, current.similarity.local.error ?? "")
            precondition(current.similarity.local.report?.analysedFiles == 2)
            precondition(current.similarity.local.report?.skippedFiles == 0 && current.similarity.local.report?.issues.isEmpty == true,
                "Dotfiles must be excluded before original preparation, without skipped-file warnings")
            precondition(current.similarity.local.report?.totalGroups == 1 && current.similarity.local.report?.scoresRetained == 1)
            while current.similarity.local.results.isIndexing { try await Task.sleep(nanoseconds: 10_000_000) }
            let reference = current.similarity.local.report!.files!.first!
            current.similarity.local.results.select(reference.id)
            try await wait { !current.similarity.local.results.isLoading }
            precondition(current.similarity.local.results.error == nil, current.similarity.local.results.error ?? "")
            precondition(current.similarity.local.results.related.first?.score == 1)
            if current.kind == .photos { precondition(current.similarity.local.results.related.first?.file.id.hasPrefix("asset:") == true) }
        }
        precondition(photo.similarity.local.localURLs.isEmpty, "Provider scans pass metadata, not an eager export directory")
        precondition(photo.similarity.local.report!.groups.flatMap(\.members).allSatisfy { $0.id.hasPrefix("asset:") && $0.localPath == nil })
        let expectedPaths = Set(["one.txt", "two.txt"].map { scans.appendingPathComponent($0).resolvingSymlinksInPath().path })
        let actualPaths = Set(model.similarity.local.report!.groups.flatMap(\.members).compactMap { $0.localPath }.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        precondition(actualPaths == expectedPaths, "Native iCloud result must resolve to its original file")
        precondition((try? manager.contentsOfDirectory(atPath: root.appendingPathComponent("Engine/photos").path)) == [])
        precondition(manager.fileExists(atPath: scans.appendingPathComponent("one.txt").path))
        print("PASS concurrent real engine scans, 5% threshold, independent catalogs, Photos asset mapping and private-copy cleanup")
        print("PASS iCloud and Photos exclude dotfiles before analysis/export without warnings; visible originals remain intact")

        let live = NativeDriveModel(kind: .photos, temporaryRoot: root.appendingPathComponent("LivePhotos"))
        let streamingProvider = SyntheticPhotosDrive(files: [scans.appendingPathComponent("one.txt"), scans.appendingPathComponent("two.txt")], afterFirst: { @MainActor in
            try await wait({ live.similarity.local.progress.analysed >= 1 }, seconds: 10)
            precondition(!live.similarity.local.progress.discoveryComplete,
                         "The first file must be analysed before discovery can return the second file")
        })
        live.connect(streamingProvider)
        live.scanConfiguration = {
            .init(executable: resources.appendingPathComponent("pikpak"), models: resources.appendingPathComponent("FileTwinModels"), worker: resources.appendingPathComponent("filetwin-worker"),
                dataDirectory: root.appendingPathComponent("Catalog/live"), temporaryDirectory: root.appendingPathComponent("Engine/live"), environment: [:])
        }
        live.findSimilar(presentWindow: false); live.similarity.local.families = ["text"]
        live.similarity.start(live.similarity.local)
        try await wait({ !live.similarity.local.isRunning }, seconds: 20)
        precondition(live.similarity.local.error == nil, live.similarity.local.error ?? "")
        precondition(live.similarity.local.report?.analysedFiles == 2 && streamingProvider.fetchedIDs.count == 2)
        try await wait { (try? manager.contentsOfDirectory(atPath: root.appendingPathComponent("Engine/live").path)) == [] }
        precondition((try? manager.contentsOfDirectory(atPath: root.appendingPathComponent("Engine/live").path)) == [])
        live.close()
        print("PASS live provider discovery waits for the first analysed file before discovering the next; no inventory barrier")

        photo.findSimilar(exactOnly: true, presentWindow: false); photo.similarity.start(photo.similarity.local)
        try await wait { !photo.similarity.local.isRunning }
        precondition(photo.similarity.local.error == nil)
        precondition(photo.similarity.local.report?.totalGroups == 1 && photo.similarity.local.report?.groups.first?.isExact == true)
        precondition(photo.similarity.local.report?.threshold == 1 && photo.similarity.local.report?.analysedFiles == 2)
        print("PASS exact duplicate scans hash content without running media similarity models")

        let album = SyntheticPhotosDrive(files: Array(repeating: scans.appendingPathComponent("one.txt"), count: 1_005))
        photo.connect(album)
        photo.findSimilar(presentWindow: false)
        let largeScope = try await photo.similarity.local.inventoryExternalSources!()
        precondition(largeScope.count == 1_005 && album.fetchedIDs.isEmpty, "Inventory must never export originals")
        let requestedCopy = root.appendingPathComponent("RequestedOriginal")
        try CloudDriveFiles.privateDirectory(requestedCopy)
        let one = try await photo.similarity.local.resolveExternalSource!(largeScope[37].id, requestedCopy, { _ in })
        precondition(album.fetchedIDs == [largeScope[37].id] && manager.fileExists(atPath: one.path))
        try manager.removeItem(at: requestedCopy)
        precondition(manager.fileExists(atPath: scans.appendingPathComponent("one.txt").path))
        print("PASS 1,005-item Photos inventory fetches nothing; a worker request exports only its selected original")

        photo.connect(SyntheticPhotosDrive(files: [scans.appendingPathComponent("unavailable.jpg"), scans.appendingPathComponent("one.txt")]))
        photo.findSimilar(presentWindow: false); photo.similarity.start(photo.similarity.local)
        try await wait { !photo.similarity.local.isRunning }
        precondition(photo.similarity.local.error == nil, photo.similarity.local.error ?? "")
        precondition(photo.similarity.local.report?.analysedFiles == 1 && photo.similarity.local.report?.skippedFiles == 1)
        precondition(photo.similarity.local.report?.status == "partial")
        precondition(photo.similarity.local.report?.files?.contains { $0.name == "unavailable.jpg" && $0.state == "failed" } == true)
        print("PASS a failed original fetch is reported without stopping the remaining queued files")

        photo.connect(SyntheticPhotosDrive(files: [scans.appendingPathComponent(".unavailable.jpg")]))
        photo.findSimilar(presentWindow: false); photo.similarity.start(photo.similarity.local)
        try await wait { !photo.similarity.local.isRunning }
        precondition(photo.similarity.local.error == nil)
        precondition(photo.similarity.local.report?.analysedFiles == 0 && photo.similarity.local.report?.skippedFiles == 0)
        precondition(photo.similarity.local.report?.files?.isEmpty == true && photo.similarity.local.report?.status == "completed")
        print("PASS an all-dotfile Photos selection finishes empty without exporting excluded originals")

        let slow = SyntheticPhotosDrive(files: [scans.appendingPathComponent("one.txt"), scans.appendingPathComponent("two.txt")], delay: 5_000_000_000)
        photo.connect(slow)
        photo.findSimilar(presentWindow: false); photo.similarity.start(photo.similarity.local)
        try await wait { slow.fetchedIDs.count == 1 }
        photo.similarity.local.cancel()
        try await wait { !photo.similarity.local.isRunning }
        // Cancel stops the queue and keeps the saved scan with its retained
        // downloads; Clear is what discards them and releases the helper.
        precondition(photo.similarity.local.error == nil && photo.similarity.local.message.hasPrefix("Scan cancelled"))
        precondition(photo.similarity.local.savedSession?.state == "cancelled")
        precondition(slow.fetchedIDs.count == 1, "Cancelling a fetch must not request the next queued original")
        photo.similarity.local.clearSession()
        // Cleared results can start a short saved-matrix query after the
        // original-copy cleanup. Wait for that separate reader to release its
        // query directory before asserting the entire temporary parent empty.
        try await wait { (try? manager.contentsOfDirectory(atPath: root.appendingPathComponent("Engine/photos").path)) == [] }
        precondition((try? manager.contentsOfDirectory(atPath: root.appendingPathComponent("Engine/photos").path)) == [])
        precondition(manager.fileExists(atPath: scans.appendingPathComponent("one.txt").path))
        model.close(); photo.close()
        print("PASS cancellation during native provider preparation without deleting originals")
    }
}

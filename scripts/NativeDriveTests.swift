import AppKit
import Foundation

private final class SyntheticPhotosDrive: NativeCloudDrive, @unchecked Sendable {
    let kind = CloudDriveKind.photos
    let root = CloudDriveLocation(id: "photos:root", title: "Synthetic Photos", isLibrary: true)
    let files: [URL]
    let delay: UInt64
    init(files: [URL], delay: UInt64 = 0) { self.files = files; self.delay = delay }
    func list(_ location: CloudDriveLocation, offset: Int, search: String) async throws -> CloudDrivePage {
        let items = files.enumerated().map { index, url in CloudDriveItem(id: "asset:synthetic-\(index)", name: url.lastPathComponent, isFolder: false, canRename: false) }
        return .init(items: items.filter { search.isEmpty || $0.name.contains(search) }, total: items.count)
    }
    func materialize(_ item: CloudDriveItem, directory: URL, progress: @escaping CloudDriveProgressHandler) async throws -> URL {
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

        let model = NativeDriveModel(kind: .icloud, temporaryRoot: root.appendingPathComponent("iCloudTemp"))
        model.connect(provider); try await wait { !model.isLoading }
        model.selection = [item.id]; model.sort(by: 2); try await Task.sleep(nanoseconds: 40_000_000)
        precondition(model.selection == [item.id])
        model.query = "Garden"; model.reload(); model.query = "Other"; model.reload()
        try await wait { !model.isLoading }; precondition(model.items.isEmpty)
        model.query = ""; model.reload(); try await wait { !model.isLoading }
        print("PASS asynchronous listing, stale search cancellation and selection preservation")

        guard CommandLine.arguments.count > 1 else { model.close(); print("PASS native drive model tests (pass app Resources for engine integration)"); return }
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let scans = root.appendingPathComponent("ScanFiles"); try manager.createDirectory(at: scans, withIntermediateDirectories: true)
        for name in ["one.txt", "two.txt"] { try text.write(to: scans.appendingPathComponent(name)) }
        let photo = NativeDriveModel(kind: .photos, temporaryRoot: root.appendingPathComponent("PhotosTemp"))
        photo.connect(SyntheticPhotosDrive(files: [scans.appendingPathComponent("one.txt"), scans.appendingPathComponent("two.txt")]))
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
            precondition(current.similarity.local.report?.totalGroups == 2)
        }
        precondition(photo.similarity.local.localURLs.count == 1)
        precondition(photo.similarity.local.report!.groups.flatMap(\.members).allSatisfy { $0.id.hasPrefix("asset:") && $0.localPath == nil })
        let expectedPaths = Set(["one.txt", "two.txt"].map { scans.appendingPathComponent($0).resolvingSymlinksInPath().path })
        let actualPaths = Set(model.similarity.local.report!.groups.flatMap(\.members).compactMap { $0.localPath }.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        precondition(actualPaths == expectedPaths, "Native iCloud result must resolve to its original file")
        precondition((try? manager.contentsOfDirectory(atPath: root.appendingPathComponent("PhotosTemp/Scan").path)) == [])
        precondition(manager.fileExists(atPath: scans.appendingPathComponent("one.txt").path))
        print("PASS concurrent real engine scans, 5% threshold, independent catalogs, Photos asset mapping and private-copy cleanup")

        photo.findSimilar(exactOnly: true, presentWindow: false); photo.similarity.start(photo.similarity.local)
        try await wait { !photo.similarity.local.isRunning }
        precondition(photo.similarity.local.error == nil)
        precondition(photo.similarity.local.report?.totalGroups == 1 && photo.similarity.local.report?.groups.first?.isExact == true)
        precondition(photo.similarity.local.report?.threshold == 1 && photo.similarity.local.report?.analysedFiles == 2)
        print("PASS exact duplicate scans hash content without running media similarity models")

        photo.connect(SyntheticPhotosDrive(files: Array(repeating: scans.appendingPathComponent("one.txt"), count: 1_005)))
        photo.findSimilar(presentWindow: false)
        let largeScope = try await photo.similarity.local.prepareExternalScope!()
        precondition(largeScope.count == 1)
        let preparedCount = manager.enumerator(at: largeScope[0], includingPropertiesForKeys: nil)!.allObjects.compactMap { $0 as? URL }.filter { $0.pathExtension == "txt" }.count
        precondition(preparedCount == 1_005)
        photo.similarity.local.cleanupExternalScope()
        print("PASS albums with more than 1,000 items use one scan root and clean up all staged files")

        photo.connect(SyntheticPhotosDrive(files: [scans.appendingPathComponent("one.txt")], delay: 5_000_000_000))
        photo.findSimilar(presentWindow: false); photo.similarity.start(photo.similarity.local)
        try await Task.sleep(nanoseconds: 80_000_000); photo.similarity.local.cancel()
        try await wait { !photo.similarity.local.isRunning }
        precondition(photo.similarity.local.error == nil && photo.similarity.local.message == "Scan cancelled")
        precondition((try? manager.contentsOfDirectory(atPath: root.appendingPathComponent("PhotosTemp/Scan").path)) == [])
        precondition(manager.fileExists(atPath: scans.appendingPathComponent("one.txt").path))
        model.close(); photo.close()
        print("PASS cancellation during native provider preparation without deleting originals")
    }
}

import Foundation

@main @MainActor struct DiskTrashTests {
    static let data = Data("Generated Trash test contents\n".utf8)
    static func rejects(_ body: () async throws -> Void) async throws {
        do { try await body() } catch { return }
        throw CloudDriveError.message("An unsafe Trash operation unexpectedly succeeded.")
    }
    static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(condition(), "Timed out waiting for generated Trash state")
    }

    static func legacyMigration(in root: URL, keepsUserFolder: Bool) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        let store = DiskTrash(volumeRoot: root, volumeID: LocalFileAccess.volumeID(root))
        try await store.prepare()
        let original = root.appendingPathComponent(UUID().uuidString + ".bin")
        try data.write(to: original)
        let undo = try await store.trash([original], title: "Migration fixture", progress: { _ in })
        let ids = try await store.list().map(\.id)
        let legacy = root.appendingPathComponent("Trash", isDirectory: true)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: false)
        try fm.moveItem(at: store.storage, to: legacy.appendingPathComponent("MyCloudDriver", isDirectory: true))
        try fm.moveItem(at: store.folder.appendingPathComponent(".MyCloudDriver.lock"), to: legacy.appendingPathComponent(".MyCloudDriver.lock"))
        try fm.removeItem(at: store.folder)
        let unrelated = legacy.appendingPathComponent(UUID().uuidString + ".bin")
        if keepsUserFolder { try data.write(to: unrelated) }

        let reopened = DiskTrash(volumeRoot: root, volumeID: LocalFileAccess.volumeID(root))
        let before = try await reopened.list()
        precondition(before.map(\.id) == ids && !fm.fileExists(atPath: reopened.folder.path), "Reading legacy Trash must not write or rename it")
        let migrated = try await reopened.prepare()
        let after = try await reopened.list()
        precondition(migrated && after.map(\.id) == ids && DiskTrash.isManagedStorage(reopened.folder))
        precondition(!fm.fileExists(atPath: legacy.appendingPathComponent("MyCloudDriver").path))
        precondition(fm.fileExists(atPath: legacy.path) == keepsUserFolder, "Only the empty app-created wrapper is removed")
        if keepsUserFolder { let contents = try Data(contentsOf: unrelated); precondition(contents == data) }
        _ = try await undo.apply()
        let restored = try Data(contentsOf: original), empty = try await reopened.list()
        precondition(restored == data, "Undo captured before migration still restores the original")
        precondition(empty.isEmpty)
        print("PASS marked legacy Trash migrates with entry IDs and Undo intact; unrelated siblings are preserved")
    }

    static func concurrentPreparation(in root: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        let files = (0..<6).map { _ in root.appendingPathComponent(UUID().uuidString + ".bin") }
        let volumeID = LocalFileAccess.volumeID(root), contents = data
        for file in files { try contents.write(to: file) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for file in files {
                group.addTask {
                    let store = DiskTrash(volumeRoot: root, volumeID: volumeID)
                    try await store.prepare()
                    _ = try await store.trash([file], title: "Concurrent fixture", progress: { _ in })
                }
            }
            try await group.waitForAll()
        }
        let reopened = DiskTrash(volumeRoot: root, volumeID: volumeID)
        let items = try await reopened.list()
        precondition(items.count == files.count)
        let hidden = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix(".") }
        precondition(hidden.map(\.lastPathComponent) == [reopened.folder.lastPathComponent], "Concurrent windows publish one complete container and clean up staging folders: \(hidden.map(\.lastPathComponent))")
        _ = try await reopened.putBack(items.map(\.id))
        for file in files { let restored = try Data(contentsOf: file); precondition(restored == contents) }
        print("PASS concurrent windows share one hidden Trash and retain every generated file")
    }

    static func mergeLegacyStorage(in root: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        let store = DiskTrash(volumeRoot: root, volumeID: LocalFileAccess.volumeID(root))
        let originals = (0..<2).map { _ in root.appendingPathComponent(UUID().uuidString + ".bin") }
        for file in originals { try data.write(to: file) }
        let oldUndo = try await store.trash([originals[0]], title: "Legacy fixture", progress: { _ in })
        let oldItems = try await store.list()
        let saved = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.moveItem(at: store.storage, to: saved)
        try await store.prepare()
        _ = try await store.trash([originals[1]], title: "New fixture", progress: { _ in })
        let newItems = try await store.list()
        let legacy = root.appendingPathComponent("Trash", isDirectory: true)
        try fm.createDirectory(at: legacy, withIntermediateDirectories: false)
        let legacyStorage = legacy.appendingPathComponent("MyCloudDriver", isDirectory: true)
        try fm.moveItem(at: saved, to: legacyStorage)
        try Data().write(to: legacy.appendingPathComponent(".MyCloudDriver.lock"))
        let newEntry = store.storage.appendingPathComponent(newItems[0].id.uuidString, isDirectory: true)
        let collision = legacyStorage.appendingPathComponent(newItems[0].id.uuidString, isDirectory: true)
        try fm.copyItem(at: newEntry, to: collision)
        try await rejects { try await store.prepare() }
        precondition(fm.fileExists(atPath: newEntry.path) && fm.fileExists(atPath: legacyStorage.appendingPathComponent(oldItems[0].id.uuidString).path),
                     "A duplicate ID must be detected before moving any entry")
        try fm.removeItem(at: collision)
        let migrated = try await store.prepare(), merged = try await store.list()
        precondition(migrated && Set(merged.map(\.id)) == Set((oldItems + newItems).map(\.id)))
        precondition(!fm.fileExists(atPath: legacy.path))
        _ = try await oldUndo.apply()
        _ = try await store.putBack(newItems.map(\.id))
        for file in originals { let contents = try Data(contentsOf: file); precondition(contents == data) }
        print("PASS old and new Trash merge without changing entry IDs; duplicate IDs cannot overwrite or partially migrate files")
    }

    static func main() async throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("DiskTrashTests-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let store = DiskTrash(volumeRoot: root, volumeID: LocalFileAccess.volumeID(root))
        try await store.prepare()
        precondition(fm.fileExists(atPath: store.folder.path) && !fm.fileExists(atPath: root.appendingPathComponent("Trash").path))
        precondition(store.folder.lastPathComponent.hasPrefix(".") && UUID(uuidString: String(store.folder.lastPathComponent.dropFirst())) != nil)
        precondition(DiskTrash.isManagedStorage(store.folder) && DiskTrash.isManagedStorage(store.storage))
        precondition(store.contains(store.folder) && store.contains(store.storage))
        precondition(!store.contains(URL(fileURLWithPath: store.folder.path + "-other", isDirectory: true)))
        let originals = [root.appendingPathComponent("One/Same.txt"), root.appendingPathComponent("Two/Same.txt")]
        for file in originals {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: false)
            try data.write(to: file)
        }
        let undo = try await store.trash(originals, title: "Move to Trash", progress: { _ in })
        let listed = try await store.list()
        precondition(listed.count == 2 && Set(listed.map(\.originalPath)) == ["/One/Same.txt", "/Two/Same.txt"])
        precondition(originals.allSatisfy { !fm.fileExists(atPath: $0.path) })
        let reopened = DiskTrash(volumeRoot: root, volumeID: LocalFileAccess.volumeID(root))
        precondition(reopened.folder == store.folder, "The opaque container name survives reopening")
        let reopenedItems = try await reopened.list()
        precondition(reopenedItems.count == 2)
        let redo = try await undo.apply()
        for file in originals { let restored = try Data(contentsOf: file); precondition(restored == data) }
        let restore = try await redo.apply()
        _ = try await restore.apply()
        print("PASS disk Trash: duplicate names, saved original locations, reopening and repeated Undo/Redo")

        _ = try await store.trash(originals, title: "Move to Trash", progress: { _ in })
        let conflictItems = try await store.list()
        try Data("Existing unrelated file".utf8).write(to: originals[1])
        try await rejects { _ = try await store.putBack(conflictItems.map(\.id)) }
        precondition(!fm.fileExists(atPath: originals[0].path))
        let existing = try Data(contentsOf: originals[1]); precondition(existing != data)
        try fm.removeItem(at: originals[1])
        try fm.removeItem(at: originals[0].deletingLastPathComponent())
        _ = try await store.putBack(conflictItems.map(\.id))
        for file in originals { let restored = try Data(contentsOf: file); precondition(restored == data) }
        print("PASS Put Back preflights conflicts, never overwrites and recreates missing original parents")

        let unrelated = store.folder.appendingPathComponent("Unrelated.txt")
        try data.write(to: unrelated)
        let oldUndo = try await store.trash([originals[0]], title: "Old deletion", progress: { _ in })
        let snapshot = try await store.list().map(\.id)
        _ = try await store.trash([originals[1]], title: "Later deletion", progress: { _ in })
        try await store.empty(snapshot, progress: { _ in })
        let remaining = try await store.list()
        precondition(remaining.count == 1 && remaining[0].originalPath == "/Two/Same.txt")
        let kept = try Data(contentsOf: unrelated); precondition(kept == data)
        try await rejects { _ = try await oldUndo.apply() }
        _ = try await store.putBack(remaining.map(\.id))
        print("PASS Empty Trash is permanent, preserves unrelated contents and excludes deletions made after confirmation")

        let wrong = DiskTrash(volumeRoot: root, volumeID: "wrong-volume")
        try await rejects { try await wrong.prepare() }
        try await rejects { _ = try await wrong.list() }
        let link = root.appendingPathComponent("Link")
        try fm.createSymbolicLink(at: link, withDestinationURL: originals[1])
        try await rejects { _ = try await store.trash([link], title: "Link", progress: { _ in }) }
        try await rejects { _ = try await store.trash([store.folder], title: "Trash", progress: { _ in }) }
        let retained = try Data(contentsOf: originals[1]); precondition(retained == data)
        print("PASS replaced disks, symlinks and the Trash container cannot be mutated")

        let collision = root.appendingPathComponent("Collision", isDirectory: true)
        let preexisting = collision.appendingPathComponent("Trash/MyCloudDriver/User file.txt")
        try fm.createDirectory(at: preexisting.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: preexisting)
        let foreign = DiskTrash(volumeRoot: collision, volumeID: LocalFileAccess.volumeID(collision))
        try await foreign.prepare()
        let foreignData = try Data(contentsOf: preexisting); precondition(foreignData == data)
        precondition(!foreign.contains(preexisting) && !DiskTrash.isManagedStorage(preexisting.deletingLastPathComponent()))
        let foreignProvider = ICloudDriveProvider(rootURL: collision, kind: .local, diskTrashRootURL: collision)
        let foreignPage = try await foreignProvider.list(foreignProvider.root, offset: 0, search: "")
        precondition(foreignPage.items.contains { $0.name == "Trash" } && !foreignPage.items.contains { $0.url == foreign.folder })
        let userTrash = foreignPage.items.first { $0.name == "Trash" }!
        let userTrashPage = try await foreignProvider.list(userTrash.location, offset: 0, search: "")
        precondition(userTrashPage.items.contains { $0.name == "MyCloudDriver" })
        print("PASS ordinary Trash folders and unmarked contents remain visible; the app container is hidden")

        let reservedRoot = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: reservedRoot, withIntermediateDirectories: false)
        let reserved = DiskTrash(volumeRoot: reservedRoot, volumeID: LocalFileAccess.volumeID(reservedRoot))
        try fm.createDirectory(at: reserved.folder, withIntermediateDirectories: false)
        let reservedFile = reserved.folder.appendingPathComponent(UUID().uuidString + ".bin")
        try data.write(to: reservedFile)
        try await rejects { try await reserved.prepare() }
        let reservedData = try Data(contentsOf: reservedFile)
        precondition(reservedData == data)
        precondition(!DiskTrash.isManagedStorage(reserved.folder) && !reserved.contains(reservedFile))
        let reservedContents = try fm.contentsOfDirectory(atPath: reserved.folder.path)
        precondition(reservedContents == [reservedFile.lastPathComponent], "A namespace collision must not adopt or modify user data")
        print("PASS even an unmarked folder with the reserved UUID is preserved without being adopted")

        try await legacyMigration(in: root.appendingPathComponent(UUID().uuidString, isDirectory: true), keepsUserFolder: false)
        try await legacyMigration(in: root.appendingPathComponent(UUID().uuidString, isDirectory: true), keepsUserFolder: true)
        try await concurrentPreparation(in: root.appendingPathComponent(UUID().uuidString, isDirectory: true))
        try await mergeLegacyStorage(in: root.appendingPathComponent(UUID().uuidString, isDirectory: true))

        let provider = ICloudDriveProvider(rootURL: root, kind: .local, diskTrashRootURL: root)
        let model = NativeDriveModel(kind: .local)
        defer { model.close() }
        model.connect(provider)
        try await wait { model.diskTrashReady && !model.isLoading }
        precondition(model.workspaceSections.contains(.trash))
        model.delete([try ICloudDriveProvider.item(originals[1])])
        try await wait { !model.isMutating && !model.diskTrashLoading && model.diskTrashItems.count == 1 }
        precondition(model.undoStack.count == 1)
        model.section = FinderWorkspaceSection.trash.rawValue
        model.undo()
        try await wait { !model.isMutating && !model.diskTrashLoading && model.diskTrashItems.isEmpty }
        model.undo(redo: true)
        try await wait { !model.isMutating && !model.diskTrashLoading && model.diskTrashItems.count == 1 }
        model.putBackFromDiskTrash(Set(model.diskTrashItems.map(\.id)))
        try await wait { !model.isMutating && !model.diskTrashLoading && model.diskTrashItems.isEmpty }
        model.undo()
        try await wait { !model.isMutating && !model.diskTrashLoading && model.diskTrashItems.count == 1 }
        model.emptyDiskTrash(Set(model.diskTrashItems.map(\.id)))
        try await wait { !model.isMutating && !model.diskTrashLoading && model.diskTrashItems.isEmpty }
        precondition(model.undoStack.allSatisfy { $0.diskTrashEntryIDs.isEmpty })
        precondition(model.redoStack.allSatisfy { $0.diskTrashEntryIDs.isEmpty })
        print("PASS connected model prepares Trash, publishes delete/Put Back/Undo/Redo and invalidates emptied-item history")
    }
}

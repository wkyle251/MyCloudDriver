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
    static func main() async throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("DiskTrashTests-\(UUID())", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        let store = DiskTrash(volumeRoot: root, volumeID: LocalFileAccess.volumeID(root))
        try await store.prepare()
        precondition(fm.fileExists(atPath: root.appendingPathComponent("Trash").path))
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
        try await rejects { try await foreign.prepare() }
        let foreignData = try Data(contentsOf: preexisting); precondition(foreignData == data)
        print("PASS existing unmarked Trash/MyCloudDriver contents are preserved")

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

import AppKit
import Foundation

private actor TreeTestDrive: NativeCloudDrive {
    nonisolated let kind = CloudDriveKind.photos
    nonisolated let root = CloudDriveLocation(id: "root", title: "Synthetic albums", isLibrary: true)
    var contents: [String: [CloudDriveItem]]
    var calls: [(String, Int, String)] = []
    var failures: Set<String> = []
    var active = 0, peak = 0, materializations = 0
    init(_ contents: [String: [CloudDriveItem]]) { self.contents = contents }
    func failNext(_ id: String) { failures.insert(id) }
    func count(_ id: String) -> Int { calls.filter { $0.0 == id }.count }
    func list(_ location: CloudDriveLocation, offset: Int, search: String) async throws -> CloudDrivePage {
        calls.append((location.id, offset, search))
        let snapshot = contents[location.id] ?? [], fail = failures.remove(location.id) != nil
        active += 1; peak = max(peak, active)
        defer { active -= 1 }
        // Intentionally finish even if the caller cancels: generation guards
        // must reject a late provider response, not just rely on cooperation.
        await Task.detached { try? await Task.sleep(nanoseconds: 80_000_000) }.value
        if fail { throw CloudDriveError.message("Synthetic folder temporarily unavailable") }
        if location.id == "root" { return .init(items: snapshot, total: snapshot.count) }
        let end = min(snapshot.count, offset + 2)
        return .init(items: Array(snapshot.dropFirst(offset).prefix(2)), total: snapshot.count,
                     nextOffset: end < snapshot.count ? end : nil)
    }
    func materialize(_ item: CloudDriveItem, directory: URL, progress: @escaping CloudDriveProgressHandler) async throws -> URL {
        materializations += 1; throw CocoaError(.featureUnsupported)
    }
    func scanItems(_ items: [CloudDriveItem], location: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> [CloudDriveItem] { items }
    func createContainer(_ name: String, in location: CloudDriveLocation) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
    func rename(_ item: CloudDriveItem, to name: String) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
    func relocate(_ items: [CloudDriveItem], from: CloudDriveLocation, to: CloudDriveLocation, copy: Bool, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
    func importFiles(_ urls: [URL], into: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
    func delete(_ items: [CloudDriveItem], progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
}

@main struct NativeDriveTreeTests {
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(condition(), "Tree operation timed out")
    }
    @MainActor static func idle(_ model: NativeDriveModel) async throws { try await wait { !model.isLoading && !model.tree.isLoading && !model.isBusy } }
    @MainActor static func row(_ name: String, in model: NativeDriveModel) -> NativeDriveRow {
        guard let row = model.tree.rows.first(where: { $0.item.name == name }) else { preconditionFailure("Missing synthetic row: \(name)") }
        return row
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let manager = FileManager.default, root = manager.temporaryDirectory.appendingPathComponent("MyCloudDriverTreeTests-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        for folder in ["Parent/Nested", "Empty", "Other"] {
            try manager.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in ["Parent/Nested/A.txt", "Parent/Nested/B.txt", "Parent/Z.txt", "Root.txt"] {
            try Data("Synthetic \(file)".utf8).write(to: root.appendingPathComponent(file))
        }
        let provider = ICloudDriveProvider(rootURL: root), model = NativeDriveModel(kind: .icloud)
        model.connect(provider); try await idle(model)
        let parent = row("Parent", in: model), location = model.location
        model.toggleExpansion(parent)
        precondition(model.tree.branch(for: parent.item).isLoading && model.location == location && model.history.count == 1)
        try await idle(model)
        let nested = row("Nested", in: model)
        precondition(nested.depth == 1 && nested.id.parent == parent.id && row("Z.txt", in: model).depth == 1)
        model.toggleExpansion(nested); try await idle(model)
        let a = row("A.txt", in: model), b = row("B.txt", in: model)
        precondition(a.depth == 2 && b.id.parent == nested.id)
        model.select(a, extending: false, toggling: false); model.moveSelection(1)
        precondition(model.focusedItem?.id == b.item.id && model.selectedItems.map(\.id) == [b.item.id])
        model.moveSelection(-1, extending: true)
        precondition(model.selection == [a.item.id, b.item.id])
        model.collapseSelection()
        precondition(model.focusedRowID == nested.id && model.isExpanded(nested.item))
        model.collapseSelection()
        precondition(!model.isExpanded(nested.item) && !model.tree.rows.contains { $0.id == a.id })
        model.expandSelection(); try await idle(model)
        model.expandSelection(); precondition(model.focusedRowID == a.id)
        model.toggleExpansion(parent)
        precondition(model.focusedRowID == parent.id && model.selection == [parent.item.id])
        model.toggleExpansion(parent); try await idle(model)
        precondition(model.tree.rows.contains { $0.id == a.id }, "Reopening preserves nested expansion")
        model.select(b, extending: false, toggling: false); model.viewMode = 1
        precondition(model.focusedItemID == parent.item.id && model.visibleRows.count == model.items.count)
        model.viewMode = 0; precondition(model.tree.rows.contains { $0.id == b.id })
        model.toggleSort(.name)
        try await wait { model.tree.branch(for: nested.item).items.map(\.name) == ["B.txt", "A.txt"] }
        precondition(model.tree.rows.filter { $0.id.parent == parent.id }.map { $0.item.name } == ["Nested", "Z.txt"])
        model.select(a, extending: false, toggling: false)
        model.enter(nested.item, rowID: nested.id); try await idle(model)
        precondition(model.history.map(\.id) == [provider.root.id, parent.item.id, nested.item.id])
        model.back(); try await idle(model); precondition(model.location.id == parent.item.id)
        model.root(); try await idle(model)
        model.toggleExpansion(row("Empty", in: model)); try await idle(model)
        precondition(model.tree.branch(for: row("Empty", in: model).item).loaded && model.tree.branch(for: row("Empty", in: model).item).items.isEmpty)
        print("PASS disclosure vs opening, indentation, keyboard/range selection, grid switching, sibling sort, breadcrumb and empty folders")

        model.toggleExpansion(row("Parent", in: model)); try await idle(model)
        model.toggleExpansion(row("Nested", in: model)); try await idle(model)
        model.select(row("A.txt", in: model), extending: false, toggling: false)
        model.reload(); try await idle(model)
        precondition(model.selection == [a.item.id] && model.isExpanded(parent.item) && model.isExpanded(nested.item))
        model.rename(row("A.txt", in: model).item, name: "Renamed.txt"); try await idle(model)
        precondition(!model.tree.rows.contains { $0.item.name == "A.txt" } && row("Renamed.txt", in: model).depth == 2)
        model.undo(); try await idle(model)
        precondition(row("A.txt", in: model).depth == 2 && !model.tree.rows.contains { $0.item.name == "Renamed.txt" })
        let source = row("A.txt", in: model).item, other = row("Other", in: model)
        model.toggleExpansion(other); try await idle(model)
        model.relocate([source], to: other.item.location, copy: false); try await idle(model)
        precondition(row("A.txt", in: model).id.parent == other.id)
        model.undo(); try await idle(model)
        precondition(row("A.txt", in: model).id.parent == nested.id)
        let selected = [parent.item, nested.item, row("A.txt", in: model).item, parent.item]
        precondition(model.operationItems(selected).map(\.id) == [parent.item.id])
        let export = root.deletingLastPathComponent().appendingPathComponent("MyCloudDriverTreeExport-\(UUID().uuidString)")
        try manager.createDirectory(at: export, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: export) }
        model.export(selected, to: export); try await idle(model)
        precondition(model.activity.latest?.state == "Completed" && manager.fileExists(atPath: export.appendingPathComponent("Parent/Nested/A.txt").path))
        let exportedNames = try manager.contentsOfDirectory(atPath: export.path)
        precondition(exportedNames == ["Parent"])
        model.select(row("B.txt", in: model), extending: false, toggling: false)
        for _ in 0..<3 {
            model.toggleFocusedFolder()
            precondition(model.focusedRowID == nested.id && model.selection == [nested.item.id])
            precondition(!model.tree.expanded.contains(nested.id) && model.tree.expanded.contains(parent.id))
            model.toggleFocusedFolder(); try await idle(model)
            precondition(model.focusedRowID == b.id && model.selection == [b.item.id])
        }
        model.toggleExpansion(parent); model.toggleExpansion(parent); try await idle(model)
        precondition(model.focusedRowID == b.id, "Reopening an ancestor restores the exact nested row")
        model.toggleFocusedFolder()
        model.select(row("Root.txt", in: model), extending: false, toggling: false)
        precondition(!model.canToggleFocusedFolder)
        model.select(nested, extending: false, toggling: false); model.toggleFocusedFolder(); try await idle(model)
        precondition(model.focusedRowID == nested.id, "Unrelated selection cancels the remembered child")
        model.delete([row("A.txt", in: model).item]); try await idle(model)
        precondition(!model.tree.rows.contains { $0.item.name == "A.txt" } && model.undoStack.last?.title == "Move to Trash")
        model.undo(); try await idle(model)
        precondition(row("A.txt", in: model).id == a.id && row("A.txt", in: model).depth == 2)
        precondition((try? Data(contentsOf: a.item.url!)) == Data("Synthetic Parent/Nested/A.txt".utf8))
        model.undo(redo: true); try await idle(model)
        precondition(!manager.fileExists(atPath: a.item.url!.path))
        model.undo(); try await idle(model)
        model.delete([row("Nested", in: model).item]); try await idle(model)
        precondition(!model.tree.rows.contains { $0.item.name == "Nested" })
        model.undo(); try await idle(model)
        precondition(row("Nested", in: model).depth == 1 && row("A.txt", in: model).depth == 2)
        precondition(manager.fileExists(atPath: b.item.url!.path))
        print("PASS folder toggle restores focused descendants; actual Finder Trash file/folder Undo and Redo retain content and expanded rows")
        model.close()
        print("PASS expanded refresh after rename/move/Undo, retained selection, and one recursive export for overlapping selection")

        func folder(_ id: String) -> CloudDriveItem { .init(id: id, name: id, isFolder: true) }
        func file(_ id: String) -> CloudDriveItem { .init(id: id, name: id + ".txt", isFolder: false) }
        let albums = (0..<8).map { folder("Album\($0)") }, shared = file("Shared")
        var pages = Dictionary(uniqueKeysWithValues: albums.map { ($0.id, [file("Z"), shared, file("A")]) })
        pages["root"] = albums
        let synthetic = TreeTestDrive(pages), photos = NativeDriveModel(kind: .photos)
        photos.connect(synthetic); try await idle(photos)
        let untouchedCalls = await synthetic.count("Album1")
        precondition(untouchedCalls == 0, "Root listing must not eagerly enumerate albums")
        let first = row("Album0", in: photos)
        photos.toggleExpansion(first); precondition(photos.tree.branch(for: first.item).isLoading)
        try await idle(photos)
        precondition(photos.tree.branch(for: first.item).nextOffset == 2)
        let countBefore = await synthetic.count("Album0")
        photos.toggleExpansion(first); photos.toggleExpansion(first); try await idle(photos)
        let countAfter = await synthetic.count("Album0")
        precondition(countBefore == countAfter, "Cached collapse/reopen should not refetch")
        await synthetic.failNext("Album0"); photos.tree.loadMore(first); try await idle(photos)
        precondition(photos.tree.branch(for: first.item).error != nil && photos.tree.branch(for: first.item).items.count == 2)
        photos.tree.retry(first); photos.toggleSort(.name); try await idle(photos)
        precondition(photos.tree.branch(for: first.item).items.map(\.name) == ["Z.txt", "Shared.txt", "A.txt"])
        precondition(photos.tree.branch(for: first.item).nextOffset == nil && photos.tree.branch(for: first.item).error == nil)
        for item in albums.dropFirst() { photos.toggleExpansion(item) }
        try await idle(photos)
        let peak = await synthetic.peak, materializations = await synthetic.materializations
        precondition(peak <= 4 && materializations == 0)
        let duplicates = photos.tree.rows.filter { $0.item.id == shared.id }
        precondition(duplicates.count == 8 && Set(duplicates.map(\.id)).count == 8)
        photos.select(duplicates[1], extending: false, toggling: false)
        precondition(photos.focusedRowID == duplicates[1].id && photos.selectedItems.count == 1)
        photos.toggleFocusedFolder()
        precondition(photos.focusedRowID == duplicates[1].id.parent && photos.selection == [duplicates[1].id.parent!.itemID])
        photos.toggleFocusedFolder(); try await idle(photos)
        precondition(photos.focusedRowID == duplicates[1].id && photos.selection == [shared.id],
                     "Focus returns to the same album occurrence of a shared Photos asset")
        photos.moveSelection(1); precondition(photos.focusedRowID != duplicates[0].id)
        photos.reload(); try await Task.sleep(nanoseconds: 110_000_000)
        photos.disconnect(); try await Task.sleep(nanoseconds: 230_000_000)
        precondition(photos.tree.rows.isEmpty && photos.items.isEmpty && !photos.tree.isLoading)
        print("PASS lazy loading, cache reuse, pagination/retry, sorting during I/O, four-request limit, duplicate Photos row identity and disconnect cancellation")

        let stale = NativeDriveModel(kind: .photos)
        stale.connect(synthetic); try await idle(stale)
        let old = row("Album0", in: stale)
        stale.toggleExpansion(old)
        try await Task.sleep(nanoseconds: 20_000_000)
        stale.toggleExpansion(old)
        try await Task.sleep(nanoseconds: 110_000_000)
        precondition(stale.tree.rows.count == albums.count && !stale.tree.branch(for: old.item).loaded)
        stale.toggleExpansion(old); try await Task.sleep(nanoseconds: 20_000_000)
        stale.enter(row("Album1", in: stale).item); try await idle(stale)
        precondition(stale.history.count == 2 && stale.tree.rows.allSatisfy { $0.depth == 0 })
        precondition(!stale.tree.expanded.contains(old.id))
        stale.close(); photos.close()
        print("PASS late expansion responses cannot reopen collapsed folders or leak across navigation")
    }
}

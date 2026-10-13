import AppKit
import Foundation

private actor TreeTestDrive: NativeCloudDrive {
    nonisolated let kind = CloudDriveKind.photos
    nonisolated let root = CloudDriveLocation(id: "root", title: "Synthetic albums", isLibrary: true)
    var contents: [String: [CloudDriveItem]]
    var calls: [(String, Int, String)] = []
    var failures: Set<String> = []
    var active = 0, peak = 0, materializations = 0
    var stalledPages = Set<String>()
    init(_ contents: [String: [CloudDriveItem]]) { self.contents = contents }
    func failNext(_ id: String) { failures.insert(id) }
    func count(_ id: String) -> Int { calls.filter { $0.0 == id }.count }
    func stallPages(_ id: String) { stalledPages.insert(id) }
    func totalCalls() -> Int { calls.count }
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
                     nextOffset: stalledPages.contains(location.id) ? offset : end < snapshot.count ? end : nil)
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
        model.select(a, extending: false, toggling: false)
        let previousPreview = model.inspectorPreviewIdentity
        model.moveSelection(1, extending: true)
        precondition(model.selectedItems.first?.id == a.item.id && model.focusedItem?.id == b.item.id
            && model.inspectorItem?.id == b.item.id && model.selection == [a.item.id, b.item.id]
            && model.inspectorPreviewIdentity?.itemID == b.item.id && model.inspectorPreviewIdentity != previousPreview,
            "Shift-arrow preview follows the keyboard cursor instead of the first file in the selection")
        model.moveSelection(-1, extending: true)
        precondition(model.inspectorItem?.id == a.item.id && model.selection == [a.item.id])
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
        photos.select(duplicates[0], extending: false, toggling: false)
        let duplicateSelection = photos.selection, duplicatePreview = photos.inspectorPreviewIdentity
        photos.select(duplicates[1], extending: false, toggling: false)
        precondition(photos.focusedRowID == duplicates[1].id && photos.selectedItems.count == 1
            && photos.selection == duplicateSelection && photos.inspectorItem?.id == shared.id
            && photos.inspectorPreviewIdentity == duplicatePreview,
            "Occurrence focus changes preserve the same selected asset and matching preview source")
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
        try await recursiveExpansionTests()
    }

    @MainActor static func recursiveExpansionTests() async throws {
        func folder(_ id: String) -> CloudDriveItem { .init(id: id, name: id, isFolder: true) }
        func file(_ id: String) -> CloudDriveItem { .init(id: id, name: id + ".txt", isFolder: false) }
        let wide = (0..<24).map { folder("Wide\($0)") }
        var contents: [String: [CloudDriveItem]] = ["Expand": wide + [folder("Deep0"), folder("Cycle")],
            "Cycle": [folder("Cycle"), file("CycleLeaf")], "Unrelated": [file("Untouched")]]
        for item in wide { contents[item.id] = [file(item.id + "-A"), file(item.id + "-B"), file(item.id + "-C")] }
        for depth in 0..<10 { contents["Deep\(depth)"] = depth == 9 ? [file("DeepLeaf")] : [folder("Deep\(depth + 1)")] }
        let provider = TreeTestDrive(contents), tree = NativeDriveTree()
        tree.reset(provider: provider)
        tree.replaceRoots([folder("Expand"), folder("Unrelated")])
        let root = tree.rootRows[0]
        var publications = 0
        tree.onChange = { publications += 1 }
        tree.expandAllLevels(root)
        precondition(tree.expandingAllRoots == [root.id] && tree.isLoading)
        try await wait { !tree.isLoading }
        precondition(tree.expandingAllRoots.isEmpty && tree.rows.contains { $0.item.id == "DeepLeaf" && $0.depth == 11 })
        precondition(wide.allSatisfy { tree.branch(for: $0).items.count == 3 && tree.branch(for: $0).nextOffset == nil })
        precondition(tree.branch(for: root.item).items.count == 26 && tree.branch(for: root.item).nextOffset == nil)
        precondition(tree.rows.filter { $0.item.id == "Cycle" }.count == 2,
                     "A repeated ancestor may be displayed but must not recurse forever")
        let unrelatedCalls = await provider.count("Unrelated"), materializations = await provider.materializations
        let peak = await provider.peak, calls = await provider.totalCalls()
        precondition(unrelatedCalls == 0 && materializations == 0 && peak <= 4)
        precondition(publications < calls, "Wide-folder replies must be coalesced into fewer tree publications")
        let callsBeforeCache = calls
        tree.expandAllLevels(root)
        precondition(!tree.isLoading)
        let callsAfterCache = await provider.totalCalls()
        precondition(callsAfterCache == callsBeforeCache, "Expanding cached levels must not refetch metadata")
        print("PASS Expand All: deep/wide paged metadata, cached branches, ancestor-cycle guard, four-request bound and coalesced publication; no materialization")

        let multiProvider = TreeTestDrive(["A": [folder("A1"), file("AFile")], "A1": [file("A1Leaf"), folder("A2")], "A2": [file("A2Leaf")],
            "B": [folder("B1")], "B1": [file("B1Leaf")], "C": [file("Untouched")]])
        let multi = NativeDriveTree(); multi.reset(provider: multiProvider)
        multi.replaceRoots([folder("A"), folder("B"), folder("C"), file("Loose")])
        let rowA = multi.rootRows[0], rowB = multi.rootRows[1], rowLoose = multi.rootRows[3]
        multi.toggle(rowA); try await wait { multi.branch(for: rowA.item).loaded }
        let rowA1 = multi.rows.first { $0.item.id == "A1" }!
        multi.expandAllLevels([rowA1, rowB, rowA, rowB, rowLoose])
        precondition(multi.expandingAllRoots == [rowB.id, rowA.id] && multi.isLoading,
                     "Roots are deduplicated, a folder under another selected root is covered by it, files are ignored and order is kept")
        try await wait { !multi.isLoading }
        precondition(multi.expandingAllRoots.isEmpty)
        precondition(["A1Leaf", "A2Leaf", "B1Leaf", "AFile"].allSatisfy { id in multi.rows.contains { $0.item.id == id } },
                     "Every level under every selected folder must open")
        let untouchedCalls = await multiProvider.count("C"), multiPeak = await multiProvider.peak
        precondition(untouchedCalls == 0 && !multi.rows.contains { $0.item.id == "Untouched" } && multiPeak <= 4,
                     "Folders outside the selection stay closed and the shared four-request bound holds")
        multi.expandAllLevels([])
        precondition(multi.expandingAllRoots.isEmpty && !multi.isLoading, "An empty selection starts nothing")
        print("PASS Expand All over several folders: deduplicated and nested roots, files ignored, unrelated folders untouched, one four-request bound")

        // Replies that arrive together are published together; the first is not held back.
        let burstProvider = TreeTestDrive(Dictionary(uniqueKeysWithValues: (0..<8).map { ("Burst\($0)", [file("Burst\($0)-leaf")]) }))
        let burst = NativeDriveTree(); burst.reset(provider: burstProvider)
        burst.replaceRoots((0..<8).map { folder("Burst\($0)") })
        let burstRows = burst.rootRows
        for row in burstRows { burst.toggle(row) }
        var burstPublications = 0
        burst.onChange = { burstPublications += 1 }
        try await wait { burst.rows.count == 16 && !burst.isLoading }
        precondition(burstPublications < 8, "Eight replies in two waves must not cause eight rebuilds: \(burstPublications)")
        let lone = NativeDriveTree(); lone.reset(provider: burstProvider); lone.replaceRoots([folder("Burst0")])
        let began = Date()
        lone.toggle(lone.rootRows[0])
        try await wait { lone.rows.count == 2 }
        precondition(Date().timeIntervalSince(began) < 0.5, "A single reply is shown at once, not after a delay")
        print("PASS tree publications: bursts of replies are batched and a lone reply is not delayed")

        let partialProvider = TreeTestDrive(["A": [folder("A1")], "A1": [folder("A2")], "A2": [file("A2Leaf")], "B": [folder("B1")], "B1": [file("B1Leaf")]])
        let partial = NativeDriveTree(); partial.reset(provider: partialProvider); partial.replaceRoots([folder("A"), folder("B")])
        let partialA = partial.rootRows[0], partialB = partial.rootRows[1]
        partial.expandAllLevels([partialA, partialB])
        try await wait { partial.branch(for: partialB.item).loaded }
        partial.toggle(partialB)
        precondition(partial.expandingAllRoots == [partialA.id] && !partial.expanded.contains(partialB.id),
                     "Collapsing one expanding folder stops only its own expansion")
        try await wait { !partial.isLoading }
        precondition(partial.rows.contains { $0.item.id == "A2Leaf" } && !partial.rows.contains { $0.item.id == "B1" },
                     "The other selected folder keeps expanding to its deepest level")
        partial.expandAllLevels([partialA, partialB])
        try await Task.sleep(nanoseconds: 20_000_000)
        partial.cancelExpandAll()
        try await Task.sleep(nanoseconds: 190_000_000)
        precondition(partial.expandingAllRoots.isEmpty && !partial.isLoading, "Stop cancels every selected folder's expansion")
        print("PASS collapsing one of several expanding folders cancels only that folder; Stop cancels them all")

        let cancelledProvider = TreeTestDrive(["Parent": [folder("Child")], "Child": [file("Hidden")]])
        let cancelled = NativeDriveTree(); cancelled.reset(provider: cancelledProvider); cancelled.replaceRoots([folder("Parent")])
        let cancelledRoot = cancelled.rootRows[0]
        cancelled.expandAllLevels(cancelledRoot)
        cancelled.toggle(cancelledRoot)
        try await Task.sleep(nanoseconds: 190_000_000)
        precondition(cancelled.expandingAllRoots.isEmpty && !cancelled.isLoading && cancelled.rows.count == 1 && !cancelled.expanded.contains(cancelledRoot.id))
        cancelled.toggle(cancelledRoot)
        try await wait { !cancelled.isLoading }
        let ordinaryChildCalls = await cancelledProvider.count("Child")
        precondition(cancelled.branch(for: cancelledRoot.item).loaded && cancelled.branch(for: cancelledRoot.item).error == nil)
        precondition(cancelled.rows.contains { $0.item.id == "Child" } && !cancelled.rows.contains { $0.item.id == "Hidden" }
                     && ordinaryChildCalls == 0,
                     "Ordinary reopen clears only the stopped marker and loads one level without restarting recursive discovery")
        cancelled.expandAllLevels(cancelledRoot)
        try await wait { !cancelled.isLoading }
        precondition(cancelled.rows.contains { $0.item.id == "Hidden" }, "A stopped branch must support a fresh explicit expansion")
        cancelled.reset(provider: cancelledProvider); cancelled.replaceRoots([folder("Parent")])
        cancelled.expandAllLevels(cancelled.rootRows[0])
        try await wait { cancelled.branch(for: folder("Parent")).loaded }
        precondition(!cancelled.expandingAllRoots.isEmpty, "Pending publication must count as an active expansion")
        cancelled.cancelExpandAll()
        let stoppedRows = cancelled.rows
        try await Task.sleep(nanoseconds: 190_000_000)
        precondition(!cancelled.isLoading && cancelled.expandingAllRoots.isEmpty && cancelled.rows.map(\.id) == stoppedRows.map(\.id))
        cancelled.reset(provider: cancelledProvider); cancelled.replaceRoots([folder("Parent")])
        cancelled.expandAllLevels(cancelled.rootRows[0])
        try await wait { cancelled.branch(for: folder("Parent")).loaded }
        cancelled.reset(provider: nil, search: "different context")
        try await Task.sleep(nanoseconds: 190_000_000)
        precondition(cancelled.rows.isEmpty && !cancelled.isLoading && cancelled.expandingAllRoots.isEmpty)
        print("PASS collapse, Stop and context/disconnect reset cancel recursive requests and pending publications; stale replies do not reopen rows")

        let failedProvider = TreeTestDrive(["Parent": [folder("Failed"), folder("Stalled"), file("Visible")],
            "Failed": [file("Recovered")], "Stalled": [file("Page0"), file("Page1"), file("Page2")]])
        await failedProvider.failNext("Failed"); await failedProvider.stallPages("Stalled")
        let failed = NativeDriveTree(); failed.reset(provider: failedProvider); failed.replaceRoots([folder("Parent")])
        failed.expandAllLevels(failed.rootRows[0]); try await wait { !failed.isLoading }
        precondition(failed.branch(for: folder("Failed")).error != nil && failed.branch(for: folder("Stalled")).error != nil)
        precondition(failed.rows.contains { $0.item.id == "Visible" } && failed.expandingAllRoots.isEmpty)
        let stalledCalls = await failedProvider.count("Stalled")
        precondition(stalledCalls == 1, "A non-advancing page must stop instead of enumerating forever")
        print("PASS failed branches preserve visible siblings and non-advancing pagination stops safely")
        tree.reset(provider: nil); cancelled.reset(provider: nil); failed.reset(provider: nil)

        let manager = FileManager.default
        let generated = manager.temporaryDirectory.appendingPathComponent("NativeExpandAll-\(UUID().uuidString)")
        try manager.createDirectory(at: generated.appendingPathComponent("Parent/Nested/Deep"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: generated) }
        try Data("Generated metadata fixture".utf8).write(to: generated.appendingPathComponent("Parent/Nested/Deep/Leaf.txt"))
        try manager.createDirectory(at: generated.appendingPathComponent("Sibling/Inner"), withIntermediateDirectories: true)
        try manager.createDirectory(at: generated.appendingPathComponent("Untouched"), withIntermediateDirectories: true)
        try Data("Sibling metadata fixture".utf8).write(to: generated.appendingPathComponent("Sibling/Inner/Note.txt"))
        try Data("Must stay closed".utf8).write(to: generated.appendingPathComponent("Untouched/Skip.txt"))
        try Data("Root file".utf8).write(to: generated.appendingPathComponent("Readme.txt"))
        try manager.createSymbolicLink(at: generated.appendingPathComponent("Parent/Nested/Cycle Link"),
                                      withDestinationURL: generated.appendingPathComponent("Parent"))
        let local = NativeDriveModel(kind: .local, temporaryRoot: generated.appendingPathComponent("Unused Staging"))
        local.connect(ICloudDriveProvider(rootURL: generated, kind: .local)); try await idle(local)
        let location = local.location, originalHistory = local.history
        local.expandAllLevels(row("Parent", in: local).item); try await idle(local)
        precondition(row("Leaf.txt", in: local).depth == 3 && !local.tree.rows.contains { $0.item.name == "Cycle Link" })
        precondition(local.location == location && local.history == originalHistory,
                     "Disclosing all levels must preserve the browser's current folder and breadcrumbs")
        precondition(!manager.fileExists(atPath: generated.appendingPathComponent("Unused Staging").path),
                     "Metadata expansion must not create materialization staging")
        local.toggleExpansion(row("Parent", in: local).item)
        precondition(local.canExpandAllLevels, "A connected Local Disk browsed as a list offers Expand All Levels")
        let several = [row("Readme.txt", in: local).item, row("Sibling", in: local).item, row("Parent", in: local).item]
        local.expandAllLevels(several)
        precondition(local.isExpandingAllLevels(several[1]) && local.isExpandingAllLevels(several[2]) && local.tree.expandingAllRoots.count == 2,
                     "Only the selected folders expand; the selected file is ignored")
        try await idle(local)
        precondition(row("Note.txt", in: local).depth == 2 && row("Leaf.txt", in: local).depth == 3)
        precondition(!local.tree.rows.contains { $0.item.name == "Skip.txt" } && !local.isExpandingAllLevels(several[1]),
                     "A folder outside the selection stays closed and the expansion ends")
        local.viewMode = 1
        precondition(!local.canExpandAllLevels, "Thumbnails have no outline to expand")
        local.expandAllLevels(several)
        precondition(local.tree.expandingAllRoots.isEmpty)
        local.viewMode = 0
        print("PASS Local Disk model expands several selected folders together, ignores files and unselected folders, and only offers it in List view")
        local.close()
        precondition(local.tree.rows.isEmpty && !local.tree.isLoading)
        print("PASS Local Disk model action expands generated descendants, skips symlinks, preserves navigation and creates no staging; close cancels tree state")
    }
}

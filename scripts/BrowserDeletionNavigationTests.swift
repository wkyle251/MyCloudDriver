import AppKit
import Foundation

private actor DeletionNavigationDrive: NativeCloudDrive {
    nonisolated let kind = CloudDriveKind.photos
    nonisolated let root = CloudDriveLocation(id: "root", title: "Generated navigation test")
    var contents: [String: [CloudDriveItem]]
    var fails = false
    init() {
        contents = ["root": [Self.item("a", folder: true), Self.item("b", folder: true), Self.item("c", folder: true), Self.item("d"), Self.item("e")],
                    "b": [Self.item("b-1"), Self.item("b-2")]]
    }
    nonisolated static func item(_ id: String, folder: Bool = false) -> CloudDriveItem {
        .init(id: id, name: folder ? id.uppercased() : "\(id.uppercased()).txt", isFolder: folder)
    }
    func failDeletion() { fails = true }
    func list(_ location: CloudDriveLocation, offset: Int, search: String) async throws -> CloudDrivePage {
        let items = contents[location.id] ?? []
        return .init(items: items, total: items.count)
    }
    func delete(_ items: [CloudDriveItem], progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? {
        try await Task.sleep(nanoseconds: 100_000_000)
        if fails { throw CloudDriveError.message("Generated deletion failure") }
        var removed = Set(items.map(\.id)), pending = Array(removed)
        while let id = pending.popLast() {
            for child in contents[id] ?? [] where removed.insert(child.id).inserted { pending.append(child.id) }
        }
        for key in Array(contents.keys) { contents[key]?.removeAll { removed.contains($0.id) } }
        return nil
    }
    func materialize(_ item: CloudDriveItem, directory: URL, progress: @escaping CloudDriveProgressHandler) async throws -> URL { throw CancellationError() }
    func scanItems(_ items: [CloudDriveItem], location: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> [CloudDriveItem] { items }
    func createContainer(_ name: String, in location: CloudDriveLocation) async throws -> CloudDriveUndo? { nil }
    func rename(_ item: CloudDriveItem, to name: String) async throws -> CloudDriveUndo? { nil }
    func relocate(_ items: [CloudDriveItem], from: CloudDriveLocation, to: CloudDriveLocation, copy: Bool, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { nil }
    func importFiles(_ urls: [URL], into: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { nil }
}

@main @MainActor struct BrowserDeletionNavigationTests {
    static func idle(_ model: NativeDriveModel) async throws {
        for _ in 0..<800 {
            if !model.isLoading && !model.tree.isLoading && !model.isMutating { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Deletion navigation fixture did not finish loading")
    }
    static func row(_ id: String, _ model: NativeDriveModel) -> NativeDriveRow {
        model.visibleRows.first { $0.item.id == id }!
    }
    private static func fixture() async throws -> (NativeDriveModel, DeletionNavigationDrive) {
        let drive = DeletionNavigationDrive(), model = NativeDriveModel(kind: .photos)
        model.connect(drive); try await idle(model)
        model.toggleExpansion(row("b", model)); try await idle(model)
        precondition(model.visibleRows.map { $0.item.id } == ["a", "b", "b-1", "b-2", "c", "d", "e"])
        return (model, drive)
    }
    static func main() async throws {
        _ = NSApplication.shared
        let suite = "MyCloudDriver.DeletionNavigation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        DownloaderModel.testDeletedBrowserNavigation(defaults: defaults)
        try DownloaderModel.testTrashUndoOutline(defaults: defaults)
        for (focus, removed, offset, expected) in [
            ("b", ["b"], -1, "a"), ("b", ["b"], 1, "c"),
            ("d", ["d"], -1, "c"), ("d", ["d"], 1, "e"),
            ("b-2", ["b-2"], -1, "b-1"), ("b-2", ["b-2"], 1, "c"),
            ("c", ["b", "c"], -1, "a"), ("c", ["b", "c"], 1, "d")
        ] {
            let (model, _) = try await fixture(); defer { model.disconnect() }
            model.select(row(focus, model), extending: false, toggling: false)
            model.delete(removed.map { row($0, model).item }); try await idle(model)
            precondition(model.selection.isEmpty)
            model.moveSelection(offset)
            precondition(model.focusedItemID == expected, "Native deletion \(focus), arrow \(offset) must select \(expected)")
        }
        for (focus, boundary, opposite, expected) in [("a", -1, 1, "b"), ("e", 1, -1, "d")] {
            let (model, _) = try await fixture(); defer { model.disconnect() }
            model.select(row(focus, model), extending: false, toggling: false)
            model.delete([row(focus, model).item]); try await idle(model)
            model.moveSelection(boundary); precondition(model.selection.isEmpty)
            model.moveSelection(opposite); precondition(model.focusedItemID == expected)
        }
        for (offset, expected) in [(-2, "a"), (2, "e")] {
            let (model, _) = try await fixture(); defer { model.disconnect() }
            model.viewMode = 1
            model.select(row("c", model), extending: false, toggling: false)
            model.delete([row("c", model).item]); try await idle(model)
            model.moveSelection(offset); precondition(model.focusedItemID == expected, "Grid movement must retain the deleted position")
        }
        let (failed, failingDrive) = try await fixture(); defer { failed.disconnect() }
        failed.select(row("b", failed), extending: false, toggling: false)
        await failingDrive.failDeletion(); failed.delete([row("b", failed).item]); try await idle(failed)
        precondition(failed.focusedItemID == "b")
        let (changed, _) = try await fixture(); defer { changed.disconnect() }
        changed.select(row("b", changed), extending: false, toggling: false)
        changed.delete([row("b", changed).item])
        changed.select(row("e", changed), extending: false, toggling: false)
        try await idle(changed); changed.moveSelection(-1)
        precondition(changed.focusedItemID == "d", "A newer selection must win over a completed deletion")
        let (cancelled, _) = try await fixture()
        cancelled.select(row("b", cancelled), extending: false, toggling: false)
        cancelled.delete([row("b", cancelled).item]); cancelled.disconnect()
        try await Task.sleep(nanoseconds: 200_000_000)
        precondition(cancelled.selection.isEmpty && cancelled.error == nil,
            "Disconnect cancellation must not restore a deleted position or report a stale failure")
        print("PASS native deletion navigation: folders, files, nested children, batches, grid offsets, boundaries, failures and selection changes during deletion")
    }
}

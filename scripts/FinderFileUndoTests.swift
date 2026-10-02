import AppKit
import Foundation

@main
struct FinderFileUndoTests {
    @MainActor static func main() throws {
        func mutation(_ id: String, parent: String = "", folder: Bool = false) -> FinderFileMutation {
            FinderFileMutation(fileId: id, kind: .trash, before: "true", after: "false",
                parentId: parent, name: id, requiresEmptyFolder: folder)
        }
        var history = FinderFileUndoHistory()
        let folder = mutation("folder", folder: true), file = mutation("file", parent: "folder")
        let batch = UUID()
        history.record(FinderUndoEntry(title: "Upload", mutations: [folder, file], uploadBatchID: batch))
        precondition(history.undoTitle == "Undo Upload" && history.redoTitle == "Redo")
        let request = history.begin(redo: false)!
        precondition(request.changes.map(\.fileId) == ["file", "folder"], "children are undone before parents")
        precondition(request.changes.allSatisfy { $0.after == "true" })
        precondition(history.begin(redo: false) == nil, "key repeats cannot launch duplicate requests")
        let partial = history.finish(completed: [file.id])
        precondition(partial.map(\.fileId) == ["file"])
        precondition(history.undoEntries.last!.mutations.map(\.fileId) == ["folder"])
        precondition(history.redoEntries.last!.mutations.map(\.fileId) == ["file"])
        _ = history.begin(redo: false); _ = history.finish(completed: [folder.id])
        precondition(history.undoEntries.isEmpty)
        let redoFolder = history.begin(redo: true)!
        precondition(redoFolder.changes.map(\.fileId) == ["folder"], "Redo restores parents before children")
        _ = history.finish(completed: [folder.id])
        precondition(history.begin(redo: true)!.changes.map(\.fileId) == ["file"])
        _ = history.finish(completed: [file.id])
        print("PASS history: reverse order, partial acknowledgements, redo dependency order, key-repeat exclusion")

        let before = history.undoEntries
        _ = history.begin(redo: false); _ = history.finish(completed: ["unrequested"])
        precondition(history.undoEntries == before && history.active == nil)
        _ = history.begin(redo: false); _ = history.finish(completed: [])
        precondition(history.undoEntries == before)
        _ = history.begin(redo: false); history.cancelRequest()
        precondition(history.undoEntries == before)
        _ = history.begin(redo: false); _ = history.finish(completed: [file.id])
        history.record(FinderUndoEntry(title: "Rename", mutations: [mutation("new-action")]))
        precondition(history.redoEntries.isEmpty)
        print("PASS history failures: unknown replies, empty replies, interrupted requests, new actions clear Redo")

        history.reset()
        history.record(FinderUndoEntry(title: "Upload", mutations: [folder, file], uploadBatchID: batch))
        history.record(FinderUndoEntry(title: "Upload", mutations: [folder, mutation("second", parent: "folder")], uploadBatchID: batch))
        precondition(history.undoEntries.count == 1)
        precondition(history.undoEntries[0].mutations.map(\.fileId) == ["folder", "file", "second"])
        for index in 0..<60 { history.record(FinderUndoEntry(title: "Move", mutations: [mutation("\(index)")])) }
        precondition(history.undoEntries.count == 50)
        history.reset(); precondition(history.undoEntries.isEmpty && history.redoEntries.isEmpty)
        print("PASS history scope: upload batch identity, parent order across resume, bounded memory, reset")

        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(FinderUndoRequest(changes: [folder]))) as! [String: Any]
        let changes = encoded["changes"] as! [[String: Any]]
        precondition(changes[0]["fileId"] as? String == "folder" && changes[0]["requiresEmptyFolder"] as? Bool == true)
        let suite = "com.wky.PikPakUndoTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        DownloaderModel.testFileUndoModel(defaults: defaults)
        try DownloaderModel.testTrashUndoOutline(defaults: defaults)
    }
}

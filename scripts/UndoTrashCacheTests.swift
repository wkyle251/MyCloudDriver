import Foundation

@main struct UndoTrashCacheTests {
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(condition(), "Trash refresh timed out")
    }
    @MainActor static func main() async throws {
        let model = PikPakManagementModel()
        defer { model.clear() }
        let context = PikPakManagementContext(identity: UUID(), accountID: "fixture-account",
            engineURL: URL(fileURLWithPath: "/offline-fixture"), environment: [:], credentialKind: .desktopOAuth)
        model.configure(context)
        let file = PikPakManagedFile(id: "file", name: "Report.txt", isFolder: false, size: 42)
        let folder = PikPakManagedFile(id: "folder", name: "Projects", isFolder: true, size: 0)
        let restoreFile = FinderFileMutation(fileId: file.id, kind: .trash, before: "true", after: "false", parentId: nil, name: nil)
        let restoreFolder = FinderFileMutation(fileId: folder.id, kind: .trash, before: "true", after: "false", parentId: nil, name: nil)
        var serverRows = [file, folder], requests = 0, delay = false
        model.fixture = { values in
            precondition(values["operation"] as? String == "list_trash")
            requests += 1
            let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
            let rows = try JSONSerialization.jsonObject(with: encoder.encode(serverRows))
            let data = try JSONSerialization.data(withJSONObject: ["account_id": "fixture-account", "files": rows, "next_page_token": ""])
            if delay { try await Task.sleep(nanoseconds: 100_000_000) }
            return data
        }
        await model.load(6)
        precondition(model.trash.map(\.id) == [file.id, folder.id])
        serverRows = [folder]
        model.fileTrashChanged([restoreFile])
        precondition(model.trash.map(\.id) == [folder.id], "Undo immediately removes a restored file from cached Trash")
        try await wait { requests >= 2 && !model.isLoading }
        serverRows = [file, folder]
        model.fileTrashChanged([restoreFile.reversed])
        try await wait { model.trash.count == 2 && !model.isLoading }
        print("PASS Trash cache: Undo removes restored items immediately; Redo reloads trashed items")

        delay = true
        let oldListing = Task { await model.load(6) }
        try await wait { model.isLoading }
        serverRows = []
        model.fileTrashChanged([restoreFile, restoreFolder])
        precondition(model.trash.isEmpty)
        await oldListing.value
        precondition(model.trash.isEmpty, "A pre-Undo response must not resurrect restored Trash rows")
        try await wait { requests >= 5 && !model.isLoading }
        precondition(model.trash.isEmpty)
        print("PASS Trash cache: stale in-flight replies are rejected and a fresh refresh waits for the listing lane")

        let pending = Task { await model.load(6) }
        try await wait { model.isLoading }
        model.fileTrashChanged([restoreFolder])
        let calls = requests
        model.clear()
        model.configure(.init(identity: UUID(), accountID: "other-account", engineURL: context.engineURL,
            environment: [:], credentialKind: .desktopOAuth))
        await pending.value
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(requests == calls && model.trash.isEmpty && !model.isLoading,
                     "Queued refresh must not cross an account switch")
        model.fileTrashChanged([restoreFile.reversed])
        try await Task.sleep(nanoseconds: 30_000_000)
        precondition(requests == calls, "Undo does not eagerly query a Trash page that has never been opened")
        print("PASS Trash cache: account-switch cancellation and lazy refresh")
    }
}

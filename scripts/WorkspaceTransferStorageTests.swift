import Foundation

@main
struct WorkspaceTransferStorageTests {
    static let account = "synthetic-window-account"
    static let first = "window-00000000-0000-4000-8000-000000000001"
    static let second = "window-00000000-0000-4000-8000-000000000002"
    static let uploadID = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
    static let firstRoot = UUID(uuidString: "00000000-0000-4000-8000-000000000004")!
    static let secondRoot = UUID(uuidString: "00000000-0000-4000-8000-000000000005")!
    static let primaryRoot = UUID(uuidString: "00000000-0000-4000-8000-000000000006")!

    static func download(id: UUID, name: String, root: URL) -> PendingDownloadRequest {
        .account(roots: [.init(queueID: id, path: "/\(name)", name: name, kind: .file, file: nil, relativeParent: [])],
                 destination: root.appendingPathComponent("synthetic-destination"), jobs: 1, proxyURL: "")
    }

    static func writeFixture(_ root: URL) throws {
        let store = TransferPersistenceStore(directory: root)
        let primary = download(id: primaryRoot, name: "Primary.txt", root: root)
        let upload = SavedUploadBatch(id: uploadID, sources: [root.appendingPathComponent("synthetic-source.zip").path],
                                     destination: .init(id: "synthetic-folder", name: "Destination", path: "/Destination"),
                                     workers: 1, createdAt: Date(timeIntervalSince1970: 1234), completedFiles: 3)
        try store.save(SavedTransfers(version: 1, accountID: account, downloads: [primary], uploads: [],
                                     downloadsPaused: false, pausedDownloadIDs: ["primary-file"]), accountID: account)
        let legacy = TransferPersistenceStore(directory: PikPakWorkspaceStorage.directory(root, workspaceSessionID: "secondary"))
        try legacy.save(SavedTransfers(version: 1, accountID: account, downloads: [primary], uploads: [upload]), accountID: account)
        let journal = try legacy.uploadDirectory(accountID: account, batchID: uploadID)
        try Data("synthetic upload checkpoint".utf8).write(to: journal.appendingPathComponent("batch.json"))
        let firstStore = TransferPersistenceStore(directory: PikPakWorkspaceStorage.directory(root, workspaceSessionID: first))
        try firstStore.save(SavedTransfers(version: 1, accountID: account,
            downloads: [primary, download(id: firstRoot, name: "First.txt", root: root)], uploads: [upload],
            downloadsPaused: true, pausedDownloadIDs: ["first-file"], pausedUploadIDs: ["first-upload-file"]), accountID: account)
        let secondStore = TransferPersistenceStore(directory: PikPakWorkspaceStorage.directory(root, workspaceSessionID: second))
        try secondStore.save(SavedTransfers(version: 1, accountID: account,
            downloads: [download(id: secondRoot, name: "Second.txt", root: root)], uploads: [],
            pausedPendingDownloadIDs: [secondRoot]), accountID: account)
        // Invalid namespaces must be ignored rather than treated as queue owners.
        let invalid = TransferPersistenceStore(directory: root.appendingPathComponent("Sessions/window-not-a-uuid"))
        try invalid.save(SavedTransfers(version: 1, accountID: account,
            downloads: [download(id: UUID(), name: "Ignored.txt", root: root)], uploads: []), accountID: account)
    }

    static func restoreFixture(_ root: URL) throws {
        let store = TransferPersistenceStore(directory: root)
        let restored = try store.loadSharedTransfers(accountID: account)!
        precondition(Set(restored.downloads.flatMap(\.pendingItems).map(\.id)) == [primaryRoot, firstRoot, secondRoot])
        precondition(restored.uploads.count == 1 && restored.uploads[0].id == uploadID && restored.uploads[0].completedFiles == 3)
        precondition(Set(restored.importedWorkspaceSessions ?? []) == ["secondary", first, second])
        precondition(restored.downloadsPaused == false, "A window pause must not pause the whole primary queue")
        precondition(restored.pausedPendingDownloadIDs == [firstRoot, secondRoot], "Each window must retain its paused roots")
        precondition(restored.pausedDownloadIDs == ["primary-file", "first-file"])
        precondition(restored.pausedUploadIDs == ["first-upload-file"])
        let journal = try store.uploadDirectory(accountID: account, batchID: uploadID).appendingPathComponent("batch.json")
        let journalData = try Data(contentsOf: journal)
        precondition(journalData == Data("synthetic upload checkpoint".utf8))
        let fresh = TransferPersistenceStore(directory: PikPakWorkspaceStorage.directory(root, workspaceSessionID: PikPakWorkspaceStorage.newSessionID()))
        let freshQueue = try fresh.load(SavedTransfers.self, accountID: account)
        precondition(freshQueue == nil, "A new window must not restore another window's migrated work")
        let otherAccount = try store.loadSharedTransfers(accountID: "different-synthetic-account")
        precondition(otherAccount == nil)
        try store.save(SavedTransfers(version: 1, accountID: account, downloads: [], uploads: [],
                                     importedWorkspaceSessions: restored.importedWorkspaceSessions), accountID: account)
        let completed = try TransferPersistenceStore(directory: root).loadSharedTransfers(accountID: account)!
        precondition(completed.downloads.isEmpty && completed.uploads.isEmpty, "Completed work must not reappear from retained window files")
        let laterID = PikPakWorkspaceStorage.newSessionID()
        let later = TransferPersistenceStore(directory: PikPakWorkspaceStorage.directory(root, workspaceSessionID: laterID))
        let laterDownload = download(id: UUID(), name: "Later.txt", root: root)
        try later.save(SavedTransfers(version: 1, accountID: account, downloads: [laterDownload], uploads: []), accountID: account)
        let nextLaunch = try TransferPersistenceStore(directory: root).loadSharedTransfers(accountID: account)!
        precondition(nextLaunch.downloads.map(\.deduplicationKey) == [laterDownload.deduplicationKey])
        precondition(Set(nextLaunch.importedWorkspaceSessions ?? []) == ["secondary", first, second, laterID])
        print("PASS window queue recovery: relaunch, legacy/UUID deduplication, journal copying, independent pauses, fresh namespaces and no completed-work resurrection")
    }

    static func testCurrentProcessExclusion(_ root: URL) throws {
        let store = TransferPersistenceStore(directory: root)
        let currentID = PikPakWorkspaceStorage.newSessionID()
        let currentStore = TransferPersistenceStore(directory: PikPakWorkspaceStorage.directory(root, workspaceSessionID: currentID))
        let queued = download(id: UUID(), name: "Current-window.txt", root: root)
        try currentStore.save(SavedTransfers(version: 1, accountID: account, downloads: [queued], uploads: []), accountID: account)
        let excluded = try store.loadSharedTransfers(accountID: account, excludedWorkspaceSessions: [currentID])
        precondition(excluded == nil, "A current-process queue must not be imported into primary")
        let ownerQueue = try currentStore.load(SavedTransfers.self, accountID: account)!
        precondition(ownerQueue.downloads.map(\.deduplicationKey) == [queued.deduplicationKey])
        let canonical = try store.load(SavedTransfers.self, accountID: account)
        precondition(canonical == nil, "Exclusion must not write a receipt or duplicate queue")
        let afterRelaunch = try TransferPersistenceStore(directory: root).loadSharedTransfers(accountID: account)!
        precondition(afterRelaunch.downloads.map(\.deduplicationKey) == [queued.deduplicationKey])
        precondition(afterRelaunch.importedWorkspaceSessions == [currentID])
        try store.save(SavedTransfers(version: 1, accountID: account, downloads: [], uploads: [],
                                     importedWorkspaceSessions: afterRelaunch.importedWorkspaceSessions), accountID: account)
        let nextRelaunch = try store.loadSharedTransfers(accountID: account)!
        precondition(nextRelaunch.downloads.isEmpty, "Imported and completed work must stay completed")
        print("PASS current-process exclusion: owner queue retained, no premature receipt, next-launch import once")
    }

    static func testInheritedDestinationCheckpointImport(_ root: URL) throws {
        for mode in ["nested-download", "deduplicated-download", "cleanup-only"] {
            let cleanupOnly = mode == "cleanup-only"
            let directory = root.appendingPathComponent(mode)
            let store = TransferPersistenceStore(directory: directory)
            let session = PikPakWorkspaceStorage.newSessionID()
            let legacy = TransferPersistenceStore(directory: PikPakWorkspaceStorage.directory(directory, workspaceSessionID: session))
            let anchor = directory.appendingPathComponent("synthetic-original-disk/Downloads", isDirectory: true)
            let nested = anchor.appendingPathComponent("Folder/Nested", isDirectory: true)
            let checkpoint = DownloadDestinationCheckpoint(volumeID: "synthetic-original-volume",
                bookmark: Data("synthetic-original-bookmark".utf8))
            let request = PendingDownloadRequest.account(roots: [.init(queueID: UUID(), path: "/Folder/Nested/one.bin", name: "one.bin",
                kind: .file, file: .init(id: "synthetic-source", name: "one.bin", size: "100", kind: .file), relativeParent: [])],
                destination: nested, jobs: 1, proxyURL: "")
            let cleanup = SavedDownloadPartialCleanup(path: nested.appendingPathComponent("one.bin.part").path,
                destinationPath: nested.path, sourceFileID: "synthetic-source")
            if mode == "deduplicated-download" {
                try store.save(SavedTransfers(version: 1, accountID: account, downloads: [request], uploads: []), accountID: account)
            }
            let farther = anchor.deletingLastPathComponent()
            try legacy.save(SavedTransfers(version: 1, accountID: account, downloads: cleanupOnly ? [] : [request], uploads: [],
                downloadDestinations: [farther.path: .init(volumeID: "synthetic-farther-volume"), anchor.path: checkpoint],
                cancelledDownloadCleanups: cleanupOnly ? [cleanup] : []), accountID: account)
            let imported = try store.loadSharedTransfers(accountID: account)!
            precondition(imported.downloadDestinations?[anchor.path] == checkpoint,
                         "Nested downloads and cleanup-only recovery must retain their inherited original-volume checkpoint")
            precondition(imported.downloadDestinations?[farther.path] == nil,
                         "Import must select the nearest inherited anchor")
            precondition(imported.importedWorkspaceSessions == [session])
            if cleanupOnly {
                precondition(imported.downloads.isEmpty && imported.cancelledDownloadCleanups == [cleanup])
            } else {
                precondition(imported.downloads.map(\.deduplicationKey) == [request.deduplicationKey])
            }
            let reloaded = try store.load(SavedTransfers.self, accountID: account)!
            precondition(reloaded.downloadDestinations?[anchor.path] == checkpoint,
                         "The original volume identity and bookmark must survive the atomic import checkpoint")
        }
        print("PASS inherited destination recovery: flattened/deduplicated nested requests, nearest ancestor and cleanup-only volume identity/bookmark import")
    }

    @MainActor static func main() throws {
        let arguments = CommandLine.arguments
        if arguments.count == 3 {
            let root = URL(fileURLWithPath: arguments[2], isDirectory: true)
            if arguments[1] == "--write" { try writeFixture(root) }
            else { try restoreFixture(root) }
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("window-transfer-storage-tests-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var identifiers = Set<String>()
        var directories = Set<URL>()
        for _ in 0..<128 {
            let id = PikPakWorkspaceStorage.newSessionID()
            precondition(PikPakWorkspaceStorage.isValidSessionID(id) && identifiers.insert(id).inserted)
            precondition(directories.insert(PikPakWorkspaceStorage.directory(root, workspaceSessionID: id)).inserted)
        }
        for id in ["primary", "secondary", "workspace-3", "workspace-128", first] {
            precondition(PikPakWorkspaceStorage.isValidSessionID(id))
        }
        for id in ["", "../primary", "workspace-03", "workspace-2", "window-AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA",
                   first + "/extra", "window-../primary", "window-not-a-uuid", first + " ", "window-00000000000040008000000000000001"] {
            precondition(!PikPakWorkspaceStorage.isValidSessionID(id), "Accepted invalid storage identifier: \(id)")
        }
        for mode in ["--write", "--restore"] {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: arguments[0])
            child.arguments = [mode, root.path]
            try child.run(); child.waitUntilExit()
            precondition(child.terminationStatus == 0, "Separate-process window recovery failed")
        }
        try testCurrentProcessExclusion(root.appendingPathComponent("exclusion"))
        try testInheritedDestinationCheckpointImport(root.appendingPathComponent("inherited-destination"))
        print("PASS canonical storage identifiers: 128 unique UUID namespaces, legacy compatibility and traversal/noncanonical rejection")
    }
}

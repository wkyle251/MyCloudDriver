import Foundation

@main
struct TransferPersistenceTests {
    static let account = "fixture-account"
    static let uploadID = UUID(uuidString: "0E223D80-F1B4-4770-9229-02F2E236348A")!

    static func fixture(_ root: URL) -> SavedTransfers {
        let downloads: [PendingDownloadRequest] = [
            .account(roots: [.init(queueID: uploadID, path: "/Folder/file.txt", name: "file.txt", kind: .file,
                                  file: .init(id: "cloud-file", name: "file.txt", size: "1234", kind: .file),
                                  relativeParent: ["Folder"])], destination: root.appendingPathComponent("download"), jobs: 32, proxyURL: ""),
            .shared(roots: [.init(queueID: uploadID,
                                 item: BrowserItem(id: "shared-folder", name: "Folder", size: 0, kind: .folder,
                                                   parentId: nil, mimeType: nil, createdTime: nil, modifiedTime: nil,
                                                   fileExtension: nil, iconLink: "secret-expiring-thumbnail", thumbnailLink: nil,
                                                   fileCategory: nil, hash: nil, md5Checksum: nil),
                                 root: .init(id: "shared-folder", name: "Folder", size: 0, kind: .folder,
                                             path: "/Folder", relativeParent: ["Share"]))],
                    access: .init(url: "https://mypikpak.com/s/test", passCode: "fixture-code", passCodeToken: "fixture-share-code"),
                    destination: root.appendingPathComponent("share-download"), jobs: 16, proxyURL: "")
        ]
        let upload = SavedUploadBatch(id: uploadID, sources: [root.appendingPathComponent("original/source.zip").path],
                                      destination: .init(id: "folder-id", name: "Destination", path: "/Destination"),
                                      workers: 48, createdAt: Date(timeIntervalSince1970: 1234),
                                      totalFiles: 2000, completedFiles: 1980, totalBytes: 5000, completedBytes: 4500)
        return SavedTransfers(version: 1, accountID: account, downloads: downloads, uploads: [upload])
    }

    static func testSharedQueueMigration(_ root: URL) throws {
        let store = TransferPersistenceStore(directory: root.appendingPathComponent("shared"))
        let secondary = TransferPersistenceStore(directory: store.directory.appendingPathComponent("Sessions/secondary"))
        let third = TransferPersistenceStore(directory: store.directory.appendingPathComponent("Sessions/workspace-3"))
        let original = fixture(root)
        try store.save(SavedTransfers(version: 1, accountID: account, downloads: [original.downloads[0]], uploads: []), accountID: account)
        try secondary.save(original, accountID: account)
        try third.save(original, accountID: account)
        let journal = try secondary.uploadDirectory(accountID: account, batchID: uploadID)
        let sentinel = Data("saved upload progress".utf8)
        try sentinel.write(to: journal.appendingPathComponent("batch.json"))
        let combined = try store.loadSharedTransfers(accountID: account)!
        precondition(combined.downloads.count == 2 && combined.uploads == original.uploads)
        precondition(Set(combined.importedWorkspaceSessions ?? []) == ["secondary", "workspace-3"])
        let copied = try store.uploadDirectory(accountID: account, batchID: uploadID).appendingPathComponent("batch.json")
        let copiedData = try Data(contentsOf: copied)
        precondition(copiedData == sentinel, "Upload progress must survive session consolidation")
        let legacy = try secondary.load(SavedTransfers.self, accountID: account)!
        precondition(legacy.downloads.count == 2, "Keep legacy records intact for recovery")
        let other = try store.loadSharedTransfers(accountID: "another-account")
        precondition(other == nil, "Never import a different account's queue")
        try store.save(SavedTransfers(version: 1, accountID: account, downloads: [], uploads: [],
            importedWorkspaceSessions: combined.importedWorkspaceSessions), accountID: account)
        let afterCompletion = try store.loadSharedTransfers(accountID: account)!
        precondition(afterCompletion.downloads.isEmpty && afterCompletion.uploads.isEmpty,
                     "Migration receipts must prevent completed work from reappearing")
        let fourth = TransferPersistenceStore(directory: store.directory.appendingPathComponent("Sessions/workspace-4"))
        let corrupt = try fourth.accountDirectory(account).appendingPathComponent("transfers-v1.json")
        try Data("broken".utf8).write(to: corrupt)
        let sharedFile = try store.accountDirectory(account).appendingPathComponent("transfers-v1.json")
        let before = try Data(contentsOf: sharedFile)
        do { _ = try store.loadSharedTransfers(accountID: account); preconditionFailure("Corrupt legacy data was accepted") }
        catch { let after = try Data(contentsOf: sharedFile); precondition(after == before) }
        print("PASS shared queue migration: deduplicated batches, copied upload journals, per-account receipts, no resurrection and corruption preservation")
    }

    @MainActor static func main() throws {
        let arguments = CommandLine.arguments
        if arguments.count == 3 {
            let root = URL(fileURLWithPath: arguments[2], isDirectory: true)
            let store = TransferPersistenceStore(directory: root.appendingPathComponent("store"))
            if arguments[1] == "--write" { try store.save(fixture(root), accountID: account); return }
            let restored = try store.load(SavedTransfers.self, accountID: account)!
            precondition(restored.downloads.count == 2 && restored.uploads.count == 1)
            let expected = fixture(root)
            precondition(restored.downloads.map(\.deduplicationKey) == expected.downloads.map(\.deduplicationKey))
            precondition(restored.downloads.map(\.pendingItems) == expected.downloads.map(\.pendingItems))
            precondition(restored.uploads == expected.uploads)
            if case .shared(let roots, let access, let destination, let jobs, _) = restored.downloads[1] {
                precondition(roots[0].item.iconLink == nil && roots[0].root.relativeParent == ["Share"])
                precondition(access.passCode == "fixture-code" && jobs == 16 && destination.isFileURL)
            } else { preconditionFailure("shared batch was lost") }
            return
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pikpak-transfer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try testSharedQueueMigration(root.appendingPathComponent("migration"))
        for mode in ["--write", "--read"] {
            let child = Process()
            child.executableURL = URL(fileURLWithPath: arguments[0])
            child.arguments = [mode, root.path]
            try child.run(); child.waitUntilExit()
            precondition(child.terminationStatus == 0, "separate-process restart test failed")
        }
        #if TRANSFER_PERSISTENCE_TESTS
        try DownloaderModel.testTransferLifecycle(in: root.appendingPathComponent("model-state"), fixture: fixture(root))
        print("PASS: model quit/reopen, duplicate shutdown, late callback, interrupted queue, account switch, removal")
        #endif
        print("PASS: separate-process restore of Browser + Links queues, paths, workers, upload sources and progress")
        let store = TransferPersistenceStore(directory: root.appendingPathComponent("store"))
        let accountDirectory = try store.accountDirectory(account)
        let file = accountDirectory.appendingPathComponent("transfers-v1.json")
        let data = try Data(contentsOf: file)
        precondition(!String(decoding: data, as: UTF8.self).contains("secret-expiring-thumbnail"))
        let otherAccount = try store.load(SavedTransfers.self, accountID: "another-account")
        let filePermissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as! NSNumber
        let directoryPermissions = try FileManager.default.attributesOfItem(atPath: accountDirectory.path)[.posixPermissions] as! NSNumber
        precondition(otherAccount == nil && filePermissions.intValue == 0o600 && directoryPermissions.intValue == 0o700)
        print("PASS: account isolation, private permissions, expiring preview URLs excluded")

        let many = (0..<2000).map { index in
            AccountDownloadRoot(queueID: UUID(), path: "/Folder/file-\(index)", name: "file-\(index)", kind: .file,
                                file: .init(id: "id-\(index)", name: "file-\(index)", size: "12345", kind: .file), relativeParent: ["Folder"])
        }
        let batch = PendingDownloadRequest.account(roots: many, destination: root, jobs: 64, proxyURL: "")
        let document = SavedTransfers(version: 1, accountID: account, downloads: [batch], uploads: [])
        try store.save(document, accountID: account)
        let loaded = try store.load(SavedTransfers.self, accountID: account)!
        precondition(loaded.downloads[0].itemCount == 2000)
        let remaining = loaded.downloads[0].removingPendingItem(id: many[42].queueID)!
        precondition(remaining.itemCount == 1999)
        try store.save(SavedTransfers(version: 1, accountID: account, downloads: [remaining], uploads: []), accountID: account)
        let afterRemoval = try store.load(SavedTransfers.self, accountID: account)!
        precondition(afterRemoval.downloads[0].itemCount == 1999)
        try store.save(SavedTransfers(version: 1, accountID: account, downloads: [], uploads: []), accountID: account)
        let afterClear = try store.load(SavedTransfers.self, accountID: account)!
        precondition(afterClear.downloads.isEmpty)
        print("PASS: 2,000-file queue, single-item removal, cleared/completed batches stay removed")

        try Data("broken checkpoint".utf8).write(to: file)
        do { _ = try store.load(SavedTransfers.self, accountID: account); preconditionFailure("corruption accepted") }
        catch { let preserved = try Data(contentsOf: file); precondition(preserved == Data("broken checkpoint".utf8)) }
        let external = root.appendingPathComponent("untouched.txt")
        try Data("untouched".utf8).write(to: external)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: external)
        do { try store.save(document, accountID: account); preconditionFailure("symlink accepted") }
        catch { let preserved = try Data(contentsOf: external); precondition(preserved == Data("untouched".utf8)) }
        print("PASS: corrupt state preserved; symbolic-link overwrite refused")
    }
}

import CryptoKit
import Foundation

/// One private file per verified account. Atomic replacements leave the last
/// valid queue intact on interruption; a malformed file is never overwritten
/// by an automatic restore. No refresh tokens or signed media URLs belong here.
struct TransferPersistenceStore {
    let directory: URL

    /// Import old window queues once per account. The receipt and combined
    /// queue are one atomic write, so completed work cannot reappear on the
    /// next launch. Keep the old files intact for recovery or an older build.
    func loadSharedTransfers(accountID: String) throws -> SavedTransfers? {
        let saved = try load(SavedTransfers.self, accountID: accountID)
        if let saved, saved.version != 1 || saved.accountID != accountID { throw CocoaError(.fileReadCorruptFile) }
        let sessions = directory.appendingPathComponent("Sessions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: sessions.path) else { return saved }
        try Self.protectDirectory(sessions)
        var imported = Set(saved?.importedWorkspaceSessions ?? [])
        var downloads = saved?.downloads ?? []
        var uploads = saved?.uploads ?? []
        var cancelled = Set(saved?.cancelledDownloads ?? [])
        var downloadKeys = Set(downloads.map(\.deduplicationKey))
        var uploadIDs = Set(uploads.map(\.id))
        var changed = false
        for session in try FileManager.default.contentsOfDirectory(at: sessions, includingPropertiesForKeys: nil).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let id = session.lastPathComponent
            guard id != "primary", PikPakWorkspaceStorage.isValidSessionID(id), !imported.contains(id) else { continue }
            let legacy = TransferPersistenceStore(directory: session)
            guard let queue = try legacy.load(SavedTransfers.self, accountID: accountID) else { continue }
            guard queue.version == 1, queue.accountID == accountID else { throw CocoaError(.fileReadCorruptFile) }
            for upload in queue.uploads where uploadIDs.insert(upload.id).inserted {
                let relative = "uploads/\(upload.id.uuidString)"
                let source = try legacy.accountDirectory(accountID).appendingPathComponent(relative)
                let target = try accountDirectory(accountID).appendingPathComponent(relative)
                if FileManager.default.fileExists(atPath: source.path), !FileManager.default.fileExists(atPath: target.path) {
                    try Self.protectDirectory(source)
                    try Self.protectDirectory(target.deletingLastPathComponent())
                    // Copy through a private sibling so an interrupted import
                    // cannot leave a half-copied journal at its final path.
                    let temporary = target.deletingLastPathComponent().appendingPathComponent(".import-\(UUID())")
                    defer { try? FileManager.default.removeItem(at: temporary) }
                    try FileManager.default.copyItem(at: source, to: temporary)
                    try FileManager.default.moveItem(at: temporary, to: target)
                }
                uploads.append(upload)
            }
            downloads.append(contentsOf: queue.downloads.filter { downloadKeys.insert($0.deduplicationKey).inserted })
            cancelled.formUnion(queue.cancelledDownloads ?? [])
            imported.insert(id); changed = true
        }
        guard changed else { return saved }
        let result = SavedTransfers(version: 1, accountID: accountID, downloads: downloads, uploads: uploads,
                                    cancelledDownloads: Array(cancelled), importedWorkspaceSessions: imported.sorted(),
                                    downloadsPaused: saved?.downloadsPaused, pausedDownloadIDs: saved?.pausedDownloadIDs,
                                    pausedPendingDownloadIDs: saved?.pausedPendingDownloadIDs, pausedUploadIDs: saved?.pausedUploadIDs)
        try save(result, accountID: accountID)
        return result
    }

    func accountDirectory(_ accountID: String) throws -> URL {
        guard !accountID.isEmpty else { throw CocoaError(.fileReadNoPermission) }
        try Self.protectDirectory(directory)
        let key = SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
        let result = directory.appendingPathComponent(key, isDirectory: true)
        try Self.protectDirectory(result)
        return result
    }

    func uploadDirectory(accountID: String, batchID: UUID) throws -> URL {
        let uploads = try accountDirectory(accountID).appendingPathComponent("uploads", isDirectory: true)
        try Self.protectDirectory(uploads)
        let result = uploads.appendingPathComponent(batchID.uuidString, isDirectory: true)
        try Self.protectDirectory(result)
        return result
    }

    func load<T: Decodable>(_ type: T.Type, accountID: String) throws -> T? {
        let url = try accountDirectory(accountID).appendingPathComponent("transfers-v1.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try Self.validateFile(url)
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard (values.fileSize ?? 0) <= 64 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }

    func save<T: Encodable>(_ value: T, accountID: String) throws {
        let url = try accountDirectory(accountID).appendingPathComponent("transfers-v1.json")
        if FileManager.default.fileExists(atPath: url.path) { try Self.validateFile(url) }
        let data = try JSONEncoder().encode(value)
        guard data.count <= 64 * 1024 * 1024 else { throw CocoaError(.fileWriteOutOfSpace) }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func validateFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
    }

    private static func protectDirectory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
        } else {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }
}

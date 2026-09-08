import CryptoKit
import Foundation

/// One private file per verified account. Atomic replacements leave the last
/// valid queue intact on interruption; a malformed file is never overwritten
/// by an automatic restore. No refresh tokens or signed media URLs belong here.
struct TransferPersistenceStore {
    let directory: URL

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

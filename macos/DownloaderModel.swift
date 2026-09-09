import AppKit
import AVFoundation
import Combine
import Foundation
@preconcurrency import QuickLookUI
import UniformTypeIdentifiers

private let duplicateProgressPrefix = "@pikpak-duplicate-progress:"
private let emptyFolderProgressPrefix = "@pikpak-empty-folder-progress:"
private let uploadProgressPrefix = "@pikpak-upload-progress:"
private let archiveProgressPrefix = "@pikpak-archive-progress:"
private let mergeProgressPrefix = "@pikpak-merge-progress:"

enum BrowserItemKind: String, Codable {
    case file = "drive#file"
    case folder = "drive#folder"
}

enum PreviewMediaKind {
    case image
    case video
    case audio
    case other
}

/// One retained span of the media, expressed as a 0...1 fraction of the file so
/// the buffer bar can draw it at its real position instead of left-anchoring a
/// single total.
struct PreviewBufferSegment: Identifiable, Equatable {
    let id: Int
    let start: Double
    let end: Double

    var width: Double { max(end - start, 0) }
}

enum PreviewStreamingState: Equatable {
    case idle
    case preparing
    case ready
    case playing
    case buffering
    case paused
    case finished
    case compatibility
    case failed

    var title: String {
        switch self {
        case .idle: return "Not loaded"
        case .preparing: return "Preparing stream"
        case .ready: return "Ready to play"
        case .playing: return "Streaming"
        case .buffering: return "Buffering"
        case .paused: return "Paused"
        case .finished: return "Finished"
        case .compatibility: return "Compatibility preview"
        case .failed: return "Stream unavailable"
        }
    }

    var systemImage: String {
        switch self {
        case .idle: return "cloud"
        case .preparing: return "arrow.triangle.2.circlepath"
        case .ready: return "play.circle"
        case .playing: return "wave.3.right.circle.fill"
        case .buffering: return "hourglass"
        case .paused: return "pause.circle"
        case .finished: return "checkmark.circle.fill"
        case .compatibility: return "play.rectangle.on.rectangle"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}

/// A safe, user-facing diagnostic attached to an operation failure. Values
/// stored here have already been stripped of credentials and signed URLs, so
/// the complete block can be selected or copied from the UI.
struct AppErrorDiagnostic: Equatable {
    let source: String
    let code: String
    let message: String
    let context: String?

    var displayText: String {
        var lines = [
            "Source: \(source)",
            "Code: \(code)",
            "Message: \(message)",
        ]
        if let context, !context.isEmpty {
            lines.append(context)
        }
        return lines.joined(separator: "\n")
    }

    func copyText(summary: String) -> String {
        "\(summary)\n\(displayText)"
    }
}

struct BrowserItem: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let size: UInt64
    let kind: BrowserItemKind
    let parentId: String?
    let mimeType: String?
    let createdTime: String?
    let modifiedTime: String?
    let fileExtension: String?
    let iconLink: String?
    let thumbnailLink: String?
    let fileCategory: String?
    let hash: String?
    let md5Checksum: String?

    var isFolder: Bool { kind == .folder }

    /// PikPak's server-side extractor accepts ZIP, RAR, and 7z archives. EPUB
    /// also uses a ZIP container, but is intentionally kept as a document.
    var isCloudExtractableArchive: Bool {
        guard !isFolder else { return false }
        let mime = (mimeType ?? "").lowercased()
        let ext = normalizedFileExtension
        guard ext != "epub", mime != "application/epub+zip" else { return false }
        if ["zip", "rar", "7z"].contains(ext) { return true }
        return mime == "application/zip"
            || mime == "application/x-zip-compressed"
            || mime == "application/vnd.rar"
            || mime == "application/x-rar"
            || mime == "application/x-rar-compressed"
            || mime == "application/x-7z-compressed"
    }

    var normalizedFileExtension: String {
        let reported = fileExtension?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let value = reported.isEmpty ? (name as NSString).pathExtension : reported
        return value.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
    }

    var artworkURL: URL? {
        for candidate in [thumbnailLink, iconLink] {
            if let candidate, let url = URL(string: candidate), url.scheme == "https" {
                return url
            }
        }
        return nil
    }

    var mediaKind: PreviewMediaKind {
        let mime = (mimeType ?? "")
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let ext = normalizedFileExtension
        // A `.ts` name can mean either MPEG transport stream or TypeScript.
        // Trust an explicit text MIME type before extension-based media hints.
        if mime.hasPrefix("text/") { return .other }
        if mime.hasPrefix("image/") || ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff"].contains(ext) {
            return .image
        }
        if mime.hasPrefix("video/") || ["mp4", "m4v", "mov", "mkv", "webm", "avi", "ts", "m2ts"].contains(ext) {
            return .video
        }
        if mime.hasPrefix("audio/") || ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus"].contains(ext) {
            return .audio
        }
        return .other
    }

    /// Text is rendered natively so it remains searchable/selectable instead
    /// of being flattened into an image. Keep this conservative: every other
    /// file still gets the explicit macOS Quick Look fallback.
    var isTextPreviewable: Bool {
        guard !isFolder else { return false }
        let mime = (mimeType ?? "")
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if mime == "text/rtf" || mime == "application/rtf" { return false }
        if mime.hasPrefix("text/") { return true }
        if [
            "application/json",
            "application/ld+json",
            "application/xml",
            "application/x-httpd-php",
            "application/x-sh",
            "application/x-yaml",
            "application/yaml",
            "application/toml",
            "application/javascript",
            "application/sql",
        ].contains(mime) {
            return true
        }
        return [
            "txt", "text", "md", "markdown", "log", "csv", "tsv",
            "json", "jsonl", "xml", "yaml", "yml", "toml", "ini",
            "cfg", "conf", "plist", "html", "htm", "css", "js", "mjs",
            "cjs", "jsx", "tsx", "swift", "rs", "py", "rb", "php",
            "sh", "bash", "zsh", "fish", "c", "h", "cpp", "hpp",
            "java", "kt", "kts", "go", "sql", "srt", "vtt", "nfo",
            "asc",
        ].contains(normalizedFileExtension)
    }

    var supportsInlinePreview: Bool {
        mediaKind != .other || isTextPreviewable
    }

    /// Finder-style text shown in the Kind column and reused by that column's
    /// sorter so the visible value and its ordering cannot drift apart.
    var kindDisplayTitle: String {
        guard !isFolder else { return "Folder" }
        let mime = (mimeType ?? "").lowercased()
        let ext = (fileExtension ?? (name as NSString).pathExtension).lowercased()
        switch mime {
        case "image/jpeg": return "JPEG image"
        case "image/png": return "PNG image"
        case "image/gif": return "GIF image"
        case "video/mp4": return "MPEG-4 movie"
        case "video/quicktime": return "QuickTime movie"
        case "audio/mpeg": return "MP3 audio"
        case "application/pdf": return "PDF document"
        default:
            if mime.hasPrefix("image/") { return "Image" }
            if mime.hasPrefix("video/") { return "Movie" }
            if mime.hasPrefix("audio/") { return "Audio" }
            return ext.isEmpty ? "File" : "\(ext.uppercased()) file"
        }
    }
}

struct ArchiveEntry: Codable, Hashable, Identifiable {
    let index: Int
    let name: String
    let path: String
    let kind: String
    let size: UInt64

    var id: Int { index }
    var isFolder: Bool {
        kind == BrowserItemKind.folder.rawValue || path.hasSuffix("/")
    }
}

struct ArchiveInspection: Codable, Equatable {
    let title: String
    let status: String
    let statusText: String
    let ready: Bool
    let requiredPassword: Bool
    let entries: [ArchiveEntry]
}

struct ArchiveExtractionResult: Codable, Equatable {
    let archiveFileId: String
    let outputFileId: String
    let progress: Double
    let phase: String
}

private struct ArchiveInspectInput: Codable {
    let fileId: String
    let gcid: String
    let password: String

    enum CodingKeys: String, CodingKey {
        case fileId = "file_id"
        case gcid
        case password
    }
}

private struct ArchiveExtractInput: Codable {
    let fileId: String
    let gcid: String
    let password: String
    let selectedIndices: [Int]

    enum CodingKeys: String, CodingKey {
        case fileId = "file_id"
        case gcid
        case password
        case selectedIndices = "selected_indices"
    }
}

private struct ArchiveProgressEvent: Decodable {
    let event: String
    let status: String?
    let progress: Double?
    let phase: String?
    let outputFileId: String?
}

enum BrowserSortColumn: String, CaseIterable {
    case name
    case size
    case kind
    case modified

    var title: String {
        switch self {
        case .name: return "Name"
        case .size: return "Size"
        case .kind: return "Kind"
        case .modified: return "Date Modified"
        }
    }
}

enum BrowserSortDirection: String {
    case ascending
    case descending

    var title: String {
        switch self {
        case .ascending: return "ascending"
        case .descending: return "descending"
        }
    }

    var systemImage: String {
        switch self {
        case .ascending: return "chevron.up"
        case .descending: return "chevron.down"
        }
    }

    mutating func toggle() {
        self = self == .ascending ? .descending : .ascending
    }
}

struct BrowserPage: Codable {
    let files: [BrowserItem]
    let nextPageToken: String?
    let quota: StorageQuota?
    let accountId: String?
    var accountProfile: PikPakAccountProfile? = nil
}

private struct AccountProfileEnvelope: Decodable {
    let accountProfile: PikPakAccountProfile?
}

enum BrowserSource: Equatable {
    case account
    case sharedLink
}

enum ShareLinkFeedbackTone: Equatable {
    case progress
    case success
    case error
    case info
}

enum SharedLinkEntryState: Equatable, Codable {
    case loading
    case ready
    case failed(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case message
    }

    private enum Kind: String, Codable {
        case loading
        case ready
        case failed
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .loading:
            self = .loading
        case .ready:
            self = .ready
        case .failed:
            self = .failed(try container.decodeIfPresent(String.self, forKey: .message) ?? "Could not open")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .loading:
            try container.encode(Kind.loading, forKey: .kind)
        case .ready:
            try container.encode(Kind.ready, forKey: .kind)
        case .failed(let message):
            try container.encode(Kind.failed, forKey: .kind)
            try container.encode(message, forKey: .message)
        }
    }

    var title: String {
        switch self {
        case .loading: return "Loading"
        case .ready: return "Ready"
        case .failed: return "Could not open"
        }
    }
}

struct SharedLinkEntry: Identifiable, Equatable, Codable {
    let id: UUID
    /// Mutable so Edit Link can repoint an existing row instead of forcing a
    /// disconnect and re-add, which would lose its id, order, and added date.
    var url: String
    var name: String
    var state: SharedLinkEntryState
    var savedItemCount: Int
    let addedAt: Date
}

struct SharedLinkRetryProgress: Equatable {
    let completed: Int
    let total: Int
}

struct ShareAccessInput: Codable, Equatable {
    let url: String
    let passCode: String
    let passCodeToken: String

    enum CodingKeys: String, CodingKey {
        case url
        case passCode = "pass_code"
        case passCodeToken = "pass_code_token"
    }
}

private struct ShareBrowseInput: Codable {
    let url: String
    let passCode: String
    let passCodeToken: String
    let parentId: String?
    let pageToken: String?
    let limit: Int

    init(
        access: ShareAccessInput,
        parentId: String?,
        pageToken: String?,
        limit: Int
    ) {
        url = access.url
        passCode = access.passCode
        passCodeToken = access.passCodeToken
        self.parentId = parentId
        self.pageToken = pageToken
        self.limit = limit
    }

    enum CodingKeys: String, CodingKey {
        case url
        case passCode = "pass_code"
        case passCodeToken = "pass_code_token"
        case parentId = "parent_id"
        case pageToken = "page_token"
        case limit
    }
}

private struct ShareBrowsePage: Codable {
    let files: [BrowserItem]
    let nextPageToken: String?
    let shareId: String
    let passCodeToken: String
    let parentId: String
    let folderName: String
}

private struct SharePreviewInput: Codable {
    let url: String
    let passCode: String
    let passCodeToken: String
    let fileId: String

    init(access: ShareAccessInput, fileId: String) {
        url = access.url
        passCode = access.passCode
        passCodeToken = access.passCodeToken
        self.fileId = fileId
    }

    enum CodingKeys: String, CodingKey {
        case url
        case passCode = "pass_code"
        case passCodeToken = "pass_code_token"
        case fileId = "file_id"
    }
}

private struct ShareMeasureInput: Codable {
    let url: String
    let passCode: String
    let passCodeToken: String
    let folderId: String

    init(access: ShareAccessInput, folderId: String) {
        url = access.url
        passCode = access.passCode
        passCodeToken = access.passCodeToken
        self.folderId = folderId
    }

    enum CodingKeys: String, CodingKey {
        case url
        case passCode = "pass_code"
        case passCodeToken = "pass_code_token"
        case folderId = "folder_id"
    }
}

private struct ShareSaveInput: Codable {
    let url: String
    let passCode: String
    let passCodeToken: String
    let fileIds: [String]

    init(access: ShareAccessInput, fileIds: [String]) {
        url = access.url
        passCode = access.passCode
        passCodeToken = access.passCodeToken
        self.fileIds = fileIds
    }

    enum CodingKeys: String, CodingKey {
        case url
        case passCode = "pass_code"
        case passCodeToken = "pass_code_token"
        case fileIds = "file_ids"
    }
}

private struct ShareSaveResult: Codable {
    let restoreStatus: String
    let restoreTaskId: String?
    let savedCount: Int
    let cacheParentIds: [String]?
}

struct ShareDownloadRoot: Codable {
    let id: String
    let name: String
    let size: UInt64
    let kind: BrowserItemKind
    let path: String
    var relativeParent: [String]? = nil

    enum CodingKeys: String, CodingKey {
        case id, name, size, kind, path
        case relativeParent = "relative_parent"
    }
}

/// One Browser or Links selection waiting for the user to start downloading.
/// This is deliberately separate from `DownloadTransfer`: a selected folder is
/// still one removable queue item before the engine recursively discovers its
/// files.
struct PendingDownloadItem: Identifiable, Equatable {
    let id: UUID
    let name: String
    let remotePath: String
    let destinationPath: String
    let kind: BrowserItemKind
    let isShared: Bool

    var isFolder: Bool { kind == .folder }
}

struct AccountDownloadRoot: Codable {
    let queueID: UUID
    let path: String
    let name: String
    let kind: BrowserItemKind
    let file: AccountDownloadCachedFile?
    let relativeParent: [String]
}

struct AccountDownloadCachedFile: Codable {
    let id: String
    let name: String
    // FileInfo uses PikPak's string-encoded u64 wire representation.
    let size: String
    let kind: BrowserItemKind
}

private struct AccountDownloadInput: Encodable {
    struct Root: Encodable {
        let path: String
        let file: AccountDownloadCachedFile?
        let relativeParent: [String]
        enum CodingKeys: String, CodingKey {
            case path, file
            case relativeParent = "relative_parent"
        }
    }
    let roots: [Root]
}

struct SharedPendingDownloadRoot: Codable {
    let queueID: UUID
    let item: BrowserItem
    let root: ShareDownloadRoot

    // Persist only file identity and destination metadata, not expiring preview URLs.
    enum CodingKeys: CodingKey { case queueID, root }
    init(queueID: UUID, item: BrowserItem, root: ShareDownloadRoot) {
        self.queueID = queueID; self.item = item; self.root = root
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        queueID = try container.decode(UUID.self, forKey: .queueID)
        root = try container.decode(ShareDownloadRoot.self, forKey: .root)
        item = BrowserItem(id: root.id, name: root.name, size: root.size, kind: root.kind,
                           parentId: nil, mimeType: nil, createdTime: nil, modifiedTime: nil,
                           fileExtension: nil, iconLink: nil, thumbnailLink: nil, fileCategory: nil,
                           hash: nil, md5Checksum: nil)
    }
}

struct SavedUploadBatch: Codable, Identifiable, Equatable {
    let id: UUID
    let sources: [String]
    let destination: BrowserLocation
    var workers: Int
    let createdAt: Date
    var totalFiles: Int = 0
    var completedFiles: Int = 0
    var totalBytes: UInt64 = 0
    var completedBytes: UInt64 = 0
}

struct SavedTransfers: Codable {
    let version: Int
    let accountID: String
    let downloads: [PendingDownloadRequest]
    let uploads: [SavedUploadBatch]
}

private struct ShareDownloadInput: Codable {
    let url: String
    let passCode: String
    let passCodeToken: String
    let roots: [ShareDownloadRoot]

    init(access: ShareAccessInput, roots: [ShareDownloadRoot]) {
        url = access.url
        passCode = access.passCode
        passCodeToken = access.passCodeToken
        self.roots = roots
    }

    enum CodingKeys: String, CodingKey {
        case url
        case passCode = "pass_code"
        case passCodeToken = "pass_code_token"
        case roots
    }
}

struct PreviewSource: Codable, Hashable {
    let url: String
    let label: String?
    let isOrigin: Bool
    let videoCodec: String?
    let audioCodec: String?

    var contentURL: URL? {
        guard let url = URL(string: url), url.scheme == "https" else { return nil }
        return url
    }
}

struct PreviewInfo: Codable {
    let name: String
    let size: UInt64
    let mimeType: String?
    let thumbnailLink: String?
    let iconLink: String?
    let contentLink: String
    let sources: [PreviewSource]?

    var contentURL: URL? {
        guard let url = URL(string: contentLink), url.scheme == "https" else { return nil }
        return url
    }
}

private struct FolderMeasurementReport: Codable {
    let totalBytes: UInt64
    let fileCount: UInt64
    let folderCount: UInt64
    let folders: [String: FolderMeasurement]?
    let parents: [String: String]?
    let listings: [String: [FolderSizeEntry]]?
    let reusedFolders: Int?

    var rootMeasurement: FolderMeasurement {
        FolderMeasurement(
            totalBytes: totalBytes,
            fileCount: fileCount,
            folderCount: folderCount
        )
    }
}

private struct FolderMeasurementCacheAccount: Codable {
    var updatedAt: TimeInterval
    var measurements: [String: FolderMeasurement]
    // Optional for lossless migration of the original aggregate-only cache.
    var index: FolderSizeIndex? = nil
}

private struct FolderMeasurementCacheDocument: Codable {
    var version: Int
    var accounts: [String: FolderMeasurementCacheAccount]
}

/// Persists opaque PikPak identifiers, direct item sizes, and aggregate counts.
/// The cache is isolated by PikPak account id and protected as owner-only data.
private enum FolderMeasurementCacheStore {
    #if FOLDER_SIZE_TESTS
    static var testFileURL: URL?
    #endif
    private static let schemaVersion = 1
    private static let maximumBytes = 64 * 1_024 * 1_024
    private static let maximumAccounts = 4
    private static let filename = "folder-sizes-v1.json"

    static func account(for accountID: String) throws -> FolderMeasurementCacheAccount? {
        let document = try loadDocument()
        guard document.version == schemaVersion else { return nil }
        return document.accounts[accountID]
    }

    static func save(
        _ measurements: [String: FolderMeasurement],
        index: FolderSizeIndex,
        for accountID: String
    ) throws {
        var document = (try? loadDocument()) ?? FolderMeasurementCacheDocument(
            version: schemaVersion,
            accounts: [:]
        )
        if document.version != schemaVersion {
            document = FolderMeasurementCacheDocument(version: schemaVersion, accounts: [:])
        }
        document.accounts[accountID] = FolderMeasurementCacheAccount(
            updatedAt: Date().timeIntervalSince1970,
            measurements: measurements,
            index: index
        )
        if document.accounts.count > maximumAccounts {
            let retainedIDs = document.accounts
                .sorted { $0.value.updatedAt > $1.value.updatedAt }
                .prefix(maximumAccounts)
                .map(\.key)
            document.accounts = document.accounts.filter { retainedIDs.contains($0.key) }
        }
        try write(document)
    }

    static func removeMeasurements(for accountID: String) throws {
        guard var document = try? loadDocument(), document.version == schemaVersion else { return }
        document.accounts.removeValue(forKey: accountID)
        try write(document)
    }

    static func removeAll() throws {
        let url = try cacheFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw LocalCredentialStoreError.invalidStorageLocation
        }
        try FileManager.default.removeItem(at: url)
    }

    private static func loadDocument() throws -> FolderMeasurementCacheDocument {
        let url = try cacheFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return FolderMeasurementCacheDocument(version: schemaVersion, accounts: [:])
        }
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            (values.fileSize ?? 0) <= maximumBytes
        else {
            throw LocalCredentialStoreError.invalidStorageLocation
        }
        try protectFile(at: url)
        return try JSONDecoder().decode(
            FolderMeasurementCacheDocument.self,
            from: Data(contentsOf: url)
        )
    }

    private static func write(_ document: FolderMeasurementCacheDocument) throws {
        let url = try cacheFileURL()
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw LocalCredentialStoreError.invalidStorageLocation
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= maximumBytes else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try data.write(to: url, options: .atomic)
        try protectFile(at: url)
    }

    private static func cacheFileURL() throws -> URL {
        #if FOLDER_SIZE_TESTS
        if let testFileURL {
            try ensurePrivateDirectory(testFileURL.deletingLastPathComponent())
            return testFileURL
        }
        #endif
        let directory = try LocalCredentialStore.applicationSupportDirectoryURL()
            .appendingPathComponent("Cache", isDirectory: true)
        try ensurePrivateDirectory(directory)
        return directory.appendingPathComponent(filename, isDirectory: false)
    }

    private static func ensurePrivateDirectory(_ directory: URL) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard isDirectory.boolValue, values.isSymbolicLink != true else {
                throw LocalCredentialStoreError.invalidStorageLocation
            }
        } else {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
    }

    private static func protectFile(at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }
}

enum DuplicateMatchKind: String, Codable {
    case exactContent = "exact_content"
    case matchingNameAndSize = "matching_name_and_size"

    var title: String {
        switch self {
        case .exactContent: return "Exact content"
        case .matchingNameAndSize: return "Possible match"
        }
    }

    var explanation: String {
        switch self {
        case .exactContent:
            return "PikPak reports the same content identifier and file size."
        case .matchingNameAndSize:
            return "PikPak did not provide a content identifier; the name and size match."
        }
    }
}

struct DuplicateFile: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let path: String
    let size: UInt64
    let modifiedTime: String?
}

struct DuplicateGroup: Codable, Identifiable {
    let id: String
    let matchKind: DuplicateMatchKind
    let size: UInt64
    let copies: Int
    let reclaimableBytes: UInt64
    let files: [DuplicateFile]
}

struct DuplicateScan: Codable {
    let rootPath: String
    let scannedFiles: Int
    let scannedFolders: Int
    let failedFolders: Int
    let duplicateFiles: Int
    let exactGroups: Int
    let possibleGroups: Int
    let reclaimableBytes: UInt64
    let groups: [DuplicateGroup]
}

private struct DuplicateProgressEvent: Decodable {
    let event: String
    let rootPath: String?
    let scannedFiles: Int?
    let scannedFolders: Int?
    let discoveredFolders: Int?
    let pendingFolders: Int?
    let failedFolders: Int?
    let currentPath: String?
    let attempt: Int?
    let maxAttempts: Int?
    let retryInMillis: UInt64?
}

private struct TrashResult: Codable {
    let trashedIds: [String]
}

private struct MoveResult: Codable {
    let movedIds: [String]
    let parentId: String
}

private struct MergeFoldersResult: Codable {
    let destinationId: String
    let mergedSourceIds: [String]
    let movedItems: Int
}

private struct MergeProgressEvent: Decodable {
    let event: String
    let sourceId: String?
    let sourceIndex: Int?
    let sourceCount: Int?
    let completedSources: Int?
    let movedItems: Int?
    let totalItems: Int?
    let remainingItems: Int?
    let attempt: Int?
    let maxAttempts: Int?
    let retryInMillis: UInt64?
}

private struct CreateFolderResult: Codable {
    let id: String
    let name: String
    let parentId: String
}

private struct RenameResult: Codable {
    let id: String
    let name: String
}

struct EmptyFolderCleanup: Codable {
    let rootPath: String
    let scannedFolders: Int
    let candidateFolders: Int
    let recheckedFolders: Int
    let skippedNonEmptyFolders: Int
    let removedFolders: Int
    let removedIds: [String]
}

private struct DSStoreCleanup: Codable {
    let rootPath: String
    let scannedFolders: Int
    let candidateFiles: Int
    let recheckedFiles: Int
    let skippedFiles: Int
    let removedFiles: Int
    let removedIds: [String]
}

struct StorageQuota: Codable, Equatable {
    let total: UInt64
    let used: UInt64

    var remaining: UInt64 {
        total > used ? total - used : 0
    }

    var usedFraction: Double {
        guard total > 0 else { return 0 }
        return min(max(Double(used) / Double(total), 0), 1)
    }
}

private struct EmptyFolderProgressEvent: Decodable {
    let event: String
    let rootPath: String?
    let scannedFolders: Int?
    let discoveredFolders: Int?
    let emptyFolders: Int?
    let checkedFolders: Int?
    let removedFolders: Int?
    let skippedFolders: Int?
    let currentPath: String?
}

enum DownloadRunState: Equatable {
    case ready
    case scanning
    case downloading
    case stopping
    case stopped
    case completed
    case failed

    var title: String {
        switch self {
        case .ready: return "Ready"
        case .scanning: return "Scanning"
        case .downloading: return "Downloading"
        case .stopping: return "Stopping"
        case .stopped: return "Stopped"
        case .completed: return "Complete"
        case .failed: return "Needs attention"
        }
    }
}

enum DownloadTransferState: Equatable {
    case queued
    case preparing
    case downloading
    case retrying(attempt: Int)
    case completed
    case skipped
    case failed
    case stopped
}

struct DownloadTransfer: Identifiable, Equatable {
    let id: String
    var name: String
    var downloadedBytes: UInt64
    var totalBytes: UInt64
    var state: DownloadTransferState
    /// Retry metadata emitted while the engine flattens a folder tree. Keeping
    /// it on the row lets one failed descendant resume without restarting its
    /// complete parent selection.
    var remotePath: String? = nil
    var outputDirectoryPath: String? = nil
    var isShared: Bool = false

    var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        return min(Double(downloadedBytes) / Double(totalBytes), 1)
    }
}

private struct DownloadQueueEntry: Decodable {
    let fileId: String
    let name: String
    let totalBytes: UInt64
    let remotePath: String?
    let outputDirectory: String?
}

private struct DownloadProgressEvent: Decodable {
    let event: String
    let totalFiles: Int?
    let totalBytes: UInt64?
    let fileId: String?
    let name: String?
    let downloadedBytes: UInt64?
    /// Bytes received from the network during this run. Unlike
    /// `downloadedBytes`, this excludes an existing resumable `.part` prefix
    /// and includes bytes that had to be fetched again after a restart.
    let transferredBytes: UInt64?
    let attempt: Int?
    let retryInMillis: UInt64?
    let files: [DownloadQueueEntry]?
}

enum UploadRunState: Equatable {
    case ready
    case hashing
    case uploading
    case paused
    case stopping
    case stopped
    case completed
    case failed

    var title: String {
        switch self {
        case .ready: return "Ready"
        case .hashing: return "Preparing files"
        case .uploading: return "Uploading"
        case .paused: return "Paused"
        case .stopping: return "Stopping"
        case .stopped: return "Stopped"
        case .completed: return "Complete"
        case .failed: return "Needs attention"
        }
    }
}

enum UploadTransferState: Equatable {
    case queued
    case hashing
    case uploading
    case retrying(attempt: Int, maxAttempts: Int)
    case instant
    case completed
    case failed
    case stopped
}

struct UploadTransfer: Identifiable, Equatable {
    let id: String
    var name: String
    var hashedBytes: UInt64
    var uploadedBytes: UInt64
    var totalBytes: UInt64
    var state: UploadTransferState
    /// Retained only in memory so a failed file can be retried without asking
    /// the user to locate it again. It is never written to the activity log.
    var sourcePath: String? = nil
    /// The exact remote parent created/resolved for this file. This preserves a
    /// nested folder upload when only one deep file needs another attempt.
    var remoteParentID: String? = nil
    var failureDiagnostic: AppErrorDiagnostic? = nil

    var fraction: Double? {
        guard totalBytes > 0 else { return nil }
        switch state {
        case .hashing:
            return min(Double(hashedBytes) / Double(totalBytes), 1)
        default:
            return min(Double(uploadedBytes) / Double(totalBytes), 1)
        }
    }
}

private struct UploadQueueEntry: Decodable {
    let uploadId: String
    let name: String
    let totalBytes: UInt64
    let sourcePath: String?
}

private struct UploadProgressEvent: Decodable {
    let event: String
    let totalFiles: Int?
    let totalBytes: UInt64?
    let totalFolders: Int?
    let createdFolders: Int?
    let fileWorkers: Int?
    let multipartWorkers: Int?
    let skippedEntries: Int?
    let uploadId: String?
    let name: String?
    let hashedBytes: UInt64?
    let uploadedBytes: UInt64?
    let instant: Bool?
    let error: String?
    let sourcePath: String?
    let parentId: String?
    let folderId: String?
    let fileId: String?
    let attempt: Int?
    let maxAttempts: Int?
    let retryInMillis: UInt64?
    let files: [UploadQueueEntry]?
}

struct BrowserLocation: Hashable, Identifiable, Codable {
    let id: String
    let name: String
    let path: String

    static let root = BrowserLocation(id: "", name: "PikPak", path: "/")
    static let sharedRoot = BrowserLocation(id: "", name: "Shared Link", path: "/")
}

/// One visible row in the Finder-style cloud outline. Children remain cached
/// in the model and are flattened only for rendering and keyboard navigation.
struct BrowserTreeEntry: Hashable, Identifiable {
    let item: BrowserItem
    let depth: Int

    var id: String { item.id }
}

struct BrowserScrollRestoreRequest: Equatable, Identifiable {
    let id = UUID()
    let itemID: String
    let focusesBrowser: Bool

    init(itemID: String, focusesBrowser: Bool = false) {
        self.itemID = itemID
        self.focusesBrowser = focusesBrowser
    }
}

private struct BrowserFolderSnapshot: Codable {
    let items: [BrowserItem]
    let nextPageToken: String?
    let anchorItemID: String
    let anchorIndex: Int
    let expandedFolderIDs: Set<String>
    let childrenByFolderID: [String: [BrowserItem]]
    let childPageTokens: [String: String]
    let itemPaths: [String: String]
    let parentIDs: [String: String]
    let loadErrors: [String: String]
}

/// Runtime presentation is shared with a saved workspace, but never encoded.
/// Restoring an unchanged tab can reuse row order, outline and item lookup.
private final class BrowserWorkspacePresentation: Sendable {
    // A persistence worker encodes only the snapshot's value fields. Runtime
    // caches are excluded from CodingKeys and accessed only on the main actor.
    @MainActor var sortRevision: UUID?
    @MainActor var entries: [BrowserTreeEntry]?
    @MainActor var entriesSortRevision: UUID?
    @MainActor var itemIndex: [String: BrowserItem]?
}

private struct BrowserWorkspaceSnapshot: Codable {
    let items: [BrowserItem]
    let stack: [BrowserLocation]
    let nextPageToken: String?
    let expandedFolderIDs: Set<String>
    let childrenByFolderID: [String: [BrowserItem]]
    let loadErrors: [String: String]
    var selectedItemID: String?
    var selectedItemIDs: Set<String>
    var selectionAnchorID: String?
    let folderSnapshots: [String: BrowserFolderSnapshot]
    let childPageTokens: [String: String]
    let itemPaths: [String: String]
    let parentIDs: [String: String]
    var presentation = BrowserWorkspacePresentation()

    private enum CodingKeys: String, CodingKey {
        case items, stack, nextPageToken, expandedFolderIDs, childrenByFolderID, loadErrors
        case selectedItemID, selectedItemIDs, selectionAnchorID, folderSnapshots, childPageTokens, itemPaths, parentIDs
    }
}

private struct SharedLinkSession: Codable {
    var access: ShareAccessInput
    var workspace: BrowserWorkspaceSnapshot?
    var savedItemIDs: Set<String>
}

/// A remote item ID is unique only inside its shared link.
private struct SharedBrowserSelectionAnchor: Equatable {
    let linkID: UUID
    let itemID: String
}

private struct SharedBrowserSelectionGroup {
    let linkID: UUID
    let items: [BrowserItem]
}

private struct PersistedSharedLinkRecord: Codable {
    let entry: SharedLinkEntry
    let session: SharedLinkSession
}

private struct PersistedSharedLinksDocument: Codable {
    let version: Int
    let activeLinkID: UUID?
    let selectedRootLinkID: UUID?
    let expandedLinkIDs: Set<UUID>
    let records: [PersistedSharedLinkRecord]
    var usesUnifiedSelection: Bool? = nil
}

private struct PendingSharedLinkURLMigration: Codable {
    let urls: [String]
    let activeIndex: Int?
}

/// Owner-only local state for the Links workspace. This deliberately lives in
/// the app's private Application Support directory rather than UserDefaults:
/// access codes and PikPak's pass-code token must never appear in preferences,
/// process arguments, logs, or Safari's data store.
private enum SharedLinksStateStore {
    static let schemaVersion = 1
    static let maximumBytes = 128 * 1_024 * 1_024
    static let maximumLinks = 256
    private static let filename = "shared-links-v1.json"

    static func load() throws -> PersistedSharedLinksDocument? {
        let url = try stateFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            (values.fileSize ?? 0) <= maximumBytes
        else {
            throw LocalCredentialStoreError.invalidStorageLocation
        }
        try protectFile(at: url)
        return try JSONDecoder().decode(
            PersistedSharedLinksDocument.self,
            from: Data(contentsOf: url)
        )
    }

    static func save(_ document: PersistedSharedLinksDocument) throws {
        let url = try stateFileURL()
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw LocalCredentialStoreError.invalidStorageLocation
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(document)
        guard data.count <= maximumBytes else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try data.write(to: url, options: .atomic)
        try protectFile(at: url)
    }

    private static func stateFileURL() throws -> URL {
        let directory = try LocalCredentialStore.applicationSupportDirectoryURL()
            .appendingPathComponent("State", isDirectory: true)
        try ensurePrivateDirectory(directory)
        return directory.appendingPathComponent(filename, isDirectory: false)
    }

    private static func ensurePrivateDirectory(_ directory: URL) throws {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            let values = try directory.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard isDirectory.boolValue, values.isSymbolicLink != true else {
                throw LocalCredentialStoreError.invalidStorageLocation
            }
        } else {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try mutableDirectory.setResourceValues(values)
    }

    private static func protectFile(at url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try mutableURL.setResourceValues(values)
    }
}

private struct BrowserTreeLoadRequest {
    let item: BrowserItem
    let append: Bool
    var expansionID: UUID? = nil
}

/// A Finder-style drop is accepted immediately even when a short foreground
/// request is still finishing. The opaque item ids remain valid across folder
/// navigation, so the actual server move can be serialized behind that request
/// without making the drag feel randomly unavailable.
private struct BrowserMoveRequest {
    let items: [BrowserItem]
    let destination: BrowserLocation
}

/// A Browser/Links click only adds roots to this pre-start queue. Once the user
/// presses Start Download, compatible selections share one concurrent pool.
/// Each root keeps a stable queue id so it can be removed before its batch is
/// handed to the recursive engine.
enum PendingDownloadRequest: Codable {
    case account(
        roots: [AccountDownloadRoot],
        destination: URL,
        jobs: Int,
        proxyURL: String
    )
    case shared(
        roots: [SharedPendingDownloadRoot],
        access: ShareAccessInput,
        destination: URL,
        jobs: Int,
        proxyURL: String
    )

    func withWorkerLimit(_ limit: Int) -> PendingDownloadRequest {
        let count = min(max(limit, 1), 64)
        switch self {
        case .account(let roots, let destination, _, let proxy):
            return .account(roots: roots, destination: destination, jobs: count, proxyURL: proxy)
        case .shared(let roots, let access, let destination, _, let proxy):
            return .shared(roots: roots, access: access, destination: destination, jobs: count, proxyURL: proxy)
        }
    }

    var itemCount: Int {
        switch self {
        case .account(let roots, _, _, _):
            return roots.count
        case .shared(let roots, _, _, _, _):
            return roots.count
        }
    }

    var pendingItems: [PendingDownloadItem] {
        switch self {
        case .account(let roots, let destination, _, _):
            return roots.map { root in
                PendingDownloadItem(
                    id: root.queueID,
                    name: root.name,
                    remotePath: root.path,
                    destinationPath: destination.path,
                    kind: root.kind,
                    isShared: false
                )
            }
        case .shared(let roots, _, let destination, _, _):
            return roots.map { root in
                PendingDownloadItem(
                    id: root.queueID,
                    name: root.item.name,
                    remotePath: root.root.path,
                    destinationPath: destination.path,
                    kind: root.item.kind,
                    isShared: true
                )
            }
        }
    }

    var deduplicationKey: String {
        switch self {
        case .account(let roots, let destination, _, _):
            return "account|\(destination.path)|\(roots.map(\.path).sorted().joined(separator: "\u{1F}"))"
        case .shared(let roots, let access, let destination, _, _):
            return "shared|\(access.url)|\(destination.path)|\(roots.map { $0.item.id }.sorted().joined(separator: "\u{1F}"))"
        }
    }

    func combining(_ other: PendingDownloadRequest) -> PendingDownloadRequest? {
        switch (self, other) {
        case let (.account(roots, destination, jobs, proxy),
                  .account(more, otherDestination, otherJobs, otherProxy)):
            guard destination == otherDestination, jobs == otherJobs, proxy == otherProxy else { return nil }
            let existingPaths = Set(roots.map(\.path))
            let fresh = more.filter { !existingPaths.contains($0.path) }
            guard !DownloadQueueBatching.destinationsOverlap(
                roots.map { $0.relativeParent + [$0.name] },
                fresh.map { $0.relativeParent + [$0.name] }
            ) else { return nil }
            // The bounded owner-only request avoids argv limits and repeated
            // path-resolution API calls for metadata already in the browser.
            let combined = roots + more
            guard combined.count <= 2000 else { return nil }
            var seen = Set<String>()
            return .account(roots: combined.filter { seen.insert($0.path).inserted },
                            destination: destination, jobs: jobs, proxyURL: proxy)
        case let (.shared(roots, access, destination, jobs, proxy),
                  .shared(more, otherAccess, otherDestination, otherJobs, otherProxy)):
            guard destination == otherDestination, jobs == otherJobs, proxy == otherProxy,
                  access.url == otherAccess.url,
                  access.passCode == otherAccess.passCode,
                  access.passCodeToken == otherAccess.passCodeToken,
                  roots.count + more.count <= 2000 else { return nil }
            let existingIDs = Set(roots.map { $0.item.id })
            guard !DownloadQueueBatching.destinationsOverlap(
                roots.map { ($0.root.relativeParent ?? []) + [$0.item.name] },
                more.filter { !existingIDs.contains($0.item.id) }
                    .map { ($0.root.relativeParent ?? []) + [$0.item.name] }
            ) else { return nil }
            var seen = Set<String>()
            return .shared(roots: (roots + more).filter { seen.insert($0.item.id).inserted },
                           access: access, destination: destination, jobs: jobs, proxyURL: proxy)
        default: return nil
        }
    }

    func removingPendingItem(id: UUID) -> PendingDownloadRequest? {
        switch self {
        case .account(let roots, let destination, let jobs, let proxyURL):
            let remaining = roots.filter { $0.queueID != id }
            guard remaining.count != roots.count else { return self }
            guard !remaining.isEmpty else { return nil }
            return .account(
                roots: remaining,
                destination: destination,
                jobs: jobs,
                proxyURL: proxyURL
            )
        case .shared(let roots, let access, let destination, let jobs, let proxyURL):
            let remaining = roots.filter { $0.queueID != id }
            guard remaining.count != roots.count else { return self }
            guard !remaining.isEmpty else { return nil }
            return .shared(
                roots: remaining,
                access: access,
                destination: destination,
                jobs: jobs,
                proxyURL: proxyURL
            )
        }
    }
}

/// Each link has one independent Save-to-PikPak helper. Additional selections
/// for that same link wait in this queue, while saves for other links and normal
/// Browser operations can continue. The captured link id ensures completion
/// updates the correct saved-state markers after the user changes context.
private struct PendingSharedSaveRequest {
    let request: ShareSaveInput
    let linkID: UUID
    let description: String

    var deduplicationKey: String {
        "\(linkID.uuidString)|\(request.fileIds.sorted().joined(separator: "\u{1F}"))"
    }
}

/// A small synchronized accumulator used by Process pipe callbacks. Keeping
/// structured JSON here means signed preview links never enter the UI log.
private final class ProcessOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ newData: Data) {
        guard !newData.isEmpty else { return }
        lock.lock()
        data.append(newData)
        lock.unlock()
    }

    func string() -> String {
        lock.lock()
        let snapshot = data
        lock.unlock()
        return String(data: snapshot, encoding: .utf8) ?? ""
    }
}

/// Converts arbitrary pipe chunks into complete UTF-8 lines. Progress JSON can
/// be split across reads, so decoding each FileHandle callback independently
/// would occasionally lose an update.
private final class ProcessLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()

    func append(_ data: Data) -> [String] {
        guard !data.isEmpty else { return [] }
        lock.lock()
        pending.append(data)
        let lines = extractCompleteLines()
        lock.unlock()
        return lines
    }

    func drain() -> [String] {
        lock.lock()
        let lines = extractCompleteLines()
        var result = lines
        if !pending.isEmpty {
            result.append(String(decoding: pending, as: UTF8.self))
            pending.removeAll(keepingCapacity: false)
        }
        lock.unlock()
        return result
    }

    private func extractCompleteLines() -> [String] {
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let lineData = pending[pending.startIndex..<newline]
            lines.append(String(decoding: lineData, as: UTF8.self))
            pending.removeSubrange(pending.startIndex...newline)
        }
        return lines
    }
}

private struct CloudDownloadPromisePayload {
    let promisedName: String
    let remotePaths: [String]
    let wrapsSelectionInFolder: Bool
    let engineURL: URL
    let environment: [String: String]
    let jobs: Int
    let onStart: () -> Void
    let onFinish: (Result<Void, Error>) -> Void
}

/// Finder asks an NSItemProvider for its file representation only after the
/// user drops it. The coordinator materializes the selected cloud data in a
/// private temporary directory, then Finder copies that file or folder to the
/// exact drop location. This avoids exposing incomplete placeholder files.
private final class CloudDownloadPromiseCoordinator {
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.wky.PikPakDownloader.file-promises"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    func makeProvider(
        fileType: String,
        payload: CloudDownloadPromisePayload
    ) -> NSItemProvider {
        let provider = NSItemProvider()
        provider.suggestedName = payload.promisedName
        provider.registerFileRepresentation(
            forTypeIdentifier: fileType,
            fileOptions: [],
            visibility: .all
        ) { [weak self] completion in
            guard let self else {
                completion(
                    nil,
                    false,
                    NSError(
                        domain: "PikPakFilePromise",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "The PikPak drag session expired."]
                    )
                )
                return nil
            }

            let progress = Progress(totalUnitCount: -1)
            self.queue.addOperation {
                self.materialize(payload: payload, progress: progress, completion: completion)
            }
            return progress
        }
        return provider
    }

    private func materialize(
        payload: CloudDownloadPromisePayload,
        progress: Progress,
        completion: @escaping (URL?, Bool, Error?) -> Void
    ) {
        payload.onStart()
        let temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("PikPakDownloader-Drag-\(UUID().uuidString)", isDirectory: true)
        let outputDirectory = payload.wrapsSelectionInFolder
            ? temporaryRoot.appendingPathComponent(payload.promisedName, isDirectory: true)
            : temporaryRoot

        do {
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: true
            )

            let process = Process()
            let stderr = Pipe()
            let stderrBuffer = ProcessOutputBuffer()
            process.executableURL = payload.engineURL
            var arguments = ["download"]
            for path in payload.remotePaths {
                arguments.append(contentsOf: ["--path", path])
            }
            arguments.append(contentsOf: [
                "--output", outputDirectory.path,
                "--jobs", String(payload.jobs),
            ])
            process.arguments = arguments
            process.environment = payload.environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = stderr
            progress.cancellationHandler = {
                if process.isRunning {
                    process.terminate()
                }
            }
            stderr.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if !data.isEmpty {
                    stderrBuffer.append(data)
                }
            }

            try process.run()
            process.waitUntilExit()
            stderr.fileHandleForReading.readabilityHandler = nil
            let trailing = stderr.fileHandleForReading.readDataToEndOfFile()
            if !trailing.isEmpty {
                stderrBuffer.append(trailing)
            }

            guard process.terminationStatus == 0 else {
                let detail = stderrBuffer.string()
                    .split(whereSeparator: \.isNewline)
                    .last
                    .map(String.init)
                    ?? "The PikPak download engine stopped."
                throw NSError(
                    domain: "PikPakFilePromise",
                    code: Int(process.terminationStatus),
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "PikPak could not complete the Finder download (exit \(process.terminationStatus)): \(detail)"
                    ]
                )
            }

            let resultURL: URL
            if payload.wrapsSelectionInFolder {
                resultURL = outputDirectory
            } else {
                let preferred = temporaryRoot.appendingPathComponent(payload.promisedName)
                if FileManager.default.fileExists(atPath: preferred.path) {
                    resultURL = preferred
                } else {
                    let children = try FileManager.default.contentsOfDirectory(
                        at: temporaryRoot,
                        includingPropertiesForKeys: nil,
                        options: []
                    )
                    guard let downloaded = children.first else {
                        throw NSError(
                            domain: "PikPakFilePromise",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "The downloader returned no local item."]
                        )
                    }
                    resultURL = downloaded
                }
            }

            payload.onFinish(.success(()))
            completion(resultURL, false, nil)
            Self.scheduleCleanup(of: temporaryRoot)
        } catch {
            payload.onFinish(.failure(error))
            completion(nil, false, error)
            try? FileManager.default.removeItem(at: temporaryRoot)
        }
    }

    private static func scheduleCleanup(of directory: URL) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3_600) {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}

/// Fetches only the beginning of a text file. Object storage normally honors
/// the Range request, but the delegate also stops locally at the byte ceiling
/// if a server ignores it, so a multi-gigabyte log cannot exhaust app memory.
private final class BoundedTextPreviewLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Output: Sendable {
        let data: Data
        let wasTruncated: Bool
        let responseEncodingName: String?
    }

    private let request: URLRequest
    private let configuration: URLSessionConfiguration
    private let maximumBytes: Int
    private let expectedFileSize: UInt64
    private let completion: @Sendable (Result<Output, Error>) -> Void
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private var responseEncodingName: String?
    private var responseTotalBytes: UInt64?
    private var terminalError: Error?
    private var stoppedAtLimit = false
    private var didFinish = false

    init(
        request: URLRequest,
        configuration: URLSessionConfiguration,
        maximumBytes: Int,
        expectedFileSize: UInt64,
        completion: @escaping @Sendable (Result<Output, Error>) -> Void
    ) {
        self.request = request
        self.configuration = configuration
        self.maximumBytes = max(maximumBytes, 1)
        self.expectedFileSize = expectedFileSize
        self.completion = completion
        buffer.reserveCapacity(min(maximumBytes, 2 * 1_024 * 1_024))
        super.init()
    }

    func start() {
        let queue = OperationQueue()
        queue.name = "com.wky.MyPikPak.text-preview"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: queue
        )
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
        session?.invalidateAndCancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        if let http = response as? HTTPURLResponse,
           !(200 ..< 300).contains(http.statusCode) {
            terminalError = NSError(
                domain: "PikPakTextPreview",
                code: http.statusCode,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "PikPak's file server returned HTTP \(http.statusCode).",
                ]
            )
            completionHandler(.cancel)
            return
        }
        responseEncodingName = response.textEncodingName
        if let contentRange = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Range"),
           let total = Self.totalBytes(fromContentRange: contentRange) {
            responseTotalBytes = total
        } else if response.expectedContentLength > 0 {
            responseTotalBytes = UInt64(response.expectedContentLength)
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let remaining = max(maximumBytes - buffer.count, 0)
        if remaining > 0 {
            buffer.append(contentsOf: data.prefix(remaining))
        }

        let knownTotal = max(expectedFileSize, responseTotalBytes ?? 0)
        let receivedPastLimit = data.count > remaining
        if buffer.count >= maximumBytes,
           receivedPastLimit || knownTotal > UInt64(buffer.count) || knownTotal == 0 {
            stoppedAtLimit = true
            dataTask.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let result: Result<Output, Error>
        if let terminalError {
            result = .failure(terminalError)
        } else if let error,
                  !(stoppedAtLimit
                    && (error as NSError).domain == NSURLErrorDomain
                    && (error as NSError).code == NSURLErrorCancelled) {
            result = .failure(error)
        } else {
            let knownTotal = max(expectedFileSize, responseTotalBytes ?? 0)
            result = .success(
                Output(
                    data: buffer,
                    wasTruncated: stoppedAtLimit || knownTotal > UInt64(buffer.count),
                    responseEncodingName: responseEncodingName
                )
            )
        }
        finish(result)
    }

    private func finish(_ result: Result<Output, Error>) {
        guard !didFinish else { return }
        didFinish = true
        task = nil
        session?.finishTasksAndInvalidate()
        session = nil
        completion(result)
    }

    private static func totalBytes(fromContentRange value: String) -> UInt64? {
        guard let slash = value.lastIndex(of: "/") else { return nil }
        let total = value[value.index(after: slash)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard total != "*" else { return nil }
        return UInt64(total)
    }
}

@MainActor
final class DownloaderModel: ObservableObject {
    @Published private(set) var accountProfile: PikPakAccountProfile?
    var accountDisplayName: String? { accountProfile?.displayName ?? activeSavedAccount?.profile?.displayName }
    @Published private(set) var savedAccounts: [SavedPikPakAccount] = []
    @Published private(set) var activeAccountID: UUID?
    @Published private(set) var accountLoginStatus: PikPakLoginStatus = .signedOut
    @Published private(set) var accountSettingsError: String?
    @Published private(set) var isChangingAccount = false
    @Published private(set) var isCheckingAccount = false
    @Published private(set) var loginFromSettings = false
    private var accountStore: PikPakAccountStore?
    private let accountVerifier = PikPakAccountVerifier()
    private var accountCheckTask: Task<Void, Never>?
    private var accountCheckGeneration = UUID()
    private var accountLoginDeviceID: String?
    private var accountLoginTargetID: UUID?
    #if FINDER_WORKSPACE_TESTS
    private var accountProfileLoader: ((PikPakAccountSessionFiles) async throws -> PikPakAccountProfile)?
    private var accountFixtureTransferDirectory: URL?
    #endif
    private var fileOpenContext = UUID()
    lazy var fileOpener: FinderFileOpener = {
        let opener = FinderFileOpener()
        opener.onStatus = { [weak self] message, isError in
            if isError { self?.setError(message) }
            else { self?.setStatus(message) }
        }
        return opener
    }()
    private(set) var finderSettings = FinderSettings()
    let fileSearch = FileSearchModel()
    lazy var fileSimilarity: FileSimilarityCoordinator = {
        let coordinator = FileSimilarityCoordinator(activity: taskActivity)
        coordinator.cloud.onRunningChanged = { [weak self] in self?.objectWillChange.send() }
        coordinator.configuration = { [weak self] source in
            guard let self else { throw CocoaError(.userCancelled) }
            return try self.similarityConfiguration(source)
        }
        coordinator.cloudScope = { [weak self] selection in
            guard let self else { throw CocoaError(.userCancelled) }
            return try self.similarityCloudScope(selection: selection)
        }
        coordinator.openCloudFile = { [weak self] file in self?.openSimilarityCloudFile(file) }
        return coordinator
    }()
    let imagePreview = ImagePreviewModel()
    var imagePreviewRequestGeneration: UUID { previewLoadGeneration }
    private var pendingFileSearchNavigation: FileSearchNavigation?
    #if FINDER_WORKSPACE_TESTS
    private var isFinderWorkspaceFixture = false
    private var finderFixtureFolders: [String: [BrowserItem]] = [:]
    private var quickLookFixtureURL: URL?
    private var quickLookFixtureURLs: [String: URL] = [:]
    private var quickLookFixtureDelay: UInt64 = 0
    private var quickLookFixtureTask: Task<Void, Never>?
    private var fileUndoFixtureItems: [String: BrowserItem] = [:]
    private var fileUndoFixtureTrashed: Set<String> = []
    private var sharedSaveFixtureRequests: [PendingSharedSaveRequest] = []
    private var sharedLinkLoadFixture: ((UUID, ShareBrowseInput, Process) -> Void)?
    private init(finderFixture: Bool, defaults: UserDefaults) {
        outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("Offline Downloads")
        isFinderWorkspaceFixture = finderFixture
        finderSettings = FinderSettings(defaults: defaults)
        refreshToken = "offline-fixture-session"
        attemptedInitialBrowse = true
    }
    #endif
    #if FOLDER_EXPANSION_TESTS
    private var isFolderExpansionFixture = false
    private var recordedExpansionLoads: [(id: String, append: Bool, token: String?, generation: UUID)] = []

    private init(folderExpansionFixture: Bool) {
        outputURL = FileManager.default.temporaryDirectory
        isFolderExpansionFixture = folderExpansionFixture
        refreshToken = "offline-expansion-fixture"
    }
    #endif
    #if BROWSER_DROP_TESTS
    private var isBrowserDropFixture = false
    private var recordedDropMoves: [([BrowserItem], BrowserLocation)] = []
    private var recordedDropUploads: [([URL], BrowserLocation)] = []

    private init(browserDropFixture: Bool) {
        outputURL = FileManager.default.temporaryDirectory
        isBrowserDropFixture = browserDropFixture
        refreshToken = "offline-fixture-token"
        transferAccountID = "offline-drop-fixture"
        transferStateReady = true
    }
    #endif
    #if FILE_SEARCH_TESTS
    private var isFileSearchFixture = false

    private init(fileSearchFixture: Bool) {
        outputURL = FileManager.default.temporaryDirectory
        isFileSearchFixture = fileSearchFixture
    }
    #endif
    var effectiveDownloadConcurrentJobs: Int { finderSettings.transferWorkers }
    var effectiveUploadConcurrentJobs: Int { finderSettings.transferWorkers }

    /// Describe work from the owning task's state, never command lines, tokens
    /// or signed URLs. Polling also notices helpers owned by nested models.
    var resourceActivities: [Int32: TaskResourceActivity] {
        var activities: [Int32: TaskResourceActivity] = [:]
        func record(_ child: Process?, _ activity: @autoclosure () -> TaskResourceActivity) {
            if let child, child.isRunning { activities[child.processIdentifier] = activity() }
        }
        record(process, resourceActivity(for: operation))
        record(downloadProcess, .init(name: downloadRunState == .scanning ? "Scanning files for download" : "Downloading files",
            detail: "\(resourceDownloadSource)\n\(downloadRunState.title) · \(downloadCompletedFiles.formatted()) of \(downloadTotalFiles.formatted()) files complete",
            symbol: "arrow.down.circle"))
        record(uploadProcess, .init(name: "Uploading files",
            detail: "\(uploadDestination?.path ?? "My PikPak")\n\(uploadRunState.title) · \(uploadCompletedFiles.formatted()) of \(uploadTotalFiles.formatted()) files complete",
            symbol: "arrow.up.circle"))
        record(duplicateProcess, .init(name: duplicateScanWasCancelled ? "Stopping duplicate scan" : "Scanning duplicate files",
            detail: "\(duplicateCurrentPath.isEmpty ? duplicateScanRootPath : duplicateCurrentPath)\n\(duplicateScannedFiles.formatted()) files · \(duplicateScannedFolders.formatted()) folders checked",
            symbol: "doc.on.doc"))
        record(maintenanceProcess, resourceActivity(for: maintenanceOperation))
        record(mergeProcess, .init(name: "Merging folders",
            detail: "\(mergeDestination?.name ?? "My PikPak")\n\(mergeMovedItems.formatted()) items moved · \(mergeCompletedSourceCount.formatted()) folders merged",
            symbol: "folder"))
        record(folderMeasurementProcess, resourceActivity(for: folderMeasurementOperation))
        for (id, child) in archiveProcesses {
            let task = archiveTasks.first { $0.id == id }
            record(child, .init(name: task?.isInspecting == true ? "Reading cloud archive" : "Extracting in PikPak",
                detail: [task?.item.name, task?.statusText].compactMap { $0 }.joined(separator: "\n"), symbol: "archivebox"))
        }
        for (id, child) in sharedSaveProcesses {
            record(child, .init(name: "Saving to My PikPak", detail: resourceLinkName(id), symbol: "icloud.and.arrow.down"))
        }
        for (id, child) in sharedLinkLoadProcesses {
            record(child, .init(name: "Loading shared link", detail: resourceLinkName(id), symbol: "link"))
        }
        for (id, child) in browserTreeLoadProcesses {
            record(child, .init(name: "Loading folder", detail: browserItemPaths[id] ?? "My PikPak", symbol: "folder"))
        }
        if let pid = fileSearch.resourceProcessIdentifier {
            activities[pid] = .init(name: "Indexing files for search",
                detail: "\(fileSearch.contextName)\n\(fileSearch.indexedItems.formatted()) items · \(fileSearch.progress.scannedFolders.formatted()) folders indexed",
                symbol: "magnifyingglass")
        }
        for scan in fileSimilarity.runs {
            if let pid = scan.processIdentifier {
                activities[pid] = .init(name: "Finding similar files · \(scan.source.title)",
                    detail: "\(scan.scopeLabel)\n\(scan.message)\n\(scan.detail)", symbol: "doc.text.magnifyingglass")
            }
        }
        var inApp: [String] = []
        if let pid = accountVerifier.processIdentifier {
            activities[pid] = .init(name: "Checking account", detail: "PikPak login status and profile", symbol: "person.crop.circle")
        }
        if previewPlayer != nil || isPreviewLoading || quickLookDownloadTask != nil || textPreviewLoader != nil {
            inApp.append("Preview: \(previewInfo?.name ?? "loading file")")
        }
        let openProcesses = fileOpener.resourceProcessNames
        for (pid, name) in openProcesses {
            activities[pid] = .init(name: "Preparing file to open", detail: name, symbol: "doc")
        }
        let openingNames = fileOpener.activeNames.values.sorted()
        if !openingNames.isEmpty { inApp.append("Opening: " + openingNames.joined(separator: ", ")) }
        if fileSearch.isScanning || fileSearch.isResolving { inApp.append("Updating search results") }
        activities[getpid()] = .init(name: "My PikPak for Mac",
            detail: (["Interface & shared app work"] + inApp).joined(separator: "\n"), symbol: "macwindow")
        return activities
    }

    private var resourceDownloadSource: String {
        guard let request = activePersistentDownload else { return "Current download batch" }
        let names: [String]
        switch request {
        case .account(let roots, _, _, _): names = roots.prefix(2).map(\.name)
        case .shared(let roots, _, _, _, _): names = roots.prefix(2).map { $0.item.name }
        }
        return names.joined(separator: ", ") + (request.itemCount > 2 ? " and \(request.itemCount - 2) more" : "")
    }

    private func resourceLinkName(_ id: UUID) -> String {
        sharedLinks.first { $0.id == id }?.name ?? "Shared link"
    }

    private func resourceFolderPath(_ id: String, linkID: UUID? = nil) -> String {
        if let linkID {
            let paths = linkID == activeSharedLinkID && isBrowsingSharedLink
                ? browserItemPaths : sharedLinkSessions[linkID]?.workspace?.itemPaths
            return paths?[id] ?? resourceLinkName(linkID)
        }
        let paths = isBrowsingSharedLink ? accountBrowserWorkspace?.itemPaths : browserItemPaths
        return paths?[id] ?? "My PikPak"
    }

    private func resourceActivity(for operation: Operation?) -> TaskResourceActivity {
        guard let operation else { return .init(name: "PikPak request") }
        switch operation {
        case .quota:
            return .init(name: "Refreshing account", detail: "Profile and storage usage", symbol: "person.crop.circle")
        case .browse(let stack, _, _, _), .shareBrowse(_, let stack, _, _):
            return .init(name: "Loading folder", detail: stack.last?.path ?? "My PikPak", symbol: "folder")
        case .browseTree(_, _, let path, _), .shareBrowseTree(_, _, _, let path, _):
            return .init(name: "Loading folder", detail: path, symbol: "folder")
        case .preview(let id), .sharePreview(_, let id):
            return .init(name: "Preparing preview", detail: browserItem(withID: id)?.name ?? "File preview", symbol: "eye")
        case .archiveInspect(_, let item):
            return .init(name: "Reading cloud archive", detail: item.name, symbol: "archivebox")
        case .archiveExtract(let item):
            return .init(name: "Extracting in PikPak", detail: item.name, symbol: "archivebox")
        case .measure(let id):
            return .init(name: "Calculating folder size", detail: resourceFolderPath(id), symbol: "folder")
        case .shareMeasure(_, let id, let linkID):
            return .init(name: "Calculating folder size", detail: resourceFolderPath(id, linkID: linkID), symbol: "folder")
        case .duplicates(let scope):
            return .init(name: "Scanning duplicate files", detail: scope.path, symbol: "doc.on.doc")
        case .emptyFolders(let scope):
            return .init(name: "Cleaning up empty folders",
                detail: "\(emptyFolderCurrentPath.isEmpty ? scope.path : emptyFolderCurrentPath)\n\(emptyFolderScannedFolders.formatted()) folders checked · \(emptyFolderRemovedFolders.formatted()) removed",
                symbol: "folder")
        case .dsStoreFiles(let scope):
            return .init(name: "Cleaning up .DS_Store files", detail: scope.path, symbol: "trash")
        case .mergeFolders(_, let destination):
            return .init(name: "Merging folders", detail: destination.name, symbol: "folder")
        case .shareSave(_, let count, let linkID):
            return .init(name: "Saving to My PikPak", detail: "\(resourceLinkName(linkID)) · \(count.formatted()) items", symbol: "icloud.and.arrow.down")
        case .undoFiles(_, let title):
            return .init(name: title, detail: "Reversing confirmed cloud changes", symbol: "arrow.uturn.backward")
        case .trash(_, let name):
            return .init(name: "Moving to Trash", detail: name, symbol: "trash")
        case .trashBrowserItems(let ids), .trashDuplicates(let ids):
            return .init(name: "Moving to Trash", detail: "\(ids.count.formatted()) items", symbol: "trash")
        case .moveBrowserItems(let items, let destination):
            return .init(name: "Moving files and folders", detail: "\(items.count.formatted()) items → \(destination.path)", symbol: "folder")
        case .renameItem(let item, _):
            return .init(name: "Renaming item", detail: item.name, symbol: "pencil")
        case .createFolder(let parent, let name):
            return .init(name: "Creating folder", detail: "\(parent.path) · \(name)", symbol: "folder.badge.plus")
        case .download, .shareDownload:
            return .init(name: "Downloading files", symbol: "arrow.down.circle")
        case .upload(let destination, _):
            return .init(name: "Uploading files", detail: destination.path, symbol: "arrow.up.circle")
        }
    }

    /// Large instant-upload batches can finish thousands of files in seconds.
    /// Keep the authoritative counters for the complete run, but expose only a
    /// small moving window to SwiftUI so List diffing never grows with the job.
    private static let maximumVisibleUploadQueueRows = 160
    private static let maximumVisibleUploadHistoryRows = 160
    private static let uploadOutputBatchSize = 192
    private static let uploadOutputBatchDelay: TimeInterval = 0.04
    /// Download progress can be just as chatty as upload progress for a large
    /// folder. Coalescing it prevents thousands of main-actor publications
    /// from starving Finder-style navigation and selection.
    private static let downloadOutputBatchSize = 192
    private static let downloadOutputBatchDelay: TimeInterval = 0.04
    private static let scanProgressBatchSize = 128
    private static let scanProgressBatchDelay: TimeInterval = 0.06

    private static let previewUserAgent = PreviewTransport.userAgent
    private static let previewStartupTimeoutNanoseconds: UInt64 = 25_000_000_000
    /// Ask AVFoundation to read substantially ahead instead of stopping after
    /// the old four-second window. Once the item duration is known this is
    /// replaced with the complete media duration.
    private static let previewFallbackForwardBufferDuration: TimeInterval = 6 * 60 * 60
    private static let previewMetricsIntervalNanoseconds: UInt64 = 500_000_000
    /// A bitrate from AVPlayer's access log describes a completed historical
    /// transfer and remains populated after the network goes idle. Derive the
    /// displayed rate from byte deltas instead, and expire the last sample soon
    /// after bytes stop arriving.
    private static let previewTransferRateIdleTimeout: TimeInterval = 1.5
    private static let compatibilityPlayerBundleID = "com.colliderli.iina"
    private static let compatibilityPreviewFilenamePrefix = "PikPakDownloader-Preview-"

    private enum Operation {
        case quota(announcesResult: Bool)
        case download
        case shareDownload(request: ShareDownloadInput)
        case upload(destination: BrowserLocation, files: [URL])
        case browse(
            stack: [BrowserLocation],
            append: Bool,
            includesQuota: Bool,
            preservesOutline: Bool
        )
        case browseTree(
            folderID: String,
            folderName: String,
            folderPath: String,
            append: Bool
        )
        case shareBrowse(
            request: ShareBrowseInput,
            stack: [BrowserLocation],
            append: Bool,
            initial: Bool
        )
        case shareBrowseTree(
            request: ShareBrowseInput,
            folderID: String,
            folderName: String,
            folderPath: String,
            append: Bool
        )
        case preview(fileID: String)
        case sharePreview(request: SharePreviewInput, fileID: String)
        case archiveInspect(request: ArchiveInspectInput, item: BrowserItem)
        case archiveExtract(item: BrowserItem)
        case measure(folderID: String)
        case shareMeasure(request: ShareMeasureInput, folderID: String, linkID: UUID)
        case shareSave(request: ShareSaveInput, itemCount: Int, linkID: UUID)
        case duplicates(scope: BrowserLocation)
        case trash(itemID: String, itemName: String)
        case undoFiles(request: FinderUndoRequest, title: String)
        case trashBrowserItems(ids: [String])
        case moveBrowserItems(items: [BrowserItem], destination: BrowserLocation)
        case renameItem(item: BrowserItem, name: String)
        case mergeFolders(folders: [BrowserItem], destination: BrowserItem)
        case createFolder(parent: BrowserLocation, name: String)
        case trashDuplicates(ids: [String])
        case emptyFolders(scope: BrowserLocation)
        case dsStoreFiles(scope: BrowserLocation)

        var hasStructuredOutput: Bool {
            switch self {
            case .browse, .browseTree, .shareBrowse, .shareBrowseTree,
                 .preview, .sharePreview, .archiveInspect, .archiveExtract,
                 .measure, .shareMeasure, .duplicates, .trash,
                 .shareSave, .trashBrowserItems, .moveBrowserItems, .renameItem,
                 .mergeFolders,
                 .trashDuplicates,
                 .createFolder, .emptyFolders, .dsStoreFiles, .quota, .undoFiles:
                return true
            case .download, .shareDownload, .upload:
                return false
            }
        }

    }

    /// Folder-size requests are serialized through one utility process to keep
    /// recursive scans service-conscious, but every request retains its own
    /// account/link namespace. This lets another link be queued without making
    /// every Calculate control look busy or sharing an empty root id.
    private struct PendingFolderMeasurementRequest {
        let arguments: [String]
        let operation: Operation
        let folderID: String
        let cacheKey: String
    }

    @Published private(set) var refreshToken: String = ""
    @Published var outputURL: URL
    // Compatibility accessors share the one Settings value; separate upload
    // and download controls can no longer silently diverge.
    var concurrentJobs: Int {
        get { finderSettings.transferWorkers }
        set { finderSettings.setTransferWorkers(newValue) }
    }
    var uploadConcurrentJobs: Int {
        get { finderSettings.transferWorkers }
        set { finderSettings.setTransferWorkers(newValue) }
    }
    @Published var proxyURL: String = "" {
        didSet {
            UserDefaults.standard.set(proxyURL, forKey: "proxyURL")
        }
    }
    @Published var status: String = "Ready"
    @Published var statusIsError = false
    @Published private(set) var statusErrorDiagnostic: AppErrorDiagnostic?
    @Published var isRunning = false
    @Published var isBrowserLoading = false
    @Published private(set) var isPreviewLoading = false
    @Published var isDownloading = false
    @Published private(set) var downloadRunState: DownloadRunState = .ready
    @Published private(set) var downloadTotalFiles = 0
    @Published private(set) var downloadTotalBytes: UInt64 = 0
    @Published private(set) var downloadDownloadedBytes: UInt64 = 0
    @Published private(set) var downloadCompletedFiles = 0
    @Published private(set) var downloadSkippedFiles = 0
    @Published private(set) var downloadFailedFiles = 0
    @Published private(set) var downloadBytesPerSecond: Double = 0
    @Published private(set) var downloadQueueTransfers: [DownloadTransfer] = []
    @Published private(set) var downloadQueueOffset = 0
    @Published private(set) var downloadingTransfers: [DownloadTransfer] = []
    @Published private(set) var completedDownloadTransfers: [DownloadTransfer] = []
    /// A separate failure history survives progress resets and transcript
    /// replay, so retrying one row does not make the other failures disappear.
    @Published private(set) var failedDownloadTransfers: [DownloadTransfer] = []
    @Published private(set) var pendingDownloadItems: [PendingDownloadItem] = []
    @Published private(set) var pendingDownloadBatchCount = 0
    @Published private(set) var restoredDownloadQueue = false
    @Published private(set) var savedUploadBatches: [SavedUploadBatch] = []
    @Published private(set) var interruptedDownloadCount = 0
    @Published var isUploading = false
    @Published private(set) var isUploadPaused = false
    @Published private(set) var uploadRunState: UploadRunState = .ready
    @Published private(set) var uploadDestination: BrowserLocation?
    @Published private(set) var uploadTotalFiles = 0
    @Published private(set) var uploadTotalBytes: UInt64 = 0
    @Published private(set) var uploadUploadedBytes: UInt64 = 0
    @Published private(set) var uploadCompletedFiles = 0
    @Published private(set) var uploadInstantFiles = 0
    @Published private(set) var uploadFailedFiles = 0
    @Published private(set) var uploadTotalFolders = 0
    @Published private(set) var uploadCreatedFolders = 0
    @Published private(set) var uploadFileWorkers = 0
    @Published private(set) var uploadMultipartWorkers = 0
    @Published private(set) var uploadSkippedEntries = 0
    @Published private(set) var uploadBytesPerSecond: Double = 0
    @Published private(set) var uploadHashBytesPerSecond: Double = 0
    @Published private(set) var uploadQueueTransfers: [UploadTransfer] = []
    @Published private(set) var uploadQueueOffset = 0
    @Published private(set) var uploadingTransfers: [UploadTransfer] = []
    @Published private(set) var completedUploadTransfers: [UploadTransfer] = []
    @Published private(set) var failedUploadTransfers: [UploadTransfer] = []
    @Published var log = ""
    @Published var isLoginPresented = false
    @Published private(set) var loginReason = "Sign in to connect this app to your PikPak account."
    @Published private(set) var requiresDedicatedSignIn = false
    @Published private(set) var storageQuota: StorageQuota?
    @Published private(set) var isQuotaLoading = false
    @Published private(set) var storageQuotaError: String?

    @Published var shareURLInput: String = ""
    @Published var sharePasscodeInput: String = ""
    @Published private(set) var browserSource: BrowserSource = .account
    @Published private(set) var shareLinkIsOpen = false
    @Published private(set) var shareLinkFeedbackMessage: String?
    @Published private(set) var shareLinkFeedbackTone: ShareLinkFeedbackTone = .info
    @Published private(set) var isOpeningShareLink = false
    @Published private(set) var isSavingSharedItems = false
    /// Save helpers are isolated by shared-link root. Publishing the item ids
    /// keeps only the affected selection in a Saving state while other links
    /// remain selectable and disconnectable.
    @Published private var savingSharedItemIDsByLinkID: [UUID: Set<String>] = [:]
    @Published private(set) var sharedLinks: [SharedLinkEntry] = []
    @Published private(set) var sharedLinkRetryProgress: SharedLinkRetryProgress?
    @Published private(set) var activeSharedLinkID: UUID?
    @Published private(set) var selectedSharedLinkRootID: UUID?
    private var sharedBrowserSelectionAnchor: SharedBrowserSelectionAnchor?
    @Published private(set) var expandedSharedLinkIDs = Set<UUID>()

    @Published private(set) var browserItems: [BrowserItem] = [] {
        didSet { invalidateBrowserPresentation(itemsChanged: true) }
    }
    @Published private(set) var browserSortColumn: BrowserSortColumn = .name {
        didSet { browserSortRevision = UUID() }
    }
    @Published private(set) var browserSortDirection: BrowserSortDirection = .ascending {
        didSet { browserSortRevision = UUID() }
    }
    @Published private(set) var browserStack: [BrowserLocation] = [.root]
    @Published private(set) var nextPageToken: String?
    @Published private(set) var browserScrollRestoreRequest: BrowserScrollRestoreRequest?
    @Published private(set) var expandedBrowserFolderIDs = Set<String>() {
        didSet { invalidateBrowserPresentation(itemsChanged: false) }
    }
    @Published private(set) var browserTreeChildren: [String: [BrowserItem]] = [:] {
        didSet { invalidateBrowserPresentation(itemsChanged: true) }
    }
    @Published private(set) var browserTreeLoadingFolderIDs = Set<String>()
    @Published private(set) var browserFolderExpansionProgress: BrowserFolderExpansionProgress?
    @Published private(set) var browserTreeLoadErrors: [String: String] = [:]
    @Published private(set) var selectedBrowserItemID: String?
    @Published private(set) var selectedBrowserItemIDs = Set<String>()
    @Published private(set) var previewInfo: PreviewInfo?
    @Published private(set) var previewPlayer: AVPlayer?
    @Published private(set) var previewFileID: String?
    @Published private(set) var previewPlaybackError: String?
    @Published private(set) var previewErrorDiagnostic: AppErrorDiagnostic?
    @Published private(set) var previewSourceLabel: String?
    @Published private(set) var previewText: String?
    @Published private(set) var previewTextEncodingName: String?
    @Published private(set) var previewTextLoadedBytes: UInt64 = 0
    @Published private(set) var previewTextWasTruncated = false
    @Published private(set) var previewRequiresCompatibilityPlayer = false
    @Published private(set) var previewCompatibilityPlayerName: String?
    @Published private(set) var isPreparingQuickLook = false
    @Published private(set) var fileUndoHistory = FinderFileUndoHistory()
    private var uploadUndoMutations: [FinderFileMutation] = []
    private var undoMoveOrigins: [String: String] = [:]
    private var fileUndoRefreshFeedback: (message: String, isError: Bool, diagnostic: AppErrorDiagnostic?)?
    @Published private(set) var previewStreamingState: PreviewStreamingState = .idle
    @Published private(set) var previewPlaybackSeconds: Double = 0
    @Published private(set) var previewDurationSeconds: Double = 0
    @Published private(set) var previewBufferedSeconds: Double = 0
    @Published private(set) var previewStreamedBytes: UInt64 = 0
    @Published private(set) var previewTransferBytesPerSecond: Double = 0
    @Published private(set) var previewRetainedBytes: UInt64 = 0
    @Published private(set) var previewRetainedTotalBytes: UInt64 = 0
    @Published private(set) var previewUsesRetainedCache = false
    @Published private(set) var previewRetainedSegments: [PreviewBufferSegment] = []
    let extractionActivity = CloudExtractionActivity()
    /// Progress redraws only the extraction controls, not a large Browser list.
    private(set) var archiveTasks: [CloudExtractionTask] {
        get { extractionActivity.tasks }
        set {
            if archiveTasks.count != newValue.count || hasActiveArchiveTasks != newValue.contains(where: \.isBusy) {
                objectWillChange.send()
            }
            extractionActivity.tasks = newValue
        }
    }
    @Published private(set) var selectedArchiveTaskID: UUID?
    var selectedArchiveTask: CloudExtractionTask? { archiveTasks.first { $0.id == selectedArchiveTaskID } }
    var archiveItem: BrowserItem? { selectedArchiveTask?.item }
    var archiveInspection: ArchiveInspection? { selectedArchiveTask?.inspection }
    var archiveExtractionResult: ArchiveExtractionResult? { selectedArchiveTask?.result }
    var archiveErrorDiagnostic: AppErrorDiagnostic? { selectedArchiveTask?.error }
    var isInspectingArchive: Bool { selectedArchiveTask?.isInspecting == true }
    var isExtractingArchive: Bool { selectedArchiveTask?.isExtracting == true }
    var archiveExtractionProgress: Double { selectedArchiveTask?.progress ?? 0 }
    var archiveExtractionPhase: String { selectedArchiveTask?.phase ?? "" }
    var hasActiveArchiveTasks: Bool { archiveTasks.contains { $0.isBusy } }
    var activeArchiveTaskCount: Int { archiveTasks.filter { $0.isInspecting || $0.isExtracting }.count }
    var archiveConcurrencyLimit: Int {
        get { finderSettings.concurrentExtractions }
        set { finderSettings.setConcurrentExtractions(newValue); pumpArchiveQueue() }
    }
    var archivePassword: String {
        get { selectedArchiveTask?.password ?? "" }
        set { if let id = selectedArchiveTaskID { updateArchiveTask(id) { $0.password = newValue } } }
    }
    var selectedArchiveEntryIndices: Set<Int> {
        get { selectedArchiveTask?.selectedIndices ?? [] }
        set { if let id = selectedArchiveTaskID { updateArchiveTask(id) { $0.selectedIndices = newValue } } }
    }
    @Published private(set) var folderMeasurement: FolderMeasurement?
    @Published private(set) var measuredFolderID: String?
    @Published private(set) var isMeasuringFolder = false
    @Published private(set) var measuringFolderID: String?
    @Published private(set) var folderMeasurements: [String: FolderMeasurement] = [:] {
        didSet {
            if browserSortColumn == .size { browserSortRevision = UUID() }
        }
    }
    @Published private var queuedFolderMeasurementCacheKeys = Set<String>()
    let taskActivity = FinderTaskActivityStore()
    @Published private(set) var duplicateScan: DuplicateScan? {
        didSet {
            if duplicateScan == nil, oldValue != nil { taskActivity.dismiss(.duplicates) }
        }
    }
    @Published private(set) var isScanningDuplicates = false
    @Published private(set) var isDeletingDuplicates = false
    private(set) var duplicateScannedFiles = 0
    private(set) var duplicateScannedFolders = 0
    private(set) var duplicateDiscoveredFolders = 0
    private(set) var duplicatePendingFolders = 0
    private(set) var duplicateFailedFolders = 0
    private(set) var duplicateRetryAttempt = 0
    private(set) var duplicateRetryMaxAttempts = 0
    private(set) var duplicateRetryInMillis: UInt64 = 0
    private(set) var duplicateCurrentPath = ""
    private(set) var duplicateScanRootPath = ""
    @Published private(set) var selectedDuplicateFileIDs = Set<String>()
    @Published private(set) var isRemovingEmptyFolders = false
    @Published private(set) var isRemovingDSStoreFiles = false
    @Published private(set) var isCreatingFolder = false
    @Published private(set) var isMovingBrowserItems = false
    @Published private(set) var isMergingFolders = false
    @Published private(set) var mergeRequestedFolders: [BrowserItem] = []
    @Published private(set) var mergeDestination: BrowserItem?
    private(set) var mergeStatus = "No folder merge has been started."
    private(set) var mergeMovedItems = 0
    private(set) var mergeTotalItems = 0
    private(set) var mergeRemainingItems = 0
    private(set) var mergeSourceIndex = 0
    private(set) var mergeSourceCount = 0
    private(set) var mergeCompletedSourceCount = 0
    private(set) var mergeRetryAttempt = 0
    private(set) var mergeRetryMaxAttempts = 0
    private(set) var mergeRetryInMillis: UInt64 = 0
    @Published private(set) var mergeDidComplete = false
    @Published private(set) var mergeErrorDiagnostic: AppErrorDiagnostic?
    private(set) var emptyFolderScannedFolders = 0
    private(set) var emptyFolderDiscoveredFolders = 0
    private(set) var emptyFolderCandidateCount = 0
    private(set) var emptyFolderCheckedFolders = 0
    private(set) var emptyFolderRemovedFolders = 0
    private(set) var emptyFolderSkippedFolders = 0
    private(set) var emptyFolderCurrentPath = ""
    private(set) var maintenanceStatus = ""

    private var process: Process?
    private var operationInputURL: URL?
    private var requestedStop = false
    private var operation: Operation?
    /// Downloads own a utility-priority process instead of the foreground
    /// Browser process. The shared token file still serializes refresh-token
    /// rotation, while folder navigation and previews remain responsive.
    private var downloadProcess: Process?
    private var downloadInputURL: URL?
    private var downloadRequestedStop = false
    private var downloadOperation: Operation?
    private var pendingDownloadOutputLines: [String] = []
    private var downloadOutputFlushScheduled = false
    private var pendingDownloadRequests: [PendingDownloadRequest] = []
    private var activePersistentDownload: PendingDownloadRequest?
    private var interruptedDownloadRequests: [PendingDownloadRequest] = []
    private var activeUploadBatchID: UUID?
    private var transferAccountID: String?
    private var transferStateReady = false
    private var transferPersistenceScheduled = false
    private var isClosingWindow = false
    private let transferPersistenceQueue = DispatchQueue(label: "com.wky.PikPakDownloader.transfer-state", qos: .utility)
    #if TRANSFER_PERSISTENCE_TESTS
    private var transferTestDirectory: URL?
    #endif
    private var activeDownloadRequestKey: String? {
        didSet { if activeDownloadRequestKey == nil { activeDownloadSelectionKeys.removeAll() } }
    }
    private var activeDownloadSelectionKeys = Set<String>()
    /// Uploads own a process independent from short-lived browser/preview
    /// requests. This keeps Finder-style navigation responsive throughout a
    /// long transfer while the shared token store serializes any refresh.
    private var uploadProcess: Process?
    private var uploadInputURL: URL?
    private var uploadRequestedStop = false
    private var uploadStateBeforePause: UploadRunState = .hashing
    private var pendingUploadOutputLines: [String] = []
    private var uploadOutputFlushScheduled = false
    private var duplicateProcess: Process?
    private var duplicateScanWasCancelled = false
    private var pendingDuplicateProgressLines: [String] = []
    private var duplicateProgressFlushScheduled = false
    /// Recursive maintenance scans own a process independent from Browser and
    /// Links requests. This keeps both file workspaces responsive while a large
    /// account tree is being checked.
    private var maintenanceProcess: Process?
    private var maintenanceOperation: Operation?
    private var maintenanceWasCancelled = false
    private var pendingMaintenanceProgressLines: [String] = []
    private var maintenanceProgressFlushScheduled = false
    /// A folder merge can take time while PikPak settles asynchronous batch
    /// moves. Keep it independent from foreground browsing and expose its
    /// verification progress in Tasks.
    private var mergeProcess: Process?
    private var mergeInputURL: URL?
    private var mergeWasCancelled = false
    private var mergeCompletedSourceIDs = Set<String>()
    /// Extraction polling owns a process independent from Browser requests so
    /// the user can keep navigating while PikPak works.
    private var archiveProcesses: [UUID: Process] = [:]
    private var archiveInputURLs: [UUID: URL] = [:]
    private var stoppedArchiveTaskIDs = Set<UUID>()
    #if ARCHIVE_TASK_TESTS
    private var archiveTestEngineURL: URL?
    private var archiveTestDirectory: URL?
    private var archiveTestDefaultsName: String?
    func setArchiveTestBrowserItems(_ items: [BrowserItem], selectedIDs: Set<String>) {
        browserItems = items
        for item in items { browserItemParentIDs[item.id] = item.parentId ?? "" }
        selectedBrowserItemIDs = selectedIDs
        selectedBrowserItemID = items.first(where: { selectedIDs.contains($0.id) })?.id
    }

    init(archiveTestEngineURL: URL, directory: URL) {
        self.archiveTestEngineURL = archiveTestEngineURL
        self.archiveTestDirectory = directory
        let suite = "com.wky.PikPakExtractionTests.\(UUID().uuidString)"
        archiveTestDefaultsName = suite
        finderSettings = FinderSettings(defaults: UserDefaults(suiteName: suite)!)
        outputURL = directory.appendingPathComponent("downloads")
        refreshToken = "offline-fixture-token"
        transferStateReady = true
        attemptedInitialBrowse = true
    }

    func stopArchiveTestHelpers() {
        guard archiveTestDirectory != nil else { return }
        isClosingWindow = true
        for child in archiveProcesses.values where child.isRunning { child.terminate() }
        for id in Array(archiveInputURLs.keys) { cleanupArchiveInputFile(id) }
        if let archiveTestDefaultsName { UserDefaults.standard.removePersistentDomain(forName: archiveTestDefaultsName) }
    }
    #endif
    /// Recursive folder measurements are read-only but can take minutes. Keep
    /// them independent from the short foreground Browser/Links request slot.
    private var folderMeasurementProcess: Process?
    private var folderMeasurementInputURL: URL?
    private var folderMeasurementOperation: Operation?
    private var folderMeasurementWasCancelled = false
    private var measuringFolderCacheKey: String?
    private var pendingFolderMeasurementRequests: [PendingFolderMeasurementRequest] = []
    private var deferredLoginReason: String?
    private var deferredLoginRequiresCleanStart = false
    private var quotaRefreshPending = false
    private var deviceID = ""
    private var folderMeasurementAccountID: String?
    private var folderSizeIndex = FolderSizeIndex()
    private var folderSizeRevision: UInt64 = 0
    private var folderSizeChanges: [String: UInt64] = [:]
    private var removedSizeFolderIDs = Set<String>()
    private var forceFullSizeRepairIDs = Set<String>()
    private var foregroundSizeRevision: UInt64 = 0
    private var sizeListingRevisions: [String: UInt64] = [:]
    private var folderMeasurementStartRevision: UInt64 = 0
    private var folderMeasurementStartAccountID: String?
    private var folderMeasurementUsesCachedSubfolders = false
    private var automaticSizeRepairIDs = Set<String>()
    private var folderSizeRepairTask: Task<Void, Never>?
    private var folderSizePersistTask: Task<Void, Never>?
    #if FOLDER_SIZE_TESTS
    private init(folderSizeTest: Bool) {
        outputURL = FileManager.default.temporaryDirectory
        isClosingWindow = true // No network helpers or real credentials in tests.
    }

    static func testIncrementalFolderSizes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-size-test-\(UUID().uuidString)", isDirectory: true)
        FolderMeasurementCacheStore.testFileURL = directory.appendingPathComponent("sizes.json")
        defer { FolderMeasurementCacheStore.testFileURL = nil }
        let model = DownloaderModel(folderSizeTest: true)
        model.folderMeasurementAccountID = "fixture-account"
        let linkKey = "shared-link:fixture:root"
        model.folderMeasurements[linkKey] = .init(totalBytes: 800, fileCount: 8, folderCount: 0)
        let report = #"{"total_bytes":100,"file_count":2,"folder_count":1,"folders":{"root":{"total_bytes":100,"file_count":2,"folder_count":1},"child":{"total_bytes":100,"file_count":2,"folder_count":0}},"parents":{"child":"root","a":"child","b":"child"},"listings":{"root":[{"id":"child","size":0,"is_folder":true}],"child":[{"id":"a","size":40,"is_folder":false},{"id":"b","size":60,"is_folder":false}]},"reused_folders":0}"#
        model.finishFolderMeasurement(output: report, folderID: "root")
        let scanRevision = model.folderSizeRevision
        model.finishTrash(output: #"{"trashed_ids":["a"]}"#, itemID: "a", itemName: "fixture")
        precondition(model.folderMeasurements["root"]?.totalBytes == 60)
        precondition(model.folderMeasurements["child"]?.fileCount == 1)
        precondition(model.folderMeasurements[linkKey]?.totalBytes == 800)
        precondition(model.automaticSizeRepairIDs.isEmpty)
        model.finishFolderMeasurement(output: report, folderID: "root", scanRevision: scanRevision,
                                      scanAccountID: "fixture-account", usedCachedSubfolders: true)
        precondition(model.folderMeasurements["root"]?.totalBytes == 60, "stale scan must not resurrect a deleted file")
        precondition(model.automaticSizeRepairIDs == ["root"])
        model.automaticSizeRepairIDs = []
        model.finishCreateFolder(output: #"{"id":"new","name":"New","parent_id":"child"}"#,
                                 parent: .init(id: "child", name: "Child", path: "/Child"), requestedName: "New")
        precondition(model.folderMeasurements["root"]?.folderCount == 2)
        model.persistFolderMeasurementsNow()
        model.folderMeasurementCacheQueue.sync {}
        let saved = try FolderMeasurementCacheStore.account(for: "fixture-account")!
        precondition(saved.index == model.folderSizeIndex)
        let otherAccount = try FolderMeasurementCacheStore.account(for: "other-account")
        precondition(otherAccount == nil)
        let permissions = try FileManager.default.attributesOfItem(atPath: FolderMeasurementCacheStore.testFileURL!.path)
        precondition((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let reopened = DownloaderModel(folderSizeTest: true)
        reopened.adoptFolderMeasurementCache(for: "fixture-account")
        precondition(reopened.folderSizeIndex == model.folderSizeIndex)
        reopened.finishTrash(output: #"{"trashed_ids":["b"]}"#, itemID: "b", itemName: "fixture")
        precondition(reopened.folderMeasurements["root"]?.totalBytes == 0)
        precondition(reopened.folderMeasurements[linkKey]?.totalBytes == 800)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let event = try decoder.decode(UploadProgressEvent.self,
            from: Data(#"{"event":"folder_progress","folder_id":"uploaded","parent_id":"child","name":"fixture","created_folders":1,"total_folders":1}"#.utf8))
        reopened.applyUploadProgressEvent(event)
        precondition(reopened.folderSizeIndex.dirty.contains("child"))
        precondition(reopened.automaticSizeRepairIDs == ["root"])
        precondition(reopened.folderMeasurements[linkKey]?.totalBytes == 800)
        let separate = DownloaderModel(folderSizeTest: true)
        separate.folderMeasurementAccountID = "fixture-account"
        separate.finishFolderMeasurement(output: report, folderID: "root")
        let independentRevision = separate.folderSizeRevision
        separate.recordFolderSizeChange(in: ["unrelated-folder"])
        separate.finishFolderMeasurement(output: report, folderID: "root", scanRevision: independentRevision,
                                         scanAccountID: "fixture-account", usedCachedSubfolders: true)
        precondition(separate.folderMeasurements["root"]?.totalBytes == 100)
        precondition(separate.automaticSizeRepairIDs.isEmpty, "unrelated mutations must not restart a scan")
        let partial = #"{"files":[{"id":"a","name":"a","size":40,"kind":"drive#file"}],"next_page_token":"more"}"#
        separate.finishBrowserTreeBrowse(output: partial, folderID: "child", folderName: "Child", folderPath: "/Child",
                                        append: false, sizeRevision: separate.folderSizeRevision)
        precondition(separate.folderMeasurements["child"]?.totalBytes == 100, "a page is not a full listing")
        let staleListingRevision = separate.folderSizeRevision
        separate.finishTrash(output: #"{"trashed_ids":["b"]}"#, itemID: "b", itemName: "fixture")
        let stale = #"{"files":[{"id":"a","name":"a","size":40,"kind":"drive#file"},{"id":"b","name":"b","size":60,"kind":"drive#file"}]}"#
        separate.finishBrowserTreeBrowse(output: stale, folderID: "child", folderName: "Child", folderPath: "/Child",
                                        append: false, sizeRevision: staleListingRevision)
        precondition(separate.folderMeasurements["child"]?.totalBytes == 40, "in-flight old browser results must not overwrite deltas")
        separate.operation = .trash(itemID: "a", itemName: "fixture")
        separate.isRunning = true
        separate.reconcileAccountFolderSize("child", items: [])
        precondition(separate.folderMeasurements["child"]?.totalBytes == 40, "server mutation awaiting acknowledgement must not be counted twice")
        separate.operation = nil
        separate.isRunning = false
        separate.folderSizePersistTask?.cancel()
        reopened.folderSizePersistTask?.cancel()
        model.folderSizePersistTask?.cancel()
        print("PASS: native callbacks, private persistence/relaunch, account/link isolation, partial pagination and scan/browse mutation races")
    }
    #endif
    private let folderMeasurementCacheQueue = DispatchQueue(
        label: "com.wky.PikPakDownloader.folder-size-cache",
        qos: .utility
    )
    private var browserSelectionAnchorID: String?
    private var browserFolderSnapshots: [String: BrowserFolderSnapshot] = [:]
    private var browserTreeNextPageTokens: [String: String] = [:]
    private var browserItemPaths: [String: String] = [:]
    private var browserItemParentIDs: [String: String] = [:]
    private var browserDragToken: String?
    private var browserDragAccountID: String?
    private var browserDraggedItems: [BrowserItem] = []
    /// Retained only until in-flight folder listings finish. A stale listing
    /// must not undo a confirmed move in the outline or its parent/path index.
    private var browserMoveCorrections: [String: (item: BrowserItem, destination: BrowserLocation, revision: UInt64)] = [:]
    private var pendingBrowserMoves: [BrowserMoveRequest] = []
    private var pendingBrowserTreeLoads: [BrowserTreeLoadRequest] = []
    private var pendingSharedSaveRequests: [PendingSharedSaveRequest] = []
    /// Saving is a mutation, but it does not need the foreground Browser helper.
    /// One helper per link lets unrelated links continue operating concurrently.
    private var sharedSaveProcesses: [UUID: Process] = [:]
    private var sharedSaveInputURLs: [UUID: URL] = [:]
    private var sharedSavesStoppedForLogin = Set<UUID>()
    /// Top-level shared URLs are independent virtual roots. Give every root its
    /// own short-lived helper so a slow or unreachable URL never monopolizes
    /// the foreground Browser process or prevents another URL from opening.
    private var sharedLinkLoadProcesses: [UUID: Process] = [:]
    private var sharedLinkLoadInputURLs: [UUID: URL] = [:]
    private var sharedLinkLoadsStoppedForLogin = Set<UUID>()
    private var pendingSharedLinkLoads: [(linkID: UUID, request: ShareBrowseInput)] = []
    private let maximumConcurrentSharedLinkLoads = 4
    private var isStartingPendingSharedLinkLoads = false
    private var sharedLinkRetryBatchIDs = Set<UUID>()
    private var attemptedInitialBrowse = false
    private var shareAccess: ShareAccessInput?
    private var pendingSharedLinkOpenAfterLogin = false
    private var accountBrowserWorkspace: BrowserWorkspaceSnapshot?
    private var sharedBrowserWorkspace: BrowserWorkspaceSnapshot?
    private var sharedLinkSessions: [UUID: SharedLinkSession] = [:]
    private var browserSortRevision = UUID()
    private var activeBrowserSortRevision: UUID?
    private var browserTreeEntriesCache: [BrowserTreeEntry]?

    private func invalidateBrowserPresentation(itemsChanged: Bool) {
        browserTreeEntriesCache = nil
        if itemsChanged { browserItemIndexCache = nil; activeBrowserSortRevision = nil }
    }
    private let sharedLinkStateQueue = DispatchQueue(
        label: "com.wky.PikPakDownloader.shared-links-state",
        qos: .utility
    )
    private var automaticPreviewTask: Task<Void, Never>?
    private var automaticPreviewTargetID: String?
    private var pendingAutomaticPreviewID: String?
    private var previewSources: [PreviewSource] = []
    private var previewSourceIndex = 0
    private var playerItemStatusObservation: NSKeyValueObservation?
    private var playerLoadedTimeRangesObservation: NSKeyValueObservation?
    private var playerTimeControlStatusObservation: NSKeyValueObservation?
    private var playerRateChangeObserver: NSObjectProtocol?
    private var previewTimeObserver: Any?
    private var previewTimeObserverPlayer: AVPlayer?
    private var playerFailureObserver: NSObjectProtocol?
    private var playerAccessLogObserver: NSObjectProtocol?
    private var playerEndObserver: NSObjectProtocol?
    private var playerStallObserver: NSObjectProtocol?
    private var previewLoadTimeoutTask: Task<Void, Never>?
    private var previewMetricsTask: Task<Void, Never>?
    private var previewPlaybackRecoveryTask: Task<Void, Never>?
    private var previewPlaybackWasRequested = false
    private var previewLoadGeneration = UUID()
    private var textPreviewLoader: BoundedTextPreviewLoader?
    private var textPreviewLoadGeneration = UUID()
    private var pendingQuickLookFileID: String?
    private var quickLookTargetItem: BrowserItem?
    private var quickLookTargetIdentity: String?
    private var quickLookCopies: [String: URL] = [:]
    private var quickLookCopyOrder: [String] = []
    private var quickLookDownloadTask: URLSessionDownloadTask?
    private var quickLookDownloadSession: URLSession?
    private var quickLookDownloadGeneration = UUID()
    private var previewResourceLoader: PreviewResourceLoader?
    private var previewResourceCaches: [String: PreviewResourceCache] = [:]
    private var previewResourceCacheFileID: String?
    /// Folder expansion used to share the single foreground engine lane, so a
    /// second disclosure click could only queue behind the first. Each open now
    /// gets its own helper, bounded so a burst of clicks cannot flood PikPak.
    private var browserTreeLoadProcesses: [String: Process] = [:]
    private var browserTreeLoadInputURLs: [String: URL] = [:]
    private var browserTreeLoadGenerations: [String: UUID] = [:]
    private var browserTreeLoadExpansionOwners: [String: UUID] = [:]
    private var browserFolderExpansion: BrowserFolderExpansionPlan?
    private var browserFolderExpansionTask: Task<Void, Never>?
    private static let browserTreeLoadConcurrencyLimit = 4
    private var previewLastCacheSnapshot: PreviewResourceCacheSnapshot?
    private var previewCacheRateSample: (bytes: UInt64, date: Date)?
    private var previewNetworkRateSample: (bytes: UInt64, date: Date)?
    private var previewLastTransferProgressDate: Date?
    private let quickLookPreviewCoordinator = QuickLookPreviewCoordinator()
    private let cloudDownloadPromiseCoordinator = CloudDownloadPromiseCoordinator()
    private var activeDownloadTransfers: [String: DownloadTransfer] = [:]
    private var queuedDownloadIDs = Set<String>()
    private var settledDownloadIDs = Set<String>()
    private var settledDownloadBytes: UInt64 = 0
    private var settledDownloadNetworkBytes: UInt64 = 0
    private var downloadNetworkBaselines: [String: UInt64] = [:]
    private var downloadNetworkBytesByID: [String: UInt64] = [:]
    private var downloadFileTotalsByID: [String: UInt64] = [:]
    private var downloadNetworkTransferredBytes: UInt64 = 0
    private var lastDownloadSpeedSampleDate: Date?
    private var lastDownloadSpeedSampleBytes: UInt64 = 0
    private var lastDownloadNetworkProgressDate: Date?
    private var lastAccountDownloadPaths: [String] = []
    private var lastSharedDownloadItems: [BrowserItem] = []
    private var lastSharedDownloadAccess: ShareAccessInput?
    private var lastDownloadUsedSharedLink = false
    /// Shared links have independent access contexts. Associate each emitted
    /// file id with the context that produced it so a later row-level retry is
    /// not accidentally sent through whichever link is currently selected.
    private var downloadSharedAccessByFileID: [String: ShareAccessInput] = [:]
    private var activeUploadTransfers: [String: UploadTransfer] = [:]
    private var queuedUploadIDs = Set<String>()
    private var settledUploadIDs = Set<String>()
    private var settledUploadBytes: UInt64 = 0
    private var settledUploadNetworkBytes: UInt64 = 0
    private var settledUploadHashedBytes: UInt64 = 0
    private var uploadNetworkTransferredBytes: UInt64 = 0
    private var uploadHashedBytes: UInt64 = 0
    private var lastUploadSpeedSampleDate: Date?
    private var lastUploadSpeedSampleBytes: UInt64 = 0
    private var lastUploadNetworkProgressDate: Date?
    private var lastUploadHashSpeedSampleDate: Date?
    private var lastUploadHashSpeedSampleBytes: UInt64 = 0
    private var lastUploadHashProgressDate: Date?
    private var preserveUploadFailureHistoryForCurrentRun = false
    private var transferMetricsTask: Task<Void, Never>?

    #if TRANSFER_PERSISTENCE_TESTS
    private init(transferTestDirectory: URL) {
        self.transferTestDirectory = transferTestDirectory
        outputURL = transferTestDirectory.appendingPathComponent("downloads")
    }
    #endif

    init() {
        let defaults = UserDefaults.standard
        let downloads = FileManager.default.urls(
            for: .downloadsDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
        let savedOutput = defaults.string(forKey: "outputPath")
        outputURL = savedOutput.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? downloads.appendingPathComponent("PikPak Downloads", isDirectory: true)
        // FinderSettings owns the unified 32-worker default. Preserve legacy
        // preference keys on disk, but do not import conflicting old limits.
        proxyURL = defaults.string(forKey: "proxyURL") ?? ""
        shareURLInput = defaults.string(forKey: "lastShareURL") ?? ""
        browserSortColumn = defaults.string(forKey: "browserSortColumn")
            .flatMap(BrowserSortColumn.init(rawValue:)) ?? .name
        browserSortDirection = defaults.string(forKey: "browserSortDirection")
            .flatMap(BrowserSortDirection.init(rawValue:)) ?? .ascending
        LocalCredentialStore.removeLegacyCredentialExchangeFiles()
        // Remove the app-owned persistent Web cookies/credentials left by
        // older Web-token builds. This WebKit store is scoped to this bundle
        // and is physically separate from Safari's profile.
        PikPakLoginDataStore.clearLegacyPersistentPikPakWebsiteData()

        do {
            let storedSession = try SessionStore.loadIsolatedSession()
            let store = try PikPakAccountStore(directory: LocalCredentialStore.applicationSupportDirectoryURL()
                .appendingPathComponent("Accounts", isDirectory: true))
            let accounts = try store.migrateLegacySession(storedSession)
            accountStore = store
            applyAccounts(accounts)
            if let active = activeSavedAccount, !active.needsSignIn {
                let session = try store.files(for: active.id).load()
                refreshToken = session.token
                deviceID = session.deviceID
                accountProfile = active.profile
                accountLoginStatus = .unverified
                status = "Saved PikPak account loaded"
            } else {
                requiresDedicatedSignIn = activeSavedAccount?.needsSignIn == true || storedSession.requiresDedicatedSignIn
                accountLoginStatus = requiresDedicatedSignIn ? .needsSignIn : .signedOut
                deviceID = storedSession.deviceID
            }
            // Commit the account directory/index before removing the old singleton.
            // Retry this cleanup on later launches if it was interrupted.
            try SessionStore.deleteToken()
        } catch {
            // Fail closed: never bypass the dedicated-profile check merely
            // because migration or storage validation failed.
            refreshToken = ""
            deviceID = (try? LocalCredentialStore.loadOrCreateDeviceID()) ?? ""
            requiresDedicatedSignIn = true
            accountLoginStatus = .needsSignIn
            accountSettingsError = "Could not load saved accounts. Your existing files have been kept."
            setError("Could not prepare local session storage: \(error.localizedDescription)")
        }

        restorePersistedSharedLinks()
    }

    var canTestConnection: Bool {
        !isRunning && !hasExclusiveBackgroundTask
            && hasUsableSession
    }
    var isBrowsingSharedLink: Bool { browserSource == .sharedLink }
    var isMaintenanceScanRunning: Bool {
        isRemovingEmptyFolders || isRemovingDSStoreFiles
    }
    var mergeProgressFraction: Double? {
        if mergeTotalItems > 0 {
            let confirmedItems = max(mergeTotalItems - mergeRemainingItems, 0)
            return min(max(Double(confirmedItems) / Double(mergeTotalItems), 0), 1)
        }
        if mergeSourceCount > 0 {
            return min(
                max(Double(mergeCompletedSourceCount) / Double(mergeSourceCount), 0),
                1
            )
        }
        return nil
    }
    var canRetryFolderMerge: Bool {
        !isRunning
            && !hasExclusiveBackgroundTask
            && !isMergingFolders
            && (mergeErrorDiagnostic != nil || !mergeDidComplete)
            && mergeDestination != nil
            && mergeRequestedFolders.contains {
                $0.id != mergeDestination?.id && !mergeCompletedSourceIDs.contains($0.id)
            }
            && hasUsableSession
            && !mergeRequestedFolders.contains(where: isExtractionSourceInUse)
    }
    /// Long work is deliberately kept off the foreground request channel.
    /// Views can use this aggregate for activity indication without disabling
    /// Browser or Links navigation.
    var hasBackgroundActivity: Bool {
        hasOtherBackgroundActivity || hasActiveArchiveTasks
    }

    /// The ordinary footer status excludes the separately displayed extractions.
    var hasOtherBackgroundActivity: Bool {
        isDownloading
            || isUploading
            || isScanningDuplicates
            || isMaintenanceScanRunning
            || isMeasuringFolder
            || isMergingFolders
    }

    /// Extraction runs on PikPak and never occupies this local work lane.
    /// Source-specific checks protect an archive while unrelated work continues.
    private var hasExclusiveBackgroundTask: Bool {
        hasOtherBackgroundActivity
    }

    /// A running folder measurement may accept more independently keyed scans
    /// into its own queue. Other transfer/maintenance work still prevents a
    /// new recursive scan from being scheduled.
    private var hasNonMeasurementBackgroundTask: Bool {
        isDownloading
            || isUploading
            || isScanningDuplicates
            || isMaintenanceScanRunning
            || isMergingFolders
    }
    var canOpenShareLink: Bool {
        !isRunning
            && !shareURLInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var activeSharedLink: SharedLinkEntry? {
        guard let activeSharedLinkID else { return nil }
        return sharedLinks.first(where: { $0.id == activeSharedLinkID })
    }

    var failedSharedLinkCount: Int {
        sharedLinks.reduce(0) { count, entry in
            if case .failed = entry.state { return count + 1 }
            return count
        }
    }

    var canRetryFailedSharedLinks: Bool {
        !isRunning && !isClosingWindow && !isChangingAccount && !isLoginPresented
            && deferredLoginReason == nil && sharedLinkRetryProgress == nil
            && failedSharedLinkCount > 0
    }

    func isSharedItemSaved(_ itemID: String) -> Bool {
        isSharedItemSaved(itemID, in: activeSharedLinkID)
    }

    func isSharedItemSaved(_ itemID: String, in linkID: UUID?) -> Bool {
        guard let linkID,
              let session = sharedLinkSessions[linkID]
        else { return false }
        return session.savedItemIDs.contains(itemID)
    }

    func isSharedItemSavingOrQueued(_ itemID: String, in linkID: UUID) -> Bool {
        if savingSharedItemIDsByLinkID[linkID]?.contains(itemID) == true {
            return true
        }
        return pendingSharedSaveRequests.contains { pending in
            pending.linkID == linkID && pending.request.fileIds.contains(itemID)
        }
    }

    /// True only when every selected recursive action root has already been
    /// accepted by PikPak. A selected folder is represented by its own id, so
    /// its descendants do not prevent the folder-level Saved state.
    var isSelectedSharedSelectionSaved: Bool {
        guard isBrowsingSharedLink else { return false }
        let groups = sharedBrowserSelectionGroups
        return !groups.isEmpty && groups.allSatisfy { group in
            group.items.allSatisfy { isSharedItemSaved($0.id, in: group.linkID) }
        }
    }

    var isSavingSelectedSharedSelection: Bool {
        guard isBrowsingSharedLink else { return false }
        return sharedBrowserSelectionGroups.contains { group in
            group.items.contains { isSharedItemSavingOrQueued($0.id, in: group.linkID) }
        }
    }

    func isSharedLinkExpanded(_ linkID: UUID) -> Bool {
        guard
            expandedSharedLinkIDs.contains(linkID),
            let entry = sharedLinks.first(where: { $0.id == linkID }),
            entry.state == .ready,
            sharedLinkSessions[linkID]?.workspace != nil
        else { return false }
        return true
    }

    func setSharedLinkExpanded(_ linkID: UUID, expanded: Bool) {
        if expanded {
            expandedSharedLinkIDs.insert(linkID)
        } else {
            expandedSharedLinkIDs.remove(linkID)
        }
        persistSharedLinkState()
    }

    /// Every added URL owns a complete cached Browser workspace. Returning a
    /// flattened presentation for the requested link lets several virtual
    /// roots stay expanded together instead of borrowing one global tree.
    func sharedLinkTreeEntries(for linkID: UUID) -> [BrowserTreeEntry] {
        if isBrowsingSharedLink, activeSharedLinkID == linkID {
            return browserTreeEntries
        }
        guard let workspace = sharedLinkSessions[linkID]?.workspace else { return [] }
        return visibleBrowserTreeEntries(from: workspace, in: linkID)
    }

    var sortedSharedLinks: [SharedLinkEntry] {
        sharedLinks.sorted { left, right in
            let primary: ComparisonResult
            switch browserSortColumn {
            case .name: primary = left.url.localizedStandardCompare(right.url)
            case .size:
                let lhs = cachedSharedLinkMeasurement(for: left.id)?.totalBytes ?? 0
                let rhs = cachedSharedLinkMeasurement(for: right.id)?.totalBytes ?? 0
                primary = lhs < rhs ? .orderedAscending : (lhs > rhs ? .orderedDescending : .orderedSame)
            case .kind: primary = .orderedSame
            case .modified: primary = left.addedAt.compare(right.addedAt)
            }
            let order = primary == .orderedSame ? left.url.localizedStandardCompare(right.url) : primary
            return browserSortDirection == .ascending ? order == .orderedAscending : order == .orderedDescending
        }
    }

    /// Avoid flashing a spinner for small cached views. Large outlines still
    /// need a layout pass even when their model snapshot can be restored cheaply.
    func workspaceSwitchNeedsLoading(to section: Int) -> Bool {
        guard !isRunning, section == 0 || section == 3 else { return false }
        if section == 3 {
            if sharedLinks.count >= 50 { return true }
            var count = 0
            for link in sharedLinks where expandedSharedLinkIDs.contains(link.id) {
                let workspace = sharedLinkSessions[link.id]?.workspace
                count += workspace?.presentation.entries?.count ?? workspace?.items.count ?? 0
                if count >= 2_000 { return true }
            }
            return false
        }
        guard let workspace = accountBrowserWorkspace else { return false }
        if (workspace.presentation.entries?.count ?? workspace.items.count) >= 2_000 { return true }
        return workspace.childrenByFolderID.values.reduce(workspace.items.count) { $0 + $1.count } >= 5_000
    }

    func isSharedLinkFolderExpanded(_ folderID: String, in linkID: UUID) -> Bool {
        if isBrowsingSharedLink, activeSharedLinkID == linkID {
            return expandedBrowserFolderIDs.contains(folderID)
        }
        return sharedLinkSessions[linkID]?.workspace?.expandedFolderIDs.contains(folderID) == true
    }

    func isSharedLinkFolderLoading(_ folderID: String, in linkID: UUID) -> Bool {
        isBrowsingSharedLink
            && activeSharedLinkID == linkID
            && browserTreeLoadingFolderIDs.contains(folderID)
    }

    func sharedLinkFolderHasMoreItems(_ folderID: String, in linkID: UUID) -> Bool {
        if isBrowsingSharedLink, activeSharedLinkID == linkID {
            return browserTreeNextPageTokens[folderID]?.isEmpty == false
        }
        return sharedLinkSessions[linkID]?.workspace?.childPageTokens[folderID]?.isEmpty == false
    }

    func sharedLinkFolderIsLoadedAndEmpty(_ folderID: String, in linkID: UUID) -> Bool {
        let workspace = sharedLinkSessions[linkID]?.workspace
        let children: [BrowserItem]?
        let error: String?
        if isBrowsingSharedLink, activeSharedLinkID == linkID {
            children = browserTreeChildren[folderID]
            error = browserTreeLoadErrors[folderID]
        } else {
            children = workspace?.childrenByFolderID[folderID]
            error = workspace?.loadErrors[folderID]
        }
        return children?.isEmpty == true
            && !sharedLinkFolderHasMoreItems(folderID, in: linkID)
            && error == nil
    }

    func sharedLinkFolderLoadError(_ folderID: String, in linkID: UUID) -> String? {
        if isBrowsingSharedLink, activeSharedLinkID == linkID {
            return browserTreeLoadErrors[folderID]
        }
        return sharedLinkSessions[linkID]?.workspace?.loadErrors[folderID]
    }
    var canSaveSharedSelection: Bool {
        guard isBrowsingSharedLink else { return false }
        return sharedBrowserSelectionGroups.contains { group in
            group.items.contains { canSaveSharedItem($0, in: group.linkID) }
        }
    }

    func sharedSaveContextMenuTitle(for item: BrowserItem, in linkID: UUID) -> String {
        let usesSelection = isBrowserItemSelected(item.id, in: linkID)
        let count = usesSelection ? browserActionSelectionCount : 1
        if count > 1 { return "Save \(count.formatted()) Items to My PikPak" }
        if usesSelection ? isSelectedSharedSelectionSaved : isSharedItemSaved(item.id, in: linkID) {
            return "Saved to My PikPak"
        }
        return "Save to My PikPak"
    }

    func canSaveSharedItemsFromContextMenu(_ item: BrowserItem, in linkID: UUID) -> Bool {
        isBrowserItemSelected(item.id, in: linkID)
            ? canSaveSharedSelection
            : canSaveSharedItem(item, in: linkID)
    }

    func saveSharedItemsFromContextMenu(_ item: BrowserItem, in linkID: UUID) {
        if !isBrowserItemSelected(item.id, in: linkID) {
            activateSharedLink(linkID)
            guard isBrowsingSharedLink, activeSharedLinkID == linkID else { return }
            selectBrowserItem(item)
        }
        saveSelectedSharedItems()
    }

    func canSaveSharedItem(_ item: BrowserItem, in linkID: UUID?) -> Bool {
        guard let linkID, hasUsableSession,
              sharedLinks.first(where: { $0.id == linkID })?.state == .ready else { return false }
        return !isSharedItemSaved(item.id, in: linkID)
            && !isSharedItemSavingOrQueued(item.id, in: linkID)
    }
    var canOpenCompatibilityPreview: Bool {
        previewRequiresCompatibilityPlayer
            && compatibilityPlayerExecutableURL() != nil
            && previewSources.contains(where: { $0.contentURL != nil })
    }
    var canOpenPreviewExternally: Bool {
        compatibilityPlayerExecutableURL() != nil
            && previewSources.contains(where: { $0.contentURL != nil })
    }
    var externalPreviewPlayerName: String? {
        compatibilityPlayerExecutableURL() == nil ? nil : "IINA"
    }
    var canOpenPreviewInQuickLook: Bool {
        !isPreparingQuickLook && preferredQuickLookSource() != nil
    }
    func canRequestQuickLook(for item: BrowserItem) -> Bool {
        !isClosingWindow && canOpenBrowserFile(item)
    }

    var isQuickLookSessionActive: Bool { quickLookTargetItem != nil && quickLookPreviewCoordinator.isActive }

    func canOpenBrowserFile(_ item: BrowserItem, in linkID: UUID? = nil) -> Bool {
        guard !item.isFolder, !isLoginPresented else { return false }
        if let linkID { return sharedLinks.first(where: { $0.id == linkID })?.state == .ready }
        return hasActiveBrowserAccess
    }

    func openBrowserFile(_ item: BrowserItem, application: URL? = nil, chooseApplication: Bool = false) {
        guard canOpenBrowserFile(item) else { return }
        do {
            let configuration = try fileOpenConfiguration(for: item)
            // Identical ids in two shared links, or another account, are not
            // the same document. Include revision/name in the local-copy key.
            let source = isBrowsingSharedLink ? "link:\(activeSharedLinkID?.uuidString ?? "")" : "account:\(transferAccountID ?? "")"
            let identity = [source, item.id, item.name, String(item.size), item.modifiedTime ?? "", item.hash ?? ""].joined(separator: "\u{1F}")
            let context = fileOpenContext
            let open: (URL?) -> Void = { [weak self] application in
                guard let self, self.fileOpenContext == context, !self.isClosingWindow else { return }
                self.fileOpener.open(identity: identity, name: item.name, application: application, configuration: configuration)
            }
            if chooseApplication {
                FinderFileApplications.chooseApplication(for: item.name) { open($0) }
            } else { open(application) }
        } catch {
            requireFreshAppLoginIfSessionTrustFailed(error)
            setError("Could not prepare Open: \(error.localizedDescription)")
        }
    }

    private func fileOpenConfiguration(for item: BrowserItem) throws -> FinderFileOpenConfiguration {
        #if FINDER_WORKSPACE_TESTS
        if isFinderWorkspaceFixture {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PikPak-Offline-Open", isDirectory: true)
            return FinderFileOpenConfiguration(executable: URL(fileURLWithPath: "/usr/bin/false"), environment: [:],
                arguments: [], exchangeDirectory: directory, copiesDirectory: directory, proxyURL: "")
        }
        #endif
        guard let executable = Bundle.main.url(forResource: "pikpak", withExtension: nil) else {
            throw NSError(domain: "PikPakOpen", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "The bundled PikPak engine is missing. Rebuild the app."])
        }
        var environment = try engineEnvironment()
        let proxy = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        environment["PIKPAK_PROXY"] = proxy.isEmpty ? nil : proxy
        var arguments = ["preview", "--id", item.id]
        var requestData: Data?
        if isBrowsingSharedLink {
            guard let shareAccess, shareLinkIsOpen else { throw CocoaError(.fileReadNoPermission) }
            arguments = ["share-preview"]
            requestData = try JSONEncoder().encode(SharePreviewInput(access: shareAccess, fileId: item.id))
        }
        return FinderFileOpenConfiguration(executable: executable, environment: environment, arguments: arguments,
            requestData: requestData, exchangeDirectory: try makePrivateExchangeDirectory(),
            copiesDirectory: try LocalCredentialStore.applicationSupportDirectoryURL()
                .appendingPathComponent("Opened Files", isDirectory: true), proxyURL: proxy)
    }
    var canBrowse: Bool { !isRunning && hasActiveBrowserAccess }
    var canGoBack: Bool { !isRunning && browserStack.count > 1 }

    /// A short read-only browser/quota request must not leave the source
    /// chooser disabled after an upload is cancelled. Uploads use their own
    /// process and the shared session store serializes token rotation.
    private var foregroundOperationAllowsConcurrentUpload: Bool {
        guard isRunning else { return true }
        switch operation {
        case .quota, .browse, .browseTree, .preview, .shareBrowse, .shareBrowseTree,
             .sharePreview, .archiveInspect, .measure, .shareMeasure, .duplicates,
             .download, .shareDownload:
            return true
        case .upload, .archiveExtract, .shareSave,
             .trash, .trashBrowserItems, .moveBrowserItems, .renameItem, .mergeFolders,
             .trashDuplicates,
             .createFolder, .emptyFolders, .dsStoreFiles, .undoFiles, .none:
            return false
        }
    }

    /// The explicit choice wins. Otherwise Transfers inherits the last
    /// account-browser folder (even while the Links workspace is visible).
    var effectiveUploadDestination: BrowserLocation {
        if let uploadDestination {
            return uploadDestination
        }
        if !isBrowsingSharedLink, let current = browserStack.last {
            return current
        }
        if let accountLocation = accountBrowserWorkspace?.stack.last {
            return accountLocation
        }
        return .root
    }

    var canChooseUploadDestination: Bool {
        canUploadFiles
    }

    var canUploadFiles: Bool {
        UploadAvailability.allowsStart(
            hasSession: hasUsableSession && transferStateReady && !isClosingWindow,
            uploadActive: isUploading || uploadProcess?.isRunning == true,
            conflictingMutation: isMergingFolders || isRemovingEmptyFolders
                || isRemovingDSStoreFiles,
            foregroundAllows: foregroundOperationAllowsConcurrentUpload
        )
    }

    func canOpenArchiveExtraction(_ item: BrowserItem) -> Bool {
        guard !isBrowsingSharedLink, item.isCloudExtractableArchive, hasUsableSession else {
            return false
        }
        return !isClosingWindow && !isChangingAccount && !isLoginPresented
            && (!isMergingFolders || !mergeRequestedFolders.contains {
                $0.id == item.parentId || isBrowserItem(item.id, descendantOf: $0.id)
            })
    }

    /// Only the archive being read/extracted and its ancestors are protected;
    /// there is no account-wide lock on file actions while PikPak works.
    private func isExtractionSourceInUse(_ item: BrowserItem) -> Bool {
        archiveTasks.contains { task in
            task.isBusy && (item.id == task.item.id || (item.isFolder && (
                item.id == task.parentFolderID || isBrowserItem(task.item.id, descendantOf: item.id))))
        }
    }
    var canChangeBrowserSelection: Bool {
        // Selection is purely local UI state. Background API work must never
        // leave a stale set of checked descendants on screen or block the user
        // from choosing another row while a task is running.
        hasActiveBrowserAccess || !browserItems.isEmpty
    }
    var hasMoreBrowserItems: Bool { nextPageToken?.isEmpty == false }
    var canDownloadSelectedBrowserItem: Bool {
        canQueueBrowserDownload
            && browserActionSelectionCount > 0
    }

    /// Downloads own a dedicated process. A valid row therefore remains
    /// actionable while browsing, previews, scans, uploads, or another download
    /// are active; additional batches are serialized by the download queue.
    var canQueueBrowserDownload: Bool {
        hasActiveBrowserAccess && hasUsableSession
    }

    var canMeasureSelectedFolder: Bool {
        guard let selectedBrowserItem else { return false }
        return canMeasureFolder(selectedBrowserItem)
    }

    func canMeasureFolder(_ item: BrowserItem, in linkID: UUID? = nil) -> Bool {
        guard
            !isRunning,
            !hasNonMeasurementBackgroundTask,
            hasActiveBrowserAccess,
            item.isFolder
        else { return false }
        let effectiveLinkID = linkID ?? (isBrowsingSharedLink ? activeSharedLinkID : nil)
        let key = folderMeasurementCacheKey(for: item.id, linkID: effectiveLinkID)
        return measuringFolderCacheKey != key
            && !queuedFolderMeasurementCacheKeys.contains(key)
    }

    /// Shared roots can legitimately use the same opaque folder id (including
    /// the empty id used by many PikPak links). Namespace those ids by the local
    /// link UUID so measuring one URL cannot paint every other URL as scanning
    /// or reuse another link's cached size.
    private func folderMeasurementCacheKey(
        for folderID: String,
        linkID: UUID?
    ) -> String {
        guard let linkID else { return folderID }
        return sharedLinkMeasurementPrefix(linkID) + folderID
    }

    private func sharedLinkMeasurementPrefix(_ linkID: UUID) -> String {
        "shared-link:\(linkID.uuidString):"
    }

    func cachedFolderMeasurement(
        for folderID: String,
        in linkID: UUID? = nil
    ) -> FolderMeasurement? {
        let effectiveLinkID = linkID ?? (isBrowsingSharedLink ? activeSharedLinkID : nil)
        return folderMeasurements[
            folderMeasurementCacheKey(for: folderID, linkID: effectiveLinkID)
        ]
    }

    func isMeasuringFolder(_ folderID: String, in linkID: UUID? = nil) -> Bool {
        let effectiveLinkID = linkID ?? (isBrowsingSharedLink ? activeSharedLinkID : nil)
        return isMeasuringFolder
            && measuringFolderCacheKey == folderMeasurementCacheKey(
                for: folderID,
                linkID: effectiveLinkID
            )
    }

    func isFolderMeasurementQueued(_ folderID: String, in linkID: UUID? = nil) -> Bool {
        let effectiveLinkID = linkID ?? (isBrowsingSharedLink ? activeSharedLinkID : nil)
        return queuedFolderMeasurementCacheKeys.contains(
            folderMeasurementCacheKey(for: folderID, linkID: effectiveLinkID)
        )
    }

    func sharedLinkRootLocation(for linkID: UUID) -> BrowserLocation? {
        sharedLinkSessions[linkID]?.workspace?.stack.first
    }

    func cachedSharedLinkMeasurement(for linkID: UUID) -> FolderMeasurement? {
        guard let rootID = sharedLinkRootLocation(for: linkID)?.id else { return nil }
        return cachedFolderMeasurement(for: rootID, in: linkID)
    }

    func isMeasuringSharedLink(_ linkID: UUID) -> Bool {
        guard let rootID = sharedLinkRootLocation(for: linkID)?.id else { return false }
        return isMeasuringFolder(rootID, in: linkID)
    }

    func isSharedLinkMeasurementQueued(_ linkID: UUID) -> Bool {
        guard let rootID = sharedLinkRootLocation(for: linkID)?.id else { return false }
        return isFolderMeasurementQueued(rootID, in: linkID)
    }

    /// Disconnect only removes the link from this app; it never calls the
    /// engine. Gating it on the shared `isRunning` flag meant the quota refresh
    /// queued right after "Save to My PikPak" disabled Disconnect on *every*
    /// link for as long as that unrelated refresh took. Only this link's own
    /// work can block it.
    func canDisconnectSharedLink(_ linkID: UUID) -> Bool {
        sharedSaveProcesses[linkID]?.isRunning != true
            && measuringFolderCacheKey?.hasPrefix(sharedLinkMeasurementPrefix(linkID)) != true
    }

    func canMeasureSharedLink(_ linkID: UUID) -> Bool {
        guard
            !isRunning,
            !hasNonMeasurementBackgroundTask,
            hasUsableSession,
            let root = sharedLinkRootLocation(for: linkID),
            let entry = sharedLinks.first(where: { $0.id == linkID }),
            entry.state == .ready
        else { return false }
        let key = folderMeasurementCacheKey(for: root.id, linkID: linkID)
        return measuringFolderCacheKey != key
            && !queuedFolderMeasurementCacheKeys.contains(key)
    }

    var canTrashSelectedBrowserItem: Bool {
        !isRunning
            && !hasExclusiveBackgroundTask
            && !isBrowsingSharedLink
            && hasUsableSession
            && !browserItemActionRoots.isEmpty
            && !browserItemActionRoots.contains(where: isExtractionSourceInUse)
    }

    func canTrashBrowserItem(_ item: BrowserItem) -> Bool {
        guard !isRunning, !hasExclusiveBackgroundTask, !isBrowsingSharedLink, hasUsableSession else { return false }
        let items = isBrowserItemSelected(item.id) ? browserItemActionRoots : [item]
        return !items.contains(where: isExtractionSourceInUse)
    }

    var canBeginBrowserDrag: Bool {
        !isBrowsingSharedLink
            && !isClosingWindow
            && !isLoginPresented
            && hasUsableSession
    }
    var activeBrowserDragItemCount: Int { browserDraggedItems.count }
    var browserDropAccountID: String? { transferAccountID }

    private var hasConflictingBrowserMoveTask: Bool {
        isUploading || isMergingFolders || isMaintenanceScanRunning
    }

    func browserDropDestination(for item: BrowserItem) -> BrowserLocation? {
        guard !isBrowsingSharedLink else { return nil }
        if item.isFolder { return browserLocation(for: item) }
        guard let parentID = browserItemParentIDs[item.id] ?? item.parentId else { return nil }
        if let location = browserStack.first(where: { $0.id == parentID }) { return location }
        if parentID.isEmpty { return .root }
        return browserItem(withID: parentID).map(browserLocation(for:))
    }

    func browserDropRejection(on destination: BrowserLocation, payload: BrowserDropPayload) -> String? {
        guard !isBrowsingSharedLink else { return "Shared links are read-only. Drop into the Browser instead." }
        guard !isClosingWindow, !isLoginPresented, hasUsableSession else { return "Sign in before dropping files into PikPak." }
        if payload == .upload {
            if isUploading { return "An upload is already running. Wait for it to finish before adding another upload." }
            if !canUploadFiles { return "Uploads are temporarily unavailable while a folder change finishes." }
            return nil
        }
        guard !browserDraggedItems.isEmpty else { return "Start a new drag from a file or folder in this app." }
        if browserDraggedItems.contains(where: { $0.id == destination.id }) {
            return "A folder cannot be moved into itself."
        }
        if browserDraggedItems.contains(where: { $0.isFolder && isBrowserItem(destination.id, descendantOf: $0.id) }) {
            return "A folder cannot be moved into one of its own subfolders."
        }
        if !canMoveBrowserItems(browserDraggedItems, to: destination) { return "These items are already in this folder." }
        return nil
    }

    func springExpandBrowserDropFolder(_ folderID: String) {
        guard !isBrowsingSharedLink, !expandedBrowserFolderIDs.contains(folderID),
              let item = browserItem(withID: folderID), item.isFolder else { return }
        toggleBrowserFolderExpansion(item)
    }

    func cancelBrowserDrag() {
        browserDragToken = nil
        browserDragAccountID = nil
        browserDraggedItems = []
    }

    func reportBrowserDropFailure(_ message: String) {
        setError(message, diagnostic: AppErrorDiagnostic(source: "Drag and drop", code: "DROP_FAILED", message: message, context: nil))
    }

    func reportBrowserUploadPreparation(count: Int, destination: BrowserLocation) {
        setStatus("Preparing \(count.formatted()) dropped item(s) for upload to \(destination.name)…")
    }

    func reportBrowserDropFailure(_ error: Error) {
        setError("Could not accept the drop. No files were uploaded.",
                 diagnostic: diagnostic(for: error, source: "Finder drag and drop", fallbackCode: "DROP_FAILED"))
    }

    var canRemoveEmptyFolders: Bool {
        !isRunning && !hasExclusiveBackgroundTask
            && !isBrowsingSharedLink
            && hasUsableSession
            && browserStack.last != nil
    }

    var canCreateFolder: Bool {
        !isRunning && !hasExclusiveBackgroundTask
            && !isBrowsingSharedLink
            && hasUsableSession
            && browserStack.last != nil
    }

    func canRenameBrowserItem(_ item: BrowserItem) -> Bool {
        !isRunning && !hasExclusiveBackgroundTask
            && !isBrowsingSharedLink
            && hasUsableSession
            && browserItem(withID: item.id) != nil
            && !isExtractionSourceInUse(item)
    }

    var canRemoveDSStoreFiles: Bool {
        !isRunning && !hasExclusiveBackgroundTask
            && !isBrowsingSharedLink
            && hasUsableSession
            && browserStack.last != nil
    }

    var canScanCurrentFolderForDuplicates: Bool {
        !isRunning && !hasExclusiveBackgroundTask
            && !isBrowsingSharedLink
            && hasUsableSession
            && browserStack.last != nil
    }

    var selectedDuplicateFiles: [DuplicateFile] {
        guard let duplicateScan else { return [] }
        return duplicateScan.groups
            .flatMap(\.files)
            .filter { selectedDuplicateFileIDs.contains($0.id) }
    }

    var selectedDuplicateBytes: UInt64 {
        selectedDuplicateFiles.reduce(UInt64(0)) {
            addingWithoutOverflow($0, $1.size)
        }
    }

    var canDeleteSelectedDuplicates: Bool {
        !isRunning
            && !hasExclusiveBackgroundTask
            && hasUsableSession
            && !selectedDuplicateFileIDs.isEmpty
            && selectedDuplicateFileIDs.isDisjoint(with: Set(archiveTasks.filter(\.isBusy).map { $0.item.id }))
    }

    var previewPlaybackFraction: Double? {
        guard previewDurationSeconds > 0 else { return nil }
        return min(max(previewPlaybackSeconds / previewDurationSeconds, 0), 1)
    }

    var previewBufferedFraction: Double? {
        if previewUsesRetainedCache, previewRetainedTotalBytes > 0 {
            return min(
                max(Double(previewRetainedBytes) / Double(previewRetainedTotalBytes), 0),
                1
            )
        }
        guard previewDurationSeconds > 0 else { return nil }
        return min(max(previewBufferedSeconds / previewDurationSeconds, 0), 1)
    }

    var downloadProcessedFiles: Int {
        downloadCompletedFiles + downloadSkippedFiles + downloadFailedFiles
    }

    var activeDownloadCount: Int {
        activeDownloadTransfers.values.filter { transfer in
            switch transfer.state {
            case .preparing, .downloading, .retrying:
                return true
            case .queued, .completed, .skipped, .failed, .stopped:
                return false
            }
        }.count
    }

    var queuedDownloadTransfers: ArraySlice<DownloadTransfer> {
        downloadQueueTransfers.dropFirst(
            min(downloadQueueOffset, downloadQueueTransfers.count)
        )
    }

    var queuedDownloadCount: Int {
        max(downloadQueueTransfers.count - downloadQueueOffset, 0)
    }

    var pendingDownloadItemCount: Int {
        pendingDownloadItems.count
    }

    var canStartPendingDownloads: Bool {
        !pendingDownloadRequests.isEmpty
            && downloadProcess?.isRunning != true
            && !isDownloading
            && hasUsableSession
            && transferStateReady && !isClosingWindow
    }

    var canClearPendingDownloads: Bool {
        !pendingDownloadRequests.isEmpty
    }

    var successfulDownloadTransfers: [DownloadTransfer] {
        completedDownloadTransfers.filter {
            $0.state == .completed || $0.state == .skipped
        }
    }

    var downloadOverallFraction: Double? {
        if downloadRunState == .completed,
           downloadTotalFiles > 0 || downloadTotalBytes > 0 {
            return 1
        }
        if downloadTotalBytes > 0 {
            return min(Double(downloadDownloadedBytes) / Double(downloadTotalBytes), 1)
        }
        guard downloadTotalFiles > 0 else { return nil }
        let successfulFiles = downloadCompletedFiles + downloadSkippedFiles
        return min(Double(successfulFiles) / Double(downloadTotalFiles), 1)
    }

    var downloadRemainingBytes: UInt64 {
        if downloadRunState == .completed { return 0 }
        return downloadTotalBytes > downloadDownloadedBytes
            ? downloadTotalBytes - downloadDownloadedBytes
            : 0
    }

    var downloadEstimatedSecondsRemaining: TimeInterval? {
        guard downloadBytesPerSecond > 1, downloadRemainingBytes > 0 else { return nil }
        return Double(downloadRemainingBytes) / downloadBytesPerSecond
    }

    var uploadProcessedFiles: Int {
        uploadCompletedFiles + uploadInstantFiles + uploadFailedFiles
    }

    var activeUploadCount: Int {
        activeUploadTransfers.values.filter { transfer in
            switch transfer.state {
            case .hashing, .uploading, .retrying:
                return true
            case .queued, .instant, .completed, .failed, .stopped:
                return false
            }
        }.count
    }

    var queuedUploadTransfers: ArraySlice<UploadTransfer> {
        let start = min(uploadQueueOffset, uploadQueueTransfers.count)
        let end = min(
            start + Self.maximumVisibleUploadQueueRows,
            uploadQueueTransfers.count
        )
        return uploadQueueTransfers[start..<end]
    }

    var queuedUploadCount: Int {
        max(uploadQueueTransfers.count - uploadQueueOffset, 0)
    }

    var uploadOverallFraction: Double? {
        if uploadTotalBytes > 0 {
            return min(Double(uploadUploadedBytes) / Double(uploadTotalBytes), 1)
        }
        guard uploadTotalFiles > 0 else { return nil }
        return min(Double(uploadProcessedFiles) / Double(uploadTotalFiles), 1)
    }

    var uploadRemainingBytes: UInt64 {
        uploadTotalBytes > uploadUploadedBytes
            ? uploadTotalBytes - uploadUploadedBytes
            : 0
    }

    var uploadEstimatedSecondsRemaining: TimeInterval? {
        guard uploadRunState == .uploading,
              uploadBytesPerSecond > 1,
              uploadRemainingBytes > 0
        else { return nil }
        return Double(uploadRemainingBytes) / uploadBytesPerSecond
    }

    var canPauseUpload: Bool {
        isUploading && !isUploadPaused && uploadProcess?.isRunning == true
    }

    var canResumeUpload: Bool {
        isUploading && isUploadPaused && uploadProcess?.isRunning == true
    }

    var canRetryFailedDownloads: Bool {
        failedDownloadTransfers.contains(where: canRetryFailedDownload)
    }

    var selectedFolderMeasurement: FolderMeasurement? {
        guard let selectedBrowserItemID else { return nil }
        return cachedFolderMeasurement(for: selectedBrowserItemID)
    }

    var currentBrowserPath: String {
        browserStack.last?.path ?? "/"
    }

    var browserTreeEntries: [BrowserTreeEntry] {
        if let browserTreeEntriesCache { return browserTreeEntriesCache }
        #if BROWSER_SCROLL_PROFILING
        BrowserScrollDiagnostics.outlineBuilds += 1
        #endif
        var entries: [BrowserTreeEntry] = []
        var visitedFolderIDs = Set<String>()
        appendVisibleBrowserTreeEntries(
            browserItems,
            depth: 0,
            visitedFolderIDs: &visitedFolderIDs,
            entries: &entries
        )
        browserTreeEntriesCache = entries
        return entries
    }

    var visibleBrowserItemCount: Int {
        browserTreeEntries.count
    }

    var selectedBrowserItem: BrowserItem? {
        guard let selectedBrowserItemID else { return nil }
        return browserItem(withID: selectedBrowserItemID)
    }

    /// The footer follows selection through expanded rows, not just folders
    /// opened by double-click. Reuse the same complete ancestry as navigation.
    var browserFooterLocations: [BrowserLocation] {
        guard let item = selectedBrowserItem else { return browserStack }
        return browserNavigationStack(opening: item)
    }

    func navigateFooter(to location: BrowserLocation) {
        if browserStack.contains(location) { selectBreadcrumb(location) }
        else if let item = browserItem(withID: location.id), item.isFolder { openFolder(item) }
    }

    var selectedBrowserItems: [BrowserItem] {
        selectedBrowserItemIDs.compactMap { browserItem(withID: $0) }
    }

    /// A folder selection is one recursive action root. Any explicitly selected
    /// descendant is omitted because Download and Trash already include it.
    /// The action roots in no particular order. Callers that only need a count
    /// or an emptiness check use this and skip the path sort below, which the
    /// outline would otherwise pay for every row it builds while scrolling.
    var browserItemActionRoots: [BrowserItem] {
        selectedBrowserItems.filter { item in
            var parentID = browserItemParentIDs[item.id]
            while let candidate = parentID {
                if selectedBrowserItemIDs.contains(candidate),
                   browserItem(withID: candidate)?.isFolder == true {
                    return false
                }
                parentID = browserItemParentIDs[candidate]
            }
            return true
        }
    }

    var browserItemsSelectedForAction: [BrowserItem] {
        sortedByBrowserPath(browserItemActionRoots)
    }

    /// Resolves each path once instead of twice per comparison, because
    /// `localizedStandardCompare` over a rebuilt path string is the expensive
    /// part of ordering a large selection.
    private func sortedByBrowserPath(_ items: [BrowserItem]) -> [BrowserItem] {
        items
            .map { (path: browserPath(for: $0), item: $0) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .map(\.item)
    }

    var browserItemsSelectedForTrash: [BrowserItem] {
        browserItemsSelectedForAction
    }

    var browserActionSelectionCount: Int {
        isBrowsingSharedLink
            ? sharedBrowserSelectionGroups.reduce(0) { $0 + $1.items.count }
            : browserItemActionRoots.count
    }

    var browserSelectionIncludesFolders: Bool {
        isBrowsingSharedLink
            ? sharedBrowserSelectionGroups.contains { $0.items.contains(where: \.isFolder) }
            : browserItemActionRoots.contains(where: \.isFolder)
    }

    /// Merge is intentionally limited to sibling selection roots. Besides
    /// matching Finder's predictable behavior, this rules out attempting to
    /// merge a folder into one of its own descendants.
    var selectedFoldersForMerge: [BrowserItem] {
        let items = browserItemActionRoots
        guard items.count >= 2, items.allSatisfy(\.isFolder) else { return [] }
        return sortedByBrowserPath(items)
    }

    var canMergeSelectedFolders: Bool {
        let folders = selectedFoldersForMerge
        guard !isRunning,
              !hasExclusiveBackgroundTask,
              !isBrowsingSharedLink,
              hasUsableSession,
              folders.count >= 2
        else { return false }
        let parentIDs = Set(folders.map { browserItemParentIDs[$0.id] ?? $0.parentId ?? "" })
        return parentIDs.count == 1 && !folders.contains(where: isExtractionSourceInUse)
    }

    /// Returns true for an explicit row selection and for every known child of
    /// a selected folder. Children loaded later inherit this state immediately.
    func isBrowserItemSelected(_ itemID: String) -> Bool {
        selectionRootID(containing: itemID) != nil
    }

    func isBrowserItemSelected(_ itemID: String, in linkID: UUID?) -> Bool {
        guard let linkID else { return isBrowserItemSelected(itemID) }
        if isBrowsingSharedLink, activeSharedLinkID == linkID {
            return isBrowserItemSelected(itemID)
        }
        guard let workspace = sharedLinkSessions[linkID]?.workspace else { return false }
        var candidate: String? = itemID
        var visited = Set<String>()
        while let id = candidate, visited.insert(id).inserted {
            if workspace.selectedItemIDs.contains(id) { return true }
            candidate = workspace.parentIDs[id]
        }
        return false
    }

    /// Read only selected roots from each cached link. Reuse its item index;
    /// scrolling must not flatten every expanded tree to count a selection.
    private var sharedBrowserSelectionGroups: [SharedBrowserSelectionGroup] {
        sharedLinks.compactMap { link in
            if isBrowsingSharedLink, activeSharedLinkID == link.id {
                let items = browserItemActionRoots
                return items.isEmpty ? nil : .init(linkID: link.id, items: items)
            }
            guard let workspace = sharedLinkSessions[link.id]?.workspace,
                  !workspace.selectedItemIDs.isEmpty else { return nil }
            let index = sharedBrowserItemIndex(workspace)
            let items = workspace.selectedItemIDs.compactMap { id -> BrowserItem? in
                var parent = workspace.parentIDs[id]
                var visited = Set<String>()
                while let ancestor = parent, visited.insert(ancestor).inserted {
                    if workspace.selectedItemIDs.contains(ancestor), index[ancestor]?.isFolder == true {
                        return nil
                    }
                    parent = workspace.parentIDs[ancestor]
                }
                return index[id]
            }
            return items.isEmpty ? nil : .init(linkID: link.id, items: items)
        }
    }

    private func sharedBrowserItemIndex(_ workspace: BrowserWorkspaceSnapshot) -> [String: BrowserItem] {
        if let index = workspace.presentation.itemIndex { return index }
        var index: [String: BrowserItem] = [:]
        for children in workspace.childrenByFolderID.values {
            for item in children { index[item.id] = item }
        }
        for item in workspace.items { index[item.id] = item }
        workspace.presentation.itemIndex = index
        return index
    }

    private func clearInactiveSharedBrowserSelections(whenRestoring: Bool = false) {
        guard isBrowsingSharedLink || whenRestoring else { return }
        for id in sharedLinkSessions.keys where id != activeSharedLinkID {
            guard var session = sharedLinkSessions[id], var workspace = session.workspace,
                  !workspace.selectedItemIDs.isEmpty || workspace.selectedItemID != nil else { continue }
            workspace.selectedItemID = nil
            workspace.selectedItemIDs = []
            workspace.selectionAnchorID = nil
            session.workspace = workspace
            sharedLinkSessions[id] = session
        }
    }

    /// Shift follows the visible order across expanded URLs. Store the anchor
    /// with its link so identical file IDs in another share cannot move it.
    private func extendSharedBrowserSelection(to item: BrowserItem) {
        guard let linkID = activeSharedLinkID else { return }
        let target = SharedBrowserSelectionAnchor(linkID: linkID, itemID: item.id)
        let anchor = sharedBrowserSelectionAnchor ?? target
        let visible = sortedSharedLinks.filter { isSharedLinkExpanded($0.id) }.flatMap { link in
            sharedLinkTreeEntries(for: link.id).map {
                SharedBrowserSelectionAnchor(linkID: link.id, itemID: $0.item.id)
            }
        }
        guard let start = visible.firstIndex(of: anchor), let end = visible.firstIndex(of: target) else {
            updateBrowserSelection(to: item)
            return
        }
        let range = visible[min(start, end)...max(start, end)]
        let groups = Dictionary(grouping: range, by: \.linkID)
        clearInactiveSharedBrowserSelections()
        for (id, references) in groups where id != linkID {
            guard var session = sharedLinkSessions[id], var workspace = session.workspace else { continue }
            workspace.selectedItemIDs = Set(references.map(\.itemID))
            workspace.selectedItemID = references.last?.itemID
            workspace.selectionAnchorID = references.first?.itemID
            session.workspace = workspace
            sharedLinkSessions[id] = session
        }
        selectedBrowserItemIDs = Set((groups[linkID] ?? []).map(\.itemID))
        normalizeBrowserSelectionRoots()
        updateBrowserSelection(to: item, replacingSelection: false)
        sharedBrowserSelectionAnchor = anchor
        setBrowserSelectionStatus()
    }

    var emptyFolderCleanupScope: BrowserLocation {
        let actionRoots = browserItemActionRoots
        if actionRoots.count == 1,
           let item = actionRoots.first,
           item.isFolder {
            return BrowserLocation(id: item.id, name: item.name, path: browserPath(for: item))
        }
        return browserStack.last ?? .root
    }

    var dsStoreCleanupScope: BrowserLocation {
        emptyFolderCleanupScope
    }

    func isBrowserFolderExpanded(_ folderID: String) -> Bool {
        expandedBrowserFolderIDs.contains(folderID)
    }

    /// Assign a new Set value instead of mutating the published collection in
    /// place. This guarantees one coherent observation update for the outline:
    /// inserted children and the disclosure rotation consume the same snapshot.
    private func setBrowserFolderExpanded(_ folderID: String, expanded: Bool) {
        var updatedIDs = expandedBrowserFolderIDs
        if expanded {
            updatedIDs.insert(folderID)
        } else {
            updatedIDs.remove(folderID)
        }
        guard updatedIDs != expandedBrowserFolderIDs else { return }
        expandedBrowserFolderIDs = updatedIDs
    }

    func isBrowserFolderLoading(_ folderID: String) -> Bool {
        browserTreeLoadingFolderIDs.contains(folderID)
    }

    func browserFolderHasMoreItems(_ folderID: String) -> Bool {
        browserTreeNextPageTokens[folderID]?.isEmpty == false
    }

    func browserFolderIsLoadedAndEmpty(_ folderID: String) -> Bool {
        browserTreeChildren[folderID]?.isEmpty == true
            && !browserFolderHasMoreItems(folderID)
            && browserTreeLoadErrors[folderID] == nil
    }

    func browserLocation(for item: BrowserItem) -> BrowserLocation {
        BrowserLocation(id: item.id, name: item.name, path: browserPath(for: item))
    }

    /// Selecting a new Finder-style header sorts ascending. Clicking the
    /// active header reverses it. The preference is shared by account and
    /// link browsers and survives relaunches.
    func toggleBrowserSort(_ column: BrowserSortColumn) {
        if browserSortColumn == column {
            browserSortDirection.toggle()
        } else {
            browserSortColumn = column
            browserSortDirection = .ascending
        }
        UserDefaults.standard.set(browserSortColumn.rawValue, forKey: "browserSortColumn")
        UserDefaults.standard.set(browserSortDirection.rawValue, forKey: "browserSortDirection")
        applyBrowserSortToCachedItems()
        setStatus("Sorted by \(browserSortColumn.title), \(browserSortDirection.title)")
    }

    /// Finder-style row selection. Shift extends from the stable anchor while
    /// Command toggles an individual row without clearing the other rows.
    func selectBrowserItem(
        _ item: BrowserItem,
        extending: Bool = false,
        toggling: Bool = false,
        visibleItems: [BrowserItem]? = nil
    ) {
        guard canChangeBrowserSelection else { return }
        if extending {
            if isBrowsingSharedLink { extendSharedBrowserSelection(to: item) }
            else { extendBrowserSelection(to: item, visibleItems: visibleItems) }
        } else if toggling {
            toggleBrowserSelection(of: item)
        } else {
            updateBrowserSelection(to: item)
        }
    }

    /// Checkbox clicks are always additive, so users can build a selection
    /// without holding Command. A checked folder represents its complete remote
    /// subtree, including descendants that have not been loaded into the UI.
    func toggleBrowserCheckbox(_ item: BrowserItem) {
        guard canChangeBrowserSelection else { return }
        if let containingSelectionID = selectionRootID(containing: item.id) {
            // A folder is one recursive selection root. Remove the complete
            // explicit subtree as well, including any stale child roots that
            // may have been restored before their parent map was available.
            selectedBrowserItemIDs = Set(selectedBrowserItemIDs.filter { selectedID in
                selectedID != containingSelectionID
                    && !isBrowserItem(selectedID, descendantOf: containingSelectionID)
            })
            if selectedBrowserItemIDs.isEmpty {
                clearBrowserSelection()
                setBrowserSelectionStatus()
                return
            }

            if selectedBrowserItemID == nil
                || selectionRootID(containing: selectedBrowserItemID ?? "") == nil {
                selectFirstExplicitBrowserItem()
            }
        } else {
            selectedBrowserItemIDs.insert(item.id)
            removeExplicitDescendants(of: item)
            browserSelectionAnchorID = item.id
            if isBrowsingSharedLink, let linkID = activeSharedLinkID {
                sharedBrowserSelectionAnchor = .init(linkID: linkID, itemID: item.id)
            }
            updateBrowserSelection(to: item, replacingSelection: false)
        }
        setBrowserSelectionStatus()
    }

    func toggleBrowserFolderExpansion(_ item: BrowserItem) {
        guard item.isFolder else { return }

        if expandedBrowserFolderIDs.contains(item.id) {
            if let expansion = browserFolderExpansion,
               expansion.contains(item.id) || isBrowserItem(expansion.rootID, descendantOf: item.id) {
                cancelBrowserFolderExpansion(announcesResult: false)
            }
            setBrowserFolderExpanded(item.id, expanded: false)
            pendingBrowserTreeLoads.removeAll { $0.item.id == item.id }
            if !isActivelyLoadingBrowserTreeFolder(item.id) {
                browserTreeLoadingFolderIDs.remove(item.id)
            }
            cancelAutomaticPreviewNavigation()
            clearFolderMeasurement()
            setStatus("Collapsed \(item.name)")
            if isBrowsingSharedLink {
                saveActiveBrowserWorkspace()
            }
            return
        }

        setBrowserFolderExpanded(item.id, expanded: true)
        if browserTreeChildren[item.id] != nil {
            setStatus("Expanded \(item.name)")
        } else {
            requestBrowserTreeLoad(item, append: false)
        }
        if isBrowsingSharedLink {
            saveActiveBrowserWorkspace()
        }
    }

    func retryBrowserTreeFolder(_ item: BrowserItem) {
        guard item.isFolder, hasActiveBrowserAccess else { return }
        setBrowserFolderExpanded(item.id, expanded: true)
        requestBrowserTreeLoad(item, append: false)
    }

    func loadMoreBrowserTreeItems(in item: BrowserItem) {
        guard item.isFolder, hasActiveBrowserAccess, browserFolderHasMoreItems(item.id) else { return }
        requestBrowserTreeLoad(item, append: true)
    }

    var canExpandBrowserSubfolders: Bool { hasActiveBrowserAccess }

    func canExpandBrowserSubfolders(in linkID: UUID?) -> Bool {
        guard let linkID else { return canExpandBrowserSubfolders }
        return hasUsableSession && sharedLinkSessions[linkID]?.workspace != nil
            && sharedLinks.contains { $0.id == linkID && $0.state == .ready }
    }

    /// One level opens the selected folder and its immediate subfolders.
    /// nil means all levels. Existing deeper disclosures are never collapsed.
    func expandBrowserSubfolders(_ item: BrowserItem, levels: Int? = 1) {
        guard item.isFolder, hasActiveBrowserAccess, levels.map({ $0 > 0 }) ?? true else { return }
        cancelBrowserFolderExpansion(announcesResult: false)
        let plan = BrowserFolderExpansionPlan(rootID: item.id, rootName: item.name, levels: levels)
        browserFolderExpansion = plan
        browserFolderExpansionProgress = plan.progress
        setStatus(plan.progress.summary)
        scheduleBrowserFolderExpansion()
    }

    func cancelBrowserFolderExpansion(announcesResult: Bool = true) {
        guard let plan = browserFolderExpansion else { return }
        browserFolderExpansion = nil
        browserFolderExpansionTask?.cancel()
        browserFolderExpansionTask = nil
        let queuedIDs = pendingBrowserTreeLoads.filter { $0.expansionID == plan.id }.map { $0.item.id }
        pendingBrowserTreeLoads.removeAll { $0.expansionID == plan.id }
        let activeIDs = browserTreeLoadExpansionOwners.compactMap { $0.value == plan.id ? $0.key : nil }
        for folderID in activeIDs { cancelBrowserTreeLoad(folderID) }
        for folderID in queuedIDs where !isActivelyLoadingBrowserTreeFolder(folderID) {
            browserTreeLoadingFolderIDs.remove(folderID)
        }
        browserFolderExpansionProgress = nil
        if announcesResult {
            setStatus("Stopped expanding \(plan.rootName). Already opened folders are kept.")
            saveActiveBrowserWorkspace()
            startNextPendingBrowserTreeLoadIfNeeded()
        }
    }

    private func scheduleBrowserFolderExpansion() {
        guard browserFolderExpansionTask == nil, let plan = browserFolderExpansion else { return }
        let planID = plan.id
        browserFolderExpansionTask = Task { [weak self] in
            // Cached trees can contain thousands of folders. Yield between
            // small batches so scrolling, previews and Cancel remain usable.
            await Task.yield()
            guard !Task.isCancelled, let self, self.browserFolderExpansion?.id == planID else { return }
            self.browserFolderExpansionTask = nil
            self.advanceBrowserFolderExpansion()
        }
    }

    private func advanceBrowserFolderExpansion() {
        guard let plan = browserFolderExpansion else { return }
        for _ in 0..<64 {
            guard let folder = plan.nextFolder() else { break }
            guard let item = browserItem(withID: folder.id), item.isFolder else {
                plan.finish(folder.id, failed: true)
                continue
            }
            setBrowserFolderExpanded(folder.id, expanded: true)
            if isActivelyLoadingBrowserTreeFolder(folder.id)
                || pendingBrowserTreeLoads.contains(where: { $0.item.id == folder.id }) { continue }

            if let children = browserTreeChildren[folder.id] {
                plan.discoverChildren(of: folder.id, folderIDs: children.filter(\.isFolder).map(\.id))
                if !browserFolderHasMoreItems(folder.id) {
                    plan.finish(folder.id)
                    continue
                }
            }
            let append = browserTreeChildren[folder.id] != nil
            let token = append ? browserTreeNextPageTokens[folder.id] : nil
            guard plan.claimPage(for: folder.id, token: token) else {
                browserTreeLoadErrors[folder.id] = "PikPak repeated a folder page. Retry this folder to continue."
                plan.finish(folder.id, failed: true)
                continue
            }
            if !requestBrowserTreeLoad(item, append: append, expansionID: plan.id) {
                plan.finish(folder.id, failed: true)
            }
        }
        if plan.isFinished {
            browserFolderExpansion = nil
            browserFolderExpansionProgress = nil
            saveActiveBrowserWorkspace()
            let message = "Expanded \(plan.loadedFolders.formatted()) folders under \(plan.rootName)."
            if plan.failedFolders == 0 {
                setStatus(message)
            } else {
                setError(message + " \(plan.failedFolders.formatted()) folders could not be loaded; use Retry on those rows.")
            }
        } else {
            browserFolderExpansionProgress = plan.progress
            if plan.hasReadyFolders { scheduleBrowserFolderExpansion() }
        }
    }

    private func resumeBrowserFolderExpansion(after folderID: String) {
        guard let plan = browserFolderExpansion, plan.isWaiting(for: folderID) else { return }
        if browserTreeLoadErrors[folderID] != nil { plan.finish(folderID, failed: true) }
        else { plan.resume(folderID) }
        scheduleBrowserFolderExpansion()
    }

    /// Finder-style Left/Right Arrow behavior. Right expands a folder, then
    /// moves into its first child; Left collapses it, then moves to its parent.
    @discardableResult
    func moveBrowserTreeSelectionHorizontally(by offset: Int) -> String? {
        guard offset != 0,
              canChangeBrowserSelection,
              let selectedBrowserItem
        else { return nil }

        if offset > 0 {
            guard selectedBrowserItem.isFolder else { return selectedBrowserItem.id }
            if !expandedBrowserFolderIDs.contains(selectedBrowserItem.id) {
                toggleBrowserFolderExpansion(selectedBrowserItem)
                return selectedBrowserItem.id
            }
            if let firstChild = browserTreeChildren[selectedBrowserItem.id]?.first {
                updateBrowserSelection(to: firstChild)
                return firstChild.id
            }
            return selectedBrowserItem.id
        }

        if selectedBrowserItem.isFolder,
           expandedBrowserFolderIDs.contains(selectedBrowserItem.id) {
            setBrowserFolderExpanded(selectedBrowserItem.id, expanded: false)
            setStatus("Collapsed \(selectedBrowserItem.name)")
            return selectedBrowserItem.id
        }

        guard let parentID = browserItemParentIDs[selectedBrowserItem.id],
              parentID != browserStack.last?.id,
              let parent = browserItem(withID: parentID)
        else { return selectedBrowserItem.id }
        updateBrowserSelection(to: parent)
        return parent.id
    }

    private var hasToken: Bool {
        !refreshToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasUsableSession: Bool {
        hasToken && !requiresDedicatedSignIn && !isChangingAccount
    }

    private var hasActiveBrowserAccess: Bool {
        isBrowsingSharedLink
            ? shareAccess != nil && shareLinkIsOpen && hasUsableSession
            : hasUsableSession
    }

    var loginDeviceID: String { accountLoginDeviceID ?? deviceID }

    var activeSavedAccount: SavedPikPakAccount? { savedAccounts.first { $0.id == activeAccountID } }
    var hasAccountSession: Bool { hasToken && !requiresDedicatedSignIn }
    var canChangeAccount: Bool { accountStore != nil && !isClosingWindow && !accountWorkIsActive && !isCheckingAccount && !isChangingAccount && !isLoginPresented }
    var canCheckAccountStatus: Bool { hasAccountSession && !isClosingWindow && !isCheckingAccount && !isChangingAccount && !isLoginPresented }
    var accountChangeBlockedReason: String? {
        if isClosingWindow { return "Reopen My PikPak to manage accounts." }
        if accountWorkIsActive { return "Finish or stop active transfers, scans and file requests before changing accounts." }
        if isChangingAccount { return "Checking the account before switching…" }
        return nil
    }

    private var accountWorkIsActive: Bool {
        isRunning || hasBackgroundActivity || isSavingSharedItems
            || !sharedLinkLoadProcesses.isEmpty || !sharedSaveProcesses.isEmpty || !browserTreeLoadProcesses.isEmpty
            || !pendingSharedLinkLoads.isEmpty || sharedLinkRetryProgress != nil
            || !archiveProcesses.isEmpty || !pendingBrowserMoves.isEmpty || !pendingSharedSaveRequests.isEmpty
            || !fileOpener.activeNames.isEmpty
            || fileSearch.isScanning || fileSearch.isResolving || fileSimilarity.cloud.isRunning
    }

    private func applyAccounts(_ document: PikPakAccountsDocument) {
        savedAccounts = document.accounts
        activeAccountID = document.activeID
    }

    private func rememberVerifiedAccount(_ profile: PikPakAccountProfile) {
        if let accountStore {
            guard let activeAccountID else { return }
            do { applyAccounts(try accountStore.updateProfile(profile, for: activeAccountID)) }
            catch {
                accountSettingsError = error.localizedDescription
                accountLoginStatus = .unavailable
                return
            }
        }
        accountProfile = profile
        requiresDedicatedSignIn = false
        accountLoginStatus = .signedIn
    }

    func checkAccountStatus(automatically: Bool = false) {
        guard !isClosingWindow, !isCheckingAccount, !isChangingAccount, !isLoginPresented else { return }
        guard let store = accountStore, let account = activeSavedAccount, !account.needsSignIn, hasToken else {
            accountLoginStatus = activeSavedAccount?.needsSignIn == true ? .needsSignIn : .signedOut
            return
        }
        if automatically, accountLoginStatus == .signedIn, let checked = account.lastChecked,
           Date().timeIntervalSince(checked) < 60 { return }
        let generation = UUID()
        accountCheckGeneration = generation
        accountSettingsError = nil
        isCheckingAccount = true
        accountLoginStatus = .checking
        accountCheckTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.accountCheckGeneration == generation { self.isCheckingAccount = false; self.accountCheckTask = nil } }
            do {
                let profile = try await self.verifyAccount(store.files(for: account.id))
                try Task.checkCancellation()
                guard self.accountCheckGeneration == generation, self.activeAccountID == account.id, !self.isClosingWindow else { return }
                if let expected = account.profile?.sub, expected != profile.sub { throw PikPakAccountError.accountMismatch }
                self.rememberVerifiedAccount(profile)
                self.synchronizeSharedSessionFromDisk()
            } catch {
                guard !Task.isCancelled, self.accountCheckGeneration == generation, !self.isClosingWindow else { return }
                self.accountSettingsError = error.localizedDescription
                if let error = error as? PikPakAccountError,
                   error == .needsSignIn || error == .missingSession || error == .accountMismatch {
                    self.accountLoginStatus = .needsSignIn
                    self.requiresDedicatedSignIn = true
                } else { self.accountLoginStatus = .unavailable }
            }
        }
    }

    func beginAccountLogin(accountID: UUID? = nil) {
        guard canChangeAccount else { accountSettingsError = accountChangeBlockedReason; return }
        accountSettingsError = nil
        accountLoginTargetID = accountID
        // A fresh device identity belongs to the new desktop authorization.
        accountLoginDeviceID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        loginFromSettings = true
        isChangingAccount = true
        PikPakLoginDataStore.clearPikPakWebsiteData { [weak self] in
            guard let self, !self.isClosingWindow else { return }
            self.isChangingAccount = false
            self.presentLogin(reason: accountID == nil ? "Sign in to add a PikPak account to this Mac." : "Sign in to reconnect this PikPak account.", fromSettings: true)
        }
    }

    func switchAccount(to id: UUID) {
        guard id != activeAccountID, canChangeAccount, let store = accountStore,
              let selected = savedAccounts.first(where: { $0.id == id }) else { return }
        if selected.needsSignIn { beginAccountLogin(accountID: id); return }
        accountSettingsError = nil
        isCheckingAccount = true
        isChangingAccount = true
        let generation = UUID()
        accountCheckGeneration = generation
        accountCheckTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.accountCheckGeneration == generation {
                    self.isCheckingAccount = false; self.isChangingAccount = false; self.accountCheckTask = nil
                }
            }
            do {
                let files = store.files(for: id)
                let profile = try await self.verifyAccount(files)
                try Task.checkCancellation()
                guard self.accountCheckGeneration == generation, !self.isClosingWindow else { return }
                if let expected = selected.profile?.sub, expected != profile.sub { throw PikPakAccountError.accountMismatch }
                _ = try store.updateProfile(profile, for: id)
                let session = try files.load() // Includes any token rotated by verification.
                let document = try store.activate(id)
                self.finishAccountChange(document, session: session, profile: profile)
            } catch {
                guard !Task.isCancelled, !self.isClosingWindow else { return }
                self.accountSettingsError = error.localizedDescription
                if let error = error as? PikPakAccountError, error == .needsSignIn || error == .missingSession {
                    if let updated = try? store.logOut(id) { self.applyAccounts(updated) }
                }
            }
        }
    }

    func logOutAccount() {
        guard canChangeAccount, let store = accountStore, let id = activeAccountID else { return }
        accountSettingsError = nil
        do {
            let updated = try store.logOut(id)
            clearAccountWorkspace()
            applyAccounts(updated)
            refreshToken = ""; deviceID = ""; requiresDedicatedSignIn = false
            accountLoginStatus = .signedOut
            PikPakLoginDataStore.clearPikPakWebsiteData()
            setStatus("Logged out of PikPak on this Mac")
        } catch {
            accountSettingsError = error.localizedDescription
            if let updated = try? store.load(), updated.activeID != id {
                clearAccountWorkspace(); applyAccounts(updated)
                refreshToken = ""; requiresDedicatedSignIn = false; accountLoginStatus = .signedOut
            }
        }
    }

    private func verifyAccount(_ files: PikPakAccountSessionFiles) async throws -> PikPakAccountProfile {
        #if FINDER_WORKSPACE_TESTS
        if let accountProfileLoader { return try await accountProfileLoader(files) }
        #endif
        guard let engine = Bundle.main.url(forResource: "pikpak", withExtension: nil) else { throw PikPakAccountError.unavailable }
        let session = try files.load()
        var environment = desktopEngineEnvironment(tokenURL: files.tokenURL, lockURL: files.lockURL, deviceID: session.deviceID)
        let proxy = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
        environment["PIKPAK_PROXY"] = proxy.isEmpty ? nil : proxy
        return try await accountVerifier.verify(engineURL: engine, environment: environment)
    }

    private func clearAccountWorkspace() {
        pendingSharedLinkLoads = []
        sharedLinkRetryBatchIDs = []
        sharedLinkRetryProgress = nil
        sharedBrowserSelectionAnchor = nil
        clearTransferAccountContext()
        resetDownloadProgress(); downloadRunState = .ready
        failedDownloadTransfers = []
        lastAccountDownloadPaths = []; lastSharedDownloadItems = []
        lastSharedDownloadAccess = nil; lastDownloadUsedSharedLink = false
        downloadSharedAccessByFileID = [:]
        resetUploadProgress(destination: .root); uploadRunState = .ready; uploadDestination = nil
        mergeRequestedFolders = []; mergeDestination = nil; mergeCompletedSourceIDs = []
        resetFolderMergeProgress(sourceCount: 0, status: "No folder merge has been started.")
        duplicateScannedFiles = 0; duplicateScannedFolders = 0; duplicateDiscoveredFolders = 0
        duplicatePendingFolders = 0; duplicateFailedFolders = 0; duplicateCurrentPath = ""; duplicateScanRootPath = ""
        emptyFolderScannedFolders = 0; emptyFolderDiscoveredFolders = 0; emptyFolderCandidateCount = 0
        emptyFolderCheckedFolders = 0; emptyFolderRemovedFolders = 0; emptyFolderSkippedFolders = 0
        emptyFolderCurrentPath = ""; maintenanceStatus = ""
        fileSimilarity.cloud.clearAccount()
        taskActivity.reset(keeping: [.similarityLocal])
        fileUndoHistory.reset()
        uploadUndoMutations.removeAll()
        _ = cancelQuickLook()
        quickLookCopies.removeAll(); quickLookCopyOrder.removeAll()
        log = ""
        clearFolderMeasurementAccountContext()
        archiveTasks = []; selectedArchiveTaskID = nil
        extractionActivity.passwordRequest = nil
        extractionActivity.showsActivity = false
        extractionActivity.passwordPresentationIsClosing = false
        fileSearch.reset(); pendingFileSearchNavigation = nil
        cancelBrowserTreeLoads(); cancelAutomaticPreviewNavigation()
        clearPreview(); clearPreviewResourceCaches()
        accountBrowserWorkspace = nil; sharedBrowserWorkspace = nil
        browserSource = .account
        resetBrowserWorkspace(root: .root)
        shareAccess = nil; shareLinkIsOpen = false
        expandedSharedLinkIDs = []; selectedSharedLinkRootID = nil
        for index in sharedLinks.indices {
            let id = sharedLinks[index].id
            sharedLinks[index].savedItemCount = 0
            sharedLinks[index].state = .failed("Open this link to load it with the current account.")
            if let access = sharedLinkSessions[id]?.access {
                sharedLinkSessions[id] = SharedLinkSession(access: .init(url: access.url, passCode: access.passCode, passCodeToken: ""),
                    workspace: nil, savedItemIDs: [])
            }
        }
        persistSharedLinkStateSynchronously()
        storageQuota = nil; storageQuotaError = nil; isQuotaLoading = false; quotaRefreshPending = false
        duplicateScan = nil; selectedDuplicateFileIDs = []
        attemptedInitialBrowse = false
    }

    private func finishAccountChange(_ document: PikPakAccountsDocument, session: (token: String, deviceID: String), profile: PikPakAccountProfile) {
        clearAccountWorkspace()
        applyAccounts(document)
        refreshToken = session.token; deviceID = session.deviceID
        requiresDedicatedSignIn = false
        adoptTransferAccount(profile.sub)
        accountProfile = profile; accountLoginStatus = .signedIn
        isChangingAccount = false
        setStatus("Signed in as \(profile.displayName ?? "PikPak account")")
        #if FINDER_WORKSPACE_TESTS
        if isFinderWorkspaceFixture { return }
        #endif
        if pendingSharedLinkOpenAfterLogin {
            pendingSharedLinkOpenAfterLogin = false
            openSharedLink()
            refreshQuota()
            return
        }
        attemptedInitialBrowse = true
        loadRoot()
    }

    private var isPreviewEngineRunning: Bool {
        guard isRunning, let operation else { return false }
        if case .preview = operation {
            return true
        }
        if case .sharePreview = operation {
            return true
        }
        return false
    }

    private var isBrowserTreeEngineRunning: Bool {
        guard isRunning, let operation else { return false }
        if case .browseTree = operation {
            return true
        }
        if case .shareBrowseTree = operation {
            return true
        }
        return false
    }

    func forgetToken() { logOutAccount() }

    func chooseOutputFolder() {
        guard !isDownloading else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Download Folder"
        panel.prompt = "Choose"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = outputURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputURL = url
        UserDefaults.standard.set(url.path, forKey: "outputPath")
    }

    func openOutputFolder() {
        try? FileManager.default.createDirectory(
            at: outputURL,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.open(outputURL)
    }

    /// Ask for local files and folders and immediately upload them into the
    /// destination selected in Transfers (or the last account-browser folder
    /// when no explicit choice has been made).
    @discardableResult
    func chooseFilesToUpload() -> Bool {
        presentUploadSourcePanel(destination: effectiveUploadDestination)
    }

    /// Browser's Upload button always targets the folder currently open there,
    /// irrespective of a destination previously selected in Transfers.
    @discardableResult
    func chooseFilesToUploadInCurrentBrowserFolder() -> Bool {
        guard !isBrowsingSharedLink, let destination = browserStack.last else {
            return false
        }
        return presentUploadSourcePanel(destination: destination)
    }

    /// Start the normal high-throughput uploader with files or complete folder
    /// trees dropped from Finder. The destination is captured when the drag is
    /// accepted so navigating immediately after a drop cannot retarget it.
    @discardableResult
    func uploadDroppedLocalItems(_ items: [URL], to destination: BrowserLocation,
                                 expectedAccountID: String? = nil) -> Bool {
        // The drop delegate already validated an account destination. Do not
        // reinterpret it if the user changes tabs while Finder supplies URLs.
        guard expectedAccountID == nil || expectedAccountID == transferAccountID else {
            reportBrowserDropFailure("The account changed while Finder supplied the files. Drop them again into the intended account.")
            return false
        }
        guard canUploadFiles else {
            setError("Another upload or conflicting folder change is active. Wait for it to finish, then drop the files again.")
            return false
        }

        let localItems: [URL]
        do {
            localItems = try LocalUploadFileURLLoader.validatedRoots(items)
        } catch {
            reportBrowserDropFailure(error)
            return false
        }

        return startUpload(files: localItems, destination: destination)
    }

    func setUploadDestination(_ destination: BrowserLocation) {
        guard canChooseUploadDestination else { return }
        uploadDestination = destination
        setStatus("Upload destination set to \(destination.path)")
    }

    @discardableResult
    private func presentUploadSourcePanel(destination: BrowserLocation) -> Bool {
        guard canUploadFiles else { return false }
        let panel = NSOpenPanel()
        panel.title = "Upload Files and Folders to \(destination.name)"
        panel.message = "Folders keep their structure when uploaded to \(destination.path)."
        panel.prompt = "Upload"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = true
        panel.resolvesAliases = true
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return false }
        return startUpload(files: panel.urls, destination: destination)
    }

    @discardableResult
    private func startUpload(
        files: [URL],
        destination: BrowserLocation,
        preservingFailedHistory: Bool = false,
        resumingBatch: SavedUploadBatch? = nil
    ) -> Bool {
        guard canUploadFiles, !files.isEmpty else { return false }
        #if BROWSER_DROP_TESTS
        if isBrowserDropFixture {
            recordedDropUploads.append((files, destination))
            setStatus("TEST upload accepted: \(files.count) item(s) to \(destination.path)")
            return true
        }
        #endif
        let resolvedUploadConcurrentJobs = effectiveUploadConcurrentJobs
        guard let accountID = transferAccountID else { return false }
        var batch = resumingBatch ?? SavedUploadBatch(
            id: UUID(), sources: files.map(\.path), destination: destination,
            workers: resolvedUploadConcurrentJobs, createdAt: Date()
        )
        // A resumed process is a new run. Keep its identity/checkpoints but use
        // the current shared limit, just like a waiting download batch.
        batch.workers = resolvedUploadConcurrentJobs
        let checkpointDirectory: URL
        do {
            checkpointDirectory = try transferStore().uploadDirectory(accountID: accountID, batchID: batch.id)
        } catch {
            setError("Cannot save this upload for resume: \(error.localizedDescription)")
            return false
        }
        if let index = savedUploadBatches.firstIndex(where: { $0.id == batch.id }) {
            savedUploadBatches[index] = batch
        } else { savedUploadBatches.append(batch) }
        guard persistTransfersSynchronously() else { return false }
        activeUploadBatchID = batch.id
        resetUploadProgress(
            destination: destination,
            preservingFailedHistory: preservingFailedHistory
        )
        UserDefaults.standard.set(proxyURL, forKey: "proxyURL")
        runUploadEngine(
            arguments: [
                "upload",
                "--parent-id", destination.id,
                "--jobs", String(resolvedUploadConcurrentJobs),
                "--checkpoint-dir", checkpointDirectory.path,
                "--progress-json",
            ],
            destination: destination,
            files: files
        )
        if !isUploading { activeUploadBatchID = nil }
        return isUploading
    }

    func canRetryFailedUpload(_ transfer: UploadTransfer) -> Bool {
        guard transfer.state == .failed,
              canUploadFiles,
              let sourcePath = transfer.sourcePath else { return false }
        return FileManager.default.fileExists(atPath: sourcePath)
    }

    /// Retry one failed local file in the exact cloud folder selected by the
    /// original recursive upload. Successful/other failed history stays visible
    /// so a large batch can be repaired one row at a time.
    func retryFailedUpload(_ transfer: UploadTransfer) {
        guard canRetryFailedUpload(transfer),
              let sourcePath = transfer.sourcePath else { return }
        let parentID = transfer.remoteParentID ?? uploadDestination?.id ?? ""
        let fallbackDestination = uploadDestination ?? .root
        let destination = BrowserLocation(
            id: parentID,
            name: fallbackDestination.name,
            path: fallbackDestination.path
        )
        failedUploadTransfers.removeAll {
            $0.sourcePath == sourcePath && $0.remoteParentID == transfer.remoteParentID
        }
        _ = startUpload(
            files: [URL(fileURLWithPath: sourcePath)],
            destination: destination,
            preservingFailedHistory: true
        )
    }

    func stopUpload() {
        guard isUploading, let uploadProcess, uploadProcess.isRunning else { return }
        uploadRequestedStop = true
        if isUploadPaused {
            // SIGTERM remains pending for a suspended child. Resume it first
            // so cancellation and its termination handler complete promptly.
            _ = uploadProcess.resume()
            isUploadPaused = false
        }
        uploadRunState = .stopping
        if !isRunning {
            setStatus("Stopping upload safely…")
        }
        uploadProcess.terminate()
    }

    func pauseUpload() {
        guard canPauseUpload, let uploadProcess else { return }
        uploadStateBeforePause = effectiveActiveUploadState()
        guard uploadProcess.suspend() else {
            setError("The upload could not be paused. It is still running.")
            return
        }
        isUploadPaused = true
        uploadRunState = .paused
        uploadBytesPerSecond = 0
        uploadHashBytesPerSecond = 0
        resetUploadSpeedBaseline()
        if !isRunning {
            setStatus("Upload paused. You can continue browsing your PikPak files.")
        }
    }

    func resumeUpload() {
        guard canResumeUpload, let uploadProcess else { return }
        guard uploadProcess.resume() else {
            setError("The paused upload could not be resumed.")
            return
        }
        isUploadPaused = false
        uploadRunState = uploadStateBeforePause == .uploading ? .uploading : effectiveActiveUploadState()
        resetUploadSpeedBaseline()
        ensureTransferMetricsTask()
        if !isRunning {
            setStatus(uploadRunState == .uploading ? "Upload resumed" : "Preparing files after pause…")
        }
    }

    func testConnection() {
        guard canTestConnection, validateConfiguration() else { return }
        runEngine(
            arguments: ["quota", "--json", "--with-profile"],
            operation: .quota(announcesResult: true)
        )
    }

    func refreshQuota() {
        guard hasUsableSession else {
            storageQuota = nil
            storageQuotaError = "Sign in to view PikPak storage."
            return
        }
        guard !isQuotaLoading else { return }
        isQuotaLoading = true
        quotaRefreshPending = true
        startPendingQuotaRefreshIfNeeded()
    }

    /// Switch between the account browser and the read-only public-link
    /// browser while preserving each workspace's navigation, expansion, and
    /// selection state independently.
    @discardableResult
    func activateAccountBrowser() -> Bool {
        switchBrowserSource(to: .account)
    }

    @discardableResult
    func activateSharedLinkBrowser() -> Bool {
        switchBrowserSource(to: .sharedLink)
    }

    func openSharedLink() {
        let rawURL = shareURLInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawURL.isEmpty else {
            setShareLinkFeedback("Paste a PikPak shared link first.", tone: .error)
            return
        }
        guard !isRunning else {
            setShareLinkFeedback("Wait for the current request to finish, then open the link again.", tone: .error)
            return
        }
        guard hasUsableSession else {
            pendingSharedLinkOpenAfterLogin = true
            setShareLinkFeedback(
                "Sign in to connect this link to your PikPak account. It will open automatically afterward.",
                tone: .info
            )
            presentLogin(reason: "Sign in so shared links can open with this app's independent PikPak session and be saved to your account.")
            return
        }
        let passcode = sharePasscodeInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = sharedLinks.first(where: { entry in
            entry.url.caseInsensitiveCompare(rawURL) == .orderedSame
        }) {
            if case .failed = existing.state,
               !passcode.isEmpty,
               var session = sharedLinkSessions[existing.id] {
                session.access = ShareAccessInput(
                    url: session.access.url,
                    passCode: passcode,
                    passCodeToken: ""
                )
                sharedLinkSessions[existing.id] = session
            }
            activateSharedLink(existing.id)
            if case .failed = existing.state {
                retrySharedLink(existing.id)
            } else {
                setShareLinkFeedback(
                    "That link is already in Links. Its saved browser position has been restored.",
                    tone: .info
                )
            }
            return
        }

        guard activateSharedLinkBrowser() else { return }
        if isBrowsingSharedLink {
            saveActiveBrowserWorkspace()
        }
        let access = ShareAccessInput(
            url: rawURL,
            passCode: passcode,
            passCodeToken: ""
        )
        let linkID = UUID()
        sharedLinks.append(
            SharedLinkEntry(
                id: linkID,
                url: rawURL,
                name: suggestedSharedLinkName(for: rawURL),
                state: .loading,
                savedItemCount: 0,
                addedAt: Date()
            )
        )
        sharedLinkSessions[linkID] = SharedLinkSession(
            access: access,
            workspace: nil,
            savedItemIDs: []
        )
        activeSharedLinkID = linkID
        selectedSharedLinkRootID = linkID
        expandedSharedLinkIDs.insert(linkID)
        shareAccess = access
        shareLinkIsOpen = false
        pendingSharedLinkOpenAfterLogin = false
        isOpeningShareLink = true
        setShareLinkFeedback("Opening this link with your private app session…", tone: .progress)
        UserDefaults.standard.set(rawURL, forKey: "lastShareURL")
        resetBrowserWorkspace(root: .sharedRoot)
        sharedBrowserWorkspace = nil
        shareURLInput = ""
        sharePasscodeInput = ""
        persistSharedLinkState()
        let request = ShareBrowseInput(
            access: access,
            parentId: nil,
            pageToken: nil,
            limit: 200
        )
        runInitialSharedLinkLoad(linkID: linkID, request: request)
    }

    func closeSharedLink() {
        guard let activeSharedLinkID else { return }
        removeSharedLink(activeSharedLinkID)
    }

    func activateSharedLink(_ linkID: UUID) {
        // Re-activating the current context must not restore an older cached
        // selection or cancel folder loads already running for this link.
        if isBrowsingSharedLink, activeSharedLinkID == linkID { return }
        guard !isRunning,
              let session = sharedLinkSessions[linkID],
              let entry = sharedLinks.first(where: { $0.id == linkID })
        else { return }

        if activeSharedLinkID != linkID { _ = cancelQuickLook() }

        // The active session controls which cached tree/API context is in use;
        // it is deliberately separate from the Finder-style selected row.
        // A context switch should not leave the previous URL painted blue.
        selectedSharedLinkRootID = nil
        if isBrowsingSharedLink {
            saveActiveBrowserWorkspace()
        } else if !activateSharedLinkBrowser() {
            return
        }

        activeSharedLinkID = linkID
        expandedSharedLinkIDs.insert(linkID)
        shareAccess = session.access
        sharedBrowserWorkspace = session.workspace
        shareLinkIsOpen = entry.state == .ready && session.workspace != nil
        isOpeningShareLink = entry.state == .loading
        if let workspace = session.workspace {
            restoreBrowserWorkspace(workspace)
        } else {
            resetBrowserWorkspace(root: .sharedRoot)
        }
        switch entry.state {
        case .ready:
            setShareLinkFeedback(
                "Restored \(entry.name) at its previous location.",
                tone: .success
            )
        case .loading:
            setShareLinkFeedback("\(entry.name) is still loading.", tone: .progress)
        case .failed(let message):
            setShareLinkFeedback("Could not open \(entry.name). \(message)", tone: .error)
        }
        setStatus(shareLinkIsOpen ? "Shared-link browser ready" : "Shared link selected")
        persistSharedLinkState()
    }

    /// Select a virtual shared-link root without conflating that visual
    /// selection with the session that remains active for its child tree.
    func selectSharedLinkRoot(_ linkID: UUID) {
        guard sharedLinks.contains(where: { $0.id == linkID }) else { return }
        if !isBrowsingSharedLink || activeSharedLinkID != linkID {
            activateSharedLink(linkID)
        }
        guard isBrowsingSharedLink, activeSharedLinkID == linkID else { return }

        clearInactiveSharedBrowserSelections()
        sharedBrowserSelectionAnchor = nil
        clearBrowserSelection()
        selectedSharedLinkRootID = linkID
        setStatus("Shared link selected")
        saveActiveBrowserWorkspace()
        persistSharedLinkState()
    }

    func retrySharedLink(_ linkID: UUID) {
        guard !isRunning, !isClosingWindow, !isChangingAccount,
              sharedLinkLoadProcesses[linkID] == nil,
              !pendingSharedLinkLoads.contains(where: { $0.linkID == linkID }),
              var session = sharedLinkSessions[linkID]
        else { return }
        guard hasUsableSession else {
            presentLogin(reason: "Sign in to retry this shared link.")
            return
        }
        activateSharedLink(linkID)
        updateSharedLink(linkID) { entry in
            entry.state = .loading
        }
        session.workspace = nil
        sharedLinkSessions[linkID] = session
        expandedSharedLinkIDs.insert(linkID)
        sharedBrowserWorkspace = nil
        shareAccess = session.access
        shareLinkIsOpen = false
        isOpeningShareLink = true
        resetBrowserWorkspace(root: .sharedRoot)
        setShareLinkFeedback("Retrying this shared link…", tone: .progress)
        persistSharedLinkState()
        let request = ShareBrowseInput(
            access: session.access,
            parentId: nil,
            pageToken: nil,
            limit: 200
        )
        runInitialSharedLinkLoad(linkID: linkID, request: request)
    }

    /// Snapshot failed roots once. Preparing their requests together preserves
    /// the active workspace and prevents another click from enqueuing duplicates.
    func retryAllFailedSharedLinks() {
        guard canRetryFailedSharedLinks else { return }
        guard hasUsableSession else {
            setShareLinkFeedback("Sign in, then choose Retry Failed Links.", tone: .info)
            presentLogin(reason: "Sign in to retry your failed shared links.")
            return
        }
        let ids = sharedLinks.compactMap { entry -> UUID? in
            guard case .failed = entry.state,
                  sharedLinkSessions[entry.id] != nil,
                  sharedLinkLoadProcesses[entry.id] == nil,
                  !pendingSharedLinkLoads.contains(where: { $0.linkID == entry.id })
            else { return nil }
            return entry.id
        }
        guard !ids.isEmpty else { return }
        sharedLinkRetryBatchIDs = Set(ids)
        sharedLinkRetryProgress = .init(completed: 0, total: ids.count)
        for index in sharedLinks.indices where sharedLinkRetryBatchIDs.contains(sharedLinks[index].id) {
            let id = sharedLinks[index].id
            guard var session = sharedLinkSessions[id] else { continue }
            session.workspace = nil
            sharedLinkSessions[id] = session
            sharedLinks[index].state = .loading
            expandedSharedLinkIDs.insert(id)
            pendingSharedLinkLoads.append((id, ShareBrowseInput(
                access: session.access, parentId: nil, pageToken: nil, limit: 200
            )))
        }
        if isBrowsingSharedLink, let activeSharedLinkID, sharedLinkRetryBatchIDs.contains(activeSharedLinkID) {
            sharedBrowserWorkspace = nil
            shareLinkIsOpen = false
            resetBrowserWorkspace(root: .sharedRoot)
        }
        refreshActiveSharedLinkLoadingState()
        let noun = ids.count == 1 ? "link" : "links"
        setShareLinkFeedback("Retrying \(ids.count.formatted()) failed \(noun)…", tone: .progress)
        setStatus("Retrying \(ids.count.formatted()) failed shared \(noun)…")
        persistSharedLinkState()
        startPendingSharedLinkLoads()
    }

    private func refreshSharedLinkRetryProgress() {
        guard !sharedLinkRetryBatchIDs.isEmpty else { return }
        let entries = sharedLinks.filter { sharedLinkRetryBatchIDs.contains($0.id) }
        let total = sharedLinkRetryBatchIDs.count
        let loading = entries.filter { $0.state == .loading }.count
        guard loading == 0 else {
            sharedLinkRetryProgress = .init(completed: total - loading, total: total)
            return
        }
        let opened = entries.filter { $0.state == .ready }.count
        let failed = entries.count - opened
        let removed = total - entries.count
        sharedLinkRetryBatchIDs = []
        sharedLinkRetryProgress = nil
        guard !isClosingWindow else { return }
        var message = "Retry complete: \(opened.formatted()) opened, \(failed.formatted()) still failed."
        if removed > 0 { message += " \(removed.formatted()) disconnected." }
        setShareLinkFeedback(message, tone: failed > 0 ? .error : .success)
        setStatus(message)
    }

    /// Editing repoints an existing row, so it needs the same quiet state that
    /// disconnecting does plus no in-flight load for this link.
    func canEditSharedLink(_ linkID: UUID) -> Bool {
        // Unlike Disconnect, editing reopens the link through the engine, so it
        // still needs the foreground lane to be free.
        !isRunning
            && canDisconnectSharedLink(linkID)
            && sharedLinkLoadProcesses[linkID] == nil
            && !pendingSharedLinkLoads.contains(where: { $0.linkID == linkID })
            && sharedLinks.contains { $0.id == linkID }
    }

    func sharedLinkAccessCode(for linkID: UUID) -> String {
        sharedLinkSessions[linkID]?.access.passCode ?? ""
    }

    /// Repoint one link at a new URL and/or access code, then reopen it. The
    /// row keeps its identity, position, and added date.
    func editSharedLink(_ linkID: UUID, url rawURL: String, passCode rawPassCode: String) {
        guard canEditSharedLink(linkID),
              let index = sharedLinks.firstIndex(where: { $0.id == linkID }),
              var session = sharedLinkSessions[linkID]
        else { return }

        let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let passCode = rawPassCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            setShareLinkFeedback("Enter a PikPak shared link.", tone: .error)
            return
        }
        guard !sharedLinks.contains(where: { other in
            other.id != linkID && other.url.caseInsensitiveCompare(url) == .orderedSame
        }) else {
            setShareLinkFeedback(
                "Another link in this list already uses that URL.",
                tone: .error
            )
            return
        }

        let urlChanged = sharedLinks[index].url.caseInsensitiveCompare(url) != .orderedSame
        let passCodeChanged = session.access.passCode != passCode
        guard urlChanged || passCodeChanged else {
            setShareLinkFeedback("That link is already up to date.", tone: .info)
            return
        }

        // The stored token was issued for the previous URL and code, so it is
        // never carried across an edit.
        session.access = ShareAccessInput(url: url, passCode: passCode, passCodeToken: "")
        session.workspace = nil
        if urlChanged {
            // Saved-item markers and cached folder sizes describe the previous
            // share; keeping them would show false checkmarks and wrong totals.
            session.savedItemIDs = []
            pendingSharedSaveRequests.removeAll { $0.linkID == linkID }
            savingSharedItemIDsByLinkID.removeValue(forKey: linkID)
            removeSharedLinkMeasurements(linkID)
            sharedLinks[index].savedItemCount = 0
            sharedLinks[index].name = suggestedSharedLinkName(for: url)
        }
        sharedLinks[index].url = url
        sharedLinkSessions[linkID] = session
        persistSharedLinkState()

        retrySharedLink(linkID)
        setShareLinkFeedback(
            urlChanged
                ? "Updated this link. Opening it…"
                : "Updated this link's access code. Opening it…",
            tone: .progress
        )
    }

    /// Copy one shared link's public `/s/` URL to the clipboard. Only the URL
    /// is copied; any access code stays in the app's owner-only local state so
    /// pasting a link elsewhere cannot leak it.
    func copySharedLinkURL(_ linkID: UUID) {
        guard let entry = sharedLinks.first(where: { $0.id == linkID }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.url, forType: .string)
        setStatus("Copied the shared link to the clipboard")
    }

    func removeSharedLink(_ linkID: UUID) {
        guard canDisconnectSharedLink(linkID) else { return }
        defer { startPendingSharedLinkLoads() }
        pendingSharedLinkLoads.removeAll { $0.linkID == linkID }
        if let process = sharedLinkLoadProcesses.removeValue(forKey: linkID),
           process.isRunning {
            process.terminate()
        }
        if let inputURL = sharedLinkLoadInputURLs.removeValue(forKey: linkID) {
            try? FileManager.default.removeItem(at: inputURL)
        }
        sharedLinkLoadsStoppedForLogin.remove(linkID)
        let wasActive = activeSharedLinkID == linkID
        if wasActive, isBrowsingSharedLink {
            saveActiveBrowserWorkspace()
        }
        sharedLinks.removeAll { $0.id == linkID }
        sharedLinkSessions.removeValue(forKey: linkID)
        pendingSharedSaveRequests.removeAll { $0.linkID == linkID }
        savingSharedItemIDsByLinkID.removeValue(forKey: linkID)
        removeSharedLinkMeasurements(linkID)
        expandedSharedLinkIDs.remove(linkID)
        if selectedSharedLinkRootID == linkID {
            selectedSharedLinkRootID = nil
        }

        guard wasActive else {
            setShareLinkFeedback("Removed the link from this app.", tone: .info)
            persistSharedLinkState()
            return
        }

        activeSharedLinkID = nil
        shareAccess = nil
        shareLinkIsOpen = false
        isOpeningShareLink = false
        isSavingSharedItems = sharedSaveProcesses.values.contains(where: { $0.isRunning })
        sharedBrowserWorkspace = nil
        if let next = sharedLinks.first {
            activateSharedLink(next.id)
        } else {
            resetBrowserWorkspace(root: .sharedRoot)
            setShareLinkFeedback("The link was removed from this app.", tone: .info)
            setStatus("Add a PikPak shared-folder URL to browse it")
            persistSharedLinkState()
        }
        refreshActiveSharedLinkLoadingState()
    }

    private func suggestedSharedLinkName(for rawURL: String) -> String {
        guard let url = URL(string: rawURL) else { return "Shared Link" }
        let component = url.pathComponents.last(where: { $0 != "/" }) ?? ""
        return component.isEmpty ? "Shared Link" : "Shared Link • \(component.prefix(8))"
    }

    private func updateSharedLink(_ linkID: UUID, _ update: (inout SharedLinkEntry) -> Void) {
        guard let index = sharedLinks.firstIndex(where: { $0.id == linkID }) else { return }
        update(&sharedLinks[index])
        persistSharedLinkState()
    }

    private func setShareLinkFeedback(_ message: String?, tone: ShareLinkFeedbackTone) {
        shareLinkFeedbackMessage = message
        shareLinkFeedbackTone = tone
    }

    private func restorePersistedSharedLinks() {
        do {
            guard let document = try SharedLinksStateStore.load() else {
                restorePendingSharedLinkURLMigration()
                return
            }
            guard document.version == SharedLinksStateStore.schemaVersion else { return }

            var restoredEntries: [SharedLinkEntry] = []
            var restoredSessions: [UUID: SharedLinkSession] = [:]
            var seenIDs = Set<UUID>()
            var seenURLs = Set<String>()
            for record in document.records.prefix(SharedLinksStateStore.maximumLinks) {
                let normalizedURL = record.entry.url
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let urlKey = normalizedURL.lowercased()
                guard
                    isSupportedPersistedSharedLinkURL(normalizedURL),
                    seenIDs.insert(record.entry.id).inserted,
                    seenURLs.insert(urlKey).inserted
                else { continue }

                var entry = record.entry
                if record.session.workspace != nil {
                    // A process killed while the link was refreshing may have
                    // left a loading marker beside a complete prior tree.
                    if case .loading = entry.state {
                        entry.state = .ready
                    }
                } else {
                    switch entry.state {
                    case .ready, .loading:
                        entry.state = .failed("Select Retry to reload this link.")
                    case .failed:
                        break
                    }
                }
                entry.savedItemCount = record.session.savedItemIDs.count
                restoredEntries.append(entry)
                restoredSessions[entry.id] = record.session
            }

            sharedLinks = restoredEntries
            sharedLinkSessions = restoredSessions
            let restoredIDs = Set(restoredEntries.map(\.id))
            expandedSharedLinkIDs = document.expandedLinkIDs.intersection(restoredIDs)
            activeSharedLinkID = document.activeLinkID.flatMap {
                restoredIDs.contains($0) ? $0 : nil
            } ?? restoredEntries.first?.id
            selectedSharedLinkRootID = document.selectedRootLinkID.flatMap {
                restoredIDs.contains($0) ? $0 : nil
            }
            // Older builds remembered independent, visually inactive
            // selections. They must not become a new batch-save selection.
            if document.usesUnifiedSelection != true {
                clearInactiveSharedBrowserSelections(whenRestoring: true)
            }
            if let activeSharedLinkID,
               let session = restoredSessions[activeSharedLinkID] {
                shareAccess = session.access
                sharedBrowserWorkspace = session.workspace
            }
            if !restoredEntries.isEmpty {
                appendOutput(
                    "Restored \(restoredEntries.count.formatted()) saved shared link(s) from local state.\n"
                )
            }
        } catch {
            appendOutput(
                "Warning: saved shared links could not be restored: \(error.localizedDescription)\n"
            )
        }
    }

    /// Build 83 and earlier held every added link only in RAM. The installer
    /// can place those still-visible URLs in one private, one-shot preference
    /// so this first persistence-capable build does not discard the user's
    /// current list while replacing the running app.
    private func restorePendingSharedLinkURLMigration() {
        let key = "pendingSharedLinkURLMigrationV1"
        let defaults = UserDefaults.standard
        guard
            let encoded = defaults.string(forKey: key),
            let data = Data(base64Encoded: encoded),
            let migration = try? JSONDecoder().decode(
                PendingSharedLinkURLMigration.self,
                from: data
            )
        else { return }

        var entries: [SharedLinkEntry] = []
        var sessions: [UUID: SharedLinkSession] = [:]
        var seenURLs = Set<String>()
        for rawURL in migration.urls.prefix(SharedLinksStateStore.maximumLinks) {
            let url = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard
                isSupportedPersistedSharedLinkURL(url),
                seenURLs.insert(url.lowercased()).inserted
            else { continue }
            let id = UUID()
            entries.append(
                SharedLinkEntry(
                    id: id,
                    url: url,
                    name: suggestedSharedLinkName(for: url),
                    state: .failed("Select Retry to reload this preserved link."),
                    savedItemCount: 0,
                    addedAt: Date()
                )
            )
            sessions[id] = SharedLinkSession(
                access: ShareAccessInput(url: url, passCode: "", passCodeToken: ""),
                workspace: nil,
                savedItemIDs: []
            )
        }
        guard !entries.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }

        sharedLinks = entries
        sharedLinkSessions = sessions
        let requestedIndex = migration.activeIndex ?? 0
        let activeIndex = min(max(requestedIndex, 0), entries.count - 1)
        activeSharedLinkID = entries[activeIndex].id
        shareAccess = sessions[entries[activeIndex].id]?.access
        persistSharedLinkStateSynchronously()
        defaults.removeObject(forKey: key)
        appendOutput(
            "Preserved \(entries.count.formatted()) shared link URL(s) from the previous build.\n"
        )
    }

    private func persistedSharedLinksDocument() -> PersistedSharedLinksDocument {
        let records = sharedLinks
            .prefix(SharedLinksStateStore.maximumLinks)
            .compactMap { entry -> PersistedSharedLinkRecord? in
                guard let session = sharedLinkSessions[entry.id] else { return nil }
                return PersistedSharedLinkRecord(entry: entry, session: session)
            }
        let persistedIDs = Set(records.map { $0.entry.id })
        return PersistedSharedLinksDocument(
            version: SharedLinksStateStore.schemaVersion,
            activeLinkID: activeSharedLinkID.flatMap {
                persistedIDs.contains($0) ? $0 : nil
            },
            selectedRootLinkID: selectedSharedLinkRootID.flatMap {
                persistedIDs.contains($0) ? $0 : nil
            },
            expandedLinkIDs: expandedSharedLinkIDs.intersection(persistedIDs),
            records: records,
            usesUnifiedSelection: true
        )
    }

    private func persistSharedLinkState() {
        #if FINDER_WORKSPACE_TESTS
        if isFinderWorkspaceFixture { return }
        #endif
        #if FOLDER_EXPANSION_TESTS
        if isFolderExpansionFixture { return }
        #endif
        #if FILE_SEARCH_TESTS
        if isFileSearchFixture { return }
        #endif
        let document = persistedSharedLinksDocument()
        sharedLinkStateQueue.async { [weak self] in
            do {
                try SharedLinksStateStore.save(document)
            } catch {
                Task { @MainActor [weak self] in
                    self?.appendOutput(
                        "Warning: shared links could not be saved locally: \(error.localizedDescription)\n"
                    )
                }
            }
        }
    }

    private func persistSharedLinkStateSynchronously() {
        #if FINDER_WORKSPACE_TESTS
        if isFinderWorkspaceFixture { return }
        #endif
        #if FOLDER_EXPANSION_TESTS
        if isFolderExpansionFixture { return }
        #endif
        #if FILE_SEARCH_TESTS
        if isFileSearchFixture { return }
        #endif
        let document = persistedSharedLinksDocument()
        do {
            try sharedLinkStateQueue.sync {
                try SharedLinksStateStore.save(document)
            }
        } catch {
            appendOutput(
                "Warning: shared links could not be saved while closing: \(error.localizedDescription)\n"
            )
        }
    }

    private func isSupportedPersistedSharedLinkURL(_ rawURL: String) -> Bool {
        guard let components = URLComponents(string: rawURL),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              components.user == nil,
              components.password == nil,
              components.path.hasPrefix("/s/")
        else { return false }
        return host == "mypikpak.com" || host.hasSuffix(".mypikpak.com")
    }

    private func switchBrowserSource(to source: BrowserSource) -> Bool {
        defer { if source == .account { _ = startNextPendingBrowserMoveIfNeeded() } }
        guard source != browserSource else { return true }
        guard !isRunning else {
            setStatus("Wait for the current browser request or transfer to finish before switching")
            return false
        }

        saveActiveBrowserWorkspace()
        _ = cancelQuickLook()
        cancelAutomaticPreviewNavigation()
        clearPreview()
        clearFolderMeasurement()
        browserSource = source
        switch source {
        case .account:
            if let accountBrowserWorkspace {
                restoreBrowserWorkspace(accountBrowserWorkspace)
            } else {
                resetBrowserWorkspace(root: .root)
                if hasUsableSession {
                    attemptedInitialBrowse = true
                    loadRoot()
                }
            }
            if !isRunning {
                setStatus(hasUsableSession ? "Account browser ready" : "Sign in to browse your cloud files")
            }
        case .sharedLink:
            if let activeSharedLinkID,
               let session = sharedLinkSessions[activeSharedLinkID] {
                shareAccess = session.access
                sharedBrowserWorkspace = session.workspace
                shareLinkIsOpen = sharedLinks.first(where: { $0.id == activeSharedLinkID })?.state == .ready
                    && session.workspace != nil
                if let workspace = session.workspace {
                    restoreBrowserWorkspace(workspace)
                } else {
                    resetBrowserWorkspace(root: .sharedRoot)
                }
            } else if let sharedBrowserWorkspace {
                restoreBrowserWorkspace(sharedBrowserWorkspace)
            } else {
                resetBrowserWorkspace(root: .sharedRoot)
            }
            setStatus(
                shareLinkIsOpen
                    ? "Shared-link browser ready"
                    : "Paste a PikPak shared-folder URL to browse it"
            )
        }
        return true
    }

    private func saveActiveBrowserWorkspace() {
        let snapshot = BrowserWorkspaceSnapshot(
            items: browserItems,
            stack: browserStack,
            nextPageToken: nextPageToken,
            expandedFolderIDs: expandedBrowserFolderIDs,
            childrenByFolderID: browserTreeChildren,
            loadErrors: browserTreeLoadErrors,
            selectedItemID: selectedBrowserItemID,
            selectedItemIDs: selectedBrowserItemIDs,
            selectionAnchorID: browserSelectionAnchorID,
            folderSnapshots: browserFolderSnapshots,
            childPageTokens: browserTreeNextPageTokens,
            itemPaths: browserItemPaths,
            parentIDs: browserItemParentIDs
        )
        snapshot.presentation.sortRevision = activeBrowserSortRevision
        snapshot.presentation.entries = browserTreeEntriesCache
        snapshot.presentation.entriesSortRevision = activeBrowserSortRevision
        snapshot.presentation.itemIndex = browserItemIndexCache
        if isBrowsingSharedLink {
            sharedBrowserWorkspace = snapshot
            if let activeSharedLinkID,
               var session = sharedLinkSessions[activeSharedLinkID] {
                // Switching to another URL while this one is still resolving
                // must not persist the temporary empty canvas as a successful
                // workspace. Its dedicated completion will store the real page.
                let isUnresolvedLoad: Bool
                if let entry = sharedLinks.first(where: { $0.id == activeSharedLinkID }),
                   case .loading = entry.state,
                   session.workspace == nil {
                    isUnresolvedLoad = true
                } else {
                    isUnresolvedLoad = false
                }
                if !isUnresolvedLoad {
                    session.workspace = snapshot
                    sharedLinkSessions[activeSharedLinkID] = session
                    persistSharedLinkState()
                }
            }
        } else {
            accountBrowserWorkspace = snapshot
        }
    }

    private func restoreBrowserWorkspace(_ snapshot: BrowserWorkspaceSnapshot) {
        cancelBrowserTreeLoads()
        browserItems = snapshot.items
        browserStack = snapshot.stack
        nextPageToken = snapshot.nextPageToken
        expandedBrowserFolderIDs = snapshot.expandedFolderIDs
        browserTreeChildren = snapshot.childrenByFolderID
        browserTreeLoadErrors = snapshot.loadErrors
        browserTreeLoadingFolderIDs = []
        selectedBrowserItemID = snapshot.selectedItemID
        selectedBrowserItemIDs = snapshot.selectedItemIDs
        browserSelectionAnchorID = snapshot.selectionAnchorID
        browserFolderSnapshots = snapshot.folderSnapshots
        browserTreeNextPageTokens = snapshot.childPageTokens
        browserItemPaths = snapshot.itemPaths
        browserItemParentIDs = snapshot.parentIDs
        browserItemIndexCache = snapshot.presentation.itemIndex
        browserTreeEntriesCache = snapshot.presentation.entriesSortRevision == browserSortRevision ? snapshot.presentation.entries : nil
        normalizeBrowserSelectionRoots()
        if snapshot.presentation.sortRevision == browserSortRevision {
            activeBrowserSortRevision = browserSortRevision
        } else {
            applyBrowserSortToCachedItems()
        }
        browserScrollRestoreRequest = nil
        pendingBrowserTreeLoads = []
    }

    private func resetBrowserWorkspace(root: BrowserLocation) {
        browserItems = []
        browserStack = [root]
        nextPageToken = nil
        browserScrollRestoreRequest = nil
        browserFolderSnapshots = [:]
        resetBrowserTreeState()
        clearBrowserSelection()
    }

    func loadBrowserIfReady() {
        guard !isRunning else { return }
        if requiresDedicatedSignIn {
            presentLogin(
                reason: "One-time session upgrade: sign in here to create an independent PikPak desktop session that cannot rotate Safari's Web token."
            )
            return
        }
        guard hasToken else {
            presentLogin(reason: "Your PikPak session is missing. Sign in to browse and download your files.")
            return
        }
        guard !attemptedInitialBrowse else { return }
        attemptedInitialBrowse = true
        loadRoot()
    }

    func signIn() {
        guard !isClosingWindow, !accountWorkIsActive, !isCheckingAccount, !isChangingAccount else {
            setStatus("Stop the active operation before signing in again")
            return
        }
        loginFromSettings = false
        accountLoginTargetID = activeAccountID
        accountLoginDeviceID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let reason: String
        if requiresDedicatedSignIn {
            reason = "One-time session upgrade: sign in here to create an independent desktop session and keep Safari separate."
        } else if hasToken {
            reason = "Sign in again to replace the saved PikPak session."
        } else {
            reason = "Sign in to connect this app to your PikPak account."
        }
        presentLogin(reason: reason)
    }

    func completeWebLogin(with session: PikPakWebSession) {
        guard !isClosingWindow, !isCheckingAccount, !isChangingAccount, let store = accountStore else { return }
        do {
            let parsed = try CredentialParser.refreshToken(from: session.refreshToken)
            let newDeviceID = session.deviceID.isEmpty ? loginDeviceID : session.deviceID
            let files = try store.stage(token: parsed, deviceID: newDeviceID)
            let expected = savedAccounts.first { $0.id == accountLoginTargetID }?.profile?.sub
            let generation = UUID()
            accountCheckGeneration = generation
            isChangingAccount = true
            isCheckingAccount = true
            isLoginPresented = false
            accountSettingsError = nil
            setStatus("Checking your PikPak account…")
            accountCheckTask = Task { [weak self] in
                guard let self else { try? store.discard(files); return }
                var committed = false
                defer {
                    if !committed { try? store.discard(files) }
                    if self.accountCheckGeneration == generation {
                        self.isCheckingAccount = false; self.isChangingAccount = false; self.accountCheckTask = nil
                        self.accountLoginDeviceID = nil; self.accountLoginTargetID = nil
                    }
                }
                do {
                    let profile = try await self.verifyAccount(files)
                    try Task.checkCancellation()
                    guard self.accountCheckGeneration == generation, !self.isClosingWindow else { return }
                    if let expected, profile.sub != expected { throw PikPakAccountError.accountMismatch }
                    let freshSession = try files.load()
                    let document = try store.commit(files, profile: profile, checkedAt: Date())
                    committed = true
                    self.finishAccountChange(document, session: freshSession, profile: profile)
                    PikPakLoginDataStore.clearPikPakWebsiteData()
                } catch {
                    guard !Task.isCancelled, !self.isClosingWindow else { return }
                    self.accountSettingsError = error.localizedDescription
                    self.setError("Could not add the account: \(error.localizedDescription)")
                }
            }
        } catch {
            accountSettingsError = error.localizedDescription
            loginReason = "The new account could not be saved. Please try again."
        }
    }

    func cancelLogin() {
        isLoginPresented = false
        accountLoginDeviceID = nil
        accountLoginTargetID = nil
        cancelAccountCheck()
        if pendingSharedLinkOpenAfterLogin {
            pendingSharedLinkOpenAfterLogin = false
            setShareLinkFeedback("Sign-in was cancelled, so the shared link was not opened.", tone: .error)
        }
        if !hasToken {
            setStatus("Sign in to browse and download your PikPak files")
        }
    }

    func cancelAccountCheck() {
        accountCheckTask?.cancel()
        accountVerifier.cancel()
        if accountLoginStatus == .checking { accountLoginStatus = hasAccountSession ? .unverified : .signedOut }
    }

    func loadRoot() {
        browserFolderSnapshots = [:]
        browserScrollRestoreRequest = nil
        loadFolder(stack: [.root], append: false, includeQuota: true)
    }

    func refreshBrowser() {
        loadFolder(stack: browserStack, append: false, includeQuota: true)
    }

    /// Command-F uses only the rendered outline (including all expanded links).
    /// Command-Shift-F keeps the independent read-only, account-root scanner.
    func presentFileSearch(scope: FileSearchScope = .expanded) {
        guard !isLoginPresented, NSApp.keyWindow?.isSheet != true else { return }
        if scope == .expanded {
            fileSearch.present(scope: .expanded,
                expandedItems: currentExpandedSearchItems(
                    includesExpandedChildren: isBrowsingSharedLink
                        || UserDefaults.standard.integer(forKey: "browserViewMode") != 1),
                contextName: isBrowsingSharedLink ? "Expanded links" : "Browser · \(currentBrowserPath)")
            return
        }
        guard hasUsableSession else {
            fileSearch.present(configuration: nil,
                failure: "Source: PikPak name search\nCode: SEARCH_SIGN_IN_REQUIRED\nMessage: Sign in from Account before searching your PikPak files.")
            return
        }
        do {
            guard let executable = Bundle.main.url(forResource: "pikpak", withExtension: nil) else {
                throw NSError(domain: "FileSearch", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The bundled PikPak engine is missing. Rebuild the app."])
            }
            var environment = try engineEnvironment()
            let proxy = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
            environment["PIKPAK_PROXY"] = proxy.isEmpty ? nil : proxy
            fileSearch.present(configuration: FileSearchConfiguration(
                executable: executable, directory: try makePrivateExchangeDirectory(),
                environment: environment
            ))
        } catch {
            fileSearch.present(configuration: nil,
                failure: "Source: PikPak name search\nCode: SEARCH_CONFIGURATION_FAILED\nMessage: \(error.localizedDescription)")
        }
    }

    /// Traverse only visible rows, not collapsed-but-cached descendants. Build
    /// each ancestry from the row depth, so nested/double-clicked locations and
    /// identical item ids under different link roots remain unambiguous.
    func currentExpandedSearchItems(includesExpandedChildren: Bool = true) -> [FileSearchMatch] {
        func matches(_ entries: [BrowserTreeEntry], stack: [BrowserLocation],
                     linkID: UUID? = nil, sourceName: String = "PikPak") -> [FileSearchMatch] {
            let base = stack.dropFirst().map { FileSearchAncestor(id: $0.id, name: $0.name) }
            var ancestors = base
            return entries.map { entry in
                ancestors = Array(ancestors.prefix(base.count + entry.depth))
                let item = entry.item
                let match = FileSearchMatch(
                    item: FileSearchItem(id: item.id, name: item.name,
                                         kind: item.isFolder ? "drive#folder" : "drive#file",
                                         size: item.size, mimeType: item.mimeType, modifiedTime: item.modifiedTime),
                    ancestors: ancestors, score: 0, linkID: linkID, sourceName: sourceName)
                if item.isFolder { ancestors.append(FileSearchAncestor(id: item.id, name: item.name)) }
                return match
            }
        }
        if isBrowsingSharedLink {
            return sharedLinks.filter { isSharedLinkExpanded($0.id) }.flatMap { link in
                let stack = activeSharedLinkID == link.id
                    ? browserStack : (sharedLinkSessions[link.id]?.workspace?.stack ?? [.sharedRoot])
                return matches(sharedLinkTreeEntries(for: link.id), stack: stack,
                               linkID: link.id, sourceName: link.url)
            }
        }
        let entries = includesExpandedChildren ? browserTreeEntries
            : browserItems.map { BrowserTreeEntry(item: $0, depth: 0) }
        return matches(entries, stack: browserStack)
    }

    func revealFileSearchResult(_ navigation: FileSearchNavigation) {
        guard !isLoginPresented else { return }
        if isRunning {
            pendingFileSearchNavigation = navigation
            setStatus("Revealing the search result after the current browser request…")
            return
        }
        pendingFileSearchNavigation = nil
        if let linkID = navigation.match.linkID {
            guard sharedLinkSessions[linkID]?.workspace != nil,
                  sharedLinks.contains(where: { $0.id == linkID }) else {
                setError("This search result's link has been disconnected. Search the current items again.")
                return
            }
            // Avoid restoring a stale saved snapshot over the active link's
            // live tree. Other expanded link roots remain untouched.
            if !isBrowsingSharedLink || activeSharedLinkID != linkID { activateSharedLink(linkID) }
            expandedSharedLinkIDs.insert(linkID)
        } else if isBrowsingSharedLink {
            saveActiveBrowserWorkspace()
            _ = cancelQuickLook()
            cancelAutomaticPreviewNavigation()
            clearPreview()
            cancelBrowserTreeLoads()
            browserSource = .account
            if let accountBrowserWorkspace {
                restoreBrowserWorkspace(accountBrowserWorkspace)
            } else {
                resetBrowserWorkspace(root: .root)
            }
        }

        if navigation.scope == .root {
            attemptedInitialBrowse = true
            materializeFileSearchAncestors(navigation)
        }
        // Union, never replace: revealing one result must not collapse the
        // user's other open branches. Folder matches select the folder itself.
        expandedBrowserFolderIDs = expandedBrowserFolderIDs.union(navigation.ancestors.map(\.id))
        applyBrowserSortToCachedItems()
        guard let item = browserItem(withID: navigation.match.item.id),
              browserTreeEntries.contains(where: { $0.id == item.id }) else {
            setError("This search result is no longer in the current tree. Search again to refresh its location.")
            return
        }
        updateBrowserSelection(to: item)
        browserScrollRestoreRequest = BrowserScrollRestoreRequest(itemID: item.id, focusesBrowser: true)
        saveActiveBrowserWorkspace()
        setStatus("Revealed search result • \(navigation.match.fullPath)")
    }

    private func materializeFileSearchAncestors(_ navigation: FileSearchNavigation) {
        let currentAncestry = browserStack.dropFirst().map(\.id)
        let targetAncestry = navigation.ancestors.map(\.id)
        if Array(targetAncestry.prefix(currentAncestry.count)) != currentAncestry {
            // The result is outside the current location. Return to the root
            // outline, keeping both its remembered branches and the folder we
            // were just viewing. No browse/network request is needed.
            if let current = browserStack.last, !current.id.isEmpty {
                browserTreeChildren[current.id] = browserItems
                browserTreeNextPageTokens[current.id] = nextPageToken
            }
            expandedBrowserFolderIDs.formUnion(currentAncestry)
            if let root = browserFolderSnapshots[""] {
                browserItems = root.items
                nextPageToken = root.nextPageToken
                expandedBrowserFolderIDs.formUnion(root.expandedFolderIDs)
                browserTreeChildren = root.childrenByFolderID.merging(browserTreeChildren) { _, live in live }
                browserTreeNextPageTokens = root.childPageTokens.merging(browserTreeNextPageTokens) { _, live in live }
                browserItemPaths = root.itemPaths.merging(browserItemPaths) { _, live in live }
                browserItemParentIDs = root.parentIDs.merging(browserItemParentIDs) { _, live in live }
            } else {
                browserItems = []
                nextPageToken = nil
            }
            browserStack = [.root]
        }

        let rootID = browserStack.last?.id ?? ""
        let routeIDs = Set(targetAncestry + [navigation.match.item.id])
        let directories = navigation.directories.drop(while: { $0.parentID != rootID })
        for directory in directories {
            let isCurrent = directory.parentID == rootID
            let cached = isCurrent ? browserItems : browserTreeChildren[directory.parentID]
            let existingIDs = Set((cached ?? []).map(\.id))
            // Keep rich live Browser metadata (thumbnails, hashes, etc.). For
            // an already loaded listing, add only the missing route/result,
            // preserving its pagination and any newer changes to siblings.
            let additions = directory.items.filter {
                !existingIDs.contains($0.id) && (cached?.isEmpty != false || routeIDs.contains($0.id))
            }.map { item in
                BrowserItem(id: item.id, name: item.name, size: item.size,
                            kind: item.isFolder ? .folder : .file, parentId: directory.parentID,
                            mimeType: item.mimeType, createdTime: nil, modifiedTime: item.modifiedTime,
                            fileExtension: nil, iconLink: nil, thumbnailLink: nil,
                            fileCategory: nil, hash: nil, md5Checksum: nil)
            }
            let items = (cached ?? []) + additions
            if isCurrent {
                browserItems = items
                if cached?.isEmpty != false { nextPageToken = directory.nextPageToken }
            } else {
                browserTreeChildren[directory.parentID] = items
                if cached == nil { browserTreeNextPageTokens[directory.parentID] = directory.nextPageToken }
            }
            let path = directory.ancestors.reduce("/") { joinedRemotePath(folder: $0, name: $1.name) }
            registerBrowserItems(items, parentID: directory.parentID, parentPath: path)
        }
    }

    func loadMoreBrowserItems() {
        guard hasMoreBrowserItems else { return }
        loadFolder(stack: browserStack, append: true)
    }

    func openFolder(_ item: BrowserItem) {
        guard item.isFolder, !isRunning else { return }
        let targetStack = browserNavigationStack(opening: item)
        rememberBrowserPosition(beforeOpening: item)
        rememberIntermediateBrowserPositions(in: targetStack)
        loadFolder(stack: targetStack, append: false)
    }

    func goBack() {
        guard browserStack.count > 1, !isRunning else { return }
        let targetStack = Array(browserStack.dropLast())
        if !restoreBrowserFolder(from: targetStack) {
            loadFolder(stack: targetStack, append: false)
        }
    }

    func selectBreadcrumb(_ location: BrowserLocation) {
        guard !isRunning, let index = browserStack.firstIndex(of: location) else { return }
        let targetStack = Array(browserStack.prefix(through: index))
        if !restoreBrowserFolder(from: targetStack) {
            loadFolder(stack: targetStack, append: false)
        }
    }

    func completeBrowserScrollRestoration(_ requestID: UUID) {
        guard browserScrollRestoreRequest?.id == requestID else { return }
        browserScrollRestoreRequest = nil
    }

    func browserSelectionChanged() {
        if let selectedBrowserItemID {
            if !isBrowserItemSelected(selectedBrowserItemID) {
                selectedBrowserItemIDs = [selectedBrowserItemID]
                browserSelectionAnchorID = selectedBrowserItemID
            }
        } else {
            selectedBrowserItemIDs = []
            browserSelectionAnchorID = nil
        }

        if automaticPreviewTargetID != nil,
           automaticPreviewTargetID != selectedBrowserItemID {
            automaticPreviewTask?.cancel()
            automaticPreviewTask = nil
            automaticPreviewTargetID = nil
        }
        if pendingAutomaticPreviewID != nil,
           pendingAutomaticPreviewID != selectedBrowserItemID {
            pendingAutomaticPreviewID = nil
        }
        if previewFileID != selectedBrowserItemID {
            clearPreview(preservingQuickLook: quickLookTargetIsCurrent)
        }
        followQuickLookSelection()
        if measuredFolderID != selectedBrowserItemID {
            clearFolderMeasurement()
        }
    }

    /// Move to the previous or next item in the visible browser page. Folder
    /// selection is immediate; previewable files use a short debounce so key
    /// repeats do not start a new network request for every intermediate row.
    @discardableResult
    func selectAdjacentBrowserItem(
        by offset: Int,
        extendingSelection: Bool = false,
        visibleItems suppliedVisibleItems: [BrowserItem]? = nil
    ) -> String? {
        guard offset != 0, canChangeBrowserSelection else { return nil }

        let visibleItems = suppliedVisibleItems ?? browserTreeEntries.map(\.item)
        guard !visibleItems.isEmpty else { return nil }
        let startIndex: Int
        if let selectedBrowserItemID,
           let selectedIndex = visibleItems.firstIndex(where: { $0.id == selectedBrowserItemID }) {
            startIndex = selectedIndex
        } else {
            startIndex = offset > 0 ? -offset : visibleItems.count - offset
        }

        let index = startIndex + offset
        guard visibleItems.indices.contains(index) else { return nil }

        let item = visibleItems[index]
        if extendingSelection {
            if isBrowsingSharedLink { extendSharedBrowserSelection(to: item) }
            else { extendBrowserSelection(to: item, visibleItems: visibleItems) }
        } else {
            updateBrowserSelection(to: item)
        }
        return item.id
    }

    func requestPreview(for item: BrowserItem) {
        #if FINDER_WORKSPACE_TESTS
        if isFinderWorkspaceFixture {
            previewFileID = item.id
            previewText = "Offline preview. This fixture never reads cloud files or uses credentials."
            previewTextEncodingName = "UTF-8"
            if quickLookFixtureURL != nil {
                previewSources = [PreviewSource(url: "https://fixture.invalid/Readme.txt", label: "Original", isOrigin: true, videoCodec: nil, audioCodec: nil)]
            }
            return
        }
        #endif
        guard !item.isFolder, !isRunning else { return }
        cancelAutomaticPreviewNavigation()
        clearPreview(preservingResourceCacheFor: item.id)
        // Keep the requested item associated with any engine/API failure so
        // the preview pane can show its diagnostic instead of going blank.
        previewFileID = item.id
        if item.mediaKind == .video || item.mediaKind == .audio {
            previewStreamingState = .preparing
        }
        if isBrowsingSharedLink {
            guard let shareAccess, shareLinkIsOpen else { return }
            let request = SharePreviewInput(access: shareAccess, fileId: item.id)
            runEngine(
                arguments: ["share-preview"],
                operation: .sharePreview(request: request, fileID: item.id)
            )
        } else {
            runEngine(
                arguments: ["preview", "--id", item.id],
                operation: .preview(fileID: item.id)
            )
        }
    }

    /// Open the native panel before metadata or file bytes arrive. A newer
    /// selection replaces this intent, without interrupting unrelated work.
    func requestQuickLook(for item: BrowserItem, in window: NSWindow? = nil) {
        guard canRequestQuickLook(for: item) else { return }
        let source = previewFileID == item.id ? preferredQuickLookSource()?.contentURL : nil
        cancelAutomaticPreviewNavigation()
        cancelQuickLookPreparation()
        quickLookTargetItem = item
        let identity = quickLookIdentity(for: item)
        quickLookTargetIdentity = identity
        quickLookPreviewCoordinator.onMove = { [weak self] offset in self?.moveQuickLookSelection(by: offset) }
        quickLookPreviewCoordinator.onClose = { [weak self] in _ = self?.cancelQuickLook() }
        quickLookPreviewCoordinator.onRetry = { [weak self] in
            guard let self, let selected = self.selectedBrowserItem else { return }
            self.requestQuickLook(for: selected)
        }
        let shown = quickLookPreviewCoordinator.showLoading(fileID: item.id, name: item.name,
            in: window ?? NSApp?.keyWindow ?? NSApp?.mainWindow)
        if NSApp != nil && !shown {
            _ = cancelQuickLook()
            setError("Quick Look is not available right now.")
            return
        }
        if let copy = quickLookCopies[identity], FileManager.default.fileExists(atPath: copy.path) {
            _ = quickLookPreviewCoordinator.present(copy, name: item.name)
            setStatus("Quick Look: \(item.name)")
            return
        }
        pendingQuickLookFileID = item.id
        isPreparingQuickLook = true
        setStatus("Preparing \(item.name) for Quick Look…")
        if let source {
            beginQuickLookDownload(sourceURL: source, item: item)
        } else if !isRunning {
            _ = startPendingQuickLookMetadataIfNeeded()
        }
    }

    private func quickLookIdentity(for item: BrowserItem) -> String {
        let source = isBrowsingSharedLink ? "link:\(activeSharedLinkID?.uuidString ?? "")" : "account:\(transferAccountID ?? "")"
        return [fileOpenContext.uuidString, source, item.id, item.name, String(item.size),
                item.modifiedTime ?? "", item.hash ?? ""].joined(separator: "\u{1F}")
    }

    private var quickLookTargetIsCurrent: Bool {
        guard let selected = selectedBrowserItem, selected.id == quickLookTargetItem?.id else { return false }
        return quickLookTargetIdentity == quickLookIdentity(for: selected)
    }

    @discardableResult
    private func startPendingQuickLookMetadataIfNeeded() -> Bool {
        guard !isRunning, let item = quickLookTargetItem, pendingQuickLookFileID == item.id else { return false }
        guard quickLookTargetIsCurrent, !isLoginPresented, !isClosingWindow else {
            _ = cancelQuickLook()
            return false
        }
        if previewFileID == item.id, openPendingQuickLookIfNeeded(for: item.id) { return true }
        requestPreview(for: item)
        // requestPreview clears the previous inline resources. Restore only
        // this still-current Quick Look intent after its synchronous setup.
        pendingQuickLookFileID = item.id
        isPreparingQuickLook = true
        if !isRunning, !openPendingQuickLookIfNeeded(for: item.id) {
            clearPendingQuickLook(for: item.id)
        }
        return true
    }

    private func followQuickLookSelection() {
        guard isQuickLookSessionActive else { return }
        guard let selected = selectedBrowserItem else { _ = cancelQuickLook(); return }
        guard !quickLookTargetIsCurrent else { return }
        if selected.isFolder {
            cancelQuickLookPreparation()
            quickLookTargetItem = selected
            quickLookTargetIdentity = quickLookIdentity(for: selected)
            quickLookPreviewCoordinator.showFolder(fileID: selected.id, name: selected.name)
        } else {
            requestQuickLook(for: selected)
        }
    }

    private func moveQuickLookSelection(by offset: Int) {
        guard isQuickLookSessionActive else { return }
        _ = selectAdjacentBrowserItem(by: offset)
    }

    @discardableResult
    func toggleQuickLookForSelection(in window: NSWindow? = nil) -> Bool {
        if cancelQuickLook() { return true }
        guard let item = selectedBrowserItem, canRequestQuickLook(for: item) else { return false }
        requestQuickLook(for: item, in: window)
        return true
    }

    private func cancelQuickLookPreparation() {
        pendingQuickLookFileID = nil
        quickLookDownloadTask?.cancel()
        quickLookDownloadTask = nil
        quickLookDownloadSession?.invalidateAndCancel()
        quickLookDownloadSession = nil
        quickLookDownloadGeneration = UUID()
        isPreparingQuickLook = false
        #if FINDER_WORKSPACE_TESTS
        quickLookFixtureTask?.cancel()
        quickLookFixtureTask = nil
        #endif
    }

    @discardableResult
    func cancelQuickLook() -> Bool {
        guard isPreparingQuickLook || isQuickLookSessionActive else { return false }
        cancelQuickLookPreparation()
        quickLookTargetItem = nil
        quickLookTargetIdentity = nil
        quickLookPreviewCoordinator.dismiss()
        setStatus("Quick Look closed")
        return true
    }

    func ownsQuickLookPanel(_ window: NSWindow) -> Bool { quickLookPreviewCoordinator.owns(window) }

    func dismissPreviewFailure() {
        guard previewPlaybackError != nil else { return }
        previewPlaybackError = nil
        previewErrorDiagnostic = nil
        previewStreamingState = .idle
        if statusIsError {
            setStatus("Preview error dismissed")
        }
    }

    /// Open a short-lived signed stream in an installed compatibility player.
    /// The URL is written to an owner-only temporary playlist instead of a
    /// process argument so it does not appear in process listings or logs.
    func openCompatibilityPreview() {
        openPreviewExternally()
    }

    /// Use IINA/mpv as a streaming fallback for any media AVPlayer cannot
    /// decode. The signed URL stays in a mode-0600 playlist and is removed
    /// shortly after the player has opened it.
    func openPreviewExternally() {
        guard let executableURL = compatibilityPlayerExecutableURL(),
              let sourceURL = preferredCompatibilitySource()?.contentURL else {
            setError("IINA is not available, or PikPak has not provided a media stream yet.")
            return
        }

        do {
            let playlistURL = try makePrivateCompatibilityPlaylist(for: sourceURL)
            let player = Process()
            player.executableURL = executableURL
            var arguments = [
                "--no-stdin",
                "--separate-windows",
                "--mpv-user-agent=\(Self.previewUserAgent)",
                "--mpv-save-position-on-quit=no",
                "--mpv-resume-playback=no",
            ]
            arguments.append("--mpv-referrer=https://mypikpak.com/")
            arguments.append(playlistURL.path)
            player.arguments = arguments
            player.standardOutput = FileHandle.nullDevice
            player.standardError = FileHandle.nullDevice
            do {
                try player.run()
            } catch {
                try? FileManager.default.removeItem(at: playlistURL)
                throw error
            }

            scheduleCompatibilityPlaylistCleanup(playlistURL)
            let playerName = externalPreviewPlayerName ?? "the external player"
            setStatus("Opened media stream in \(playerName)")
        } catch {
            appendOutput("Could not open the external media preview: \(error.localizedDescription)\n")
            setError("Could not open the media stream in IINA.")
        }
    }

    func openPreviewInQuickLook() {
        guard let item = selectedBrowserItem else { return }
        requestQuickLook(for: item)
    }

    private func beginQuickLookDownload(sourceURL: URL, item: BrowserItem) {
        pendingQuickLookFileID = nil
        let generation = UUID()
        quickLookDownloadGeneration = generation
        isPreparingQuickLook = true
        #if FINDER_WORKSPACE_TESTS
        if isFinderWorkspaceFixture, let url = quickLookFixtureURLs[item.id] ?? quickLookFixtureURL {
            quickLookFixtureTask = Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: self.quickLookFixtureDelay)
                guard !Task.isCancelled, generation == self.quickLookDownloadGeneration, self.quickLookTargetIsCurrent else { return }
                self.isPreparingQuickLook = false
                self.cacheQuickLookCopy(url)
                _ = self.quickLookPreviewCoordinator.present(url, name: item.name)
                self.setStatus("Quick Look: \(item.name)")
            }
            return
        }
        #endif
        startQuickLookDownload(sourceURL: sourceURL, originalName: item.name, generation: generation)
    }

    private func cacheQuickLookCopy(_ file: URL) {
        guard let identity = quickLookTargetIdentity else { return }
        quickLookCopies[identity] = file
        quickLookCopyOrder.removeAll { $0 == identity }
        quickLookCopyOrder.append(identity)
        while quickLookCopyOrder.count > 8 { quickLookCopies[quickLookCopyOrder.removeFirst()] = nil }
    }

    private func startQuickLookDownload(
        sourceURL: URL,
        originalName: String,
        generation: UUID
    ) {
        var request = URLRequest(url: sourceURL)
        for (field, value) in PreviewTransport.mediaHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.setValue("*/*", forHTTPHeaderField: "Accept")

        let session = URLSession(
            configuration: PreviewTransport.configuration(proxyURL: proxyURL)
        )
        quickLookDownloadSession = session
        let task = session.downloadTask(with: request) { [weak self, session] temporaryURL, response, error in
            defer { session.finishTasksAndInvalidate() }
            var result: Result<URL, Error>
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse,
                      !(200 ..< 300).contains(http.statusCode) {
                result = .failure(
                    NSError(
                        domain: "PikPakQuickLook",
                        code: http.statusCode,
                        userInfo: [NSLocalizedDescriptionKey: "PikPak's file server returned HTTP \(http.statusCode)."]
                    )
                )
            } else if let temporaryURL {
                do {
                    let destination = try Self.moveQuickLookDownload(
                        from: temporaryURL,
                        originalName: originalName
                    )
                    result = .success(destination)
                } catch {
                    result = .failure(error)
                }
            } else {
                result = .failure(
                    NSError(
                        domain: "PikPakQuickLook",
                        code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "The temporary download did not return a file."]
                    )
                )
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                guard generation == self.quickLookDownloadGeneration, self.quickLookTargetIsCurrent, self.isQuickLookSessionActive else {
                    if case .success(let staleFileURL) = result {
                        try? FileManager.default.removeItem(at: staleFileURL)
                    }
                    return
                }
                self.quickLookDownloadTask = nil
                self.quickLookDownloadSession = nil

                self.isPreparingQuickLook = false
                switch result {
                case .success(let fileURL):
                    self.cacheQuickLookCopy(fileURL)
                    Self.scheduleQuickLookCleanup(fileURL)
                    if self.quickLookPreviewCoordinator.present(fileURL, name: originalName) {
                        self.setStatus("Quick Look: \(originalName)")
                    } else {
                        self.setError("Quick Look is not available right now.")
                    }
                case .failure(let error):
                    self.quickLookPreviewCoordinator.showFailure("Could not load this preview. Check your connection and try again.")
                    let diagnostic = self.diagnostic(
                        for: error,
                        source: "Quick Look temporary download",
                        fallbackCode: "QUICK_LOOK_DOWNLOAD_FAILED"
                    )
                    let routeHint = PreviewTransport.usesProxy(self.proxyURL)
                        ? "The app proxy was used and system certificate validation remained enabled."
                        : "No app proxy is configured; this Mac attempted the media CDN directly."
                    let enrichedDiagnostic = AppErrorDiagnostic(
                        source: diagnostic.source,
                        code: diagnostic.code,
                        message: diagnostic.message,
                        context: [diagnostic.context, routeHint]
                            .compactMap { $0 }
                            .joined(separator: "\n")
                    )
                    self.setError(
                        "Could not prepare the file for Quick Look.",
                        diagnostic: enrichedDiagnostic
                    )
                }
            }
        }
        quickLookDownloadTask = task
        let route = PreviewTransport.usesProxy(proxyURL) ? " through the app proxy" : ""
        setStatus("Downloading a private temporary copy for Quick Look\(route)…")
        task.resume()
    }

    func measureSelectedFolder() {
        guard canMeasureSelectedFolder, let item = selectedBrowserItem else { return }
        measureFolder(item)
    }

    func measureSharedLink(_ linkID: UUID) {
        guard canMeasureSharedLink(linkID) else { return }
        if activeSharedLinkID != linkID {
            activateSharedLink(linkID)
        }
        guard
            activeSharedLinkID == linkID,
            let root = sharedLinkRootLocation(for: linkID),
            let shareAccess,
            shareLinkIsOpen
        else { return }

        measuredFolderID = root.id
        folderMeasurement = cachedFolderMeasurement(for: root.id, in: linkID)
        let request = ShareMeasureInput(access: shareAccess, folderId: root.id)
        runFolderMeasurementEngine(
            arguments: ["share-measure"],
            operation: .shareMeasure(request: request, folderID: root.id, linkID: linkID)
        )
    }

    func measureFolder(_ item: BrowserItem) {
        guard canMeasureFolder(item), isBrowsingSharedLink || validateConfiguration() else { return }

        measuredFolderID = item.id
        folderMeasurement = cachedFolderMeasurement(for: item.id)
        if isBrowsingSharedLink {
            guard let shareAccess,
                  let linkID = activeSharedLinkID,
                  shareLinkIsOpen else { return }
            let request = ShareMeasureInput(access: shareAccess, folderId: item.id)
            runFolderMeasurementEngine(
                arguments: ["share-measure"],
                operation: .shareMeasure(
                    request: request,
                    folderID: item.id,
                    linkID: linkID
                )
            )
        } else {
            runFolderMeasurementEngine(
                arguments: ["measure", "--id", item.id],
                operation: .measure(folderID: item.id)
            )
        }
    }

    func cancelFolderMeasurement() {
        guard isMeasuringFolder,
              let folderMeasurementProcess,
              folderMeasurementProcess.isRunning
        else { return }
        folderMeasurementWasCancelled = true
        setStatus("Cancelling folder size calculation…")
        folderMeasurementProcess.terminate()
    }

    func scanCurrentFolderForDuplicates() {
        guard
            canScanCurrentFolderForDuplicates,
            let scope = browserStack.last,
            validateConfiguration()
        else { return }

        duplicateScan = nil
        selectedDuplicateFileIDs = []
        duplicateScannedFiles = 0
        duplicateScannedFolders = 0
        duplicateDiscoveredFolders = 1
        duplicatePendingFolders = 1
        duplicateFailedFolders = 0
        duplicateRetryAttempt = 0
        duplicateRetryMaxAttempts = 0
        duplicateRetryInMillis = 0
        duplicateCurrentPath = scope.path
        duplicateScanRootPath = scope.path
        #if FINDER_WORKSPACE_TESTS
        if isFinderWorkspaceFixture {
            configureTaskActivityInspection("running")
            return
        }
        #endif
        runDuplicateScan(scope: scope)
    }

    func cancelDuplicateScan() {
        #if FINDER_WORKSPACE_TESTS
        if isFinderWorkspaceFixture, isScanningDuplicates {
            isScanningDuplicates = false
            taskActivity.finish(.duplicates, state: .cancelled, message: "Duplicate scan cancelled")
            return
        }
        #endif
        guard isScanningDuplicates, let duplicateProcess, duplicateProcess.isRunning else { return }
        duplicateScanWasCancelled = true
        taskActivity.stopping(.duplicates, message: "Cancelling duplicate scan…")
        if !isRunning {
            setStatus("Cancelling duplicate scan…")
        }
        duplicateProcess.terminate()
    }

    func setDuplicateFileSelected(_ fileID: String, selected: Bool) {
        guard let duplicateScan,
              let group = duplicateScan.groups.first(where: { group in
                  group.files.contains(where: { $0.id == fileID })
              })
        else { return }

        if selected {
            let selectedInGroup = group.files.filter {
                selectedDuplicateFileIDs.contains($0.id)
            }.count
            guard selectedInGroup < max(group.files.count - 1, 0) else {
                setError("Keep at least one copy from each duplicate group.")
                return
            }
            selectedDuplicateFileIDs.insert(fileID)
        } else {
            selectedDuplicateFileIDs.remove(fileID)
        }
    }

    func selectRecommendedDuplicates() {
        guard let duplicateScan else { return }
        selectedDuplicateFileIDs = Set(
            duplicateScan.groups
                .filter { $0.matchKind == .exactContent }
                .flatMap { $0.files.dropFirst().map(\.id) }
        )
        setStatus("Selected redundant exact-content copies while keeping one copy per group")
    }

    func clearDuplicateSelection() {
        selectedDuplicateFileIDs = []
    }

    func deleteSelectedDuplicates() {
        guard canDeleteSelectedDuplicates else { return }
        let ids = selectedDuplicateFileIDs.sorted()
        runEngine(
            arguments: ["trash", "--yes"],
            operation: .trashDuplicates(ids: ids)
        )
    }

    func trashBrowserItem(_ item: BrowserItem) {
        guard !isRunning, !hasExclusiveBackgroundTask, hasUsableSession, !isExtractionSourceInUse(item) else { return }
        cancelAutomaticPreviewNavigation()
        runEngine(
            arguments: ["trash", "--id", item.id, "--yes"],
            operation: .trash(itemID: item.id, itemName: item.name)
        )
    }

    private var canPerformFileUndo: Bool {
        hasUsableSession && !isRunning && !isUploading && !isChangingAccount
            && !isClosingWindow && !isLoginPresented && !hasExclusiveBackgroundTask
            && !hasConflictingBrowserMoveTask && pendingBrowserMoves.isEmpty
            && !archiveTasks.contains(where: \.isBusy)
            && fileUndoHistory.active == nil
    }
    var canUndoFileAction: Bool { canPerformFileUndo && !fileUndoHistory.undoEntries.isEmpty }
    var canRedoFileAction: Bool { canPerformFileUndo && !fileUndoHistory.redoEntries.isEmpty }

    func performFileUndo(redo: Bool) {
        guard redo ? canRedoFileAction : canUndoFileAction else { return }
        let title = redo ? fileUndoHistory.redoTitle : fileUndoHistory.undoTitle
        if !redo, let batch = fileUndoHistory.undoEntries.last?.uploadBatchID,
           savedUploadBatches.contains(where: { $0.id == batch }) { discardSavedUpload(batch) }
        fileUndoRefreshFeedback = nil
        guard let request = fileUndoHistory.begin(redo: redo) else { return }
        cancelAutomaticPreviewNavigation()
        _ = cancelQuickLook()
        #if FINDER_WORKSPACE_TESTS
        if isFinderWorkspaceFixture {
            finishFileUndoFixture(request: request, title: title)
            return
        }
        #endif
        runEngine(arguments: ["undo-files"], operation: .undoFiles(request: request, title: title))
        if !isRunning { fileUndoHistory.cancelRequest() }
    }

    private func recordTrashUndo(ids: [String], title: String = "Move to Trash") {
        let mutations = ids.map { id in
            let item = browserItem(withID: id)
            return FinderFileMutation(fileId: id, kind: .trash, before: "false", after: "true",
                parentId: item.flatMap { accountSizeParent(of: $0) }, name: item?.name)
        }
        fileUndoHistory.record(FinderUndoEntry(title: title, mutations: mutations))
    }

    private func recordCreatedUploadItem(id: String, parentID: String, name: String?, folder: Bool) {
        guard !id.isEmpty, !uploadUndoMutations.contains(where: { $0.fileId == id }) else { return }
        // PikPak can adjust duplicate names. The created ID and parent identify
        // this upload without assuming the server kept the local filename.
        uploadUndoMutations.append(FinderFileMutation(fileId: id, kind: .trash,
            before: "true", after: "false", parentId: parentID, name: nil, requiresEmptyFolder: folder))
    }

    private func finishFileUndo(output: String, request: FinderUndoRequest, title: String) {
        do {
            let result = try JSONDecoder().decode(FinderUndoResult.self, from: Data(output.utf8))
            guard Set(result.completed).isSubset(of: Set(request.changes.map(\.id))) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let applied = fileUndoHistory.finish(completed: result.completed)
            let removed = Set(applied.filter { $0.kind == .trash && $0.after == "true" }.map(\.fileId))
            var parents = Set(applied.compactMap(\.parentId))
            for change in applied where change.kind == .move { parents.formUnion([change.before, change.after]) }
            removeCachedAccountBrowserItems(withIDs: removed, invalidatingFolders: parents)
            recordFolderSizeChange(in: parents)
            duplicateScan = nil; selectedDuplicateFileIDs = []
            if let error = result.error {
                setError("\(title) stopped after \(applied.count) of \(request.changes.count) item(s). \(redactedEngineOutput(error)) Unfinished changes remain available to retry.")
            } else if applied.count != request.changes.count {
                setError("PikPak did not confirm every change. Unfinished changes remain available to retry.")
            } else {
                setStatus("\(title) completed · \(applied.count) item(s)")
            }
        } catch {
            fileUndoHistory.cancelRequest()
            setError("Could not read PikPak's Undo/Redo result. Refresh the folder and retry; the history was kept.")
        }
    }

    func trashSelectedBrowserItems() {
        guard canTrashSelectedBrowserItem else { return }
        let ids = browserItemsSelectedForTrash.map(\.id)
        guard !ids.isEmpty else { return }
        cancelAutomaticPreviewNavigation()
        runEngine(
            arguments: ["trash", "--yes"],
            operation: .trashBrowserItems(ids: ids)
        )
    }

    /// Starts one app-local Finder-style drag. If the grabbed row belongs to
    /// the current multi-selection, all selection roots travel together.
    /// Otherwise the grabbed row becomes the sole selection first.
    func beginBrowserDrag(_ item: BrowserItem) -> String? {
        guard canBeginBrowserDrag else { return nil }
        if !isBrowserItemSelected(item.id) {
            // Snapshot the grabbed row immediately; a drag must not depend
            // on a later click/mouse-up handler changing the selection.
            updateBrowserSelection(to: item)
        }
        let items = browserItemsSelectedForAction
        guard !items.isEmpty else { return nil }

        cancelAutomaticPreviewNavigation()
        let token = UUID().uuidString
        browserDragToken = token
        browserDragAccountID = transferAccountID
        browserDraggedItems = items
        let noun = items.count == 1 ? items[0].name : "\(items.count.formatted()) items"
        setStatus("Drag \(noun) onto a PikPak folder to move, or into Finder to download")
        return token
    }

    /// Add a lazy Finder file promise to the same provider used for in-app
    /// cloud moves. No cloud bytes are fetched until Finder supplies the final
    /// drop directory.
    func makeBrowserDownloadPromiseProvider() -> NSItemProvider? {
        #if BROWSER_DROP_TESTS
        if isBrowserDropFixture { return nil }
        #endif
        guard canBeginBrowserDrag, !browserDraggedItems.isEmpty else { return nil }
        guard let engineURL = Bundle.main.url(forResource: "pikpak", withExtension: nil) else {
            setError("The bundled download engine is missing. Rebuild the app.")
            return nil
        }

        do {
            var environment = try engineEnvironment()
            let proxy = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if proxy.isEmpty {
                environment.removeValue(forKey: "PIKPAK_PROXY")
            } else {
                environment["PIKPAK_PROXY"] = proxy
            }

            let items = browserDraggedItems
            let remotePaths = items.map { browserPath(for: $0) }
            let wrapsSelection = items.count > 1
            let rawName = wrapsSelection
                ? "PikPak Selection (\(items.count.formatted()) items)"
                : items[0].name
            let promisedName = Self.safePromisedFilename(rawName)
            let fileType: String
            if wrapsSelection || items[0].isFolder {
                fileType = UTType.folder.identifier
            } else if !items[0].normalizedFileExtension.isEmpty,
                      let type = UTType(filenameExtension: items[0].normalizedFileExtension) {
                fileType = type.identifier
            } else {
                fileType = UTType.data.identifier
            }
            let itemDescription = wrapsSelection
                ? "\(items.count.formatted()) PikPak items"
                : "“\(items[0].name)”"

            let payload = CloudDownloadPromisePayload(
                promisedName: promisedName,
                remotePaths: remotePaths,
                wrapsSelectionInFolder: wrapsSelection,
                engineURL: engineURL,
                environment: environment,
                jobs: effectiveDownloadConcurrentJobs,
                onStart: { [weak self] in
                    Task { @MainActor in
                        self?.setStatus("Downloading \(itemDescription) to the Finder destination…")
                    }
                },
                onFinish: { [weak self] result in
                    Task { @MainActor in
                        guard let self else { return }
                        switch result {
                        case .success:
                            self.setStatus("Downloaded \(itemDescription) to Finder")
                        case .failure(let error):
                            self.setError(
                                "Could not download \(itemDescription) to Finder.",
                                diagnostic: self.diagnostic(
                                    for: error,
                                    source: "Finder file promise",
                                    fallbackCode: "FINDER_DOWNLOAD_FAILED"
                                )
                            )
                        }
                    }
                }
            )
            return cloudDownloadPromiseCoordinator.makeProvider(
                fileType: fileType,
                payload: payload
            )
        } catch {
            setError(
                "Could not prepare this Finder download.",
                diagnostic: diagnostic(
                    for: error,
                    source: "Finder file promise",
                    fallbackCode: "FINDER_DOWNLOAD_PREPARE_FAILED"
                )
            )
            return nil
        }
    }

    private static func safePromisedFilename(_ rawName: String) -> String {
        let sanitized = rawName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "PikPak Download" : sanitized
    }

    /// Values used by the drag image before `beginBrowserDrag` runs. A child
    /// represented by a checked ancestor correctly previews that ancestor as
    /// the recursive move root instead of pretending only one file will move.
    func browserDragItemCount(startingWith item: BrowserItem) -> Int {
        browserItemsForDrag(startingWith: item).count
    }

    func browserDragTitle(startingWith item: BrowserItem) -> String {
        let items = browserItemsForDrag(startingWith: item)
        if items.count == 1 {
            return items[0].name
        }
        return "\(items.count.formatted()) items"
    }

    func browserDragContainsFolder(startingWith item: BrowserItem) -> Bool {
        browserItemsForDrag(startingWith: item).contains(where: \.isFolder)
    }

    func canDropBrowserDrag(on destination: BrowserLocation) -> Bool {
        guard canBeginBrowserDrag, !browserDraggedItems.isEmpty else { return false }
        return canMoveBrowserItems(browserDraggedItems, to: destination)
    }

    private func canMoveBrowserItems(
        _ items: [BrowserItem],
        to destination: BrowserLocation
    ) -> Bool {
        guard !items.isEmpty, !items.contains(where: isExtractionSourceInUse) else { return false }
        let destinationID = destination.id

        for item in items {
            if item.id == destinationID {
                return false
            }
            if item.isFolder, isBrowserItem(destinationID, descendantOf: item.id) {
                return false
            }
        }

        return items.contains {
            (browserItemParentIDs[$0.id] ?? $0.parentId) != destinationID
        }
    }

    /// Validates the opaque, own-process drag token before performing the
    /// server mutation. This prevents unrelated or external drags from ever
    /// becoming PikPak move requests.
    @discardableResult
    func performBrowserDrop(token: String, on destination: BrowserLocation) -> Bool {
        guard token == browserDragToken, browserDragAccountID == transferAccountID,
              canDropBrowserDrag(on: destination) else {
            return false
        }
        let items = browserDraggedItems.filter {
            (browserItemParentIDs[$0.id] ?? $0.parentId) != destination.id
        }
        cancelBrowserDrag()
        guard !items.isEmpty else { return false }

        cancelAutomaticPreviewNavigation()
        enqueueBrowserMove(items: items, destination: destination)
        return true
    }

    @discardableResult
    func mergeSelectedFolders(keeping destinationID: String) -> Bool {
        guard canMergeSelectedFolders, validateConfiguration() else { return false }
        let folders = selectedFoldersForMerge
        guard let destination = folders.first(where: { $0.id == destinationID }) else {
            setError("Choose one of the selected folders to keep after the merge.")
            return false
        }
        guard folders.contains(where: { $0.id != destination.id }) else { return false }

        cancelAutomaticPreviewNavigation()
        mergeRequestedFolders = folders
        mergeDestination = destination
        mergeCompletedSourceIDs = []
        resetFolderMergeProgress(
            sourceCount: folders.count - 1,
            status: "Preparing to merge into \(destination.name)…"
        )
        runFolderMergeEngine(folders: folders, destination: destination)
        return true
    }

    func retryFolderMerge() {
        guard canRetryFolderMerge, let destination = mergeDestination else { return }
        let remainingSources = mergeRequestedFolders.filter {
            $0.id != destination.id && !mergeCompletedSourceIDs.contains($0.id)
        }
        guard !remainingSources.isEmpty else { return }
        resetFolderMergeProgress(
            sourceCount: mergeRequestedFolders.count - 1,
            status: "Retrying the unfinished folder merge…"
        )
        runFolderMergeEngine(
            folders: [destination] + remainingSources,
            destination: destination
        )
    }

    func cancelFolderMerge() {
        guard isMergingFolders, let mergeProcess, mergeProcess.isRunning else { return }
        mergeWasCancelled = true
        taskActivity.stopping(.folderMerge, message: "Cancelling folder merge…")
        setMergeStatus("Cancelling safely after the current PikPak request…")
        mergeProcess.terminate()
    }

    private func browserItemsForDrag(startingWith item: BrowserItem) -> [BrowserItem] {
        isBrowserItemSelected(item.id) ? browserItemsSelectedForAction : [item]
    }

    /// Last drop wins when the same item is dropped again before an earlier
    /// queued move starts. Different selections retain their Finder order and
    /// execute one request at a time through the shared session coordinator.
    private func enqueueBrowserMove(
        items: [BrowserItem],
        destination: BrowserLocation
    ) {
        let incomingIDs = Set(items.map(\.id))
        pendingBrowserMoves = pendingBrowserMoves.compactMap { request in
            let remaining = request.items.filter { !incomingIDs.contains($0.id) }
            return remaining.isEmpty
                ? nil
                : BrowserMoveRequest(items: remaining, destination: request.destination)
        }
        pendingBrowserMoves.append(BrowserMoveRequest(items: items, destination: destination))

        if isRunning || hasConflictingBrowserMoveTask {
            setStatus("Move to \(destination.path) queued; it will start when the current folder change finishes")
            return
        }
        _ = startNextPendingBrowserMoveIfNeeded()
    }

    @discardableResult
    private func startNextPendingBrowserMoveIfNeeded() -> Bool {
        guard !isRunning,
              !isClosingWindow,
              !hasConflictingBrowserMoveTask,
              !isLoginPresented,
              !isBrowsingSharedLink,
              hasUsableSession
        else { return false }

        while !pendingBrowserMoves.isEmpty {
            let request = pendingBrowserMoves.removeFirst()
            let items = request.items.filter {
                (browserItemParentIDs[$0.id] ?? $0.parentId) != request.destination.id
            }
            guard canMoveBrowserItems(items, to: request.destination) else { continue }
            startBrowserMove(items: items, destination: request.destination)
            return isRunning
        }
        return false
    }

    private func startBrowserMove(
        items: [BrowserItem],
        destination: BrowserLocation
    ) {
        #if BROWSER_DROP_TESTS
        if isBrowserDropFixture {
            recordedDropMoves.append((items, destination))
            isRunning = true
            setStatus("TEST move accepted: \(items.map(\.name).joined(separator: ", ")) to \(destination.path)")
            return
        }
        #endif
        runEngine(
            arguments: ["move", "--to-parent-id", destination.id],
            operation: .moveBrowserItems(items: items, destination: destination)
        )
    }

    func createFolder(named rawName: String, in parent: BrowserLocation) {
        guard canCreateFolder, validateConfiguration() else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            setError("Enter a name for the new folder.")
            return
        }
        runEngine(
            arguments: [
                "create-folder",
                "--parent-id", parent.id,
                "--name", name,
            ],
            operation: .createFolder(parent: parent, name: name)
        )
    }

    func renameBrowserItem(_ item: BrowserItem, to rawName: String) {
        guard canRenameBrowserItem(item), validateConfiguration() else { return }
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            setError("Enter a new name for this item.")
            return
        }
        guard name != item.name else {
            setStatus("The item is already named \(item.name)")
            return
        }

        cancelAutomaticPreviewNavigation()
        runEngine(
            arguments: [
                "rename",
                "--id", item.id,
                "--name", name,
            ],
            operation: .renameItem(item: item, name: name)
        )
    }

    func selectArchiveTask(_ id: UUID) {
        guard archiveTasks.contains(where: { $0.id == id }) else { return }
        selectedArchiveTaskID = id
    }

    func hasArchiveTask(for item: BrowserItem) -> Bool {
        archiveTasks.contains { $0.item.id == item.id }
    }

    func openArchiveExtraction(_ item: BrowserItem) {
        guard canOpenArchiveExtraction(item) else { return }
        extractArchives([item])
    }

    func presentNextArchivePasswordRequest() {
        guard !isClosingWindow, !isChangingAccount, !isLoginPresented,
              !extractionActivity.passwordPresentationIsClosing,
              extractionActivity.passwordRequest == nil,
              let task = archiveTasks.first(where: { $0.needsPassword && !$0.passwordPromptDeferred }) else { return }
        updateArchiveTask(task.id) { $0.passwordPromptDeferred = true }
        extractionActivity.showsActivity = false
        extractionActivity.passwordRequest = ArchivePasswordRequest(
            taskID: task.id, name: task.item.name, retry: task.passwordWasAttempted)
    }

    func requestArchivePassword(_ taskID: UUID) {
        guard archiveTasks.first(where: { $0.id == taskID })?.needsPassword == true else { return }
        updateArchiveTask(taskID) { $0.passwordPromptDeferred = false }
        presentNextArchivePasswordRequest()
    }

    func deferArchivePasswordRequest(_ request: ArchivePasswordRequest) {
        guard extractionActivity.passwordRequest?.id == request.id else { return }
        extractionActivity.passwordPresentationIsClosing = true
        extractionActivity.passwordRequest = nil
    }

    func archivePasswordSheetDidDismiss() {
        extractionActivity.passwordPresentationIsClosing = false
        presentNextArchivePasswordRequest()
    }

    func submitArchivePassword(_ password: String, for request: ArchivePasswordRequest) {
        guard !password.isEmpty, !isClosingWindow, !isChangingAccount,
              extractionActivity.passwordRequest?.id == request.id,
              let task = archiveTasks.first(where: { $0.id == request.taskID }), task.needsPassword else { return }
        deferArchivePasswordRequest(request)
        updateArchiveTask(task.id) { $0.extractWhenReady = true; $0.passwordWasAttempted = true }
        inspectArchive(task.item, password: password, activate: false)
    }

    func clearFinishedArchiveTasks() {
        let ids = archiveTasks.filter { $0.isComplete }.map(\.id)
        for id in ids { removeArchiveTask(id) }
    }

    @discardableResult
    func revealArchiveOutput(_ taskID: UUID) -> Bool {
        guard !isRunning, let task = archiveTasks.first(where: { $0.id == taskID }), task.isComplete,
              let parentID = task.parentFolderID, activateAccountBrowser() else { return false }
        let stack: [BrowserLocation]
        if parentID.isEmpty { stack = [.root] }
        else if let index = browserStack.firstIndex(where: { $0.id == parentID }) {
            stack = Array(browserStack.prefix(through: index))
        } else if let parent = browserItem(withID: parentID) {
            stack = browserNavigationStack(opening: parent)
        } else {
            let path = browserItemPaths[parentID] ?? "/"
            stack = [.root, BrowserLocation(id: parentID, name: "Extraction folder", path: path)]
        }
        loadFolder(stack: stack, append: false, includeQuota: false)
        return true
    }

    private func updateArchiveTask(_ id: UUID, _ update: (inout CloudExtractionTask) -> Void) {
        guard let index = archiveTasks.firstIndex(where: { $0.id == id }) else { return }
        update(&archiveTasks[index])
    }

    /// Each inspection gets its own helper and private password request.
    func inspectArchive(_ item: BrowserItem, password: String = "", activate: Bool = true) {
        let existing = archiveTasks.first { $0.item.id == item.id }
        guard hasUsableSession, !isClosingWindow,
              existing != nil || canOpenArchiveExtraction(item), validateConfiguration() else { return }
        if let existing, existing.isBusy { if activate { selectArchiveTask(existing.id) }; return }
        let taskID: UUID
        if let existing { taskID = existing.id }
        else {
            taskID = UUID()
            archiveTasks.append(CloudExtractionTask(id: taskID, item: item,
                parentFolderID: browserItemParentIDs[item.id] ?? item.parentId ?? browserStack.last?.id))
        }
        if activate { selectArchiveTask(taskID) }
        updateArchiveTask(taskID) {
            $0.inspection = nil; $0.result = nil; $0.error = nil
            $0.password = password; $0.selectedIndices = []
            $0.passwordWasAttempted = !password.isEmpty
            $0.queuedAction = .inspect
        }
        pumpArchiveQueue()
    }

    func startArchiveExtraction(password: String, selectedIndices: Set<Int>) {
        guard let taskID = selectedArchiveTaskID else {
            reportArchiveStartBlocked("ARCHIVE_NOT_SELECTED", "Select an archive task before extracting its contents.")
            return
        }
        enqueueArchiveExtraction(taskID, password: password, selectedIndices: selectedIndices)
    }

    private func reportArchiveStartBlocked(_ code: String, _ message: String) {
        setError(message, diagnostic: AppErrorDiagnostic(
            source: "Cloud extraction", code: code, message: message, context: nil))
    }

    private func enqueueArchiveExtraction(_ taskID: UUID, password: String, selectedIndices: Set<Int>) {
        guard let task = archiveTasks.first(where: { $0.id == taskID }) else {
            reportArchiveStartBlocked("ARCHIVE_TASK_NOT_FOUND", "This archive task is no longer available. Choose the archive again in Browser.")
            return
        }
        guard !isClosingWindow else {
            reportArchiveStartBlocked("ARCHIVE_WINDOW_CLOSING", "The app is stopping its tasks. Reopen the app before starting another extraction.")
            return
        }
        guard !task.isBusy else {
            setStatus("This archive is already queued or running. Follow its progress in the footer.")
            return
        }
        guard let inspection = task.inspection, inspection.ready else {
            reportArchiveStartBlocked("ARCHIVE_NOT_READY", task.inspection?.requiredPassword == true
                ? "Enter the archive password to continue extracting."
                : "Read the archive contents before choosing items to extract.")
            return
        }
        guard hasUsableSession, !isLoginPresented else {
            reportArchiveStartBlocked("ARCHIVE_SIGN_IN_REQUIRED", "Complete sign-in from Account before starting this extraction. Your selected archive items have been kept.")
            return
        }
        guard validateConfiguration() else { return }

        let validIndices = Set(inspection.entries.map(\.index))
        let selected = selectedIndices.intersection(validIndices).sorted()
        guard !selected.isEmpty else {
            reportArchiveStartBlocked("ARCHIVE_SELECTION_EMPTY", "Select at least one archive item to extract.")
            return
        }
        updateArchiveTask(taskID) {
            $0.password = password; $0.selectedIndices = Set(selected)
            $0.result = nil; $0.error = nil; $0.queuedAction = .extract
        }
        pumpArchiveQueue()
    }

    /// Explicitly selected archive files only; selected folders are never
    /// scanned or expanded into surprise extraction requests.
    func archivesForExtraction(contextItem: BrowserItem) -> [BrowserItem] {
        let archives = browserItemActionRoots.filter { $0.isCloudExtractableArchive }
        // A checked ancestor folder can make its archive child look selected.
        // The explicit context action still targets that archive, without
        // recursively extracting every archive inside the selected folder.
        if archives.contains(where: { $0.id == contextItem.id }) { return archives }
        return contextItem.isCloudExtractableArchive ? [contextItem] : []
    }

    func extractArchives(_ items: [BrowserItem]) {
        var seen = Set<String>()
        let archives = items.filter { seen.insert($0.id).inserted && canOpenArchiveExtraction($0) }
        for item in archives {
            if let task = archiveTasks.first(where: { $0.item.id == item.id }) {
                guard task.result == nil else { continue }
                updateArchiveTask(task.id) { $0.extractWhenReady = true }
                guard !task.isBusy else { continue }
                if let inspection = task.inspection, inspection.ready {
                    enqueueArchiveExtraction(task.id, password: task.password, selectedIndices: Set(inspection.entries.map(\.index)))
                } else if task.inspection?.requiredPassword != true {
                    inspectArchive(item, password: task.password, activate: false)
                }
            } else {
                let id = UUID()
                archiveTasks.append(CloudExtractionTask(id: id, item: item,
                    parentFolderID: browserItemParentIDs[item.id] ?? item.parentId ?? browserStack.last?.id,
                    extractWhenReady: true))
                inspectArchive(item, activate: false)
            }
        }
        if let first = archives.first, let task = archiveTasks.first(where: { $0.item.id == first.id }) { selectArchiveTask(task.id) }
        if !archives.isEmpty { setStatus("Preparing \(archives.count) archive(s) for background extraction.") }
        presentNextArchivePasswordRequest()
    }

    func startReadyArchiveTasks() {
        for task in archiveTasks where !task.isBusy && task.error == nil && task.result == nil && task.inspection?.ready == true {
            enqueueArchiveExtraction(task.id, password: task.password, selectedIndices: task.selectedIndices)
        }
    }

    private func pumpArchiveQueue() {
        guard !isClosingWindow, hasUsableSession, !isLoginPresented, !isChangingAccount else { return }
        while !isLoginPresented, !isClosingWindow,
              archiveProcesses.count < min(8, max(1, archiveConcurrencyLimit)),
              let task = archiveTasks.first(where: { $0.queuedAction != nil }) {
            let action = task.queuedAction!
            updateArchiveTask(task.id) { $0.queuedAction = nil }
            if action == .inspect {
                runArchiveTaskEngine(taskID: task.id, command: "archive-inspect", request:
                    ArchiveInspectInput(fileId: task.item.id, gcid: task.item.hash ?? "", password: task.password))
            } else {
                runArchiveTaskEngine(taskID: task.id, command: "archive-extract", request:
                    ArchiveExtractInput(fileId: task.item.id, gcid: task.item.hash ?? "", password: task.password,
                                        selectedIndices: task.selectedIndices.sorted()))
            }
        }
    }

    func retryArchiveTask(_ id: UUID) {
        guard let task = archiveTasks.first(where: { $0.id == id }), !task.isBusy else { return }
        if task.needsPassword { requestArchivePassword(id); return }
        // Re-inspect after failures because an archive may need its password
        // again. Never blindly resubmit an extraction with a cleared password.
        updateArchiveTask(id) { $0.extractWhenReady = true }
        inspectArchive(task.item, activate: false)
    }

    /// Clear a completed/error task so the Extractions workspace can return to
    /// its empty state. A running server task is never discarded here.
    func clearArchiveExtractionPresentation() {
        guard let id = selectedArchiveTaskID else { return }
        removeArchiveTask(id)
    }

    func removeArchiveTask(_ id: UUID) {
        guard let task = archiveTasks.first(where: { $0.id == id }), !task.isInspecting, !task.isExtracting else { return }
        if extractionActivity.passwordRequest?.taskID == id { extractionActivity.passwordRequest = nil }
        archiveTasks.removeAll { $0.id == id }
        if selectedArchiveTaskID == id { selectedArchiveTaskID = archiveTasks.last?.id }
    }

    func cancelArchiveInspection(_ id: UUID) {
        if archiveTasks.first(where: { $0.id == id })?.queuedAction != nil {
            updateArchiveTask(id) {
                $0.queuedAction = nil; $0.extractWhenReady = false; $0.phase = "Cancelled"
                $0.password = ""
            }
            return
        }
        guard archiveTasks.first(where: { $0.id == id })?.isInspecting == true else { return }
        stoppedArchiveTaskIDs.insert(id)
        if let child = archiveProcesses[id], child.isRunning { child.terminate() }
    }

    func removeEmptyFolders(in scope: BrowserLocation) {
        guard canRemoveEmptyFolders, validateConfiguration() else { return }
        emptyFolderScannedFolders = 0
        emptyFolderDiscoveredFolders = 1
        emptyFolderCandidateCount = 0
        emptyFolderCheckedFolders = 0
        emptyFolderRemovedFolders = 0
        emptyFolderSkippedFolders = 0
        emptyFolderCurrentPath = scope.path
        runMaintenanceScan(
            arguments: [
                "empty-folders",
                "--parent-id", scope.id,
                "--root-path", scope.path,
                "--yes",
                "--progress-json",
            ],
            operation: .emptyFolders(scope: scope)
        )
    }

    func removeDSStoreFiles(in scope: BrowserLocation) {
        guard canRemoveDSStoreFiles, validateConfiguration() else { return }
        runMaintenanceScan(
            arguments: [
                "ds-store",
                "--parent-id", scope.id,
                "--root-path", scope.path,
                "--yes",
            ],
            operation: .dsStoreFiles(scope: scope)
        )
    }

    func cancelMaintenanceScan() {
        guard isMaintenanceScanRunning,
              let maintenanceProcess,
              maintenanceProcess.isRunning
        else { return }

        maintenanceWasCancelled = true
        let message: String
        switch maintenanceOperation {
        case .emptyFolders:
            message = "Cancelling empty-folder scan…"
        case .dsStoreFiles:
            message = "Cancelling .DS_Store scan…"
        default:
            message = "Cancelling maintenance scan…"
        }
        if let kind = taskKind(for: maintenanceOperation) { taskActivity.stopping(kind, message: message) }
        setMaintenanceStatus(message)
        maintenanceProcess.terminate()
    }

    func downloadBrowserItem(_ item: BrowserItem) {
        if isBrowsingSharedLink {
            if !isBrowserItemSelected(item.id) {
                selectBrowserItem(item)
            }
            startSharedDownload(items: [item])
            return
        }
        startDownload(paths: [browserPath(for: item)], items: [item])
    }

    func downloadSelectedBrowserItem() {
        if isBrowsingSharedLink {
            let groups = sharedBrowserSelectionGroups
            guard !groups.isEmpty else {
                setError("Select a file or folder in the browser first.")
                return
            }
            for group in groups {
                guard let session = sharedLinkSessions[group.linkID] else { continue }
                let paths = group.linkID == activeSharedLinkID
                    ? browserItemPaths : session.workspace?.itemPaths ?? [:]
                let base = group.linkID == activeSharedLinkID
                    ? currentBrowserPath : session.workspace?.stack.last?.path ?? "/"
                let overrides = Dictionary(uniqueKeysWithValues: group.items.map {
                    ($0.id, paths[$0.id] ?? joinedRemotePath(folder: base, name: $0.name))
                })
                startSharedDownload(items: group.items, using: session.access, pathOverrides: overrides)
            }
            return
        }
        let items = browserItemsSelectedForAction
        guard !items.isEmpty else {
            setError("Select a file or folder in the browser first.")
            return
        }
        if isBrowsingSharedLink {
            startSharedDownload(items: items)
        } else {
            startDownload(
                paths: items.map { browserPath(for: $0) },
                items: items
            )
        }
    }

    private func startDownload(
        paths requestedPaths: [String],
        items requestedItems: [BrowserItem] = [],
        destination destinationOverride: URL? = nil,
        startImmediately: Bool = false
    ) {
        guard hasUsableSession else {
            presentLogin(reason: "Sign in before downloading files from PikPak.")
            return
        }
        guard validateConfiguration() else { return }

        var seenPaths = Set<String>()
        let paths = requestedPaths.compactMap { requestedPath -> String? in
            var path = requestedPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty else { return nil }
            if !path.hasPrefix("/") {
                path = "/" + path
            }
            guard seenPaths.insert(path).inserted else { return nil }
            return path
        }
        guard !paths.isEmpty else {
            setError("Select at least one remote file or folder to download.")
            return
        }

        let resolvedConcurrentJobs = effectiveDownloadConcurrentJobs
        UserDefaults.standard.set(proxyURL, forKey: "proxyURL")
        let destination = destinationOverride ?? outputURL
        UserDefaults.standard.set(outputURL.path, forKey: "outputPath")
        var itemsByPath: [String: BrowserItem] = [:]
        for item in requestedItems {
            itemsByPath[browserPath(for: item)] = item
        }
        let relativeParents = DownloadQueueBatching.relativeParents(for: paths)
        let roots = paths.enumerated().map { index, path in
            let item = itemsByPath[path]
            let inferredName = (path as NSString).lastPathComponent
            return AccountDownloadRoot(
                queueID: UUID(),
                path: path,
                name: item?.name ?? (inferredName.isEmpty ? path : inferredName),
                kind: item?.kind ?? .file,
                file: item.map { AccountDownloadCachedFile(id: $0.id, name: $0.name, size: String($0.size), kind: $0.kind) },
                relativeParent: relativeParents[index]
            )
        }
        queueDownload(
            .account(
                roots: roots,
                destination: destination,
                jobs: resolvedConcurrentJobs,
                proxyURL: proxyURL
            ),
            startImmediately: startImmediately
        )
    }

    private func startSharedDownload(
        items: [BrowserItem],
        using accessOverride: ShareAccessInput? = nil,
        destination destinationOverride: URL? = nil,
        pathOverrides: [String: String] = [:],
        startImmediately: Bool = false
    ) {
        guard hasUsableSession else {
            presentLogin(reason: "Sign in before downloading files from this shared link.")
            return
        }
        guard let downloadAccess = accessOverride ?? shareAccess,
              !items.isEmpty else { return }
        let resolvedConcurrentJobs = effectiveDownloadConcurrentJobs
        UserDefaults.standard.set(proxyURL, forKey: "proxyURL")
        UserDefaults.standard.set(outputURL.path, forKey: "outputPath")
        let paths = items.map { pathOverrides[$0.id] ?? browserPath(for: $0) }
        let relativeParents = DownloadQueueBatching.relativeParents(for: paths)
        let roots = items.enumerated().map { index, item in
            SharedPendingDownloadRoot(
                queueID: UUID(),
                item: item,
                root: ShareDownloadRoot(
                    id: item.id,
                    name: item.name,
                    size: item.size,
                    kind: item.kind,
                    path: paths[index],
                    relativeParent: relativeParents[index]
                )
            )
        }
        let destination = destinationOverride ?? outputURL
        queueDownload(
            .shared(
                roots: roots,
                access: downloadAccess,
                destination: destination,
                jobs: resolvedConcurrentJobs,
                proxyURL: proxyURL
            ),
            startImmediately: startImmediately
        )
    }

    private func queueDownload(
        _ request: PendingDownloadRequest,
        startImmediately: Bool = false
    ) {
        guard transferStateReady, !isClosingWindow else {
            setError("Open Browser to verify your account and restore saved transfers before adding downloads.")
            return
        }
        let key = request.deduplicationKey
        guard activeDownloadRequestKey != key,
              !activeDownloadSelectionKeys.contains(key),
              !pendingDownloadRequests.contains(where: {
                  $0.deduplicationKey == key
              }) else {
            setStatus("That download selection is already queued or running")
            return
        }
        pendingDownloadRequests.append(request)
        synchronizePendingDownloadQueue()
        guard persistTransfersSynchronously() else { return }
        let noun = request.itemCount == 1 ? "item" : "items"
        setStatus("Added \(request.itemCount.formatted()) \(noun) to the download queue • "
            + (isDownloading ? "will join the next compatible worker batch automatically"
                             : "press Start Download in Transfers when ready"))
        if startImmediately {
            _ = startNextPendingDownloadIfNeeded()
        }
    }

    private func beginDownload(_ request: PendingDownloadRequest) {
        let destination: URL
        let proxy: String
        switch request {
        case .account(_, let requestDestination, _, let requestProxy),
             .shared(_, _, let requestDestination, _, let requestProxy):
            destination = requestDestination
            proxy = requestProxy
        }

        do {
            try FileManager.default.createDirectory(
                at: destination,
                withIntermediateDirectories: true
            )
        } catch {
            activeDownloadRequestKey = nil
            retainInterruptedDownload()
            setError("Cannot create the download folder: \(error.localizedDescription)")
            startNextPendingDownloadIfNeeded()
            return
        }

        resetDownloadProgress()
        switch request {
        case .account(let roots, _, let jobs, _):
            let paths = roots.map(\.path)
            lastAccountDownloadPaths = paths
            lastSharedDownloadItems = []
            lastSharedDownloadAccess = nil
            lastDownloadUsedSharedLink = false

            let arguments = ["download",
                "--output", destination.path,
                "--jobs", String(jobs),
                "--progress-json",
            ]
            runDownloadEngine(
                arguments: arguments,
                operation: .download,
                proxyOverride: proxy,
                accountRequest: AccountDownloadInput(roots: roots.map {
                    .init(path: $0.path, file: $0.file, relativeParent: $0.relativeParent)
                })
            )

        case .shared(let pendingRoots, let access, _, let jobs, _):
            let items = pendingRoots.map(\.item)
            let roots = pendingRoots.map(\.root)
            lastSharedDownloadItems = items
            lastSharedDownloadAccess = access
            lastAccountDownloadPaths = []
            lastDownloadUsedSharedLink = true
            let input = ShareDownloadInput(access: access, roots: roots)
            runDownloadEngine(
                arguments: [
                    "share-download",
                    "--output", destination.path,
                    "--jobs", String(jobs),
                    "--progress-json",
                ],
                operation: .shareDownload(request: input),
                proxyOverride: proxy
            )
        }
    }

    @discardableResult
    private func startNextPendingDownloadIfNeeded() -> Bool {
        guard downloadProcess?.isRunning != true,
              !isDownloading,
              hasUsableSession,
              transferStateReady, !isClosingWindow,
              !pendingDownloadRequests.isEmpty
        else { return false }
        // A settings change applies to waiting batches too, without touching
        // the allocation of an already running engine or its checkpoint.
        pendingDownloadRequests = pendingDownloadRequests.map { $0.withWorkerLimit(effectiveDownloadConcurrentJobs) }
        var selectionKeys = Set<String>()
        if let first = pendingDownloadRequests.first { selectionKeys.insert(first.deduplicationKey) }
        guard let request = DownloadQueueBatching.takeNext(from: &pendingDownloadRequests, combining: { batch, next in
            guard let combined = batch.combining(next) else { return nil }
            selectionKeys.insert(next.deduplicationKey)
            return combined
        }) else { return false }
        activePersistentDownload = request
        synchronizePendingDownloadQueue()
        guard persistTransfersSynchronously() else {
            activePersistentDownload = nil
            pendingDownloadRequests.insert(request, at: 0)
            synchronizePendingDownloadQueue()
            return false
        }
        activeDownloadRequestKey = request.deduplicationKey
        activeDownloadSelectionKeys = selectionKeys
        beginDownload(request)
        if !isDownloading { retainInterruptedDownload() }
        return isDownloading
    }

    /// Compatible user-prepared selections run together with the chosen worker
    /// count. Other destinations/sessions continue automatically afterward;
    /// adding a Browser/Links selection while idle
    /// never starts network transfer by itself.
    func startPendingDownloads() {
        guard canStartPendingDownloads else {
            if pendingDownloadRequests.isEmpty {
                setStatus("The download queue is empty")
            }
            return
        }
        _ = startNextPendingDownloadIfNeeded()
    }

    func removePendingDownloadItem(_ itemID: UUID) {
        guard let requestIndex = pendingDownloadRequests.firstIndex(where: {
            $0.pendingItems.contains(where: { $0.id == itemID })
        }) else { return }

        let itemName = pendingDownloadRequests[requestIndex].pendingItems
            .first(where: { $0.id == itemID })?.name ?? "item"
        if let remaining = pendingDownloadRequests[requestIndex]
            .removingPendingItem(id: itemID) {
            pendingDownloadRequests[requestIndex] = remaining
        } else {
            pendingDownloadRequests.remove(at: requestIndex)
        }
        synchronizePendingDownloadQueue()
        _ = persistTransfersSynchronously()
        setStatus("Removed \(itemName) from the download queue")
    }

    func clearPendingDownloads() {
        guard !pendingDownloadRequests.isEmpty else { return }
        let removedCount = pendingDownloadItems.count
        pendingDownloadRequests.removeAll()
        synchronizePendingDownloadQueue()
        _ = persistTransfersSynchronously()
        setStatus("Removed \(removedCount.formatted()) item(s) from the download queue")
    }

    private func synchronizePendingDownloadQueue() {
        pendingDownloadItems = pendingDownloadRequests.flatMap(\.pendingItems)
        pendingDownloadBatchCount = pendingDownloadRequests.count
        if pendingDownloadRequests.isEmpty { restoredDownloadQueue = false }
    }

    // MARK: Durable transfer batches

    private func transferStore() throws -> TransferPersistenceStore {
        #if FINDER_WORKSPACE_TESTS
        if let accountFixtureTransferDirectory { return TransferPersistenceStore(directory: accountFixtureTransferDirectory) }
        #endif
        #if TRANSFER_PERSISTENCE_TESTS
        if let transferTestDirectory { return TransferPersistenceStore(directory: transferTestDirectory) }
        #endif
        return TransferPersistenceStore(directory: try LocalCredentialStore.applicationSupportDirectoryURL()
            .appendingPathComponent("Transfers", isDirectory: true))
    }

    private func adoptTransferAccount(_ rawAccountID: String) {
        let accountID = rawAccountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accountID.isEmpty, transferAccountID != accountID || !transferStateReady else { return }
        if transferAccountID != accountID { clearTransferAccountContext() }
        transferAccountID = accountID
        do {
            let store = try transferStore()
            let saved = try transferPersistenceQueue.sync {
                try store.load(SavedTransfers.self, accountID: accountID)
            }
            if let saved {
                guard saved.version == 1, saved.accountID == accountID else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                var seen = Set<String>()
                pendingDownloadRequests = saved.downloads.filter { seen.insert($0.deduplicationKey).inserted }
                savedUploadBatches = saved.uploads
                restoredDownloadQueue = !pendingDownloadRequests.isEmpty
                synchronizePendingDownloadQueue()
                if !saved.downloads.isEmpty || !saved.uploads.isEmpty {
                    appendOutput("Restored unfinished transfers. Open Transfers and choose Resume; no transfer starts automatically.\n")
                }
            }
            transferStateReady = true
        } catch {
            // Keep the unreadable file intact instead of silently replacing a
            // potentially recoverable queue with an empty snapshot.
            transferStateReady = false
            setError("Saved transfers could not be restored. The saved file was kept unchanged: \(error.localizedDescription)")
        }
    }

    private func clearTransferAccountContext() {
        fileUndoRefreshFeedback = nil; undoMoveOrigins.removeAll()
        fileUndoHistory.reset()
        uploadUndoMutations.removeAll()
        fileOpenContext = UUID()
        accountProfile = nil
        fileOpener.reset()
        _ = persistTransfersSynchronously()
        cancelBrowserDrag()
        pendingBrowserMoves = []
        browserMoveCorrections = [:]
        transferAccountID = nil
        transferStateReady = false
        pendingDownloadRequests = []
        interruptedDownloadRequests = []
        activePersistentDownload = nil
        activeUploadBatchID = nil
        savedUploadBatches = []
        interruptedDownloadCount = 0
        restoredDownloadQueue = false
        synchronizePendingDownloadQueue()
    }

    private func transferSnapshot() -> SavedTransfers? {
        guard transferStateReady, let accountID = transferAccountID else { return nil }
        var downloads = interruptedDownloadRequests
        if let activePersistentDownload { downloads.append(activePersistentDownload) }
        downloads.append(contentsOf: pendingDownloadRequests)
        return SavedTransfers(version: 1, accountID: accountID,
                             downloads: downloads, uploads: savedUploadBatches)
    }

    @discardableResult
    private func persistTransfersSynchronously() -> Bool {
        transferPersistenceScheduled = false
        guard !isClosingWindow, let snapshot = transferSnapshot() else { return false }
        do {
            let store = try transferStore()
            try transferPersistenceQueue.sync { try store.save(snapshot, accountID: snapshot.accountID) }
            return true
        } catch {
            setError("Could not save unfinished transfers for resume: \(error.localizedDescription)")
            return false
        }
    }

    private func scheduleTransferPersistence() {
        guard !isClosingWindow, transferStateReady, !transferPersistenceScheduled else { return }
        transferPersistenceScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.transferPersistenceScheduled, !self.isClosingWindow else { return }
            self.transferPersistenceScheduled = false
            self.updateSavedUploadProgress()
            guard let snapshot = self.transferSnapshot() else { return }
            do {
                let store = try self.transferStore()
                self.transferPersistenceQueue.async { [weak self] in
                    do { try store.save(snapshot, accountID: snapshot.accountID) }
                    catch {
                        Task { @MainActor [weak self] in
                            self?.setError("Could not update the saved transfer state: \(error.localizedDescription)")
                        }
                    }
                }
            } catch { self.setError("Could not save transfers: \(error.localizedDescription)") }
        }
    }

    private func retainInterruptedDownload() {
        if let request = activePersistentDownload,
           !interruptedDownloadRequests.contains(where: { $0.deduplicationKey == request.deduplicationKey }) {
            interruptedDownloadRequests.append(request)
        }
        activePersistentDownload = nil
        interruptedDownloadCount = interruptedDownloadRequests.reduce(0) { $0 + $1.itemCount }
        _ = persistTransfersSynchronously()
    }

    func requeueInterruptedDownloads() {
        guard transferStateReady, !interruptedDownloadRequests.isEmpty else { return }
        let existing = Set(pendingDownloadRequests.map(\.deduplicationKey))
        pendingDownloadRequests.insert(contentsOf: interruptedDownloadRequests.filter {
            !existing.contains($0.deduplicationKey)
        }, at: 0)
        interruptedDownloadRequests = []
        interruptedDownloadCount = 0
        restoredDownloadQueue = true
        synchronizePendingDownloadQueue()
        _ = persistTransfersSynchronously()
        setStatus("Interrupted downloads returned to the queue. Press Resume Downloads when ready.")
    }

    var resumableUploadBatches: [SavedUploadBatch] {
        savedUploadBatches.filter { $0.id != activeUploadBatchID }
    }

    private func updateSavedUploadProgress() {
        guard let index = savedUploadBatches.firstIndex(where: { $0.id == activeUploadBatchID }) else { return }
        var batch = savedUploadBatches[index]
        batch.totalFiles = uploadTotalFiles
        batch.completedFiles = uploadCompletedFiles + uploadInstantFiles
        batch.totalBytes = uploadTotalBytes
        batch.completedBytes = settledUploadBytes
        if savedUploadBatches[index] != batch { savedUploadBatches[index] = batch }
    }

    func resumeSavedUpload(_ batchID: UUID) {
        guard canUploadFiles, let batch = savedUploadBatches.first(where: { $0.id == batchID }) else { return }
        _ = startUpload(files: batch.sources.map { URL(fileURLWithPath: $0) },
                        destination: batch.destination, resumingBatch: batch)
    }

    func discardSavedUpload(_ batchID: UUID) {
        guard batchID != activeUploadBatchID else { return }
        savedUploadBatches.removeAll { $0.id == batchID }
        if persistTransfersSynchronously() { removeUploadCheckpoint(batchID) }
        setStatus("Removed saved upload. Local files and uploaded cloud files were not deleted.")
    }

    private func removeUploadCheckpoint(_ batchID: UUID) {
        guard let accountID = transferAccountID, let store = try? transferStore() else { return }
        transferPersistenceQueue.async {
            // Only this batch's private journal, never the user's sources or
            // any destination directory. UUID comes from our saved batch.
            if let directory = try? store.uploadDirectory(accountID: accountID, batchID: batchID) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    #if TRANSFER_PERSISTENCE_TESTS
    /// Compiled only into the offline regression harness. No real credentials,
    /// browser snapshots, user defaults, or network helper are touched.
    static func testTransferLifecycle(in directory: URL, fixture: SavedTransfers) throws {
        let first = DownloaderModel(transferTestDirectory: directory)
        first.adoptTransferAccount(fixture.accountID)
        for request in fixture.downloads { first.queueDownload(request) }
        first.activePersistentDownload = first.pendingDownloadRequests.removeFirst()
        first.synchronizePendingDownloadQueue()
        first.savedUploadBatches = fixture.uploads
        first.activeUploadBatchID = fixture.uploads[0].id
        first.uploadTotalFiles = 2000
        first.uploadCompletedFiles = 1900
        first.uploadInstantFiles = 80
        first.uploadTotalBytes = 5000
        first.settledUploadBytes = 4500
        first.stopForWindowClose()
        first.stopForWindowClose() // duplicate view-disappear/AppDelegate calls
        // A late termination callback must not remove the resumable selection.
        first.finishDownloadProcess(exitCode: 0, errorOutput: "", operation: .download)
        let reopened = DownloaderModel(transferTestDirectory: directory)
        reopened.adoptTransferAccount(fixture.accountID)
        precondition(reopened.pendingDownloadRequests.count == 2 && reopened.restoredDownloadQueue)
        precondition(reopened.resumableUploadBatches == fixture.uploads)
        precondition(!reopened.isDownloading && !reopened.isUploading)
        reopened.activePersistentDownload = reopened.pendingDownloadRequests.removeFirst()
        reopened.synchronizePendingDownloadQueue()
        reopened.retainInterruptedDownload()
        precondition(reopened.interruptedDownloadCount == 1)
        reopened.requeueInterruptedDownloads()
        precondition(reopened.pendingDownloadRequests.count == 2 && reopened.interruptedDownloadCount == 0)
        reopened.removePendingDownloadItem(reopened.pendingDownloadItems[0].id)
        let afterRemoval = DownloaderModel(transferTestDirectory: directory)
        afterRemoval.adoptTransferAccount(fixture.accountID)
        precondition(afterRemoval.pendingDownloadRequests.count == 1)
        afterRemoval.adoptTransferAccount("different-account")
        precondition(afterRemoval.pendingDownloadRequests.isEmpty && afterRemoval.savedUploadBatches.isEmpty)
        afterRemoval.adoptTransferAccount(fixture.accountID)
        precondition(afterRemoval.pendingDownloadRequests.count == 1 && afterRemoval.savedUploadBatches.count == 1)
        afterRemoval.clearPendingDownloads()
        afterRemoval.discardSavedUpload(fixture.uploads[0].id)
        let cleared = DownloaderModel(transferTestDirectory: directory)
        cleared.adoptTransferAccount(fixture.accountID)
        precondition(cleared.pendingDownloadRequests.isEmpty && cleared.savedUploadBatches.isEmpty)
    }
    #endif

    func retryFailedDownloads() {
        let retryableTransfers = failedDownloadTransfers.filter(canRetryFailedDownload)
        guard !retryableTransfers.isEmpty else { return }
        for transfer in retryableTransfers {
            retryFailedDownload(transfer)
        }
    }

    func canRetryFailedDownload(_ transfer: DownloadTransfer) -> Bool {
        guard transfer.state == .failed || transfer.state == .stopped,
              hasUsableSession,
              let remotePath = transfer.remotePath,
              !remotePath.isEmpty,
              let outputDirectoryPath = transfer.outputDirectoryPath,
              !outputDirectoryPath.isEmpty
        else { return false }
        return !transfer.isShared || downloadSharedAccessByFileID[transfer.id] != nil
    }

    /// Retry exactly one failed file, preserving its original remote source,
    /// shared-link authorization (when applicable), and nested local output
    /// directory. Other failed rows stay available for independent retry.
    func retryFailedDownload(_ transfer: DownloadTransfer) {
        guard canRetryFailedDownload(transfer),
              let remotePath = transfer.remotePath,
              let outputDirectoryPath = transfer.outputDirectoryPath
        else { return }

        removeFailedDownloadFromHistory(transfer)
        let destination = URL(fileURLWithPath: outputDirectoryPath, isDirectory: true)
        if transfer.isShared {
            guard let access = downloadSharedAccessByFileID[transfer.id] else { return }
            let item = BrowserItem(
                id: transfer.id,
                name: transfer.name,
                size: transfer.totalBytes,
                kind: .file,
                parentId: nil,
                mimeType: nil,
                createdTime: nil,
                modifiedTime: nil,
                fileExtension: nil,
                iconLink: nil,
                thumbnailLink: nil,
                fileCategory: nil,
                hash: nil,
                md5Checksum: nil
            )
            startSharedDownload(
                items: [item],
                using: access,
                destination: destination,
                pathOverrides: [transfer.id: remotePath],
                startImmediately: true
            )
        } else {
            startDownload(
                paths: [remotePath],
                destination: destination,
                startImmediately: true
            )
        }
    }

    func saveSelectedSharedItems() {
        guard isBrowsingSharedLink else { return }
        let groups = sharedBrowserSelectionGroups
        guard !groups.isEmpty else {
            setShareLinkFeedback("Select at least one shared file or folder to save.", tone: .error)
            return
        }
        for group in groups {
            saveSharedItems(group.items, in: group.linkID)
        }
    }

    /// The row action saves exactly one item without replacing a different
    /// multi-selection just to reuse the toolbar's selection-based command.
    func saveSharedItem(_ item: BrowserItem, in linkID: UUID? = nil) {
        guard let linkID = linkID ?? activeSharedLinkID else { return }
        saveSharedItems([item], in: linkID)
    }

    private func saveSharedItems(_ selectedItems: [BrowserItem], in linkID: UUID) {
        guard let session = sharedLinkSessions[linkID],
              session.workspace != nil,
              sharedLinks.first(where: { $0.id == linkID })?.state == .ready else {
            setShareLinkFeedback("Open a shared link before saving items.", tone: .error)
            return
        }
        guard hasUsableSession else {
            setShareLinkFeedback("Sign in before saving shared items to PikPak.", tone: .error)
            presentLogin(reason: "Sign in to save selected shared items to your PikPak account.")
            return
        }
        guard !selectedItems.isEmpty else {
            setShareLinkFeedback("Select at least one shared file or folder to save.", tone: .error)
            return
        }
        let items = selectedItems.filter { item in
            !isSharedItemSaved(item.id, in: linkID)
                && !isSharedItemSavingOrQueued(item.id, in: linkID)
        }
        guard !items.isEmpty else {
            if selectedItems.allSatisfy({ isSharedItemSaved($0.id, in: linkID) }) {
                setShareLinkFeedback("The selected items are already saved to My PikPak.", tone: .success)
            } else {
                setShareLinkFeedback("The selected items are already being saved.", tone: .progress)
            }
            return
        }
        let request = ShareSaveInput(access: session.access, fileIds: items.map(\.id).sorted())
        let description = items.count == 1 ? items[0].name : "\(items.count.formatted()) selected items"
        let pending = PendingSharedSaveRequest(
            request: request,
            linkID: linkID,
            description: description
        )
        if sharedSaveProcesses[linkID]?.isRunning == true {
            let key = pending.deduplicationKey
            guard !pendingSharedSaveRequests.contains(where: {
                $0.deduplicationKey == key
            }) else {
                setShareLinkFeedback("That selection is already queued to save.", tone: .info)
                return
            }
            pendingSharedSaveRequests.append(pending)
            setShareLinkFeedback(
                "Save queued for \(description); it will start after this link's current save.",
                tone: .progress
            )
            setStatus("Save to My PikPak queued")
            return
        }
        startSharedSave(pending)
    }

    private func startSharedSave(_ pending: PendingSharedSaveRequest) {
        guard hasUsableSession,
              sharedLinkSessions[pending.linkID] != nil,
              sharedSaveProcesses[pending.linkID]?.isRunning != true else { return }
        runSharedSave(pending)
    }

    @discardableResult
    private func startNextPendingSharedSaveIfNeeded(for requestedLinkID: UUID? = nil) -> Bool {
        guard !isLoginPresented,
              hasUsableSession,
              !pendingSharedSaveRequests.isEmpty
        else { return false }
        let queuedRequests = pendingSharedSaveRequests
        pendingSharedSaveRequests = []
        var started = false
        for pending in queuedRequests {
            let isRequestedLink = requestedLinkID == nil || pending.linkID == requestedLinkID
            if isRequestedLink,
               sharedSaveProcesses[pending.linkID]?.isRunning != true,
               sharedLinkSessions[pending.linkID] != nil {
                startSharedSave(pending)
                started = true
            } else {
                pendingSharedSaveRequests.append(pending)
            }
        }
        return started
    }

    /// Save-to-PikPak has its own per-link helper instead of borrowing the
    /// foreground Browser process. This keeps outline selection, previews, and
    /// disconnect controls for every unrelated link responsive during a save.
    private func runSharedSave(_ pending: PendingSharedSaveRequest) {
        let linkID = pending.linkID
        #if FINDER_WORKSPACE_TESTS
        if isFinderWorkspaceFixture {
            sharedSaveFixtureRequests.append(pending)
            finishShareSave(output: "{\"restore_status\":\"complete\",\"saved_count\":\(pending.request.fileIds.count)}",
                            requestedIDs: pending.request.fileIds, linkID: linkID)
            return
        }
        #endif
        guard let engineURL = Bundle.main.url(forResource: "pikpak", withExtension: nil) else {
            setShareLinkFeedback("The bundled shared-link engine is missing.", tone: .error)
            return
        }

        var requestURL: URL?
        let process = Process()
        do {
            let exchangeDirectory = try makePrivateExchangeDirectory()
            let encodedRequestURL = try writePrivateRequest(
                pending.request,
                named: "share-save-\(linkID.uuidString)",
                in: exchangeDirectory
            )
            requestURL = encodedRequestURL

            let stdout = Pipe()
            let stderr = Pipe()
            let stdoutBuffer = ProcessOutputBuffer()
            let stderrBuffer = ProcessOutputBuffer()

            process.executableURL = engineURL
            process.arguments = [
                "share-save",
                "--request-file", encodedRequestURL.path,
            ]
            process.standardOutput = stdout
            process.standardError = stderr
            process.currentDirectoryURL = exchangeDirectory
            process.qualityOfService = .userInitiated

            var environment = try engineEnvironment()
            let proxy = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if proxy.isEmpty {
                environment.removeValue(forKey: "PIKPAK_PROXY")
            } else {
                environment["PIKPAK_PROXY"] = proxy
            }
            process.environment = environment

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                stdoutBuffer.append(data)
            }
            stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                stderrBuffer.append(data)
                if let text = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async {
                        self?.appendOutput(self?.redactedEngineOutput(text) ?? text)
                    }
                }
            }

            process.terminationHandler = { [weak self] finishedProcess in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                stdoutBuffer.append(stdout.fileHandleForReading.readDataToEndOfFile())
                stderrBuffer.append(stderr.fileHandleForReading.readDataToEndOfFile())
                let structuredOutput = stdoutBuffer.string()
                let errorOutput = stderrBuffer.string()
                DispatchQueue.main.async {
                    self?.finishSharedSaveProcess(
                        pending: pending,
                        process: finishedProcess,
                        exitCode: finishedProcess.terminationStatus,
                        structuredOutput: structuredOutput,
                        errorOutput: errorOutput
                    )
                }
            }

            sharedSaveProcesses[linkID] = process
            sharedSaveInputURLs[linkID] = encodedRequestURL
            savingSharedItemIDsByLinkID[linkID] = Set(pending.request.fileIds)
            isSavingSharedItems = true
            if activeSharedLinkID == linkID {
                setShareLinkFeedback(
                    "Saving \(pending.description) to Pack From Shared…",
                    tone: .progress
                )
            }
            if !isRunning {
                setStatus("Saving \(pending.description) to My PikPak…")
            }
            try process.run()
        } catch {
            if let trackedProcess = sharedSaveProcesses[linkID],
               trackedProcess === process {
                sharedSaveProcesses.removeValue(forKey: linkID)
            }
            let inputURL = sharedSaveInputURLs.removeValue(forKey: linkID) ?? requestURL
            if let inputURL {
                try? FileManager.default.removeItem(at: inputURL)
            }
            savingSharedItemIDsByLinkID.removeValue(forKey: linkID)
            isSavingSharedItems = sharedSaveProcesses.values.contains(where: { $0.isRunning })
            let launchDiagnostic = diagnostic(
                for: error,
                source: "macOS shared-save process launcher"
            )
            if activeSharedLinkID == linkID {
                setShareLinkFeedback(
                    "The selected items could not be saved: \(error.localizedDescription)",
                    tone: .error
                )
            }
            appendOutput("A shared save could not start.\n\(launchDiagnostic.displayText)\n")
            requireFreshAppLoginIfSessionTrustFailed(error)
            _ = startNextPendingSharedSaveIfNeeded(for: linkID)
        }
    }

    private func finishSharedSaveProcess(
        pending: PendingSharedSaveRequest,
        process finishedProcess: Process,
        exitCode: Int32,
        structuredOutput: String,
        errorOutput: String
    ) {
        let linkID = pending.linkID
        guard let trackedProcess = sharedSaveProcesses[linkID],
              trackedProcess === finishedProcess else { return }

        sharedSaveProcesses.removeValue(forKey: linkID)
        if let inputURL = sharedSaveInputURLs.removeValue(forKey: linkID) {
            try? FileManager.default.removeItem(at: inputURL)
        }
        savingSharedItemIDsByLinkID.removeValue(forKey: linkID)
        isSavingSharedItems = sharedSaveProcesses.values.contains(where: { $0.isRunning })
        let stoppedForLogin = sharedSavesStoppedForLogin.remove(linkID) != nil
        synchronizeSharedSessionFromDisk()

        if !stoppedForLogin,
           sharedLinkSessions[linkID] != nil,
           sharedLinks.contains(where: { $0.id == linkID }) {
            if exitCode == 0 {
                finishShareSave(
                    output: structuredOutput,
                    requestedIDs: pending.request.fileIds,
                    linkID: linkID
                )
            } else {
                let operation = Operation.shareSave(
                    request: pending.request,
                    itemCount: pending.request.fileIds.count,
                    linkID: linkID
                )
                let failure = engineErrorPresentation(
                    errorOutput,
                    operation: operation,
                    exitCode: exitCode
                )
                if activeSharedLinkID == linkID {
                    setShareLinkFeedback(
                        "The selected items could not be saved. \(failure.summary)",
                        tone: .error
                    )
                }
                appendOutput("A shared save failed.\n\(failure.diagnostic.displayText)\n")
                handleWebLoginNeeded(for: errorOutput)
            }
        }

        _ = startNextPendingSharedSaveIfNeeded(for: linkID)
        if sharedSaveProcesses.isEmpty {
            presentDeferredLoginIfNeeded()
            startPendingQuotaRefreshIfNeeded()
        }
    }

    func stop() {
        guard isDownloading, let downloadProcess, downloadProcess.isRunning else { return }
        downloadRequestedStop = true
        downloadRunState = .stopping
        setStatus("Stopping safely; partial files and waiting queue items will be kept…")
        downloadProcess.terminate()
    }

    func stopForWindowClose() {
        fileSimilarity.close()
        _ = cancelQuickLook()
        quickLookCopies.removeAll(); quickLookCopyOrder.removeAll()
        fileOpener.cancelAll()
        pendingSharedLinkLoads = []
        sharedLinkRetryBatchIDs = []
        sharedLinkRetryProgress = nil
        #if FINDER_WORKSPACE_TESTS
        if isFinderWorkspaceFixture {
            isClosingWindow = true
            sharedLinkLoadProcesses.removeAll()
            fileSearch.close()
            return
        }
        #endif
        guard !isClosingWindow else { return }
        flushAllUploadOutputLines()
        updateSavedUploadProgress()
        _ = persistTransfersSynchronously()
        isClosingWindow = true
        cancelAccountCheck()
        folderSizeRepairTask?.cancel()
        persistFolderMeasurementsNow()
        // Drain the final debounced size snapshot before normal application exit.
        folderMeasurementCacheQueue.sync {}
        #if TRANSFER_PERSISTENCE_TESTS
        if transferTestDirectory != nil { return }
        #endif
        fileSearch.close()
        cancelBrowserTreeLoads()
        pendingFileSearchNavigation = nil
        cancelAutomaticPreviewNavigation()
        pendingBrowserTreeLoads = []
        pendingSharedSaveRequests = []
        activeDownloadRequestKey = nil
        clearPreview()
        clearPreviewResourceCaches()
        if isBrowsingSharedLink {
            saveActiveBrowserWorkspace()
        }
        // Flush after all previously queued snapshots so a normal Quit always
        // leaves the latest URL list, disclosures, and loaded trees on disk.
        persistSharedLinkStateSynchronously()
        let linkLoadProcesses = sharedLinkLoadProcesses
        let linkLoadInputs = sharedLinkLoadInputURLs.values
        let saveProcesses = sharedSaveProcesses
        let saveInputs = sharedSaveInputURLs.values
        sharedLinkLoadProcesses.removeAll()
        sharedLinkLoadInputURLs.removeAll()
        sharedLinkLoadsStoppedForLogin.removeAll()
        sharedSaveProcesses.removeAll()
        sharedSaveInputURLs.removeAll()
        sharedSavesStoppedForLogin.removeAll()
        savingSharedItemIDsByLinkID.removeAll()
        isSavingSharedItems = false
        for process in linkLoadProcesses.values where process.isRunning {
            process.terminate()
        }
        for inputURL in linkLoadInputs {
            try? FileManager.default.removeItem(at: inputURL)
        }
        for process in saveProcesses.values where process.isRunning {
            process.terminate()
        }
        for inputURL in saveInputs {
            try? FileManager.default.removeItem(at: inputURL)
        }
        if let downloadProcess, downloadProcess.isRunning {
            downloadRequestedStop = true
            downloadProcess.terminate()
        }
        if let duplicateProcess, duplicateProcess.isRunning {
            duplicateScanWasCancelled = true
            duplicateProcess.terminate()
        }
        if let maintenanceProcess, maintenanceProcess.isRunning {
            maintenanceWasCancelled = true
            maintenanceProcess.terminate()
        }
        if let mergeProcess, mergeProcess.isRunning {
            mergeWasCancelled = true
            mergeProcess.terminate()
        }
        if let uploadProcess, uploadProcess.isRunning {
            uploadRequestedStop = true
            if isUploadPaused {
                _ = uploadProcess.resume()
                isUploadPaused = false
            }
            uploadProcess.terminate()
        }
        for (taskID, archiveProcess) in archiveProcesses where archiveProcess.isRunning {
            stoppedArchiveTaskIDs.insert(taskID)
            archiveProcess.terminate()
        }
        clearPendingFolderMeasurements()
        if let folderMeasurementProcess, folderMeasurementProcess.isRunning {
            folderMeasurementWasCancelled = true
            folderMeasurementProcess.terminate()
        }
        if let process, process.isRunning {
            requestedStop = false
            process.terminate()
        }
    }

    func clearLog() {
        log = ""
    }

    private func rememberBrowserPosition(beforeOpening item: BrowserItem) {
        let visibleEntries = browserTreeEntries
        guard
            let location = browserStack.last,
            let index = visibleEntries.firstIndex(where: { $0.id == item.id })
        else { return }

        // Keep snapshots only for the active ancestry. This preserves Back and
        // breadcrumb navigation without accumulating every folder ever visited.
        let activeLocationIDs = Set(browserStack.map(\.id))
        browserFolderSnapshots = browserFolderSnapshots.filter {
            activeLocationIDs.contains($0.key)
        }
        browserFolderSnapshots[location.id] = BrowserFolderSnapshot(
            items: browserItems,
            nextPageToken: nextPageToken,
            anchorItemID: item.id,
            anchorIndex: index,
            expandedFolderIDs: expandedBrowserFolderIDs,
            childrenByFolderID: browserTreeChildren,
            childPageTokens: browserTreeNextPageTokens,
            itemPaths: browserItemPaths,
            parentIDs: browserItemParentIDs,
            loadErrors: browserTreeLoadErrors
        )
        browserScrollRestoreRequest = nil
    }

    /// Opening a nested outline row used to append only that row, producing a
    /// misleading `PikPak > leaf` breadcrumb. Rebuild the route through every
    /// cached parent until it reaches the folder currently being browsed.
    private func browserNavigationStack(opening item: BrowserItem) -> [BrowserLocation] {
        guard let currentLocation = browserStack.last else {
            return [browserLocation(for: item)]
        }

        var routeItems = [item]
        var cursorID = item.id
        var visitedIDs: Set<String> = [item.id]

        while true {
            guard let parentID = browserItemParentIDs[cursorID] else {
                return browserStack + [browserLocation(for: item)]
            }
            if parentID == currentLocation.id {
                break
            }
            guard visitedIDs.insert(parentID).inserted,
                  let parent = browserItem(withID: parentID),
                  parent.isFolder
            else {
                return browserStack + [browserLocation(for: item)]
            }
            routeItems.append(parent)
            cursorID = parent.id
        }

        return browserStack + routeItems.reversed().map(browserLocation(for:))
    }

    /// A direct jump through expanded outline rows has no separately rendered
    /// intermediate folder screens. Synthesize their snapshots from the same
    /// cached child lists so clicking any new breadcrumb still restores the
    /// row through which the user entered that level.
    private func rememberIntermediateBrowserPositions(in targetStack: [BrowserLocation]) {
        let firstNewIndex = browserStack.count
        guard targetStack.count - firstNewIndex > 1 else { return }

        for index in firstNewIndex..<(targetStack.count - 1) {
            let location = targetStack[index]
            let nextLocation = targetStack[index + 1]
            guard let items = browserTreeChildren[location.id],
                  let anchorIndex = items.firstIndex(where: { $0.id == nextLocation.id })
            else { continue }

            browserFolderSnapshots[location.id] = BrowserFolderSnapshot(
                items: items,
                nextPageToken: browserTreeNextPageTokens[location.id],
                anchorItemID: nextLocation.id,
                anchorIndex: anchorIndex,
                expandedFolderIDs: expandedBrowserFolderIDs,
                childrenByFolderID: browserTreeChildren,
                childPageTokens: browserTreeNextPageTokens,
                itemPaths: browserItemPaths,
                parentIDs: browserItemParentIDs,
                loadErrors: browserTreeLoadErrors
            )
        }
    }

    private func restoreBrowserFolder(from stack: [BrowserLocation]) -> Bool {
        guard
            let location = stack.last,
            let snapshot = browserFolderSnapshots[location.id]
        else { return false }

        cancelBrowserTreeLoads()
        cancelAutomaticPreviewNavigation()
        clearPreview()
        clearFolderMeasurement()

        browserItems = snapshot.items
        browserStack = stack
        nextPageToken = snapshot.nextPageToken
        expandedBrowserFolderIDs = snapshot.expandedFolderIDs
        browserTreeChildren = snapshot.childrenByFolderID
        browserTreeNextPageTokens = snapshot.childPageTokens
        browserItemPaths = snapshot.itemPaths
        browserItemParentIDs = snapshot.parentIDs
        browserTreeLoadErrors = snapshot.loadErrors
        browserTreeLoadingFolderIDs = []
        applyBrowserSortToCachedItems()

        let visibleEntries = browserTreeEntries
        let restoredIndex: Int?
        if let exactIndex = visibleEntries.firstIndex(where: {
            $0.item.id == snapshot.anchorItemID
        }) {
            restoredIndex = exactIndex
        } else if visibleEntries.isEmpty {
            restoredIndex = nil
        } else {
            restoredIndex = min(snapshot.anchorIndex, visibleEntries.count - 1)
        }

        if let restoredIndex {
            let itemID = visibleEntries[restoredIndex].item.id
            selectedBrowserItemIDs = [itemID]
            browserSelectionAnchorID = itemID
            selectedBrowserItemID = itemID
            browserScrollRestoreRequest = BrowserScrollRestoreRequest(itemID: itemID)
            setStatus(
                "Returned to \(location.name) at item \((restoredIndex + 1).formatted())"
            )
        } else {
            clearBrowserSelection()
            browserScrollRestoreRequest = nil
            setStatus("Returned to \(location.name)")
        }

        let activeLocationIDs = Set(stack.map(\.id))
        browserFolderSnapshots = browserFolderSnapshots.filter {
            activeLocationIDs.contains($0.key)
        }
        if isBrowsingSharedLink {
            saveActiveBrowserWorkspace()
        }
        return true
    }

    private func loadFolder(
        stack: [BrowserLocation],
        append: Bool,
        includeQuota: Bool = false,
        preserveOutline: Bool = false
    ) {
        #if FINDER_WORKSPACE_TESTS
        if isFinderWorkspaceFixture {
            guard let location = stack.last else { return }
            browserStack = stack
            browserItems = finderFixtureFolders[location.id] ?? []
            selectedBrowserItemID = nil
            selectedBrowserItemIDs = []
            setStatus("Offline folder refreshed — no network or cloud changes")
            return
        }
        #endif
        guard let location = stack.last else { return }
        if !append {
            cancelBrowserTreeLoads()
            browserScrollRestoreRequest = nil
        }
        if isBrowsingSharedLink {
            guard let shareAccess, shareLinkIsOpen else { return }
            let request = ShareBrowseInput(
                access: shareAccess,
                parentId: location.id,
                pageToken: append ? nextPageToken : nil,
                limit: 200
            )
            runEngine(
                arguments: ["share-browse"],
                operation: .shareBrowse(
                    request: request,
                    stack: stack,
                    append: append,
                    initial: false
                )
            )
            return
        }

        guard validateConfiguration() else { return }
        var arguments = [
            "browse",
            "--parent-id", location.id,
            "--limit", "200",
        ]
        if append, let nextPageToken, !nextPageToken.isEmpty {
            arguments += ["--page-token", nextPageToken]
        }
        if includeQuota {
            arguments.append("--with-quota")
        }
        runEngine(
            arguments: arguments,
            operation: .browse(
                stack: stack,
                append: append,
                includesQuota: includeQuota,
                preservesOutline: preserveOutline
            )
        )
    }

    /// Switching folder trees (navigation, link switch, sign-out) must not let
    /// an in-flight listing land in the workspace that replaced it.
    private func cancelBrowserTreeLoads() {
        cancelBrowserFolderExpansion(announcesResult: false)
        let processes = browserTreeLoadProcesses
        browserTreeLoadProcesses = [:]
        browserTreeLoadGenerations = [:]
        browserTreeLoadExpansionOwners = [:]
        pendingBrowserTreeLoads = []
        browserTreeLoadingFolderIDs = []
        browserMoveCorrections = [:]
        for process in processes.values where process.isRunning {
            process.terminationHandler = nil
            process.terminate()
        }
        for inputURL in browserTreeLoadInputURLs.values {
            try? FileManager.default.removeItem(at: inputURL)
        }
        browserTreeLoadInputURLs = [:]
    }

    private func cancelBrowserTreeLoad(_ folderID: String) {
        browserTreeLoadGenerations.removeValue(forKey: folderID)
        browserTreeLoadExpansionOwners.removeValue(forKey: folderID)
        if let process = browserTreeLoadProcesses.removeValue(forKey: folderID), process.isRunning {
            process.terminationHandler = nil
            process.terminate()
        }
        if let inputURL = browserTreeLoadInputURLs.removeValue(forKey: folderID) {
            try? FileManager.default.removeItem(at: inputURL)
        }
        browserTreeLoadingFolderIDs.remove(folderID)
    }

    @discardableResult
    private func loadBrowserTreeFolder(_ item: BrowserItem, append: Bool, expansionID: UUID? = nil) -> Bool {
        let folderPath = browserPath(for: item)
        if isBrowsingSharedLink {
            guard let shareAccess, shareLinkIsOpen else { return false }
            let request = ShareBrowseInput(
                access: shareAccess,
                parentId: item.id,
                pageToken: append ? browserTreeNextPageTokens[item.id] : nil,
                limit: 500
            )
            return runBrowserTreeHelper(
                item: item,
                folderPath: folderPath,
                append: append,
                shareRequest: request,
                expansionID: expansionID
            )
        }

        #if FOLDER_EXPANSION_TESTS
        if !isFolderExpansionFixture, !validateConfiguration() { return false }
        #else
        guard validateConfiguration() else { return false }
        #endif
        return runBrowserTreeHelper(
            item: item,
            folderPath: folderPath,
            append: append,
            shareRequest: nil,
            expansionID: expansionID
        )
    }

    /// One helper process per expanding folder. Deliberately does not touch
    /// `isRunning`: expansions are read-only listings, so they neither block
    /// each other nor the foreground lane that previews and actions use.
    /// Concurrency is capped by the caller; token rotation across processes is
    /// already serialized by the shared lock and session file.
    private func runBrowserTreeHelper(
        item: BrowserItem,
        folderPath: String,
        append: Bool,
        shareRequest: ShareBrowseInput?,
        expansionID: UUID? = nil
    ) -> Bool {
        guard hasUsableSession else {
            presentLogin(reason: "Complete the desktop-session sign-in before accessing PikPak.")
            return false
        }
        guard !isActivelyLoadingBrowserTreeFolder(item.id) else { return true }
        let generation = UUID()
        #if FOLDER_EXPANSION_TESTS
        if isFolderExpansionFixture {
            browserTreeLoadProcesses[item.id] = Process()
            browserTreeLoadGenerations[item.id] = generation
            browserTreeLoadExpansionOwners[item.id] = expansionID
            browserTreeLoadingFolderIDs.insert(item.id)
            recordedExpansionLoads.append((item.id, append, append ? browserTreeNextPageTokens[item.id] : nil, generation))
            return true
        }
        #endif
        guard let engineURL = Bundle.main.url(forResource: "pikpak", withExtension: nil) else {
            browserTreeLoadingFolderIDs.remove(item.id)
            setError("The bundled download engine is missing. Rebuild the app.")
            browserTreeLoadErrors[item.id] = "The bundled download engine is missing. Rebuild the app."
            return false
        }

        let folderID = item.id
        let folderName = item.name
        let sizeRevision = folderSizeRevision
        var requestURL: URL?
        let process = Process()
        do {
            let exchangeDirectory = try makePrivateExchangeDirectory()
            var arguments: [String]
            if let shareRequest {
                let encoded = try writePrivateRequest(
                    shareRequest,
                    named: "share-tree-\(UUID().uuidString)",
                    in: exchangeDirectory
                )
                requestURL = encoded
                arguments = ["share-browse", "--request-file", encoded.path]
            } else {
                arguments = ["browse", "--parent-id", folderID, "--limit", "500"]
                if append,
                   let pageToken = browserTreeNextPageTokens[folderID],
                   !pageToken.isEmpty {
                    arguments += ["--page-token", pageToken]
                }
            }

            let stdout = Pipe()
            let stderr = Pipe()
            let stdoutBuffer = ProcessOutputBuffer()
            let stderrBuffer = ProcessOutputBuffer()

            process.executableURL = engineURL
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = stderr
            process.currentDirectoryURL = exchangeDirectory
            process.qualityOfService = .userInitiated

            var environment = try engineEnvironment()
            let proxy = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if proxy.isEmpty {
                environment.removeValue(forKey: "PIKPAK_PROXY")
            } else {
                environment["PIKPAK_PROXY"] = proxy
            }
            process.environment = environment

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                stdoutBuffer.append(data)
            }
            stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                stderrBuffer.append(data)
                if let text = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async {
                        self?.appendOutput(self?.redactedEngineOutput(text) ?? text)
                    }
                }
            }

            let isShared = shareRequest != nil
            process.terminationHandler = { [weak self] finished in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                stdoutBuffer.append(stdout.fileHandleForReading.readDataToEndOfFile())
                stderrBuffer.append(stderr.fileHandleForReading.readDataToEndOfFile())
                let structuredOutput = stdoutBuffer.string()
                let errorOutput = stderrBuffer.string()
                let exitCode = finished.terminationStatus
                DispatchQueue.main.async {
                    self?.finishBrowserTreeHelper(
                        generation: generation,
                        folderID: folderID,
                        folderName: folderName,
                        folderPath: folderPath,
                        append: append,
                        isShared: isShared,
                        sizeRevision: sizeRevision,
                        exitCode: exitCode,
                        structuredOutput: structuredOutput,
                        errorOutput: errorOutput
                    )
                }
            }

            browserTreeLoadProcesses[folderID] = process
            browserTreeLoadGenerations[folderID] = generation
            browserTreeLoadExpansionOwners[folderID] = expansionID
            if let requestURL {
                browserTreeLoadInputURLs[folderID] = requestURL
            }
            browserTreeLoadingFolderIDs.insert(folderID)
            try process.run()
            return true
        } catch {
            if let tracked = browserTreeLoadProcesses[folderID], tracked === process {
                browserTreeLoadProcesses.removeValue(forKey: folderID)
            }
            if let inputURL = browserTreeLoadInputURLs.removeValue(forKey: folderID) ?? requestURL {
                try? FileManager.default.removeItem(at: inputURL)
            }
            browserTreeLoadingFolderIDs.remove(folderID)
            browserTreeLoadGenerations.removeValue(forKey: folderID)
            browserTreeLoadExpansionOwners.removeValue(forKey: folderID)
            browserTreeLoadErrors[folderID] = "This folder could not be opened."
            appendOutput("A folder helper could not start: \(error.localizedDescription)\n")
            return false
        }
    }

    private func finishBrowserTreeHelper(
        generation: UUID,
        folderID: String,
        folderName: String,
        folderPath: String,
        append: Bool,
        isShared: Bool,
        sizeRevision: UInt64,
        exitCode: Int32,
        structuredOutput: String,
        errorOutput: String
    ) {
        // Cancellation/link switching can reuse the same folder ID before an
        // old termination callback reaches the main queue. Never apply that
        // old page, or remove the replacement helper's loading state.
        guard browserTreeLoadGenerations[folderID] == generation else { return }
        defer { if browserTreeLoadProcesses.isEmpty { browserMoveCorrections = [:] } }
        browserTreeLoadGenerations.removeValue(forKey: folderID)
        browserTreeLoadExpansionOwners.removeValue(forKey: folderID)
        browserTreeLoadProcesses.removeValue(forKey: folderID)
        if let inputURL = browserTreeLoadInputURLs.removeValue(forKey: folderID) {
            try? FileManager.default.removeItem(at: inputURL)
        }
        browserTreeLoadingFolderIDs.remove(folderID)

        // A folder collapsed while its listing was in flight discards the result
        // rather than reopening itself.
        guard expandedBrowserFolderIDs.contains(folderID) else {
            browserFolderExpansion?.finish(folderID, failed: true)
            scheduleBrowserFolderExpansion()
            startNextPendingBrowserTreeLoadIfNeeded()
            return
        }

        if exitCode == 0, !structuredOutput.isEmpty {
            if isShared {
                finishShareBrowserTreeBrowse(
                    output: structuredOutput,
                    folderID: folderID,
                    folderName: folderName,
                    folderPath: folderPath,
                    append: append
                )
            } else {
                finishBrowserTreeBrowse(
                    output: structuredOutput,
                    folderID: folderID,
                    folderName: folderName,
                    folderPath: folderPath,
                    append: append,
                    sizeRevision: sizeRevision
                )
            }
        } else {
            browserTreeLoadErrors[folderID] = "PikPak could not list \(folderName)."
            if !errorOutput.isEmpty {
                appendOutput(redactedEngineOutput(errorOutput))
            }
        }
        resumeBrowserFolderExpansion(after: folderID)
        startNextPendingBrowserTreeLoadIfNeeded()
    }


    /// Expanding the outline is a lightweight browse action. If another
    /// preview or branch request is still finishing, keep the disclosure open
    /// and queue this request instead of silently discarding the click.
    @discardableResult
    private func requestBrowserTreeLoad(_ item: BrowserItem, append: Bool, expansionID: UUID? = nil) -> Bool {
        guard item.isFolder, hasActiveBrowserAccess else { return false }
        browserTreeLoadErrors.removeValue(forKey: item.id)

        // A later manual disclosure/load-more owns its request independently
        // of Cancel Expansion, even if expansion originally queued that page.
        if expansionID == nil {
            browserTreeLoadExpansionOwners.removeValue(forKey: item.id)
            for index in pendingBrowserTreeLoads.indices where pendingBrowserTreeLoads[index].item.id == item.id {
                pendingBrowserTreeLoads[index].expansionID = nil
            }
        }
        guard !isActivelyLoadingBrowserTreeFolder(item.id) else { return true }
        if pendingBrowserTreeLoads.contains(where: { $0.item.id == item.id }) { return true }

        if browserTreeLoadProcesses.count < Self.browserTreeLoadConcurrencyLimit {
            return loadBrowserTreeFolder(item, append: append, expansionID: expansionID)
        }

        if !pendingBrowserTreeLoads.contains(where: {
            $0.item.id == item.id && $0.append == append
        }) {
            pendingBrowserTreeLoads.append(BrowserTreeLoadRequest(item: item, append: append, expansionID: expansionID))
        }
        browserTreeLoadingFolderIDs.insert(item.id)
        setStatus("Queued \(item.name); it will expand as an open folder finishes")
        return true
    }

    @discardableResult
    private func startNextPendingBrowserTreeLoadIfNeeded() -> Bool {
        guard !isLoginPresented, hasActiveBrowserAccess else { return false }

        while !pendingBrowserTreeLoads.isEmpty,
              browserTreeLoadProcesses.count < Self.browserTreeLoadConcurrencyLimit {
            let request = pendingBrowserTreeLoads.removeFirst()
            let folderID = request.item.id
            guard expandedBrowserFolderIDs.contains(folderID) else {
                browserTreeLoadingFolderIDs.remove(folderID)
                browserFolderExpansion?.finish(folderID, failed: true)
                scheduleBrowserFolderExpansion()
                continue
            }
            if !request.append, browserTreeChildren[folderID] != nil {
                browserTreeLoadingFolderIDs.remove(folderID)
                resumeBrowserFolderExpansion(after: folderID)
                continue
            }
            if request.append, !browserFolderHasMoreItems(folderID) {
                browserTreeLoadingFolderIDs.remove(folderID)
                resumeBrowserFolderExpansion(after: folderID)
                continue
            }

            if !loadBrowserTreeFolder(request.item, append: request.append, expansionID: request.expansionID) {
                browserTreeLoadingFolderIDs.remove(folderID)
                browserTreeLoadErrors[folderID] = browserTreeLoadErrors[folderID] ?? "This folder could not be opened."
                resumeBrowserFolderExpansion(after: folderID)
            }
        }
        return !browserTreeLoadProcesses.isEmpty
    }

    /// Quota is deliberately serialized behind the normal engine process and
    /// the duplicate scanner. It uses the same desktop token/device chain and
    /// therefore cannot race another process while a refresh token rotates.
    @discardableResult
    private func startPendingQuotaRefreshIfNeeded() -> Bool {
        guard quotaRefreshPending,
              !isRunning,
              !isScanningDuplicates,
              !isLoginPresented,
              hasUsableSession
        else { return false }

        quotaRefreshPending = false
        storageQuotaError = nil
        runEngine(
            arguments: ["quota", "--json", "--with-profile"],
            operation: .quota(announcesResult: false)
        )
        return isRunning
    }

    private func isActivelyLoadingBrowserTreeFolder(_ folderID: String) -> Bool {
        if browserTreeLoadGenerations[folderID] != nil { return true }
        if browserTreeLoadProcesses[folderID]?.isRunning == true { return true }
        switch operation {
        case .some(.browseTree(let activeID, _, _, _)):
            return activeID == folderID
        case .some(.shareBrowseTree(_, let activeID, _, _, _)):
            return activeID == folderID
        default:
            return false
        }
    }

    private func appendVisibleBrowserTreeEntries(
        _ items: [BrowserItem],
        depth: Int,
        visitedFolderIDs: inout Set<String>,
        entries: inout [BrowserTreeEntry]
    ) {
        appendVisibleBrowserTreeEntries(
            items,
            depth: depth,
            expandedFolderIDs: expandedBrowserFolderIDs,
            childrenByFolderID: browserTreeChildren,
            visitedFolderIDs: &visitedFolderIDs,
            entries: &entries
        )
    }

    private func visibleBrowserTreeEntries(
        from workspace: BrowserWorkspaceSnapshot, in linkID: UUID
    ) -> [BrowserTreeEntry] {
        if workspace.presentation.entriesSortRevision == browserSortRevision,
           let entries = workspace.presentation.entries { return entries }
        let needsSort = workspace.presentation.sortRevision != browserSortRevision
        var entries: [BrowserTreeEntry] = []
        var visitedFolderIDs = Set<String>()
        appendVisibleBrowserTreeEntries(
            needsSort ? sortedBrowserItems(workspace.items, in: linkID) : workspace.items,
            depth: 0,
            expandedFolderIDs: workspace.expandedFolderIDs,
            childrenByFolderID: needsSort ? workspace.childrenByFolderID.mapValues { sortedBrowserItems($0, in: linkID) } : workspace.childrenByFolderID,
            visitedFolderIDs: &visitedFolderIDs,
            entries: &entries
        )
        workspace.presentation.entries = entries
        workspace.presentation.entriesSortRevision = browserSortRevision
        return entries
    }

    private func appendVisibleBrowserTreeEntries(
        _ items: [BrowserItem],
        depth: Int,
        expandedFolderIDs: Set<String>,
        childrenByFolderID: [String: [BrowserItem]],
        visitedFolderIDs: inout Set<String>,
        entries: inout [BrowserTreeEntry]
    ) {
        for item in items {
            entries.append(BrowserTreeEntry(item: item, depth: depth))
            guard item.isFolder,
                  expandedFolderIDs.contains(item.id),
                  visitedFolderIDs.insert(item.id).inserted,
                  let children = childrenByFolderID[item.id]
            else { continue }
            appendVisibleBrowserTreeEntries(
                children,
                depth: depth + 1,
                expandedFolderIDs: expandedFolderIDs,
                childrenByFolderID: childrenByFolderID,
                visitedFolderIDs: &visitedFolderIDs,
                entries: &entries
            )
        }
    }

    /// Sort sibling rows without flattening the outline. Folders remain above
    /// files in either direction, matching the app's Finder-style navigation;
    /// every expanded folder applies the same ordering to its own children.
    private func sortedBrowserItems(_ items: [BrowserItem], in linkID: UUID? = nil) -> [BrowserItem] {
        var modifiedDates: [String: Date] = [:]
        if browserSortColumn == .modified {
            modifiedDates.reserveCapacity(items.count)
            for item in items {
                if let date = Self.browserSortDate(from: item.modifiedTime) {
                    modifiedDates[item.id] = date
                }
            }
        }

        return items.sorted { left, right in
            if left.isFolder != right.isFolder {
                return left.isFolder
            }

            // Unknown timestamps stay at the bottom in both directions rather
            // than jumping above real dates when descending is selected.
            if browserSortColumn == .modified {
                let leftHasDate = modifiedDates[left.id] != nil
                let rightHasDate = modifiedDates[right.id] != nil
                if leftHasDate != rightHasDate {
                    return leftHasDate
                }
            }

            let primaryOrder = compareBrowserItems(
                left,
                right,
                by: browserSortColumn,
                modifiedDates: modifiedDates,
                linkID: linkID
            )
            if primaryOrder != .orderedSame {
                switch browserSortDirection {
                case .ascending:
                    return primaryOrder == .orderedAscending
                case .descending:
                    return primaryOrder == .orderedDescending
                }
            }

            let nameOrder = left.name.localizedStandardCompare(right.name)
            if nameOrder != .orderedSame {
                return nameOrder == .orderedAscending
            }
            return left.id < right.id
        }
    }

    private func compareBrowserItems(
        _ left: BrowserItem,
        _ right: BrowserItem,
        by column: BrowserSortColumn,
        modifiedDates: [String: Date],
        linkID: UUID? = nil
    ) -> ComparisonResult {
        switch column {
        case .name:
            return left.name.localizedStandardCompare(right.name)
        case .size:
            let leftSize = left.isFolder
                ? cachedFolderMeasurement(for: left.id, in: linkID)?.totalBytes ?? 0
                : left.size
            let rightSize = right.isFolder
                ? cachedFolderMeasurement(for: right.id, in: linkID)?.totalBytes ?? 0
                : right.size
            if leftSize < rightSize { return .orderedAscending }
            if leftSize > rightSize { return .orderedDescending }
            return .orderedSame
        case .kind:
            return left.kindDisplayTitle.localizedStandardCompare(right.kindDisplayTitle)
        case .modified:
            let leftDate = modifiedDates[left.id]
            let rightDate = modifiedDates[right.id]
            switch (leftDate, rightDate) {
            case let (.some(leftDate), .some(rightDate)):
                return leftDate.compare(rightDate)
            case (.some, .none):
                return .orderedAscending
            case (.none, .some):
                return .orderedDescending
            case (.none, .none):
                return .orderedSame
            }
        }
    }

    /// Keep the cached sibling arrays sorted so frequent preview/playback
    /// updates only flatten the outline; they do not repeatedly re-sort a
    /// folder containing thousands of files.
    private func applyBrowserSortToCachedItems() {
        browserItems = sortedBrowserItems(browserItems)
        browserTreeChildren = browserTreeChildren.mapValues { sortedBrowserItems($0) }
        activeBrowserSortRevision = browserSortRevision
    }

    private static let browserSortFractionalISOFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let browserSortBasicISOFormatter = ISO8601DateFormatter()

    private static func browserSortDate(from value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return browserSortFractionalISOFormatter.date(from: value)
            ?? browserSortBasicISOFormatter.date(from: value)
    }

    /// Rebuilt on demand and dropped by `didSet` on either backing collection.
    /// Scanning `browserItems` and every loaded child array per lookup made
    /// selection-derived values cost O(items) each, which the outline pays once
    /// per row it builds while scrolling a large folder.
    private var browserItemIndexCache: [String: BrowserItem]?

    private var browserItemIndex: [String: BrowserItem] {
        if let browserItemIndexCache {
            return browserItemIndexCache
        }
        var index: [String: BrowserItem] = [:]
        index.reserveCapacity(browserItems.count)
        // Children are inserted first so a top-level entry still wins on a
        // duplicate id, matching the old scan order.
        for children in browserTreeChildren.values {
            for item in children {
                index[item.id] = item
            }
        }
        for item in browserItems {
            index[item.id] = item
        }
        browserItemIndexCache = index
        return index
    }

    private func browserItem(withID itemID: String) -> BrowserItem? {
        browserItemIndex[itemID]
    }

    private func updateBrowserSelection(
        to item: BrowserItem,
        replacingSelection: Bool = true
    ) {
        let keepsCurrentPreview = previewFileID == item.id
        if isBrowsingSharedLink {
            selectedSharedLinkRootID = nil
        }
        if replacingSelection {
            if isBrowsingSharedLink, let linkID = activeSharedLinkID {
                clearInactiveSharedBrowserSelections()
                sharedBrowserSelectionAnchor = .init(linkID: linkID, itemID: item.id)
            }
            selectedBrowserItemIDs = [item.id]
            browserSelectionAnchorID = item.id
        }
        selectedBrowserItemID = item.id
        if !keepsCurrentPreview {
            clearPreview(preservingQuickLook: quickLookTargetIsCurrent)
        }
        if isQuickLookSessionActive {
            cancelAutomaticPreviewNavigation()
            followQuickLookSelection()
        } else if item.isFolder {
            cancelAutomaticPreviewNavigation()
            setStatus("Folder selected; use Right Arrow to expand or Return to open")
        } else if !keepsCurrentPreview {
            scheduleAutomaticPreview(for: item)
        }
    }

    private func extendBrowserSelection(
        to item: BrowserItem,
        visibleItems suppliedVisibleItems: [BrowserItem]? = nil
    ) {
        let visibleItems = suppliedVisibleItems ?? browserTreeEntries.map(\.item)
        guard let targetIndex = visibleItems.firstIndex(where: { $0.id == item.id }) else {
            updateBrowserSelection(to: item)
            return
        }

        let anchorID = browserSelectionAnchorID ?? selectedBrowserItemID ?? item.id
        guard let anchorIndex = visibleItems.firstIndex(where: { $0.id == anchorID }) else {
            updateBrowserSelection(to: item)
            return
        }

        let bounds = min(anchorIndex, targetIndex)...max(anchorIndex, targetIndex)
        selectedBrowserItemIDs = Set(bounds.map { visibleItems[$0].id })
        normalizeBrowserSelectionRoots()
        updateBrowserSelection(to: item, replacingSelection: false)
        setBrowserSelectionStatus()
    }

    private func toggleBrowserSelection(of item: BrowserItem) {
        toggleBrowserCheckbox(item)
    }

    private func selectionRootID(containing itemID: String) -> String? {
        var candidate: String? = itemID
        var visited = Set<String>()
        while let current = candidate, visited.insert(current).inserted {
            if selectedBrowserItemIDs.contains(current) {
                return current
            }
            candidate = browserItemParentIDs[current]
        }
        return nil
    }

    private func isBrowserItem(_ itemID: String, descendantOf folderID: String) -> Bool {
        var parentID = browserItemParentIDs[itemID]
        var visited = Set<String>()
        while let current = parentID, visited.insert(current).inserted {
            if current == folderID {
                return true
            }
            parentID = browserItemParentIDs[current]
        }
        return false
    }

    private func removeExplicitDescendants(of item: BrowserItem) {
        guard item.isFolder else { return }
        selectedBrowserItemIDs = Set(selectedBrowserItemIDs.filter {
            $0 == item.id || !isBrowserItem($0, descendantOf: item.id)
        })
    }

    private func normalizeBrowserSelectionRoots() {
        selectedBrowserItemIDs = Set(selectedBrowserItemIDs.filter { itemID in
            var parentID = browserItemParentIDs[itemID]
            var visited = Set<String>()
            while let current = parentID, visited.insert(current).inserted {
                if selectedBrowserItemIDs.contains(current),
                   browserItem(withID: current)?.isFolder == true {
                    return false
                }
                parentID = browserItemParentIDs[current]
            }
            return true
        })
    }

    private func selectFirstExplicitBrowserItem() {
        let visibleItems = browserTreeEntries.map(\.item)
        let replacement = visibleItems.first {
            selectedBrowserItemIDs.contains($0.id)
        } ?? selectedBrowserItems.first
        if let replacement {
            browserSelectionAnchorID = replacement.id
            updateBrowserSelection(to: replacement, replacingSelection: false)
        } else {
            clearBrowserSelection()
        }
    }

    private func setBrowserSelectionStatus() {
        let roots = isBrowsingSharedLink
            ? sharedBrowserSelectionGroups.flatMap(\.items)
            : browserItemsSelectedForAction
        guard !roots.isEmpty else {
            setStatus("No items selected")
            return
        }
        if roots.count == 1, roots[0].isFolder {
            setStatus("Selected \(roots[0].name) and everything inside it")
            return
        }
        let suffix = roots.contains(where: \.isFolder)
            ? "; selected folders include all contents"
            : ""
        setStatus("\(roots.count.formatted()) items selected\(suffix)")
    }

    /// Clear the current account/shared-link selection from an unused browser
    /// canvas click. Keeping this in the model makes List and Thumbnails follow
    /// the same rules and lets the active shared-link workspace persist the
    /// cleared state instead of restoring a stale selection later.
    func clearBrowserSelectionFromCanvas() {
        let clearsSharedLinkRoot = isBrowsingSharedLink
            && selectedSharedLinkRootID != nil
        guard selectedBrowserItemID != nil
                || !selectedBrowserItemIDs.isEmpty
                || clearsSharedLinkRoot
                || (isBrowsingSharedLink && browserActionSelectionCount > 0)
        else {
            return
        }
        clearInactiveSharedBrowserSelections()
        sharedBrowserSelectionAnchor = nil
        clearBrowserSelection()
        if isBrowsingSharedLink {
            selectedSharedLinkRootID = nil
        }
        setStatus("No items selected")
        saveActiveBrowserWorkspace()
    }

    private func clearBrowserSelection() {
        _ = cancelQuickLook()
        selectedBrowserItemID = nil
        selectedBrowserItemIDs = []
        browserSelectionAnchorID = nil
        cancelAutomaticPreviewNavigation()
        clearPreview()
        clearFolderMeasurement()
    }

    private func browserPath(for item: BrowserItem) -> String {
        browserItemPaths[item.id]
            ?? joinedRemotePath(folder: currentBrowserPath, name: item.name)
    }

    private func resetBrowserTreeState() {
        cancelBrowserTreeLoads()
        expandedBrowserFolderIDs = []
        browserTreeChildren = [:]
        browserTreeLoadingFolderIDs = []
        browserTreeLoadErrors = [:]
        browserTreeNextPageTokens = [:]
        browserItemPaths = [:]
        browserItemParentIDs = [:]
        pendingBrowserTreeLoads = []
    }

    private func registerBrowserItems(
        _ items: [BrowserItem],
        parentID: String,
        parentPath: String
    ) {
        if !isBrowsingSharedLink {
            for (parent, child) in zip(browserStack, browserStack.dropFirst()) {
                folderSizeIndex.parents[child.id] = parent.id
            }
        }
        for item in items {
            browserItemParentIDs[item.id] = parentID
            browserItemPaths[item.id] = joinedRemotePath(folder: parentPath, name: item.name)
            if !isBrowsingSharedLink, folderSizeIndex.parents[item.id] == nil {
                folderSizeIndex.parents[item.id] = parentID
            }
        }
    }

    private func removeCachedBrowserItems(withIDs itemIDs: Set<String>) {
        removeAccountFolderSizes(itemIDs)
        var removedIDs = itemIDs
        var foldersToVisit = Array(itemIDs)
        while let folderID = foldersToVisit.popLast() {
            for child in browserTreeChildren[folderID] ?? [] {
                if removedIDs.insert(child.id).inserted, child.isFolder {
                    foldersToVisit.append(child.id)
                }
            }
        }

        browserItems.removeAll { removedIDs.contains($0.id) }
        for folderID in Array(browserTreeChildren.keys) {
            if removedIDs.contains(folderID) {
                browserTreeChildren.removeValue(forKey: folderID)
            } else {
                browserTreeChildren[folderID]?.removeAll { removedIDs.contains($0.id) }
            }
        }
        expandedBrowserFolderIDs.subtract(removedIDs)
        browserTreeLoadingFolderIDs.subtract(removedIDs)
        pendingBrowserTreeLoads.removeAll { removedIDs.contains($0.item.id) }
        for itemID in removedIDs {
            browserTreeNextPageTokens.removeValue(forKey: itemID)
            browserTreeLoadErrors.removeValue(forKey: itemID)
            browserItemPaths.removeValue(forKey: itemID)
            browserItemParentIDs.removeValue(forKey: itemID)
        }

        // Cached Back snapshots predate the mutation and must not resurrect a
        // file that PikPak has already moved to Trash.
        browserFolderSnapshots = [:]
    }

    /// A background account-maintenance scan may finish while the user is in
    /// Links. Update the saved account workspace without touching the visible
    /// shared-link tree or its selection.
    private func removeCachedAccountBrowserItems(withIDs itemIDs: Set<String>, invalidatingFolders: Set<String> = []) {
        guard isBrowsingSharedLink else {
            removeCachedBrowserItems(withIDs: itemIDs)
            for id in invalidatingFolders {
                expandedBrowserFolderIDs.remove(id)
                browserTreeChildren.removeValue(forKey: id)
                browserTreeNextPageTokens.removeValue(forKey: id)
                browserTreeLoadErrors.removeValue(forKey: id)
            }
            return
        }
        removeAccountFolderSizes(itemIDs)
        guard let snapshot = accountBrowserWorkspace else {
            return
        }

        var removedIDs = itemIDs
        var foldersToVisit = Array(itemIDs)
        while let folderID = foldersToVisit.popLast() {
            for child in snapshot.childrenByFolderID[folderID] ?? [] {
                if removedIDs.insert(child.id).inserted, child.isFolder {
                    foldersToVisit.append(child.id)
                }
            }
        }

        var children = snapshot.childrenByFolderID
        for folderID in Array(children.keys) {
            if removedIDs.contains(folderID) {
                children.removeValue(forKey: folderID)
            } else {
                children[folderID]?.removeAll { removedIDs.contains($0.id) }
            }
        }
        var childPageTokens = snapshot.childPageTokens
        var itemPaths = snapshot.itemPaths
        var parentIDs = snapshot.parentIDs
        var loadErrors = snapshot.loadErrors
        for itemID in removedIDs {
            childPageTokens.removeValue(forKey: itemID)
            itemPaths.removeValue(forKey: itemID)
            parentIDs.removeValue(forKey: itemID)
            loadErrors.removeValue(forKey: itemID)
        }

        for id in invalidatingFolders {
            children.removeValue(forKey: id)
            childPageTokens.removeValue(forKey: id)
            loadErrors.removeValue(forKey: id)
        }
        accountBrowserWorkspace = BrowserWorkspaceSnapshot(
            items: snapshot.items.filter { !removedIDs.contains($0.id) },
            stack: snapshot.stack,
            nextPageToken: snapshot.nextPageToken,
            expandedFolderIDs: snapshot.expandedFolderIDs.subtracting(removedIDs.union(invalidatingFolders)),
            childrenByFolderID: children,
            loadErrors: loadErrors,
            selectedItemID: snapshot.selectedItemID.flatMap {
                removedIDs.contains($0) ? nil : $0
            },
            selectedItemIDs: snapshot.selectedItemIDs.subtracting(removedIDs),
            selectionAnchorID: snapshot.selectionAnchorID.flatMap {
                removedIDs.contains($0) ? nil : $0
            },
            // Back snapshots predate the cloud mutation and could resurrect a
            // row that has already moved to Trash.
            folderSnapshots: [:],
            childPageTokens: childPageTokens,
            itemPaths: itemPaths,
            parentIDs: parentIDs
        )
    }

    private func validateConfiguration() -> Bool {
        do {
            refreshToken = try CredentialParser.refreshToken(from: refreshToken)
        } catch {
            setError(error.localizedDescription)
            return false
        }
        return true
    }

    /// Duplicate discovery can take minutes on a large account, so it owns a
    /// separate process from short Browser and preview requests. The scanner
    /// remains read-only; downloads, measurements, and Trash operations stay
    /// unavailable until it finishes to avoid competing heavy work.
    private func runDuplicateScan(scope: BrowserLocation) {
        guard hasUsableSession else {
            presentLogin(reason: "Complete the desktop-session sign-in before accessing PikPak.")
            return
        }
        guard duplicateProcess?.isRunning != true else { return }
        taskActivity.begin(.duplicates, scope: scope.path, message: "Checking \(scope.name) for duplicate files…")
        guard let engineURL = Bundle.main.url(forResource: "pikpak", withExtension: nil) else {
            let message = "The bundled download engine is missing. Rebuild the app."
            taskActivity.finish(.duplicates, state: .failed, message: message)
            setError(message)
            return
        }

        do {
            let exchangeDirectory = try makePrivateExchangeDirectory()

            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            let stdoutBuffer = ProcessOutputBuffer()
            let stderrBuffer = ProcessOutputBuffer()
            let stderrLineBuffer = ProcessLineBuffer()

            process.executableURL = engineURL
            process.arguments = [
                "duplicates",
                "--parent-id", scope.id,
                "--root-path", scope.path,
                "--progress-json",
            ]
            process.standardOutput = stdout
            process.standardError = stderr
            process.currentDirectoryURL = exchangeDirectory
            process.qualityOfService = .utility

            var environment = try engineEnvironment()
            let proxy = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if proxy.isEmpty {
                environment.removeValue(forKey: "PIKPAK_PROXY")
            } else {
                environment["PIKPAK_PROXY"] = proxy
            }
            process.environment = environment

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                stdoutBuffer.append(data)
            }
            stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let lines = stderrLineBuffer.append(data)
                guard !lines.isEmpty else { return }
                for line in lines where !line.hasPrefix(duplicateProgressPrefix) {
                    stderrBuffer.append(Data((line + "\n").utf8))
                }
                DispatchQueue.main.async {
                    self?.enqueueDuplicateProgressLines(lines)
                }
            }

            process.terminationHandler = { [weak self] finishedProcess in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                stdoutBuffer.append(stdout.fileHandleForReading.readDataToEndOfFile())
                let trailingError = stderr.fileHandleForReading.readDataToEndOfFile()
                let trailingLines = stderrLineBuffer.append(trailingError)
                    + stderrLineBuffer.drain()
                for line in trailingLines where !line.hasPrefix(duplicateProgressPrefix) {
                    stderrBuffer.append(Data((line + "\n").utf8))
                }
                let structuredOutput = stdoutBuffer.string()
                let errorOutput = stderrBuffer.string()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.enqueueDuplicateProgressLines(trailingLines)
                    self.flushAllDuplicateProgressLines()
                    self.finishDuplicateProcess(
                        exitCode: finishedProcess.terminationStatus,
                        structuredOutput: structuredOutput,
                        errorOutput: errorOutput,
                        scope: scope
                    )
                }
            }

            duplicateScanWasCancelled = false
            duplicateProgressFlushScheduled = false
            pendingDuplicateProgressLines.removeAll(keepingCapacity: true)
            duplicateProcess = process
            isScanningDuplicates = true
            statusIsError = false
            statusErrorDiagnostic = nil
            status = "Checking \(scope.name) for duplicate files…"
            try process.run()
        } catch {
            duplicateProcess = nil
            duplicateScanWasCancelled = false
            duplicateProgressFlushScheduled = false
            pendingDuplicateProgressLines.removeAll(keepingCapacity: true)
            isScanningDuplicates = false
            let message = "Could not start duplicate scan: \(error.localizedDescription)"
            taskActivity.finish(.duplicates, state: .failed, message: message)
            setError(message)
            requireFreshAppLoginIfSessionTrustFailed(error)
        }
    }

    /// Empty-folder and .DS_Store scans can take minutes on a large account.
    /// Keep them off the foreground engine slot so account folders, saved
    /// shared links, and media previews remain available throughout the scan.
    private func runMaintenanceScan(arguments: [String], operation: Operation) {
        guard hasUsableSession else {
            presentLogin(reason: "Complete the desktop-session sign-in before scanning PikPak.")
            return
        }
        guard maintenanceProcess?.isRunning != true else { return }
        guard let kind = taskKind(for: operation) else { return }
        let scope: BrowserLocation
        switch operation {
        case .emptyFolders(let location), .dsStoreFiles(let location): scope = location
        default: return
        }
        taskActivity.begin(kind, scope: scope.path, message: "Preparing \(kind.title.lowercased())…")
        if !isRunning { setStatus("Preparing \(kind.title.lowercased())…") }
        guard let engineURL = Bundle.main.url(forResource: "pikpak", withExtension: nil) else {
            let message = "The bundled maintenance engine is missing. Rebuild the app."
            taskActivity.finish(kind, state: .failed, message: message)
            setError(message)
            return
        }

        let tracksEmptyFolderProgress: Bool
        switch operation {
        case .emptyFolders:
            tracksEmptyFolderProgress = true
        case .dsStoreFiles:
            tracksEmptyFolderProgress = false
        default:
            assertionFailure("Unsupported background maintenance operation")
            return
        }

        do {
            let exchangeDirectory = try makePrivateExchangeDirectory()
            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            let stdoutBuffer = ProcessOutputBuffer()
            let stderrBuffer = ProcessOutputBuffer()
            let stderrLineBuffer = ProcessLineBuffer()

            process.executableURL = engineURL
            process.arguments = arguments
            process.standardOutput = stdout
            process.standardError = stderr
            process.currentDirectoryURL = exchangeDirectory
            process.qualityOfService = .utility

            var environment = try engineEnvironment()
            let proxy = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if proxy.isEmpty {
                environment.removeValue(forKey: "PIKPAK_PROXY")
            } else {
                environment["PIKPAK_PROXY"] = proxy
            }
            process.environment = environment

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                stdoutBuffer.append(data)
            }
            stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                if tracksEmptyFolderProgress {
                    let lines = stderrLineBuffer.append(data)
                    guard !lines.isEmpty else { return }
                    for line in lines where !line.hasPrefix(emptyFolderProgressPrefix) {
                        stderrBuffer.append(Data((line + "\n").utf8))
                    }
                    DispatchQueue.main.async {
                        self?.enqueueMaintenanceProgressLines(lines)
                    }
                } else {
                    stderrBuffer.append(data)
                }
            }

            process.terminationHandler = { [weak self] finishedProcess in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                stdoutBuffer.append(stdout.fileHandleForReading.readDataToEndOfFile())
                let trailingError = stderr.fileHandleForReading.readDataToEndOfFile()
                let trailingLines: [String]
                if tracksEmptyFolderProgress {
                    trailingLines = stderrLineBuffer.append(trailingError)
                        + stderrLineBuffer.drain()
                    for line in trailingLines where !line.hasPrefix(emptyFolderProgressPrefix) {
                        stderrBuffer.append(Data((line + "\n").utf8))
                    }
                } else {
                    trailingLines = []
                    stderrBuffer.append(trailingError)
                }
                let structuredOutput = stdoutBuffer.string()
                let errorOutput = stderrBuffer.string()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.enqueueMaintenanceProgressLines(trailingLines)
                    self.flushAllMaintenanceProgressLines()
                    self.finishMaintenanceProcess(
                        exitCode: finishedProcess.terminationStatus,
                        structuredOutput: structuredOutput,
                        errorOutput: errorOutput,
                        operation: operation
                    )
                }
            }

            maintenanceWasCancelled = false
            maintenanceOperation = operation
            maintenanceProgressFlushScheduled = false
            pendingMaintenanceProgressLines.removeAll(keepingCapacity: true)
            maintenanceProcess = process
            switch operation {
            case .emptyFolders(let scope):
                isRemovingEmptyFolders = true
                isRemovingDSStoreFiles = false
                setMaintenanceStatus("Scanning \(scope.name) for empty folders…")
            case .dsStoreFiles(let scope):
                isRemovingEmptyFolders = false
                isRemovingDSStoreFiles = true
                setMaintenanceStatus("Scanning \(scope.name) for .DS_Store files…")
            default:
                break
            }
            try process.run()
        } catch {
            maintenanceProcess = nil
            maintenanceOperation = nil
            maintenanceWasCancelled = false
            maintenanceProgressFlushScheduled = false
            pendingMaintenanceProgressLines.removeAll(keepingCapacity: true)
            isRemovingEmptyFolders = false
            isRemovingDSStoreFiles = false
            let message = "Could not start maintenance scan: \(error.localizedDescription)"
            maintenanceStatus = message
            taskActivity.finish(kind, state: .failed, message: message, diagnostic: diagnostic(for: error, source: "macOS process launcher"))
            setError(message, diagnostic: diagnostic(for: error, source: "macOS process launcher"))
            requireFreshAppLoginIfSessionTrustFailed(error)
        }
    }

    private func resetFolderMergeProgress(sourceCount: Int, status: String) {
        mergeMovedItems = 0
        mergeTotalItems = 0
        mergeRemainingItems = 0
        mergeSourceIndex = 0
        mergeSourceCount = max(sourceCount, 0)
        mergeCompletedSourceCount = mergeCompletedSourceIDs.count
        mergeRetryAttempt = 0
        mergeRetryMaxAttempts = 0
        mergeRetryInMillis = 0
        mergeDidComplete = false
        mergeErrorDiagnostic = nil
        setMergeStatus(status)
    }

    /// PikPak acknowledges folder moves before every listing endpoint has
    /// necessarily converged. The dedicated helper polls that state without
    /// occupying the foreground Browser/Links process.
    private func runFolderMergeEngine(
        folders: [BrowserItem],
        destination: BrowserItem
    ) {
        guard hasUsableSession else {
            presentLogin(reason: "Complete the desktop-session sign-in before merging folders.")
            return
        }
        guard mergeProcess?.isRunning != true else { return }
        let sourceIDs = folders.filter { $0.id != destination.id }.map(\.id)
        guard !sourceIDs.isEmpty else { return }
        taskActivity.begin(.folderMerge, scope: destination.name, message: "Preparing folder merge…")
        if !isRunning { setStatus("Preparing folder merge…") }
        guard let engineURL = Bundle.main.url(forResource: "pikpak", withExtension: nil) else {
            let message = "The bundled folder-merge engine is missing. Rebuild the app."
            mergeStatus = message
            mergeErrorDiagnostic = AppErrorDiagnostic(
                source: "My PikPak for Mac",
                code: "MERGE_ENGINE_MISSING",
                message: message,
                context: nil
            )
            taskActivity.finish(.folderMerge, state: .failed, message: message, diagnostic: mergeErrorDiagnostic)
            setError(message, diagnostic: mergeErrorDiagnostic)
            return
        }

        do {
            let exchangeDirectory = try makePrivateExchangeDirectory()
            let sourceIDsURL = try writePrivateRequest(
                sourceIDs,
                named: "merge-source-ids",
                in: exchangeDirectory
            )
            mergeInputURL = sourceIDsURL

            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            let stdoutBuffer = ProcessOutputBuffer()
            let stderrBuffer = ProcessOutputBuffer()
            let stderrLineBuffer = ProcessLineBuffer()

            process.executableURL = engineURL
            process.arguments = [
                "merge-folders",
                "--destination-id", destination.id,
                "--source-ids-file", sourceIDsURL.path,
                "--yes",
                "--progress-json",
            ]
            process.standardOutput = stdout
            process.standardError = stderr
            process.currentDirectoryURL = exchangeDirectory
            process.qualityOfService = .utility

            var environment = try engineEnvironment()
            let proxy = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if proxy.isEmpty {
                environment.removeValue(forKey: "PIKPAK_PROXY")
            } else {
                environment["PIKPAK_PROXY"] = proxy
            }
            process.environment = environment

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                stdoutBuffer.append(data)
            }
            stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let lines = stderrLineBuffer.append(data)
                guard !lines.isEmpty else { return }
                for line in lines where !line.hasPrefix(mergeProgressPrefix) {
                    stderrBuffer.append(Data((line + "\n").utf8))
                }
                DispatchQueue.main.async {
                    for line in lines {
                        self?.handleMergeProgressLine(line)
                    }
                }
            }

            process.terminationHandler = { [weak self] finishedProcess in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                stdoutBuffer.append(stdout.fileHandleForReading.readDataToEndOfFile())
                let trailingError = stderr.fileHandleForReading.readDataToEndOfFile()
                let trailingLines = stderrLineBuffer.append(trailingError)
                    + stderrLineBuffer.drain()
                for line in trailingLines where !line.hasPrefix(mergeProgressPrefix) {
                    stderrBuffer.append(Data((line + "\n").utf8))
                }
                let structuredOutput = stdoutBuffer.string()
                let errorOutput = stderrBuffer.string()
                DispatchQueue.main.async {
                    guard let self else { return }
                    for line in trailingLines {
                        self.handleMergeProgressLine(line)
                    }
                    self.finishFolderMergeProcess(
                        exitCode: finishedProcess.terminationStatus,
                        structuredOutput: structuredOutput,
                        errorOutput: errorOutput,
                        folders: folders,
                        destination: destination
                    )
                }
            }

            mergeWasCancelled = false
            mergeProcess = process
            isMergingFolders = true
            setMergeStatus("Preparing to merge into \(destination.name)…")
            try process.run()
        } catch {
            cleanupMergeInputFile()
            mergeProcess = nil
            mergeWasCancelled = false
            isMergingFolders = false
            let launchDiagnostic = diagnostic(for: error, source: "macOS process launcher")
            let message = "Could not start the folder merge: \(error.localizedDescription)"
            mergeStatus = message
            mergeErrorDiagnostic = launchDiagnostic
            taskActivity.finish(.folderMerge, state: .failed, message: message, diagnostic: launchDiagnostic)
            setError(message, diagnostic: launchDiagnostic)
            requireFreshAppLoginIfSessionTrustFailed(error)
        }
    }

    private func handleMergeProgressLine(_ rawLine: String) {
        let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        guard line.hasPrefix(mergeProgressPrefix) else {
            if !line.isEmpty {
                appendOutput(redactedEngineOutput(line) + "\n")
            }
            return
        }

        let payload = String(line.dropFirst(mergeProgressPrefix.count))
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let event = try decoder.decode(MergeProgressEvent.self, from: Data(payload.utf8))
            applyMergeProgressEvent(event)
        } catch {
            appendOutput("Warning: ignored one malformed folder-merge progress update.\n")
        }
    }

    private func applyMergeProgressEvent(_ event: MergeProgressEvent) {
        if let sourceCount = event.sourceCount {
            mergeSourceCount = max(mergeSourceCount, sourceCount)
        }
        if let sourceIndex = event.sourceIndex {
            mergeSourceIndex = max(sourceIndex, 0)
        }
        if let movedItems = event.movedItems {
            mergeMovedItems = max(movedItems, 0)
        }
        if let totalItems = event.totalItems {
            mergeTotalItems = max(totalItems, 0)
        }
        if let remainingItems = event.remainingItems {
            mergeRemainingItems = max(remainingItems, 0)
        }
        if let completedSources = event.completedSources {
            mergeCompletedSourceCount = max(mergeCompletedSourceCount, completedSources)
        }
        mergeRetryAttempt = max(event.attempt ?? 0, 0)
        mergeRetryMaxAttempts = max(event.maxAttempts ?? 0, 0)
        mergeRetryInMillis = event.retryInMillis ?? 0

        let sourceName = event.sourceId.flatMap { id in
            mergeRequestedFolders.first(where: { $0.id == id })?.name
        } ?? "source folder"

        switch event.event {
        case "preparing":
            mergeRemainingItems = mergeTotalItems
            setMergeStatus("Reading the selected folders before moving anything…")
        case "source_started":
            setMergeStatus("Merging \(sourceName)…")
        case "move_submitted":
            setMergeStatus("Move accepted for \(sourceName); waiting for PikPak to settle…")
        case "verifying":
            setMergeStatus(
                "Verifying \(sourceName) • check \(mergeRetryAttempt.formatted()) of \(mergeRetryMaxAttempts.formatted())"
            )
        case "source_completed":
            if let sourceID = event.sourceId {
                mergeCompletedSourceIDs.insert(sourceID)
            }
            mergeCompletedSourceCount = max(
                mergeCompletedSourceIDs.count,
                event.completedSources ?? 0
            )
            setMergeStatus("Finished \(sourceName); continuing with the next source…")
        case "completed":
            mergeCompletedSourceCount = max(
                mergeSourceCount,
                event.completedSources ?? 0
            )
            mergeRemainingItems = 0
            setMergeStatus("Folder merge completed")
        default:
            break
        }
    }

    private func finishFolderMergeProcess(
        exitCode: Int32,
        structuredOutput: String,
        errorOutput: String,
        folders: [BrowserItem],
        destination: BrowserItem
    ) {
        defer { _ = startNextPendingBrowserMoveIfNeeded() }
        let wasCancelled = mergeWasCancelled
        synchronizeSharedSessionFromDisk()
        cleanupMergeInputFile()
        mergeProcess = nil
        mergeWasCancelled = false
        isMergingFolders = false
        mergeRetryAttempt = 0
        mergeRetryMaxAttempts = 0
        mergeRetryInMillis = 0

        // Includes cancelled / partially failed merges: moved children may
        // already be in the destination even when the final result failed.
        let changedFolders = Set(folders.map(\.id)).union([destination.id])
        recordFolderSizeChange(in: changedFolders)

        if wasCancelled {
            mergeStatus = "Merge cancelled safely. Moved items remain in the destination; nonempty sources were kept."
            if !isRunning {
                setStatus(mergeStatus)
            }
        } else if exitCode == 0 {
            finishMergeFolders(
                output: structuredOutput,
                requestedFolders: folders,
                destination: destination
            )
        } else {
            let failure = engineErrorPresentation(
                errorOutput,
                operation: .mergeFolders(folders: folders, destination: destination),
                exitCode: exitCode
            )
            mergeStatus = failure.summary
            mergeErrorDiagnostic = failure.diagnostic
            appendOutput(failure.summary + "\n" + failure.diagnostic.displayText + "\n")
            if !isRunning {
                setError(failure.summary, diagnostic: failure.diagnostic)
            }
            handleWebLoginNeeded(for: errorOutput)
        }

        taskActivity.finish(.folderMerge,
            state: wasCancelled ? .cancelled : (mergeDidComplete ? .completed : .failed),
            message: mergeStatus,
            detail: "\(mergeCompletedSourceCount.formatted()) of \(mergeSourceCount.formatted()) source folders merged · \(mergeMovedItems.formatted()) items moved",
            diagnostic: mergeErrorDiagnostic)
        quotaRefreshPending = true
        presentDeferredLoginIfNeeded()
        startPendingQuotaRefreshIfNeeded()
    }

    private func setMergeStatus(_ message: String) {
        mergeStatus = message
        taskActivity.update(.folderMerge, message: message,
            detail: "\(mergeCompletedSourceCount.formatted()) of \(mergeSourceCount.formatted()) source folders merged · \(mergeMovedItems.formatted()) items moved",
            fraction: mergeProgressFraction)
    }

    /// Keep the long-running server progress poll separate from the foreground
    /// Browser process. PikPak performs the actual decompression in the cloud;
    /// this child only starts the task and follows its progress.
    private func runArchiveTaskEngine<Request: Encodable>(
        taskID: UUID,
        command: String,
        request: Request
    ) {
        guard hasUsableSession else {
            presentLogin(reason: "Complete the desktop-session sign-in before extracting an archive.")
            return
        }
        guard !isClosingWindow, archiveProcesses[taskID] == nil,
              let task = archiveTasks.first(where: { $0.id == taskID }) else { return }
        let item = task.item
        let isInspection = command == "archive-inspect"
        let generation = UUID()
        guard let engineURL = archiveEngineURL else {
            let error = AppErrorDiagnostic(source: "App bundle", code: "ARCHIVE_ENGINE_MISSING",
                message: "The bundled cloud extraction engine is missing. Rebuild the app.", context: nil)
            updateArchiveTask(taskID) { $0.error = error; $0.password = "" }
            setError(error.message, diagnostic: error)
            return
        }

        do {
            let exchangeDirectory = try archiveExchangeDirectory()
            let requestURL = try writePrivateRequest(
                request,
                named: command,
                in: exchangeDirectory
            )
            archiveInputURLs[taskID] = requestURL

            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            let stdoutBuffer = ProcessOutputBuffer()
            let stderrBuffer = ProcessOutputBuffer()
            let stderrLineBuffer = ProcessLineBuffer()

            process.executableURL = engineURL
            process.arguments = [
                command,
                "--request-file", requestURL.path,
            ]
            if !isInspection { process.arguments?.append("--progress-json") }
            process.standardOutput = stdout
            process.standardError = stderr
            process.currentDirectoryURL = exchangeDirectory
            // Cloud extraction can remain open for a long time while PikPak
            // prepares an archive. Keep its polling/progress helper below the
            // foreground Browser and Links interaction priority as well.
            process.qualityOfService = .utility

            var environment = try archiveEngineEnvironment()
            let proxy = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if proxy.isEmpty {
                environment.removeValue(forKey: "PIKPAK_PROXY")
            } else {
                environment["PIKPAK_PROXY"] = proxy
            }
            process.environment = environment

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                stdoutBuffer.append(data)
            }
            stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let lines = stderrLineBuffer.append(data)
                guard !lines.isEmpty else { return }
                for line in lines where !line.hasPrefix(archiveProgressPrefix) {
                    stderrBuffer.append(Data((line + "\n").utf8))
                }
                DispatchQueue.main.async {
                    for line in lines {
                        self?.handleArchiveStderrLine(line, taskID: taskID, generation: generation)
                    }
                }
            }

            process.terminationHandler = { [weak self] finishedProcess in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                stdoutBuffer.append(stdout.fileHandleForReading.readDataToEndOfFile())
                let trailingError = stderr.fileHandleForReading.readDataToEndOfFile()
                let trailingLines = stderrLineBuffer.append(trailingError)
                    + stderrLineBuffer.drain()
                for line in trailingLines where !line.hasPrefix(archiveProgressPrefix) {
                    stderrBuffer.append(Data((line + "\n").utf8))
                }
                let output = stdoutBuffer.string()
                let errorOutput = stderrBuffer.string()
                DispatchQueue.main.async {
                    guard let self else { return }
                    for line in trailingLines {
                        self.handleArchiveStderrLine(line, taskID: taskID, generation: generation)
                    }
                    self.finishArchiveTaskProcess(
                        exitCode: finishedProcess.terminationStatus,
                        structuredOutput: output,
                        errorOutput: errorOutput,
                        taskID: taskID,
                        generation: generation,
                        isInspection: isInspection
                    )
                }
            }

            updateArchiveTask(taskID) {
                $0.result = nil; $0.error = nil; $0.progress = 0; $0.hasReportedProgress = false
                $0.phase = isInspection ? "Reading archive" : "Starting"
                $0.generation = generation
                $0.isInspecting = isInspection; $0.isExtracting = !isInspection
            }
            stoppedArchiveTaskIDs.remove(taskID)
            archiveProcesses[taskID] = process
            statusIsError = false
            statusErrorDiagnostic = nil
            if !isRunning {
                status = isInspection ? "Reading \(item.name) on PikPak…" : "Starting cloud extraction for \(item.name)…"
            }
            try process.run()
        } catch {
            cleanupArchiveInputFile(taskID)
            archiveProcesses.removeValue(forKey: taskID)
            stoppedArchiveTaskIDs.remove(taskID)
            let launchDiagnostic = diagnostic(
                for: error,
                source: "macOS process launcher",
                fallbackCode: "ARCHIVE_EXTRACTION_LAUNCH_FAILED"
            )
            updateArchiveTask(taskID) {
                $0.isInspecting = false; $0.isExtracting = false
                $0.error = launchDiagnostic; $0.phase = "Failed to start"; $0.password = ""
            }
            setError(
                "Could not start PikPak cloud extraction: \(error.localizedDescription)",
                diagnostic: launchDiagnostic
            )
            requireFreshAppLoginIfSessionTrustFailed(error)
        }
    }

    private var archiveEngineURL: URL? {
        #if ARCHIVE_TASK_TESTS
        if let archiveTestEngineURL { return archiveTestEngineURL }
        #endif
        return Bundle.main.url(forResource: "pikpak", withExtension: nil)
    }

    private func archiveExchangeDirectory() throws -> URL {
        #if ARCHIVE_TASK_TESTS
        if let archiveTestDirectory { return archiveTestDirectory }
        #endif
        return try makePrivateExchangeDirectory()
    }

    private func archiveEngineEnvironment() throws -> [String: String] {
        #if ARCHIVE_TASK_TESTS
        if archiveTestEngineURL != nil { return ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"] }
        #endif
        return try engineEnvironment()
    }

    private func handleArchiveStderrLine(_ line: String, taskID: UUID, generation: UUID) {
        guard !isClosingWindow,
              let task = archiveTasks.first(where: { $0.id == taskID }),
              task.generation == generation, task.isBusy,
              !stoppedArchiveTaskIDs.contains(taskID) else { return }
        guard line.hasPrefix(archiveProgressPrefix) else {
            if !line.isEmpty {
                appendOutput(redactedEngineOutput(line + "\n"))
            }
            return
        }
        let payload = String(line.dropFirst(archiveProgressPrefix.count))
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let event = try? decoder.decode(
            ArchiveProgressEvent.self,
            from: Data(payload.utf8)
        ) else { return }

        switch event.event {
        case "started":
            updateArchiveTask(taskID) {
                $0.phase = event.status?.isEmpty == false ? event.status! : "Queued on PikPak"
            }
        case "progress":
            updateArchiveTask(taskID) {
                if let progress = event.progress, progress.isFinite {
                    $0.progress = min(max(progress, 0), 100)
                    $0.hasReportedProgress = true
                }
                $0.phase = readableArchivePhase(event.phase)
            }
        case "completed":
            updateArchiveTask(taskID) { $0.progress = 100; $0.hasReportedProgress = true; $0.phase = "Finishing" }
        default:
            break
        }
    }

    private func readableArchivePhase(_ phase: String?) -> String {
        let raw = (phase ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "Extracting in PikPak" }
        return raw
            .replacingOccurrences(of: "PHASE_TYPE_", with: "")
            .replacingOccurrences(of: "_", with: " ")
            .lowercased()
            .capitalized
    }

    private func finishArchiveTaskProcess(
        exitCode: Int32,
        structuredOutput: String,
        errorOutput: String,
        taskID: UUID,
        generation: UUID,
        isInspection: Bool
    ) {
        defer { _ = startNextPendingBrowserMoveIfNeeded() }
        guard let task = archiveTasks.first(where: { $0.id == taskID }),
              task.generation == generation else { return }
        let item = task.item
        let stoppedTracking = stoppedArchiveTaskIDs.remove(taskID) != nil
        #if ARCHIVE_TASK_TESTS
        if archiveTestDirectory == nil { synchronizeSharedSessionFromDisk() }
        #else
        synchronizeSharedSessionFromDisk()
        #endif
        cleanupArchiveInputFile(taskID)
        archiveProcesses.removeValue(forKey: taskID)
        updateArchiveTask(taskID) {
            $0.isInspecting = false; $0.isExtracting = false
            if !isInspection { $0.password = "" }
        }
        guard !isClosingWindow else { return }
        defer { pumpArchiveQueue() }

        if stoppedTracking {
            updateArchiveTask(taskID) {
                $0.phase = isInspection ? "Inspection cancelled" : "Progress tracking stopped"
                $0.password = ""
            }
            if !isRunning {
                setStatus(isInspection ? "Archive inspection cancelled" : "Stopped tracking cloud extraction. PikPak may continue it on the server.")
            }
            presentDeferredLoginIfNeeded()
            return
        }

        if exitCode == 0 {
            if isInspection {
                finishArchiveInspection(output: structuredOutput, item: item, taskID: taskID)
                presentDeferredLoginIfNeeded()
                return
            }
            do {
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                let result = try decoder.decode(
                    ArchiveExtractionResult.self,
                    from: Data(structuredOutput.utf8)
                )
                guard result.archiveFileId == item.id else { throw CocoaError(.fileReadCorruptFile) }
                updateArchiveTask(taskID) {
                    $0.result = result; $0.error = nil; $0.progress = 100; $0.phase = "Complete"
                    $0.password = ""
                }
                if let parent = accountSizeParent(of: item) {
                    recordFolderSizeChange(in: [parent])
                }
                if !isRunning {
                    setStatus("Extracted \(item.name) in PikPak")
                }
            } catch {
                let decodeDiagnostic = diagnostic(
                    for: error,
                    source: "PikPak extraction response",
                    fallbackCode: "ARCHIVE_RESPONSE_INVALID"
                )
                updateArchiveTask(taskID) { $0.error = decodeDiagnostic; $0.phase = "Result unavailable" }
                setError(
                    "PikPak completed the extraction, but its result could not be read.",
                    diagnostic: decodeDiagnostic
                )
            }
        } else {
            let failure = engineErrorPresentation(
                errorOutput,
                operation: isInspection
                    ? .archiveInspect(request: .init(fileId: item.id, gcid: "", password: ""), item: item)
                    : .archiveExtract(item: item),
                exitCode: exitCode
            )
            updateArchiveTask(taskID) { $0.error = failure.diagnostic; $0.phase = "Failed"; $0.password = "" }
            if !isRunning {
                setError(failure.summary, diagnostic: failure.diagnostic)
            } else {
                appendOutput(failure.summary + "\n" + failure.diagnostic.displayText + "\n")
            }
            handleWebLoginNeeded(for: errorOutput)
        }

        #if ARCHIVE_TASK_TESTS
        if archiveTestDirectory != nil { return }
        #endif
        if exitCode == 0,
           !refreshArchiveDestinationPreservingExpandedFolders(for: item, parentFolderID: task.parentFolderID) {
            quotaRefreshPending = true
            startPendingQuotaRefreshIfNeeded()
        }
        presentDeferredLoginIfNeeded()
    }

    /// Refresh only the folder that received the extracted output. A normal
    /// Browser refresh rebuilds the outline and closes every disclosure; this
    /// targeted variant deliberately retains all expanded ids and cached child
    /// branches. If the user has navigated elsewhere, their current Browser is
    /// left untouched and will naturally show the result on its next refresh.
    @discardableResult
    private func refreshArchiveDestinationPreservingExpandedFolders(
        for item: BrowserItem, parentFolderID: String?
    ) -> Bool {
        guard !isBrowsingSharedLink, !isRunning else { return false }
        let parentID = parentFolderID
            ?? browserItemParentIDs[item.id]
            ?? item.parentId

        guard let parentID else { return false }
        if browserStack.last?.id == parentID {
            loadFolder(
                stack: browserStack,
                append: false,
                includeQuota: true,
                preserveOutline: true
            )
            return isRunning
        }

        guard let parent = browserItem(withID: parentID) else { return false }
        loadBrowserTreeFolder(parent, append: false)
        if isRunning {
            quotaRefreshPending = true
        }
        return isRunning
    }

    /// Run downloads independently from the foreground browser engine. Live
    /// progress is coalesced before it reaches SwiftUI so even a many-thousand
    /// file transfer does not monopolize the main actor.
    private func runDownloadEngine(
        arguments: [String],
        operation: Operation,
        proxyOverride: String? = nil,
        accountRequest: AccountDownloadInput? = nil
    ) {
        guard hasUsableSession else {
            presentLogin(reason: "Complete the desktop-session sign-in before accessing PikPak.")
            return
        }
        guard downloadProcess?.isRunning != true, !isDownloading else { return }
        switch operation {
        case .download, .shareDownload:
            break
        default:
            assertionFailure("Unsupported background download operation")
            return
        }
        guard let engineURL = Bundle.main.url(forResource: "pikpak", withExtension: nil) else {
            setError("The bundled download engine is missing. Rebuild the app.")
            return
        }

        do {
            let exchangeDirectory = try makePrivateExchangeDirectory()
            var effectiveArguments = arguments
            if let accountRequest {
                let requestURL = try writePrivateRequest(accountRequest, named: "account-download", in: exchangeDirectory)
                downloadInputURL = requestURL
                effectiveArguments.append(contentsOf: ["--roots-file", requestURL.path])
            }
            if case .shareDownload(let request) = operation {
                let requestURL = try writePrivateRequest(
                    request,
                    named: "share-download",
                    in: exchangeDirectory
                )
                downloadInputURL = requestURL
                effectiveArguments.append(contentsOf: ["--request-file", requestURL.path])
            }

            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            let stdoutBuffer = ProcessOutputBuffer()
            let stderrBuffer = ProcessOutputBuffer()
            let stdoutLineBuffer = ProcessLineBuffer()

            process.executableURL = engineURL
            process.arguments = effectiveArguments
            process.standardOutput = stdout
            process.standardError = stderr
            process.currentDirectoryURL = exchangeDirectory
            process.qualityOfService = .utility

            var environment = try engineEnvironment()
            let proxy = (proxyOverride ?? proxyURL)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if proxy.isEmpty {
                environment.removeValue(forKey: "PIKPAK_PROXY")
            } else {
                environment["PIKPAK_PROXY"] = proxy
            }
            process.environment = environment

            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                stdoutBuffer.append(data)
                let lines = stdoutLineBuffer.append(data)
                guard !lines.isEmpty else { return }
                DispatchQueue.main.async {
                    self?.enqueueDownloadOutputLines(lines)
                }
            }
            stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                stderrBuffer.append(data)
                if let text = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async {
                        self?.appendOutput(self?.redactedEngineOutput(text) ?? text)
                    }
                }
            }

            process.terminationHandler = { [weak self] finishedProcess in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                let trailingOutput = stdout.fileHandleForReading.readDataToEndOfFile()
                let trailingError = stderr.fileHandleForReading.readDataToEndOfFile()
                stdoutBuffer.append(trailingOutput)
                stderrBuffer.append(trailingError)
                let trailingLines = stdoutLineBuffer.append(trailingOutput)
                    + stdoutLineBuffer.drain()
                let trailingErrorText = String(data: trailingError, encoding: .utf8) ?? ""
                let completeOutput = stdoutBuffer.string()
                let errorOutput = stderrBuffer.string()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.enqueueDownloadOutputLines(trailingLines)
                    self.flushAllDownloadOutputLines()
                    // Replaying the complete ordered transcript closes the
                    // small race between pipe callbacks and process exit.
                    self.replayDownloadProgress(from: completeOutput)
                    if !trailingErrorText.isEmpty {
                        self.appendOutput(self.redactedEngineOutput(trailingErrorText))
                    }
                    self.finishDownloadProcess(
                        exitCode: finishedProcess.terminationStatus,
                        errorOutput: errorOutput,
                        operation: operation
                    )
                }
            }

            downloadProcess = process
            downloadOperation = operation
            downloadRequestedStop = false
            isDownloading = true
            downloadRunState = .scanning
            statusIsError = false
            statusErrorDiagnostic = nil
            if !isUploading { log = "" }
            status = {
                if case .shareDownload = operation {
                    return "Scanning the shared selection…"
                }
                return "Scanning the remote selection…"
            }()
            ensureTransferMetricsTask()
            try process.run()
        } catch {
            cleanupDownloadInputFile()
            downloadProcess = nil
            downloadOperation = nil
            downloadRequestedStop = false
            activeDownloadRequestKey = nil
            isDownloading = false
            retainInterruptedDownload()
            finishDownloadProgress(as: .failed)
            stopTransferMetricsTaskIfIdle()
            setError("Could not start downloader: \(error.localizedDescription)")
            requireFreshAppLoginIfSessionTrustFailed(error)
            if deferredLoginReason == nil {
                _ = startNextPendingDownloadIfNeeded()
            }
        }
    }

    private func finishDownloadProcess(
        exitCode: Int32,
        errorOutput: String,
        operation finishedOperation: Operation
    ) {
        guard !isClosingWindow else { cleanupDownloadInputFile(); return }
        let wasStopped = downloadRequestedStop
        if wasStopped || exitCode != 0 {
            retainInterruptedDownload()
        } else {
            activePersistentDownload = nil
            _ = persistTransfersSynchronously()
        }
        synchronizeSharedSessionFromDisk()
        cleanupDownloadInputFile()
        downloadProcess = nil
        downloadOperation = nil
        downloadRequestedStop = false
        activeDownloadRequestKey = nil
        downloadOutputFlushScheduled = false
        pendingDownloadOutputLines.removeAll(keepingCapacity: true)
        isDownloading = false

        if wasStopped {
            finishDownloadProgress(as: .stopped)
            if !isRunning {
                let message = {
                    if case .shareDownload = finishedOperation {
                        return "Stopped. Shared-file .part files were kept for resume."
                    }
                    return "Stopped. Any .part files were kept and will resume next time."
                }()
                setStatus(message)
            }
        } else if exitCode == 0 {
            finishDownloadProgress(as: .completed)
            if !isRunning {
                setStatus(
                    {
                        if case .shareDownload = finishedOperation {
                            return "Shared-link download finished"
                        }
                        return "Download finished"
                    }()
                )
            }
        } else {
            finishDownloadProgress(as: .failed)
            let failure = engineErrorPresentation(
                errorOutput,
                operation: finishedOperation,
                exitCode: exitCode
            )
            if !isRunning {
                setError(failure.summary, diagnostic: failure.diagnostic)
            } else {
                appendOutput(failure.summary + "\n" + failure.diagnostic.displayText + "\n")
            }
            handleWebLoginNeeded(for: errorOutput)
        }

        stopTransferMetricsTaskIfIdle()
        presentDeferredLoginIfNeeded()
        if !wasStopped, deferredLoginReason == nil {
            _ = startNextPendingDownloadIfNeeded()
        }
        startPendingQuotaRefreshIfNeeded()
    }

    /// Folder-size recursion has its own read-only process. Results are merged
    /// into the persistent per-account cache even if the user has navigated to
    /// another folder by the time the scan completes.
    private func runFolderMeasurementEngine(arguments: [String], operation: Operation) {
        guard hasUsableSession else {
            presentLogin(reason: "Complete the desktop-session sign-in before calculating folder sizes.")
            return
        }
        let folderID: String
        let cacheKey: String
        switch operation {
        case .measure(let id):
            folderID = id
            cacheKey = folderMeasurementCacheKey(for: id, linkID: nil)
        case .shareMeasure(_, let id, let linkID):
            folderID = id
            cacheKey = folderMeasurementCacheKey(for: id, linkID: linkID)
        default:
            assertionFailure("Unsupported background folder measurement")
            return
        }
        guard measuringFolderCacheKey != cacheKey,
              !queuedFolderMeasurementCacheKeys.contains(cacheKey)
        else { return }

        if folderMeasurementProcess?.isRunning == true || isMeasuringFolder {
            pendingFolderMeasurementRequests.append(
                PendingFolderMeasurementRequest(
                    arguments: arguments,
                    operation: operation,
                    folderID: folderID,
                    cacheKey: cacheKey
                )
            )
            queuedFolderMeasurementCacheKeys.insert(cacheKey)
            setStatus(
                "Folder size calculation queued; "
                    + "\(pendingFolderMeasurementRequests.count.formatted()) waiting"
            )
            return
        }
        guard let engineURL = Bundle.main.url(forResource: "pikpak", withExtension: nil) else {
            setError("The bundled folder-size engine is missing. Rebuild the app.")
            return
        }

        do {
            let exchangeDirectory = try makePrivateExchangeDirectory()
            var effectiveArguments = arguments
            if case .measure = operation,
               effectiveArguments.contains("--use-size-cache") {
                effectiveArguments.removeAll { $0 == "--use-size-cache" }
                struct Seed: Encodable { let folders: [String: FolderMeasurement] }
                let seedURL = try writePrivateRequest(
                    Seed(folders: folderSizeIndex.usableMeasurements),
                    named: "folder-size-seed", in: exchangeDirectory
                )
                folderMeasurementInputURL = seedURL
                effectiveArguments.append(contentsOf: ["--cache-file", seedURL.path])
            }
            if case .shareMeasure(let request, _, _) = operation {
                let requestURL = try writePrivateRequest(
                    request,
                    named: "share-measure",
                    in: exchangeDirectory
                )
                folderMeasurementInputURL = requestURL
                effectiveArguments.append(contentsOf: ["--request-file", requestURL.path])
            }

            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            let stdoutBuffer = ProcessOutputBuffer()
            let stderrBuffer = ProcessOutputBuffer()

            process.executableURL = engineURL
            process.arguments = effectiveArguments
            process.standardOutput = stdout
            process.standardError = stderr
            process.currentDirectoryURL = exchangeDirectory
            process.qualityOfService = .utility

            var environment = try engineEnvironment()
            let proxy = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if proxy.isEmpty {
                environment.removeValue(forKey: "PIKPAK_PROXY")
            } else {
                environment["PIKPAK_PROXY"] = proxy
            }
            process.environment = environment

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                stdoutBuffer.append(data)
            }
            stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                stderrBuffer.append(data)
                if let text = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async {
                        self?.appendOutput(self?.redactedEngineOutput(text) ?? text)
                    }
                }
            }

            process.terminationHandler = { [weak self] finishedProcess in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                stdoutBuffer.append(stdout.fileHandleForReading.readDataToEndOfFile())
                let trailingError = stderr.fileHandleForReading.readDataToEndOfFile()
                stderrBuffer.append(trailingError)
                let trailingErrorText = String(data: trailingError, encoding: .utf8) ?? ""
                let structuredOutput = stdoutBuffer.string()
                let errorOutput = stderrBuffer.string()
                DispatchQueue.main.async {
                    guard let self else { return }
                    if !trailingErrorText.isEmpty {
                        self.appendOutput(self.redactedEngineOutput(trailingErrorText))
                    }
                    self.finishFolderMeasurementProcess(
                        exitCode: finishedProcess.terminationStatus,
                        structuredOutput: structuredOutput,
                        errorOutput: errorOutput,
                        operation: operation,
                        folderID: folderID
                    )
                }
            }

            folderMeasurementProcess = process
            folderMeasurementStartRevision = folderSizeRevision
            folderMeasurementStartAccountID = folderMeasurementAccountID
            folderMeasurementUsesCachedSubfolders = arguments.contains("--use-size-cache")
            folderMeasurementOperation = operation
            folderMeasurementWasCancelled = false
            measuringFolderID = folderID
            measuringFolderCacheKey = cacheKey
            queuedFolderMeasurementCacheKeys.remove(cacheKey)
            isMeasuringFolder = true
            statusIsError = false
            statusErrorDiagnostic = nil
            status = {
                if case .shareMeasure = operation {
                    return "Calculating shared folder size in the background…"
                }
                return "Calculating folder size in the background…"
            }()
            try process.run()
        } catch {
            cleanupFolderMeasurementInputFile()
            folderMeasurementProcess = nil
            folderMeasurementOperation = nil
            folderMeasurementWasCancelled = false
            isMeasuringFolder = false
            measuringFolderID = nil
            measuringFolderCacheKey = nil
            setError("Could not start folder-size calculation: \(error.localizedDescription)")
            requireFreshAppLoginIfSessionTrustFailed(error)
            startNextPendingFolderMeasurementIfNeeded()
        }
    }

    private func finishFolderMeasurementProcess(
        exitCode: Int32,
        structuredOutput: String,
        errorOutput: String,
        operation finishedOperation: Operation,
        folderID: String
    ) {
        let wasCancelled = folderMeasurementWasCancelled
        synchronizeSharedSessionFromDisk()
        cleanupFolderMeasurementInputFile()
        folderMeasurementProcess = nil
        folderMeasurementOperation = nil
        folderMeasurementWasCancelled = false
        isMeasuringFolder = false
        measuringFolderID = nil
        measuringFolderCacheKey = nil
        guard !isClosingWindow else { return }

        if wasCancelled {
            if !isRunning {
                setStatus("Folder size calculation cancelled")
            }
        } else if exitCode == 0 {
            let linkID: UUID? = {
                if case .shareMeasure(_, _, let linkID) = finishedOperation {
                    return linkID
                }
                return nil
            }()
            finishFolderMeasurement(
                output: structuredOutput,
                folderID: folderID,
                linkID: linkID,
                scanRevision: folderMeasurementStartRevision,
                scanAccountID: folderMeasurementStartAccountID,
                usedCachedSubfolders: folderMeasurementUsesCachedSubfolders
            )
        } else {
            let failure = engineErrorPresentation(
                errorOutput,
                operation: finishedOperation,
                exitCode: exitCode
            )
            if !isRunning {
                setError(failure.summary, diagnostic: failure.diagnostic)
            } else {
                appendOutput(failure.summary + "\n" + failure.diagnostic.displayText + "\n")
            }
            handleWebLoginNeeded(for: errorOutput)
        }

        presentDeferredLoginIfNeeded()
        startPendingQuotaRefreshIfNeeded()
        startNextPendingFolderMeasurementIfNeeded()
        scheduleFolderSizeRepair()
    }

    private func startNextPendingFolderMeasurementIfNeeded() {
        guard
            folderMeasurementProcess?.isRunning != true,
            !isMeasuringFolder,
            !isLoginPresented,
            deferredLoginReason == nil,
            !pendingFolderMeasurementRequests.isEmpty
        else { return }

        let next = pendingFolderMeasurementRequests.removeFirst()
        queuedFolderMeasurementCacheKeys.remove(next.cacheKey)
        runFolderMeasurementEngine(
            arguments: next.arguments,
            operation: next.operation
        )
    }

    private func clearPendingFolderMeasurements() {
        pendingFolderMeasurementRequests.removeAll(keepingCapacity: false)
        queuedFolderMeasurementCacheKeys.removeAll(keepingCapacity: false)
    }

    /// Run uploads independently from the foreground browser engine. The
    /// engine processes still share one app-owned refresh-token store, so a
    /// folder listing and an upload cannot race token rotation even though
    /// their network requests may proceed concurrently.
    private func runUploadEngine(
        arguments: [String],
        destination: BrowserLocation,
        files: [URL]
    ) {
        guard hasUsableSession else {
            presentLogin(reason: "Complete the desktop-session sign-in before accessing PikPak.")
            return
        }
        guard uploadProcess?.isRunning != true, !files.isEmpty else { return }
        uploadUndoMutations.removeAll()
        guard let engineURL = Bundle.main.url(forResource: "pikpak", withExtension: nil) else {
            setError("The bundled upload engine is missing. Rebuild the app.")
            return
        }

        do {
            let exchangeDirectory = try makePrivateExchangeDirectory()
            let inputsURL = exchangeDirectory
                .appendingPathComponent("upload-inputs-\(UUID().uuidString).json")
            try JSONEncoder().encode(files.map(\.path))
                .write(to: inputsURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: inputsURL.path
            )
            uploadInputURL = inputsURL

            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            let stdoutLineBuffer = ProcessLineBuffer()
            let stderrBuffer = ProcessOutputBuffer()
            var effectiveArguments = arguments
            effectiveArguments.append(contentsOf: ["--inputs-file", inputsURL.path])

            process.executableURL = engineURL
            process.arguments = effectiveArguments
            process.standardOutput = stdout
            process.standardError = stderr
            process.currentDirectoryURL = exchangeDirectory
            // Hash-heavy batches may legitimately use dozens of workers. Run
            // the child at utility QoS so AppKit navigation and scrolling keep
            // priority even when the uploader is saturating CPU or storage.
            process.qualityOfService = .utility

            var environment = try engineEnvironment()
            let proxy = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if proxy.isEmpty {
                environment.removeValue(forKey: "PIKPAK_PROXY")
            } else {
                environment["PIKPAK_PROXY"] = proxy
            }
            process.environment = environment

            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let lines = stdoutLineBuffer.append(data)
                guard !lines.isEmpty else { return }
                DispatchQueue.main.async {
                    self?.enqueueUploadOutputLines(lines)
                }
            }
            stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                stderrBuffer.append(data)
                if let text = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async {
                        self?.appendOutput(self?.redactedEngineOutput(text) ?? text)
                    }
                }
            }

            process.terminationHandler = { [weak self] finishedProcess in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                let trailingOutput = stdout.fileHandleForReading.readDataToEndOfFile()
                let trailingError = stderr.fileHandleForReading.readDataToEndOfFile()
                stderrBuffer.append(trailingError)
                let trailingLines = stdoutLineBuffer.append(trailingOutput)
                    + stdoutLineBuffer.drain()
                let trailingErrorText = String(data: trailingError, encoding: .utf8) ?? ""
                let errorOutput = stderrBuffer.string()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.enqueueUploadOutputLines(trailingLines)
                    self.flushAllUploadOutputLines()
                    if !trailingErrorText.isEmpty {
                        self.appendOutput(self.redactedEngineOutput(trailingErrorText))
                    }
                    self.finishUploadProcess(
                        exitCode: finishedProcess.terminationStatus,
                        errorOutput: errorOutput,
                        destination: destination
                    )
                }
            }

            uploadProcess = process
            uploadRequestedStop = false
            isUploadPaused = false
            isUploading = true
            if !isUploadPaused {
                uploadRunState = .hashing
            }
            statusIsError = false
            statusErrorDiagnostic = nil
            if !isDownloading { log = "" }
            if !isRunning {
                status = "Preparing local files for upload…"
            }
            ensureTransferMetricsTask()
            try process.run()
        } catch {
            cleanupUploadInputFile()
            uploadProcess = nil
            uploadRequestedStop = false
            isUploadPaused = false
            isUploading = false
            activeUploadBatchID = nil
            _ = persistTransfersSynchronously()
            finishUploadProgress(as: .failed)
            stopTransferMetricsTaskIfIdle()
            setError("Could not start uploader: \(error.localizedDescription)")
            requireFreshAppLoginIfSessionTrustFailed(error)
        }
    }

    private func finishUploadProcess(
        exitCode: Int32,
        errorOutput: String,
        destination: BrowserLocation
    ) {
        defer { _ = startNextPendingBrowserMoveIfNeeded() }
        guard !isClosingWindow else { cleanupUploadInputFile(); return }
        let wasStopped = uploadRequestedStop
        if !uploadUndoMutations.isEmpty {
            fileUndoHistory.record(FinderUndoEntry(title: "Upload", mutations: uploadUndoMutations,
                                                  uploadBatchID: activeUploadBatchID))
            uploadUndoMutations.removeAll()
        }
        updateSavedUploadProgress()
        let completedBatchID = !wasStopped && exitCode == 0 ? activeUploadBatchID : nil
        if let completedBatchID { savedUploadBatches.removeAll { $0.id == completedBatchID } }
        activeUploadBatchID = nil
        if persistTransfersSynchronously(), let completedBatchID {
            removeUploadCheckpoint(completedBatchID)
        }
        synchronizeSharedSessionFromDisk()
        cleanupUploadInputFile()
        uploadProcess = nil
        uploadRequestedStop = false
        isUploadPaused = false
        isUploading = false

        if wasStopped {
            finishUploadProgress(as: .stopped)
            if !isRunning {
                setStatus("Upload stopped. Use Resume in Saved Uploads to continue; completed cloud files were kept.")
            }
        } else if exitCode == 0 {
            finishUploadProgress(as: .completed)
            if !isRunning {
                setStatus("Upload finished")
            }
        } else {
            finishUploadProgress(as: .failed)
            let failure = engineErrorPresentation(
                errorOutput,
                operation: .upload(destination: destination, files: []),
                exitCode: exitCode
            )
            if !isRunning {
                setError(failure.summary, diagnostic: failure.diagnostic)
            } else {
                appendOutput(
                    failure.summary + "\n" + failure.diagnostic.displayText + "\n"
                )
            }
            handleWebLoginNeeded(for: errorOutput)
        }

        if uploadCompletedFiles + uploadInstantFiles > 0 || uploadCreatedFolders > 0 {
            recordFolderSizeChange(in: [destination.id])
        }

        stopTransferMetricsTaskIfIdle()
        if deferredLoginReason != nil {
            presentDeferredLoginIfNeeded()
            return
        }
        if uploadCompletedFiles + uploadInstantFiles > 0,
           !isBrowsingSharedLink,
           browserStack.last?.id == destination.id,
           !isRunning {
            refreshBrowser()
        } else {
            quotaRefreshPending = true
            startPendingQuotaRefreshIfNeeded()
        }
    }

    /// Link roots use a bounded queue separate from the foreground Browser
    /// helper, so a large retry batch cannot spawn a process for every URL.
    private func runInitialSharedLinkLoad(
        linkID: UUID,
        request: ShareBrowseInput
    ) {
        guard sharedLinkLoadProcesses[linkID] == nil,
              !pendingSharedLinkLoads.contains(where: { $0.linkID == linkID })
        else { return }
        pendingSharedLinkLoads.append((linkID, request))
        startPendingSharedLinkLoads()
    }

    private func startPendingSharedLinkLoads() {
        guard !isStartingPendingSharedLinkLoads else { return }
        isStartingPendingSharedLinkLoads = true
        defer {
            isStartingPendingSharedLinkLoads = false
            refreshActiveSharedLinkLoadingState()
            refreshSharedLinkRetryProgress()
        }
        guard !isClosingWindow, hasUsableSession, !isLoginPresented, deferredLoginReason == nil else {
            failPendingSharedLinkLoads(message: "Sign in, then retry this link.")
            return
        }
        while sharedLinkLoadProcesses.count < maximumConcurrentSharedLinkLoads,
              !pendingSharedLinkLoads.isEmpty {
            let pending = pendingSharedLinkLoads.removeFirst()
            guard sharedLinkSessions[pending.linkID] != nil,
                  sharedLinks.contains(where: { $0.id == pending.linkID && $0.state == .loading })
            else { continue }
            startInitialSharedLinkLoad(linkID: pending.linkID, request: pending.request)
            // A launch failure can request fresh sign-in synchronously.
            if isClosingWindow || !hasUsableSession || isLoginPresented || deferredLoginReason != nil {
                failPendingSharedLinkLoads(message: "Sign in, then retry this link.")
                break
            }
        }
    }

    private func failPendingSharedLinkLoads(message: String) {
        let pending = pendingSharedLinkLoads
        pendingSharedLinkLoads = []
        for load in pending { markSharedLinkFailed(load.linkID, message: message) }
        refreshActiveSharedLinkLoadingState()
        refreshSharedLinkRetryProgress()
    }

    private func startInitialSharedLinkLoad(linkID: UUID, request: ShareBrowseInput) {
        guard hasUsableSession else {
            markSharedLinkFailed(linkID, message: "Sign in, then retry this link.")
            presentLogin(reason: "Complete the desktop-session sign-in before accessing PikPak.")
            return
        }
        guard sharedLinkLoadProcesses[linkID] == nil,
              sharedLinkSessions[linkID] != nil,
              sharedLinks.contains(where: { $0.id == linkID })
        else { return }
        #if FINDER_WORKSPACE_TESTS
        if isFinderWorkspaceFixture, let sharedLinkLoadFixture {
            let process = Process()
            sharedLinkLoadProcesses[linkID] = process
            sharedLinkLoadFixture(linkID, request, process)
            return
        }
        #endif
        guard let engineURL = Bundle.main.url(forResource: "pikpak", withExtension: nil) else {
            markSharedLinkFailed(linkID, message: "The bundled shared-link engine is missing.")
            setError("The bundled download engine is missing. Rebuild the app.")
            return
        }

        var requestURL: URL?
        let process = Process()
        do {
            let exchangeDirectory = try makePrivateExchangeDirectory()
            let encodedRequestURL = try writePrivateRequest(
                request,
                named: "share-browse-\(linkID.uuidString)",
                in: exchangeDirectory
            )
            requestURL = encodedRequestURL

            let stdout = Pipe()
            let stderr = Pipe()
            let stdoutBuffer = ProcessOutputBuffer()
            let stderrBuffer = ProcessOutputBuffer()

            process.executableURL = engineURL
            process.arguments = [
                "share-browse",
                "--request-file", encodedRequestURL.path,
            ]
            process.standardOutput = stdout
            process.standardError = stderr
            process.currentDirectoryURL = exchangeDirectory
            process.qualityOfService = .userInitiated

            var environment = try engineEnvironment()
            let proxy = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if proxy.isEmpty {
                environment.removeValue(forKey: "PIKPAK_PROXY")
            } else {
                environment["PIKPAK_PROXY"] = proxy
            }
            process.environment = environment

            stdout.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                stdoutBuffer.append(data)
            }
            stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                stderrBuffer.append(data)
                if let text = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async {
                        self?.appendOutput(self?.redactedEngineOutput(text) ?? text)
                    }
                }
            }

            process.terminationHandler = { [weak self] finishedProcess in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                stdoutBuffer.append(stdout.fileHandleForReading.readDataToEndOfFile())
                let trailingError = stderr.fileHandleForReading.readDataToEndOfFile()
                stderrBuffer.append(trailingError)
                let structuredOutput = stdoutBuffer.string()
                let errorOutput = stderrBuffer.string()
                DispatchQueue.main.async {
                    self?.finishInitialSharedLinkLoad(
                        linkID: linkID,
                        request: request,
                        process: finishedProcess,
                        exitCode: finishedProcess.terminationStatus,
                        structuredOutput: structuredOutput,
                        errorOutput: errorOutput
                    )
                }
            }

            sharedLinkLoadProcesses[linkID] = process
            sharedLinkLoadInputURLs[linkID] = encodedRequestURL
            refreshActiveSharedLinkLoadingState()
            try process.run()
        } catch {
            if let trackedProcess = sharedLinkLoadProcesses[linkID],
               trackedProcess === process {
                sharedLinkLoadProcesses.removeValue(forKey: linkID)
            }
            let inputURL = sharedLinkLoadInputURLs.removeValue(forKey: linkID) ?? requestURL
            if let inputURL {
                try? FileManager.default.removeItem(at: inputURL)
            }
            refreshActiveSharedLinkLoadingState()
            markSharedLinkFailed(linkID, message: error.localizedDescription)
            let launchDiagnostic = diagnostic(
                for: error,
                source: "macOS shared-link process launcher"
            )
            if activeSharedLinkID == linkID {
                setShareLinkFeedback(
                    "The shared link could not be opened: \(error.localizedDescription)",
                    tone: .error
                )
                setError(
                    "Could not start the shared-link helper: \(error.localizedDescription)",
                    diagnostic: launchDiagnostic
                )
            } else {
                appendOutput(
                    "A shared-link helper could not start.\n\(launchDiagnostic.displayText)\n"
                )
            }
            requireFreshAppLoginIfSessionTrustFailed(error)
        }
    }

    private func finishInitialSharedLinkLoad(
        linkID: UUID,
        request: ShareBrowseInput,
        process finishedProcess: Process,
        exitCode: Int32,
        structuredOutput: String,
        errorOutput: String
    ) {
        guard let trackedProcess = sharedLinkLoadProcesses[linkID],
              trackedProcess === finishedProcess
        else { return }
        defer { startPendingSharedLinkLoads() }

        sharedLinkLoadProcesses.removeValue(forKey: linkID)
        if let inputURL = sharedLinkLoadInputURLs.removeValue(forKey: linkID) {
            try? FileManager.default.removeItem(at: inputURL)
        }
        let stoppedForLogin = sharedLinkLoadsStoppedForLogin.remove(linkID) != nil
        synchronizeSharedSessionFromDisk()

        guard sharedLinkSessions[linkID] != nil,
              sharedLinks.contains(where: { $0.id == linkID })
        else {
            refreshActiveSharedLinkLoadingState()
            if sharedLinkLoadProcesses.isEmpty {
                presentDeferredLoginIfNeeded()
            }
            return
        }

        if stoppedForLogin {
            markSharedLinkFailed(linkID, message: "Sign in again, then select Retry.")
        } else if exitCode == 0 {
            finishInitialSharedLinkPage(
                output: structuredOutput,
                linkID: linkID
            )
        } else {
            let operation = Operation.shareBrowse(
                request: request,
                stack: [.sharedRoot],
                append: false,
                initial: true
            )
            let failure = engineErrorPresentation(
                errorOutput,
                operation: operation,
                exitCode: exitCode
            )
            markSharedLinkFailed(linkID, message: failure.summary)
            if activeSharedLinkID == linkID {
                setShareLinkFeedback("Could not open this link. \(failure.summary)", tone: .error)
                setError(failure.summary, diagnostic: failure.diagnostic)
            } else {
                appendOutput(
                    "A shared link could not be opened.\n\(failure.diagnostic.displayText)\n"
                )
            }
            handleWebLoginNeeded(for: errorOutput)
        }

        refreshActiveSharedLinkLoadingState()
        if sharedLinkLoadProcesses.isEmpty {
            presentDeferredLoginIfNeeded()
        }
    }

    private func finishInitialSharedLinkPage(output: String, linkID: UUID) {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let page = try decoder.decode(ShareBrowsePage.self, from: Data(output.utf8))
            guard var session = sharedLinkSessions[linkID] else { return }

            let updatedAccess = ShareAccessInput(
                url: session.access.url,
                passCode: session.access.passCode,
                passCodeToken: page.passCodeToken
            )
            let workspace = initialSharedLinkWorkspace(from: page)
            session.access = updatedAccess
            session.workspace = workspace
            sharedLinkSessions[linkID] = session

            let resolvedName = page.folderName.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = resolvedName.isEmpty ? "Shared Link" : resolvedName
            updateSharedLink(linkID) { entry in
                entry.name = displayName
                entry.state = .ready
            }
            expandedSharedLinkIDs.insert(linkID)

            if isBrowsingSharedLink, activeSharedLinkID == linkID {
                shareAccess = updatedAccess
                sharedBrowserWorkspace = workspace
                shareLinkIsOpen = true
                restoreBrowserWorkspace(workspace)
                setShareLinkFeedback(
                    "Link opened successfully with your app session. Select files or folders to download or save to My PikPak.",
                    tone: .success
                )
                let suffix = page.nextPageToken == nil ? "" : " (more available)"
                setStatus("Loaded \(workspace.items.count) shared item(s)\(suffix)")
            } else {
                appendOutput("Opened shared link \(displayName).\n")
            }
            persistSharedLinkState()
        } catch {
            let message = "PikPak returned shared-folder data this app could not read."
            markSharedLinkFailed(linkID, message: message)
            let decodeDiagnostic = diagnostic(
                for: error,
                source: "PikPak shared-folder response",
                fallbackCode: "SHARED_LINK_RESPONSE_INVALID"
            )
            appendOutput(
                "Could not decode shared folder data.\n\(decodeDiagnostic.displayText)\n"
            )
            if activeSharedLinkID == linkID {
                setShareLinkFeedback(message, tone: .error)
                setError(message, diagnostic: decodeDiagnostic)
            }
        }
    }

    private func initialSharedLinkWorkspace(
        from page: ShareBrowsePage
    ) -> BrowserWorkspaceSnapshot {
        let rawName = page.folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let location = BrowserLocation(
            id: page.parentId,
            name: rawName.isEmpty ? "Shared Link" : rawName,
            path: "/"
        )
        let items = sortedBrowserItems(page.files)
        var itemPaths: [String: String] = [:]
        var parentIDs: [String: String] = [:]
        for item in items {
            itemPaths[item.id] = joinedRemotePath(folder: location.path, name: item.name)
            parentIDs[item.id] = location.id
        }
        return BrowserWorkspaceSnapshot(
            items: items,
            stack: [location],
            nextPageToken: page.nextPageToken,
            expandedFolderIDs: [],
            childrenByFolderID: [:],
            loadErrors: [:],
            selectedItemID: nil,
            selectedItemIDs: [],
            selectionAnchorID: nil,
            folderSnapshots: [:],
            childPageTokens: [:],
            itemPaths: itemPaths,
            parentIDs: parentIDs
        )
    }

    private func refreshActiveSharedLinkLoadingState() {
        guard let activeSharedLinkID,
              let entry = sharedLinks.first(where: { $0.id == activeSharedLinkID })
        else {
            isOpeningShareLink = false
            return
        }
        if case .loading = entry.state {
            isOpeningShareLink = true
        } else {
            isOpeningShareLink = false
        }
    }

    private func runEngine(arguments: [String], operation: Operation) {
        guard !isChangingAccount else { return }
        if case .archiveInspect(let request, let item) = operation {
            inspectArchive(item, password: request.password)
            return
        }
        guard hasUsableSession else {
            presentLogin(reason: "Complete the desktop-session sign-in before accessing PikPak.")
            return
        }
        guard !isRunning else { return }
        if hasExclusiveBackgroundTask {
            switch operation {
            case .quota, .browse, .browseTree, .preview,
                 .shareBrowse, .shareBrowseTree, .sharePreview, .shareSave:
                break
            default:
                return
            }
        }
        guard let engineURL = Bundle.main.url(forResource: "pikpak", withExtension: nil) else {
            setError("The bundled download engine is missing. Rebuild the app.")
            return
        }

        do {
            let exchangeDirectory = try makePrivateExchangeDirectory()

            var effectiveArguments = arguments
            let batchItemIDs: [String]?
            let batchFilenamePrefix: String
            switch operation {
            case .trashBrowserItems(let ids), .trashDuplicates(let ids):
                batchItemIDs = ids
                batchFilenamePrefix = "trash-ids"
            case .moveBrowserItems(let items, _):
                batchItemIDs = items.map(\.id)
                batchFilenamePrefix = "move-ids"
            default:
                batchItemIDs = nil
                batchFilenamePrefix = "item-ids"
            }
            if let ids = batchItemIDs {
                let idsURL = exchangeDirectory
                    .appendingPathComponent("\(batchFilenamePrefix)-\(UUID().uuidString).json")
                try JSONEncoder().encode(ids).write(to: idsURL, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: idsURL.path
                )
                operationInputURL = idsURL
                effectiveArguments.append(contentsOf: ["--ids-file", idsURL.path])
            }
            if case .upload(_, let files) = operation {
                let inputsURL = exchangeDirectory
                    .appendingPathComponent("upload-inputs-\(UUID().uuidString).json")
                try JSONEncoder().encode(files.map(\.path))
                    .write(to: inputsURL, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: inputsURL.path
                )
                operationInputURL = inputsURL
                effectiveArguments.append(contentsOf: ["--inputs-file", inputsURL.path])
            }
            switch operation {
            case .undoFiles(let request, _):
                let requestURL = try writePrivateRequest(request, named: "file-undo", in: exchangeDirectory)
                operationInputURL = requestURL
                effectiveArguments.append(contentsOf: ["--request-file", requestURL.path])
            case .shareBrowse(let request, _, _, _):
                let requestURL = try writePrivateRequest(
                    request,
                    named: "share-browse",
                    in: exchangeDirectory
                )
                operationInputURL = requestURL
                effectiveArguments.append(contentsOf: ["--request-file", requestURL.path])
            case .shareBrowseTree(let request, _, _, _, _):
                let requestURL = try writePrivateRequest(
                    request,
                    named: "share-tree",
                    in: exchangeDirectory
                )
                operationInputURL = requestURL
                effectiveArguments.append(contentsOf: ["--request-file", requestURL.path])
            case .sharePreview(let request, _):
                let requestURL = try writePrivateRequest(
                    request,
                    named: "share-preview",
                    in: exchangeDirectory
                )
                operationInputURL = requestURL
                effectiveArguments.append(contentsOf: ["--request-file", requestURL.path])
            case .shareMeasure(let request, _, _):
                let requestURL = try writePrivateRequest(
                    request,
                    named: "share-measure",
                    in: exchangeDirectory
                )
                operationInputURL = requestURL
                effectiveArguments.append(contentsOf: ["--request-file", requestURL.path])
            case .shareDownload(let request):
                let requestURL = try writePrivateRequest(
                    request,
                    named: "share-download",
                    in: exchangeDirectory
                )
                operationInputURL = requestURL
                effectiveArguments.append(contentsOf: ["--request-file", requestURL.path])
            case .shareSave(let request, _, _):
                let requestURL = try writePrivateRequest(
                    request,
                    named: "share-save",
                    in: exchangeDirectory
                )
                operationInputURL = requestURL
                effectiveArguments.append(contentsOf: ["--request-file", requestURL.path])
            case .archiveInspect(let request, _):
                let requestURL = try writePrivateRequest(
                    request,
                    named: "archive-inspect",
                    in: exchangeDirectory
                )
                operationInputURL = requestURL
                effectiveArguments.append(contentsOf: ["--request-file", requestURL.path])
            default:
                break
            }

            let process = Process()
            let stdout = Pipe()
            let stderr = Pipe()
            let stdoutBuffer = ProcessOutputBuffer()
            let stderrBuffer = ProcessOutputBuffer()
            let stdoutLineBuffer = ProcessLineBuffer()
            let stderrLineBuffer = ProcessLineBuffer()
            let structured = operation.hasStructuredOutput
            let tracksDownloadProgress: Bool
            if case .download = operation {
                tracksDownloadProgress = true
            } else if case .shareDownload = operation {
                tracksDownloadProgress = true
            } else {
                tracksDownloadProgress = false
            }
            let tracksUploadProgress: Bool
            if case .upload = operation {
                tracksUploadProgress = true
            } else {
                tracksUploadProgress = false
            }
            let tracksDuplicateProgress: Bool
            if case .duplicates = operation {
                tracksDuplicateProgress = true
            } else {
                tracksDuplicateProgress = false
            }
            let tracksEmptyFolderProgress: Bool
            if case .emptyFolders = operation {
                tracksEmptyFolderProgress = true
            } else {
                tracksEmptyFolderProgress = false
            }
            process.executableURL = engineURL
            process.arguments = effectiveArguments
            process.standardOutput = stdout
            process.standardError = stderr
            process.currentDirectoryURL = exchangeDirectory

            var environment = try engineEnvironment()
            let proxy = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if proxy.isEmpty {
                environment.removeValue(forKey: "PIKPAK_PROXY")
            } else {
                environment["PIKPAK_PROXY"] = proxy
            }
            process.environment = environment

            stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                if structured {
                    stdoutBuffer.append(data)
                } else if tracksDownloadProgress || tracksUploadProgress {
                    if tracksDownloadProgress {
                        // Keep an ordered source of truth for the final
                        // dashboard in addition to the live line callbacks.
                        stdoutBuffer.append(data)
                    }
                    let lines = stdoutLineBuffer.append(data)
                    guard !lines.isEmpty else { return }
                    DispatchQueue.main.async {
                        for line in lines {
                            if tracksDownloadProgress {
                                self?.handleDownloadOutputLine(line)
                            } else {
                                self?.handleUploadOutputLine(line)
                            }
                        }
                    }
                } else if let text = String(data: data, encoding: .utf8) {
                    DispatchQueue.main.async {
                        self?.appendOutput(text)
                    }
                }
            }
            stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                if tracksDuplicateProgress || tracksEmptyFolderProgress {
                    let lines = stderrLineBuffer.append(data)
                    guard !lines.isEmpty else { return }
                    let prefix = tracksDuplicateProgress
                        ? duplicateProgressPrefix
                        : emptyFolderProgressPrefix
                    for line in lines where !line.hasPrefix(prefix) {
                        stderrBuffer.append(Data((line + "\n").utf8))
                    }
                    DispatchQueue.main.async {
                        for line in lines {
                            if tracksDuplicateProgress {
                                self?.handleDuplicateStderrLine(line)
                            } else {
                                self?.handleEmptyFolderStderrLine(line)
                            }
                        }
                    }
                } else if let text = String(data: data, encoding: .utf8) {
                    stderrBuffer.append(data)
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.appendOutput(self.redactedEngineOutput(text))
                    }
                }
            }

            process.terminationHandler = { [weak self] finishedProcess in
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                let trailingOutput = stdout.fileHandleForReading.readDataToEndOfFile()
                let trailingError = stderr.fileHandleForReading.readDataToEndOfFile()
                if structured || tracksDownloadProgress {
                    stdoutBuffer.append(trailingOutput)
                }
                let trailingDuplicateLines: [String]
                if tracksDuplicateProgress || tracksEmptyFolderProgress {
                    trailingDuplicateLines = stderrLineBuffer.append(trailingError)
                        + stderrLineBuffer.drain()
                    let prefix = tracksDuplicateProgress
                        ? duplicateProgressPrefix
                        : emptyFolderProgressPrefix
                    for line in trailingDuplicateLines
                    where !line.hasPrefix(prefix) {
                        stderrBuffer.append(Data((line + "\n").utf8))
                    }
                } else {
                    trailingDuplicateLines = []
                    stderrBuffer.append(trailingError)
                }
                let trailingOutputText = String(data: trailingOutput, encoding: .utf8) ?? ""
                let trailingErrorText = String(data: trailingError, encoding: .utf8) ?? ""
                let trailingDownloadLines: [String]
                if tracksDownloadProgress || tracksUploadProgress {
                    trailingDownloadLines = stdoutLineBuffer.append(trailingOutput) + stdoutLineBuffer.drain()
                } else {
                    trailingDownloadLines = []
                }
                let structuredOutput = stdoutBuffer.string()
                let errorOutput = stderrBuffer.string()
                DispatchQueue.main.async {
                    guard let self else { return }
                    if tracksDownloadProgress {
                        self.replayDownloadProgress(from: structuredOutput)
                    } else if tracksUploadProgress {
                        for line in trailingDownloadLines {
                            self.handleUploadOutputLine(line)
                        }
                    } else if !structured, !trailingOutputText.isEmpty {
                        self.appendOutput(trailingOutputText)
                    }
                    if tracksDuplicateProgress || tracksEmptyFolderProgress {
                        for line in trailingDuplicateLines {
                            if tracksDuplicateProgress {
                                self.handleDuplicateStderrLine(line)
                            } else {
                                self.handleEmptyFolderStderrLine(line)
                            }
                        }
                    } else if !trailingErrorText.isEmpty {
                        self.appendOutput(self.redactedEngineOutput(trailingErrorText))
                    }
                    self.finishProcess(
                        exitCode: finishedProcess.terminationStatus,
                        structuredOutput: structuredOutput,
                        errorOutput: errorOutput
                    )
                }
            }

            self.process = process
            if case .moveBrowserItems(let items, _) = operation {
                undoMoveOrigins = Dictionary(items.compactMap { item in
                    accountSizeParent(of: item).map { (item.id, $0) }
                }, uniquingKeysWith: { first, _ in first })
            }
            self.operation = operation
            foregroundSizeRevision = folderSizeRevision
            requestedStop = false
            isRunning = true
            isBrowserLoading = false
            isDeletingDuplicates = false
            isCreatingFolder = false
            isMovingBrowserItems = false
            statusIsError = false
            statusErrorDiagnostic = nil
            if !structured {
                log = ""
            }
            switch operation {
            case .quota(let announcesResult):
                isQuotaLoading = true
                if announcesResult {
                    status = "Testing PikPak connection and storage…"
                }
            case .download:
                isDownloading = true
                downloadRunState = .scanning
                status = "Scanning the remote path…"
                ensureTransferMetricsTask()
            case .shareDownload:
                isDownloading = true
                downloadRunState = .scanning
                status = "Scanning the shared selection…"
                ensureTransferMetricsTask()
            case .upload(let destination, _):
                isUploading = true
                uploadRunState = .hashing
                uploadDestination = destination
                status = "Preparing local files for upload…"
            case .browse(_, let append, let includesQuota, _):
                isBrowserLoading = true
                if includesQuota {
                    isQuotaLoading = true
                }
                status = append ? "Loading more files…" : "Loading cloud folder…"
            case .shareBrowse(_, _, let append, _):
                isBrowserLoading = true
                status = append ? "Loading more shared files…" : "Opening shared folder…"
            case .browseTree(let folderID, let folderName, _, let append):
                browserTreeLoadingFolderIDs.insert(folderID)
                browserTreeLoadErrors.removeValue(forKey: folderID)
                status = append
                    ? "Loading more items in \(folderName)…"
                    : "Expanding \(folderName)…"
            case .shareBrowseTree(_, let folderID, let folderName, _, let append):
                browserTreeLoadingFolderIDs.insert(folderID)
                browserTreeLoadErrors.removeValue(forKey: folderID)
                status = append
                    ? "Loading more shared items in \(folderName)…"
                    : "Expanding shared folder \(folderName)…"
            case .preview:
                isPreviewLoading = true
                status = "Preparing secure preview…"
            case .sharePreview:
                isPreviewLoading = true
                status = "Preparing shared-file preview…"
            case .archiveInspect(_, let item):
                status = "Reading \(item.name) on PikPak…"
            case .archiveExtract(let item):
                status = "Starting cloud extraction for \(item.name)…"
            case .measure:
                isMeasuringFolder = true
                status = "Calculating selected folder size…"
            case .shareMeasure:
                isMeasuringFolder = true
                status = "Calculating shared folder size…"
            case .shareSave(_, let itemCount, _):
                isSavingSharedItems = true
                status = "Saving \(itemCount.formatted()) shared item(s) to PikPak…"
            case .duplicates(let scope):
                isScanningDuplicates = true
                status = "Checking \(scope.name) for duplicate files…"
            case .trash(_, let itemName):
                status = "Moving \(itemName) to Trash…"
            case .undoFiles(_, let title):
                status = "\(title)…"
            case .trashBrowserItems(let ids):
                status = "Moving \(ids.count) selected item(s) to Trash…"
            case .moveBrowserItems(let items, let destination):
                isMovingBrowserItems = true
                status = "Moving \(items.count.formatted()) item(s) to \(destination.name)…"
            case .renameItem(let item, let name):
                status = "Renaming \(item.name) to \(name)…"
            case .mergeFolders(let folders, let destination):
                isMergingFolders = true
                status = "Merging \(folders.count.formatted()) folders into \(destination.name)…"
            case .createFolder(let parent, let name):
                isCreatingFolder = true
                status = "Creating \(name) in \(parent.name)…"
            case .trashDuplicates(let ids):
                isDeletingDuplicates = true
                status = "Moving \(ids.count) selected duplicate file(s) to Trash…"
            case .emptyFolders(let scope):
                isRemovingEmptyFolders = true
                status = "Scanning \(scope.name) for empty folders…"
            case .dsStoreFiles(let scope):
                isRemovingDSStoreFiles = true
                status = "Scanning \(scope.name) for .DS_Store files…"
            }
            try process.run()
        } catch {
            cleanupCredentialFiles()
            self.process = nil
            self.operation = nil
            isRunning = false
            isBrowserLoading = false
            if case .browseTree(let folderID, _, _, _) = operation {
                browserTreeLoadingFolderIDs.remove(folderID)
            }
            if case .shareBrowseTree(_, let folderID, _, _, _) = operation {
                browserTreeLoadingFolderIDs.remove(folderID)
            }
            if case .preview = operation {
                isPreviewLoading = false
            }
            if case .sharePreview = operation {
                isPreviewLoading = false
            }
            if case .download = operation {
                isDownloading = false
                finishDownloadProgress(as: .failed)
            }
            if case .shareDownload = operation {
                isDownloading = false
                finishDownloadProgress(as: .failed)
            }
            if case .upload = operation {
                finishUploadProgress(as: .failed)
            }
            if case .quota = operation {
                isQuotaLoading = false
                storageQuotaError = "Storage information could not be loaded."
            }
            if case .browse(_, _, let includesQuota, _) = operation, includesQuota {
                isQuotaLoading = false
                storageQuotaError = "Storage information could not be loaded."
            }
            if case .measure = operation {
                isMeasuringFolder = false
                measuringFolderID = nil
                measuringFolderCacheKey = nil
            }
            if case .shareMeasure = operation {
                isMeasuringFolder = false
                measuringFolderID = nil
                measuringFolderCacheKey = nil
            }
            isDeletingDuplicates = false
            if case .emptyFolders = operation {
                isRemovingEmptyFolders = false
            }
            if case .dsStoreFiles = operation {
                isRemovingDSStoreFiles = false
            }
            isCreatingFolder = false
            isMovingBrowserItems = false
            if case .mergeFolders = operation {
                isMergingFolders = false
            }
            let launchDiagnostic = diagnostic(
                for: error,
                source: "macOS process launcher"
            )
            switch operation {
            case .preview, .sharePreview:
                previewStreamingState = .failed
                previewPlaybackError = "The preview helper could not be started."
                previewErrorDiagnostic = launchDiagnostic
            case .archiveInspect(_, let item), .archiveExtract(let item):
                if let task = archiveTasks.first(where: { $0.item.id == item.id }) {
                    updateArchiveTask(task.id) { $0.error = launchDiagnostic }
                }
            default:
                break
            }
            setError(
                "Could not start downloader: \(error.localizedDescription)",
                diagnostic: launchDiagnostic
            )
            if case .shareBrowse(_, _, _, let initial) = operation, initial {
                isOpeningShareLink = false
                markActiveSharedLinkFailed(error.localizedDescription)
                setShareLinkFeedback(
                    "The shared link could not be opened: \(error.localizedDescription)",
                    tone: .error
                )
            }
            if case .shareSave = operation {
                isSavingSharedItems = false
                setShareLinkFeedback(
                    "The selected items could not be saved: \(error.localizedDescription)",
                    tone: .error
                )
            }
            requireFreshAppLoginIfSessionTrustFailed(error)
        }
    }

    private func finishProcess(exitCode: Int32, structuredOutput: String, errorOutput: String) {
        defer {
            if let navigation = pendingFileSearchNavigation, !isRunning {
                revealFileSearchResult(navigation)
            }
        }
        let completedOperation = operation
        let completedWasPreview: Bool
        switch completedOperation {
        case .preview, .sharePreview:
            completedWasPreview = true
        default:
            completedWasPreview = false
        }
        synchronizeSharedSessionFromDisk()
        cleanupCredentialFiles()
        process = nil
        isRunning = false
        isBrowserLoading = false
        if case .some(.download) = completedOperation {
            isDownloading = false
        }
        if case .some(.shareDownload) = completedOperation {
            isDownloading = false
        }
        if case .some(.shareBrowse(_, _, _, let initial)) = completedOperation, initial {
            isOpeningShareLink = false
        }
        if case .some(.shareSave) = completedOperation {
            isSavingSharedItems = false
        }
        if case .some(.browseTree(let folderID, _, _, _)) = completedOperation {
            browserTreeLoadingFolderIDs.remove(folderID)
        }
        if case .some(.shareBrowseTree(_, let folderID, _, _, _)) = completedOperation {
            browserTreeLoadingFolderIDs.remove(folderID)
        }
        if completedWasPreview {
            isPreviewLoading = false
        }
        if case .some(.quota) = completedOperation {
            isQuotaLoading = false
        }
        if case .some(.browse(_, _, let includesQuota, _)) = completedOperation,
           includesQuota {
            isQuotaLoading = false
        }
        if case .some(.measure) = completedOperation {
            isMeasuringFolder = false
            measuringFolderID = nil
            measuringFolderCacheKey = nil
        }
        if case .some(.shareMeasure) = completedOperation {
            isMeasuringFolder = false
            measuringFolderID = nil
            measuringFolderCacheKey = nil
        }
        isDeletingDuplicates = false
        if case .some(.emptyFolders) = completedOperation {
            isRemovingEmptyFolders = false
        }
        if case .some(.dsStoreFiles) = completedOperation {
            isRemovingDSStoreFiles = false
        }
        isCreatingFolder = false
        isMovingBrowserItems = false
        if case .some(.mergeFolders) = completedOperation {
            isMergingFolders = false
        }

        if requestedStop {
            switch completedOperation {
            case .measure:
                setStatus("Folder size calculation cancelled")
            case .duplicates:
                setStatus("Duplicate scan cancelled")
            case .download:
                finishDownloadProgress(as: .stopped)
                setStatus("Stopped. Any .part files were kept and will resume next time.")
            case .shareDownload:
                finishDownloadProgress(as: .stopped)
                setStatus("Stopped. Shared-file .part files were kept for resume.")
            case .upload:
                finishUploadProgress(as: .stopped)
                setStatus("Upload stopped. Completed cloud files were kept.")
            default:
                setStatus("Stopped. Any .part files were kept and will resume next time.")
            }
        } else if exitCode == 0 {
            switch completedOperation {
            case .quota(let announcesResult):
                finishQuota(output: structuredOutput, announcesResult: announcesResult)
            case .download:
                finishDownloadProgress(as: .completed)
                setStatus("Download finished")
            case .shareDownload:
                finishDownloadProgress(as: .completed)
                setStatus("Shared-link download finished")
            case .upload:
                finishUploadProgress(as: .completed)
                setStatus("Upload finished")
            case .browse(let stack, let append, let includesQuota, let preservesOutline):
                finishBrowse(
                    output: structuredOutput,
                    stack: stack,
                    append: append,
                    includesQuota: includesQuota,
                    preservesOutline: preservesOutline
                )
            case .shareBrowse(_, let stack, let append, let initial):
                finishShareBrowse(
                    output: structuredOutput,
                    stack: stack,
                    append: append,
                    initial: initial
                )
            case .browseTree(let folderID, let folderName, let folderPath, let append):
                finishBrowserTreeBrowse(
                    output: structuredOutput,
                    folderID: folderID,
                    folderName: folderName,
                    folderPath: folderPath,
                    append: append
                )
            case .shareBrowseTree(_, let folderID, let folderName, let folderPath, let append):
                finishShareBrowserTreeBrowse(
                    output: structuredOutput,
                    folderID: folderID,
                    folderName: folderName,
                    folderPath: folderPath,
                    append: append
                )
            case .preview(let fileID):
                finishPreview(output: structuredOutput, fileID: fileID)
            case .sharePreview(_, let fileID):
                finishPreview(output: structuredOutput, fileID: fileID)
            case .archiveInspect(_, let item):
                if let task = archiveTasks.first(where: { $0.item.id == item.id }) {
                    finishArchiveInspection(output: structuredOutput, item: item, taskID: task.id)
                }
            case .archiveExtract(let item):
                setStatus("Cloud extraction started for \(item.name)")
            case .measure(let folderID):
                finishFolderMeasurement(output: structuredOutput, folderID: folderID)
            case .shareMeasure(_, let folderID, let linkID):
                finishFolderMeasurement(
                    output: structuredOutput,
                    folderID: folderID,
                    linkID: linkID
                )
            case .shareSave(let request, _, let linkID):
                finishShareSave(
                    output: structuredOutput,
                    requestedIDs: request.fileIds,
                    linkID: linkID
                )
            case .duplicates(let scope):
                finishDuplicateScan(output: structuredOutput, scope: scope)
            case .trash(let itemID, let itemName):
                finishTrash(output: structuredOutput, itemID: itemID, itemName: itemName)
            case .undoFiles(let request, let title):
                finishFileUndo(output: structuredOutput, request: request, title: title)
            case .trashBrowserItems(let ids):
                finishTrashBrowserItems(output: structuredOutput, requestedIDs: ids)
            case .moveBrowserItems(let items, let destination):
                finishMoveBrowserItems(
                    output: structuredOutput,
                    requestedItems: items,
                    destination: destination
                )
            case .renameItem(let item, let name):
                finishRenameItem(
                    output: structuredOutput,
                    requestedItem: item,
                    requestedName: name
                )
            case .mergeFolders(let folders, let destination):
                finishMergeFolders(
                    output: structuredOutput,
                    requestedFolders: folders,
                    destination: destination
                )
            case .createFolder(let parent, let name):
                finishCreateFolder(output: structuredOutput, parent: parent, requestedName: name)
            case .trashDuplicates(let ids):
                finishTrashDuplicates(output: structuredOutput, requestedIDs: ids)
            case .emptyFolders(let scope):
                finishEmptyFolderCleanup(output: structuredOutput, scope: scope)
            case .dsStoreFiles(let scope):
                finishDSStoreCleanup(output: structuredOutput, scope: scope)
            case .none:
                setStatus("Finished")
            }
        } else {
            // Large CLI batches report confirmed IDs even when a later batch
            // fails. Keep those changes reversible without claiming the rest.
            if !structuredOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                switch completedOperation {
                case .trash(let id, let name): finishTrash(output: structuredOutput, itemID: id, itemName: name)
                case .trashBrowserItems(let ids): finishTrashBrowserItems(output: structuredOutput, requestedIDs: ids)
                case .moveBrowserItems(let items, let destination): finishMoveBrowserItems(output: structuredOutput, requestedItems: items, destination: destination)
                default: break
                }
            }
            if case .some(.download) = completedOperation {
                finishDownloadProgress(as: .failed)
            }
            if case .some(.shareDownload) = completedOperation {
                finishDownloadProgress(as: .failed)
            }
            if case .some(.upload) = completedOperation {
                finishUploadProgress(as: .failed)
            }
            if case .some(.preview) = completedOperation {
                previewStreamingState = .failed
            }
            if case .some(.sharePreview) = completedOperation {
                previewStreamingState = .failed
            }
            let failure = engineErrorPresentation(
                errorOutput,
                operation: completedOperation,
                exitCode: exitCode
            )
            let message = failure.summary
            switch completedOperation {
            case .some(.preview(let fileID)), .some(.sharePreview(_, let fileID)):
                clearPendingQuickLook(for: fileID)
                previewFileID = fileID
                previewPlaybackError = "PikPak could not prepare a secure preview source for this file."
                previewErrorDiagnostic = failure.diagnostic
            case .some(.archiveInspect(_, let item)), .some(.archiveExtract(let item)):
                if let task = archiveTasks.first(where: { $0.item.id == item.id }) {
                    updateArchiveTask(task.id) { $0.error = failure.diagnostic }
                }
            default:
                break
            }
            if case .some(.shareBrowse(_, _, _, let initial)) = completedOperation, initial {
                markActiveSharedLinkFailed(message)
                setShareLinkFeedback("Could not open this link. \(message)", tone: .error)
            }
            if case .some(.shareSave) = completedOperation {
                setShareLinkFeedback("Could not save the selected items. \(message)", tone: .error)
            }
            if case .some(.quota) = completedOperation {
                storageQuotaError = message
            }
            if case .some(.browseTree(let folderID, _, _, _)) = completedOperation {
                browserTreeLoadErrors[folderID] = message
            }
            if case .some(.shareBrowseTree(_, let folderID, _, _, _)) = completedOperation {
                browserTreeLoadErrors[folderID] = message
            }
            if case .some(.browse(_, _, let includesQuota, _)) = completedOperation,
               includesQuota {
                storageQuotaError = "Storage information could not be loaded."
            }
            if case .some(.quota(let announcesResult)) = completedOperation,
               !announcesResult,
               !isRejectedSessionError(errorOutput.lowercased()) {
                storageQuotaError = message
                appendOutput(
                    "Storage refresh: \(message)\n\(failure.diagnostic.displayText)\n"
                )
            } else {
                setError(message, diagnostic: failure.diagnostic)
            }
            handleWebLoginNeeded(for: errorOutput)
        }
        let operationWasStopped = requestedStop
        if case .undoFiles = completedOperation {
            fileUndoHistory.cancelRequest()
            if !isBrowsingSharedLink { fileUndoRefreshFeedback = (status, statusIsError, statusErrorDiagnostic) }
        } else if case .browse = completedOperation, let feedback = fileUndoRefreshFeedback {
            fileUndoRefreshFeedback = nil
            if exitCode == 0 {
                if feedback.isError { setError(feedback.message, diagnostic: feedback.diagnostic) }
                else { setStatus(feedback.message) }
            }
        }
        if exitCode != 0 || operationWasStopped {
            let changedParents = sizeMutationScopes(for: completedOperation)
            if !changedParents.isEmpty { recordFolderSizeChange(in: changedParents) }
        }
        let shouldRefreshAfterUpload: Bool
        if case .some(.upload) = completedOperation {
            shouldRefreshAfterUpload = uploadCompletedFiles + uploadInstantFiles > 0
        } else {
            shouldRefreshAfterUpload = false
        }
        if shouldRefreshAfterUpload {
            if case .some(.upload(let destination, _)) = completedOperation {
                recordFolderSizeChange(in: [destination.id])
            }
        }
        let shouldStartPendingPreview = completedWasPreview && exitCode == 0 && !operationWasStopped
        operation = nil
        requestedStop = false
        stopTransferMetricsTaskIfIdle()
        if deferredLoginReason != nil {
            presentDeferredLoginIfNeeded()
            return
        }
        if case .undoFiles = completedOperation, !isBrowsingSharedLink, !isClosingWindow, !isLoginPresented {
            refreshBrowser()
            return
        }
        if !operationWasStopped {
            _ = startNextPendingSharedSaveIfNeeded()
        }
        let startedPendingMove = startNextPendingBrowserMoveIfNeeded()
        // Tree helpers have their own read-only lane. Starting a queued
        // expansion must not consume or clear the next selected-file preview.
        if !operationWasStopped { startNextPendingBrowserTreeLoadIfNeeded() }
        let startedQuickLook = !startedPendingMove && startPendingQuickLookMetadataIfNeeded()
        if !startedPendingMove, !startedQuickLook, shouldStartPendingPreview {
            startPendingAutomaticPreviewIfNeeded()
        } else if completedWasPreview {
            pendingAutomaticPreviewID = nil
        }
        if startedPendingMove {
            quotaRefreshPending = quotaRefreshPending || shouldRefreshAfterUpload
        } else if shouldRefreshAfterUpload, !isBrowsingSharedLink {
            quotaRefreshPending = false
            refreshBrowser()
        } else {
            startPendingQuotaRefreshIfNeeded()
        }
    }

    private func finishDuplicateProcess(
        exitCode: Int32,
        structuredOutput: String,
        errorOutput: String,
        scope: BrowserLocation
    ) {
        let wasCancelled = duplicateScanWasCancelled
        synchronizeSharedSessionFromDisk()
        duplicateProcess = nil
        duplicateScanWasCancelled = false
        duplicateProgressFlushScheduled = false
        pendingDuplicateProgressLines.removeAll(keepingCapacity: true)
        isScanningDuplicates = false
        duplicateRetryAttempt = 0
        duplicateRetryMaxAttempts = 0
        duplicateRetryInMillis = 0

        if wasCancelled {
            taskActivity.finish(.duplicates, state: .cancelled, message: "Duplicate scan cancelled")
            if !isRunning {
                setStatus("Duplicate scan cancelled")
            }
            presentDeferredLoginIfNeeded()
            if !startNextPendingBrowserMoveIfNeeded() {
                startPendingQuotaRefreshIfNeeded()
            }
            return
        }

        if exitCode == 0 {
            finishDuplicateScan(output: structuredOutput, scope: scope)
        } else {
            let failure = engineErrorPresentation(
                errorOutput,
                operation: .duplicates(scope: scope),
                exitCode: exitCode
            )
            taskActivity.finish(.duplicates, state: .failed, message: failure.summary, diagnostic: failure.diagnostic)
            setError(failure.summary, diagnostic: failure.diagnostic)
            handleWebLoginNeeded(for: errorOutput)
        }
        presentDeferredLoginIfNeeded()
        if !startNextPendingBrowserMoveIfNeeded() {
            startPendingQuotaRefreshIfNeeded()
        }
    }

    private func finishMaintenanceProcess(
        exitCode: Int32,
        structuredOutput: String,
        errorOutput: String,
        operation finishedOperation: Operation
    ) {
        defer { _ = startNextPendingBrowserMoveIfNeeded() }
        let wasCancelled = maintenanceWasCancelled
        synchronizeSharedSessionFromDisk()
        maintenanceProcess = nil
        maintenanceOperation = nil
        maintenanceWasCancelled = false
        maintenanceProgressFlushScheduled = false
        pendingMaintenanceProgressLines.removeAll(keepingCapacity: true)
        isRemovingEmptyFolders = false
        isRemovingDSStoreFiles = false

        if wasCancelled {
            let message: String
            switch finishedOperation {
            case .emptyFolders:
                message = "Empty-folder scan cancelled. Any folders already moved remain in PikPak Trash."
            case .dsStoreFiles:
                message = ".DS_Store scan cancelled. Any files already moved remain in PikPak Trash."
            default:
                message = "Maintenance scan cancelled"
            }
            if let kind = taskKind(for: finishedOperation) {
                taskActivity.finish(kind, state: .cancelled, message: message)
            }
            setMaintenanceStatus(message)
            presentDeferredLoginIfNeeded()
            startPendingQuotaRefreshIfNeeded()
            return
        }

        if exitCode == 0 {
            switch finishedOperation {
            case .emptyFolders(let scope):
                finishEmptyFolderCleanup(output: structuredOutput, scope: scope)
            case .dsStoreFiles(let scope):
                finishDSStoreCleanup(output: structuredOutput, scope: scope)
            default:
                break
            }
            quotaRefreshPending = true
        } else {
            let failure = engineErrorPresentation(
                errorOutput,
                operation: finishedOperation,
                exitCode: exitCode
            )
            if let kind = taskKind(for: finishedOperation) {
                taskActivity.finish(kind, state: .failed, message: failure.summary, diagnostic: failure.diagnostic)
            }
            maintenanceStatus = failure.summary
            appendOutput(failure.summary + "\n" + failure.diagnostic.displayText + "\n")
            if !isRunning {
                setError(failure.summary, diagnostic: failure.diagnostic)
            }
            handleWebLoginNeeded(for: errorOutput)
        }

        presentDeferredLoginIfNeeded()
        startPendingQuotaRefreshIfNeeded()
    }

    private func resetDownloadProgress() {
        downloadOutputFlushScheduled = false
        pendingDownloadOutputLines.removeAll(keepingCapacity: true)
        downloadRunState = .scanning
        downloadTotalFiles = 0
        downloadTotalBytes = 0
        downloadDownloadedBytes = 0
        downloadCompletedFiles = 0
        downloadSkippedFiles = 0
        downloadFailedFiles = 0
        downloadBytesPerSecond = 0
        downloadQueueTransfers = []
        downloadQueueOffset = 0
        downloadingTransfers = []
        completedDownloadTransfers = []
        activeDownloadTransfers = [:]
        queuedDownloadIDs = []
        settledDownloadIDs = []
        settledDownloadBytes = 0
        settledDownloadNetworkBytes = 0
        downloadNetworkBaselines = [:]
        downloadNetworkBytesByID = [:]
        downloadFileTotalsByID = [:]
        downloadNetworkTransferredBytes = 0
        lastDownloadSpeedSampleDate = Date()
        lastDownloadSpeedSampleBytes = 0
        lastDownloadNetworkProgressDate = nil
    }

    private func resetUploadProgress(
        destination: BrowserLocation,
        preservingFailedHistory: Bool = false
    ) {
        preserveUploadFailureHistoryForCurrentRun = preservingFailedHistory
        uploadOutputFlushScheduled = false
        pendingUploadOutputLines.removeAll(keepingCapacity: true)
        uploadRunState = .hashing
        isUploadPaused = false
        uploadDestination = destination
        uploadTotalFiles = 0
        uploadTotalBytes = 0
        uploadUploadedBytes = 0
        uploadCompletedFiles = 0
        uploadInstantFiles = 0
        uploadFailedFiles = 0
        uploadTotalFolders = 0
        uploadCreatedFolders = 0
        uploadFileWorkers = 0
        uploadMultipartWorkers = 0
        uploadSkippedEntries = 0
        uploadBytesPerSecond = 0
        uploadHashBytesPerSecond = 0
        uploadQueueTransfers = []
        uploadQueueOffset = 0
        uploadingTransfers = []
        completedUploadTransfers = []
        if !preservingFailedHistory {
            failedUploadTransfers = []
        }
        activeUploadTransfers = [:]
        queuedUploadIDs = []
        settledUploadIDs = []
        settledUploadBytes = 0
        settledUploadNetworkBytes = 0
        settledUploadHashedBytes = 0
        uploadNetworkTransferredBytes = 0
        uploadHashedBytes = 0
        lastUploadSpeedSampleDate = Date()
        lastUploadSpeedSampleBytes = 0
        lastUploadNetworkProgressDate = nil
        lastUploadHashSpeedSampleDate = Date()
        lastUploadHashSpeedSampleBytes = 0
        lastUploadHashProgressDate = nil
    }

    private func enqueueDownloadOutputLines(_ lines: [String]) {
        guard isDownloading, !lines.isEmpty else { return }
        pendingDownloadOutputLines.append(contentsOf: lines)
        scheduleDownloadOutputFlush()
    }

    private func scheduleDownloadOutputFlush() {
        guard !downloadOutputFlushScheduled, !pendingDownloadOutputLines.isEmpty else {
            return
        }
        downloadOutputFlushScheduled = true
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.downloadOutputBatchDelay
        ) { [weak self] in
            guard let self, self.downloadOutputFlushScheduled else { return }
            self.downloadOutputFlushScheduled = false
            self.flushDownloadOutputBatch()
        }
    }

    private func flushDownloadOutputBatch() {
        guard !pendingDownloadOutputLines.isEmpty else { return }
        let count = min(
            pendingDownloadOutputLines.count,
            Self.downloadOutputBatchSize
        )
        let lines = Array(pendingDownloadOutputLines.prefix(count))
        pendingDownloadOutputLines.removeFirst(count)
        for line in lines {
            handleDownloadOutputLine(line)
        }
        scheduleDownloadOutputFlush()
    }

    private func flushAllDownloadOutputLines() {
        downloadOutputFlushScheduled = false
        guard !pendingDownloadOutputLines.isEmpty else { return }
        let lines = pendingDownloadOutputLines
        pendingDownloadOutputLines.removeAll(keepingCapacity: true)
        for line in lines {
            handleDownloadOutputLine(line)
        }
    }

    private func handleDownloadOutputLine(_ rawLine: String) {
        // A pipe callback can already be queued on the main actor when the
        // process exits. Ignore that stale callback after finalization; the
        // termination path deterministically replays the complete transcript.
        guard isDownloading else { return }
        let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        let prefix = "@pikpak-progress:"
        guard line.hasPrefix(prefix) else {
            if !line.isEmpty {
                appendOutput(line + "\n")
            }
            return
        }

        guard let event = decodeDownloadProgressEvent(line, prefix: prefix) else {
            appendOutput("Warning: ignored one malformed download progress update.\n")
            return
        }
        applyDownloadProgressEvent(event)
    }

    private func decodeDownloadProgressEvent(
        _ line: String,
        prefix: String = "@pikpak-progress:"
    ) -> DownloadProgressEvent? {
        guard line.hasPrefix(prefix) else { return nil }
        let json = String(line.dropFirst(prefix.count))
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(DownloadProgressEvent.self, from: Data(json.utf8))
        } catch {
            return nil
        }
    }

    /// Rebuild the final dashboard from the engine's complete ordered stdout.
    /// Live pipe callbacks make the UI responsive, but Process termination and
    /// main-actor delivery can race. Replaying once before finalization ensures
    /// no last progress event, completed row, or byte count is lost.
    private func replayDownloadProgress(from output: String) {
        resetDownloadProgress()
        let prefix = "@pikpak-progress:"
        for rawLine in output.split(whereSeparator: { $0.isNewline }) {
            let line = String(rawLine)
            guard line.hasPrefix(prefix),
                  let event = decodeDownloadProgressEvent(line, prefix: prefix)
            else { continue }
            applyDownloadProgressEvent(event)
        }
    }

    /// Coalesce the uploader's very chatty JSON stream into short main-actor
    /// batches. SwiftUI then performs one render pass for many small-file
    /// completions instead of one pass per line, while each batch remains
    /// short enough for folder navigation and controls to stay responsive.
    private func enqueueUploadOutputLines(_ lines: [String]) {
        guard isUploading, !lines.isEmpty else { return }
        pendingUploadOutputLines.append(contentsOf: lines)
        scheduleUploadOutputFlush()
    }

    private func scheduleUploadOutputFlush() {
        guard !uploadOutputFlushScheduled, !pendingUploadOutputLines.isEmpty else {
            return
        }
        uploadOutputFlushScheduled = true
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.uploadOutputBatchDelay
        ) { [weak self] in
            guard let self, self.uploadOutputFlushScheduled else { return }
            self.uploadOutputFlushScheduled = false
            self.flushUploadOutputBatch()
        }
    }

    private func flushUploadOutputBatch() {
        guard !pendingUploadOutputLines.isEmpty else { return }
        let count = min(
            pendingUploadOutputLines.count,
            Self.uploadOutputBatchSize
        )
        let lines = Array(pendingUploadOutputLines.prefix(count))
        pendingUploadOutputLines.removeFirst(count)
        for line in lines {
            handleUploadOutputLine(line)
        }
        scheduleTransferPersistence()
        scheduleUploadOutputFlush()
    }

    private func flushAllUploadOutputLines() {
        uploadOutputFlushScheduled = false
        let lines = pendingUploadOutputLines
        pendingUploadOutputLines.removeAll(keepingCapacity: true)
        for line in lines {
            handleUploadOutputLine(line)
        }
    }

    private func handleUploadOutputLine(_ rawLine: String) {
        let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        guard line.hasPrefix(uploadProgressPrefix) else {
            if !line.isEmpty {
                appendOutput(line + "\n")
            }
            return
        }

        let json = String(line.dropFirst(uploadProgressPrefix.count))
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let event = try decoder.decode(UploadProgressEvent.self, from: Data(json.utf8))
            applyUploadProgressEvent(event)
        } catch {
            appendOutput("Warning: ignored one malformed upload progress update.\n")
        }
    }

    private func enqueueDuplicateProgressLines(_ lines: [String]) {
        guard isScanningDuplicates, !lines.isEmpty else { return }
        pendingDuplicateProgressLines.append(contentsOf: lines)
        guard !duplicateProgressFlushScheduled else { return }
        duplicateProgressFlushScheduled = true
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.scanProgressBatchDelay
        ) { [weak self] in
            guard let self, self.duplicateProgressFlushScheduled else { return }
            self.duplicateProgressFlushScheduled = false
            self.flushDuplicateProgressBatch()
        }
    }

    private func flushDuplicateProgressBatch() {
        guard !pendingDuplicateProgressLines.isEmpty else { return }
        let count = min(pendingDuplicateProgressLines.count, Self.scanProgressBatchSize)
        let lines = Array(pendingDuplicateProgressLines.prefix(count))
        pendingDuplicateProgressLines.removeFirst(count)
        for line in lines {
            handleDuplicateStderrLine(line)
        }
        if !pendingDuplicateProgressLines.isEmpty {
            duplicateProgressFlushScheduled = true
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.scanProgressBatchDelay
            ) { [weak self] in
                guard let self, self.duplicateProgressFlushScheduled else { return }
                self.duplicateProgressFlushScheduled = false
                self.flushDuplicateProgressBatch()
            }
        }
    }

    private func flushAllDuplicateProgressLines() {
        duplicateProgressFlushScheduled = false
        let lines = pendingDuplicateProgressLines
        pendingDuplicateProgressLines.removeAll(keepingCapacity: true)
        for line in lines {
            handleDuplicateStderrLine(line)
        }
    }

    private func enqueueMaintenanceProgressLines(_ lines: [String]) {
        guard isMaintenanceScanRunning, !lines.isEmpty else { return }
        pendingMaintenanceProgressLines.append(contentsOf: lines)
        guard !maintenanceProgressFlushScheduled else { return }
        maintenanceProgressFlushScheduled = true
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.scanProgressBatchDelay
        ) { [weak self] in
            guard let self, self.maintenanceProgressFlushScheduled else { return }
            self.maintenanceProgressFlushScheduled = false
            self.flushMaintenanceProgressBatch()
        }
    }

    private func flushMaintenanceProgressBatch() {
        guard !pendingMaintenanceProgressLines.isEmpty else { return }
        let count = min(pendingMaintenanceProgressLines.count, Self.scanProgressBatchSize)
        let lines = Array(pendingMaintenanceProgressLines.prefix(count))
        pendingMaintenanceProgressLines.removeFirst(count)
        for line in lines {
            handleEmptyFolderStderrLine(line)
        }
        if !pendingMaintenanceProgressLines.isEmpty {
            maintenanceProgressFlushScheduled = true
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.scanProgressBatchDelay
            ) { [weak self] in
                guard let self, self.maintenanceProgressFlushScheduled else { return }
                self.maintenanceProgressFlushScheduled = false
                self.flushMaintenanceProgressBatch()
            }
        }
    }

    private func flushAllMaintenanceProgressLines() {
        maintenanceProgressFlushScheduled = false
        let lines = pendingMaintenanceProgressLines
        pendingMaintenanceProgressLines.removeAll(keepingCapacity: true)
        for line in lines {
            handleEmptyFolderStderrLine(line)
        }
    }

    private func handleDuplicateStderrLine(_ rawLine: String) {
        let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        guard line.hasPrefix(duplicateProgressPrefix) else {
            if !line.isEmpty {
                appendOutput(redactedEngineOutput(line) + "\n")
            }
            return
        }

        let json = String(line.dropFirst(duplicateProgressPrefix.count))
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let event = try decoder.decode(DuplicateProgressEvent.self, from: Data(json.utf8))
            applyDuplicateProgressEvent(event)
        } catch {
            appendOutput("Warning: ignored one malformed duplicate-scan progress update.\n")
        }
    }

    private func handleEmptyFolderStderrLine(_ rawLine: String) {
        let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
        guard line.hasPrefix(emptyFolderProgressPrefix) else {
            if !line.isEmpty {
                appendOutput(redactedEngineOutput(line) + "\n")
            }
            return
        }

        let json = String(line.dropFirst(emptyFolderProgressPrefix.count))
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let event = try decoder.decode(EmptyFolderProgressEvent.self, from: Data(json.utf8))
            applyEmptyFolderProgressEvent(event)
        } catch {
            appendOutput("Warning: ignored one malformed empty-folder progress update.\n")
        }
    }

    private func applyEmptyFolderProgressEvent(_ event: EmptyFolderProgressEvent) {
        switch event.event {
        case "scan_started":
            emptyFolderScannedFolders = 0
            emptyFolderDiscoveredFolders = max(event.discoveredFolders ?? 1, 1)
            emptyFolderCandidateCount = 0
            emptyFolderCheckedFolders = 0
            emptyFolderRemovedFolders = 0
            emptyFolderSkippedFolders = 0
            emptyFolderCurrentPath = event.rootPath ?? emptyFolderCurrentPath
        case "scan_progress":
            emptyFolderScannedFolders = max(event.scannedFolders ?? 0, 0)
            emptyFolderDiscoveredFolders = max(
                event.discoveredFolders ?? emptyFolderDiscoveredFolders,
                emptyFolderScannedFolders
            )
            emptyFolderCurrentPath = event.currentPath ?? emptyFolderCurrentPath
            if isRemovingEmptyFolders {
                setMaintenanceStatus(
                    "Checking empty folders: \(emptyFolderScannedFolders.formatted()) of \(emptyFolderDiscoveredFolders.formatted()) discovered…"
                )
            }
        case "delete_started":
            emptyFolderCandidateCount = max(event.emptyFolders ?? 0, 0)
            emptyFolderCheckedFolders = 0
            emptyFolderRemovedFolders = 0
            emptyFolderSkippedFolders = 0
            if isRemovingEmptyFolders {
                setMaintenanceStatus(emptyFolderCandidateCount == 0
                    ? "No empty descendant folders found"
                    : "Safety-checking \(emptyFolderCandidateCount.formatted()) empty folder(s) before removal…"
                )
            }
        case "delete_progress":
            emptyFolderCandidateCount = max(
                event.emptyFolders ?? emptyFolderCandidateCount,
                0
            )
            emptyFolderCheckedFolders = max(event.checkedFolders ?? 0, 0)
            emptyFolderRemovedFolders = max(event.removedFolders ?? 0, 0)
            emptyFolderSkippedFolders = max(event.skippedFolders ?? 0, 0)
            emptyFolderCurrentPath = event.currentPath ?? emptyFolderCurrentPath
            if isRemovingEmptyFolders {
                setMaintenanceStatus(
                    "Checked \(emptyFolderCheckedFolders.formatted()) of \(emptyFolderCandidateCount.formatted()); moved \(emptyFolderRemovedFolders.formatted()), kept \(emptyFolderSkippedFolders.formatted())…"
                )
            }
        default:
            break
        }
    }

    private func applyDuplicateProgressEvent(_ event: DuplicateProgressEvent) {
        defer { publishDuplicateActivity() }
        switch event.event {
        case "scan_started":
            duplicateScannedFiles = 0
            duplicateScannedFolders = 0
            duplicateDiscoveredFolders = max(event.discoveredFolders ?? 1, 1)
            duplicatePendingFolders = duplicateDiscoveredFolders
            duplicateFailedFolders = 0
            duplicateRetryAttempt = 0
            duplicateRetryMaxAttempts = 0
            duplicateRetryInMillis = 0
            duplicateCurrentPath = event.rootPath ?? duplicateScanRootPath
        case "scan_progress":
            duplicateScannedFiles = max(event.scannedFiles ?? duplicateScannedFiles, 0)
            duplicateScannedFolders = max(event.scannedFolders ?? duplicateScannedFolders, 0)
            duplicateDiscoveredFolders = max(
                event.discoveredFolders ?? duplicateDiscoveredFolders,
                duplicateScannedFolders
            )
            duplicatePendingFolders = max(event.pendingFolders ?? duplicatePendingFolders, 0)
            duplicateFailedFolders = max(event.failedFolders ?? duplicateFailedFolders, 0)
            duplicateRetryAttempt = 0
            duplicateRetryMaxAttempts = 0
            duplicateRetryInMillis = 0
            duplicateCurrentPath = event.currentPath ?? duplicateCurrentPath
        case "folder_retrying":
            duplicateScannedFiles = max(event.scannedFiles ?? duplicateScannedFiles, 0)
            duplicateScannedFolders = max(event.scannedFolders ?? duplicateScannedFolders, 0)
            duplicateDiscoveredFolders = max(
                event.discoveredFolders ?? duplicateDiscoveredFolders,
                duplicateScannedFolders
            )
            duplicatePendingFolders = max(event.pendingFolders ?? duplicatePendingFolders, 0)
            duplicateFailedFolders = max(event.failedFolders ?? duplicateFailedFolders, 0)
            duplicateRetryAttempt = max(event.attempt ?? 1, 1)
            duplicateRetryMaxAttempts = max(
                event.maxAttempts ?? duplicateRetryAttempt,
                duplicateRetryAttempt
            )
            duplicateRetryInMillis = event.retryInMillis ?? 0
            duplicateCurrentPath = event.currentPath ?? duplicateCurrentPath
        case "folder_skipped":
            duplicateScannedFiles = max(event.scannedFiles ?? duplicateScannedFiles, 0)
            duplicateScannedFolders = max(event.scannedFolders ?? duplicateScannedFolders, 0)
            duplicateDiscoveredFolders = max(
                event.discoveredFolders ?? duplicateDiscoveredFolders,
                duplicateScannedFolders
            )
            duplicatePendingFolders = max(event.pendingFolders ?? duplicatePendingFolders, 0)
            duplicateFailedFolders = max(event.failedFolders ?? duplicateFailedFolders, 0)
            duplicateRetryAttempt = 0
            duplicateRetryMaxAttempts = 0
            duplicateRetryInMillis = 0
            duplicateCurrentPath = event.currentPath ?? duplicateCurrentPath
        default:
            break
        }
    }

    private func applyUploadProgressEvent(_ event: UploadProgressEvent) {
        switch event.event {
        case "discovery_started":
            updateActiveUploadRunState()
            if isUploading && !isRunning {
                setStatus("Scanning the local selection…")
            }

        case "plan":
            activeUploadTransfers = [:]
            queuedUploadIDs = []
            settledUploadIDs = []
            settledUploadBytes = 0
            settledUploadNetworkBytes = 0
            settledUploadHashedBytes = 0
            uploadNetworkTransferredBytes = 0
            uploadHashedBytes = 0
            uploadQueueTransfers = []
            uploadQueueOffset = 0
            uploadingTransfers = []
            completedUploadTransfers = []
            if !preserveUploadFailureHistoryForCurrentRun {
                failedUploadTransfers = []
            }
            preserveUploadFailureHistoryForCurrentRun = false
            uploadTotalFiles = max(event.totalFiles ?? 0, 0)
            uploadTotalBytes = event.totalBytes ?? 0
            uploadUploadedBytes = 0
            uploadCompletedFiles = 0
            uploadInstantFiles = 0
            uploadFailedFiles = 0
            uploadTotalFolders = max(event.totalFolders ?? 0, 0)
            uploadCreatedFolders = 0
            uploadFileWorkers = max(event.fileWorkers ?? 0, 0)
            uploadMultipartWorkers = max(event.multipartWorkers ?? 0, 0)
            uploadSkippedEntries = max(event.skippedEntries ?? 0, 0)
            uploadBytesPerSecond = 0
            uploadHashBytesPerSecond = 0
            if !isUploadPaused {
                uploadRunState = .hashing
            }
            lastUploadSpeedSampleDate = Date()
            lastUploadSpeedSampleBytes = 0
            lastUploadNetworkProgressDate = nil
            lastUploadHashSpeedSampleDate = Date()
            lastUploadHashSpeedSampleBytes = 0
            lastUploadHashProgressDate = nil
            if isUploading && !isRunning {
                if uploadTotalFolders > 0 {
                    setStatus(
                        "Preparing \(uploadTotalFiles.formatted()) file(s) in \(uploadTotalFolders.formatted()) folder(s)…"
                    )
                } else {
                    setStatus("Preparing \(uploadTotalFiles.formatted()) file(s) for upload…")
                }
            }

        case "file_committed":
            if let fileID = event.fileId, let parent = event.parentId {
                recordCreatedUploadItem(id: fileID, parentID: parent, name: event.name, folder: false)
            }
        case "folder_progress":
            if let folderID = event.folderId, let parentID = event.parentId {
                recordCreatedUploadItem(id: folderID, parentID: parentID, name: nil, folder: true)
                // A resumed folder may already contain completed files. Do
                // not assume it is empty or add its size twice.
                folderSizeIndex.parents[folderID] = parentID
                recordFolderSizeChange(in: [parentID, folderID])
            }
            uploadCreatedFolders = max(event.createdFolders ?? uploadCreatedFolders, 0)
            uploadTotalFolders = max(event.totalFolders ?? uploadTotalFolders, uploadCreatedFolders)
            if isUploading && !isRunning {
                let name = event.name ?? "folder"
                setStatus(
                    "Creating cloud folders: \(uploadCreatedFolders.formatted()) of \(uploadTotalFolders.formatted()) • \(name)"
                )
            }

        case "queue_batch":
            let additions = (event.files ?? []).compactMap { file -> UploadTransfer? in
                guard queuedUploadIDs.insert(file.uploadId).inserted else { return nil }
                return UploadTransfer(
                    id: file.uploadId,
                    name: file.name,
                    hashedBytes: 0,
                    uploadedBytes: 0,
                    totalBytes: file.totalBytes,
                    state: .queued,
                    sourcePath: file.sourcePath
                )
            }
            if !additions.isEmpty {
                uploadQueueTransfers.append(contentsOf: additions)
            }

        case "file_hashing", "file_hash_progress":
            guard let uploadID = event.uploadId, let name = event.name else { return }
            guard !settledUploadIDs.contains(uploadID) else { return }
            let previous = activeUploadTransfers[uploadID] ?? dequeueUploadTransfer(uploadID: uploadID)
            let total = event.totalBytes ?? previous?.totalBytes ?? 0
            let hashed = event.hashedBytes ?? previous?.hashedBytes ?? 0
            activeUploadTransfers[uploadID] = UploadTransfer(
                id: uploadID,
                name: name,
                hashedBytes: total > 0 ? min(hashed, total) : hashed,
                uploadedBytes: previous?.uploadedBytes ?? 0,
                totalBytes: total,
                state: .hashing,
                sourcePath: previous?.sourcePath,
                remoteParentID: previous?.remoteParentID
            )
            updateActiveUploadRunState()
            if event.event == "file_hashing", isUploading && !isRunning {
                setStatus("Preparing \(name) for upload…")
            }
            publishUploadProgress()

        case "file_started", "file_progress":
            guard let uploadID = event.uploadId, let name = event.name else { return }
            guard !settledUploadIDs.contains(uploadID) else { return }
            let previous = activeUploadTransfers[uploadID] ?? dequeueUploadTransfer(uploadID: uploadID)
            let total = event.totalBytes ?? previous?.totalBytes ?? 0
            let uploaded = event.uploadedBytes ?? previous?.uploadedBytes ?? 0
            activeUploadTransfers[uploadID] = UploadTransfer(
                id: uploadID,
                name: name,
                hashedBytes: previous?.hashedBytes ?? total,
                uploadedBytes: total > 0 ? min(uploaded, total) : uploaded,
                totalBytes: total,
                state: .uploading,
                sourcePath: previous?.sourcePath,
                remoteParentID: previous?.remoteParentID
            )
            updateActiveUploadRunState()
            if event.event == "file_started", isUploading && !isRunning {
                setStatus("Uploading \(name)…")
            }
            publishUploadProgress()

        case "file_retrying":
            guard let uploadID = event.uploadId, let name = event.name else { return }
            guard !settledUploadIDs.contains(uploadID) else { return }
            let previous = activeUploadTransfers[uploadID] ?? dequeueUploadTransfer(uploadID: uploadID)
            activeUploadTransfers[uploadID] = UploadTransfer(
                id: uploadID,
                name: name,
                hashedBytes: previous?.hashedBytes ?? 0,
                uploadedBytes: previous?.uploadedBytes ?? 0,
                totalBytes: previous?.totalBytes ?? 0,
                state: .retrying(
                    attempt: max(event.attempt ?? 2, 2),
                    maxAttempts: max(event.maxAttempts ?? 3, 2)
                ),
                sourcePath: previous?.sourcePath,
                remoteParentID: previous?.remoteParentID
            )
            if isUploading, !isRunning, let retryMilliseconds = event.retryInMillis {
                let delay = Double(retryMilliseconds) / 1_000
                setStatus(
                    "Retrying \(name) in "
                        + delay.formatted(.number.precision(.fractionLength(1))) + "s…"
                )
            }
            updateActiveUploadRunState()
            publishUploadProgress()

        case "file_completed":
            if let parent = event.parentId, !settledUploadIDs.contains(event.uploadId ?? "") {
                recordFolderSizeChange(in: [parent])
            }
            settleUploadTransfer(event, state: event.instant == true ? .instant : .completed)
        case "file_failed":
            settleUploadTransfer(event, state: .failed)
        default:
            break
        }
    }

    private func settleUploadTransfer(
        _ event: UploadProgressEvent,
        state: UploadTransferState
    ) {
        guard let uploadID = event.uploadId, let name = event.name else { return }
        guard settledUploadIDs.insert(uploadID).inserted else { return }

        let previous = activeUploadTransfers.removeValue(forKey: uploadID)
            ?? dequeueUploadTransfer(uploadID: uploadID)
        let total = event.totalBytes ?? previous?.totalBytes ?? 0
        let uploaded: UInt64
        let hashed: UInt64
        switch state {
        case .instant, .completed:
            uploaded = total
            hashed = total
        case .failed:
            uploaded = previous?.uploadedBytes ?? 0
            hashed = previous?.hashedBytes ?? 0
        case .queued, .hashing, .uploading, .retrying, .stopped:
            uploaded = previous?.uploadedBytes ?? 0
            hashed = previous?.hashedBytes ?? 0
        }
        settledUploadBytes = addingWithoutOverflow(settledUploadBytes, uploaded)
        settledUploadHashedBytes = addingWithoutOverflow(
            settledUploadHashedBytes,
            hashed
        )
        if state != .instant {
            settledUploadNetworkBytes = addingWithoutOverflow(
                settledUploadNetworkBytes,
                uploaded
            )
        }

        switch state {
        case .completed:
            uploadCompletedFiles += 1
        case .instant:
            uploadInstantFiles += 1
        case .failed:
            uploadFailedFiles += 1
        case .queued, .hashing, .uploading, .retrying, .stopped:
            break
        }
        let transfer = UploadTransfer(
            id: uploadID,
            name: name,
            hashedBytes: hashed,
            uploadedBytes: uploaded,
            totalBytes: total,
            state: state,
            sourcePath: event.sourcePath ?? previous?.sourcePath,
            remoteParentID: event.parentId ?? previous?.remoteParentID,
            failureDiagnostic: state == .failed
                ? uploadFailureDiagnostic(from: event.error)
                : nil
        )
        switch state {
        case .failed:
            appendFailedUploadHistory(transfer)
        case .instant, .completed:
            appendCompletedUploadHistory(transfer)
        case .queued, .hashing, .uploading, .retrying, .stopped:
            break
        }
        updateActiveUploadRunState()
        publishUploadProgress()
    }

    private func appendCompletedUploadHistory(_ transfer: UploadTransfer) {
        var history = completedUploadTransfers
        history.append(transfer)
        if history.count > Self.maximumVisibleUploadHistoryRows {
            history.removeFirst(history.count - Self.maximumVisibleUploadHistoryRows)
        }
        completedUploadTransfers = history
    }

    private func appendFailedUploadHistory(_ transfer: UploadTransfer) {
        var history = failedUploadTransfers
        history.append(transfer)
        if history.count > Self.maximumVisibleUploadHistoryRows {
            history.removeFirst(history.count - Self.maximumVisibleUploadHistoryRows)
        }
        failedUploadTransfers = history
    }

    private func dequeueUploadTransfer(uploadID: String) -> UploadTransfer? {
        guard uploadQueueOffset < uploadQueueTransfers.count else { return nil }
        if uploadQueueTransfers[uploadQueueOffset].id == uploadID {
            let transfer = uploadQueueTransfers[uploadQueueOffset]
            uploadQueueOffset += 1
            return transfer
        }
        guard let index = uploadQueueTransfers[uploadQueueOffset...]
            .firstIndex(where: { $0.id == uploadID })
        else { return nil }
        uploadQueueTransfers.swapAt(uploadQueueOffset, index)
        let transfer = uploadQueueTransfers[uploadQueueOffset]
        uploadQueueOffset += 1
        return transfer
    }

    private func publishUploadProgress() {
        let active = activeUploadTransfers.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        uploadingTransfers = active
        let activeBytes = active.reduce(UInt64(0)) {
            addingWithoutOverflow($0, $1.uploadedBytes)
        }
        let currentBytes = addingWithoutOverflow(settledUploadBytes, activeBytes)
        uploadUploadedBytes = uploadTotalBytes > 0
            ? min(currentBytes, uploadTotalBytes)
            : currentBytes

        let activeHashedBytes = active.reduce(UInt64(0)) {
            addingWithoutOverflow($0, $1.hashedBytes)
        }
        let currentHashedBytes = addingWithoutOverflow(
            settledUploadHashedBytes,
            activeHashedBytes
        )
        let boundedHashedBytes = uploadTotalBytes > 0
            ? min(currentHashedBytes, uploadTotalBytes)
            : currentHashedBytes
        if boundedHashedBytes > uploadHashedBytes {
            uploadHashedBytes = boundedHashedBytes
            lastUploadHashProgressDate = Date()
        }

        // Network rate deliberately excludes instant uploads. Those bytes are
        // logically complete but never crossed the network during this run.
        let activeNetworkBytes = active.reduce(UInt64(0)) {
            addingWithoutOverflow($0, $1.uploadedBytes)
        }
        let networkBytes = addingWithoutOverflow(
            settledUploadNetworkBytes,
            activeNetworkBytes
        )
        if networkBytes > uploadNetworkTransferredBytes {
            uploadNetworkTransferredBytes = networkBytes
            lastUploadNetworkProgressDate = Date()
        }
    }

    private func effectiveActiveUploadState() -> UploadRunState {
        if activeUploadTransfers.values.contains(where: { $0.state == .uploading }) {
            return .uploading
        }
        return .hashing
    }

    private func updateActiveUploadRunState() {
        guard isUploading,
              !isUploadPaused,
              uploadRunState != .stopping
        else { return }
        uploadRunState = effectiveActiveUploadState()
    }

    private func resetUploadSpeedBaseline() {
        lastUploadSpeedSampleDate = Date()
        lastUploadSpeedSampleBytes = uploadNetworkTransferredBytes
        lastUploadHashSpeedSampleDate = Date()
        lastUploadHashSpeedSampleBytes = uploadHashedBytes
    }

    private func ensureTransferMetricsTask() {
        guard transferMetricsTask == nil else { return }
        transferMetricsTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 500_000_000)
                } catch {
                    return
                }
                guard !Task.isCancelled, let self else { return }
                self.sampleTransferRates()
                self.stopTransferMetricsTaskIfIdle()
            }
        }
    }

    private func stopTransferMetricsTaskIfIdle() {
        guard !isDownloading, !isUploading else { return }
        transferMetricsTask?.cancel()
        transferMetricsTask = nil
    }

    private func sampleTransferRates() {
        let now = Date()
        sampleDownloadRate(at: now)

        if isUploading, !isUploadPaused, uploadRunState == .uploading {
            let previousDate = lastUploadSpeedSampleDate ?? now
            let interval = now.timeIntervalSince(previousDate)
            if interval >= 0.5 {
                let delta = uploadNetworkTransferredBytes >= lastUploadSpeedSampleBytes
                    ? uploadNetworkTransferredBytes - lastUploadSpeedSampleBytes
                    : 0
                let current = Double(delta) / interval
                if delta > 0 {
                    uploadBytesPerSecond = uploadBytesPerSecond > 0
                        ? uploadBytesPerSecond * 0.65 + current * 0.35
                        : current
                } else if lastUploadNetworkProgressDate.map({
                    now.timeIntervalSince($0) >= 2.0
                }) ?? true {
                    uploadBytesPerSecond = 0
                }
                lastUploadSpeedSampleDate = now
                lastUploadSpeedSampleBytes = uploadNetworkTransferredBytes
            }
        } else {
            uploadBytesPerSecond = 0
            lastUploadSpeedSampleDate = now
            lastUploadSpeedSampleBytes = uploadNetworkTransferredBytes
        }

        if isUploading, !isUploadPaused {
            let previousDate = lastUploadHashSpeedSampleDate ?? now
            let interval = now.timeIntervalSince(previousDate)
            if interval >= 0.5 {
                let delta = uploadHashedBytes >= lastUploadHashSpeedSampleBytes
                    ? uploadHashedBytes - lastUploadHashSpeedSampleBytes
                    : 0
                let current = Double(delta) / interval
                if delta > 0 {
                    uploadHashBytesPerSecond = uploadHashBytesPerSecond > 0
                        ? uploadHashBytesPerSecond * 0.65 + current * 0.35
                        : current
                } else if lastUploadHashProgressDate.map({
                    now.timeIntervalSince($0) >= 2.0
                }) ?? true {
                    uploadHashBytesPerSecond = 0
                }
                lastUploadHashSpeedSampleDate = now
                lastUploadHashSpeedSampleBytes = uploadHashedBytes
            }
        } else {
            uploadHashBytesPerSecond = 0
            lastUploadHashSpeedSampleDate = now
            lastUploadHashSpeedSampleBytes = uploadHashedBytes
        }
    }

    private func sampleDownloadRate(at now: Date) {
        guard isDownloading, downloadRunState == .downloading else {
            downloadBytesPerSecond = 0
            lastDownloadSpeedSampleDate = now
            lastDownloadSpeedSampleBytes = downloadNetworkTransferredBytes
            return
        }

        let previousDate = lastDownloadSpeedSampleDate ?? now
        let interval = now.timeIntervalSince(previousDate)
        guard interval >= 0.35 else { return }

        let delta = downloadNetworkTransferredBytes >= lastDownloadSpeedSampleBytes
            ? downloadNetworkTransferredBytes - lastDownloadSpeedSampleBytes
            : 0
        if delta > 0 {
            let current = Double(delta) / interval
            // A modest moving average keeps the readout readable without
            // allowing a long-lived historical speed to distort the ETA.
            downloadBytesPerSecond = downloadBytesPerSecond > 0
                ? downloadBytesPerSecond * 0.55 + current * 0.45
                : current
        } else if lastDownloadNetworkProgressDate.map({
            now.timeIntervalSince($0) >= 1.5
        }) ?? true {
            downloadBytesPerSecond = 0
        }
        lastDownloadSpeedSampleDate = now
        lastDownloadSpeedSampleBytes = downloadNetworkTransferredBytes
    }

    private func applyDownloadProgressEvent(_ event: DownloadProgressEvent) {
        switch event.event {
        case "plan":
            activeDownloadTransfers = [:]
            queuedDownloadIDs = []
            settledDownloadIDs = []
            settledDownloadBytes = 0
            settledDownloadNetworkBytes = 0
            downloadNetworkBaselines = [:]
            downloadNetworkBytesByID = [:]
            downloadFileTotalsByID = [:]
            downloadNetworkTransferredBytes = 0
            downloadQueueTransfers = []
            downloadQueueOffset = 0
            downloadingTransfers = []
            completedDownloadTransfers = []
            downloadTotalFiles = max(event.totalFiles ?? 0, 0)
            downloadTotalBytes = event.totalBytes ?? 0
            downloadDownloadedBytes = 0
            downloadCompletedFiles = 0
            downloadSkippedFiles = 0
            downloadFailedFiles = 0
            downloadBytesPerSecond = 0
            if isDownloading {
                downloadRunState = downloadTotalFiles > 0 ? .downloading : .completed
            }
            lastDownloadSpeedSampleDate = Date()
            lastDownloadSpeedSampleBytes = 0
            lastDownloadNetworkProgressDate = nil
            if isDownloading, downloadTotalFiles > 0 {
                setStatus("Downloading \(downloadTotalFiles) file(s)…")
            }

        case "queue_batch":
            let additions = (event.files ?? []).compactMap { file -> DownloadTransfer? in
                guard queuedDownloadIDs.insert(file.fileId).inserted else { return nil }
                // The plan already includes this value in its aggregate. Keep
                // the per-file component so an authoritative download URL can
                // correct the aggregate later without double-counting it.
                downloadFileTotalsByID[file.fileId] = file.totalBytes
                if lastDownloadUsedSharedLink, let access = lastSharedDownloadAccess {
                    downloadSharedAccessByFileID[file.fileId] = access
                }
                return DownloadTransfer(
                    id: file.fileId,
                    name: file.name,
                    downloadedBytes: 0,
                    totalBytes: file.totalBytes,
                    state: .queued,
                    remotePath: file.remotePath,
                    outputDirectoryPath: file.outputDirectory,
                    isShared: lastDownloadUsedSharedLink
                )
            }
            if !additions.isEmpty {
                downloadQueueTransfers.append(contentsOf: additions)
            }

        case "file_dequeued":
            guard let fileID = event.fileId, let name = event.name else { return }
            guard !settledDownloadIDs.contains(fileID) else { return }
            let queued = dequeueTransfer(fileID: fileID)
            let reportedTotal = event.totalBytes ?? queued?.totalBytes ?? 0
            reconcileDownloadTotal(reportedTotal, for: fileID)
            activeDownloadTransfers[fileID] = DownloadTransfer(
                id: fileID,
                name: name,
                downloadedBytes: 0,
                totalBytes: reportedTotal,
                state: .preparing,
                remotePath: queued?.remotePath,
                outputDirectoryPath: queued?.outputDirectoryPath,
                isShared: queued?.isShared ?? lastDownloadUsedSharedLink
            )
            if isDownloading {
                downloadRunState = .downloading
            }
            publishDownloadProgress()

        case "file_started", "file_progress":
            guard let fileID = event.fileId, let name = event.name else { return }
            guard !settledDownloadIDs.contains(fileID) else { return }
            let previous = activeDownloadTransfers[fileID] ?? dequeueTransfer(fileID: fileID)
            let downloaded = event.downloadedBytes ?? previous?.downloadedBytes ?? 0
            let total = event.totalBytes ?? previous?.totalBytes ?? 0
            reconcileDownloadTotal(total, for: fileID)
            if event.event == "file_started", downloadNetworkBaselines[fileID] == nil {
                // A resumed .part file contributes to logical completion, but
                // it was not downloaded during this run and must not inflate
                // the current network speed.
                downloadNetworkBaselines[fileID] = downloaded
            }
            if let transferred = event.transferredBytes {
                downloadNetworkBytesByID[fileID] = max(
                    downloadNetworkBytesByID[fileID] ?? 0,
                    transferred
                )
            }
            activeDownloadTransfers[fileID] = DownloadTransfer(
                id: fileID,
                name: name,
                downloadedBytes: total > 0 ? min(downloaded, total) : downloaded,
                totalBytes: total,
                state: .downloading,
                remotePath: previous?.remotePath,
                outputDirectoryPath: previous?.outputDirectoryPath,
                isShared: previous?.isShared ?? lastDownloadUsedSharedLink
            )
            if isDownloading {
                downloadRunState = .downloading
            }
            publishDownloadProgress()

        case "file_retrying":
            guard let fileID = event.fileId, let name = event.name else { return }
            guard !settledDownloadIDs.contains(fileID) else { return }
            let previous = activeDownloadTransfers[fileID]
            if let total = event.totalBytes {
                reconcileDownloadTotal(total, for: fileID)
            }
            if let transferred = event.transferredBytes {
                downloadNetworkBytesByID[fileID] = max(
                    downloadNetworkBytesByID[fileID] ?? 0,
                    transferred
                )
            }
            activeDownloadTransfers[fileID] = DownloadTransfer(
                id: fileID,
                name: name,
                downloadedBytes: previous?.downloadedBytes ?? 0,
                totalBytes: previous?.totalBytes ?? 0,
                state: .retrying(attempt: event.attempt ?? 1),
                remotePath: previous?.remotePath,
                outputDirectoryPath: previous?.outputDirectoryPath,
                isShared: previous?.isShared ?? lastDownloadUsedSharedLink
            )
            if isDownloading, let retryMilliseconds = event.retryInMillis {
                let delay = Double(retryMilliseconds) / 1_000
                setStatus("Retrying a transfer in \(delay.formatted(.number.precision(.fractionLength(1))))s…")
            }
            publishDownloadProgress()

        case "file_completed":
            settleDownloadTransfer(event, state: .completed)
        case "file_skipped":
            settleDownloadTransfer(event, state: .skipped)
        case "file_failed":
            settleDownloadTransfer(event, state: .failed)
        default:
            break
        }
    }

    /// Replace one file's planned size with the authoritative size returned by
    /// the download endpoint. PikPak list metadata can lag behind the signed
    /// download response, so leaving the original aggregate untouched makes
    /// the overall percentage and remaining-byte value disagree with rows.
    private func reconcileDownloadTotal(_ total: UInt64, for fileID: String) {
        guard total > 0 else {
            if downloadFileTotalsByID[fileID] == nil {
                downloadFileTotalsByID[fileID] = 0
            }
            return
        }
        guard let previous = downloadFileTotalsByID[fileID] else {
            // A Plan event already supplied the aggregate. With no mapped
            // component there is no safe delta to apply, so remember the
            // observed value without adding it twice.
            downloadFileTotalsByID[fileID] = total
            return
        }
        guard previous != total else { return }

        downloadFileTotalsByID[fileID] = total
        if total > previous {
            downloadTotalBytes = addingWithoutOverflow(
                downloadTotalBytes,
                total - previous
            )
        } else {
            downloadTotalBytes = downloadTotalBytes >= previous - total
                ? downloadTotalBytes - (previous - total)
                : 0
        }
    }

    private func settleDownloadTransfer(
        _ event: DownloadProgressEvent,
        state: DownloadTransferState
    ) {
        guard let fileID = event.fileId, let name = event.name else { return }
        guard settledDownloadIDs.insert(fileID).inserted else { return }

        let previous = activeDownloadTransfers.removeValue(forKey: fileID)
        let networkBaseline = downloadNetworkBaselines.removeValue(forKey: fileID) ?? 0
        // A failure wrapper may only know the older browser-list size. Once a
        // started transfer supplied an authoritative total, preserve it.
        let total = state == .failed
            ? (previous?.totalBytes ?? event.totalBytes ?? 0)
            : (event.totalBytes ?? previous?.totalBytes ?? 0)
        reconcileDownloadTotal(total, for: fileID)
        if let transferred = event.transferredBytes {
            downloadNetworkBytesByID[fileID] = max(
                downloadNetworkBytesByID[fileID] ?? 0,
                transferred
            )
        }
        let reportedDownloaded = event.downloadedBytes ?? 0
        let downloaded: UInt64
        switch state {
        case .completed, .skipped:
            downloaded = total
        case .failed:
            downloaded = max(previous?.downloadedBytes ?? 0, reportedDownloaded)
        case .queued, .preparing, .downloading, .retrying, .stopped:
            downloaded = max(previous?.downloadedBytes ?? 0, reportedDownloaded)
        }
        settledDownloadBytes = addingWithoutOverflow(settledDownloadBytes, downloaded)
        let measuredNetworkBytes = downloadNetworkBytesByID.removeValue(forKey: fileID)
        let networkBytes: UInt64
        if state == .skipped {
            networkBytes = 0
        } else if let measured = measuredNetworkBytes {
            networkBytes = measured
        } else {
            // Backward-compatible fallback for an older bundled engine.
            networkBytes = downloaded >= networkBaseline
                ? downloaded - networkBaseline
                : 0
        }
        settledDownloadNetworkBytes = addingWithoutOverflow(
            settledDownloadNetworkBytes,
            networkBytes
        )

        switch state {
        case .completed:
            downloadCompletedFiles += 1
        case .skipped:
            downloadSkippedFiles += 1
        case .failed:
            downloadFailedFiles += 1
        case .queued, .preparing, .downloading, .retrying, .stopped:
            break
        }

        let settledTransfer = DownloadTransfer(
            id: fileID,
            name: name,
            downloadedBytes: downloaded,
            totalBytes: total,
            state: state,
            remotePath: previous?.remotePath,
            outputDirectoryPath: previous?.outputDirectoryPath,
            isShared: previous?.isShared ?? lastDownloadUsedSharedLink
        )
        completedDownloadTransfers.append(settledTransfer)
        if state == .failed || state == .stopped {
            appendFailedDownloadHistory(settledTransfer)
        } else if state == .completed || state == .skipped {
            removeFailedDownloadFromHistory(settledTransfer)
        }
        publishDownloadProgress()
    }

    private func appendFailedDownloadHistory(_ transfer: DownloadTransfer) {
        var history = failedDownloadTransfers
        history.removeAll { sameDownloadRetryTarget($0, transfer) }
        history.append(transfer)
        failedDownloadTransfers = history
    }

    private func removeFailedDownloadFromHistory(_ transfer: DownloadTransfer) {
        failedDownloadTransfers.removeAll { sameDownloadRetryTarget($0, transfer) }
    }

    private func sameDownloadRetryTarget(
        _ left: DownloadTransfer,
        _ right: DownloadTransfer
    ) -> Bool {
        left.id == right.id
            && left.isShared == right.isShared
            && left.remotePath == right.remotePath
            && left.outputDirectoryPath == right.outputDirectoryPath
    }

    private func dequeueTransfer(fileID: String) -> DownloadTransfer? {
        guard downloadQueueOffset < downloadQueueTransfers.count else { return nil }

        if downloadQueueTransfers[downloadQueueOffset].id == fileID {
            let transfer = downloadQueueTransfers[downloadQueueOffset]
            downloadQueueOffset += 1
            return transfer
        }

        guard let index = downloadQueueTransfers[downloadQueueOffset...]
            .firstIndex(where: { $0.id == fileID })
        else { return nil }
        downloadQueueTransfers.swapAt(downloadQueueOffset, index)
        let transfer = downloadQueueTransfers[downloadQueueOffset]
        downloadQueueOffset += 1
        return transfer
    }

    private func publishDownloadProgress() {
        let active = activeDownloadTransfers.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
        downloadingTransfers = active

        let activeBytes = active.reduce(UInt64(0)) {
            addingWithoutOverflow($0, $1.downloadedBytes)
        }
        let currentBytes = addingWithoutOverflow(settledDownloadBytes, activeBytes)
        downloadDownloadedBytes = downloadTotalBytes > 0
            ? min(currentBytes, downloadTotalBytes)
            : currentBytes

        let activeNetworkBytes = active.reduce(UInt64(0)) { total, transfer in
            let bytes: UInt64
            if let measured = downloadNetworkBytesByID[transfer.id] {
                bytes = measured
            } else {
                // Compatibility with progress emitted by older engines.
                let baseline = downloadNetworkBaselines[transfer.id] ?? 0
                bytes = transfer.downloadedBytes >= baseline
                    ? transfer.downloadedBytes - baseline
                    : 0
            }
            return addingWithoutOverflow(total, bytes)
        }
        let networkBytes = addingWithoutOverflow(
            settledDownloadNetworkBytes,
            activeNetworkBytes
        )
        if networkBytes > downloadNetworkTransferredBytes {
            downloadNetworkTransferredBytes = networkBytes
            lastDownloadNetworkProgressDate = Date()
        }
        sampleDownloadRate(at: Date())
    }

    private func finishDownloadProgress(as state: DownloadRunState) {
        downloadRunState = state
        downloadBytesPerSecond = 0
        lastDownloadSpeedSampleDate = nil

        if state == .stopped || state == .failed {
            let transferState: DownloadTransferState = state == .stopped ? .stopped : .failed
            let unfinished = activeDownloadTransfers.values.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            for var transfer in unfinished where settledDownloadIDs.insert(transfer.id).inserted {
                transfer.state = transferState
                settledDownloadBytes = addingWithoutOverflow(
                    settledDownloadBytes,
                    transfer.downloadedBytes
                )
                let baseline = downloadNetworkBaselines.removeValue(forKey: transfer.id) ?? 0
                let networkBytes = downloadNetworkBytesByID.removeValue(forKey: transfer.id)
                    ?? (transfer.downloadedBytes >= baseline
                        ? transfer.downloadedBytes - baseline
                        : 0)
                settledDownloadNetworkBytes = addingWithoutOverflow(
                    settledDownloadNetworkBytes,
                    networkBytes
                )
                if state == .failed {
                    downloadFailedFiles += 1
                }
                completedDownloadTransfers.append(transfer)
                appendFailedDownloadHistory(transfer)
            }
            activeDownloadTransfers = [:]
        }
        publishDownloadProgress()
        downloadBytesPerSecond = 0
    }

    private func finishUploadProgress(as state: UploadRunState) {
        uploadRunState = state
        uploadBytesPerSecond = 0
        uploadHashBytesPerSecond = 0
        lastUploadSpeedSampleDate = nil
        lastUploadHashSpeedSampleDate = nil

        if state == .stopped || state == .failed {
            let transferState: UploadTransferState = state == .stopped ? .stopped : .failed
            let unfinished = activeUploadTransfers.values.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            }
            for var transfer in unfinished where settledUploadIDs.insert(transfer.id).inserted {
                transfer.state = transferState
                settledUploadBytes = addingWithoutOverflow(
                    settledUploadBytes,
                    transfer.uploadedBytes
                )
                settledUploadNetworkBytes = addingWithoutOverflow(
                    settledUploadNetworkBytes,
                    transfer.uploadedBytes
                )
                settledUploadHashedBytes = addingWithoutOverflow(
                    settledUploadHashedBytes,
                    transfer.hashedBytes
                )
                if state == .failed {
                    uploadFailedFiles += 1
                    transfer.failureDiagnostic = uploadFailureDiagnostic(from: nil)
                    appendFailedUploadHistory(transfer)
                }
            }
            activeUploadTransfers = [:]
        }
        publishUploadProgress()
        uploadBytesPerSecond = 0
        uploadHashBytesPerSecond = 0
    }

    private func uploadFailureDiagnostic(from rawError: String?) -> AppErrorDiagnostic {
        let rawMessage = rawError?.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = rawMessage.flatMap { $0.isEmpty ? nil : $0 }
            .map { sanitizedDiagnosticText($0, maximumLength: 500) }
            ?? "The upload process stopped before this file completed."
        let lowered = message.lowercased()
        let code: String
        if let statusRange = message.range(
            of: #"(?i)\bHTTP\s+\d{3}\b"#,
            options: .regularExpression
        ), let status = message[statusRange].split(separator: " ").last {
            code = "HTTP_\(status)"
        } else if lowered.contains("tls") && lowered.contains("close_notify") {
            code = "TLS_PEER_CLOSED"
        } else if lowered.contains("timed out") || lowered.contains("timeout") {
            code = "NETWORK_TIMEOUT"
        } else if lowered.contains("connection") {
            code = "NETWORK_CONNECTION_FAILED"
        } else {
            code = "UPLOAD_FILE_FAILED"
        }
        return AppErrorDiagnostic(
            source: lowered.contains("upload storage")
                ? "PikPak upload storage"
                : "PikPak upload",
            code: code,
            message: message,
            context: "The local source was not deleted. Select it again to retry."
        )
    }

    private func addingWithoutOverflow(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? UInt64.max : sum
    }

    private func finishBrowse(
        output: String,
        stack: [BrowserLocation],
        append: Bool,
        includesQuota: Bool,
        preservesOutline: Bool
    ) {
        let sizeRevision = foregroundSizeRevision
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let page = try decoder.decode(BrowserPage.self, from: Data(output.utf8))
            if let accountID = page.accountId {
                if let expected = activeSavedAccount?.profile?.sub, expected != accountID {
                    throw PikPakAccountError.accountMismatch
                }
                adoptTransferAccount(accountID)
                adoptFolderMeasurementCache(for: accountID)
                let profile = page.accountProfile.flatMap { $0.sub == accountID ? $0 : nil }
                    ?? PikPakAccountProfile(sub: accountID, name: activeSavedAccount?.profile?.name)
                rememberVerifiedAccount(profile)
            }
            if let quota = page.quota {
                storageQuota = quota
                storageQuotaError = nil
            } else if includesQuota {
                storageQuotaError = "Storage capacity is temporarily unavailable. Click to retry."
            }
            guard let location = stack.last else {
                setError("PikPak returned a folder without a browser location.")
                return
            }
            if append {
                let existingIDs = Set(browserItems.map(\.id))
                let newItems = page.files.filter { !existingIDs.contains($0.id) }
                browserItems.append(contentsOf: newItems)
                registerBrowserItems(
                    newItems,
                    parentID: location.id,
                    parentPath: location.path
                )
            } else {
                browserItems = page.files
                browserStack = stack
                if !preservesOutline {
                    resetBrowserTreeState()
                }
                registerBrowserItems(
                    page.files,
                    parentID: location.id,
                    parentPath: location.path
                )
                if !preservesOutline {
                    clearBrowserSelection()
                }
            }
            applyBrowserSortToCachedItems()
            nextPageToken = page.nextPageToken
            if !append { sizeListingRevisions[location.id] = sizeRevision }
            if page.nextPageToken?.isEmpty != false, !isUploading, !isMergingFolders,
               sizeRevision == folderSizeRevision, sizeListingRevisions[location.id] == sizeRevision {
                reconcileAccountFolderSize(location.id, items: browserItems)
            }
            let suffix = page.nextPageToken == nil ? "" : " (more available)"
            setStatus("Loaded \(browserItems.count) item(s)\(suffix)")
        } catch {
            appendOutput("Could not decode folder data: \(error.localizedDescription)\n")
            setError("PikPak returned folder data this app could not read.")
        }
    }

    private func finishShareBrowse(
        output: String,
        stack: [BrowserLocation],
        append: Bool,
        initial: Bool
    ) {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let page = try decoder.decode(ShareBrowsePage.self, from: Data(output.utf8))
            updateShareAccess(passCodeToken: page.passCodeToken)
            let effectiveStack: [BrowserLocation]
            if initial {
                let name = page.folderName.trimmingCharacters(in: .whitespacesAndNewlines)
                effectiveStack = [
                    BrowserLocation(
                        id: page.parentId,
                        name: name.isEmpty ? "Shared Link" : name,
                        path: "/"
                    )
                ]
            } else {
                effectiveStack = stack
            }
            guard let location = effectiveStack.last else {
                setError("PikPak returned a shared folder without a browser location.")
                return
            }
            if append {
                let existingIDs = Set(browserItems.map(\.id))
                let newItems = page.files.filter { !existingIDs.contains($0.id) }
                browserItems.append(contentsOf: newItems)
                registerBrowserItems(
                    newItems,
                    parentID: location.id,
                    parentPath: location.path
                )
            } else {
                browserItems = page.files
                browserStack = effectiveStack
                resetBrowserTreeState()
                registerBrowserItems(
                    page.files,
                    parentID: location.id,
                    parentPath: location.path
                )
                clearBrowserSelection()
            }
            applyBrowserSortToCachedItems()
            nextPageToken = page.nextPageToken
            shareLinkIsOpen = true
            if initial, let activeSharedLinkID {
                updateSharedLink(activeSharedLinkID) { entry in
                    let name = page.folderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    entry.name = name.isEmpty ? "Shared Link" : name
                    entry.state = .ready
                }
            }
            let suffix = page.nextPageToken == nil ? "" : " (more available)"
            setShareLinkFeedback(
                "Link opened successfully with your app session. Select files or folders to download or save to My PikPak.",
                tone: .success
            )
            setStatus("Loaded \(browserItems.count) shared item(s)\(suffix)")
            saveActiveBrowserWorkspace()
        } catch {
            appendOutput("Could not decode shared folder data: \(error.localizedDescription)\n")
            if initial {
                markActiveSharedLinkFailed(error.localizedDescription)
            }
            setShareLinkFeedback(
                "Could not open this link because PikPak returned unreadable folder data.",
                tone: .error
            )
            setError("PikPak returned shared-folder data this app could not read.")
        }
    }

    private func finishShareSave(
        output: String,
        requestedIDs: [String],
        linkID: UUID
    ) {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let result = try decoder.decode(ShareSaveResult.self, from: Data(output.utf8))
            let count = max(result.savedCount, requestedIDs.count)
            let noun = count == 1 ? "item" : "items"
            if activeSharedLinkID == linkID {
                setShareLinkFeedback(
                    "Saved \(count.formatted()) \(noun) to Pack From Shared in your PikPak.",
                    tone: .success
                )
            }
            setStatus("Shared selection saved to PikPak")
            let knownSharedParents = (accountBrowserWorkspace?.items ?? [])
                .filter { $0.isFolder && $0.name == "Pack From Shared" }.map(\.id)
            let changedParents = Set(result.cacheParentIds ?? knownSharedParents)
            for parent in changedParents { folderSizeIndex.parents[parent] = "" }
            if !changedParents.isEmpty { recordFolderSizeChange(in: changedParents) }
            accountBrowserWorkspace = nil
            attemptedInitialBrowse = false
            quotaRefreshPending = true
            if var session = sharedLinkSessions[linkID] {
                session.savedItemIDs.formUnion(requestedIDs)
                sharedLinkSessions[linkID] = session
                updateSharedLink(linkID) { entry in
                    entry.savedItemCount = session.savedItemIDs.count
                }
            }
        } catch {
            appendOutput("Could not decode shared save result: \(error.localizedDescription)\n")
            if activeSharedLinkID == linkID {
                setShareLinkFeedback(
                    "PikPak accepted the request but returned an unreadable save result. Refresh Browser to check Pack From Shared.",
                    tone: .error
                )
            }
            setError("PikPak returned a save result this app could not read.")
        }
    }

    private func finishShareBrowserTreeBrowse(
        output: String,
        folderID: String,
        folderName: String,
        folderPath: String,
        append: Bool
    ) {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let page = try decoder.decode(ShareBrowsePage.self, from: Data(output.utf8))
            updateShareAccess(passCodeToken: page.passCodeToken)
            let displayedItems: [BrowserItem]
            if append {
                let existingItems = browserTreeChildren[folderID] ?? []
                let existingIDs = Set(existingItems.map(\.id))
                let newItems = page.files.filter { !existingIDs.contains($0.id) }
                displayedItems = existingItems + newItems
                registerBrowserItems(newItems, parentID: folderID, parentPath: folderPath)
            } else {
                displayedItems = page.files
                registerBrowserItems(page.files, parentID: folderID, parentPath: folderPath)
            }
            browserTreeChildren[folderID] = sortedBrowserItems(displayedItems)

            if let token = page.nextPageToken, !token.isEmpty {
                browserTreeNextPageTokens[folderID] = token
            } else {
                browserTreeNextPageTokens.removeValue(forKey: folderID)
            }
            browserTreeLoadErrors.removeValue(forKey: folderID)
            let suffix = page.nextPageToken?.isEmpty == false ? " (more available)" : ""
            setStatus(
                displayedItems.isEmpty
                    ? "\(folderName) is empty"
                    : "Expanded \(folderName): \(displayedItems.count.formatted()) shared item(s)\(suffix)"
            )
            saveActiveBrowserWorkspace()
        } catch {
            browserTreeLoadErrors[folderID] =
                "PikPak returned shared-folder data this app could not read."
            saveActiveBrowserWorkspace()
            appendOutput("Could not decode shared folder tree data: \(error.localizedDescription)\n")
            setError("PikPak returned shared-folder data this app could not read.")
        }
    }

    private func updateShareAccess(passCodeToken: String) {
        guard let current = shareAccess else { return }
        let updated = ShareAccessInput(
            url: current.url,
            passCode: current.passCode,
            passCodeToken: passCodeToken
        )
        shareAccess = updated
        if let activeSharedLinkID,
           var session = sharedLinkSessions[activeSharedLinkID] {
            session.access = updated
            sharedLinkSessions[activeSharedLinkID] = session
            persistSharedLinkState()
        }
    }

    private func markActiveSharedLinkFailed(_ message: String) {
        guard let activeSharedLinkID else { return }
        markSharedLinkFailed(activeSharedLinkID, message: message)
    }

    private func markSharedLinkFailed(_ linkID: UUID, message: String) {
        updateSharedLink(linkID) { entry in
            entry.state = .failed(message)
        }
        if activeSharedLinkID == linkID {
            shareLinkIsOpen = false
        }
    }

    private func finishBrowserTreeBrowse(
        output: String,
        folderID: String,
        folderName: String,
        folderPath: String,
        append: Bool,
        sizeRevision: UInt64? = nil
    ) {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let page = try decoder.decode(BrowserPage.self, from: Data(output.utf8))
            let revision = sizeRevision ?? foregroundSizeRevision
            let newerMoves = browserMoveCorrections.filter { $0.value.revision > revision }
            var files = page.files.filter { file in
                newerMoves[file.id].map { $0.destination.id == folderID } ?? true
            }
            let listedIDs = Set(files.map(\.id))
            files.append(contentsOf: newerMoves.values.compactMap { move in
                move.destination.id == folderID && !listedIDs.contains(move.item.id) ? move.item : nil
            })
            // The folder (or an ancestor) can itself have moved during this
            // request; use its current path when indexing loaded descendants.
            let currentPath = browserItemPaths[folderID] ?? folderPath
            let displayedItems: [BrowserItem]
            if append {
                let existingItems = browserTreeChildren[folderID] ?? []
                let existingIDs = Set(existingItems.map(\.id))
                let newItems = files.filter { !existingIDs.contains($0.id) }
                displayedItems = existingItems + newItems
                registerBrowserItems(newItems, parentID: folderID, parentPath: currentPath)
            } else {
                displayedItems = files
                registerBrowserItems(files, parentID: folderID, parentPath: currentPath)
            }
            browserTreeChildren[folderID] = sortedBrowserItems(displayedItems)

            if !append { sizeListingRevisions[folderID] = revision }
            if page.nextPageToken?.isEmpty != false, !isUploading, !isMergingFolders,
               revision == folderSizeRevision, sizeListingRevisions[folderID] == revision {
                reconcileAccountFolderSize(folderID, items: displayedItems)
            }

            if let token = page.nextPageToken, !token.isEmpty {
                browserTreeNextPageTokens[folderID] = token
            } else {
                browserTreeNextPageTokens.removeValue(forKey: folderID)
            }
            browserTreeLoadErrors.removeValue(forKey: folderID)

            let moreSuffix = page.nextPageToken?.isEmpty == false ? " (more available)" : ""
            if displayedItems.isEmpty {
                setStatus("\(folderName) is empty")
            } else {
                setStatus(
                    "Expanded \(folderName): \(displayedItems.count.formatted()) item(s)\(moreSuffix)"
                )
            }
        } catch {
            browserTreeLoadErrors[folderID] = "PikPak returned folder data this app could not read."
            appendOutput("Could not decode folder tree data: \(error.localizedDescription)\n")
            setError("PikPak returned folder data this app could not read.")
        }
    }

    private func finishArchiveInspection(output: String, item: BrowserItem, taskID: UUID) {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let inspection = try decoder.decode(
                ArchiveInspection.self,
                from: Data(output.utf8)
            )
            updateArchiveTask(taskID) {
                $0.inspection = inspection; $0.error = nil
                $0.selectedIndices = inspection.ready ? Set(inspection.entries.map(\.index)) : []
                if inspection.requiredPassword {
                    $0.password = ""; $0.passwordPromptDeferred = false
                }
                if inspection.ready && inspection.entries.isEmpty { $0.password = "" }
            }
            if inspection.ready {
                let count = inspection.entries.count
                setStatus(
                    count == 1
                        ? "Archive ready: 1 top-level item"
                        : "Archive ready: \(count.formatted()) top-level items"
                )
                if archiveTasks.first(where: { $0.id == taskID })?.extractWhenReady == true, count > 0 {
                    let password = archiveTasks.first(where: { $0.id == taskID })?.password ?? ""
                    enqueueArchiveExtraction(taskID, password: password, selectedIndices: Set(inspection.entries.map(\.index)))
                }
            } else if inspection.requiredPassword {
                let detail = inspection.statusText.trimmingCharacters(in: .whitespacesAndNewlines)
                setStatus(detail.isEmpty ? "This archive needs a password" : detail)
                presentNextArchivePasswordRequest()
            } else {
                let detail = inspection.statusText.trimmingCharacters(in: .whitespacesAndNewlines)
                let code = inspection.status.trimmingCharacters(in: .whitespacesAndNewlines)
                let diagnostic = AppErrorDiagnostic(
                    source: "PikPak API",
                    code: code.isEmpty ? "ARCHIVE_NOT_READY" : code,
                    message: detail.isEmpty ? "PikPak could not open this archive." : detail,
                    context: nil
                )
                updateArchiveTask(taskID) { $0.error = diagnostic; $0.password = "" }
                setError("PikPak could not open this archive.", diagnostic: diagnostic)
            }
        } catch {
            let decodeDiagnostic = diagnostic(
                for: error,
                source: "PikPak archive response",
                fallbackCode: "ARCHIVE_RESPONSE_INVALID"
            )
            updateArchiveTask(taskID) { $0.error = decodeDiagnostic; $0.password = "" }
            setError(
                "PikPak returned archive contents this app could not read.",
                diagnostic: decodeDiagnostic
            )
        }
    }

    private func finishPreview(output: String, fileID: String) {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let preview = try decoder.decode(PreviewInfo.self, from: Data(output.utf8))
            guard selectedBrowserItemID == fileID else {
                setStatus("Preview discarded because the selection changed")
                return
            }
            previewInfo = preview
            previewFileID = fileID
            previewPlaybackError = nil
            previewErrorDiagnostic = nil
            previewSources = playbackSources(from: preview)

            guard !previewSources.isEmpty else {
                isPreviewLoading = false
                previewStreamingState = .failed
                previewPlaybackError = "PikPak did not provide a valid secure file link."
                let diagnostic = AppErrorDiagnostic(
                    source: "PikPak preview response",
                    code: "MISSING_PREVIEW_URL",
                    message: "The response contained no usable HTTPS file source.",
                    context: nil
                )
                previewErrorDiagnostic = diagnostic
                clearPendingQuickLook(for: fileID)
                setError(
                    "PikPak did not provide a valid preview link for this file.",
                    diagnostic: diagnostic
                )
                return
            }

            if openPendingQuickLookIfNeeded(for: fileID) {
                isPreviewLoading = false
                return
            }

            if selectedBrowserItem?.mediaKind == .video || selectedBrowserItem?.mediaKind == .audio {
                if prepareCompatibilityPreviewIfNeeded() {
                    return
                }
                loadPreviewSource(at: 0, fileID: fileID, autoplay: false)
                return
            }

            if selectedBrowserItem?.isTextPreviewable == true {
                guard let sourceURL = preferredQuickLookSource()?.contentURL else {
                    isPreviewLoading = false
                    setTextPreviewFailure(
                        summary: "PikPak did not provide a downloadable source for this text file.",
                        diagnostic: AppErrorDiagnostic(
                            source: "PikPak preview response",
                            code: "MISSING_TEXT_URL",
                            message: "The response contained no direct HTTPS text source.",
                            context: nil
                        )
                    )
                    return
                }
                startTextPreviewDownload(
                    sourceURL: sourceURL,
                    fileID: fileID,
                    expectedFileSize: preview.size
                )
                return
            }

            guard preview.contentURL != nil else {
                isPreviewLoading = false
                setError("PikPak returned an invalid preview URL.")
                return
            }
            isPreviewLoading = false
            setStatus("Preview ready")
        } catch {
            isPreviewLoading = false
            clearPendingQuickLook(for: fileID)
            if selectedBrowserItem?.mediaKind == .video || selectedBrowserItem?.mediaKind == .audio {
                previewStreamingState = .failed
                previewPlaybackError = "PikPak returned preview data that this app could not read."
            }
            appendOutput("Could not decode preview data: \(error.localizedDescription)\n")
            let errorDiagnostic = diagnostic(
                for: error,
                source: "Preview response decoder",
                fallbackCode: "INVALID_PREVIEW_RESPONSE"
            )
            previewErrorDiagnostic = errorDiagnostic
            setError(
                "PikPak returned preview data this app could not read.",
                diagnostic: errorDiagnostic
            )
        }
    }

    func reportImagePreviewFailure(_ error: Error, fileID: String, generation: UUID) {
        guard selectedBrowserItemID == fileID, previewFileID == fileID,
              previewLoadGeneration == generation else { return }
        let message = "Could not load the original image. The last available image is kept; try Reload Preview or Quick Look."
        let detail = diagnostic(for: error, source: "Image preview", fallbackCode: "IMAGE_PREVIEW_FAILED")
        previewPlaybackError = message
        previewErrorDiagnostic = detail
        isPreviewLoading = false
        setError(message, diagnostic: detail)
    }

    private func startTextPreviewDownload(
        sourceURL: URL,
        fileID: String,
        expectedFileSize: UInt64
    ) {
        let maximumBytes = 2 * 1_024 * 1_024
        textPreviewLoader?.cancel()
        let generation = UUID()
        textPreviewLoadGeneration = generation
        previewText = nil
        previewTextEncodingName = nil
        previewTextLoadedBytes = 0
        previewTextWasTruncated = false
        previewSourceLabel = "Selectable text"
        isPreviewLoading = true

        var request = URLRequest(url: sourceURL)
        for (field, value) in PreviewTransport.mediaHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        request.setValue("text/plain, text/*;q=0.9, */*;q=0.5", forHTTPHeaderField: "Accept")
        request.setValue("bytes=0-\(maximumBytes - 1)", forHTTPHeaderField: "Range")

        let loader = BoundedTextPreviewLoader(
            request: request,
            configuration: PreviewTransport.configuration(proxyURL: proxyURL),
            maximumBytes: maximumBytes,
            expectedFileSize: expectedFileSize
        ) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self,
                      generation == self.textPreviewLoadGeneration,
                      self.previewFileID == fileID,
                      self.selectedBrowserItemID == fileID else { return }
                self.textPreviewLoader = nil
                self.isPreviewLoading = false

                switch result {
                case .success(let output):
                    guard let decoded = Self.decodeTextPreview(
                        output.data,
                        responseEncodingName: output.responseEncodingName
                    ) else {
                        self.setTextPreviewFailure(
                            summary: "This file does not contain readable plain text.",
                            diagnostic: AppErrorDiagnostic(
                                source: "Text preview decoder",
                                code: "TEXT_ENCODING_UNSUPPORTED",
                                message: "The downloaded bytes could not be decoded as a supported text encoding.",
                                context: "Try Quick Look to open the complete temporary file with a compatible macOS viewer."
                            )
                        )
                        return
                    }

                    self.previewText = decoded.text
                    self.previewTextEncodingName = decoded.encodingName
                    self.previewTextLoadedBytes = UInt64(output.data.count)
                    self.previewTextWasTruncated = output.wasTruncated
                    self.previewSourceLabel = "Selectable text • \(decoded.encodingName)"
                    if output.wasTruncated {
                        self.setStatus("Text preview ready — showing the first 2 MB")
                    } else {
                        self.setStatus("Text preview ready")
                    }

                case .failure(let error):
                    let errorDiagnostic = self.diagnostic(
                        for: error,
                        source: "Text preview download",
                        fallbackCode: "TEXT_PREVIEW_DOWNLOAD_FAILED"
                    )
                    self.setTextPreviewFailure(
                        summary: "The text file could not be loaded for preview.",
                        diagnostic: errorDiagnostic
                    )
                }
            }
        }
        textPreviewLoader = loader
        let route = PreviewTransport.usesProxy(proxyURL) ? " through the app proxy" : ""
        setStatus("Loading a secure text preview\(route)…")
        loader.start()
    }

    private func setTextPreviewFailure(
        summary: String,
        diagnostic: AppErrorDiagnostic
    ) {
        previewText = nil
        previewTextEncodingName = nil
        previewTextLoadedBytes = 0
        previewTextWasTruncated = false
        previewPlaybackError = summary
        previewErrorDiagnostic = diagnostic
        setError(summary, diagnostic: diagnostic)
    }

    private func openPendingQuickLookIfNeeded(for fileID: String) -> Bool {
        guard pendingQuickLookFileID == fileID, quickLookTargetIsCurrent,
              let item = quickLookTargetItem, item.id == fileID,
              let source = preferredQuickLookSource()?.contentURL else { return false }
        beginQuickLookDownload(sourceURL: source, item: item)
        return true
    }

    private func clearPendingQuickLook(for fileID: String) {
        guard pendingQuickLookFileID == fileID else { return }
        pendingQuickLookFileID = nil
        isPreparingQuickLook = false
        quickLookPreviewCoordinator.showFailure("Could not prepare this file for preview. Try again.")
    }

    private nonisolated static func decodeTextPreview(
        _ data: Data,
        responseEncodingName: String?
    ) -> (text: String, encodingName: String)? {
        guard !data.isEmpty else { return ("", "UTF-8") }

        var candidates: [(String.Encoding, String)] = []
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            candidates.append((.utf8, "UTF-8"))
        } else if data.starts(with: [0xFF, 0xFE]) {
            candidates.append((.utf16LittleEndian, "UTF-16 LE"))
        } else if data.starts(with: [0xFE, 0xFF]) {
            candidates.append((.utf16BigEndian, "UTF-16 BE"))
        }

        if let responseEncodingName,
           let responseEncoding = textEncoding(named: responseEncodingName) {
            candidates.append(responseEncoding)
        }

        let sample = data.prefix(4_096)
        if sample.count >= 4 {
            var evenZeroes = 0
            var oddZeroes = 0
            for (index, byte) in sample.enumerated() where byte == 0 {
                if index.isMultiple(of: 2) {
                    evenZeroes += 1
                } else {
                    oddZeroes += 1
                }
            }
            if oddZeroes > max(sample.count / 10, 2) && evenZeroes <= oddZeroes / 4 {
                candidates.append((.utf16LittleEndian, "UTF-16 LE"))
            } else if evenZeroes > max(sample.count / 10, 2) && oddZeroes <= evenZeroes / 4 {
                candidates.append((.utf16BigEndian, "UTF-16 BE"))
            }
        }

        candidates.append(contentsOf: [
            (.utf8, "UTF-8"),
            (.windowsCP1252, "Windows-1252"),
            (.isoLatin1, "ISO-8859-1"),
        ])

        var tried = Set<UInt>()
        for (encoding, name) in candidates where tried.insert(encoding.rawValue).inserted {
            guard var text = String(data: data, encoding: encoding),
                  looksLikePlainText(text) else { continue }
            if text.first == "\u{FEFF}" {
                text.removeFirst()
            }
            return (text, name)
        }
        return nil
    }

    private nonisolated static func textEncoding(
        named rawName: String
    ) -> (String.Encoding, String)? {
        let name = rawName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "_", with: "-")
        switch name {
        case "utf-8", "utf8": return (.utf8, "UTF-8")
        case "utf-16", "utf16": return (.utf16, "UTF-16")
        case "utf-16le": return (.utf16LittleEndian, "UTF-16 LE")
        case "utf-16be": return (.utf16BigEndian, "UTF-16 BE")
        case "us-ascii", "ascii": return (.ascii, "ASCII")
        case "windows-1252", "cp1252": return (.windowsCP1252, "Windows-1252")
        case "iso-8859-1", "latin1", "latin-1": return (.isoLatin1, "ISO-8859-1")
        default: return nil
        }
    }

    private nonisolated static func looksLikePlainText(_ text: String) -> Bool {
        var inspected = 0
        var unsupportedControls = 0
        for scalar in text.unicodeScalars.prefix(40_000) {
            inspected += 1
            switch scalar.value {
            case 0x09, 0x0A, 0x0C, 0x0D:
                continue
            case 0x00 ..< 0x20, 0x7F:
                unsupportedControls += 1
            default:
                continue
            }
        }
        guard inspected > 0 else { return true }
        return unsupportedControls <= max(2, inspected / 100)
    }

    private func playbackSources(from preview: PreviewInfo) -> [PreviewSource] {
        var candidates = preview.sources ?? []
        if let contentURL = preview.contentURL,
           !candidates.contains(where: { $0.contentURL == contentURL }) {
            candidates.append(
                PreviewSource(
                    url: contentURL.absoluteString,
                    label: "Preferred stream",
                    isOrigin: false,
                    videoCodec: nil,
                    audioCodec: nil
                )
            )
        }

        var seen = Set<String>()
        let unique = candidates.filter { source in
            guard let url = source.contentURL else { return false }
            return seen.insert(url.absoluteString).inserted
        }
        guard selectedBrowserItem?.mediaKind == .video else { return unique }

        // Prefer PikPak's macOS-friendly transcodes. Original AVI/MKV files
        // can contain legacy codecs even when the extension is recognized.
        return unique.enumerated().sorted { lhs, rhs in
            let leftRank = playbackCompatibilityRank(lhs.element)
            let rightRank = playbackCompatibilityRank(rhs.element)
            return leftRank == rightRank ? lhs.offset < rhs.offset : leftRank < rightRank
        }.map(\.element)
    }

    private func playbackCompatibilityRank(_ source: PreviewSource) -> Int {
        let isPlaylist = source.contentURL?.pathExtension.lowercased() == "m3u8"
        let codec = source.videoCodec?.lowercased() ?? ""
        let isNativeCodec = codec.contains("h264") || codec.contains("avc")
            || codec.contains("hevc") || codec.contains("h265")
        if !source.isOrigin, isNativeCodec {
            return isPlaylist ? 1 : 0
        }
        if !source.isOrigin {
            return isPlaylist ? 3 : 2
        }
        return isPlaylist ? 5 : 4
    }

    /// PikPak sometimes exposes only the original AVI rather than an H.264 or
    /// HLS transcode. In that case AVPlayer cannot decode common legacy AVI
    /// codecs such as FMP4/Xvid, so offer the already-installed compatibility
    /// player immediately instead of waiting through repeated native failures.
    private func prepareCompatibilityPreviewIfNeeded() -> Bool {
        guard let item = selectedBrowserItem,
              item.normalizedFileExtension == "avi",
              previewSources.allSatisfy(\.isOrigin),
              previewSources.contains(where: { source in
                  let codec = source.videoCodec?.uppercased() ?? ""
                  return ["FMP4", "XVID", "DIVX", "DX50", "MP4V"].contains(codec)
              }) else {
            return false
        }
        return activateCompatibilityPreview()
    }

    private func activateCompatibilityPreview() -> Bool {
        guard compatibilityPlayerExecutableURL() != nil,
              preferredCompatibilitySource() != nil else { return false }
        previewPlaybackWasRequested = false
        previewPlayer?.pause()
        previewPlayer = nil
        previewRequiresCompatibilityPlayer = true
        previewCompatibilityPlayerName = "IINA"
        previewPlaybackError = nil
        previewErrorDiagnostic = nil
        previewSourceLabel = "Original AVI"
        isPreviewLoading = false
        resetPreviewStreamingMetrics(state: .compatibility)
        setStatus("AVI compatibility preview ready")
        return true
    }

    private func compatibilityPlayerExecutableURL() -> URL? {
        var applicationURLs: [URL] = []
        if let discovered = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: Self.compatibilityPlayerBundleID
        ) {
            applicationURLs.append(discovered)
        }
        applicationURLs.append(URL(fileURLWithPath: "/Applications/IINA.app", isDirectory: true))
        applicationURLs.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications/IINA.app", isDirectory: true)
        )

        for applicationURL in applicationURLs {
            let executable = applicationURL
                .appendingPathComponent("Contents/MacOS/iina-cli", isDirectory: false)
            if FileManager.default.isExecutableFile(atPath: executable.path) {
                return executable
            }
        }
        return nil
    }

    private func preferredCompatibilitySource() -> PreviewSource? {
        previewSources.first(where: { !$0.isOrigin && $0.contentURL != nil })
            ?? previewSources.first(where: { $0.contentURL != nil })
    }

    private func preferredQuickLookSource() -> PreviewSource? {
        // Quick Look needs one complete local media file. An HLS `.m3u8`
        // transcode only downloads its playlist, not its segments, so prefer
        // PikPak's original/direct object and reject playlist sources.
        previewSources.first(where: { source in
            source.isOrigin
                && source.contentURL?.pathExtension.lowercased() != "m3u8"
        })
            ?? previewSources.first(where: { source in
                source.contentURL?.pathExtension.lowercased() != "m3u8"
            })
    }

    private func makePrivateCompatibilityPlaylist(for sourceURL: URL) throws -> URL {
        let filename = Self.compatibilityPreviewFilenamePrefix + UUID().uuidString + ".m3u"
        let playlistURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(filename, isDirectory: false)
        var lines = ["#EXTM3U", "#EXTVLCOPT:http-referrer=https://mypikpak.com/"]
        lines.append(sourceURL.absoluteString)
        lines.append("")
        guard let data = lines.joined(separator: "\n").data(using: .utf8),
              FileManager.default.createFile(
                atPath: playlistURL.path,
                contents: data,
                attributes: [.posixPermissions: NSNumber(value: 0o600)]
              ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return playlistURL
    }

    private func scheduleCompatibilityPlaylistCleanup(_ playlistURL: URL) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 120) {
            try? FileManager.default.removeItem(at: playlistURL)
        }
    }

    private nonisolated static func moveQuickLookDownload(
        from temporaryURL: URL,
        originalName: String
    ) throws -> URL {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory
            .appendingPathComponent("PikPakDownloader-QuickLook", isDirectory: true)
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )
        try manager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: directory.path
        )
        let fileExtension = (originalName as NSString).pathExtension
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
        let destination = directory
            .appendingPathComponent(UUID().uuidString + suffix, isDirectory: false)
        try manager.moveItem(at: temporaryURL, to: destination)
        try manager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o600)],
            ofItemAtPath: destination.path
        )
        return destination
    }

    private nonisolated static func scheduleQuickLookCleanup(_ fileURL: URL) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 6 * 60 * 60) {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    private func previewMIMETypeOverride(
        for source: PreviewSource,
        contentURL: URL
    ) -> String? {
        let extensionName = contentURL.pathExtension.lowercased()
        if extensionName == "m3u8" { return nil }

        if !source.isOrigin {
            switch extensionName {
            case "mp4", "m4v": return "video/mp4"
            case "mov": return "video/quicktime"
            case "m4a": return "audio/mp4"
            default: break
            }
            let videoCodec = source.videoCodec?.lowercased() ?? ""
            if videoCodec.contains("h264") || videoCodec.contains("avc")
                || videoCodec.contains("hevc") || videoCodec.contains("h265") {
                return "video/mp4"
            }
            let audioCodec = source.audioCodec?.lowercased() ?? ""
            if selectedBrowserItem?.mediaKind == .audio,
               audioCodec.contains("aac") {
                return "audio/mp4"
            }
            // Do not stamp an optimized source with the original file's MIME
            // type. Let AVFoundation inspect an otherwise unknown transcode.
            return nil
        }

        return previewInfo?.mimeType?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadPreviewSource(at index: Int, fileID: String, autoplay: Bool) {
        guard selectedBrowserItemID == fileID,
              previewSources.indices.contains(index),
              let contentURL = previewSources[index].contentURL else {
            isPreviewLoading = false
            return
        }

        removePreviewPlayerObservers()
        previewPlayer?.pause()

        let generation = UUID()
        previewLoadGeneration = generation
        previewPlaybackWasRequested = autoplay
        previewSourceIndex = index
        previewPlaybackError = nil
        previewErrorDiagnostic = nil
        previewRequiresCompatibilityPlayer = false
        previewCompatibilityPlayerName = nil
        isPreviewLoading = true
        resetPreviewStreamingMetrics(state: .preparing)

        let source = previewSources[index]
        let sourceName = previewSourceName(source)
        let supportsRetainedTransport = contentURL.pathExtension.lowercased() != "m3u8"
        let resourceCache = supportsRetainedTransport
            ? previewResourceCache(for: source, index: index, fileID: fileID)
            : nil
        let usesManagedTransport = resourceCache != nil
        let proxyLabel = PreviewTransport.usesProxy(proxyURL) ? " • app proxy" : ""
        let transportLabel = usesManagedTransport ? " • retained cache\(proxyLabel)" : proxyLabel
        previewSourceLabel =
            "\(sourceName) • \(index + 1) of \(previewSources.count)\(transportLabel)"

        // PikPak's signed links commonly use a generic `/download/` path and
        // may be served as application/octet-stream. Give AVFoundation the
        // file's real media type and the same browser identity used by the API
        // client so it can recognize and fetch the stream reliably.
        var assetOptions: [String: Any] = [
            AVURLAssetHTTPUserAgentKey: Self.previewUserAgent,
            AVURLAssetPreferPreciseDurationAndTimingKey: false,
            AVURLAssetAllowsConstrainedNetworkAccessKey: true,
            AVURLAssetAllowsExpensiveNetworkAccessKey: true,
        ]
        // Both account and shared-link CDN URLs can enforce PikPak's Web
        // origin/referrer checks. Applying the same harmless media headers to
        // every signed source also fixes shared-link previews that previously
        // returned a thumbnail but stalled when AVFoundation fetched bytes.
        assetOptions["AVURLAssetHTTPHeaderFieldsKey"] = [
            "Referer": "https://mypikpak.com/",
            "Origin": "https://mypikpak.com",
            "Accept": "video/*, audio/*, */*;q=0.8",
        ]
        if #available(macOS 14.0, *),
           let mimeType = previewMIMETypeOverride(for: source, contentURL: contentURL),
           !mimeType.isEmpty {
            assetOptions[AVURLAssetOverrideMIMETypeKey] = mimeType
        }
        let asset: AVURLAsset
        if let resourceCache {
            previewUsesRetainedCache = true
            updatePreviewCacheMetrics(
                resourceCache.snapshot,
                generation: generation,
                fileID: fileID,
                resetsRateSample: true
            )
            let resourceLoader = PreviewResourceLoader(
                originalURL: contentURL,
                proxyURL: proxyURL,
                cache: resourceCache,
                onCacheProgress: { [weak self] snapshot in
                    Task { @MainActor [weak self] in
                        self?.updatePreviewCacheMetrics(
                            snapshot,
                            generation: generation,
                            fileID: fileID
                        )
                    }
                }
            )
            previewResourceLoader = resourceLoader
            asset = AVURLAsset(url: resourceLoader.assetURL, options: assetOptions)
            asset.resourceLoader.setDelegate(
                resourceLoader,
                queue: resourceLoader.delegateQueue
            )
        } else {
            previewResourceLoader = nil
            asset = AVURLAsset(url: contentURL, options: assetOptions)
        }
        let playerItem = AVPlayerItem(asset: asset)
        // Keep network reads eligible while the user pauses playback and ask
        // AVFoundation for a long forward buffer. AVFoundation can still cap
        // this under system resource pressure, but it no longer receives the
        // previous instruction to stop after only four seconds.
        playerItem.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        playerItem.preferredForwardBufferDuration = Self.previewFallbackForwardBufferDuration
        let player = AVPlayer(playerItem: playerItem)
        // Keep the requested playback rate across a temporary buffer shortage.
        // With this disabled AVPlayer converts an exhausted progressive stream
        // to `.paused` and rate 0 instead of waiting and resuming automatically.
        player.automaticallyWaitsToMinimizeStalling = true
        previewPlayer = player
        startPreviewMetricsPolling(
            player: player,
            playerItem: playerItem,
            generation: generation,
            fileID: fileID
        )

        let mediaName = selectedBrowserItem?.mediaKind == .audio ? "audio" : "video"
        setStatus("Loading \(mediaName) preview…")

        playerItemStatusObservation = playerItem.observe(
            \.status,
            options: [.initial, .new]
        ) { [weak self] observedItem, _ in
            let status = observedItem.status
            let error = observedItem.error
            DispatchQueue.main.async {
                self?.handlePreviewPlayerStatus(
                    status,
                    error: error,
                    generation: generation,
                    fileID: fileID,
                    autoplay: autoplay
                )
            }
        }

        playerLoadedTimeRangesObservation = playerItem.observe(
            \.loadedTimeRanges,
            options: [.initial, .new]
        ) { [weak self] observedItem, _ in
            DispatchQueue.main.async {
                self?.updatePreviewStreamingMetrics(
                    from: observedItem,
                    currentTime: player.currentTime(),
                    generation: generation,
                    fileID: fileID
                )
            }
        }

        playerTimeControlStatusObservation = player.observe(
            \.timeControlStatus,
            options: [.initial, .new]
        ) { [weak self] observedPlayer, _ in
            let timeControlStatus = observedPlayer.timeControlStatus
            DispatchQueue.main.async {
                self?.handlePreviewTimeControlStatus(
                    timeControlStatus,
                    generation: generation,
                    fileID: fileID
                )
            }
        }

        playerRateChangeObserver = NotificationCenter.default.addObserver(
            forName: AVPlayer.rateDidChangeNotification,
            object: player,
            queue: .main
        ) { [weak self, weak player] notification in
            DispatchQueue.main.async {
                guard let self, let player else { return }
                self.handlePreviewRateChange(
                    notification,
                    player: player,
                    generation: generation,
                    fileID: fileID
                )
            }
        }

        previewTimeObserverPlayer = player
        previewTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak playerItem] time in
            guard let playerItem else { return }
            DispatchQueue.main.async {
                self?.updatePreviewStreamingMetrics(
                    from: playerItem,
                    currentTime: time,
                    generation: generation,
                    fileID: fileID
                )
            }
        }

        playerFailureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] notification in
            let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            DispatchQueue.main.async {
                self?.tryNextPreviewSource(
                    after: error,
                    generation: generation,
                    fileID: fileID,
                    autoplay: autoplay || player.timeControlStatus == .playing
                )
            }
        }

        playerAccessLogObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemNewAccessLogEntry,
            object: playerItem,
            queue: .main
        ) { [weak self, weak playerItem] _ in
            guard let playerItem else { return }
            DispatchQueue.main.async {
                self?.updatePreviewStreamingMetrics(
                    from: playerItem,
                    currentTime: player.currentTime(),
                    generation: generation,
                    fileID: fileID
                )
            }
        }

        playerEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self,
                      generation == self.previewLoadGeneration,
                      self.previewFileID == fileID else { return }
                self.previewPlaybackWasRequested = false
                self.previewPlaybackRecoveryTask?.cancel()
                self.previewPlaybackRecoveryTask = nil
                self.previewPlaybackSeconds = self.previewDurationSeconds
                self.previewStreamingState = .finished
            }
        }

        playerStallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled,
            object: playerItem,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self,
                      generation == self.previewLoadGeneration,
                      self.previewFileID == fileID else { return }
                self.previewPlaybackWasRequested = true
                self.previewStreamingState = .buffering
            }
        }

        previewLoadTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.previewStartupTimeoutNanoseconds)
            guard !Task.isCancelled, let self else { return }
            self.tryNextPreviewSource(
                after: nil,
                generation: generation,
                fileID: fileID,
                autoplay: autoplay
            )
        }
    }

    private func previewResourceCache(
        for source: PreviewSource,
        index: Int,
        fileID: String
    ) -> PreviewResourceCache? {
        if previewResourceCacheFileID != fileID {
            clearPreviewResourceCaches()
            previewResourceCacheFileID = fileID
        }
        let key = previewResourceCacheKey(for: source, index: index)
        if let cached = previewResourceCaches[key] {
            return cached
        }
        do {
            let cache = try PreviewResourceCache()
            previewResourceCaches[key] = cache
            return cache
        } catch {
            appendOutput(
                "Could not create the retained preview cache: \(error.localizedDescription)\n"
            )
            return nil
        }
    }

    private func previewResourceCacheKey(
        for source: PreviewSource,
        index: Int
    ) -> String {
        let url = source.contentURL
        return [
            String(index),
            source.isOrigin ? "origin" : "transcode",
            source.label ?? "",
            source.videoCodec ?? "",
            source.audioCodec ?? "",
            url?.host ?? "",
            url?.path ?? source.url,
        ].joined(separator: "|")
    }

    private func clearPreviewResourceCaches() {
        let caches = Array(previewResourceCaches.values)
        previewResourceCaches = [:]
        previewResourceCacheFileID = nil
        previewCacheRateSample = nil
        previewLastTransferProgressDate = nil
        for cache in caches {
            cache.removeFromDisk()
        }
    }

    private func handlePreviewPlayerStatus(
        _ playerStatus: AVPlayerItem.Status,
        error: Error?,
        generation: UUID,
        fileID: String,
        autoplay: Bool
    ) {
        guard generation == previewLoadGeneration,
              selectedBrowserItemID == fileID,
              previewFileID == fileID else { return }

        switch playerStatus {
        case .readyToPlay:
            previewLoadTimeoutTask?.cancel()
            previewLoadTimeoutTask = nil
            isPreviewLoading = false
            previewPlaybackError = nil
            previewErrorDiagnostic = nil
            let shouldStartPlayback = autoplay || previewPlaybackWasRequested
            previewPlaybackWasRequested = shouldStartPlayback
            previewStreamingState = shouldStartPlayback ? .playing : .ready
            if let playerItem = previewPlayer?.currentItem {
                let duration = CMTimeGetSeconds(playerItem.duration)
                if duration.isFinite, duration > 0 {
                    // For finite video/audio, explicitly request buffering all
                    // the way to the end even if playback is paused.
                    playerItem.preferredForwardBufferDuration = duration
                }
                updatePreviewStreamingMetrics(
                    from: playerItem,
                    currentTime: previewPlayer?.currentTime() ?? .zero,
                    generation: generation,
                    fileID: fileID
                )
            }
            let mediaName = selectedBrowserItem?.mediaKind == .audio ? "Audio" : "Video"
            setStatus("\(mediaName) preview ready")
            if shouldStartPlayback {
                previewPlayer?.play()
            }
        case .failed:
            tryNextPreviewSource(
                after: error,
                generation: generation,
                fileID: fileID,
                autoplay: autoplay
            )
        case .unknown:
            break
        @unknown default:
            tryNextPreviewSource(
                after: error,
                generation: generation,
                fileID: fileID,
                autoplay: autoplay
            )
        }
    }

    /// AVPlayer's rate-change notification distinguishes a user/app transport
    /// command from an automatic rate failure or interruption. Remembering that
    /// intent prevents a transient network stall from being mistaken for the
    /// user pressing Pause, while still respecting a real Pause action.
    private func handlePreviewRateChange(
        _ notification: Notification,
        player: AVPlayer,
        generation: UUID,
        fileID: String
    ) {
        guard generation == previewLoadGeneration,
              selectedBrowserItemID == fileID,
              previewFileID == fileID else { return }

        let reasonValue = notification.userInfo?[AVPlayer.rateDidChangeReasonKey]
        let rawReason = (reasonValue as? AVPlayer.RateDidChangeReason)?.rawValue
            ?? (reasonValue as? String)
        if rawReason == AVPlayer.RateDidChangeReason.setRateCalled.rawValue {
            if player.rate > 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
                previewPlaybackWasRequested = true
            } else {
                previewPlaybackWasRequested = false
                previewPlaybackRecoveryTask?.cancel()
                previewPlaybackRecoveryTask = nil
                if previewDurationSeconds > 0,
                   previewPlaybackSeconds >= previewDurationSeconds - 0.25 {
                    previewStreamingState = .finished
                } else if previewPlaybackSeconds > 0.05 {
                    previewStreamingState = .paused
                } else {
                    previewStreamingState = .ready
                }
            }
            return
        }

        if rawReason == AVPlayer.RateDidChangeReason.audioSessionInterrupted.rawValue
            || rawReason == AVPlayer.RateDidChangeReason.appBackgrounded.rawValue {
            previewPlaybackWasRequested = false
            previewPlaybackRecoveryTask?.cancel()
            previewPlaybackRecoveryTask = nil
            return
        }

        if player.rate > 0 || player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            previewPlaybackWasRequested = true
        } else if previewPlaybackWasRequested {
            schedulePreviewPlaybackRecovery(
                player: player,
                generation: generation,
                fileID: fileID
            )
        }
    }

    /// AVPlayer's periodic time observer stops advancing when playback is
    /// paused. Polling the item separately keeps loaded-time-range and network
    /// byte progress visible while AVFoundation continues filling its buffer.
    private func startPreviewMetricsPolling(
        player: AVPlayer,
        playerItem: AVPlayerItem,
        generation: UUID,
        fileID: String
    ) {
        previewMetricsTask?.cancel()
        previewMetricsTask = Task { [weak self, weak player, weak playerItem] in
            while !Task.isCancelled {
                guard let self, let player, let playerItem else { return }
                self.updatePreviewStreamingMetrics(
                    from: playerItem,
                    currentTime: player.currentTime(),
                    generation: generation,
                    fileID: fileID
                )
                do {
                    try await Task.sleep(
                        nanoseconds: Self.previewMetricsIntervalNanoseconds
                    )
                } catch {
                    return
                }
            }
        }
    }

    private func handlePreviewTimeControlStatus(
        _ timeControlStatus: AVPlayer.TimeControlStatus,
        generation: UUID,
        fileID: String
    ) {
        guard generation == previewLoadGeneration,
              selectedBrowserItemID == fileID,
              previewFileID == fileID else { return }

        guard !isPreviewLoading,
              previewPlayer?.currentItem?.status == .readyToPlay else {
            previewStreamingState = .preparing
            return
        }

        switch timeControlStatus {
        case .playing:
            previewPlaybackWasRequested = true
            previewPlaybackRecoveryTask?.cancel()
            previewPlaybackRecoveryTask = nil
            previewStreamingState = .playing
        case .waitingToPlayAtSpecifiedRate:
            previewPlaybackWasRequested = true
            previewPlaybackRecoveryTask?.cancel()
            previewPlaybackRecoveryTask = nil
            previewStreamingState = .buffering
        case .paused:
            if previewDurationSeconds > 0,
               previewPlaybackSeconds >= previewDurationSeconds - 0.25 {
                previewPlaybackWasRequested = false
                previewStreamingState = .finished
            } else if previewPlaybackWasRequested,
                      let player = previewPlayer {
                previewStreamingState = .buffering
                schedulePreviewPlaybackRecovery(
                    player: player,
                    generation: generation,
                    fileID: fileID
                )
            } else if previewPlaybackSeconds > 0.05 {
                previewStreamingState = .paused
            } else {
                previewStreamingState = .ready
            }
        @unknown default:
            previewStreamingState = .ready
        }
    }

    private func schedulePreviewPlaybackRecovery(
        player: AVPlayer,
        generation: UUID,
        fileID: String
    ) {
        guard previewPlaybackWasRequested,
              previewPlaybackRecoveryTask == nil else { return }
        previewPlaybackRecoveryTask = Task { [weak self, weak player] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            guard let self, let player else { return }
            self.previewPlaybackRecoveryTask = nil
            guard generation == self.previewLoadGeneration,
                  self.selectedBrowserItemID == fileID,
                  self.previewFileID == fileID,
                  self.previewPlaybackWasRequested,
                  player.currentItem?.status == .readyToPlay,
                  player.timeControlStatus == .paused else { return }
            player.play()
        }
    }

    private func updatePreviewStreamingMetrics(
        from playerItem: AVPlayerItem,
        currentTime: CMTime,
        generation: UUID,
        fileID: String
    ) {
        guard generation == previewLoadGeneration,
              selectedBrowserItemID == fileID,
              previewFileID == fileID else { return }

        let duration = CMTimeGetSeconds(playerItem.duration)
        if duration.isFinite, duration > 0 {
            previewDurationSeconds = duration
        }

        let current = CMTimeGetSeconds(currentTime)
        if current.isFinite, current >= 0 {
            previewPlaybackSeconds = previewDurationSeconds > 0
                ? min(current, previewDurationSeconds)
                : current
        }

        if previewUsesRetainedCache {
            if let snapshot = previewLastCacheSnapshot {
                previewBufferedSeconds = bufferedSecondsAhead(
                    of: previewPlaybackSeconds,
                    in: snapshot
                )
            }
        } else if !previewUsesRetainedCache {
            let availableDuration = loadedDuration(in: playerItem.loadedTimeRanges)
            previewBufferedSeconds = previewDurationSeconds > 0
                ? min(availableDuration, previewDurationSeconds)
                : availableDuration
        }

        let now = Date()
        expirePreviewTransferRateIfIdle(now: now)
        guard !previewUsesRetainedCache else { return }
        guard let events = playerItem.accessLog()?.events, !events.isEmpty else { return }
        let transferredBytes = events.reduce(UInt64(0)) { total, event in
            guard event.numberOfBytesTransferred > 0 else { return total }
            return addingWithoutOverflow(total, UInt64(event.numberOfBytesTransferred))
        }
        previewStreamedBytes = max(previewStreamedBytes, transferredBytes)
        updatePreviewNetworkRate(transferredBytes: transferredBytes, now: now)
    }

    /// AVPlayer's `observedBitrate` is deliberately not used here: it is an
    /// access-log statistic for an earlier request, not evidence that bytes are
    /// arriving now. Sampling the cumulative network-byte counter makes zero
    /// traffic settle back to zero even while playback continues from a buffer.
    private func updatePreviewNetworkRate(transferredBytes: UInt64, now: Date) {
        guard let sample = previewNetworkRateSample else {
            previewNetworkRateSample = (transferredBytes, now)
            previewTransferBytesPerSecond = 0
            return
        }

        let elapsed = now.timeIntervalSince(sample.date)
        guard elapsed >= 0.15 else { return }
        previewNetworkRateSample = (transferredBytes, now)

        if transferredBytes > sample.bytes {
            previewTransferBytesPerSecond = Double(transferredBytes - sample.bytes) / elapsed
            previewLastTransferProgressDate = now
        } else if transferredBytes < sample.bytes {
            // Access-log events may roll over when AVPlayer changes requests.
            // Establish a fresh baseline rather than reporting an invalid rate.
            previewTransferBytesPerSecond = 0
            previewLastTransferProgressDate = nil
        } else {
            expirePreviewTransferRateIfIdle(now: now)
        }
    }

    private func expirePreviewTransferRateIfIdle(now: Date) {
        guard previewTransferBytesPerSecond > 0 else { return }
        guard let lastProgress = previewLastTransferProgressDate,
              now.timeIntervalSince(lastProgress) < Self.previewTransferRateIdleTimeout else {
            previewTransferBytesPerSecond = 0
            return
        }
    }

    private func loadedDuration(in values: [NSValue]) -> Double {
        let ranges = values.compactMap { value -> (start: Double, end: Double)? in
            let range = value.timeRangeValue
            let start = CMTimeGetSeconds(range.start)
            let end = CMTimeGetSeconds(CMTimeRangeGetEnd(range))
            guard start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
            return (start, end)
        }.sorted { $0.start < $1.start }

        var total = 0.0
        var current: (start: Double, end: Double)?
        for range in ranges {
            guard let active = current else {
                current = range
                continue
            }
            if range.start <= active.end {
                current = (active.start, max(active.end, range.end))
            } else {
                total += active.end - active.start
                current = range
            }
        }
        if let current {
            total += current.end - current.start
        }
        return total
    }

    /// Seconds of media retained *continuously from the playhead* — the thing
    /// the row beside "Playback" implies. Byte offsets map through a constant
    /// rate, the same approximation this pane already makes elsewhere; it is far
    /// closer to the truth than treating the sparse cache total as though it
    /// were one contiguous run starting at t = 0.
    private func bufferedSecondsAhead(
        of playbackSeconds: Double,
        in snapshot: PreviewResourceCacheSnapshot
    ) -> Double {
        guard previewDurationSeconds > 0,
              let contentLength = snapshot.contentLength,
              contentLength > 0 else { return 0 }
        let bytesPerSecond = Double(contentLength) / previewDurationSeconds
        guard bytesPerSecond > 0 else { return 0 }
        let clamped = min(max(playbackSeconds, 0), previewDurationSeconds)
        let offset = Int64(clamped * bytesPerSecond)
        guard let end = snapshot.contiguousEnd(from: offset) else { return 0 }
        let reachable = Double(end) / bytesPerSecond
        return min(max(reachable - clamped, 0), previewDurationSeconds - clamped)
    }

    private func updatePreviewCacheMetrics(
        _ snapshot: PreviewResourceCacheSnapshot,
        generation: UUID,
        fileID: String,
        resetsRateSample: Bool = false
    ) {
        guard generation == previewLoadGeneration,
              selectedBrowserItemID == fileID,
              previewFileID == fileID else { return }

        let cachedBytes = UInt64(max(snapshot.cachedBytes, 0))
        let totalBytes = UInt64(max(snapshot.contentLength ?? 0, 0))
        previewUsesRetainedCache = true
        previewRetainedBytes = cachedBytes
        previewRetainedTotalBytes = totalBytes
        previewStreamedBytes = cachedBytes
        previewLastCacheSnapshot = snapshot
        previewRetainedSegments = snapshot.normalizedRanges.enumerated().map { index, span in
            PreviewBufferSegment(id: index, start: span.lowerBound, end: span.upperBound)
        }
        previewBufferedSeconds = bufferedSecondsAhead(of: previewPlaybackSeconds, in: snapshot)

        let now = Date()
        if resetsRateSample {
            previewCacheRateSample = (cachedBytes, now)
            previewTransferBytesPerSecond = 0
            previewLastTransferProgressDate = nil
            return
        }
        guard let sample = previewCacheRateSample else {
            previewCacheRateSample = (cachedBytes, now)
            return
        }
        let elapsed = now.timeIntervalSince(sample.date)
        guard elapsed >= 0.15 else { return }
        previewCacheRateSample = (cachedBytes, now)
        if cachedBytes > sample.bytes {
            previewTransferBytesPerSecond = Double(cachedBytes - sample.bytes) / elapsed
            previewLastTransferProgressDate = now
        } else if cachedBytes < sample.bytes {
            previewTransferBytesPerSecond = 0
            previewLastTransferProgressDate = nil
        } else {
            expirePreviewTransferRateIfIdle(now: now)
        }
    }

    private func tryNextPreviewSource(
        after error: Error?,
        generation: UUID,
        fileID: String,
        autoplay: Bool
    ) {
        guard generation == previewLoadGeneration,
              selectedBrowserItemID == fileID,
              previewFileID == fileID else { return }

        let failedSourceNumber = previewSourceIndex + 1
        let diagnostic = previewFailureDiagnostic(
            error,
            playerItem: previewPlayer?.currentItem
        )
        let failure = "failed (\(diagnostic.code))"
        let shouldResumePlayback = autoplay
            || previewPlaybackWasRequested
            || previewPlayer?.timeControlStatus == .playing
            || previewPlayer?.timeControlStatus == .waitingToPlayAtSpecifiedRate

        let nextIndex = previewSourceIndex + 1
        if previewSources.indices.contains(nextIndex) {
            appendOutput(
                "Preview source \(failedSourceNumber) \(failure); trying the next secure source.\n"
            )
            loadPreviewSource(
                at: nextIndex,
                fileID: fileID,
                autoplay: shouldResumePlayback
            )
            return
        }

        let extensionName = selectedBrowserItem?.normalizedFileExtension ?? ""
        if extensionName == "avi",
           activateCompatibilityPreview() {
            appendOutput(
                "Native preview sources were incompatible; compatibility preview is ready.\n"
            )
            return
        }

        appendOutput("All \(previewSources.count) preview sources failed \(failure).\n")
        previewLoadGeneration = UUID()
        previewPlaybackWasRequested = false
        removePreviewPlayerObservers()
        previewPlayer?.pause()
        previewPlayer = nil
        previewSourceLabel = nil
        isPreviewLoading = false
        previewStreamingState = .failed
        let mediaName = selectedBrowserItem?.mediaKind == .audio ? "audio" : "video"
        previewPlaybackError = "This \(mediaName) could not be played. You can retry the preview or download the file."
        previewErrorDiagnostic = diagnostic
        setError(
            "The \(mediaName) preview could not be loaded. Try again or download the file.",
            diagnostic: diagnostic
        )
    }

    private func previewSourceName(_ source: PreviewSource) -> String {
        if let label = source.label?.trimmingCharacters(in: .whitespacesAndNewlines),
           !label.isEmpty {
            return label
        }
        return source.isOrigin ? "Original file" : "Optimized stream"
    }

    private func previewFailureDiagnostic(
        _ error: Error?,
        playerItem: AVPlayerItem?
    ) -> AppErrorDiagnostic {
        let event = playerItem?.errorLog()?.events.last
        let nsError = error as NSError?
        let eventDomain = event?.errorDomain.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = eventDomain?.isEmpty == false
            ? eventDomain!
            : (nsError?.domain ?? "AVPlayer")

        var codes: [String] = []
        if let event, event.errorStatusCode != 0 {
            if (100...599).contains(event.errorStatusCode) {
                codes.append("HTTP \(event.errorStatusCode)")
            } else {
                codes.append("Stream \(event.errorStatusCode)")
            }
        }
        if let nsError {
            codes.append("\(nsError.domain) \(nsError.code)")
        }
        if codes.isEmpty {
            codes.append("PREVIEW_STARTUP_TIMEOUT")
        }

        let eventMessage = event.flatMap(\.errorComment)?.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let rawMessage: String
        if let eventMessage, !eventMessage.isEmpty {
            rawMessage = eventMessage
        } else if let nsError {
            rawMessage = nsError.localizedDescription
        } else {
            rawMessage = "No playable media data arrived within 25 seconds."
        }

        var contextLines: [String] = []
        if let previewSourceLabel, !previewSourceLabel.isEmpty {
            contextLines.append("Preview source: \(previewSourceLabel)")
        }
        if let nsError,
           let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain != nsError.domain || underlying.code != nsError.code {
            contextLines.append("Underlying code: \(underlying.domain) \(underlying.code)")
        }
        if PreviewTransport.isSecureConnectionFailure(error ?? playerItem?.error)
            || codes.contains(where: { $0.contains("-1200") }) {
            let routeHint = PreviewTransport.usesProxy(proxyURL)
                ? "Transport: app HTTPS proxy; macOS certificate validation enabled."
                : "Transport: direct. Configure Proxy in Transfers > Advanced if this network resets PikPak TLS."
            contextLines.append(routeHint)
        }

        return AppErrorDiagnostic(
            source: source,
            code: codes.joined(separator: " • "),
            message: sanitizedDiagnosticText(rawMessage, maximumLength: 500),
            context: contextLines.isEmpty ? nil : contextLines.joined(separator: "\n")
        )
    }

    private func removePreviewPlayerObservers() {
        previewResourceLoader?.invalidate()
        previewResourceLoader = nil
        playerItemStatusObservation?.invalidate()
        playerItemStatusObservation = nil
        playerLoadedTimeRangesObservation?.invalidate()
        playerLoadedTimeRangesObservation = nil
        playerTimeControlStatusObservation?.invalidate()
        playerTimeControlStatusObservation = nil
        if let playerRateChangeObserver {
            NotificationCenter.default.removeObserver(playerRateChangeObserver)
            self.playerRateChangeObserver = nil
        }
        if let previewTimeObserver, let previewTimeObserverPlayer {
            previewTimeObserverPlayer.removeTimeObserver(previewTimeObserver)
        }
        previewTimeObserver = nil
        previewTimeObserverPlayer = nil
        if let playerFailureObserver {
            NotificationCenter.default.removeObserver(playerFailureObserver)
            self.playerFailureObserver = nil
        }
        if let playerAccessLogObserver {
            NotificationCenter.default.removeObserver(playerAccessLogObserver)
            self.playerAccessLogObserver = nil
        }
        if let playerEndObserver {
            NotificationCenter.default.removeObserver(playerEndObserver)
            self.playerEndObserver = nil
        }
        if let playerStallObserver {
            NotificationCenter.default.removeObserver(playerStallObserver)
            self.playerStallObserver = nil
        }
        previewLoadTimeoutTask?.cancel()
        previewLoadTimeoutTask = nil
        previewMetricsTask?.cancel()
        previewMetricsTask = nil
        previewPlaybackRecoveryTask?.cancel()
        previewPlaybackRecoveryTask = nil
    }

    private func resetPreviewStreamingMetrics(state: PreviewStreamingState) {
        previewStreamingState = state
        previewPlaybackSeconds = 0
        previewDurationSeconds = 0
        previewBufferedSeconds = 0
        previewStreamedBytes = 0
        previewTransferBytesPerSecond = 0
        previewRetainedBytes = 0
        previewRetainedTotalBytes = 0
        previewUsesRetainedCache = false
        previewRetainedSegments = []
        previewLastCacheSnapshot = nil
        previewCacheRateSample = nil
        previewNetworkRateSample = nil
        previewLastTransferProgressDate = nil
    }

    private func finishFolderMeasurement(
        output: String,
        folderID: String,
        linkID: UUID? = nil,
        scanRevision: UInt64? = nil,
        scanAccountID: String? = nil,
        usedCachedSubfolders: Bool = false
    ) {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let report = try decoder.decode(FolderMeasurementReport.self, from: Data(output.utf8))
            if linkID == nil, let scanRevision {
                guard scanAccountID == folderMeasurementAccountID,
                      !removedSizeFolderIDs.contains(folderID) else { return }
                var topology = folderSizeIndex
                topology.parents.merge(report.parents ?? [:]) { _, new in new }
                let overlaps = folderSizeChanges.contains { id, revision in
                    revision > scanRevision && topology.ancestors(of: id).contains(folderID)
                } || sizeMutationOverlaps(folderID, topology: topology)
                if overlaps {
                    // Only an overlapping mutation invalidates the result. A
                    // manual full rescan remains full when retried, never seeded
                    // from the stale descendants it was supposed to replace.
                    automaticSizeRepairIDs.insert(folderID)
                    if !usedCachedSubfolders { forceFullSizeRepairIDs.insert(folderID) }
                    scheduleFolderSizeRepair()
                    appendOutput("Folder changed during size calculation; queued a fresh size update.\n")
                    return
                }
            }
            let rootMeasurement = report.folders?[folderID] ?? report.rootMeasurement

            // Publish the complete cache in one assignment so a large folder
            // tree refreshes once instead of re-rendering for every descendant.
            var updatedMeasurements = folderMeasurements
            let contextualMeasurements = (report.folders ?? [:]).reduce(
                into: [String: FolderMeasurement]()
            ) { values, entry in
                values[
                    folderMeasurementCacheKey(for: entry.key, linkID: linkID)
                ] = entry.value
            }
            updatedMeasurements.merge(contextualMeasurements) { _, newest in newest }
            let rootCacheKey = folderMeasurementCacheKey(for: folderID, linkID: linkID)
            updatedMeasurements[rootCacheKey] = rootMeasurement
            if linkID == nil {
                var sizes = report.folders ?? [:]
                sizes[folderID] = rootMeasurement
                folderSizeIndex.applyScan(
                    rootID: folderID, folders: sizes,
                    scannedListings: report.listings ?? [:], parentIDs: report.parents ?? [:]
                )
                publishAccountFolderSizes()
                updatedMeasurements = folderMeasurements
            } else {
                folderMeasurements = updatedMeasurements
            }
            persistFolderMeasurements()

            let activeLinkID = isBrowsingSharedLink ? activeSharedLinkID : nil
            if activeLinkID == linkID {
                if let selectedBrowserItemID,
                   let selectedMeasurement = updatedMeasurements[
                       folderMeasurementCacheKey(
                           for: selectedBrowserItemID,
                           linkID: linkID
                       )
                   ] {
                    folderMeasurement = selectedMeasurement
                    measuredFolderID = selectedBrowserItemID
                } else if selectedBrowserItemID == folderID {
                    folderMeasurement = rootMeasurement
                    measuredFolderID = folderID
                }
            }
            if browserSortColumn == .size, activeLinkID == linkID {
                applyBrowserSortToCachedItems()
            }
            let subfolderCount = max(0, (report.folders?.count ?? 1) - 1)
            let completionMessage: String
            if subfolderCount == 0 {
                completionMessage = "Folder size calculated"
            } else {
                completionMessage = "Folder size updated; cached \(subfolderCount.formatted()) subfolder \(subfolderCount == 1 ? "size" : "sizes")"
            }
            if !isRunning {
                setStatus(completionMessage)
            } else {
                appendOutput(completionMessage + "\n")
            }
        } catch {
            appendOutput("Could not decode folder size data: \(error.localizedDescription)\n")
            if !isRunning {
                setError("PikPak returned folder size data this app could not read.")
            }
        }
    }

    private func publishAccountFolderSizes() {
        var sizes = folderMeasurements.filter { $0.key.hasPrefix("shared-link:") }
        sizes.merge(folderSizeIndex.usableMeasurements) { _, new in new }
        if folderMeasurements != sizes { folderMeasurements = sizes }
        updateSelectedFolderMeasurementFromCache()
    }

    private func sizeMutationScopes(for operation: Operation?) -> Set<String> {
        switch operation {
        case .trash(let id, _): return [folderSizeIndex.parents[id] ?? id]
        case .trashBrowserItems(let ids), .trashDuplicates(let ids):
            return Set(ids.map { folderSizeIndex.parents[$0] ?? $0 })
        case .moveBrowserItems(let items, let destination):
            return Set(items.map { accountSizeParent(of: $0) ?? $0.id }).union([destination.id])
        case .createFolder(let parent, _), .upload(let parent, _): return [parent.id]
        case .emptyFolders(let scope), .dsStoreFiles(let scope): return [scope.id]
        case .archiveExtract(let item): return [accountSizeParent(of: item) ?? ""]
        case .mergeFolders(let folders, let destination): return Set(folders.map(\.id)).union([destination.id])
        default: return []
        }
    }

    private func sizeMutationOverlaps(_ folderID: String, topology: FolderSizeIndex) -> Bool {
        var scopes = isRunning ? sizeMutationScopes(for: operation) : []
        if isUploading, let destination = uploadDestination { scopes.insert(destination.id) }
        if isMergingFolders {
            scopes.formUnion(mergeRequestedFolders.map(\.id))
            if let destination = mergeDestination { scopes.insert(destination.id) }
        }
        scopes.formUnion(sizeMutationScopes(for: maintenanceOperation))
        for task in archiveTasks where task.isExtracting {
            scopes.insert(accountSizeParent(of: task.item) ?? "")
        }
        if !sharedSaveProcesses.isEmpty {
            let parents = (accountBrowserWorkspace?.items ?? [])
                .filter { $0.isFolder && $0.name == "Pack From Shared" }.map(\.id)
            scopes.formUnion(parents.isEmpty ? [""] : parents)
        }
        return scopes.contains {
            topology.ancestors(of: $0).contains(folderID)
                || topology.ancestors(of: folderID).contains($0)
        }
    }

    private func recordFolderSizeChange(in parentIDs: Set<String>) {
        let previousDirty = folderSizeIndex.dirty
        for id in parentIDs { folderSizeIndex.markChanged(id) }
        if previousDirty == folderSizeIndex.dirty {
            // Still invalidate an overlapping in-flight scan, but avoid
            // republishing / serializing the whole index for every uploaded file.
            folderSizeRevision &+= 1
            for id in parentIDs {
                for ancestor in folderSizeIndex.ancestors(of: id) { folderSizeChanges[ancestor] = folderSizeRevision }
            }
            return
        }
        finishFolderSizeMutation(affectedParents: parentIDs)
    }

    private func finishFolderSizeMutation(affectedParents: Set<String>) {
        folderSizeRevision &+= 1
        for id in affectedParents {
            for ancestor in folderSizeIndex.ancestors(of: id) { folderSizeChanges[ancestor] = folderSizeRevision }
            if let root = folderSizeIndex.repairRoot(for: id), folderSizeIndex.dirty.contains(root) {
                automaticSizeRepairIDs.insert(root)
            }
        }
        publishAccountFolderSizes()
        persistFolderMeasurements()
        scheduleFolderSizeRepair()
    }

    private func scheduleFolderSizeRepair() {
        guard !automaticSizeRepairIDs.isEmpty, !isClosingWindow else { return }
        folderSizeRepairTask?.cancel()
        folderSizeRepairTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            guard !Task.isCancelled, let self else { return }
            guard !self.isClosingWindow, self.hasUsableSession,
                  !self.isLoginPresented, self.deferredLoginReason == nil else { return }
            // Batch many upload completions into one shallow refresh. The UI,
            // normal browsing, and independent transfer helpers never wait.
            guard !self.isUploading, !self.isMergingFolders, !self.isMeasuringFolder else {
                self.scheduleFolderSizeRepair()
                return
            }
            let requested = self.automaticSizeRepairIDs
            let roots = requested.filter { id in
                !self.folderSizeIndex.ancestors(of: id).dropFirst().contains(where: requested.contains)
            }
            self.automaticSizeRepairIDs.removeAll()
            for id in roots.sorted() {
                if self.removedSizeFolderIDs.contains(id) { continue }
                if self.sizeMutationOverlaps(id, topology: self.folderSizeIndex) {
                    self.automaticSizeRepairIDs.insert(id)
                    continue
                }
                let forceFull = self.forceFullSizeRepairIDs.remove(id) != nil
                self.runFolderMeasurementEngine(
                    arguments: ["measure", "--id", id] + (forceFull ? [] : ["--use-size-cache"]),
                    operation: .measure(folderID: id)
                )
            }
            self.scheduleFolderSizeRepair()
        }
    }

    private func sizeEntry(_ item: BrowserItem) -> FolderSizeEntry {
        FolderSizeEntry(id: item.id, size: item.size, isFolder: item.isFolder)
    }

    private func accountSizeParent(of item: BrowserItem) -> String? {
        folderSizeIndex.parents[item.id] ?? item.parentId
    }

    private func removeAccountFolderSizes(_ ids: Set<String>) {
        if let activeID = measuringFolderID,
           folderSizeIndex.ancestors(of: activeID).contains(where: ids.contains) {
            removedSizeFolderIDs.insert(activeID)
        }
        removedSizeFolderIDs.formUnion(ids)
        let workspaceItems = isBrowsingSharedLink
            ? (accountBrowserWorkspace.map { $0.items + $0.childrenByFolderID.values.flatMap { $0 } } ?? [])
            : browserItems + browserTreeChildren.values.flatMap { $0 }
        for item in workspaceItems where ids.contains(item.id) && folderSizeIndex.parents[item.id] == nil {
            if let parent = item.parentId { folderSizeIndex.parents[item.id] = parent }
        }
        let parents = Set(ids.compactMap { folderSizeIndex.parents[$0] })
        folderSizeIndex.remove(ids)
        automaticSizeRepairIDs.subtract(ids)
        finishFolderSizeMutation(affectedParents: parents.subtracting(ids))
    }

    private func reconcileAccountFolderSize(_ folderID: String, items: [BrowserItem]) {
        // The server may already reflect a mutation whose acknowledgement has
        // not reached the GUI yet. Do not reconcile that snapshot and then
        // apply the same confirmed deletion/move as a second delta.
        guard !sizeMutationOverlaps(folderID, topology: folderSizeIndex) else { return }
        if folderSizeIndex.reconcile(folderID: folderID, entries: items.map(sizeEntry)) {
            finishFolderSizeMutation(affectedParents: [folderID])
        }
    }

    private func removeSharedLinkMeasurements(_ linkID: UUID) {
        let prefix = sharedLinkMeasurementPrefix(linkID)
        pendingFolderMeasurementRequests.removeAll { request in
            request.cacheKey.hasPrefix(prefix)
        }
        queuedFolderMeasurementCacheKeys = Set(
            queuedFolderMeasurementCacheKeys.filter { !$0.hasPrefix(prefix) }
        )
        folderMeasurements = folderMeasurements.filter { key, _ in
            !key.hasPrefix(prefix)
        }
        updateSelectedFolderMeasurementFromCache()
        persistFolderMeasurements()
    }

    private func adoptFolderMeasurementCache(for rawAccountID: String) {
        let accountID = rawAccountID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !accountID.isEmpty, folderMeasurementAccountID != accountID else { return }

        // Never carry one account's opaque folder ids into another account.
        let currentSessionMeasurements = folderMeasurementAccountID == nil
            ? folderMeasurements
            : [:]
        persistFolderMeasurementsNow()
        folderSizeRepairTask?.cancel()
        automaticSizeRepairIDs = []
        folderSizeIndex = FolderSizeIndex(
            measurements: currentSessionMeasurements.filter { !$0.key.hasPrefix("shared-link:") }
        )
        folderSizeRevision &+= 1
        folderSizeChanges = [:]
        removedSizeFolderIDs = []
        forceFullSizeRepairIDs = []
        folderMeasurementAccountID = accountID
        do {
            let cachedAccount = try folderMeasurementCacheQueue.sync {
                try FolderMeasurementCacheStore.account(for: accountID)
            }
            let persistedMeasurements = cachedAccount?.measurements ?? [:]
            var mergedMeasurements = persistedMeasurements
            mergedMeasurements.merge(currentSessionMeasurements) { _, newest in newest }
            folderSizeIndex = cachedAccount?.index ?? FolderSizeIndex(
                measurements: mergedMeasurements.filter { !$0.key.hasPrefix("shared-link:") }
            )
            folderMeasurements = mergedMeasurements
            publishAccountFolderSizes()
            automaticSizeRepairIDs = Set(folderSizeIndex.dirty.compactMap { folderSizeIndex.repairRoot(for: $0) })
            scheduleFolderSizeRepair()
            updateSelectedFolderMeasurementFromCache()
            if browserSortColumn == .size {
                applyBrowserSortToCachedItems()
            }
            if !persistedMeasurements.isEmpty {
                appendOutput(
                    "Loaded \(persistedMeasurements.count.formatted()) saved folder sizes for this PikPak account.\n"
                )
            }
        } catch {
            folderMeasurements = currentSessionMeasurements
            updateSelectedFolderMeasurementFromCache()
            appendOutput(
                "Warning: saved folder sizes could not be loaded: \(error.localizedDescription)\n"
            )
        }
    }

    private func persistFolderMeasurements() {
        folderSizePersistTask?.cancel()
        folderSizePersistTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, let self else { return }
            self.persistFolderMeasurementsNow()
        }
    }

    private func persistFolderMeasurementsNow() {
        folderSizePersistTask?.cancel()
        folderSizePersistTask = nil
        guard let accountID = folderMeasurementAccountID else { return }
        let measurements = folderMeasurements
        let index = folderSizeIndex
        folderMeasurementCacheQueue.async { [weak self] in
            do {
                try FolderMeasurementCacheStore.save(measurements, index: index, for: accountID)
            } catch {
                Task { @MainActor [weak self] in
                    self?.appendOutput(
                        "Warning: folder sizes could not be saved locally: \(error.localizedDescription)\n"
                    )
                }
            }
        }
    }

    private func updateSelectedFolderMeasurementFromCache() {
        guard
            let selectedBrowserItemID,
            let selectedItem = selectedBrowserItem,
            selectedItem.isFolder,
            let measurement = cachedFolderMeasurement(for: selectedBrowserItemID)
        else {
            folderMeasurement = nil
            measuredFolderID = nil
            return
        }
        folderMeasurement = measurement
        measuredFolderID = selectedBrowserItemID
    }

    private func clearFolderMeasurementAccountContext() {
        persistFolderMeasurementsNow()
        folderSizeRepairTask?.cancel()
        folderSizeRepairTask = nil
        automaticSizeRepairIDs = []
        folderSizeIndex = FolderSizeIndex()
        folderSizeChanges = [:]
        removedSizeFolderIDs = []
        forceFullSizeRepairIDs = []
        sizeListingRevisions = [:]
        folderSizeRevision &+= 1
        folderMeasurementAccountID = nil
        folderMeasurements.removeAll(keepingCapacity: false)
        folderMeasurement = nil
        measuredFolderID = nil
        measuringFolderID = nil
        measuringFolderCacheKey = nil
        clearPendingFolderMeasurements()
    }

    private func finishQuota(output: String, announcesResult: Bool) {
        do {
            let quota = try JSONDecoder().decode(StorageQuota.self, from: Data(output.utf8))
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            if let envelope = try? decoder.decode(AccountProfileEnvelope.self, from: Data(output.utf8)),
               let profile = envelope.accountProfile {
                if let expected = activeSavedAccount?.profile?.sub, expected != profile.sub {
                    throw PikPakAccountError.accountMismatch
                }
                adoptTransferAccount(profile.sub)
                rememberVerifiedAccount(profile)
            }
            storageQuota = quota
            storageQuotaError = nil
            if announcesResult {
                setStatus("Connection successful; PikPak storage updated")
            }
        } catch {
            storageQuotaError = "PikPak returned storage information this app could not read."
            appendOutput("Could not decode storage quota: \(error.localizedDescription)\n")
            if announcesResult {
                setError(storageQuotaError ?? "Could not read PikPak storage information.")
            }
        }
    }

    private func finishDuplicateScan(output: String, scope: BrowserLocation) {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let scan = try decoder.decode(DuplicateScan.self, from: Data(output.utf8))
            duplicateScan = scan
            duplicateScannedFiles = scan.scannedFiles
            duplicateScannedFolders = scan.scannedFolders
            duplicateDiscoveredFolders = max(
                scan.scannedFolders + scan.failedFolders,
                1
            )
            duplicatePendingFolders = 0
            duplicateFailedFolders = scan.failedFolders
            duplicateRetryAttempt = 0
            duplicateRetryMaxAttempts = 0
            duplicateRetryInMillis = 0
            duplicateCurrentPath = scan.rootPath
            duplicateScanRootPath = scan.rootPath
            selectedDuplicateFileIDs = Set(
                scan.groups
                    .filter { $0.matchKind == .exactContent }
                    .flatMap { $0.files.dropFirst().map(\.id) }
            )
            let message: String
            if scan.failedFolders > 0 {
                message = "Duplicate scan completed with partial results; \(scan.failedFolders.formatted()) folder(s) were unavailable"
            } else if scan.groups.isEmpty {
                message = "No duplicate files found in \(scope.name)"
            } else {
                message = "Found \(scan.groups.count) duplicate group(s) in \(scope.name)"
            }
            taskActivity.finish(.duplicates, state: scan.failedFolders > 0 ? .partial : .completed,
                message: message, detail: "\(scan.scannedFiles.formatted()) files checked in \(scan.scannedFolders.formatted()) folders")
            if !isRunning { setStatus(message) }
        } catch {
            appendOutput("Could not decode duplicate scan data: \(error.localizedDescription)\n")
            let message = "PikPak returned duplicate data this app could not read."
            taskActivity.finish(.duplicates, state: .failed, message: message)
            setError(message)
        }
    }

    private func finishTrash(output: String, itemID: String, itemName: String) {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let result = try decoder.decode(TrashResult.self, from: Data(output.utf8))
            guard result.trashedIds.contains(itemID) else {
                setError("PikPak did not confirm that the selected item was moved to Trash.")
                return
            }

            recordTrashUndo(ids: [itemID])
            removeCachedBrowserItems(withIDs: Set([itemID]))
            if selectedBrowserItemID == itemID {
                clearBrowserSelection()
            } else {
                selectedBrowserItemIDs.remove(itemID)
            }
            duplicateScan = nil
            selectedDuplicateFileIDs = []
            setStatus("\(itemName) moved to PikPak Trash")
        } catch {
            appendOutput("Could not decode Trash response: \(error.localizedDescription)\n")
            setError("PikPak returned a Trash response this app could not read.")
        }
    }

    private func finishTrashBrowserItems(output: String, requestedIDs: [String]) {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let result = try decoder.decode(TrashResult.self, from: Data(output.utf8))
            let requested = Set(requestedIDs)
            let trashed = Set(result.trashedIds).intersection(requested)
            guard !trashed.isEmpty else {
                setError(
                    "PikPak did not confirm every selected item was moved to Trash. Refresh the folder before retrying."
                )
                return
            }

            recordTrashUndo(ids: requestedIDs.filter { trashed.contains($0) })
            removeCachedBrowserItems(withIDs: trashed)
            clearBrowserSelection()
            duplicateScan = nil
            selectedDuplicateFileIDs = []
            if requested.isSubset(of: trashed) { setStatus("Moved \(trashed.count.formatted()) selected item(s) to PikPak Trash") }
            else { setError("Moved \(trashed.count) of \(requested.count) item(s) to Trash. The confirmed items can be undone.") }
        } catch {
            appendOutput("Could not decode batch Trash response: \(error.localizedDescription)\n")
            setError("PikPak returned a Trash response this app could not read.")
        }
    }

    private func finishMoveBrowserItems(
        output: String,
        requestedItems: [BrowserItem],
        destination: BrowserLocation
    ) {
        defer { undoMoveOrigins.removeAll() }
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let result = try decoder.decode(MoveResult.self, from: Data(output.utf8))
            let requestedIDs = Set(requestedItems.map(\.id))
            let movedIDs = Set(result.movedIds).intersection(requestedIDs)
            guard !movedIDs.isEmpty, result.parentId == destination.id else {
                setError(
                    "PikPak did not confirm every moved item. Refresh the affected folders before retrying."
                )
                return
            }

            let changes = requestedItems.filter { movedIDs.contains($0.id) }.compactMap { item -> FinderFileMutation? in
                guard let parent = undoMoveOrigins[item.id] ?? accountSizeParent(of: item), parent != destination.id else { return nil }
                return FinderFileMutation(fileId: item.id, kind: .move, before: parent, after: destination.id,
                    parentId: nil, name: item.name)
            }
            fileUndoHistory.record(FinderUndoEntry(title: "Move", mutations: changes))
            applySuccessfulBrowserMove(
                items: requestedItems.filter { movedIDs.contains($0.id) },
                destination: destination
            )
            clearBrowserSelection()
            duplicateScan = nil
            selectedDuplicateFileIDs = []
            if requestedIDs.isSubset(of: movedIDs) { setStatus("Moved \(movedIDs.count.formatted()) item(s) to \(destination.name)") }
            else { setError("Moved \(movedIDs.count) of \(requestedIDs.count) item(s). The confirmed moves can be undone.") }
        } catch {
            appendOutput("Could not decode move response: \(error.localizedDescription)\n")
            setError("PikPak returned a move response this app could not read.")
        }
    }

    private func finishMergeFolders(
        output: String,
        requestedFolders: [BrowserItem],
        destination: BrowserItem
    ) {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let result = try decoder.decode(MergeFoldersResult.self, from: Data(output.utf8))
            let requestedSourceIDs = Set(
                requestedFolders.filter { $0.id != destination.id }.map(\.id)
            )
            let mergedSourceIDs = Set(result.mergedSourceIds)
            guard result.destinationId == destination.id,
                  requestedSourceIDs.isSubset(of: mergedSourceIDs)
            else {
                let message = "PikPak did not confirm every selected folder was merged. Refresh the folder before retrying."
                let diagnostic = AppErrorDiagnostic(
                    source: "PikPak engine",
                    code: "MERGE_RESULT_INCOMPLETE",
                    message: message,
                    context: nil
                )
                mergeStatus = message
                mergeErrorDiagnostic = diagnostic
                setError(message, diagnostic: diagnostic)
                return
            }

            // Discard the removed source branches. The surviving destination
            // is collapsed so its next expansion is fetched authoritatively
            // and includes children that were not previously loaded in this UI.
            removeCachedAccountBrowserItems(withIDs: mergedSourceIDs, invalidatingFolders: [destination.id])
            if !isBrowsingSharedLink {
                if browserItem(withID: destination.id) != nil {
                    updateBrowserSelection(to: destination)
                } else {
                    clearBrowserSelection()
                }
            }
            duplicateScan = nil
            selectedDuplicateFileIDs = []
            quotaRefreshPending = true
            mergeCompletedSourceIDs.formUnion(mergedSourceIDs)
            mergeCompletedSourceCount = max(mergeSourceCount, mergeCompletedSourceIDs.count)
            mergeMovedItems = max(mergeMovedItems, result.movedItems)
            mergeRemainingItems = 0
            mergeDidComplete = true
            mergeErrorDiagnostic = nil
            let message = "Merged \(requestedFolders.count.formatted()) folders into \(destination.name); moved \(result.movedItems.formatted()) item(s)"
            mergeStatus = message
            setStatus(message)
        } catch {
            appendOutput("Could not decode merge-folders response: \(error.localizedDescription)\n")
            let message = "PikPak returned a merge response this app could not read. Refresh the folder to check the result."
            let diagnostic = self.diagnostic(
                for: error,
                source: "PikPak merge response",
                fallbackCode: "MERGE_RESULT_INVALID"
            )
            mergeStatus = message
            mergeErrorDiagnostic = diagnostic
            setError(message, diagnostic: diagnostic)
        }
    }

    /// Reparents only the confirmed roots while retaining already-loaded
    /// descendants. The outline therefore updates immediately without a full
    /// folder reload, and the next manual refresh remains authoritative.
    private func applySuccessfulBrowserMove(
        items: [BrowserItem],
        destination: BrowserLocation
    ) {
        let oldParents = Set(items.compactMap { accountSizeParent(of: $0) })
        folderSizeIndex.move(items.map(sizeEntry), to: destination.id)
        finishFolderSizeMutation(affectedParents: oldParents.union([destination.id]))
        if !browserTreeLoadProcesses.isEmpty {
            for item in items {
                browserMoveCorrections[item.id] = (item, destination, folderSizeRevision)
            }
        }
        let movedIDs = Set(items.map(\.id))
        browserItems.removeAll { movedIDs.contains($0.id) }
        for folderID in Array(browserTreeChildren.keys) {
            browserTreeChildren[folderID]?.removeAll { movedIDs.contains($0.id) }
        }

        for item in items {
            browserItemParentIDs[item.id] = destination.id
            let itemPath = joinedRemotePath(folder: destination.path, name: item.name)
            browserItemPaths[item.id] = itemPath
            if item.isFolder {
                updateKnownBrowserDescendantPaths(folderID: item.id, folderPath: itemPath)
            }
        }

        if browserStack.last?.id == destination.id {
            let existingIDs = Set(browserItems.map(\.id))
            browserItems.append(contentsOf: items.filter { !existingIDs.contains($0.id) })
            browserItems = sortedBrowserItems(browserItems)
        } else if browserTreeChildren[destination.id] != nil {
            let existingIDs = Set((browserTreeChildren[destination.id] ?? []).map(\.id))
            browserTreeChildren[destination.id]?.append(
                contentsOf: items.filter { !existingIDs.contains($0.id) }
            )
            browserTreeChildren[destination.id] = sortedBrowserItems(
                browserTreeChildren[destination.id] ?? []
            )
        }

        // Back-navigation snapshots describe old parent relationships and
        // must not resurrect the pre-move layout.
        browserFolderSnapshots = [:]
    }

    private func finishRenameItem(
        output: String,
        requestedItem: BrowserItem,
        requestedName: String
    ) {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let result = try decoder.decode(RenameResult.self, from: Data(output.utf8))
            guard result.id == requestedItem.id, result.name == requestedName else {
                setError(
                    "PikPak returned an unexpected rename result. Refresh the folder before retrying."
                )
                return
            }

            fileUndoHistory.record(FinderUndoEntry(title: "Rename", mutations: [FinderFileMutation(
                fileId: requestedItem.id, kind: .rename, before: requestedItem.name, after: requestedName,
                parentId: accountSizeParent(of: requestedItem), name: nil)]))
            let renamedExtension = (result.name as NSString).pathExtension
            let renamedFileExtension: String? = requestedItem.isFolder || renamedExtension.isEmpty
                ? nil
                : renamedExtension
            let renamedItem = BrowserItem(
                id: requestedItem.id,
                name: result.name,
                size: requestedItem.size,
                kind: requestedItem.kind,
                parentId: requestedItem.parentId,
                mimeType: requestedItem.mimeType,
                createdTime: requestedItem.createdTime,
                modifiedTime: requestedItem.modifiedTime,
                fileExtension: renamedFileExtension,
                iconLink: requestedItem.iconLink,
                thumbnailLink: requestedItem.thumbnailLink,
                fileCategory: requestedItem.fileCategory,
                hash: requestedItem.hash,
                md5Checksum: requestedItem.md5Checksum
            )

            browserItems = sortedBrowserItems(browserItems.map {
                $0.id == renamedItem.id ? renamedItem : $0
            })
            browserTreeChildren = browserTreeChildren.mapValues { children in
                sortedBrowserItems(children.map {
                    $0.id == renamedItem.id ? renamedItem : $0
                })
            }

            let oldPath = browserPath(for: requestedItem)
            let parentID = browserItemParentIDs[requestedItem.id]
                ?? requestedItem.parentId
                ?? ""
            let fallbackParentPath = (oldPath as NSString).deletingLastPathComponent
            let parentPath = browserStack.first(where: { $0.id == parentID })?.path
                ?? browserItemPaths[parentID]
                ?? (fallbackParentPath.isEmpty ? "/" : fallbackParentPath)
            let renamedPath = joinedRemotePath(folder: parentPath, name: result.name)
            browserItemPaths[renamedItem.id] = renamedPath
            if renamedItem.isFolder {
                updateKnownBrowserDescendantPaths(
                    folderID: renamedItem.id,
                    folderPath: renamedPath
                )
            }

            // Back-navigation snapshots contain the previous immutable row
            // value and would otherwise restore the old name later.
            browserFolderSnapshots = [:]
            // Renaming changes neither bytes nor ancestry.
            duplicateScan = nil
            selectedDuplicateFileIDs = []
            setStatus("Renamed \(requestedItem.name) to \(result.name)")
        } catch {
            appendOutput("Could not decode rename response: \(error.localizedDescription)\n")
            setError(
                "PikPak renamed the item but returned a response this app could not read. Refresh the folder to check it."
            )
        }
    }

    private func updateKnownBrowserDescendantPaths(folderID: String, folderPath: String) {
        for child in browserTreeChildren[folderID] ?? [] {
            browserItemParentIDs[child.id] = folderID
            let childPath = joinedRemotePath(folder: folderPath, name: child.name)
            browserItemPaths[child.id] = childPath
            if child.isFolder {
                updateKnownBrowserDescendantPaths(folderID: child.id, folderPath: childPath)
            }
        }
    }

    private func finishCreateFolder(
        output: String,
        parent: BrowserLocation,
        requestedName: String
    ) {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let result = try decoder.decode(CreateFolderResult.self, from: Data(output.utf8))
            guard !result.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  result.parentId == parent.id,
                  result.name == requestedName
            else {
                setError("PikPak returned an unexpected result for the new folder. Refresh before retrying.")
                return
            }

            fileUndoHistory.record(FinderUndoEntry(title: "New Folder", mutations: [FinderFileMutation(
                fileId: result.id, kind: .trash, before: "true", after: "false", parentId: parent.id,
                name: nil, requiresEmptyFolder: true)]))
            let item = BrowserItem(
                id: result.id,
                name: result.name,
                size: 0,
                kind: .folder,
                parentId: result.parentId,
                mimeType: nil,
                createdTime: nil,
                modifiedTime: nil,
                fileExtension: nil,
                iconLink: nil,
                thumbnailLink: nil,
                fileCategory: nil,
                hash: nil,
                md5Checksum: nil
            )
            browserItemParentIDs[item.id] = parent.id
            browserItemPaths[item.id] = joinedRemotePath(folder: parent.path, name: item.name)
            folderSizeIndex.insertEmptyFolder(id: item.id, parent: parent.id)
            finishFolderSizeMutation(affectedParents: [parent.id])

            if browserStack.last?.id == parent.id {
                if !browserItems.contains(where: { $0.id == item.id }) {
                    browserItems.append(item)
                    browserItems = sortedBrowserItems(browserItems)
                }
            } else if browserTreeChildren[parent.id] != nil,
                      browserTreeChildren[parent.id]?.contains(where: { $0.id == item.id }) == false {
                browserTreeChildren[parent.id]?.append(item)
                browserTreeChildren[parent.id] = sortedBrowserItems(
                    browserTreeChildren[parent.id] ?? []
                )
            }

            browserFolderSnapshots = [:]
            duplicateScan = nil
            selectedDuplicateFileIDs = []
            setStatus("Created folder \(result.name) in \(parent.name)")
        } catch {
            appendOutput("Could not decode create-folder response: \(error.localizedDescription)\n")
            setError("PikPak created the folder but returned a response this app could not read. Refresh the folder to check it.")
        }
    }

    private func finishEmptyFolderCleanup(output: String, scope: BrowserLocation) {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let result = try decoder.decode(EmptyFolderCleanup.self, from: Data(output.utf8))
            let removedIDs = Set(result.removedIds)

            emptyFolderScannedFolders = result.scannedFolders
            emptyFolderDiscoveredFolders = max(
                emptyFolderDiscoveredFolders,
                result.scannedFolders
            )
            emptyFolderCandidateCount = result.candidateFolders
            emptyFolderCheckedFolders = result.recheckedFolders
            emptyFolderRemovedFolders = result.removedFolders
            emptyFolderSkippedFolders = result.skippedNonEmptyFolders
            emptyFolderCurrentPath = result.rootPath

            if !removedIDs.isEmpty {
                if removedIDs.contains(where: { folderSizeIndex.parents[$0] == nil }) {
                    recordFolderSizeChange(in: [scope.id])
                }
                removeCachedAccountBrowserItems(withIDs: removedIDs)
                if !isBrowsingSharedLink {
                    selectedBrowserItemIDs.subtract(removedIDs)
                    if let selectedBrowserItemID, removedIDs.contains(selectedBrowserItemID) {
                        selectFirstExplicitBrowserItem()
                    }
                }
                duplicateScan = nil
                selectedDuplicateFileIDs = []
            }

            if result.candidateFolders == 0 {
                setMaintenanceStatus("No empty folders found below \(scope.name)")
            } else if result.removedFolders == 0 {
                setMaintenanceStatus(
                    "Kept \(result.skippedNonEmptyFolders.formatted()) folder(s) because they were no longer empty"
                )
            } else if result.skippedNonEmptyFolders > 0 {
                setMaintenanceStatus(
                    "Moved \(result.removedFolders.formatted()) verified empty folder(s); kept \(result.skippedNonEmptyFolders.formatted()) non-empty folder(s)"
                )
            } else {
                setMaintenanceStatus(
                    "Moved \(result.removedFolders.formatted()) verified empty folder(s) below \(scope.name) to PikPak Trash"
                )
            }
            taskActivity.finish(.emptyFolders, state: .completed, message: maintenanceStatus,
                detail: "\(result.scannedFolders.formatted()) folders scanned · \(result.removedFolders.formatted()) removed · \(result.skippedNonEmptyFolders.formatted()) kept")
        } catch {
            appendOutput("Could not decode empty-folder cleanup response: \(error.localizedDescription)\n")
            let message = "PikPak returned an empty-folder cleanup response this app could not read."
            taskActivity.finish(.emptyFolders, state: .failed, message: message)
            maintenanceStatus = message
            if !isRunning {
                setError(message)
            }
        }
    }

    private func finishDSStoreCleanup(output: String, scope: BrowserLocation) {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let result = try decoder.decode(DSStoreCleanup.self, from: Data(output.utf8))
            let removedIDs = Set(result.removedIds)

            if !removedIDs.isEmpty {
                if removedIDs.contains(where: { folderSizeIndex.parents[$0] == nil }) {
                    recordFolderSizeChange(in: [scope.id])
                }
                removeCachedAccountBrowserItems(withIDs: removedIDs)
                if !isBrowsingSharedLink {
                    selectedBrowserItemIDs.subtract(removedIDs)
                    if let selectedBrowserItemID, removedIDs.contains(selectedBrowserItemID) {
                        selectFirstExplicitBrowserItem()
                    }
                }
                duplicateScan = nil
                selectedDuplicateFileIDs = []
                if !isBrowsingSharedLink {
                    browserFolderSnapshots = [:]
                }
            }

            if result.candidateFiles == 0 {
                setMaintenanceStatus("No .DS_Store files found below \(scope.name)")
            } else if result.removedFiles == 0 {
                setMaintenanceStatus(
                    "Kept \(result.skippedFiles.formatted()) changed or missing .DS_Store candidate(s)"
                )
            } else if result.skippedFiles > 0 {
                setMaintenanceStatus(
                    "Moved \(result.removedFiles.formatted()) .DS_Store file(s) to Trash; kept \(result.skippedFiles.formatted()) changed candidate(s)"
                )
            } else {
                setMaintenanceStatus(
                    "Moved \(result.removedFiles.formatted()) .DS_Store file(s) below \(scope.name) to PikPak Trash"
                )
            }
            appendOutput(
                "Scanned \(result.scannedFolders.formatted()) folder(s), found \(result.candidateFiles.formatted()), rechecked \(result.recheckedFiles.formatted()), removed \(result.removedFiles.formatted()), skipped \(result.skippedFiles.formatted()) .DS_Store file(s).\n"
            )
            taskActivity.finish(.dsStore, state: .completed, message: maintenanceStatus,
                detail: "\(result.scannedFolders.formatted()) folders scanned · \(result.removedFiles.formatted()) removed · \(result.skippedFiles.formatted()) kept")
        } catch {
            appendOutput("Could not decode .DS_Store cleanup response: \(error.localizedDescription)\n")
            let message = "PikPak returned a .DS_Store cleanup response this app could not read."
            taskActivity.finish(.dsStore, state: .failed, message: message)
            maintenanceStatus = message
            if !isRunning {
                setError(message)
            }
        }
    }

    private func finishTrashDuplicates(output: String, requestedIDs: [String]) {
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let result = try decoder.decode(TrashResult.self, from: Data(output.utf8))
            let requested = Set(requestedIDs)
            let trashed = Set(result.trashedIds)
            guard requested.isSubset(of: trashed) else {
                setError("PikPak did not confirm every selected duplicate was moved to Trash. Run the scan again before retrying.")
                return
            }

            removeCachedAccountBrowserItems(withIDs: trashed)
            if !isBrowsingSharedLink {
                if let selectedBrowserItemID, trashed.contains(selectedBrowserItemID) {
                    clearBrowserSelection()
                } else {
                    selectedBrowserItemIDs.subtract(trashed)
                }
            }

            if let scan = duplicateScan {
                let groups = scan.groups.compactMap { group -> DuplicateGroup? in
                    let files = group.files.filter { !trashed.contains($0.id) }
                    guard files.count > 1 else { return nil }
                    let extraCopies = UInt64(files.count - 1)
                    return DuplicateGroup(
                        id: group.id,
                        matchKind: group.matchKind,
                        size: group.size,
                        copies: files.count,
                        reclaimableBytes: multiplyingWithoutOverflow(group.size, extraCopies),
                        files: files
                    )
                }
                let exactGroups = groups.filter { $0.matchKind == .exactContent }.count
                let reclaimableBytes = groups
                    .filter { $0.matchKind == .exactContent }
                    .reduce(UInt64(0)) {
                        addingWithoutOverflow($0, $1.reclaimableBytes)
                    }
                duplicateScan = DuplicateScan(
                    rootPath: scan.rootPath,
                    scannedFiles: scan.scannedFiles >= trashed.count
                        ? scan.scannedFiles - trashed.count
                        : 0,
                    scannedFolders: scan.scannedFolders,
                    failedFolders: scan.failedFolders,
                    duplicateFiles: groups.reduce(0) { $0 + $1.copies },
                    exactGroups: exactGroups,
                    possibleGroups: groups.count - exactGroups,
                    reclaimableBytes: reclaimableBytes,
                    groups: groups
                )
            }

            selectedDuplicateFileIDs.subtract(trashed)
            let message = "Moved \(trashed.count) duplicate file(s) to PikPak Trash"
            taskActivity.finish(.duplicates, state: .completed, message: message,
                detail: "\(duplicateScan?.groups.count ?? 0) duplicate groups remaining")
            setStatus(message)
        } catch {
            appendOutput("Could not decode duplicate Trash response: \(error.localizedDescription)\n")
            setError("PikPak returned a Trash response this app could not read.")
        }
    }

    private func multiplyingWithoutOverflow(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (product, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? UInt64.max : product
    }

    private func synchronizeSharedSessionFromDisk() {
        #if FINDER_WORKSPACE_TESTS
        if isFinderWorkspaceFixture { return }
        #endif
        do {
            let newestToken: String
            if let accountStore, let activeAccountID, activeSavedAccount?.needsSignIn == false {
                newestToken = try accountStore.files(for: activeAccountID).load().token
            } else {
                guard accountStore == nil, let token = try LocalCredentialStore.loadToken() else { return }
                newestToken = token
            }
            if newestToken != refreshToken {
                refreshToken = newestToken
                appendOutput("Shared session rotation synchronized.\n")
            }
        } catch {
            appendOutput("Warning: shared session could not be reloaded: \(error.localizedDescription)\n")
        }
    }

    private func similarityConfiguration(_ source: SimilaritySource) throws -> SimilarityConfiguration {
        guard !isClosingWindow else { throw CocoaError(.userCancelled) }
        guard let resources = Bundle.main.resourceURL,
              FileManager.default.isExecutableFile(atPath: resources.appendingPathComponent("filetwin-worker").path) else {
            throw NSError(domain: "FileSimilarity", code: 1, userInfo: [NSLocalizedDescriptionKey: "The FileTwin worker is missing. Rebuild the app with the similarity components."])
        }
        let support = try LocalCredentialStore.applicationSupportDirectoryURL().appendingPathComponent("Similarity", isDirectory: true)
        let identity: String
        var environment: [String: String]
        if source == .cloud {
            guard hasUsableSession else {
                throw NSError(domain: "FileSimilarity", code: 2, userInfo: [NSLocalizedDescriptionKey: "Sign in from Settings → Accounts before scanning PikPak files."])
            }
            environment = try engineEnvironment()
            let proxy = proxyURL.trimmingCharacters(in: .whitespacesAndNewlines)
            environment["PIKPAK_PROXY"] = proxy.isEmpty ? nil : proxy
            identity = "Cloud/\(activeAccountID?.uuidString ?? "desktop")"
        } else {
            // A local scan works without login or an OAuth configuration.
            environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("PIKPAK_") }
            identity = "Local"
        }
        return SimilarityConfiguration(executable: resources.appendingPathComponent("pikpak"),
            models: resources.appendingPathComponent("FileTwinModels", isDirectory: true),
            worker: resources.appendingPathComponent("filetwin-worker"),
            dataDirectory: support.appendingPathComponent(identity, isDirectory: true),
            temporaryDirectory: support.appendingPathComponent("Temporary", isDirectory: true), environment: environment)
    }

    private func similarityCloudScope(selection: Bool) throws -> [SimilarityCloudRoot] {
        guard hasUsableSession else {
            throw NSError(domain: "FileSimilarity", code: 2, userInfo: [NSLocalizedDescriptionKey: "Sign in from Settings → Accounts to choose cloud files. This Mac scans are available without signing in."])
        }
        guard !isBrowsingSharedLink else {
            throw NSError(domain: "FileSimilarity", code: 3, userInfo: [NSLocalizedDescriptionKey: "Choose a folder or files in the Browser tab, then use that scope here. Shared links are not part of your cloud scan."])
        }
        if selection {
            let items = browserItemsSelectedForAction
            guard !items.isEmpty else {
                throw NSError(domain: "FileSimilarity", code: 4, userInfo: [NSLocalizedDescriptionKey: "Select files or folders in Browser first, then choose Use Browser Selection."])
            }
            return items.map { item in
                let route = browserNavigationStack(opening: item)
                return SimilarityCloudRoot(id: item.id, name: item.name, path: route.last?.path ?? item.name,
                    isFolder: item.isFolder, size: item.size,
                    ancestors: route.dropFirst().dropLast().map { SimilarityAncestor(id: $0.id, name: $0.name) })
            }
        }
        let folder = browserStack.last ?? .root
        return [SimilarityCloudRoot(id: folder.id, name: folder.name, path: folder.path, isFolder: true, size: 0,
            ancestors: browserStack.dropFirst().dropLast().map { SimilarityAncestor(id: $0.id, name: $0.name) })]
    }

    #if FINDER_WORKSPACE_TESTS
    static func testSimilarityScope(defaults: UserDefaults) throws {
        let model = finderWorkspaceFixture(defaults: defaults)
        let root = try model.similarityCloudScope(selection: false)
        precondition(root.count == 1 && root[0].id.isEmpty && root[0].path == "/")
        let projects = model.browserItems.first { $0.name == "Projects" }!
        model.openFolder(projects)
        let drafts = model.browserItems.first { $0.name == "Drafts" }!
        model.selectBrowserItem(drafts)
        let selected = try model.similarityCloudScope(selection: true)
        precondition(selected.count == 1 && selected[0].isFolder && selected[0].path == "/Projects/Drafts")
        precondition(selected[0].ancestors.map(\.id) == [projects.id])
        model.taskActivity.begin(.similarityLocal, scope: "/Local", message: "Comparing")
        precondition(!model.accountWorkIsActive, "Local similarity activity does not prevent switching cloud accounts")
        model.fileSimilarity.cloud.cloudRoots = selected
        model.fileSimilarity.cloud.clearAccount()
        precondition(model.fileSimilarity.cloud.cloudRoots.isEmpty)
        model.stopForWindowClose()
        print("PASS current cloud folder, nested selection ancestry and account scope clearing")
    }
    #endif

    private func openSimilarityCloudFile(_ file: SimilarityFile) {
        guard let fileID = file.cloudId, hasUsableSession, !isClosingWindow else { return }
        do {
            // Results are account files even when the main window is in Links.
            let configuration = try similarityConfiguration(.cloud)
            let opening = FinderFileOpenConfiguration(executable: configuration.executable, environment: configuration.environment,
                arguments: ["preview", "--id", fileID], exchangeDirectory: try makePrivateExchangeDirectory(),
                copiesDirectory: try LocalCredentialStore.applicationSupportDirectoryURL().appendingPathComponent("Opened Files", isDirectory: true),
                proxyURL: proxyURL)
            fileOpener.open(identity: "similarity:\(activeAccountID?.uuidString ?? "desktop"):\(fileID):\(file.bytes)",
                name: file.name, application: nil, configuration: opening)
        } catch { fileSimilarity.cloud.error = "Could not open this cloud file: \(error.localizedDescription)" }
    }

    private func engineEnvironment() throws -> [String: String] {
        guard !isChangingAccount else { throw PikPakAccountError.cancelled }
        if let accountStore {
            guard let activeAccountID, activeSavedAccount?.needsSignIn == false else { throw LocalCredentialStoreError.untrustedSession }
            let files = accountStore.files(for: activeAccountID)
            let session = try files.load()
            guard session.deviceID == deviceID else { throw LocalCredentialStoreError.untrustedSession }
            return desktopEngineEnvironment(tokenURL: files.tokenURL, lockURL: files.lockURL, deviceID: session.deviceID)
        }
        guard
            try LocalCredentialStore.hasDedicatedAppLoginProfile(),
            try LocalCredentialStore.loadToken() != nil
        else { throw LocalCredentialStoreError.untrustedSession }

        let persistedDeviceID = try LocalCredentialStore.loadOrCreateDeviceID()
        guard !deviceID.isEmpty, persistedDeviceID == deviceID else {
            throw LocalCredentialStoreError.untrustedSession
        }
        return desktopEngineEnvironment(tokenURL: try LocalCredentialStore.tokenFileURL(),
            lockURL: try LocalCredentialStore.refreshLockFileURL(), deviceID: persistedDeviceID)
    }

    private func desktopEngineEnvironment(tokenURL: URL, lockURL: URL, deviceID: String) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "PIKPAK_REFRESH_TOKEN")
        environment.removeValue(forKey: "PIKPAK_ROTATED_TOKEN_FILE")
        environment["PIKPAK_REFRESH_TOKEN_FILE"] = tokenURL.path
        environment["PIKPAK_REFRESH_TOKEN_LOCK_FILE"] = lockURL.path
        environment["PIKPAK_DEVICE_ID"] = deviceID
        // The GUI session is deliberately issued to PikPak's desktop client.
        // Never let a shell-level Web-client override rejoin Safari's token
        // family when the bundled engine starts.
        environment["PIKPAK_CLIENT_ID"] = PikPakDesktopOAuth.clientID
        environment["PIKPAK_CLIENT_SECRET"] = PikPakDesktopOAuth.clientSecret
        return environment
    }

    private func writePrivateRequest<T: Encodable>(
        _ request: T,
        named prefix: String,
        in directory: URL
    ) throws -> URL {
        let url = directory.appendingPathComponent("\(prefix)-\(UUID().uuidString).json")
        try JSONEncoder().encode(request).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
        return url
    }

    private func requireFreshAppLoginIfSessionTrustFailed(_ error: Error) {
        guard error is LocalCredentialStoreError else { return }
        _ = cancelQuickLook()
        quickLookCopies.removeAll(); quickLookCopyOrder.removeAll()
        fileOpenContext = UUID()
        accountProfile = nil
        fileOpener.reset()
        refreshToken = ""
        requiresDedicatedSignIn = true
        accountLoginStatus = .needsSignIn
        attemptedInitialBrowse = false
        storageQuota = nil
        storageQuotaError = nil
        isQuotaLoading = false
        quotaRefreshPending = false
        presentLogin(
            reason: "The saved session is not an independent desktop session. Sign in here to keep My PikPak for Mac separate from Safari."
        )
    }

    private func makePrivateExchangeDirectory() throws -> URL {
        let directory = try LocalCredentialStore.applicationSupportDirectoryURL()
            .appendingPathComponent("Credential Exchange", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        return directory
    }

    private func cleanupCredentialFiles() {
        if let operationInputURL {
            try? FileManager.default.removeItem(at: operationInputURL)
        }
        operationInputURL = nil
    }

    private func cleanupDownloadInputFile() {
        if let downloadInputURL {
            try? FileManager.default.removeItem(at: downloadInputURL)
        }
        downloadInputURL = nil
    }

    private func cleanupUploadInputFile() {
        if let uploadInputURL {
            try? FileManager.default.removeItem(at: uploadInputURL)
        }
        uploadInputURL = nil
    }

    private func cleanupArchiveInputFile(_ taskID: UUID) {
        if let url = archiveInputURLs.removeValue(forKey: taskID) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func cleanupFolderMeasurementInputFile() {
        if let folderMeasurementInputURL {
            try? FileManager.default.removeItem(at: folderMeasurementInputURL)
        }
        folderMeasurementInputURL = nil
    }

    private func cleanupMergeInputFile() {
        if let mergeInputURL {
            try? FileManager.default.removeItem(at: mergeInputURL)
        }
        mergeInputURL = nil
    }

    private func clearPreview(preservingResourceCacheFor retainedFileID: String? = nil,
                              preservingQuickLook: Bool = false) {
        imagePreview.reset(unlessFileID: retainedFileID)
        textPreviewLoader?.cancel()
        textPreviewLoader = nil
        textPreviewLoadGeneration = UUID()
        if !preservingQuickLook { cancelQuickLookPreparation() }
        previewLoadGeneration = UUID()
        previewPlaybackWasRequested = false
        removePreviewPlayerObservers()
        previewPlayer?.pause()
        previewPlayer = nil
        previewInfo = nil
        previewFileID = nil
        previewSources = []
        previewSourceIndex = 0
        previewPlaybackError = nil
        previewErrorDiagnostic = nil
        previewSourceLabel = nil
        previewText = nil
        previewTextEncodingName = nil
        previewTextLoadedBytes = 0
        previewTextWasTruncated = false
        previewRequiresCompatibilityPlayer = false
        previewCompatibilityPlayerName = nil
        isPreviewLoading = false
        resetPreviewStreamingMetrics(state: .idle)
        // A nil retention target means the preview UI/player is being cleared,
        // not that the selected media changed. Keep its sparse byte cache so a
        // later retry/reselection and backward seeks do not re-download data.
        // Supplying a different file ID is the sole normal cache eviction path.
        if let retainedFileID,
           previewResourceCacheFileID != retainedFileID {
            clearPreviewResourceCaches()
        }
    }

    private func scheduleAutomaticPreview(for item: BrowserItem) {
        #if BROWSER_DROP_TESTS
        if isBrowserDropFixture { return }
        #endif
        #if FILE_SEARCH_TESTS
        if isFileSearchFixture { return }
        #endif
        automaticPreviewTask?.cancel()
        automaticPreviewTask = nil
        automaticPreviewTargetID = nil
        pendingAutomaticPreviewID = nil

        guard item.supportsInlinePreview else {
            setStatus("File selected; use Quick Look to preview this type")
            return
        }

        let fileID = item.id
        automaticPreviewTargetID = fileID
        automaticPreviewTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled, let self else { return }
            self.beginAutomaticPreview(fileID: fileID)
        }
    }

    private func beginAutomaticPreview(fileID: String) {
        guard automaticPreviewTargetID == fileID else { return }
        automaticPreviewTask = nil
        automaticPreviewTargetID = nil
        guard
            selectedBrowserItemID == fileID,
            let item = selectedBrowserItem,
            !item.isFolder,
            item.supportsInlinePreview
        else { return }

        if isRunning {
            if isPreviewEngineRunning {
                pendingAutomaticPreviewID = fileID
                setStatus("Switching preview…")
            }
            return
        }
        requestPreview(for: item)
    }

    private func startPendingAutomaticPreviewIfNeeded() {
        guard let fileID = pendingAutomaticPreviewID else { return }
        pendingAutomaticPreviewID = nil
        guard
            selectedBrowserItemID == fileID,
            previewFileID != fileID,
            let item = selectedBrowserItem,
            !item.isFolder,
            item.supportsInlinePreview
        else { return }
        requestPreview(for: item)
    }

    private func cancelAutomaticPreviewNavigation() {
        automaticPreviewTask?.cancel()
        automaticPreviewTask = nil
        automaticPreviewTargetID = nil
        pendingAutomaticPreviewID = nil
    }

    private func clearFolderMeasurement() {
        folderMeasurement = nil
        measuredFolderID = nil
    }

    private func joinedRemotePath(folder: String, name: String) -> String {
        folder == "/" ? "/\(name)" : "\(folder)/\(name)"
    }

    private struct StructuredAPIError {
        let code: String?
        let message: String?
    }

    private struct EngineErrorPresentation {
        let summary: String
        let diagnostic: AppErrorDiagnostic
    }

    private func engineErrorPresentation(
        _ raw: String,
        operation: Operation?,
        exitCode: Int32?
    ) -> EngineErrorPresentation {
        let lowered = raw.lowercased()
        let fallback = engineErrorFallback(for: operation)
        let apiError = structuredAPIError(from: raw)
        let serviceMessage = apiError?.message

        let summary: String
        if isRejectedSessionError(lowered) {
            summary = "Your PikPak session expired or was rejected. Sign in again to continue."
        } else if lowered.contains("additional verification") || lowered.contains("need verify") {
            summary = "PikPak requires account verification. Complete the sign-in prompt to continue."
        } else if lowered.contains("timed out") || lowered.contains("connect") || lowered.contains("dns") {
            summary = "Could not reach PikPak. Check the network or proxy setting, then try again."
        } else if let serviceMessage {
            summary = "\(fallback) \(serviceMessage)"
        } else if let detail = lastDiagnosticLine(from: raw, maximumLength: 220) {
            summary = "\(fallback) \(detail)"
        } else {
            summary = "\(fallback) See Activity for details."
        }

        let httpStatus = httpStatusCode(from: raw)
        var codes: [String] = []
        if let httpStatus {
            codes.append("HTTP \(httpStatus)")
        }
        if let apiCode = apiError?.code,
           !apiCode.isEmpty,
           apiCode != "0" {
            codes.append("API \(apiCode)")
        }
        if codes.isEmpty, let exitCode {
            codes.append("ENGINE_EXIT_\(exitCode)")
        }
        if codes.isEmpty {
            codes.append("ENGINE_ERROR")
        }

        let diagnosticMessage = serviceMessage
            ?? lastDiagnosticLine(from: raw, maximumLength: 500)
            ?? summary
        let context = exitCode.map { "Engine exit code: \($0)" }
        let source = apiError != nil || httpStatus != nil
            ? "PikPak API"
            : (lowered.contains("http request failed") ? "PikPak network" : "PikPak engine")
        return EngineErrorPresentation(
            summary: summary,
            diagnostic: AppErrorDiagnostic(
                source: source,
                code: codes.joined(separator: " • "),
                message: sanitizedDiagnosticText(diagnosticMessage, maximumLength: 500),
                context: context
            )
        )
    }

    private func engineErrorFallback(for operation: Operation?) -> String {
        switch operation {
        case .browse, .browseTree:
            return "Could not load this PikPak folder."
        case .shareBrowse, .shareBrowseTree:
            return "Could not load this PikPak shared folder."
        case .preview:
            return "Could not prepare this preview."
        case .sharePreview:
            return "Could not prepare this shared-file preview."
        case .archiveInspect:
            return "Could not read this archive on PikPak."
        case .archiveExtract:
            return "PikPak cloud extraction failed."
        case .measure:
            return "Could not calculate this folder's size."
        case .shareMeasure:
            return "Could not calculate this shared folder's size."
        case .shareSave:
            return "Could not save the selected shared items to PikPak."
        case .duplicates:
            return "Could not check this folder for duplicate files."
        case .trash:
            return "Could not move the selected item to PikPak Trash."
        case .undoFiles:
            return "Could not finish Undo/Redo. Its unfinished changes are still available to retry."
        case .trashBrowserItems:
            return "Could not move all selected items to PikPak Trash. Some items may already have moved; refresh the folder before retrying."
        case .moveBrowserItems:
            return "Could not move all selected items. Some earlier batches may already have moved; refresh the affected folders before retrying."
        case .renameItem:
            return "Could not rename the selected PikPak item."
        case .mergeFolders:
            return "Could not finish merging all selected folders. Any source still containing data was kept; refresh the folder to see partial progress before retrying."
        case .createFolder:
            return "Could not create the PikPak folder."
        case .trashDuplicates:
            return "Could not finish moving all selected duplicates to PikPak Trash. Some earlier batches may have succeeded; scan again before retrying."
        case .emptyFolders:
            return "Could not finish removing empty folders. Some earlier batches may already be in PikPak Trash; refresh the folder before retrying."
        case .dsStoreFiles:
            return "Could not finish removing .DS_Store files. Some earlier batches may already be in PikPak Trash; refresh the folder before retrying."
        case .quota:
            return "Could not load PikPak storage information."
        case .download:
            return "The download stopped."
        case .shareDownload:
            return "The shared-link download stopped."
        case .upload:
            return "The upload stopped."
        case .none:
            return "The PikPak operation failed."
        }
    }

    private func structuredAPIError(from raw: String) -> StructuredAPIError? {
        var candidates = raw
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .reversed()
            .map { $0 }
        candidates.append(raw)

        for candidate in candidates {
            guard let openingBrace = candidate.firstIndex(of: "{"),
                  let closingBrace = candidate.lastIndex(of: "}"),
                  openingBrace <= closingBrace else { continue }
            let json = String(candidate[openingBrace...closingBrace])
            guard let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) else {
                continue
            }

            let code = diagnosticJSONValue(
                in: object,
                keys: ["error_code", "errorCode", "code", "status_code"]
            )
            let message = diagnosticJSONValue(
                in: object,
                keys: [
                    "error_description", "errorDescription", "error_message",
                    "message", "share_status_text", "error",
                ]
            )
            if code != nil || message != nil {
                return StructuredAPIError(
                    code: code.map { sanitizedDiagnosticText($0, maximumLength: 80) },
                    message: message.map { sanitizedDiagnosticText($0, maximumLength: 500) }
                )
            }
        }
        return nil
    }

    private func diagnosticJSONValue(in object: Any, keys: [String]) -> String? {
        if let dictionary = object as? [String: Any] {
            for key in keys {
                guard let value = dictionary[key] else { continue }
                if let string = value as? String {
                    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty { return trimmed }
                } else if let number = value as? NSNumber {
                    return number.stringValue
                }
            }
            for value in dictionary.values {
                if let nested = diagnosticJSONValue(in: value, keys: keys) {
                    return nested
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let nested = diagnosticJSONValue(in: value, keys: keys) {
                    return nested
                }
            }
        }
        return nil
    }

    private func httpStatusCode(from raw: String) -> String? {
        let pattern = #"(?i)(?:API\s+error|HTTP(?:\s+status)?|status)\s*[:=]?\s*(\d{3})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: raw,
                  range: NSRange(raw.startIndex..., in: raw)
              ),
              let range = Range(match.range(at: 1), in: raw)
        else { return nil }
        return String(raw[range])
    }

    private func lastDiagnosticLine(from raw: String, maximumLength: Int) -> String? {
        let line = redactedEngineOutput(raw)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .last { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let line else { return nil }
        return sanitizedDiagnosticText(line, maximumLength: maximumLength)
    }

    private func diagnostic(
        for error: Error,
        source: String? = nil,
        fallbackCode: String? = nil
    ) -> AppErrorDiagnostic {
        let nsError = error as NSError
        return AppErrorDiagnostic(
            source: source ?? nsError.domain,
            code: fallbackCode ?? "\(nsError.domain) \(nsError.code)",
            message: sanitizedDiagnosticText(nsError.localizedDescription, maximumLength: 500),
            context: fallbackCode == nil ? nil : "System code: \(nsError.domain) \(nsError.code)"
        )
    }

    private func sanitizedDiagnosticText(_ raw: String, maximumLength: Int) -> String {
        let collapsed = redactedEngineOutput(raw)
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        guard collapsed.count > maximumLength else { return collapsed }
        return String(collapsed.prefix(maximumLength)) + "…"
    }

    private func redactedEngineOutput(_ raw: String) -> String {
        var safe = raw
        let token = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            safe = safe.replacingOccurrences(of: token, with: "[credential redacted]")
        }
        safe = safe.replacingOccurrences(
            of: #"(?i)(\"?(?:access_token|refresh_token|authorization)\"?\s*[:=]\s*\"?)[^\",\s}]+"#,
            with: "$1[credential redacted]",
            options: .regularExpression
        )
        return safe.replacingOccurrences(
            of: #"https?://[^\s"\x27)\]},]+"#,
            with: "[URL redacted]",
            options: .regularExpression
        )
    }

    private func webLoginReason(for raw: String) -> String? {
        let lowered = raw.lowercased()
        if isRejectedSessionError(lowered) {
            return "Your saved PikPak session expired or was rejected. Sign in again and the app will replace it automatically."
        }
        if lowered.contains("additional verification") || lowered.contains("need verify") {
            return "PikPak requires account verification. Complete the official sign-in prompt, then the app will continue automatically."
        }
        return nil
    }

    private func isRejectedSessionError(_ lowered: String) -> Bool {
        lowered.contains("invalid_grant")
            || lowered.contains("error_code\":4126")
            || lowered.contains("error_code: 4126")
            || lowered.contains("status 400") && lowered.contains("authentication")
            || lowered.contains("status 401") && lowered.contains("authentication")
            || lowered.contains("refresh token")
                && (lowered.contains("invalid")
                    || lowered.contains("expired")
                    || lowered.contains("rejected"))
    }

    private func handleWebLoginNeeded(for raw: String) {
        guard let reason = webLoginReason(for: raw) else { return }
        if isRejectedSessionError(raw.lowercased()) {
            presentCleanLoginAfterRejectedSession(reason: reason)
        } else {
            presentLogin(reason: reason)
        }
    }

    private func presentCleanLoginAfterRejectedSession(reason: String) {
        clearPendingFolderMeasurements()
        if isRunning
            || sharedLinkLoadProcesses.values.contains(where: { $0.isRunning })
            || sharedSaveProcesses.values.contains(where: { $0.isRunning })
            || downloadProcess?.isRunning == true
            || uploadProcess?.isRunning == true
            || duplicateProcess?.isRunning == true
            || maintenanceProcess?.isRunning == true
            || mergeProcess?.isRunning == true
            || archiveProcesses.values.contains(where: { $0.isRunning })
            || folderMeasurementProcess?.isRunning == true {
            deferredLoginRequiresCleanStart = true
            presentLogin(reason: reason)
            return
        }
        // Never put a rejected refresh token back into the login page. Remove
        // the app-owned desktop token chain and wait for the disposable WebKit
        // broker data to finish clearing before a fresh page is created.
        refreshToken = ""
        requiresDedicatedSignIn = true
        accountLoginStatus = .needsSignIn
        accountLoginTargetID = activeAccountID
        attemptedInitialBrowse = false
        storageQuota = nil
        storageQuotaError = nil
        isQuotaLoading = false
        quotaRefreshPending = false
        isLoginPresented = false
        deferredLoginRequiresCleanStart = false
        do {
            if let accountStore, let activeAccountID {
                applyAccounts(try accountStore.logOut(activeAccountID, deactivate: false))
            } else { try SessionStore.deleteToken() }
        } catch {
            appendOutput(
                "Warning: expired local session could not be completely removed: \(error.localizedDescription)\n"
            )
        }
        setStatus("Preparing a clean PikPak sign-in…")
        PikPakLoginDataStore.clearPikPakWebsiteData { [weak self] in
            guard let self else { return }
            self.loginReason = reason
            self.isLoginPresented = true
        }
    }

    private func presentLogin(reason: String, fromSettings: Bool = false) {
        guard !isClosingWindow else { return }
        failPendingSharedLinkLoads(message: "Sign in, then retry this link.")
        loginFromSettings = fromSettings
        if !loginFromSettings {
            accountLoginTargetID = activeAccountID
            if accountLoginDeviceID == nil {
                accountLoginDeviceID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            }
        }
        clearPendingFolderMeasurements()
        if isRunning {
            deferredLoginReason = reason
            setStatus("Finishing the current browser request before secure sign-in…")
            return
        }
        let runningSharedLinkLoads = sharedLinkLoadProcesses.filter { $0.value.isRunning }
        if !runningSharedLinkLoads.isEmpty {
            deferredLoginReason = reason
            sharedLinkLoadsStoppedForLogin.formUnion(runningSharedLinkLoads.keys)
            for process in runningSharedLinkLoads.values {
                process.terminate()
            }
            setStatus("Stopping shared-link requests before secure sign-in…")
            return
        }
        let runningSharedSaves = sharedSaveProcesses.filter { $0.value.isRunning }
        if !runningSharedSaves.isEmpty {
            deferredLoginReason = reason
            sharedSavesStoppedForLogin.formUnion(runningSharedSaves.keys)
            for process in runningSharedSaves.values {
                process.terminate()
            }
            setStatus("Stopping shared saves before secure sign-in…")
            return
        }
        if let downloadProcess, downloadProcess.isRunning {
            deferredLoginReason = reason
            downloadRequestedStop = true
            downloadRunState = .stopping
            downloadProcess.terminate()
            setStatus("Stopping the download before secure sign-in…")
            return
        }
        if let uploadProcess, uploadProcess.isRunning {
            deferredLoginReason = reason
            uploadRequestedStop = true
            if isUploadPaused {
                _ = uploadProcess.resume()
                isUploadPaused = false
            }
            uploadRunState = .stopping
            uploadProcess.terminate()
            setStatus("Stopping the upload before secure sign-in…")
            return
        }
        if let duplicateProcess, duplicateProcess.isRunning {
            deferredLoginReason = reason
            duplicateScanWasCancelled = true
            duplicateProcess.terminate()
            setStatus("Stopping the duplicate scan before secure sign-in…")
            return
        }
        if let maintenanceProcess, maintenanceProcess.isRunning {
            deferredLoginReason = reason
            maintenanceWasCancelled = true
            maintenanceProcess.terminate()
            setStatus("Stopping the maintenance scan before secure sign-in…")
            return
        }
        if let mergeProcess, mergeProcess.isRunning {
            deferredLoginReason = reason
            mergeWasCancelled = true
            mergeProcess.terminate()
            setStatus("Stopping the folder merge before secure sign-in…")
            return
        }
        if archiveProcesses.values.contains(where: { $0.isRunning }) {
            deferredLoginReason = reason
            for (id, child) in archiveProcesses where child.isRunning {
                stoppedArchiveTaskIDs.insert(id)
                child.terminate()
            }
            setStatus("Stopping archive helpers before secure sign-in…")
            return
        }
        if let folderMeasurementProcess, folderMeasurementProcess.isRunning {
            deferredLoginReason = reason
            folderMeasurementWasCancelled = true
            folderMeasurementProcess.terminate()
            setStatus("Stopping folder-size calculation before secure sign-in…")
            return
        }
        loginReason = reason
        isLoginPresented = true
    }

    private func presentDeferredLoginIfNeeded() {
        guard let reason = deferredLoginReason else { return }
        let requiresCleanStart = deferredLoginRequiresCleanStart
        deferredLoginReason = nil
        deferredLoginRequiresCleanStart = false
        if requiresCleanStart {
            presentCleanLoginAfterRejectedSession(reason: reason)
        } else {
            presentLogin(reason: reason)
        }
    }

    private func appendOutput(_ text: String) {
        var safeText = text.replacingOccurrences(of: "\r", with: "\n")
        let token = refreshToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !token.isEmpty {
            safeText = safeText.replacingOccurrences(of: token, with: "[credential redacted]")
        }
        log.append(safeText)

        // A capped text log prevents this GUI from repeating PikPak's own
        // thousands-of-rows renderer failure on very large folder downloads.
        let maximumCharacters = 120_000
        let retainedCharacters = 90_000
        if log.count > maximumCharacters {
            log = "… older activity trimmed …\n" + String(log.suffix(retainedCharacters))
        }
    }

    private func setStatus(_ message: String) {
        status = message
        statusIsError = false
        statusErrorDiagnostic = nil
    }

    private func taskKind(for operation: Operation?) -> FinderTaskKind? {
        switch operation {
        case .emptyFolders: return .emptyFolders
        case .dsStoreFiles: return .dsStore
        default: return nil
        }
    }

    private func publishDuplicateActivity() {
        let message: String
        if duplicateRetryAttempt > 0 {
            message = "Retrying folder request \(duplicateRetryAttempt) of \(duplicateRetryMaxAttempts)…"
        } else {
            message = "Checking duplicates: \(duplicateScannedFiles.formatted()) files in \(duplicateScannedFolders.formatted()) folders…"
        }
        var detail = "\(duplicatePendingFolders.formatted()) folders queued"
        if duplicateFailedFolders > 0 { detail += " · \(duplicateFailedFolders.formatted()) unavailable" }
        if duplicateRetryInMillis > 0 { detail += " · Retry in \(String(format: "%.1f", Double(duplicateRetryInMillis) / 1000))s" }
        if !duplicateCurrentPath.isEmpty { detail += "\n" + duplicateCurrentPath }
        taskActivity.update(.duplicates, message: message, detail: detail)
    }

    private func setMaintenanceStatus(_ message: String) {
        maintenanceStatus = message
        if let kind = taskKind(for: maintenanceOperation) {
            let detail = kind == .emptyFolders
                ? "\(emptyFolderScannedFolders.formatted()) folders scanned · \(emptyFolderCandidateCount.formatted()) candidates · \(emptyFolderRemovedFolders.formatted()) removed\n\(emptyFolderCurrentPath)"
                : "Checking descendant folders; only exact .DS_Store filenames are removed."
            taskActivity.update(kind, message: message, detail: detail)
        } else if !isRunning {
            setStatus(message)
        }
    }

    private func setError(
        _ message: String,
        diagnostic: AppErrorDiagnostic? = nil
    ) {
        status = message
        statusIsError = true
        statusErrorDiagnostic = diagnostic
    }
}

#if FOLDER_EXPANSION_TESTS
extension DownloaderModel {
    /// Synthetic listings and inert Process records exercise the real Browser
    /// scheduler. This fixture never reads credentials, persists link state,
    /// launches the engine, or touches the user's cloud data.
    static func testBrowserFolderExpansion() async throws {
        func item(_ id: String, folder: Bool = true) -> BrowserItem {
            BrowserItem(id: id, name: id, size: folder ? 0 : 42, kind: folder ? .folder : .file,
                        parentId: nil, mimeType: nil, createdTime: nil, modifiedTime: nil,
                        fileExtension: nil, iconLink: nil, thumbnailLink: nil,
                        fileCategory: nil, hash: nil, md5Checksum: nil)
        }
        let root = item("Root"), a = item("A"), b = item("B"), c = item("C"), other = item("Other")
        func fixture() -> DownloaderModel {
            let model = DownloaderModel(folderExpansionFixture: true)
            model.browserItems = [root, other]
            model.registerBrowserItems(model.browserItems, parentID: "", parentPath: "/")
            model.isDownloading = true
            model.isUploading = true // Also avoids unrelated size-cache reconciliation.
            return model
        }
        func drain() async {
            for _ in 0..<8 { await Task.yield() }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        func finish(_ model: DownloaderModel, _ id: String, files: [BrowserItem] = [],
                    next: String = "", error: Bool = false, staleGeneration: UUID? = nil) throws {
            let request = model.recordedExpansionLoads.last { $0.id == id }!
            let data = try JSONSerialization.data(withJSONObject: [
                "files": files.map { ["id": $0.id, "name": $0.name,
                                      "size": 42, "kind": $0.isFolder ? "drive#folder" : "drive#file"] },
                "next_page_token": next, "share_id": "fixture", "pass_code_token": "",
                "parent_id": id, "folder_name": id,
            ])
            model.finishBrowserTreeHelper(generation: staleGeneration ?? request.generation,
                folderID: id, folderName: id, folderPath: "/\(id)", append: request.append,
                isShared: model.isBrowsingSharedLink, sizeRevision: model.folderSizeRevision,
                exitCode: error ? 1 : 0, structuredOutput: String(decoding: data, as: UTF8.self),
                errorOutput: error ? "Offline listing failure" : "")
        }

        for levels in [1, 2] {
            let model = fixture()
            model.browserTreeChildren = [root.id: [a], a.id: [b], b.id: [c], c.id: [], other.id: []]
            model.expandedBrowserFolderIDs = [other.id, c.id]
            model.selectedBrowserItemIDs = [other.id]
            model.selectedBrowserItemID = other.id
            model.expandBrowserSubfolders(root, levels: levels)
            await drain()
            let expected: Set<String> = levels == 1 ? [root.id, a.id, other.id, c.id] : [root.id, a.id, b.id, other.id, c.id]
            precondition(model.expandedBrowserFolderIDs == expected, "exact requested depth; keep already-open branches")
            precondition(model.recordedExpansionLoads.isEmpty && model.browserFolderExpansionProgress == nil)
            precondition(model.selectedBrowserItemIDs == [other.id] && model.selectedBrowserItemID == other.id)
            precondition(model.isDownloading && model.isUploading && !model.isRunning && model.canBrowse)
        }
        print("PASS model: cached 1/2-level expansion, stable selection/disclosures, concurrent upload/download availability")

        let deep = fixture()
        deep.browserTreeChildren = [root.id: [a], a.id: [b], b.id: [c], c.id: []]
        deep.expandBrowserSubfolders(root, levels: nil)
        await drain()
        precondition(deep.expandedBrowserFolderIDs == [root.id, a.id, b.id, c.id])
        let large = fixture()
        let manyFolders = (0..<2_048).map { item("Cached \($0)") }
        large.browserTreeChildren = Dictionary(uniqueKeysWithValues: manyFolders.map { ($0.id, [BrowserItem]()) })
        large.browserTreeChildren[root.id] = manyFolders
        large.expandBrowserSubfolders(root)
        precondition(large.expandedBrowserFolderIDs.isEmpty && large.browserFolderExpansionProgress != nil,
                     "starting expansion yields immediately instead of blocking on cached recursion")
        for _ in 0..<100 where large.browserFolderExpansion != nil { await drain() }
        precondition(large.expandedBrowserFolderIDs.count == 2_049 && large.browserFolderExpansion == nil)
        precondition(large.recordedExpansionLoads.isEmpty)
        print("PASS model: all levels, 2,049 cached folders, asynchronous bounded UI batches without re-fetching")

        let paged = fixture()
        paged.expandBrowserSubfolders(root)
        await drain()
        let children = (0..<6).map { item("Folder \($0)") }
        let files = (0..<494).map { item("File \($0).txt", folder: false) }
        try finish(paged, root.id, files: files + children, next: "root-page-2")
        await drain()
        precondition(paged.browserTreeLoadProcesses.count == 4, "fill all four listing slots")
        precondition(!paged.pendingBrowserTreeLoads.isEmpty && paged.browserTreeLoadingFolderIDs.count > 4)
        var iteration = 0
        while paged.browserFolderExpansion != nil {
            iteration += 1
            precondition(iteration < 100, "expansion must settle")
            precondition(paged.browserTreeLoadProcesses.count <= 4, "bounded independent helper concurrency")
            for id in Array(paged.browserTreeLoadGenerations.keys) {
                let request = paged.recordedExpansionLoads.last { $0.id == id }!
                if id == root.id {
                    precondition(request.token == "root-page-2")
                    try finish(paged, id, files: [children[0], item("Late Folder")])
                } else if id == children[0].id && !request.append {
                    try finish(paged, id, files: (0..<500).map { item("Nested \($0).txt", folder: false) }, next: "child-page-2")
                } else if id == children[0].id {
                    try finish(paged, id, files: [item("Grandchild")])
                } else {
                    try finish(paged, id, error: id == children[5].id)
                }
            }
            await drain()
        }
        precondition(paged.browserTreeChildren[root.id]?.count == 501, "all pages and no duplicated folder entries")
        precondition(paged.browserTreeChildren[children[0].id]?.count == 501, "paginate boundary-level folders too")
        precondition(paged.expandedBrowserFolderIDs.contains("Late Folder"))
        precondition(!paged.expandedBrowserFolderIDs.contains("Grandchild"), "stop expansion at requested depth")
        precondition(paged.browserTreeLoadErrors[children[5].id] != nil && paged.statusIsError)
        precondition(paged.browserTreeLoadingFolderIDs.isEmpty && paged.pendingBrowserTreeLoads.isEmpty)
        print("PASS model: multi-page roots and children, late folders, four parallel helpers, loading states, partial failures")

        let cancelled = fixture()
        cancelled.toggleBrowserFolderExpansion(other)
        cancelled.expandBrowserSubfolders(root, levels: nil)
        await drain()
        let oldGeneration = cancelled.browserTreeLoadGenerations[root.id]!
        cancelled.cancelBrowserFolderExpansion()
        precondition(cancelled.browserTreeLoadGenerations[other.id] != nil, "Cancel never cancels a manual browse")
        precondition(cancelled.browserTreeLoadGenerations[root.id] == nil && cancelled.expandedBrowserFolderIDs.contains(root.id))
        cancelled.expandBrowserSubfolders(root)
        await drain()
        let newGeneration = cancelled.browserTreeLoadGenerations[root.id]!
        try finish(cancelled, root.id, files: [item("Stale")], staleGeneration: oldGeneration)
        precondition(cancelled.browserTreeChildren[root.id] == nil)
        precondition(cancelled.browserTreeLoadGenerations[root.id] == newGeneration, "old completion cannot clear new spinner")
        cancelled.toggleBrowserFolderExpansion(root)
        precondition(cancelled.browserFolderExpansion == nil && !cancelled.expandedBrowserFolderIDs.contains(root.id))
        try finish(cancelled, root.id, files: [item("Late")], staleGeneration: newGeneration)
        precondition(cancelled.browserTreeChildren[root.id] == nil, "collapse stays collapsed after late reply")
        cancelled.cancelBrowserTreeLoads()
        print("PASS model: Cancel, collapsed branches, unrelated manual requests, replacement generations and late callbacks")

        let repeated = fixture()
        repeated.browserTreeChildren[root.id] = []
        repeated.browserTreeNextPageTokens[root.id] = "repeated"
        repeated.expandBrowserSubfolders(root)
        await drain()
        try finish(repeated, root.id, next: "repeated")
        await drain()
        precondition(repeated.browserFolderExpansion == nil && repeated.recordedExpansionLoads.count == 1)
        precondition(repeated.browserTreeLoadErrors[root.id]?.contains("repeated") == true)

        let links = fixture()
        links.browserSource = .sharedLink
        links.shareLinkIsOpen = true
        let firstID = UUID(), secondID = UUID()
        links.saveActiveBrowserWorkspace()
        let workspace = links.sharedBrowserWorkspace!
        for id in [firstID, secondID] {
            let access = ShareAccessInput(url: "https://mypikpak.com/s/fixture-\(id)", passCode: "", passCodeToken: "")
            links.sharedLinks.append(SharedLinkEntry(id: id, url: access.url, name: "Fixture", state: .ready, savedItemCount: 0, addedAt: Date()))
            links.sharedLinkSessions[id] = SharedLinkSession(access: access, workspace: workspace, savedItemIDs: [])
        }
        links.activateSharedLink(firstID)
        links.expandBrowserSubfolders(root)
        await drain()
        let firstGeneration = links.browserTreeLoadGenerations[root.id]!
        links.activateSharedLink(secondID)
        precondition(links.browserFolderExpansion == nil)
        precondition(links.sharedLinkSessions[firstID]?.workspace?.expandedFolderIDs.contains(root.id) == true)
        links.expandBrowserSubfolders(root)
        await drain()
        try finish(links, root.id, files: [item("Wrong Link")], staleGeneration: firstGeneration)
        precondition(links.browserTreeChildren[root.id] == nil)
        try finish(links, root.id, files: [])
        await drain()
        precondition(links.browserFolderExpansion == nil && links.browserTreeChildren[root.id] == [])
        print("PASS model: repeated-token termination, shared-link scope, preserved workspace, no cross-link results or persistence")
    }
}
#endif

#if FINDER_WORKSPACE_TESTS
extension DownloaderModel {
    static func workspaceSwitchFixture(count: Int = 50_000) -> DownloaderModel {
        let model = finderWorkspaceFixture()
        model.populateScrollingFixture(count: count)
        model.applyBrowserSortToCachedItems()
        model.saveActiveBrowserWorkspace()
        model.populateScrollingFixture(count: count, links: true)
        model.applyBrowserSortToCachedItems()
        model.saveActiveBrowserWorkspace()
        _ = model.activateAccountBrowser()
        return model
    }

    static func testWorkspacePresentation() throws {
        let model = workspaceSwitchFixture(count: 5_000)
        let original = model.browserTreeEntries.map(\.id)
        precondition(model.workspaceSwitchNeedsLoading(to: 0) && model.workspaceSwitchNeedsLoading(to: 3))
        precondition(!model.workspaceSwitchNeedsLoading(to: 1))
        precondition(model.activateSharedLinkBrowser())
        let first = model.sharedLinks[0].id
        let firstEntries = model.sharedLinkTreeEntries(for: first).map(\.id)
        model.setSharedLinkExpanded(first, expanded: false)
        precondition(!model.isSharedLinkExpanded(first))
        model.setSharedLinkExpanded(first, expanded: true)
        precondition(model.isSharedLinkExpanded(first) && model.sharedLinkTreeEntries(for: first).map(\.id) == firstEntries)
        model.browserSortDirection = .descending
        model.applyBrowserSortToCachedItems()
        for link in model.sharedLinks.prefix(3) {
            let files = model.sharedLinkTreeEntries(for: link.id).filter { !$0.item.isFolder }.map(\.item.name)
            precondition(files == files.sorted { $0.localizedStandardCompare($1) == .orderedDescending },
                "sort changes update inactive links as well as the active one")
        }
        precondition(model.activateAccountBrowser())
        let descending = model.browserTreeEntries.map(\.id)
        precondition(descending != original && Set(descending) == Set(original), "restored account follows the new sort")
        model.browserSortDirection = .ascending
        model.applyBrowserSortToCachedItems()
        precondition(model.browserTreeEntries.map(\.id) == original)
        model.browserItems = Array(model.browserItems.dropLast())
        precondition(model.browserTreeEntries.count == original.count - 1, "a changed listing invalidates the outline")
        model.saveActiveBrowserWorkspace()
        let encoded = try JSONEncoder().encode(model.accountBrowserWorkspace!)
        precondition(!String(decoding: encoded, as: UTF8.self).contains("presentation"))
        let decoded = try JSONDecoder().decode(BrowserWorkspaceSnapshot.self, from: encoded)
        precondition(decoded.presentation.entries == nil && decoded.presentation.sortRevision == nil,
            "persisted workspaces remain backward compatible and rebuild runtime caches")
        model.restoreBrowserWorkspace(decoded)
        precondition(model.browserTreeEntries.count == original.count - 1)
        let small = finderWorkspaceFixture()
        precondition(!small.workspaceSwitchNeedsLoading(to: 0) && !small.workspaceSwitchNeedsLoading(to: 3))
        small.expandedSharedLinkIDs = Set(small.sharedLinks.map(\.id))
        let scoped = small.sharedLinks.flatMap { link in
            small.sharedLinkTreeEntries(for: link.id).map { "\(link.id.uuidString)|\($0.id)" }
        }
        precondition(scoped.count == Set(scoped).count, "identical file IDs in different links have distinct rows")
        small.browserItems = []; small.browserTreeChildren = [:]; small.expandedBrowserFolderIDs = []
        precondition(small.browserTreeEntries.isEmpty)
        print("PASS workspace caches: sort changes, inactive links, changed listings, collapse/expand, scoped row identities, legacy persistence and loading thresholds")
    }

    static func reportWorkspaceSwitchPerformance() {
        for count in [5_000, 50_000] {
            let model = workspaceSwitchFixture(count: count)
            _ = model.browserTreeEntries
            for link in model.sharedLinks { _ = model.sharedLinkTreeEntries(for: link.id) }
            var browserTimes: [Double] = [], linkTimes: [Double] = [], rowTimes: [Double] = []
            var checksum = 0
            for _ in 0..<6 {
                _ = model.activateSharedLinkBrowser()
                var began = ProcessInfo.processInfo.systemUptime
                precondition(model.activateAccountBrowser())
                browserTimes.append((ProcessInfo.processInfo.systemUptime - began) * 1000)
                began = ProcessInfo.processInfo.systemUptime
                precondition(model.activateSharedLinkBrowser())
                linkTimes.append((ProcessInfo.processInfo.systemUptime - began) * 1000)
                began = ProcessInfo.processInfo.systemUptime
                for _ in 0..<10 {
                    checksum += model.browserTreeEntries.count
                    for link in model.sharedLinks { checksum += model.sharedLinkTreeEntries(for: link.id).count }
                }
                rowTimes.append((ProcessInfo.processInfo.systemUptime - began) * 1000 / 10)
            }
            func mean(_ values: [Double]) -> Double { values.reduce(0,+) / Double(values.count) }
            print(String(format: "items=%d switch_to_browser_ms=%.2f switch_to_links_ms=%.2f links_row_preparation_ms=%.2f checksum=%d",
                count, mean(browserTimes), mean(linkTimes), mean(rowTimes), checksum))
        }
    }

    static func finderAccountsFixture() throws -> DownloaderModel {
        let model = finderWorkspaceFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pikpak-accounts-fixture-\(UUID().uuidString)")
        let store = try PikPakAccountStore(directory: directory)
        let a = try store.stage(token: "fixture-account-a", deviceID: String(repeating: "a", count: 32))
        let profileA = PikPakAccountProfile(sub: "offline-account-a", name: "Taylor Chen")
        _ = try store.commit(a, profile: profileA, checkedAt: Date())
        let b = try store.stage(token: "fixture-account-b", deviceID: String(repeating: "b", count: 32))
        _ = try store.commit(b, profile: .init(sub: "offline-account-b", name: "Jordan Lee"), checkedAt: Date())
        model.accountStore = store
        model.accountFixtureTransferDirectory = directory.appendingPathComponent("Transfers")
        model.applyAccounts(try store.activate(a.id))
        model.adoptTransferAccount(profileA.sub)
        model.accountProfile = profileA
        model.refreshToken = try a.load().token
        model.deviceID = try a.load().deviceID
        model.accountLoginStatus = .signedIn
        model.accountProfileLoader = { files in
            try await Task.sleep(nanoseconds: 30_000_000)
            let token = try files.load().token
            if token == "fixture-account-a" { return profileA }
            if token == "fixture-account-b" { return .init(sub: "offline-account-b", name: "Jordan Lee") }
            return .init(sub: "offline-account-c", name: "Alex Morgan")
        }
        return model
    }

    static func testAccountManagement() async throws {
        func require(_ condition: Bool, _ message: String) { precondition(condition, message) }
        let model = try finderAccountsFixture()
        let store = model.accountStore!
        defer { try? FileManager.default.removeItem(at: store.directory) }
        let idA = model.activeAccountID!
        let idB = model.savedAccounts.first { $0.id != idA }!.id
        let loader = model.accountProfileLoader
        let queueID = UUID()
        model.queueDownload(.account(roots: [.init(queueID: queueID, path: "/Report A.txt", name: "Report A.txt", kind: .file, file: nil, relativeParent: [])],
            destination: store.directory.appendingPathComponent("Downloads"), jobs: 32, proxyURL: ""))
        model.isDownloading = true
        model.switchAccount(to: idB)
        model.logOutAccount()
        require(model.activeAccountID == idA && model.accountCheckTask == nil, "busy transfers prevent switching and logout")
        model.isDownloading = false
        model.checkAccountStatus()
        await model.accountCheckTask?.value
        require(model.accountLoginStatus == .signedIn && model.accountProfile?.sub == "offline-account-a", "live status refresh")
        let environmentA = try model.engineEnvironment()
        model.switchAccount(to: idB)
        await model.accountCheckTask?.value
        require(model.activeAccountID == idB && model.accountProfile?.sub == "offline-account-b", "verified account switch")
        require(model.pendingDownloadItems.isEmpty, "another account cannot see the old account's queued download")
        require(model.browserItems.isEmpty && model.selectedBrowserItemIDs.isEmpty && model.storageQuota == nil,
                "old account files, selection and quota cleared")
        require(model.sharedLinks.allSatisfy { $0.savedItemCount == 0 } && model.sharedLinkSessions.values.allSatisfy { $0.savedItemIDs.isEmpty && $0.workspace == nil },
                "shared-link account state cannot leak across accounts")
        let environmentB = try model.engineEnvironment()
        require(environmentA["PIKPAK_REFRESH_TOKEN_FILE"] != environmentB["PIKPAK_REFRESH_TOKEN_FILE"] && environmentA["PIKPAK_REFRESH_TOKEN_LOCK_FILE"] != environmentB["PIKPAK_REFRESH_TOKEN_LOCK_FILE"], "worker paths follow the selected account")
        model.switchAccount(to: idA)
        await model.accountCheckTask?.value
        require(model.pendingDownloadItems.map(\.id) == [queueID] && !model.isDownloading, "switching back restores the queue without starting it")
        model.switchAccount(to: idB)
        await model.accountCheckTask?.value
        model.accountProfileLoader = { _ in throw PikPakAccountError.unavailable }
        model.switchAccount(to: idA)
        await model.accountCheckTask?.value
        require(model.activeAccountID == idB && model.accountProfile?.sub == "offline-account-b", "network failure preserves the current account")
        model.accountProfileLoader = { _ in .init(sub: "wrong-account", name: "Wrong") }
        model.switchAccount(to: idA)
        await model.accountCheckTask?.value
        require(model.activeAccountID == idB, "mismatched identity is never activated")
        model.accountProfileLoader = { _ in
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return .init(sub: "offline-account-a", name: "Taylor Chen")
        }
        model.switchAccount(to: idA)
        let cancelled = model.accountCheckTask
        model.cancelAccountCheck()
        await cancelled?.value
        require(model.activeAccountID == idB && !model.isChangingAccount, "cancelled switch leaves the current account")
        model.accountProfileLoader = { _ in throw PikPakAccountError.needsSignIn }
        model.switchAccount(to: idA)
        await model.accountCheckTask?.value
        require(model.activeAccountID == idB && model.savedAccounts.first(where: { $0.id == idA })?.needsSignIn == true,
                "expired inactive account prompts sign-in without logging out the current account")
        model.accountProfileLoader = loader
        model.completeWebLogin(with: .init(refreshToken: "fixture-account-c", deviceID: String(repeating: "c", count: 32)))
        await model.accountCheckTask?.value
        require(model.savedAccounts.count == 3 && model.accountProfile?.sub == "offline-account-c", "new login adds an account and preserves the others")
        let idC = model.activeAccountID!
        model.logOutAccount()
        require(model.activeAccountID == nil && !model.hasAccountSession && model.accountLoginStatus == .signedOut, "logout state")
        require(!FileManager.default.fileExists(atPath: store.files(for: idC).tokenURL.path), "logout removes that account's token")
        require(try store.files(for: idB).load().token == "fixture-account-b", "logout keeps other saved sessions")
        model.switchAccount(to: idB)
        await model.accountCheckTask?.value
        require(model.activeAccountID == idB && model.hasAccountSession, "switch from a logged-out state")
        model.accountProfileLoader = { _ in throw PikPakAccountError.missingSession }
        model.checkAccountStatus()
        await model.accountCheckTask?.value
        require(model.accountLoginStatus == .needsSignIn && !model.hasAccountSession,
                "missing saved credentials prompt sign-in")
        model.loginFromSettings = true
        model.presentLogin(reason: "Synthetic browser request needs sign-in")
        require(!model.loginFromSettings && model.isLoginPresented, "browser login returns to the main window after using Settings")
        model.cancelLogin()
        model.isClosingWindow = true
        require(!model.canChangeAccount && !model.canCheckAccountStatus, "closed workspace cannot start account changes")
        print("PASS accounts: status check, busy-task guards, session/worker isolation, workspace clearing, failed/cancelled/mismatched/expired switches, add account and logout")
    }

    func populateScrollingFixture(count: Int, links: Bool = false) {
        precondition(isFinderWorkspaceFixture)
        finderSettings.showsPreviewPane = false
        browserStack = [.root]
        selectedBrowserItemID = nil
        selectedBrowserItemIDs = []
        browserTreeChildren = [:]
        expandedBrowserFolderIDs = []
        browserItemPaths = [:]
        browserItemParentIDs = [:]
        browserItems = (0..<count).map { index in
            let folder = index.isMultiple(of: 5)
            let name = String(format: folder ? "Project %05d" : "Report %05d.txt", index)
            return BrowserItem(id: "fixture-\(index)", name: name, size: folder ? 0 : 24_576,
                kind: folder ? .folder : .file, parentId: "", mimeType: folder ? nil : "text/plain",
                createdTime: "2026-09-01T10:00:00Z", modifiedTime: "2026-09-08T01:00:00Z",
                fileExtension: folder ? nil : "txt", iconLink: nil, thumbnailLink: nil,
                fileCategory: nil, hash: nil, md5Checksum: nil)
        }
        registerBrowserItems(browserItems, parentID: "", parentPath: "/")
        finderFixtureFolders = ["": browserItems]
        status = "Offline scrolling fixture · \(count.formatted()) rows · no network or transfers"
        if links {
            let allItems = browserItems
            sharedLinks = []
            sharedLinkSessions = [:]
            expandedSharedLinkIDs = []
            let perLink = max(1, (count + 101) / 102)
            for index in 0..<102 {
                let id = UUID()
                let url = "https://mypikpak.com/s/offline-scroll-\(index)"
                let items = Array(allItems.dropFirst(index * perLink).prefix(perLink))
                sharedLinks.append(.init(id: id, url: url, name: String(format: "Example Link %03d", index + 1),
                    state: .ready, savedItemCount: 0, addedAt: Date()))
                sharedLinkSessions[id] = SharedLinkSession(
                    access: ShareAccessInput(url: url, passCode: "", passCodeToken: ""),
                    workspace: BrowserWorkspaceSnapshot(items: items, stack: [.sharedRoot], nextPageToken: nil,
                        expandedFolderIDs: [], childrenByFolderID: [:], loadErrors: [:], selectedItemID: nil,
                        selectedItemIDs: [], selectionAnchorID: nil, folderSnapshots: [:], childPageTokens: [:],
                        itemPaths: Dictionary(items.map { ($0.id, "/\($0.name)") }, uniquingKeysWith: { _, new in new }),
                        parentIDs: Dictionary(items.map { ($0.id, "") }, uniquingKeysWith: { _, new in new })), savedItemIDs: [])
                expandedSharedLinkIDs.insert(id)
            }
            browserSource = .sharedLink
            activeSharedLinkID = sharedLinks.first?.id
            if let activeSharedLinkID, let session = sharedLinkSessions[activeSharedLinkID] {
                browserItems = session.workspace?.items ?? []
                browserItemPaths = session.workspace?.itemPaths ?? [:]
                browserItemParentIDs = session.workspace?.parentIDs ?? [:]
                shareAccess = session.access
            }
            browserStack = [.sharedRoot]
            shareLinkIsOpen = true
        }
    }

    func setResourceScanFixture(_ child: Process, files: Int, folders: Int, path: String) {
        precondition(isFinderWorkspaceFixture)
        duplicateProcess = child
        isScanningDuplicates = child.isRunning
        duplicateScannedFiles = files
        duplicateScannedFolders = folders
        duplicateScanRootPath = "/Projects"
        duplicateCurrentPath = path
    }

    /// Identical folder IDs in two synthetic shares exercise the production
    /// selection and request routing without credentials or a bundled engine.
    static func sharedSelectionFixture(defaults: UserDefaults) -> DownloaderModel {
        let model = finderWorkspaceFixture(defaults: defaults)
        let notes = model.browserItems.first { $0.id == "Notes" }!
        for id in model.sharedLinkSessions.keys {
            var session = model.sharedLinkSessions[id]!
            let old = session.workspace!
            session.workspace = BrowserWorkspaceSnapshot(
                items: old.items + [notes], stack: old.stack, nextPageToken: nil,
                expandedFolderIDs: old.expandedFolderIDs, childrenByFolderID: old.childrenByFolderID,
                loadErrors: [:], selectedItemID: nil, selectedItemIDs: [], selectionAnchorID: nil,
                folderSnapshots: [:], childPageTokens: [:], itemPaths: old.itemPaths, parentIDs: old.parentIDs)
            session.savedItemIDs = []
            session.access = ShareAccessInput(url: session.access.url, passCode: "fixture-\(id)",
                                             passCodeToken: "token-\(id)")
            model.sharedLinkSessions[id] = session
            model.updateSharedLink(id) { $0.savedItemCount = 0 }
        }
        model.activateSharedLink(model.sharedLinks[0].id)
        return model
    }

    static func sharedLinkRetryFixture(defaults: UserDefaults, failedCount: Int = 9, automatic: Bool = false) -> DownloaderModel {
        let model = sharedSelectionFixture(defaults: defaults)
        model.finderSettings.showsPreviewPane = false
        for number in 1...max(1, failedCount) {
            let id = UUID()
            let access = ShareAccessInput(url: "https://mypikpak.com/s/offline-retry-\(number)",
                passCode: "fixture-code-\(number)", passCodeToken: "fixture-cache-\(number)")
            model.sharedLinks.append(.init(id: id, url: access.url, name: "Example Link \(number + 2)",
                state: .failed("The connection timed out. Retry this link."), savedItemCount: 1, addedAt: Date()))
            model.sharedLinkSessions[id] = SharedLinkSession(access: access, workspace: nil, savedItemIDs: ["already-saved"])
        }
        if automatic {
            model.sharedLinkLoadFixture = { [weak model] id, request, process in
                Task { @MainActor [weak model] in
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    model?.completeSharedLinkLoadFixture(id: id, request: request, process: process,
                        succeeds: !request.url.hasSuffix("-3"))
                }
            }
        }
        return model
    }

    private func completeSharedLinkLoadFixture(id: UUID, request: ShareBrowseInput, process: Process, succeeds: Bool) {
        let page = ShareBrowsePage(files: [], nextPageToken: nil, shareId: "fixture-share", passCodeToken: "fixture-new-cache",
            parentId: "", folderName: "Example Shared Folder")
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let output = String(data: try! encoder.encode(page), encoding: .utf8)!
        finishInitialSharedLinkLoad(linkID: id, request: request, process: process,
            exitCode: succeeds ? 0 : 1, structuredOutput: succeeds ? output : "",
            errorOutput: succeeds ? "" : "Connection reset by peer")
    }

    static func testSharedLinkRetries(defaults: UserDefaults) {
        typealias Load = (id: UUID, request: ShareBrowseInput, process: Process)
        let model = sharedLinkRetryFixture(defaults: defaults, failedCount: 10)
        var launched: [Load] = []
        model.sharedLinkLoadFixture = { launched.append(($0, $1, $2)) }
        let alreadyLoading = model.sharedLinks.last!.id
        model.updateSharedLink(alreadyLoading) { $0.state = .loading }
        model.runInitialSharedLinkLoad(linkID: alreadyLoading, request: .init(
            access: model.sharedLinkSessions[alreadyLoading]!.access, parentId: nil, pageToken: nil, limit: 200))
        let active = model.activeSharedLinkID
        model.toggleBrowserCheckbox(model.browserItem(withID: "Projects")!)
        let selection = model.selectedBrowserItemIDs
        let items = model.browserItems
        let ready = Array(model.sharedLinks.prefix(2))
        let expectedAccess = model.sharedLinkSessions.mapValues(\.access)
        let failedID = model.sharedLinks[2].id
        model.retryAllFailedSharedLinks()
        precondition(model.sharedLinkRetryProgress == .init(completed: 0, total: 9))
        precondition(launched.count == 4 && model.pendingSharedLinkLoads.count == 6,
            "the batch shares four slots with requests that were already loading")
        precondition(model.activeSharedLinkID == active && model.selectedBrowserItemIDs == selection && model.browserItems == items,
            "batch retry preserves the active ready link and its selected files")
        precondition(Array(model.sharedLinks.prefix(2)) == ready, "ready links are untouched")
        precondition(model.accountWorkIsActive, "queued work prevents an account change")
        model.retryAllFailedSharedLinks()
        let queued = model.pendingSharedLinkLoads.last!.linkID
        model.retrySharedLink(queued)
        precondition(launched.count == 4 && model.pendingSharedLinkLoads.count == 6 && !model.canEditSharedLink(queued),
            "repeated batch or row clicks cannot duplicate or edit a queued request")
        model.removeSharedLink(queued)
        precondition(model.sharedLinkRetryProgress == .init(completed: 1, total: 9))
        precondition(!model.pendingSharedLinkLoads.contains { $0.linkID == queued })
        precondition(model.activateAccountBrowser(), "the account browser stays available during retries")
        model.isRunning = true // An unrelated foreground request must not stall the batch.
        var completed = 0
        while completed < launched.count {
            let load = launched[completed]
            precondition(load.request.url == expectedAccess[load.id]!.url
                && load.request.passCode == expectedAccess[load.id]!.passCode
                && load.request.passCodeToken == expectedAccess[load.id]!.passCodeToken,
                "each request retains its own saved URL and access code")
            model.completeSharedLinkLoadFixture(id: load.id, request: load.request, process: load.process, succeeds: load.id != failedID)
            precondition(model.sharedLinkLoadProcesses.count <= 4)
            completed += 1
        }
        model.isRunning = false
        precondition(launched.count == 9 && Set(launched.map(\.id)).count == 9 && !launched.contains { $0.id == queued })
        precondition(model.sharedLinkRetryProgress == nil && model.pendingSharedLinkLoads.isEmpty && model.failedSharedLinkCount == 1)
        precondition(model.shareLinkFeedbackMessage == "Retry complete: 7 opened, 1 still failed. 1 disconnected.")
        precondition(model.browserSource == .account, "late completions never switch tabs")
        precondition(model.sharedLinkSessions[failedID]!.savedItemIDs == ["already-saved"], "retry keeps saved-item history")
        model.retryAllFailedSharedLinks()
        precondition(model.sharedLinkRetryProgress == .init(completed: 0, total: 1) && launched.last!.id == failedID)
        let last = launched.last!
        model.completeSharedLinkLoadFixture(id: last.id, request: last.request, process: last.process, succeeds: true)
        model.completeSharedLinkLoadFixture(id: last.id, request: last.request, process: last.process, succeeds: false)
        precondition(model.failedSharedLinkCount == 0 && model.sharedLinkRetryProgress == nil && !model.canRetryFailedSharedLinks,
            "late or duplicate callbacks cannot overwrite a successful retry")
        print("PASS link retries: failed-only snapshot, four-worker bound, access-code isolation, preserved selection, disconnect, repeat clicks and mixed results")

        let interrupted = sharedLinkRetryFixture(defaults: defaults)
        var interruptedLoads: [Load] = []
        interrupted.sharedLinkLoadFixture = { interruptedLoads.append(($0, $1, $2)) }
        interrupted.retryAllFailedSharedLinks()
        interrupted.deferredLoginReason = "Fixture requires sign-in"
        let first = interruptedLoads[0]
        interrupted.completeSharedLinkLoadFixture(id: first.id, request: first.request, process: first.process, succeeds: false)
        precondition(interruptedLoads.count == 4 && interrupted.pendingSharedLinkLoads.isEmpty && interrupted.failedSharedLinkCount == 6,
            "authentication interruption stops all queued requests")
        interrupted.stopForWindowClose()
        for load in interruptedLoads.dropFirst() {
            interrupted.completeSharedLinkLoadFixture(id: load.id, request: load.request, process: load.process, succeeds: true)
        }
        precondition(interrupted.sharedLinkRetryProgress == nil && interrupted.sharedLinkLoadProcesses.isEmpty && interruptedLoads.count == 4)
        precondition(!interrupted.canRetryFailedSharedLinks)
        print("PASS link retries: login interruption, window-close cancellation and ignored late callbacks")

        let signedOut = sharedLinkRetryFixture(defaults: defaults, failedCount: 1)
        signedOut.refreshToken = ""
        signedOut.retryAllFailedSharedLinks()
        precondition(signedOut.isLoginPresented && signedOut.failedSharedLinkCount == 1 && signedOut.sharedLinkRetryProgress == nil)
        let missingEngine = sharedLinkRetryFixture(defaults: defaults, failedCount: 50)
        missingEngine.activateSharedLink(missingEngine.sharedLinks[2].id)
        missingEngine.retryAllFailedSharedLinks()
        precondition(missingEngine.failedSharedLinkCount == 50 && missingEngine.sharedLinkRetryProgress == nil
            && missingEngine.pendingSharedLinkLoads.isEmpty && missingEngine.sharedLinkLoadProcesses.isEmpty && !missingEngine.isOpeningShareLink,
            "synchronous launch failures drain the queue without recursion or stuck spinners")
        print("PASS link retries: signed-out prompt and failed helper launch recovery")
    }

    static func testSharedSelection(defaults: UserDefaults) {
        func fixture() -> DownloaderModel { sharedSelectionFixture(defaults: defaults) }
        let model = fixture()
        let first = model.sharedLinks[0].id, second = model.sharedLinks[1].id
        let projects = model.browserItem(withID: "Projects")!
        let notes = model.browserItem(withID: "Notes")!
        let drafts = model.browserItem(withID: "Drafts")!
        let readme = model.browserItem(withID: "Readme.txt")!
        model.toggleBrowserCheckbox(projects)
        model.toggleBrowserCheckbox(notes)
        precondition(model.browserActionSelectionCount == 2)
        precondition(model.isBrowserItemSelected(drafts.id, in: first))
        precondition(model.sharedSaveContextMenuTitle(for: projects, in: first) == "Save 2 Items to My PikPak")
        model.activateSharedLink(first)
        precondition(model.selectedBrowserItemIDs == [projects.id, notes.id], "same-context activation preserves current selection")
        model.activateSharedLink(second)
        model.toggleBrowserCheckbox(projects)
        precondition(model.browserActionSelectionCount == 3)
        precondition(model.isBrowserItemSelected(projects.id, in: first) && model.isBrowserItemSelected(projects.id, in: second))
        precondition(!model.isBrowserItemSelected(notes.id, in: second))
        model.saveSharedItemsFromContextMenu(drafts, in: first)
        precondition(model.sharedSaveFixtureRequests.count == 2)
        let requests = Dictionary(uniqueKeysWithValues: model.sharedSaveFixtureRequests.map { ($0.linkID, $0.request) })
        precondition(Set(requests[first]!.fileIds) == [projects.id, notes.id] && requests[second]!.fileIds == [projects.id])
        for (id, request) in requests {
            precondition(request.url == model.sharedLinkSessions[id]!.access.url)
            precondition(request.passCode == "fixture-\(id)" && request.passCodeToken == "token-\(id)")
        }
        precondition(model.isSelectedSharedSelectionSaved && !model.canSaveSharedSelection)
        precondition(model.activeSharedLinkID == second && model.browserActionSelectionCount == 3)
        model.saveSelectedSharedItems()
        precondition(model.sharedSaveFixtureRequests.count == 2, "saved selections are not resubmitted")
        print("PASS Links selection: additive folders, recursive roots, duplicate IDs across shares, context batch save and correct per-share authorization")

        model.clearBrowserSelectionFromCanvas()
        precondition(model.browserActionSelectionCount == 0 && !model.isBrowserItemSelected(notes.id, in: first))
        model.selectBrowserItem(notes)
        model.activateSharedLink(first)
        model.selectBrowserItem(readme, toggling: true)
        precondition(model.browserActionSelectionCount == 2)
        model.selectBrowserItem(readme, toggling: true)
        precondition(model.browserActionSelectionCount == 1 && model.selectedBrowserItemIDs.isEmpty)
        model.clearBrowserSelectionFromCanvas()
        precondition(model.browserActionSelectionCount == 0, "canvas clears inactive selections even when active selection is empty")
        model.toggleBrowserCheckbox(readme)
        model.activateSharedLink(second)
        model.selectBrowserItem(notes)
        precondition(model.browserActionSelectionCount == 1 && !model.isBrowserItemSelected(readme.id, in: first))
        model.activateSharedLink(first)
        model.toggleBrowserCheckbox(readme)
        model.selectSharedLinkRoot(second)
        precondition(model.browserActionSelectionCount == 0 && model.selectedSharedLinkRootID == second)
        print("PASS Links selection lifecycle: Command toggles, plain click replaces, canvas/root clears all shares")

        let range = fixture()
        let ordered = range.sortedSharedLinks.map(\.id)
        let startLink = ordered[0], endLink = ordered[1]
        range.activateSharedLink(startLink)
        let visible = range.sharedLinkTreeEntries(for: startLink).map(\.item)
        let start = visible.last!, end = range.sharedLinkTreeEntries(for: endLink).first!.item
        range.selectBrowserItem(start)
        range.activateSharedLink(endLink)
        range.selectBrowserItem(end, extending: true)
        precondition(range.browserActionSelectionCount == 2)
        precondition(range.isBrowserItemSelected(start.id, in: startLink) && range.isBrowserItemSelected(end.id, in: endLink))
        range.activateSharedLink(startLink)
        range.selectBrowserItem(start, extending: true)
        precondition(range.browserActionSelectionCount == 1, "Shift range shrinks back to the original namespaced anchor")
        range.selectBrowserItem(projects)
        range.selectBrowserItem(drafts, extending: true)
        precondition(range.browserActionSelectionCount == 1, "selected parent and descendant remain one recursive action root")
        print("PASS Links Shift selection: visible order across links, stable anchor, shrinking ranges, recursive normalization")

        let single = fixture()
        let singleFirst = single.sharedLinks[0].id, singleSecond = single.sharedLinks[1].id
        single.toggleBrowserCheckbox(projects)
        single.toggleBrowserCheckbox(notes)
        precondition(single.sharedSaveContextMenuTitle(for: readme, in: singleSecond) == "Save to My PikPak")
        single.saveSharedItemsFromContextMenu(readme, in: singleSecond)
        precondition(single.sharedSaveFixtureRequests.count == 1)
        precondition(single.sharedSaveFixtureRequests[0].linkID == singleSecond && single.sharedSaveFixtureRequests[0].request.fileIds == [readme.id])
        precondition(single.browserActionSelectionCount == 1 && !single.isBrowserItemSelected(projects.id, in: singleFirst))
        single.saveSharedItem(notes, in: singleFirst)
        precondition(single.sharedSaveFixtureRequests.last!.linkID == singleFirst && single.sharedSaveFixtureRequests.last!.request.fileIds == [notes.id])
        precondition(single.activeSharedLinkID == singleSecond && single.selectedBrowserItemIDs == [readme.id])
        print("PASS Links context targeting: unselected row saves itself; per-row save retains other selections and active context")

        let filtered = fixture()
        let link = filtered.activeSharedLinkID!
        filtered.sharedLinkSessions[link]!.savedItemIDs = [projects.id]
        filtered.toggleBrowserCheckbox(projects)
        filtered.toggleBrowserCheckbox(notes)
        precondition(filtered.canSaveSharedItemsFromContextMenu(projects, in: link), "a saved clicked row must allow unsaved selected siblings")
        filtered.saveSharedItemsFromContextMenu(projects, in: link)
        precondition(filtered.sharedSaveFixtureRequests.last!.request.fileIds == [notes.id])
        filtered.selectBrowserItem(readme)
        filtered.pendingSharedSaveRequests = [.init(request: .init(access: filtered.shareAccess!, fileIds: [readme.id]), linkID: link, description: "Fixture")]
        precondition(!filtered.canSaveSharedItemsFromContextMenu(readme, in: link))
        let requestCount = filtered.sharedSaveFixtureRequests.count
        filtered.saveSelectedSharedItems()
        precondition(filtered.sharedSaveFixtureRequests.count == requestCount)
        print("PASS Links eligibility: mixed saved/unsaved selections and queued items are filtered without duplicate submissions")

        let downloads = fixture()
        downloads.transferStateReady = true
        let downloadFirst = downloads.sharedLinks[0].id, downloadSecond = downloads.sharedLinks[1].id
        downloads.toggleBrowserCheckbox(projects)
        downloads.activateSharedLink(downloadSecond)
        downloads.toggleBrowserCheckbox(projects)
        downloads.downloadSelectedBrowserItem()
        precondition(downloads.pendingDownloadRequests.count == 2)
        let urls = downloads.pendingDownloadRequests.compactMap { pending -> String? in
            guard case .shared(let roots, let access, _, _, _) = pending else { return nil }
            precondition(roots.count == 1 && roots[0].item.id == projects.id)
            return access.url
        }
        precondition(Set(urls) == Set([downloadFirst, downloadSecond].map { downloads.sharedLinkSessions[$0]!.access.url }))
        print("PASS Links download compatibility: multiple shared selections enter the queue with separate authorization")
    }

    static func finderWorkspaceFixture(defaults: UserDefaults = .standard) -> DownloaderModel {
        let model = DownloaderModel(finderFixture: true, defaults: defaults)
        model.accountProfile = PikPakAccountProfile(sub: "offline-account", name: "Taylor Chen")
        let content = Data("My PikPak Open test. This is a synthetic local document.\n".utf8)
        model.fileOpener.resolve = { _ in
            PreviewInfo(name: "Readme.txt", size: UInt64(content.count), mimeType: "text/plain",
                        thumbnailLink: nil, iconLink: nil, contentLink: "https://fixture.invalid/Readme.txt", sources: nil)
        }
        model.fileOpener.download = { url, _ in
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try content.write(to: temporary)
            return (temporary, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        func item(_ name: String, folder: Bool = false, parent: String = "") -> BrowserItem {
            BrowserItem(id: name, name: name, size: folder ? 0 : 24_576, kind: folder ? .folder : .file,
                parentId: parent, mimeType: folder ? nil : "text/plain", createdTime: "2026-09-01T10:00:00Z",
                modifiedTime: "2026-09-08T01:00:00Z", fileExtension: folder ? nil : "txt",
                iconLink: nil, thumbnailLink: nil, fileCategory: nil, hash: nil, md5Checksum: nil)
        }
        let projects = item("Projects", folder: true)
        let notes = item("Notes", folder: true)
        let drafts = item("Drafts", folder: true, parent: projects.id)
        let design = item("Design.txt", parent: drafts.id)
        let readme = item("Readme.txt")
        model.browserItems = [projects, notes, readme]
        model.browserTreeChildren = [projects.id: [drafts], drafts.id: [design], notes.id: []]
        model.finderFixtureFolders = model.browserTreeChildren.merging(["": model.browserItems]) { _, new in new }
        for (parent, children) in model.finderFixtureFolders {
            let path = parent == "Drafts" ? "/Projects/Drafts" : (parent.isEmpty ? "/" : "/\(parent)")
            model.registerBrowserItems(children, parentID: parent, parentPath: path)
        }
        model.expandedBrowserFolderIDs = [projects.id, drafts.id]
        model.selectedBrowserItemID = drafts.id
        model.selectedBrowserItemIDs = [drafts.id]
        model.storageQuota = StorageQuota(total: 10_000_000_000_000, used: 6_250_000_000_000)
        model.status = "Offline Finder-style workspace · synthetic files only"

        for number in 1...2 {
            let id = UUID()
            let url = "https://mypikpak.com/s/offline-example-\(number)"
            model.sharedLinks.append(SharedLinkEntry(id: id, url: url, name: "Example Link \(number)",
                state: .ready, savedItemCount: number == 1 ? 1 : 0, addedAt: Date()))
            model.sharedLinkSessions[id] = SharedLinkSession(
                access: ShareAccessInput(url: url, passCode: "", passCodeToken: ""),
                workspace: BrowserWorkspaceSnapshot(items: [projects, readme], stack: [.sharedRoot], nextPageToken: nil,
                    expandedFolderIDs: [projects.id, drafts.id], childrenByFolderID: [projects.id: [drafts], drafts.id: [design]],
                    loadErrors: [:], selectedItemID: nil, selectedItemIDs: [], selectionAnchorID: nil,
                    folderSnapshots: [:], childPageTokens: [:], itemPaths: model.browserItemPaths,
                    parentIDs: model.browserItemParentIDs),
                savedItemIDs: number == 1 ? [projects.id] : [])
            model.expandedSharedLinkIDs.insert(id)
            if model.activeSharedLinkID == nil { model.activeSharedLinkID = id }
        }
        return model
    }

    func configureFileInteractionFixture(directory: URL, metadataLoading: Bool = false) throws {
        let file = directory.appendingPathComponent("Readme.txt")
        try Data("Quick Look works with Space.\n\nThis is a synthetic local document for My PikPak.\nPress Space or Escape to close the preview.\n".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        quickLookFixtureURL = file
        finderSettings.showsPreviewPane = false
        let image = BrowserItem(id: "Sample.jpg", name: "Sample.jpg", size: 1024, kind: .file, parentId: "",
            mimeType: "image/jpeg", createdTime: nil, modifiedTime: nil, fileExtension: "jpg",
            iconLink: nil, thumbnailLink: nil, fileCategory: nil, hash: nil, md5Checksum: nil)
        browserItems.append(image)
        selectedBrowserItemID = "Readme.txt"
        selectedBrowserItemIDs = ["Readme.txt"]
        if metadataLoading {
            previewFileID = "Readme.txt"
            operation = .preview(fileID: "Readme.txt")
            isRunning = true
        }
        fileOpener.launch = { [weak self] _, application in
            self?.setStatus("Offline app handoff: \(application?.deletingPathExtension().lastPathComponent ?? "default app")")
        }
    }

    func configureQuickLookNavigationFixture(directory: URL, delay: UInt64 = 8_000_000_000) throws {
        _ = cancelQuickLook()
        clearPreview()
        browserSource = .account
        browserStack = [.root]
        browserTreeChildren = [:]
        expandedBrowserFolderIDs = []
        let names = ["Cloud Folder", "First.txt", "Second.txt", "Third.txt"]
        browserItems = names.map { name in
            BrowserItem(id: name, name: name, size: 64, kind: name.hasSuffix(".txt") ? .file : .folder,
                parentId: "", mimeType: "text/plain", createdTime: nil, modifiedTime: nil,
                fileExtension: name.hasSuffix(".txt") ? "txt" : nil,
                iconLink: nil, thumbnailLink: nil, fileCategory: nil, hash: nil, md5Checksum: nil)
        }
        registerBrowserItems(browserItems, parentID: "", parentPath: "/")
        for item in browserItems where !item.isFolder {
            let url = directory.appendingPathComponent(item.name)
            try Data("\(item.name)\n\nThis is a different synthetic document.\nUse Up and Down to change the selected file.\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            quickLookFixtureURLs[item.id] = url
        }
        quickLookFixtureURL = quickLookFixtureURLs["First.txt"]
        quickLookFixtureDelay = delay
        finderSettings.showsPreviewPane = false
        selectedBrowserItemID = "First.txt"
        selectedBrowserItemIDs = ["First.txt"]
        isRunning = false
        operation = nil
    }

    func configureFileUndoFixture(_ scenario: String = "trash") {
        _ = cancelQuickLook(); clearBrowserSelection(); fileUndoHistory.reset()
        browserSource = .account; browserStack = [.root]; browserTreeChildren = [:]
        expandedBrowserFolderIDs = []; isRunning = false; operation = nil
        finderSettings.showsPreviewPane = false
        func item(_ name: String, folder: Bool = false) -> BrowserItem {
            BrowserItem(id: name, name: name, size: 64, kind: folder ? .folder : .file,
                parentId: "", mimeType: nil, createdTime: nil, modifiedTime: nil, fileExtension: nil,
                iconLink: nil, thumbnailLink: nil, fileCategory: nil, hash: nil, md5Checksum: nil)
        }
        let file = item("Report.txt"), folder = item("Projects", folder: true)
        browserItems = [folder, file]; registerBrowserItems(browserItems, parentID: "", parentPath: "/")
        fileUndoFixtureItems = [file.id: file, folder.id: folder]; fileUndoFixtureTrashed = []
        switch scenario {
        case "move":
            finishMoveBrowserItems(output: "{\"moved_ids\":[\"Report.txt\"],\"parent_id\":\"Projects\"}",
                requestedItems: [file], destination: BrowserLocation(id: folder.id, name: folder.name, path: "/Projects"))
        case "rename":
            finishRenameItem(output: "{\"id\":\"Report.txt\",\"name\":\"Renamed.txt\"}",
                requestedItem: file, requestedName: "Renamed.txt")
        case "upload":
            uploadUndoMutations = []
            recordCreatedUploadItem(id: file.id, parentID: "", name: file.name, folder: false)
            fileUndoHistory.record(FinderUndoEntry(title: "Upload", mutations: uploadUndoMutations, uploadBatchID: UUID()))
            uploadUndoMutations = []
        case "folder":
            finishCreateFolder(output: "{\"id\":\"New Folder\",\"parent_id\":\"\",\"name\":\"New Folder\"}",
                parent: .root, requestedName: "New Folder")
            fileUndoFixtureItems["New Folder"] = item("New Folder", folder: true)
        default:
            finishTrash(output: "{\"trashed_ids\":[\"Report.txt\"]}", itemID: file.id, itemName: file.name)
        }
        if let entry = fileUndoHistory.undoEntries.last { applyFileUndoFixtureChanges(entry.mutations) }
        setStatus("Synthetic \(scenario) completed · press Command-Z to undo")
    }

    private func applyFileUndoFixtureChanges(_ changes: [FinderFileMutation]) {
        for change in changes {
            guard let item = fileUndoFixtureItems[change.fileId] else { continue }
            if change.kind == .trash {
                if change.after == "true" { fileUndoFixtureTrashed.insert(item.id) }
                else { fileUndoFixtureTrashed.remove(item.id) }
            } else {
                fileUndoFixtureItems[item.id] = BrowserItem(id: item.id,
                    name: change.kind == .rename ? change.after : item.name, size: item.size, kind: item.kind,
                    parentId: change.kind == .move ? change.after : item.parentId, mimeType: item.mimeType,
                    createdTime: nil, modifiedTime: nil, fileExtension: item.fileExtension,
                    iconLink: nil, thumbnailLink: nil, fileCategory: nil, hash: nil, md5Checksum: nil)
            }
        }
        let visible = fileUndoFixtureItems.values.filter { !fileUndoFixtureTrashed.contains($0.id) }
        browserItems = sortedBrowserItems(visible.filter { ($0.parentId ?? "").isEmpty })
        browserTreeChildren = Dictionary(grouping: visible.filter { !($0.parentId ?? "").isEmpty }, by: { $0.parentId ?? "" })
        registerBrowserItems(browserItems, parentID: "", parentPath: "/")
        for (parent, items) in browserTreeChildren { registerBrowserItems(items, parentID: parent, parentPath: "/\(parent)") }
    }

    private func finishFileUndoFixture(request: FinderUndoRequest, title: String) {
        let applied = fileUndoHistory.finish(completed: request.changes.map(\.id))
        applyFileUndoFixtureChanges(applied)
        setStatus("\(title) completed · \(applied.count) item(s) · synthetic files only")
    }

    static func testFileUndoModel(defaults: UserDefaults) {
        let model = finderWorkspaceFixture(defaults: defaults)
        for scenario in ["trash", "move", "rename", "upload", "folder"] {
            model.configureFileUndoFixture(scenario)
            precondition(model.canUndoFileAction && !model.canRedoFileAction)
            let changes = model.fileUndoHistory.undoEntries.last!.mutations
            model.performFileUndo(redo: false)
            precondition(!model.canUndoFileAction && model.canRedoFileAction)
            model.performFileUndo(redo: true)
            precondition(model.canUndoFileAction && !model.canRedoFileAction)
            precondition(model.fileUndoHistory.undoEntries.last!.mutations == changes)
        }
        model.isUploading = true
        precondition(!model.canUndoFileAction, "a live upload must settle before cloud undo")
        model.isUploading = false; model.isRunning = true
        precondition(!model.canUndoFileAction, "one mutation at a time")
        model.isRunning = false
        model.configureFileUndoFixture("upload")
        let batch = model.fileUndoHistory.undoEntries.last!.uploadBatchID!
        model.savedUploadBatches = [SavedUploadBatch(id: batch, sources: ["/offline/Report.txt"], destination: .root,
                                                   workers: 1, createdAt: Date())]
        model.performFileUndo(redo: false)
        precondition(model.savedUploadBatches.isEmpty, "undo cancels a stopped upload's remaining saved work")

        model.configureFileUndoFixture("upload"); model.fileUndoHistory.reset()
        model.finishTrashBrowserItems(output: "{\"trashed_ids\":[\"Report.txt\",\"Projects\"]}",
                                      requestedIDs: ["Report.txt", "unconfirmed"])
        precondition(model.fileUndoHistory.undoEntries.last!.mutations.map(\.fileId) == ["Report.txt"])
        precondition(model.browserItems.contains { $0.id == "Projects" }, "ignore unrequested acknowledgements")
        model.configureFileUndoFixture("upload"); model.fileUndoHistory.reset()
        model.undoMoveOrigins = ["Report.txt": "captured-parent"]
        model.finishMoveBrowserItems(output: "{\"moved_ids\":[\"Report.txt\"],\"parent_id\":\"destination\"}",
            requestedItems: model.browserItems, destination: .init(id: "destination", name: "Destination", path: "/Destination"))
        precondition(model.fileUndoHistory.undoEntries.last!.mutations.count == 1)
        precondition(model.fileUndoHistory.undoEntries.last!.mutations[0].before == "captured-parent",
                     "move history uses the parent captured before the request")
        model.clearTransferAccountContext()
        precondition(model.fileUndoHistory.undoEntries.isEmpty && model.fileUndoHistory.redoEntries.isEmpty)
        print("PASS model Undo/Redo: confirmed Trash, move, rename, upload, new folder, partial batches, captured move parents, saved-upload cancellation, busy guards and account isolation")
    }

    func finishFileInteractionPreviewFixture() {
        guard isFinderWorkspaceFixture, quickLookFixtureURL != nil else { return }
        isRunning = false
        operation = nil
        previewSources = [PreviewSource(url: "https://fixture.invalid/Readme.txt", label: "Original", isOrigin: true, videoCodec: nil, audioCodec: nil)]
        _ = openPendingQuickLookIfNeeded(for: "Readme.txt")
    }

    static func testQuickLookRequests(defaults: UserDefaults) {
        let model = finderWorkspaceFixture(defaults: defaults)
        let file = model.browserItems.first { !$0.isFolder }!
        let folder = model.browserItems.first { $0.isFolder }!
        model.selectedBrowserItemID = file.id
        model.selectedBrowserItemIDs = [file.id]
        model.previewFileID = file.id
        model.operation = .preview(fileID: file.id)
        model.isRunning = true
        precondition(model.canRequestQuickLook(for: file), "Space must join an in-flight inline preview for this file")
        precondition(model.toggleQuickLookForSelection())
        precondition(model.isPreparingQuickLook && model.pendingQuickLookFileID == file.id && model.isRunning)
        let generation = model.quickLookDownloadGeneration
        precondition(model.toggleQuickLookForSelection(), "a second Space cancels preparation")
        precondition(!model.isPreparingQuickLook && model.pendingQuickLookFileID == nil && generation != model.quickLookDownloadGeneration)
        precondition(!model.openPendingQuickLookIfNeeded(for: file.id), "late metadata cannot reopen a cancelled preview")
        precondition(model.isRunning, "cancelling Quick Look preserves the inline metadata request")
        model.previewFileID = "another-file"
        precondition(model.canRequestQuickLook(for: file), "Quick Look may open while an unrelated request finishes")
        model.requestQuickLook(for: file)
        precondition(model.pendingQuickLookFileID == file.id && model.isRunning && model.previewFileID == "another-file",
                     "queue the intent without replacing unrelated foreground work")
        precondition(model.cancelQuickLook())
        model.isRunning = false
        precondition(!model.canRequestQuickLook(for: folder))
        model.operation = .sharePreview(request: SharePreviewInput(access: ShareAccessInput(url: "https://mypikpak.com/s/offline", passCode: "", passCodeToken: ""), fileId: file.id), fileID: file.id)
        model.previewFileID = file.id
        model.isRunning = true
        model.requestQuickLook(for: file)
        precondition(model.pendingQuickLookFileID == file.id && model.isPreparingQuickLook, "shared-link metadata joins the same path")
        precondition(model.cancelQuickLook())
        precondition(!model.cancelQuickLook(), "Escape without Quick Look stays available to the browser")
        print("PASS Quick Look requests: account/shared metadata race, second-Space/Escape cancellation, stale responses, unrelated work and folders")
    }

    static func testQuickLookNavigation(defaults: UserDefaults, directory: URL) async throws {
        let model = finderWorkspaceFixture(defaults: defaults)
        try model.configureQuickLookNavigationFixture(directory: directory, delay: 80_000_000)
        let first = model.browserItems.first { $0.id == "First.txt" }!
        let second = model.browserItems.first { $0.id == "Second.txt" }!
        let third = model.browserItems.first { $0.id == "Third.txt" }!
        let folder = model.browserItems.first { $0.isFolder }!
        model.requestQuickLook(for: first)
        precondition(model.isQuickLookSessionActive && model.isPreparingQuickLook && model.quickLookPreviewCoordinator.itemID == first.id)
        precondition(model.automaticPreviewTask == nil, "inline debounce cannot later cancel an explicit Quick Look request")
        let firstGeneration = model.quickLookDownloadGeneration
        model.moveQuickLookSelection(by: 1)
        precondition(model.selectedBrowserItemID == second.id && model.quickLookPreviewCoordinator.itemID == second.id)
        precondition(model.isPreparingQuickLook && model.quickLookDownloadGeneration != firstGeneration)
        let secondGeneration = model.quickLookDownloadGeneration
        model.selectBrowserItem(second)
        model.browserSelectionChanged()
        precondition(model.quickLookDownloadGeneration == secondGeneration, "reselecting the same row preserves its pending preview")
        model.moveQuickLookSelection(by: 1)
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(model.quickLookPreviewCoordinator.itemID == third.id && !model.isPreparingQuickLook)
        precondition(model.quickLookCopies.count == 1 && model.quickLookCopies[model.quickLookIdentity(for: third)] != nil,
                     "cancelled earlier requests cannot replace or cache a newer selection")
        model.moveQuickLookSelection(by: 1)
        precondition(model.selectedBrowserItemID == third.id, "the last row does not wrap")
        model.moveQuickLookSelection(by: -1)
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(model.quickLookPreviewCoordinator.itemID == second.id && !model.isPreparingQuickLook)
        model.moveQuickLookSelection(by: 1)
        precondition(!model.isPreparingQuickLook && model.quickLookFixtureTask == nil, "returning to a fetched file reuses the private copy")
        model.selectBrowserItem(folder)
        precondition(model.quickLookPreviewCoordinator.itemID == folder.id && !model.isPreparingQuickLook,
                     "a folder selection replaces the old file with folder information")
        model.moveQuickLookSelection(by: 1)
        precondition(model.selectedBrowserItemID == first.id && model.isPreparingQuickLook)
        model.quickLookPreviewCoordinator.onClose?()
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(!model.isQuickLookSessionActive && !model.isPreparingQuickLook && model.quickLookPreviewCoordinator.itemID == nil,
                     "the native close callback cancels a pending copy without reopening")
        precondition(model.quickLookCopies[model.quickLookIdentity(for: first)] == nil)

        model.clearPreview()
        model.previewFileID = first.id
        model.operation = .preview(fileID: first.id)
        model.isRunning = true
        model.requestQuickLook(for: first)
        model.selectBrowserItem(second)
        // Force a fresh revision so this request cannot reuse the prior copy.
        model.fileOpenContext = UUID()
        model.clearPreview()
        model.requestQuickLook(for: second)
        model.browserSelectionChanged()
        precondition(model.isRunning && model.pendingQuickLookFileID == second.id && model.isPreparingQuickLook,
                     "navigation keeps only the latest metadata intent while the current read finishes")
        precondition(!model.openPendingQuickLookIfNeeded(for: first.id), "late metadata for the old selection is ignored")
        model.isRunning = false
        model.operation = nil
        precondition(model.startPendingQuickLookMetadataIfNeeded())
        precondition(model.quickLookPreviewCoordinator.itemID == second.id && model.isPreparingQuickLook)
        precondition(model.cancelQuickLook())
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(!model.isQuickLookSessionActive && !model.isPreparingQuickLook)

        model.requestQuickLook(for: second)
        model.clearBrowserSelectionFromCanvas()
        precondition(!model.isQuickLookSessionActive && !model.isPreparingQuickLook,
                     "clearing the selection closes Quick Look synchronously")
        model.selectBrowserItem(first)
        model.requestQuickLook(for: first)
        precondition(model.switchBrowserSource(to: .sharedLink))
        try await Task.sleep(nanoseconds: 150_000_000)
        precondition(!model.isQuickLookSessionActive && !model.isPreparingQuickLook,
                     "switching sources cancels a pending preview before restoring another workspace")
        print("PASS Quick Look navigation: immediate pending state, Up/Down, boundaries, rapid changes, same-row selection, copy reuse, folders, metadata queue, cleared selection, source changes and native-close cancellation")
    }

    /// Offline snapshots for native status/menu inspection. No engine or
    /// session files are accessed; the real progress/result decoders are used.
    func configureTaskActivityInspection(_ scenario: String) {
        taskActivity.reset()
        isScanningDuplicates = false
        isMergingFolders = false
        duplicateScan = nil
        log = "Offline status inspection. Synthetic files only."
        setStatus("Loaded 4 item(s)")
        guard scenario != "ready" else { return }
        duplicateScanRootPath = "/Projects"
        taskActivity.begin(.duplicates, scope: "/Projects", message: "Checking duplicate files…")
        if scenario == "running" {
            isScanningDuplicates = true
            handleDuplicateStderrLine(duplicateProgressPrefix + #"{"event":"scan_progress","scanned_files":1250,"scanned_folders":86,"discovered_folders":124,"pending_folders":38,"current_path":"/Projects/Research"}"#)
        } else {
            finishDuplicateScan(output: Self.taskActivityDuplicateFixture, scope: .root)
        }
        if scenario == "mixed" {
            taskActivity.begin(.emptyFolders, scope: "/Projects/Drafts", message: "Scanning empty folders…")
            taskActivity.finish(.emptyFolders, state: .completed,
                message: "Moved 18 verified empty folders to PikPak Trash", detail: "86 folders scanned · 18 removed · 2 kept")
            let diagnostic = AppErrorDiagnostic(source: "PikPak", code: "HTTP 503",
                message: "The service is temporarily unavailable. Try again.", context: "Destination: Projects")
            taskActivity.begin(.folderMerge, scope: "/Projects", message: "Merging folders…")
            taskActivity.finish(.folderMerge, state: .failed, message: "Could not finish merging folders", diagnostic: diagnostic)
        }
    }

    private static var taskActivityDuplicateFixture: String {
        #"{"root_path":"/Projects","scanned_files":1250,"scanned_folders":86,"failed_folders":0,"duplicate_files":2,"exact_groups":1,"possible_groups":0,"reclaimable_bytes":24576,"groups":[{"id":"fixture-group","match_kind":"exact_content","size":24576,"copies":2,"reclaimable_bytes":24576,"files":[{"id":"Readme.txt","name":"Readme.txt","path":"/Projects/Readme.txt","size":24576},{"id":"Design.txt","name":"Readme copy.txt","path":"/Projects/Drafts/Readme copy.txt","size":24576}]}]}"#
    }

    static func testTaskActivity(defaults: UserDefaults) throws {
        let model = finderWorkspaceFixture(defaults: defaults)
        model.configureTaskActivityInspection("running")
        precondition(model.canBrowse && !model.canScanCurrentFolderForDuplicates)
        precondition(model.taskActivity.tasks.first?.fraction == nil, "recursive totals are unknown")
        var browserUpdates = 0, footerUpdates = 0
        let browserObservation = model.objectWillChange.sink { browserUpdates += 1 }
        let footerObservation = model.taskActivity.objectWillChange.sink { footerUpdates += 1 }
        model.handleDuplicateStderrLine(duplicateProgressPrefix + #"{"event":"scan_progress","scanned_files":1400,"scanned_folders":90,"pending_folders":34,"current_path":"/Projects/Reports"}"#)
        precondition(browserUpdates == 0 && footerUpdates == 1, "live progress refreshes only the footer")
        model.setStatus("Loaded 4 item(s)")
        precondition(model.taskActivity.summary?.contains("1,400") == true, "browsing cannot overwrite scan progress")
        model.handleDuplicateStderrLine(duplicateProgressPrefix + #"{"event":"folder_retrying","attempt":2,"max_attempts":4,"retry_in_millis":1500}"#)
        precondition(model.taskActivity.tasks.first?.detail.contains("1.5s") == true)
        model.cancelDuplicateScan()
        precondition(model.taskActivity.tasks.first?.state == .cancelled && !model.isScanningDuplicates)
        model.configureTaskActivityInspection("complete")
        precondition(model.duplicateScan?.groups.count == 1 && model.selectedDuplicateFileIDs == ["Design.txt"])
        model.setDuplicateFileSelected("Readme.txt", selected: true)
        precondition(model.selectedDuplicateFileIDs == ["Design.txt"], "retain one copy per group")
        model.setStatus("Loaded another folder")
        precondition(model.taskActivity.summary?.contains("duplicate group") == true)
        let partial = taskActivityDuplicateFixture.replacingOccurrences(of: "\"failed_folders\":0", with: "\"failed_folders\":2")
        model.finishDuplicateScan(output: partial, scope: .root)
        precondition(model.taskActivity.tasks.first?.state == .partial)
        model.finishDuplicateScan(output: "malformed", scope: .root)
        precondition(model.taskActivity.tasks.first?.state == .failed, "decode errors cannot show completion")

        // Result review can be opened from Links. Confirmed account removals
        // must not delete identical IDs from the shared tree or its selection.
        model.configureTaskActivityInspection("complete")
        precondition(model.activateSharedLinkBrowser())
        let sharedItems = model.browserItems.map(\.id)
        let sharedSelection = model.selectedBrowserItemIDs
        model.finishTrashDuplicates(output: #"{"trashed_ids":["Design.txt"]}"#, requestedIDs: ["Design.txt"])
        precondition(model.browserItems.map(\.id) == sharedItems && model.selectedBrowserItemIDs == sharedSelection)
        precondition(model.duplicateScan?.groups.isEmpty == true)
        precondition(model.activateAccountBrowser())
        precondition(model.browserItem(withID: "Design.txt") == nil)
        model.taskActivity.begin(.emptyFolders, scope: "/Projects", message: "Scanning…")
        model.maintenanceOperation = .emptyFolders(scope: .root)
        model.isRemovingEmptyFolders = true
        browserUpdates = 0
        model.handleEmptyFolderStderrLine(emptyFolderProgressPrefix + #"{"event":"scan_progress","scanned_folders":20,"discovered_folders":40,"current_path":"/Projects"}"#)
        precondition(browserUpdates == 0 && model.taskActivity.summary?.contains("20") == true)
        model.maintenanceOperation = nil
        model.isRemovingEmptyFolders = false
        model.finishEmptyFolderCleanup(output: #"{"root_path":"/Projects","scanned_folders":40,"candidate_folders":0,"rechecked_folders":0,"skipped_non_empty_folders":0,"removed_folders":0,"removed_ids":[]}"#, scope: .root)
        precondition(model.taskActivity.tasks.first?.state == .completed)
        model.taskActivity.begin(.dsStore, scope: "/Projects", message: "Scanning…")
        model.finishDSStoreCleanup(output: "malformed", scope: .root)
        precondition(model.taskActivity.tasks.first?.state == .failed)

        model.taskActivity.begin(.dsStore, scope: "/Projects", message: "Scanning…")
        model.finishDSStoreCleanup(output: #"{"root_path":"/Projects","scanned_folders":40,"candidate_files":0,"rechecked_files":0,"skipped_files":0,"removed_files":0,"removed_ids":[]}"#, scope: .root)
        precondition(model.taskActivity.tasks.first?.state == .completed)

        let merge = finderWorkspaceFixture(defaults: defaults)
        let destination = merge.browserItems.first { $0.id == "Projects" }!
        let source = merge.browserItems.first { $0.id == "Notes" }!
        precondition(merge.activateSharedLinkBrowser())
        let sharedChildren = merge.browserTreeChildren.mapValues { $0.map(\.id) }
        let mergeSharedItems = merge.browserItems.map(\.id)
        merge.finishMergeFolders(output: #"{"destination_id":"Projects","merged_source_ids":["Notes"],"moved_items":10}"#,
            requestedFolders: [destination, source], destination: destination)
        precondition(merge.mergeDidComplete)
        precondition(merge.browserItems.map(\.id) == mergeSharedItems && merge.browserTreeChildren.mapValues { $0.map(\.id) } == sharedChildren,
            "account merges do not change the active shared-link tree")
        precondition(merge.activateAccountBrowser())
        precondition(merge.browserItem(withID: "Notes") == nil && merge.browserTreeChildren["Projects"] == nil,
            "merged source is removed and account destination reloads its changed contents")

        model.taskActivity.begin(.folderMerge, scope: "/Projects", message: "Merging…")
        browserUpdates = 0
        model.handleMergeProgressLine(mergeProgressPrefix + #"{"event":"verifying","source_count":2,"completed_sources":1,"moved_items":10,"total_items":10,"remaining_items":5,"attempt":2,"max_attempts":6}"#)
        precondition(browserUpdates == 0 && model.taskActivity.tasks.first?.fraction == 0.5)
        model.taskActivity.stopping(.folderMerge, message: "Cancelling…")
        model.handleMergeProgressLine(mergeProgressPrefix + #"{"event":"completed","completed_sources":2}"#)
        precondition(model.taskActivity.tasks.first?.state == .stopping && model.taskActivity.summary == "Cancelling…")
        model.taskActivity.dismiss(.folderMerge)
        precondition(model.taskActivity.tasks.first?.kind == .folderMerge, "active work cannot be dismissed")
        model.taskActivity.finish(.folderMerge, state: .cancelled, message: "Merge cancelled")
        model.taskActivity.dismiss(.folderMerge)
        precondition(!model.taskActivity.tasks.contains { $0.kind == .folderMerge })
        model.taskActivity.showsDuplicateResults = true
        model.clearAccountWorkspace()
        precondition(model.taskActivity.tasks.isEmpty && !model.taskActivity.showsDuplicateResults && model.duplicateScan == nil)
        browserObservation.cancel(); footerObservation.cancel()
        print("PASS task status: isolated progress, browsing, cancellation, duplicate review/keep-one, partial/decode failure, account-scoped Trash, cleanup/merge progress and account clearing")
    }

    #if FINDER_FOOTER_TESTS
    func configureFooterInspection(_ state: String) {
        switch state {
        case "error":
            setError("Could not finish scanning Projects. The service is temporarily unavailable. Try again when the connection is restored.",
                diagnostic: AppErrorDiagnostic(source: "PikPak", code: "HTTP 503",
                    message: "The service could not complete the request.",
                    context: "Folder: /Projects/Research/Reports"))
        case "busy":
            isRunning = true
            setStatus("Scanning for duplicate files in Projects · 1,250 files checked…")
        default:
            setStatus("Ready")
        }
        log = "Offline footer inspection. No PikPak request was made."
    }
    #endif

    static func testFinderWorkspace(defaults: UserDefaults) throws {
        let model = finderWorkspaceFixture(defaults: defaults)
        model.finderSettings.setTransferWorkers(48)
        precondition(model.effectiveDownloadConcurrentJobs == 48 && model.effectiveUploadConcurrentJobs == 48)
        model.uploadConcurrentJobs = 24
        precondition(model.concurrentJobs == 24 && model.effectiveDownloadConcurrentJobs == 24)
        model.concurrentJobs = 32
        precondition(model.uploadConcurrentJobs == 32)

        model.selectedBrowserItemID = "Design.txt"
        model.selectedBrowserItemIDs = ["Design.txt"]
        precondition(model.browserFooterLocations.map(\.id) == ["", "Projects", "Drafts", "Design.txt"])
        let location = model.browserFooterLocations[2]
        model.navigateFooter(to: location)
        precondition(model.browserStack.map(\.id) == ["", "Projects", "Drafts"])
        model.goBack()
        precondition(model.browserStack.last?.id == "Projects" && model.selectedBrowserItemID == "Drafts")

        let root = AccountDownloadRoot(queueID: UUID(), path: "/Readme.txt", name: "Readme.txt", kind: .file,
                                      file: nil, relativeParent: [])
        let original = PendingDownloadRequest.account(roots: [root], destination: model.outputURL, jobs: 2, proxyURL: "")
        let updated = original.withWorkerLimit(48)
        precondition(updated.pendingItems == original.pendingItems)
        if case .account(_, _, let jobs, _) = updated { precondition(jobs == 48) }
        else { preconditionFailure("account queue source changed") }

        let first = model.sharedLinks[0].id, second = model.sharedLinks[1].id
        let item = model.sharedLinkTreeEntries(for: first).first!.item
        precondition(!model.canSaveSharedItem(item, in: first))
        precondition(model.canSaveSharedItem(item, in: second), "same ID on another link must stay saveable")
        model.activateSharedLink(first)
        precondition(model.isBrowsingSharedLink && model.isSharedLinkExpanded(first) && model.isSharedLinkExpanded(second))
        precondition(model.activateAccountBrowser())
        precondition(model.browserStack.last?.id == "Projects", "sidebar switching preserves navigation")
        print("PASS Finder model: unified limits, queued limit changes preserve files, selected path ancestry, remembered navigation, link-scoped save state")
    }
}
#endif

#if BROWSER_DROP_TESTS
extension DownloaderModel {
    static func browserDropUIFixture() -> DownloaderModel {
        let model = DownloaderModel(browserDropFixture: true)
        func item(_ id: String, folder: Bool, parent: String = "") -> BrowserItem {
            BrowserItem(id: id, name: id, size: 42, kind: folder ? .folder : .file,
                        parentId: parent, mimeType: nil, createdTime: nil, modifiedTime: nil,
                        fileExtension: nil, iconLink: nil, thumbnailLink: nil,
                        fileCategory: nil, hash: nil, md5Checksum: nil)
        }
        let first = item("Folder A", folder: true), second = item("Folder B", folder: true)
        let nested = item("Nested", folder: true, parent: "Folder B")
        let files = [item("One.txt", folder: false, parent: "Folder A"), item("Two.txt", folder: false, parent: "Folder A")]
        model.browserItems = [first, second]
        model.browserTreeChildren = [first.id: files, second.id: [nested], nested.id: []]
        model.registerBrowserItems([first, second], parentID: "", parentPath: "/")
        model.registerBrowserItems(files, parentID: first.id, parentPath: "/Folder A")
        model.registerBrowserItems([nested], parentID: second.id, parentPath: "/Folder B")
        model.expandedBrowserFolderIDs = [first.id]
        return model
    }

    /// Only synthetic IDs and stubbed mutation boundaries. Never starts an
    /// engine, saves credentials, uploads a file or moves real account data.
    static func testBrowserDropModel(localFiles: [URL]) {
        func item(_ id: String, folder: Bool = false, parent: String = "") -> BrowserItem {
            BrowserItem(id: id, name: id, size: 42, kind: folder ? .folder : .file,
                        parentId: parent, mimeType: nil, createdTime: nil, modifiedTime: nil,
                        fileExtension: nil, iconLink: nil, thumbnailLink: nil,
                        fileCategory: nil, hash: nil, md5Checksum: nil)
        }
        let a = item("A", folder: true), b = item("B", folder: true)
        let sub = item("Sub", folder: true, parent: "A")
        let first = item("One.txt", parent: "A"), second = item("Two.txt", parent: "A")
        let deep = item("Deep.txt", parent: "Sub"), other = item("Other.txt", parent: "B")
        let dest = BrowserLocation(id: "B", name: "B", path: "/B")
        func fixture() -> DownloaderModel {
            let model = DownloaderModel(browserDropFixture: true)
            model.browserItems = [a, b]
            model.browserTreeChildren = ["A": [sub, first, second], "Sub": [deep], "B": [other]]
            model.registerBrowserItems([a, b], parentID: "", parentPath: "/")
            model.registerBrowserItems([sub, first, second], parentID: "A", parentPath: "/A")
            model.registerBrowserItems([deep], parentID: "Sub", parentPath: "/A/Sub")
            model.registerBrowserItems([other], parentID: "B", parentPath: "/B")
            model.expandedBrowserFolderIDs = ["A", "B", "Sub"]
            return model
        }

        let multi = fixture()
        multi.selectedBrowserItemIDs = [first.id, second.id]
        multi.selectedBrowserItemID = first.id
        let token = multi.beginBrowserDrag(second)!
        precondition(multi.activeBrowserDragItemCount == 2)
        precondition(multi.browserDropDestination(for: deep)?.id == "Sub")
        precondition(multi.browserDropDestination(for: a)?.id == "A")
        precondition(!multi.performBrowserDrop(token: "not-the-token", on: dest))
        precondition(multi.performBrowserDrop(token: token, on: dest))
        precondition(Set(multi.recordedDropMoves[0].0.map(\.id)) == [first.id, second.id])
        precondition(multi.recordedDropMoves[0].1 == dest && multi.activeBrowserDragItemCount == 0)
        precondition(!multi.performBrowserDrop(token: token, on: .root), "tokens are one-use")

        let roots = fixture()
        roots.selectedBrowserItemIDs = [a.id, deep.id]
        roots.selectedBrowserItemID = a.id
        let rootsToken = roots.beginBrowserDrag(deep)!
        precondition(roots.activeBrowserDragItemCount == 1, "a checked ancestor carries its whole subtree once")
        precondition(roots.browserDropRejection(on: roots.browserLocation(for: sub), payload: .move) != nil)
        precondition(roots.browserDropRejection(on: roots.browserLocation(for: a), payload: .move) != nil)
        precondition(roots.browserDropRejection(on: .root, payload: .move) != nil, "no-op drop")
        precondition(roots.performBrowserDrop(token: rootsToken, on: dest))
        precondition(roots.recordedDropMoves[0].0.map(\.id) == [a.id])
        roots.isClosingWindow = true // Never schedule cache repair helpers in this fixture.
        roots.applySuccessfulBrowserMove(items: [a], destination: dest)
        precondition(roots.browserTreeChildren["B"]?.contains { $0.id == a.id } == true)
        precondition(roots.browserItemParentIDs[a.id] == "B")
        precondition(roots.browserItemPaths[deep.id] == "/B/A/Sub/Deep.txt")
        precondition(roots.browserTreeChildren["Sub"] == [deep] && roots.expandedBrowserFolderIDs.contains("Sub"))

        let lateListing = fixture()
        lateListing.isClosingWindow = true // Cache/network helpers remain disabled.
        lateListing.browserTreeLoadProcesses["A"] = Process() // A listing in flight; never executed.
        lateListing.browserTreeLoadProcesses["B"] = Process()
        let beforeMove = lateListing.folderSizeRevision
        lateListing.applySuccessfulBrowserMove(items: [first], destination: dest)
        lateListing.finishBrowserTreeBrowse(output: #"{"files":[{"id":"One.txt","name":"One.txt","size":42,"kind":"drive#file"}],"next_page_token":""}"#,
            folderID: "A", folderName: "A", folderPath: "/A", append: false, sizeRevision: beforeMove)
        lateListing.finishBrowserTreeBrowse(output: #"{"files":[],"next_page_token":""}"#,
            folderID: "B", folderName: "B", folderPath: "/B", append: false, sizeRevision: beforeMove)
        precondition(lateListing.browserTreeChildren["A"]?.isEmpty == true, "late listing must not resurrect a moved file")
        precondition(lateListing.browserTreeChildren["B"]?.map(\.id) == [first.id], "late listing must not hide a confirmed arrival")
        precondition(lateListing.browserItemParentIDs[first.id] == "B" && lateListing.browserItemPaths[first.id] == "/B/One.txt")

        let unselected = fixture()
        unselected.selectedBrowserItemIDs = [first.id, second.id]
        _ = unselected.beginBrowserDrag(other)
        precondition(unselected.activeBrowserDragItemCount == 1 && unselected.selectedBrowserItemIDs == [other.id])
        unselected.cancelBrowserDrag()
        precondition(unselected.activeBrowserDragItemCount == 0 && !unselected.canDropBrowserDrag(on: .root))

        let busy = fixture()
        busy.isDownloading = true
        busy.isScanningDuplicates = true
        busy.isMeasuringFolder = true
        precondition(busy.canBeginBrowserDrag && busy.canUploadFiles)
        let busyToken = busy.beginBrowserDrag(first)!
        precondition(busy.performBrowserDrop(token: busyToken, on: dest))
        precondition(busy.recordedDropMoves.count == 1, "downloads and read-only scans do not stall moves")
        precondition(busy.isScanningDuplicates && busy.isDownloading && busy.isMeasuringFolder)

        let queued = fixture()
        queued.isUploading = true
        let queuedToken = queued.beginBrowserDrag(first)!
        precondition(queued.performBrowserDrop(token: queuedToken, on: dest))
        precondition(queued.recordedDropMoves.isEmpty && queued.pendingBrowserMoves.count == 1)
        queued.browserStack = [.root, queued.browserLocation(for: a)]
        queued.isUploading = false
        precondition(queued.startNextPendingBrowserMoveIfNeeded())
        precondition(queued.recordedDropMoves[0].1 == dest, "navigation cannot retarget a queued drop")

        let stale = fixture()
        let staleToken = stale.beginBrowserDrag(first)!
        stale.transferAccountID = "a-different-account"
        precondition(!stale.performBrowserDrop(token: staleToken, on: dest))
        precondition(stale.recordedDropMoves.isEmpty)

        let upload = fixture()
        upload.isDownloading = true
        upload.isScanningDuplicates = true
        upload.isMeasuringFolder = true
        upload.isRunning = true
        upload.operation = .browseTree(folderID: "A", folderName: "A", folderPath: "/A", append: false)
        let account = upload.browserDropAccountID!
        precondition(upload.browserDropRejection(on: dest, payload: .upload) == nil)
        precondition(upload.uploadDroppedLocalItems(localFiles, to: dest, expectedAccountID: account))
        precondition(upload.recordedDropUploads[0].0 == localFiles && upload.recordedDropUploads[0].1 == dest)
        upload.transferAccountID = "changed-account"
        precondition(!upload.uploadDroppedLocalItems(localFiles, to: .root, expectedAccountID: account))
        precondition(!upload.uploadDroppedLocalItems(localFiles + [URL(fileURLWithPath: "/nonexistent-drop-fixture")], to: dest))
        precondition(upload.recordedDropUploads.count == 1, "a failed drop must never start a partial upload")
        upload.isUploading = true
        precondition(upload.browserDropRejection(on: dest, payload: .upload) != nil)
        print("PASS model: multi-selection, recursive roots, no-op/self/descendant rejection, one-use/account-bound tokens, exact destination, background work, queued moves, outline preservation, atomic uploads")
    }
}
#endif

#if FILE_SEARCH_TESTS
extension DownloaderModel {
    /// Synthetic UI-model coverage: no credentials, user preferences, network,
    /// media preview, or real shared-link persistence is accessed.
    static func testFileSearchReveal() {
        func item(_ id: String, folder: Bool = false, parent: String = "") -> BrowserItem {
            BrowserItem(id: id, name: id, size: 42, kind: folder ? .folder : .file,
                        parentId: parent, mimeType: nil, createdTime: nil, modifiedTime: nil,
                        fileExtension: nil, iconLink: nil, thumbnailLink: "https://example.invalid/fixture.png",
                        fileCategory: nil, hash: "fixture-hash", md5Checksum: nil)
        }
        let a = item("A", folder: true), b = item("B", folder: true, parent: "A")
        let other = item("Other", folder: true), closed = item("Closed", folder: true)
        let leaf = item("Deep.txt", parent: "B"), hidden = item("Hidden.txt", parent: "Closed")
        let otherLeaf = item("Other.txt", parent: "Other")
        let model = DownloaderModel(fileSearchFixture: true)
        model.browserItems = [a, other, closed]
        model.browserTreeChildren = ["A": [b], "B": [leaf], "Other": [otherLeaf], "Closed": [hidden]]
        model.expandedBrowserFolderIDs = ["A", "B", "Other"]
        model.registerBrowserItems(model.browserItems, parentID: "", parentPath: "/")
        model.registerBrowserItems([b], parentID: "A", parentPath: "/A")
        model.registerBrowserItems([leaf], parentID: "B", parentPath: "/A/B")
        let visible = model.currentExpandedSearchItems()
        precondition(Set(visible.map(\.id)) == ["A", "B", "Deep.txt", "Other", "Other.txt", "Closed"])
        precondition(visible.first { $0.id == "Deep.txt" }?.ancestors.map(\.id) == ["A", "B"])
        precondition(model.currentExpandedSearchItems(includesExpandedChildren: false).count == 3)
        let localIndex = FileSearchIndex()
        localIndex.replaceExpandedItems(visible)
        let local = localIndex.navigation(for: localIndex.search("Deep.txt", limit: 100).matches[0], scope: .expanded)
        model.revealFileSearchResult(local)
        precondition(model.browserStack == [.root] && model.expandedBrowserFolderIDs == ["A", "B", "Other"])
        precondition(model.selectedBrowserItemID == "Deep.txt" && model.selectedBrowserItemIDs == ["Deep.txt"])
        precondition(model.browserScrollRestoreRequest?.itemID == "Deep.txt" && model.browserScrollRestoreRequest?.focusesBrowser == true)
        precondition(model.selectedBrowserItem?.hash == "fixture-hash", "local reveal retains native metadata")

        model.browserStack = [.root, .init(id: "A", name: "A", path: "/A")]
        model.browserItems = [b]
        precondition(model.currentExpandedSearchItems().first { $0.id == "Deep.txt" }?.fullPath == "PikPak › A › B › Deep.txt")

        let rootIndex = FileSearchIndex()
        func page(_ parent: String, _ ancestors: [FileSearchAncestor], _ items: [BrowserItem]) {
            rootIndex.ingest(FileSearchEvent(event: "page", parentId: parent, ancestors: ancestors,
                items: items.map { FileSearchItem(id: $0.id, name: $0.name, kind: $0.isFolder ? "drive#folder" : "drive#file",
                                                  size: $0.size, mimeType: nil, modifiedTime: nil) },
                nextPageToken: nil, progress: FileSearchProgress(), code: nil, message: nil))
        }
        page("", [], [a, other, closed])
        page("A", [.init(id: "A", name: "A")], [b])
        page("B", [.init(id: "A", name: "A"), .init(id: "B", name: "B")], [leaf])
        page("Other", [.init(id: "Other", name: "Other")], [otherLeaf])
        let navigation = rootIndex.navigation(for: rootIndex.search("Deep.txt", limit: 100).matches[0])
        let rootModel = DownloaderModel(fileSearchFixture: true)
        rootModel.browserItems = [a, other]
        rootModel.browserTreeChildren = ["Other": [otherLeaf]]
        rootModel.expandedBrowserFolderIDs = ["Other"]
        rootModel.nextPageToken = "root-page-2"
        rootModel.isDownloading = true
        rootModel.isUploading = true
        rootModel.revealFileSearchResult(navigation)
        precondition(rootModel.browserStack == [.root])
        precondition(rootModel.expandedBrowserFolderIDs == ["A", "B", "Other"])
        precondition(rootModel.browserTreeEntries.contains { $0.id == "Deep.txt" && $0.depth == 2 })
        precondition(rootModel.browserTreeEntries.contains { $0.id == "Other.txt" })
        precondition(rootModel.selectedBrowserItemID == "Deep.txt" && rootModel.nextPageToken == "root-page-2")
        precondition(rootModel.browserItems.first { $0.id == "A" }?.thumbnailLink == a.thumbnailLink)
        precondition(rootModel.isDownloading && rootModel.isUploading && !rootModel.isRunning)

        // Root reveal while drilled into a different folder restores the root
        // snapshot and leaves the previous location expanded, too.
        rootModel.rememberBrowserPosition(beforeOpening: other)
        rootModel.browserStack = [.root, .init(id: "Other", name: "Other", path: "/Other")]
        rootModel.browserItems = [otherLeaf]
        rootModel.nextPageToken = "other-page-2"
        rootModel.revealFileSearchResult(navigation)
        precondition(rootModel.browserStack == [.root] && rootModel.nextPageToken == "root-page-2")
        precondition(rootModel.browserTreeChildren["Other"] == [otherLeaf])
        precondition(rootModel.browserTreeNextPageTokens["Other"] == "other-page-2")

        // Reveal a result beyond an already loaded page without discarding
        // that page's continuation token or rich sibling metadata.
        let paged = DownloaderModel(fileSearchFixture: true)
        paged.browserStack = [.root, .init(id: "A", name: "A", path: "/A"), .init(id: "B", name: "B", path: "/A/B")]
        paged.browserItems = (0..<200).map { item("page-\($0)", parent: "B") }
        paged.nextPageToken = "page-201"
        paged.revealFileSearchResult(navigation)
        precondition(paged.browserItems.count == 201 && paged.nextPageToken == "page-201")
        precondition(paged.selectedBrowserItemID == "Deep.txt" && paged.browserStack.last?.id == "B")
        let folderNavigation = rootIndex.navigation(for: rootIndex.search("B", limit: 100).matches.first { $0.id == "B" }!)
        rootModel.revealFileSearchResult(folderNavigation)
        precondition(rootModel.selectedBrowserItemID == "B" && rootModel.browserStack == [.root])

        let firstLink = UUID(), secondLink = UUID(), collapsedLink = UUID()
        let links = DownloaderModel(fileSearchFixture: true)
        links.browserSource = .sharedLink
        links.browserStack = [.sharedRoot]
        links.browserItems = [a]
        links.browserTreeChildren = ["A": [b], "B": [leaf]]
        links.expandedBrowserFolderIDs = ["A", "B"]
        links.activeSharedLinkID = firstLink
        for id in [firstLink, secondLink, collapsedLink] {
            links.sharedLinks.append(SharedLinkEntry(id: id, url: "https://mypikpak.com/s/fixture-\(id)",
                name: "Fixture link", state: .ready, savedItemCount: 0, addedAt: Date()))
            links.sharedLinkSessions[id] = SharedLinkSession(
                access: ShareAccessInput(url: "https://mypikpak.com/s/fixture-\(id)", passCode: "", passCodeToken: ""),
                workspace: BrowserWorkspaceSnapshot(items: [a], stack: [.sharedRoot], nextPageToken: nil,
                    expandedFolderIDs: ["A", "B"], childrenByFolderID: ["A": [b], "B": [leaf]],
                    loadErrors: [:], selectedItemID: nil, selectedItemIDs: [], selectionAnchorID: nil,
                    folderSnapshots: [:], childPageTokens: [:], itemPaths: [:], parentIDs: ["A": "", "B": "A", "Deep.txt": "B"]),
                savedItemIDs: [])
        }
        links.expandedSharedLinkIDs = [firstLink, secondLink]
        let linkVisible = links.currentExpandedSearchItems()
        precondition(linkVisible.count == 6 && Set(linkVisible.map(\.id)).count == 6)
        precondition(!linkVisible.contains { $0.linkID == collapsedLink })
        let linkIndex = FileSearchIndex()
        linkIndex.replaceExpandedItems(linkVisible)
        let secondResult = linkIndex.search("Deep.txt", limit: 100).matches.first { $0.linkID == secondLink }!
        links.revealFileSearchResult(linkIndex.navigation(for: secondResult, scope: .expanded))
        precondition(links.activeSharedLinkID == secondLink && links.selectedSharedLinkRootID == nil)
        precondition(links.selectedBrowserItemID == "Deep.txt" && links.expandedSharedLinkIDs == [firstLink, secondLink])
        precondition(links.sharedLinkSessions[firstLink]?.workspace?.expandedFolderIDs == ["A", "B"])
        links.revealFileSearchResult(navigation)
        precondition(!links.isBrowsingSharedLink && links.selectedBrowserItemID == "Deep.txt")
        precondition(links.browserTreeEntries.contains { $0.id == "Deep.txt" && $0.depth == 2 })
        print("PASS browser reveal: expanded-only scope, full ancestry, parent expansion, selection/focus, pagination, thumbnails, existing branches, transfer independence, multiple links")
    }
}
#endif

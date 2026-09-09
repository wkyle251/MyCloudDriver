import AppKit
import Foundation
import UniformTypeIdentifiers

enum CloudDriveKind: String, CaseIterable, Identifiable, Codable {
    case pikpak, icloud, photos
    var id: Self { self }
    var title: String { switch self { case .pikpak: return "PikPak"; case .icloud: return "iCloud Drive"; case .photos: return "Apple Photos" } }
    var symbol: String { switch self { case .pikpak: return "cloud.fill"; case .icloud: return "icloud.fill"; case .photos: return "photo.on.rectangle.angled" } }
    var subtitle: String { switch self {
    case .pikpak: return "Your cloud files, shared links and transfers."
    case .icloud: return "Your iCloud files and folders, together on this Mac."
    case .photos: return "Your photos, videos and albums, including iCloud Photos."
    } }
    var containerName: String { self == .photos ? "Album" : "Folder" }
}

struct CloudDriveLocation: Hashable, Identifiable, Sendable {
    let id: String
    let title: String
    var url: URL?
    var isLibrary: Bool = false
}

struct CloudDriveItem: Hashable, Identifiable, Sendable {
    let id: String
    var name: String
    let isFolder: Bool
    var bytes: UInt64?
    var modified: Date?
    var url: URL?
    var mediaType: String = "file"
    var isDownloaded = true
    var canRename = true
    var canDelete = true
    var symbol: String {
        if isFolder { return "folder.fill" }
        switch mediaType { case "image": return "photo"; case "video": return "film"; case "audio": return "waveform"; default: return "doc" }
    }
    var kindLabel: String { isFolder ? "Folder" : UTType(filenameExtension: (name as NSString).pathExtension)?.localizedDescription ?? "File" }
    var sizeLabel: String { bytes.map { ByteCountFormatter.string(fromByteCount: Int64(clamping: $0), countStyle: .file) } ?? "—" }
    var location: CloudDriveLocation { .init(id: id, title: name, url: url) }
}

struct CloudDrivePage: Sendable {
    let items: [CloudDriveItem]
    let total: Int
    var nextOffset: Int?
}

struct CloudDriveProgress: Sendable {
    var message: String
    var completed: Int = 0
    var total: Int = 0
    var fraction: Double? = nil
    var bytes: UInt64 = 0
    var fileSize: UInt64 = 0
}
typealias CloudDriveProgressHandler = @Sendable (CloudDriveProgress) -> Void

struct CloudDriveUndo: @unchecked Sendable {
    let id = UUID()
    let title: String
    let apply: @Sendable () async throws -> CloudDriveUndo
}

protocol NativeCloudDrive: AnyObject, Sendable {
    var kind: CloudDriveKind { get }
    var root: CloudDriveLocation { get }
    func list(_ location: CloudDriveLocation, offset: Int, search: String) async throws -> CloudDrivePage
    func materialize(_ item: CloudDriveItem, directory: URL, progress: @escaping CloudDriveProgressHandler) async throws -> URL
    func scanItems(_ items: [CloudDriveItem], location: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> [CloudDriveItem]
    func createContainer(_ name: String, in location: CloudDriveLocation) async throws -> CloudDriveUndo?
    func rename(_ item: CloudDriveItem, to name: String) async throws -> CloudDriveUndo?
    func relocate(_ items: [CloudDriveItem], from: CloudDriveLocation, to: CloudDriveLocation, copy: Bool, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo?
    func importFiles(_ urls: [URL], into: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo?
    func delete(_ items: [CloudDriveItem], progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo?
}

enum CloudDriveError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

enum CloudDriveFiles {
    @TaskLocal static var coordinationCancellation: DriveCoordinationCancellation?
    static func availableName(_ name: String, in directory: URL) -> URL {
        let safe = FinderFileOpenStorage.safeFilename(name)
        let original = directory.appendingPathComponent(safe), ext = original.pathExtension
        let stem = original.deletingPathExtension().lastPathComponent
        var candidate = original, suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(stem) (\(suffix))" + (ext.isEmpty ? "" : ".\(ext)")); suffix += 1
        }
        return candidate
    }
    static func validName(_ name: String) throws -> String {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != ".", value != "..", !value.contains("/"), !value.contains(":"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CloudDriveError.message("Enter a name without slashes, colons or control characters.")
        }
        return value
    }
    static func privateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else { throw CloudDriveError.message("The private working folder is unavailable.") }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    static func detached<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        let cancellation = DriveCoordinationCancellation()
        let task = Task.detached(priority: .utility) {
            try $coordinationCancellation.withValue(cancellation) { try operation() }
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel(); cancellation.cancel() })
    }
    static func coordinated<T>(_ url: URL, writing: Bool = false, _ operation: (URL) throws -> T) throws -> T {
        try Task.checkCancellation()
        let coordinator = NSFileCoordinator()
        coordinationCancellation?.add(coordinator)
        defer { coordinationCancellation?.remove(coordinator) }
        var error: NSError?
        var result: Result<T, Error>?
        if writing {
            coordinator.coordinate(writingItemAt: url, options: [], error: &error) { value in result = Result { try operation(value) } }
        } else {
            coordinator.coordinate(readingItemAt: url, options: [], error: &error) { value in result = Result { try operation(value) } }
        }
        if let error { if Task.isCancelled { throw CancellationError() }; throw error }
        guard let result else { throw CloudDriveError.message("The file provider did not grant access.") }
        return try result.get()
    }
}

final class DriveCoordinationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var coordinators: [ObjectIdentifier: NSFileCoordinator] = [:]
    private var cancelled = false
    func add(_ value: NSFileCoordinator) {
        lock.lock(); coordinators[ObjectIdentifier(value)] = value; let cancelled = cancelled; lock.unlock()
        if cancelled { value.cancel() }
    }
    func remove(_ value: NSFileCoordinator) { lock.lock(); coordinators[ObjectIdentifier(value)] = nil; lock.unlock() }
    func cancel() {
        lock.lock(); cancelled = true; let current = Array(coordinators.values); lock.unlock()
        current.forEach { $0.cancel() }
    }
}

/// Membership deltas keep Undo from removing media that was already in an album.
struct PhotosAlbumMembershipPlan {
    let added: Set<String>
    let removed: Set<String>
    init(selected: Set<String>, source: Set<String>, destination: Set<String>, move: Bool, sameAlbum: Bool) {
        added = selected.subtracting(destination)
        removed = move && !sameAlbum ? selected.intersection(source) : []
    }
}

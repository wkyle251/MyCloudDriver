import AppKit
import Foundation
import UniformTypeIdentifiers

enum CloudDriveKind: String, CaseIterable, Identifiable, Codable {
    case pikpak, icloud, photos, local
    var id: Self { self }
    var title: String { switch self { case .pikpak: return "PikPak"; case .icloud: return "iCloud Drive"; case .photos: return "Apple Photos"; case .local: return "Local Disk" } }
    var symbol: String { switch self { case .pikpak: return "cloud.fill"; case .icloud: return "icloud.fill"; case .photos: return "photo.on.rectangle.angled"; case .local: return "internaldrive" } }
    var subtitle: String { switch self {
    case .pikpak: return "Your cloud files, shared links and transfers."
    case .icloud: return "Your iCloud files and folders, together on this Mac."
    case .photos: return "Your photos, videos and albums, including iCloud Photos."
    case .local: return "Folders on this Mac, external disks and network shares."
    } }
    var containerName: String { self == .photos ? "Album" : "Folder" }
}

struct CloudDriveLocation: Hashable, Identifiable, Sendable, Codable {
    let id: String
    let title: String
    var url: URL?
    var isLibrary: Bool = false
}

struct CloudDriveItem: Hashable, Identifiable, Sendable, Codable {
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
    /// Storage identity and revision captured by discovery, retained in scan reports.
    var revision: String? = nil
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
    /// Media preparation can download a source and then process it. Processing has no network transfer rate.
    enum Activity: Sendable, Equatable { case transferring, processing }
    var message: String
    var completed: Int = 0
    var total: Int = 0
    var fraction: Double? = nil
    var bytes: UInt64 = 0
    var fileSize: UInt64 = 0
    var activity: Activity? = nil
}
typealias CloudDriveProgressHandler = @Sendable (CloudDriveProgress) -> Void

struct CloudDriveMeasurement: Sendable, Equatable {
    var files = 0
    var bytes: UInt64 = 0
    /// Total bytes under every folder the walk visited, by item ID. Calculate on
    /// a parent sizes its subfolders from the same pass. Empty for drives
    /// without folders, and not part of equality: totals are what callers compare.
    var folders: [String: UInt64] = [:]

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.files == rhs.files && lhs.bytes == rhs.bytes }
}

struct CloudDriveUndo: @unchecked Sendable {
    let id = UUID()
    let title: String
    var diskTrashEntryIDs: Set<UUID> = []
    let apply: @Sendable () async throws -> CloudDriveUndo
}

protocol NativeCloudDrive: AnyObject, Sendable {
    var kind: CloudDriveKind { get }
    var root: CloudDriveLocation { get }
    var supportsSimilarityPreviews: Bool { get }
    func previewForSimilarity(_ item: CloudDriveItem, progress: @escaping CloudDriveProgressHandler) async throws -> Data
    func list(_ location: CloudDriveLocation, offset: Int, search: String) async throws -> CloudDrivePage
    func materialize(_ item: CloudDriveItem, directory: URL, progress: @escaping CloudDriveProgressHandler) async throws -> URL
    func scanItems(_ items: [CloudDriveItem], location: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> [CloudDriveItem]
    func discoverItems(_ items: [CloudDriveItem], location: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler,
                       found: @escaping @Sendable (CloudDriveItem) -> Void) async throws
    /// Total size of the files under `items`, or of the whole location when
    /// `items` is empty. `directory` holds any original fetched to measure it.
    func measureFiles(_ items: [CloudDriveItem], location: CloudDriveLocation, directory: URL,
                      progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveMeasurement
    func createContainer(_ name: String, in location: CloudDriveLocation) async throws -> CloudDriveUndo?
    func rename(_ item: CloudDriveItem, to name: String) async throws -> CloudDriveUndo?
    func relocate(_ items: [CloudDriveItem], from: CloudDriveLocation, to: CloudDriveLocation, copy: Bool, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo?
    func importFiles(_ urls: [URL], into: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo?
    func delete(_ items: [CloudDriveItem], progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo?
    func deleteVerified(_ items: [CloudDriveItem], progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo?
    func refreshedItems(_ items: [CloudDriveItem]) async throws -> [CloudDriveItem]
    func streamForSimilarity(_ item: CloudDriveItem, pipe: URL, capacity: UInt64,
                             progress: @escaping CloudDriveProgressHandler) async throws -> URL
}

extension NativeCloudDrive {
    var supportsSimilarityPreviews: Bool { false }
    /// A drive that publishes no size for an item fetches the original first.
    func measureFiles(_ items: [CloudDriveItem], location: CloudDriveLocation, directory: URL,
                      progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveMeasurement {
        let files = try await scanItems(items, location: location, progress: progress)
        var total = CloudDriveMeasurement(files: files.count)
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            if let bytes = file.bytes { total.bytes += bytes }
            else {
                let url = try await materialize(file, directory: directory, progress: progress)
                total.bytes += UInt64(max(0, try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0))
                if kind == .photos { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            }
            progress(.init(message: "Calculating original size", completed: index + 1, total: files.count))
        }
        return total
    }
    func previewForSimilarity(_ item: CloudDriveItem, progress: @escaping CloudDriveProgressHandler) async throws -> Data {
        throw CloudDriveError.message("This drive does not provide similarity previews.")
    }
    func refreshedItems(_ items: [CloudDriveItem]) async throws -> [CloudDriveItem] {
        throw CloudDriveError.message("This drive cannot verify the files to keep. No files were moved to Trash.")
    }
    func deleteVerified(_ items: [CloudDriveItem], progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? {
        let fresh = try await refreshedItems(items)
        guard fresh.count == items.count, zip(fresh, items).allSatisfy({ $0.id == $1.id && $0.revision != nil && $0.revision == $1.revision }) else {
            throw CloudDriveError.message("A file changed after comparison. No files were moved to Trash. Scan the group again.")
        }
        return try await delete(items, progress: progress)
    }
    /// A scan asks for an original in RAM whenever the drive published no local
    /// path for it. A drive that cannot read its own storage directly still
    /// answers: the original is materialized into a private directory, streamed
    /// into the helper's pipe and removed. Photos overrides this so a real asset
    /// is never written to a regular file on the way through.
    func streamForSimilarity(_ item: CloudDriveItem, pipe: URL, capacity: UInt64,
                             progress: @escaping CloudDriveProgressHandler) async throws -> URL {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("MemorySource-\(UUID().uuidString)", isDirectory: true)
        try CloudDriveFiles.privateDirectory(staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        let original = try await materialize(item, directory: staging, progress: progress)
        try Task.checkCancellation()
        try await CloudDriveFiles.detached {
            let source = try FileHandle(forReadingFrom: original)
            defer { try? source.close() }
            let destination = try SimilarityMemoryPipe.open(pipe)
            defer { try? destination.close() }
            var sent: UInt64 = 0
            while let chunk = try source.read(upToCount: 1 << 20), !chunk.isEmpty {
                try CloudDriveFiles.checkCancellation()
                guard sent + UInt64(chunk.count) <= capacity else {
                    throw CloudDriveError.message("This original needs more RAM. Increase Scan Resources and retry.")
                }
                try SimilarityMemoryPipe.write(chunk, to: destination)
                sent += UInt64(chunk.count)
            }
        }
        return pipe
    }
    func discoverItems(_ items: [CloudDriveItem], location: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler,
                       found: @escaping @Sendable (CloudDriveItem) -> Void) async throws {
        for item in try await scanItems(items, location: location, progress: progress) {
            try Task.checkCancellation(); found(item)
        }
    }
    func scanItemStream(_ items: [CloudDriveItem], location: CloudDriveLocation,
                        progress: @escaping CloudDriveProgressHandler) -> AsyncThrowingStream<CloudDriveItem, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await discoverItems(items, location: location, progress: progress) { item in continuation.yield(item) }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

final class CloudDriveScanCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [CloudDriveItem] = []
    func append(_ item: CloudDriveItem) { lock.lock(); defer { lock.unlock() }; values.append(item) }
    var items: [CloudDriveItem] { lock.lock(); defer { lock.unlock() }; return values }
}

enum CloudDriveError: LocalizedError {
    case message(String)
    case waiting(String)
    var errorDescription: String? {
        switch self { case .message(let message), .waiting(let message): return message }
    }
}

enum CloudDriveFiles {
    @TaskLocal static var coordinationCancellation: DriveCoordinationCancellation?
    // NSFileCoordinator and paused FileHandle copies can block. Keep those
    // waits off Swift's cooperative executor so its actors can resume/cancel
    // transfers and other async app features can continue to run.
    private static let fileQueue = DispatchQueue(label: "MyCloudDriver.file-coordination", qos: .utility, attributes: .concurrent)
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
        let cancellation = DriveCoordinationCancellation(), transferControl = NativeTransferControl.current
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                fileQueue.async {
                    continuation.resume(with: Result {
                        try cancellation.check()
                        return try NativeTransferControl.$current.withValue(transferControl) {
                            try $coordinationCancellation.withValue(cancellation) { try operation() }
                        }
                    })
                }
            }
        }, onCancel: { cancellation.cancel(); transferControl?.cancel() })
    }
    static func checkCancellation() throws {
        try coordinationCancellation?.check()
        try Task.checkCancellation()
    }
    static func coordinated<T>(_ url: URL, writing: Bool = false, _ operation: (URL) throws -> T) throws -> T {
        try checkCancellation()
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
        if let error { try checkCancellation(); throw error }
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
    func check() throws {
        lock.lock(); let cancelled = cancelled; lock.unlock()
        if cancelled { throw CancellationError() }
    }
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

import Darwin
import Foundation

struct DiskTrashItem: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let originalPath: String
    let deletedAt: Date
    let isFolder: Bool
    let bytes: UInt64?
}

/// A recoverable, same-volume Trash. Every entry is journalled before its
/// original is moved. Only marked app storage and validated entry IDs are ever
/// emptied; an existing user's Trash folder is never adopted wholesale.
final class DiskTrash: @unchecked Sendable {
    let volumeRoot: URL
    let volumeID: String?
    var folder: URL { volumeRoot.appendingPathComponent("Trash", isDirectory: true) }
    var storage: URL { folder.appendingPathComponent("MyCloudDriver", isDirectory: true) }
    private let fm = FileManager.default

    private struct Marker: Codable {
        let format: String
        let id: UUID
    }
    private struct Record: Codable {
        let version: Int
        let id: UUID
        let volumeID: String
        let components: [String]
        let name: String
        let deletedAt: Date
        let isFolder: Bool
        let bytes: UInt64?
    }
    private static let format = "com.wky.MyCloudDriver.disk-trash.v1"
    private static let recordName = ".original-location.json"

    init(volumeRoot: URL, volumeID: String?) {
        self.volumeRoot = volumeRoot.standardizedFileURL
        self.volumeID = volumeID
    }

    func contains(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path == storage.path || path.hasPrefix(storage.path + "/")
    }

    static func isManagedStorage(_ url: URL) -> Bool {
        guard url.lastPathComponent == "MyCloudDriver", url.deletingLastPathComponent().lastPathComponent == "Trash" else { return false }
        let marker = url.appendingPathComponent(".store.json", isDirectory: false)
        var value = stat()
        guard lstat(marker.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG, value.st_size <= 4_096,
              let data = try? Data(contentsOf: marker), let stored = try? JSONDecoder().decode(Marker.self, from: data) else { return false }
        return stored.format == format
    }

    func prepare() async throws {
        try await CloudDriveFiles.detached { try self.locked(create: true, writing: true) { } }
    }

    func list() async throws -> [DiskTrashItem] {
        try await CloudDriveFiles.detached {
            try self.locked(create: false, writing: false) {
                try self.records().map { record in
                    DiskTrashItem(id: record.id, name: record.name,
                        originalPath: "/" + record.components.joined(separator: "/"), deletedAt: record.deletedAt,
                        isFolder: record.isFolder, bytes: record.bytes)
                }.sorted { $0.deletedAt == $1.deletedAt ? $0.id.uuidString < $1.id.uuidString : $0.deletedAt > $1.deletedAt }
            }
        }
    }

    func trash(_ urls: [URL], title: String, progress: @escaping CloudDriveProgressHandler,
               validate: (@Sendable (URL) throws -> Void)? = nil) async throws -> CloudDriveUndo {
        let ids = try await CloudDriveFiles.detached {
            try self.locked(create: true, writing: true) {
                let sources = try self.sources(urls)
                var moved: [(Record, URL)] = []
                do {
                    for (index, source) in sources.enumerated() {
                        try CloudDriveFiles.checkCancellation()
                        try self.validateVolume(writing: true)
                        let values = try source.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                        let record = Record(version: 1, id: UUID(), volumeID: self.volumeID!,
                            components: self.relative(source), name: source.lastPathComponent, deletedAt: Date(),
                            isFolder: values.isDirectory == true,
                            bytes: values.isDirectory == true ? nil : values.fileSize.map { UInt64(max(0, $0)) })
                        let directory = self.directory(record.id)
                        try self.fm.createDirectory(at: directory, withIntermediateDirectories: false)
                        do {
                            // A crash after the rename still leaves the original location recoverable.
                            try JSONEncoder().encode(record).write(to: directory.appendingPathComponent(Self.recordName, isDirectory: false), options: .atomic)
                            try self.move(source, self.payload(record)) { try validate?(source) }
                        } catch {
                            // Never remove a payload after a move whose result is uncertain.
                            if self.info(self.payload(record)) == nil { try? self.fm.removeItem(at: directory) }
                            throw error
                        }
                        moved.append((record, source))
                        progress(.init(message: "Moving to this disk’s Trash", completed: index + 1, total: sources.count))
                    }
                } catch {
                    for (record, source) in moved.reversed() {
                        if (try? self.move(self.payload(record), source)) != nil { try? self.removeEmptyEntry(record) }
                    }
                    throw error
                }
                return moved.map { $0.0.id }
            }
        }
        return restoreUndo(ids, title: title)
    }

    func putBack(_ ids: [UUID], title: String = "Put Back") async throws -> CloudDriveUndo {
        let originals = try await CloudDriveFiles.detached {
            try self.locked(create: false, writing: true) {
                let records = try self.selected(ids)
                let destinations = try records.map { record -> URL in
                    let destination = try self.original(record)
                    guard self.info(destination) == nil else {
                        throw CloudDriveError.message("“\(record.name)” already exists in its original location. Move or rename it before using Put Back.")
                    }
                    return destination
                }
                var moved: [(Record, URL)] = []
                do {
                    for (record, destination) in zip(records, destinations) {
                        try CloudDriveFiles.checkCancellation()
                        try self.ensureOriginalParents(record)
                        try self.move(self.payload(record), destination)
                        moved.append((record, destination))
                    }
                } catch {
                    for (record, destination) in moved.reversed() { try? self.move(destination, self.payload(record)) }
                    throw error
                }
                for record in records { try? self.removeEmptyEntry(record) }
                return destinations
            }
        }
        return .init(title: title) { try await self.trash(originals, title: title, progress: { _ in }) }
    }

    /// IDs are snapshotted when the confirmation opens. A new deletion made by
    /// another window while that dialog is open must survive this operation.
    func empty(_ ids: [UUID], progress: @escaping CloudDriveProgressHandler) async throws {
        try await CloudDriveFiles.detached {
            try self.locked(create: false, writing: true) {
                let records = try self.selected(ids)
                for (index, record) in records.enumerated() {
                    try CloudDriveFiles.checkCancellation()
                    try self.validateVolume(writing: true)
                    try self.verifyEntry(record)
                    try self.fm.removeItem(at: self.directory(record.id))
                    progress(.init(message: "Emptying this disk’s Trash", completed: index + 1, total: records.count))
                }
            }
        }
    }

    private func restoreUndo(_ ids: [UUID], title: String) -> CloudDriveUndo {
        .init(title: title, diskTrashEntryIDs: Set(ids)) { try await self.putBack(ids, title: title) }
    }

    private func validateVolume(writing: Bool) throws {
        guard let volumeID else { throw CloudDriveError.message("This disk’s identity could not be verified. Reconnect it before using Trash.") }
        try LocalFileAccess.validate(volumeRoot, volumeID: volumeID, directory: true, writing: writing)
    }

    private func info(_ url: URL) -> stat? {
        var value = stat()
        return lstat(url.path, &value) == 0 ? value : nil
    }

    private func safeDirectory(_ url: URL, create: Bool = false) throws {
        if let value = info(url) {
            guard value.st_mode & S_IFMT == S_IFDIR else {
                throw CloudDriveError.message("The Trash location contains a link or a file. It has been left unchanged.")
            }
        } else if create {
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
        } else { throw CloudDriveError.message("This disk’s Trash is unavailable. Reconnect the disk and try again.") }
    }

    private func locked<T>(create: Bool, writing: Bool, _ operation: () throws -> T) throws -> T {
        try CloudDriveFiles.checkCancellation()
        try validateVolume(writing: writing)
        try safeDirectory(folder, create: create)
        let lockURL = folder.appendingPathComponent(".MyCloudDriver.lock", isDirectory: false)
        let descriptor = open(lockURL.path, (writing ? O_RDWR | O_CREAT : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw CloudDriveError.message("Cannot access this disk’s Trash. Check its connection and write permissions.") }
        defer { close(descriptor) }
        var value = stat()
        guard fstat(descriptor, &value) == 0, value.st_mode & S_IFMT == S_IFREG else {
            throw CloudDriveError.message("The Trash lock is unavailable. Its contents have been left unchanged.")
        }
        while flock(descriptor, (writing ? LOCK_EX : LOCK_SH) | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            try CloudDriveFiles.checkCancellation()
            Thread.sleep(forTimeInterval: 0.02)
        }
        defer { flock(descriptor, LOCK_UN) }
        try validateVolume(writing: writing)
        let marker = storage.appendingPathComponent(".store.json", isDirectory: false)
        if info(storage) == nil, create {
            try safeDirectory(storage, create: true)
            do { try JSONEncoder().encode(Marker(format: Self.format, id: UUID())).write(to: marker, options: .atomic) }
            catch { try? fm.removeItem(at: storage); throw error }
        }
        try safeDirectory(storage)
        guard let markerInfo = info(marker), markerInfo.st_mode & S_IFMT == S_IFREG, markerInfo.st_size <= 4_096,
              let data = try? Data(contentsOf: marker), let stored = try? JSONDecoder().decode(Marker.self, from: data), stored.format == Self.format else {
            throw CloudDriveError.message("Trash/MyCloudDriver was not created by this app. Its existing contents have been left unchanged.")
        }
        return try operation()
    }

    private func directory(_ id: UUID) -> URL { storage.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func payload(_ record: Record) -> URL { directory(record.id).appendingPathComponent(record.name, isDirectory: record.isFolder) }
    private func relative(_ url: URL) -> [String] { Array(url.pathComponents.dropFirst(volumeRoot.pathComponents.count)) }

    private func load(_ id: UUID) throws -> Record {
        let directory = directory(id)
        try safeDirectory(directory)
        let url = directory.appendingPathComponent(Self.recordName, isDirectory: false)
        guard let value = info(url), value.st_mode & S_IFMT == S_IFREG, value.st_size <= 65_536,
              let data = try? Data(contentsOf: url), let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == 1, record.id == id, record.volumeID == volumeID,
              !record.components.isEmpty, record.components.allSatisfy(Self.safeComponent),
              record.components.last == record.name, Self.safeComponent(record.name), record.name != Self.recordName else {
            throw CloudDriveError.message("A Trash record is damaged or belongs to another disk. Its contents have been kept.")
        }
        return record
    }

    private static func safeComponent(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.utf8.contains(0)
    }

    private func verifyEntry(_ record: Record) throws {
        try safeDirectory(directory(record.id))
        let names = Set(try fm.contentsOfDirectory(atPath: directory(record.id).path))
        guard names == [Self.recordName, record.name], let value = info(payload(record)),
              value.st_mode & S_IFMT == (record.isFolder ? S_IFDIR : S_IFREG) else {
            throw CloudDriveError.message("An item in Trash changed or is no longer available. Refresh Trash before continuing.")
        }
    }

    private func records() throws -> [Record] {
        var records: [Record] = []
        for name in try fm.contentsOfDirectory(atPath: storage.path) {
            try CloudDriveFiles.checkCancellation()
            guard let id = UUID(uuidString: name), id.uuidString == name else { continue }
            let record = try load(id)
            // A journal written before an interrupted move, or left after a
            // successful restore, must not look like another deleted file.
            guard info(payload(record)) != nil else { continue }
            try verifyEntry(record)
            records.append(record)
        }
        return records
    }

    private func selected(_ ids: [UUID]) throws -> [Record] {
        var seen = Set<UUID>()
        return try ids.filter { seen.insert($0).inserted }.map { id in
            let record = try load(id)
            try verifyEntry(record)
            return record
        }
    }

    private func sources(_ urls: [URL]) throws -> [URL] {
        var seen = Set<String>()
        let sources = try urls.map { url -> URL in
            let url = url.standardizedFileURL
            guard url.path.hasPrefix(volumeRoot.path + "/"), !contains(url),
                  url != folder, !storage.path.hasPrefix(url.path + "/"),
                  url.lastPathComponent != Self.recordName, let value = info(url),
                  value.st_mode & S_IFMT == S_IFREG || value.st_mode & S_IFMT == S_IFDIR,
                  url.resolvingSymlinksInPath().path == url.path else {
                throw CloudDriveError.message("This item cannot be moved into this disk’s Trash. The drive and Trash folders are protected.")
            }
            try LocalFileAccess.validate(url, volumeID: volumeID)
            return url
        }.filter { seen.insert($0.path).inserted }
        let folders = Set(sources.filter { info($0)!.st_mode & S_IFMT == S_IFDIR }.map(\.path))
        return sources.filter { url in !folders.contains { url.path.hasPrefix($0 + "/") } }
    }

    private func original(_ record: Record) throws -> URL {
        let url = record.components.enumerated().reduce(volumeRoot) { value, element in
            value.appendingPathComponent(element.element, isDirectory: element.offset < record.components.count - 1 || record.isFolder)
        }
        guard !contains(url), url != folder, !storage.path.hasPrefix(url.path + "/") else {
            throw CloudDriveError.message("The original location is not safe to restore. Its contents have been kept in Trash.")
        }
        try checkParents(record, create: false)
        return url
    }

    private func checkParents(_ record: Record, create: Bool) throws {
        var parent = volumeRoot
        for component in record.components.dropLast() {
            parent.appendPathComponent(component, isDirectory: true)
            if info(parent) == nil && !create { continue }
            try safeDirectory(parent, create: create)
            try LocalFileAccess.validate(parent, volumeID: volumeID, directory: true, writing: create)
        }
    }
    private func ensureOriginalParents(_ record: Record) throws { try checkParents(record, create: true) }

    private func removeEmptyEntry(_ record: Record) throws {
        let names = try fm.contentsOfDirectory(atPath: directory(record.id).path)
        guard names == [Self.recordName] else { return }
        try fm.removeItem(at: directory(record.id))
    }

    private func move(_ from: URL, _ to: URL, validate: (() throws -> Void)? = nil) throws {
        try validateVolume(writing: true)
        let coordinator = NSFileCoordinator()
        CloudDriveFiles.coordinationCancellation?.add(coordinator)
        defer { CloudDriveFiles.coordinationCancellation?.remove(coordinator) }
        var error: NSError?, result: Result<Void, Error>?
        coordinator.coordinate(writingItemAt: from, options: .forMoving, writingItemAt: to, options: [], error: &error) { source, destination in
            result = Result {
                try CloudDriveFiles.checkCancellation()
                try validate?()
                guard self.info(destination) == nil else { throw CloudDriveError.message("An item already exists at the destination. It has not been replaced.") }
                try self.fm.moveItem(at: source, to: destination)
                coordinator.item(at: source, didMoveTo: destination)
            }
        }
        if let error { throw error }
        guard let result else { throw CloudDriveError.message("The disk did not complete the move. Refresh Trash before trying again.") }
        try result.get()
    }
}

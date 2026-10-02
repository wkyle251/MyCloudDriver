import Foundation
import UniformTypeIdentifiers

final class ICloudDriveProvider: NativeCloudDrive, @unchecked Sendable {
    let kind: CloudDriveKind
    let root: CloudDriveLocation
    private let securityScopedURL: URL?
    let volumeID: String?
    init(rootURL: URL, kind: CloudDriveKind = .icloud, volumeID: String? = nil) {
        precondition(kind == .icloud || kind == .local)
        self.kind = kind
        // A scan can own a folder independently of the Browser's connection.
        // Keep the picker's access alive for this provider's entire lifetime.
        securityScopedURL = rootURL.startAccessingSecurityScopedResource() ? rootURL : nil
        self.volumeID = volumeID ?? LocalFileAccess.volumeID(rootURL)
        let rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        root = .init(id: rootURL.absoluteString, title: kind == .local ? (rootURL.lastPathComponent.isEmpty ? "Local Disk" : rootURL.lastPathComponent) : kind.title, url: rootURL)
    }
    deinit { securityScopedURL?.stopAccessingSecurityScopedResource() }
    func validateAccess() throws {
        guard let url = root.url else { throw CloudDriveError.message("Choose an available folder or disk.") }
        try LocalFileAccess.validate(url, volumeID: volumeID, directory: true)
    }
    func uploadSources(_ items: [CloudDriveItem]) throws -> [URL] {
        try items.map { try LocalFileAccess.validate(checked($0.url)) }
    }
    private func checked(_ url: URL?) throws -> URL {
        try validateAccess()
        guard let url, let base = root.url else { throw CloudDriveError.message("Reconnect \(kind.title) in Settings.") }
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved == base || resolved.path.hasPrefix(base.path == "/" ? "/" : base.path + "/") else {
            throw CloudDriveError.message("This item is outside the connected drive.")
        }
        return resolved
    }
    static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        .fileSizeKey, .contentModificationDateKey, .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey, .isHiddenKey]

    static func item(_ url: URL) throws -> CloudDriveItem {
        // File coordination can return /private/var for an input under /var.
        // Use one resolved identity for listings, scan results and reveal.
        let url = url.standardizedFileURL.resolvingSymlinksInPath()
        return item(url, values: try url.resourceValues(forKeys: keys))
    }
    /// A non-symlink entry listed (with `keys` prefetched) from `folder`, which
    /// is already resolved. Its resolved identity is that folder plus its name,
    /// so neither the path nor the prefetched values are read from disk again.
    static func item(listed url: URL, in folder: URL) throws -> CloudDriveItem {
        let values = try url.resourceValues(forKeys: keys)
        return item(folder.appendingPathComponent(url.lastPathComponent, isDirectory: values.isDirectory == true), values: values)
    }
    private static func item(_ url: URL, values: URLResourceValues) -> CloudDriveItem {
        let type = UTType(filenameExtension: url.pathExtension)
        return .init(id: url.absoluteString, name: url.lastPathComponent, isFolder: values.isDirectory == true,
            bytes: values.isDirectory == true ? nil : values.fileSize.map { UInt64(max(0, $0)) },
            modified: values.contentModificationDate, url: url,
            mediaType: type?.conforms(to: .image) == true ? "image" : type?.conforms(to: .movie) == true ? "video"
                : type?.conforms(to: .audio) == true ? "audio" : "file",
            isDownloaded: values.isUbiquitousItem != true || values.ubiquitousItemDownloadingStatus == .current || values.ubiquitousItemDownloadingStatus == .downloaded)
    }
    func refreshedItems(_ items: [CloudDriveItem]) async throws -> [CloudDriveItem] {
        let urls = try items.map { try checked($0.url) }
        return try await CloudDriveFiles.detached {
            try urls.map { url in
                try CloudDriveFiles.checkCancellation()
                return try CloudDriveFiles.coordinated(url) { try Self.item($0) }
            }
        }
    }
    func list(_ location: CloudDriveLocation, offset: Int, search: String) async throws -> CloudDrivePage {
        let folder = try checked(location.url)
        return try await CloudDriveFiles.detached {
            let children: [URL] = try CloudDriveFiles.coordinated(folder) { url in
                try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(Self.keys), options: [.skipsHiddenFiles])
            }
            var items: [CloudDriveItem] = []
            for url in children {
                try CloudDriveFiles.checkCancellation()
                guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { continue }
                let item = try Self.item(listed: url, in: folder)
                if search.isEmpty || item.name.localizedStandardContains(search) { items.append(item) }
            }
            items.sort { $0.isFolder == $1.isFolder ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.isFolder }
            try CloudDriveFiles.checkCancellation()
            return .init(items: items, total: items.count)
        }
    }
    func materialize(_ item: CloudDriveItem, directory: URL, progress: @escaping CloudDriveProgressHandler) async throws -> URL {
        let url = try checked(item.url)
        return try await CloudDriveFiles.detached {
            try LocalFileAccess.validate(url)
            try Self.download(url, progress: progress)
            return url
        }
    }
    private static func download(_ url: URL, progress: CloudDriveProgressHandler) throws {
        let values = try url.resourceValues(forKeys: keys)
        guard values.isUbiquitousItem == true else { return }
        if values.ubiquitousItemDownloadingStatus != .current && values.ubiquitousItemDownloadingStatus != .downloaded {
            progress(.init(message: "Downloading \(url.lastPathComponent)…"))
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
        // Coordination waits for File Provider materialization on this worker,
        // never on the main actor. The accessor rechecks cancellation before use.
        try CloudDriveFiles.coordinated(url) { coordinated in
            try CloudDriveFiles.checkCancellation()
            let file = try FileHandle(forReadingFrom: coordinated)
            try file.close()
        }
    }
    func scanItems(_ items: [CloudDriveItem], location: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> [CloudDriveItem] {
        let collector = CloudDriveScanCollector()
        try await discoverItems(items, location: location, progress: progress) { collector.append($0) }
        return collector.items
    }
    func discoverItems(_ items: [CloudDriveItem], location: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler,
                       found: @escaping @Sendable (CloudDriveItem) -> Void) async throws {
        let roots = try items.isEmpty ? [checked(location.url)] : items.map { try checked($0.url) }
        try await CloudDriveFiles.detached {
            var pending = roots, count = 0, seen = Set<URL>()
            while let url = pending.popLast() {
                try CloudDriveFiles.checkCancellation()
                guard seen.insert(url.standardizedFileURL).inserted else { continue }
                do {
                    let v = try url.resourceValues(forKeys: Self.keys)
                    if v.isSymbolicLink == true || v.isHidden == true { continue }
                    if v.isDirectory == true {
                        let children = try CloudDriveFiles.coordinated(url) {
                            try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: Array(Self.keys), options: [.skipsHiddenFiles])
                        }
                        pending.append(contentsOf: children)
                    } else if v.isRegularFile == true {
                        count += 1; found(try Self.item(url))
                    }
                    if count % 25 == 0 { progress(.init(message: "Finding \(self.kind.title) files", completed: count)) }
                } catch {
                    guard Self.missingDuringScan(error) else { throw error }
                    // A disconnected disk must not look like an empty folder.
                    try self.validateAccess()
                }
            }
            try self.validateAccess()
        }
    }
    private static let sizeKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        .isHiddenKey, .fileSizeKey]

    /// Same walk and exclusions as `discoverItems`, but sums the sizes each
    /// folder listing already prefetched instead of resolving and re-reading
    /// every file into an item. Local folders skip file coordination.
    func measureFiles(_ items: [CloudDriveItem], location: CloudDriveLocation, directory: URL,
                      progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveMeasurement {
        let roots = try items.isEmpty ? [checked(location.url)] : items.map { try checked($0.url) }
        return try await CloudDriveFiles.detached {
            var pending = roots, seen = Set<URL>(), total = CloudDriveMeasurement()
            var reported = Date.distantPast
            let list = { (folder: URL) in
                try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(Self.sizeKeys),
                                                            options: [.skipsHiddenFiles])
            }
            while let url = pending.popLast() {
                try CloudDriveFiles.checkCancellation()
                guard seen.insert(url.standardizedFileURL).inserted else { continue }
                do {
                    let v = try url.resourceValues(forKeys: Self.sizeKeys)
                    if v.isSymbolicLink == true || v.isHidden == true { continue }
                    if v.isDirectory == true {
                        // An iCloud folder can be a placeholder its File Provider fills in first.
                        pending.append(contentsOf: try self.kind == .icloud ? CloudDriveFiles.coordinated(url, list) : list(url))
                    } else if v.isRegularFile == true {
                        var size = v.fileSize
                        if size == nil {
                            // As before, an original without a size is fetched, then measured.
                            try Self.download(url, progress: progress)
                            var fetched = url
                            fetched.removeAllCachedResourceValues()
                            size = try fetched.resourceValues(forKeys: [.fileSizeKey]).fileSize
                        }
                        total.files += 1
                        total.bytes += UInt64(max(0, size ?? 0))
                    }
                    // Progress is for people: a few updates a second, not one per file.
                    if Date().timeIntervalSince(reported) >= 0.25 {
                        reported = Date()
                        progress(.init(message: "Calculating \(self.kind.title) size", completed: total.files))
                    }
                } catch {
                    guard Self.missingDuringScan(error) else { throw error }
                    // A disconnected disk must not look like an empty folder.
                    try self.validateAccess()
                }
            }
            try self.validateAccess()
            return total
        }
    }

    static func missingDuringScan(_ error: Error) -> Bool {
        let value = error as NSError
        return (value.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(value.code))
            || (value.domain == NSPOSIXErrorDomain && value.code == Int(ENOENT))
    }
    private static func move(_ source: URL, _ destination: URL) throws {
        guard source != destination else { return }
        guard !destination.path.hasPrefix(source.path + "/") else { throw CloudDriveError.message("A folder cannot be moved into itself.") }
        let coordinator = NSFileCoordinator()
        CloudDriveFiles.coordinationCancellation?.add(coordinator)
        defer { CloudDriveFiles.coordinationCancellation?.remove(coordinator) }
        var error: NSError?, result: Result<Void, Error>?
        coordinator.coordinate(writingItemAt: source, options: .forMoving, writingItemAt: destination, options: [], error: &error) { source, destination in
            result = Result {
                guard !FileManager.default.fileExists(atPath: destination.path) else { throw CloudDriveError.message("An item named “\(destination.lastPathComponent)” already exists.") }
                try FileManager.default.moveItem(at: source, to: destination)
                coordinator.item(at: source, didMoveTo: destination)
            }
        }
        if let error { throw error }
        guard let result else { throw CloudDriveError.message("The file provider did not complete the move.") }
        try result.get()
    }
    private static func moveUndo(_ pairs: [(URL, URL)], title: String) -> CloudDriveUndo {
        .init(title: title) {
            try await CloudDriveFiles.detached {
                var done: [(URL, URL)] = []
                do {
                    for (from, to) in pairs { try Self.move(from, to); done.append((to, from)) }
                } catch { for (from, to) in done.reversed() { try? Self.move(from, to) }; throw error }
                return Self.moveUndo(Array(done.reversed()), title: title)
            }
        }
    }
    private static func trashUndo(_ urls: [URL], title: String) -> CloudDriveUndo {
        .init(title: title) { try await Self.trash(urls, title: title, progress: { _ in }) }
    }
    private static func trash(_ urls: [URL], title: String, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo {
        try await CloudDriveFiles.detached {
            var restore: [(URL, URL)] = []
            do {
                for (index, url) in urls.enumerated() {
                    try CloudDriveFiles.checkCancellation()
                    var trashed: NSURL?
                    try CloudDriveFiles.coordinated(url, writing: true) { try FileManager.default.trashItem(at: $0, resultingItemURL: &trashed) }
                    guard let trashed else { throw CloudDriveError.message("Finder did not return the Trash location.") }
                    restore.append((trashed as URL, url))
                    progress(.init(message: "Moving to Trash", completed: index + 1, total: urls.count))
                }
            } catch { for (from, to) in restore.reversed() { try? Self.move(from, to) }; throw error }
            // Redo uses Trash again instead of relying on an expired Trash name.
            let pairs = restore
            return .init(title: title) {
                try await CloudDriveFiles.detached {
                    var restored: [URL] = []
                    do { for (from, to) in pairs { try Self.move(from, to); restored.append(to) } }
                    catch { throw CloudDriveError.message("Some items could not be restored. Their original names may already be in use. \(error.localizedDescription)") }
                    return Self.trashUndo(restored, title: title)
                }
            }
        }
    }
    func createContainer(_ name: String, in location: CloudDriveLocation) async throws -> CloudDriveUndo? {
        let folder = try checked(location.url).appendingPathComponent(CloudDriveFiles.validName(name), isDirectory: true)
        return try await CloudDriveFiles.detached {
            try CloudDriveFiles.coordinated(folder, writing: true) { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: false) }
            return Self.trashUndo([folder], title: "New Folder")
        }
    }
    func rename(_ item: CloudDriveItem, to name: String) async throws -> CloudDriveUndo? {
        let from = try checked(item.url), to = from.deletingLastPathComponent().appendingPathComponent(try CloudDriveFiles.validName(name))
        guard from != root.url else { throw CloudDriveError.message("The connected drive root cannot be renamed.") }
        return try await CloudDriveFiles.detached { try Self.move(from, to); return Self.moveUndo([(to, from)], title: "Rename") }
    }
    func relocate(_ items: [CloudDriveItem], from: CloudDriveLocation, to: CloudDriveLocation, copy: Bool, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? {
        let urls = try items.map { try checked($0.url) }, destination = try checked(to.url)
        if copy { return try await importFiles(urls, into: to, progress: progress) }
        return try await CloudDriveFiles.detached {
            var undo: [(URL, URL)] = []
            do {
                for (index, source) in urls.enumerated() {
                    try CloudDriveFiles.checkCancellation()
                    let target = destination.appendingPathComponent(source.lastPathComponent)
                    if source == target { continue }
                    try Self.move(source, target); undo.append((target, source))
                    progress(.init(message: "Moving files", completed: index + 1, total: urls.count))
                }
            } catch { for (a, b) in undo.reversed() { try? Self.move(a, b) }; throw error }
            return Self.moveUndo(Array(undo.reversed()), title: "Move")
        }
    }
    static func copy(_ source: URL, to destination: URL, progress: CloudDriveProgressHandler, destinationVolumeID: String? = nil) throws {
        try NativeTransferControl.current?.check(); try CloudDriveFiles.checkCancellation()
        let destinationVolumeID = destinationVolumeID ?? LocalFileAccess.volumeID(destination.deletingLastPathComponent())
        try LocalFileAccess.validate(source)
        try LocalFileAccess.validate(destination.deletingLastPathComponent(), volumeID: destinationVolumeID, directory: true, writing: true)
        guard source != destination, !destination.path.hasPrefix(source.path + "/") else { throw CloudDriveError.message("Choose a destination outside the source folder.") }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw CloudDriveError.message("An item named “\(destination.lastPathComponent)” already exists.") }
        try CloudDriveFiles.coordinated(source) { source in
            try CloudDriveFiles.coordinated(destination, writing: true) { destination in
                guard !FileManager.default.fileExists(atPath: destination.path) else { throw CloudDriveError.message("An item named “\(destination.lastPathComponent)” already exists.") }
                let v = try source.resourceValues(forKeys: Self.keys)
                guard v.isSymbolicLink != true else { throw CloudDriveError.message("Symbolic links are excluded from transfers.") }
                var created = false
                do {
                    if v.isDirectory == true {
                        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                        created = true
                        for file in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                            try Self.copy(file, to: destination.appendingPathComponent(file.lastPathComponent), progress: progress, destinationVolumeID: destinationVolumeID)
                        }
                    } else {
                        let inputDescriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW)
                        guard inputDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                        let input = FileHandle(fileDescriptor: inputDescriptor, closeOnDealloc: true)
                        defer { try? input.close() }
                        let descriptor = Darwin.open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
                        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                        created = true
                        let output = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                        defer { try? output.close() }
                        var bytes: UInt64 = 0, last = Date.distantPast
                        while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty {
                            try NativeTransferControl.current?.check(); try CloudDriveFiles.checkCancellation(); try output.write(contentsOf: data); bytes += UInt64(data.count)
                            if Date().timeIntervalSince(last) > 0.25 {
                                progress(.init(message: "Copying \(source.lastPathComponent)", fraction: v.fileSize.flatMap { $0 > 0 ? Double(bytes) / Double($0) : nil }, bytes: bytes)); last = Date()
                            }
                        }
                        if let expected = v.fileSize, bytes != UInt64(max(0, expected)) {
                            throw CloudDriveError.message("“\(source.lastPathComponent)” changed or its disk became unavailable during export. Reconnect the disk and retry.")
                        }
                        try output.synchronize()
                    }
                    if let date = v.contentModificationDate { try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: destination.path) }
                } catch {
                    if created, destinationVolumeID == LocalFileAccess.volumeID(destination.deletingLastPathComponent()) {
                        try? FileManager.default.removeItem(at: destination)
                    }
                    throw error
                }
            }
        }
    }
    func importFiles(_ urls: [URL], into location: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? {
        let destination = try checked(location.url)
        return try await CloudDriveFiles.detached {
            var copied: [URL] = []
            do {
                for (index, source) in urls.enumerated() {
                    let target = destination.appendingPathComponent(source.lastPathComponent)
                    try Self.copy(source, to: target, progress: progress); copied.append(target)
                    progress(.init(message: "Copying files", completed: index + 1, total: urls.count))
                }
            } catch { for file in copied { try? FileManager.default.removeItem(at: file) }; throw error }
            return Self.trashUndo(copied, title: "Import")
        }
    }
    func delete(_ items: [CloudDriveItem], progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? {
        let urls = try items.map { try checked($0.url) }
        guard !urls.contains(root.url!) else { throw CloudDriveError.message("The connected drive root cannot be moved to Trash.") }
        return try await Self.trash(urls, title: "Move to Trash", progress: progress)
    }

    func cleanupCandidates(in location: CloudDriveLocation, empty: Bool, progress: @escaping CloudDriveProgressHandler) async throws -> [CloudDriveItem] {
        let root = try checked(location.url)
        return try await CloudDriveFiles.detached {
            var candidates: [URL] = [], visited = 0
            func walk(_ folder: URL) throws -> Bool {
                try CloudDriveFiles.checkCancellation()
                let children = try CloudDriveFiles.coordinated(folder) { try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: Array(Self.keys)) }
                var allEmpty = true
                for child in children {
                    try CloudDriveFiles.checkCancellation(); visited += 1
                    let values = try child.resourceValues(forKeys: Self.keys)
                    if values.isSymbolicLink == true { allEmpty = false; continue }
                    if values.isDirectory == true {
                        if try !walk(child) { allEmpty = false }
                    } else {
                        allEmpty = false
                        if !empty && child.lastPathComponent == ".DS_Store" && values.isRegularFile == true { candidates.append(child) }
                    }
                    if visited % 100 == 0 { progress(.init(message: "Checking \(visited.formatted()) items", completed: visited)) }
                }
                if empty && allEmpty && folder != root { candidates.append(folder) }
                return allEmpty
            }
            _ = try walk(root)
            let paths = Set(candidates.map(\.path))
            return try candidates.filter { candidate in
                var parent = candidate.deletingLastPathComponent()
                while parent != root && parent.path.count > root.path.count {
                    if paths.contains(parent.path) { return false }; parent.deleteLastPathComponent()
                }
                return true
            }.map(Self.item)
        }
    }
    private static func isEmptyTree(_ folder: URL) throws -> Bool {
        try CloudDriveFiles.checkCancellation()
        for child in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(Self.keys)) {
            let values = try child.resourceValues(forKeys: Self.keys)
            guard values.isSymbolicLink != true, values.isDirectory == true, try isEmptyTree(child) else { return false }
        }
        return true
    }
    func cleanup(_ items: [CloudDriveItem], empty: Bool, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? {
        let urls = try items.map { try checked($0.url) }
        guard !urls.contains(root.url!) else { throw CloudDriveError.message("The drive root cannot be removed.") }
        // Recheck after review. Newly arrived user content must never be trashed.
        try await CloudDriveFiles.detached {
            for url in urls {
                let safe = try CloudDriveFiles.coordinated(url) { url in
                    let values = try url.resourceValues(forKeys: Self.keys)
                    guard values.isSymbolicLink != true else { return false }
                    if empty { guard values.isDirectory == true else { return false }; return try Self.isEmptyTree(url) }
                    return values.isRegularFile == true && url.lastPathComponent == ".DS_Store"
                }
                guard safe else { throw CloudDriveError.message("The cleanup scope changed. Review it again before removing items.") }
            }
        }
        return try await Self.trash(urls, title: empty ? "Remove Empty Folders" : "Remove .DS_Store Files", progress: progress)
    }
    func merge(_ items: [CloudDriveItem], progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? {
        guard items.count > 1, items.allSatisfy(\.isFolder), let first = items.first else { throw CloudDriveError.message("Select at least two folders to merge.") }
        let target = try checked(first.url), sources = try items.dropFirst().map { try checked($0.url) }
        guard !sources.contains(where: { $0 == root.url || target.path.hasPrefix($0.path + "/") || $0.path.hasPrefix(target.path + "/") }) else { throw CloudDriveError.message("Select separate folders at the same level.") }
        let plan = try await CloudDriveFiles.detached { () -> [(URL, URL)] in
            var plan: [(URL, URL)] = [], names = Set<String>()
            for source in sources {
                for child in try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil) {
                    let destination = target.appendingPathComponent(child.lastPathComponent)
                    guard names.insert(child.lastPathComponent.lowercased()).inserted, !FileManager.default.fileExists(atPath: destination.path) else {
                        throw CloudDriveError.message("“\(child.lastPathComponent)” has a conflicting name. Rename it or move it separately, then merge again.")
                    }
                    plan.append((child, destination))
                }
            }
            return plan
        }
        let moves = try await CloudDriveFiles.detached { () -> CloudDriveUndo in
            var reverse: [(URL, URL)] = []
            do {
                for (index, pair) in plan.enumerated() {
                    try CloudDriveFiles.checkCancellation(); try Self.move(pair.0, pair.1); reverse.append((pair.1, pair.0))
                    progress(.init(message: "Merging into \(first.name)", completed: index + 1, total: plan.count))
                }
            } catch { for pair in reverse.reversed() { try? Self.move(pair.0, pair.1) }; throw error }
            return Self.moveUndo(Array(reverse.reversed()), title: "Merge Folders")
        }
        do {
            let folders = try sources.map(Self.item)
            let removed = try await cleanup(folders, empty: true, progress: progress)
            return .sequence(([removed].compactMap { $0 }) + [moves], title: "Merge Folders")
        } catch { _ = try? await moves.apply(); throw error }
    }
}

import Foundation
import Darwin
import UniformTypeIdentifiers

final class ICloudDriveProvider: NativeCloudDrive, @unchecked Sendable {
    let kind: CloudDriveKind
    let root: CloudDriveLocation
    private let securityScopedURL: URL?
    let volumeID: String?
    let diskTrash: DiskTrash?
    init(rootURL: URL, kind: CloudDriveKind = .icloud, volumeID: String? = nil, diskTrashRootURL: URL? = nil) {
        precondition(kind == .icloud || kind == .local)
        self.kind = kind
        // A scan can own a folder independently of the Browser's connection.
        // Keep the picker's access alive for this provider's entire lifetime.
        securityScopedURL = rootURL.startAccessingSecurityScopedResource() ? rootURL : nil
        self.volumeID = volumeID ?? LocalFileAccess.volumeID(rootURL)
        let rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        root = .init(id: rootURL.absoluteString, title: kind == .local ? (rootURL.lastPathComponent.isEmpty ? "Local Disk" : rootURL.lastPathComponent) : kind.title, url: rootURL)
        let values = kind == .local ? (try? rootURL.resourceValues(forKeys: [.volumeURLKey, .volumeIsLocalKey, .volumeIsInternalKey])) : nil
        let trashRoot = diskTrashRootURL ?? (values?.volumeIsLocal == false || values?.volumeIsInternal == false ? values?.volume : nil)
        let identity = self.volumeID
        diskTrash = kind == .local ? trashRoot.map { DiskTrash(volumeRoot: $0, volumeID: identity) } : nil
    }
    deinit {
        if let url = securityScopedURL { NativeFileWork.performCleanup { url.stopAccessingSecurityScopedResource() } }
    }
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
        guard diskTrash?.contains(resolved) != true else { throw CloudDriveError.message("Use the Trash tab to put back or empty deleted items.") }
        return resolved
    }
    /// What every listing needs. The system hands these back with the folder's own listing.
    static let baseKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        .fileSizeKey, .contentModificationDateKey, .isHiddenKey]
    /// Adds the iCloud download state. The system looks these up one file at a time, which on 50,000 files
    /// takes about 1.2 s instead of 0.07 s, so only a listing that can contain iCloud files asks for them.
    static let keys: Set<URLResourceKey> = baseKeys.union([.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])

    /// Every key for the iCloud Drive browser and for a folder that is itself in iCloud; the base keys for
    /// anything else, where no file can be an iCloud placeholder and every file counts as downloaded.
    static func listingKeys(for folder: URL, kind: CloudDriveKind,
                            isUbiquitous: (URL) -> Bool = { FileManager.default.isUbiquitousItem(at: $0) }) -> Set<URLResourceKey> {
        kind == .icloud || isUbiquitous(folder) ? keys : baseKeys
    }

    private static let mediaTypeLock = NSLock()
    private static var mediaTypes: [String: String] = [:]
    /// "image", "video", "audio" or "file" for a filename extension. Looking a type up and testing its
    /// conformance costs far more than a dictionary read, and a folder has a handful of distinct extensions.
    static func mediaType(forExtension ext: String) -> String {
        mediaTypeLock.lock()
        let known = mediaTypes[ext]
        mediaTypeLock.unlock()
        if let known { return known }
        let type = UTType(filenameExtension: ext)
        let value = type?.conforms(to: .image) == true ? "image" : type?.conforms(to: .movie) == true ? "video"
            : type?.conforms(to: .audio) == true ? "audio" : "file"
        mediaTypeLock.lock(); defer { mediaTypeLock.unlock() }
        if mediaTypes.count >= 1_000 { mediaTypes.removeAll(keepingCapacity: true) }
        mediaTypes[ext] = value
        return value
    }

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
        item(listed: url, in: folder, values: try url.resourceValues(forKeys: keys))
    }
    static func item(listed url: URL, in folder: URL, values: URLResourceValues) -> CloudDriveItem {
        item(folder.appendingPathComponent(url.lastPathComponent, isDirectory: values.isDirectory == true), values: values)
    }
    private static func item(_ url: URL, values: URLResourceValues) -> CloudDriveItem {
        .init(id: url.absoluteString, name: url.lastPathComponent, isFolder: values.isDirectory == true,
            bytes: values.isDirectory == true ? nil : values.fileSize.map { UInt64(max(0, $0)) },
            modified: values.contentModificationDate, url: url,
            mediaType: mediaType(forExtension: url.pathExtension),
            isDownloaded: values.isUbiquitousItem != true || values.ubiquitousItemDownloadingStatus == .current || values.ubiquitousItemDownloadingStatus == .downloaded,
            revision: fileRevision(url))
    }
    static func fileRevision(_ url: URL) -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return "\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }
    func refreshedItems(_ items: [CloudDriveItem]) async throws -> [CloudDriveItem] {
        let cancellation = DriveCoordinationCancellation(), control = NativeTransferControl.current
        return try await NativeFileWork.run(onCancel: { cancellation.cancel(); control?.cancel() }) {
            try NativeTransferControl.$current.withValue(control) {
                try CloudDriveFiles.$coordinationCancellation.withValue(cancellation) {
                    let urls = try items.map { try self.checked($0.url) }
                    return try urls.map { url in
                        try CloudDriveFiles.checkCancellation()
                        return try CloudDriveFiles.coordinated(url) { try Self.item($0) }
                    }
                }
            }
        }
    }
    func list(_ location: CloudDriveLocation, offset: Int, search: String) async throws -> CloudDrivePage {
        let cancellation = DriveCoordinationCancellation(), control = NativeTransferControl.current
        return try await NativeFileWork.run(onCancel: { cancellation.cancel(); control?.cancel() }) {
            try NativeTransferControl.$current.withValue(control) {
                try CloudDriveFiles.$coordinationCancellation.withValue(cancellation) {
                    let folder = try self.checked(location.url)
                    let resourceKeys = Self.listingKeys(for: folder, kind: self.kind)
                    let children: [URL] = try CloudDriveFiles.coordinated(folder) { url in
                        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: Array(resourceKeys), options: [.skipsHiddenFiles])
                    }
                    var items: [CloudDriveItem] = []
                    for url in children {
                        try CloudDriveFiles.checkCancellation()
                        if self.diskTrash?.contains(url) == true { continue }
                        let values = try url.resourceValues(forKeys: resourceKeys)
                        guard values.isSymbolicLink != true else { continue }
                        let item = Self.item(listed: url, in: folder, values: values)
                        if search.isEmpty || item.name.localizedStandardContains(search) { items.append(item) }
                    }
                    items.sort { $0.isFolder == $1.isFolder ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.isFolder }
                    try CloudDriveFiles.checkCancellation()
                    return .init(items: items, total: items.count)
                }
            }
        }
    }
    /// Search uses the directory's prefetched names and attributes. Constructing
    /// normal Browser items also reads an lstat revision per file, which is
    /// unnecessary for name matching and costly on network disks.
    func searchPage(_ location: CloudDriveLocation, offset: Int) async throws -> CloudDrivePage {
        guard offset == 0 else { return .init(items: [], total: 0) }
        let cancellation = DriveCoordinationCancellation()
        return try await NativeFileWork.run(priority: .low, onCancel: { cancellation.cancel() }) {
            try CloudDriveFiles.$coordinationCancellation.withValue(cancellation) {
                let folder = try self.checked(location.url)
                let resourceKeys = Self.baseKeys
                let children = try CloudDriveFiles.coordinated(folder) {
                    try FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: Array(resourceKeys), options: [.skipsHiddenFiles])
                }
                var items: [CloudDriveItem] = []
                items.reserveCapacity(children.count)
                for url in children {
                    try CloudDriveFiles.checkCancellation()
                    if self.diskTrash?.contains(url) == true { continue }
                    let values = try url.resourceValues(forKeys: resourceKeys)
                    guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true else { continue }
                    // The parent is already canonical; resolving every child's
                    // symlinks would reintroduce a storage call for every name.
                    let original = folder.appendingPathComponent(url.lastPathComponent, isDirectory: values.isDirectory == true)
                    // Name-only metadata does not establish local availability.
                    // Cached reveal must not hydrate originals for thumbnails.
                    items.append(.init(id: original.absoluteString, name: original.lastPathComponent, isFolder: values.isDirectory == true,
                        bytes: values.isDirectory == true ? nil : values.fileSize.map { UInt64(max(0, $0)) },
                        modified: values.contentModificationDate, url: original,
                        mediaType: values.isDirectory == true ? "file" : Self.mediaType(forExtension: original.pathExtension), isDownloaded: false))
                }
                try CloudDriveFiles.checkCancellation()
                // Query ranking and sorting run on the shared search worker.
                return .init(items: items, total: items.count)
            }
        }
    }

    func materialize(_ item: CloudDriveItem, directory: URL, progress: @escaping CloudDriveProgressHandler) async throws -> URL {
        let cancellation = DriveCoordinationCancellation(), control = NativeTransferControl.current
        return try await NativeFileWork.run(timeout: 300, onCancel: { cancellation.cancel(); control?.cancel() }) {
            try NativeTransferControl.$current.withValue(control) {
                try CloudDriveFiles.$coordinationCancellation.withValue(cancellation) {
                    let url = try self.checked(item.url)
                    try LocalFileAccess.validate(url)
                    try Self.download(url, progress: progress)
                    return url
                }
            }
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
                if self.diskTrash?.contains(url) == true { continue }
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
            let startedAt = ProcessInfo.processInfo.systemUptime
            let usedDiskBytes = self.usedDiskBytes(for: roots, location: location.url)
            // Each entry remembers the folder it was listed from, so a file's size lands in its
            // folder without rebuilding its path. `direct` holds the bytes in each folder's own
            // files; `visited` the folders walked, which are the only ones that get a total.
            var pending: [(url: URL, folder: String?)] = roots.map { ($0, nil) }
            var seen = Set<URL>(), total = CloudDriveMeasurement()
            var direct: [String: UInt64] = [:], visited = Set<String>()
            var reported = -Double.infinity
            // The walk finishes each selected folder before it starts the next: the unstarted ones wait at the
            // bottom of the stack, and the one in progress is exhausted when nothing but those is left.
            let rootCount = roots.count
            var started = 0, announced = -1
            let finished = { started - (pending.count > rootCount - started ? 1 : 0) }
            let report = { (done: Int, complete: Bool) in
                let size = FolderSizeProgress(files: total.files, bytes: total.bytes, usedDiskBytes: usedDiskBytes,
                    elapsedSeconds: ProcessInfo.processInfo.systemUptime - startedAt,
                    phase: complete ? .complete : done == rootCount ? .finalizing : .scanning)
                // Whole disks use their used bytes; other selections count finished roots.
                let several = rootCount > 1
                progress(.init(message: Self.tally(size, kind: self.kind), completed: several ? done : total.files,
                               total: several ? rootCount : 0,
                               fraction: size.fraction ?? (several ? (complete ? 1 : min(0.99, Double(done) / Double(rootCount))) : nil),
                               bytes: total.bytes, folderSize: size))
            }
            let list = { (folder: URL) in
                try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(Self.sizeKeys),
                                                            options: [.skipsHiddenFiles])
            }
            while true {
                // Each folder finished moves the bar at once, whatever the time since the last update.
                if finished() > announced { announced = finished(); report(announced, false) }
                guard let (url, listedFrom) = pending.popLast() else { break }
                if listedFrom == nil { started += 1 }
                try CloudDriveFiles.checkCancellation()
                if self.diskTrash?.contains(url) == true { continue }
                guard seen.insert(url.standardizedFileURL).inserted else { continue }
                do {
                    let v = try url.resourceValues(forKeys: Self.sizeKeys)
                    if v.isSymbolicLink == true || v.isHidden == true { continue }
                    if v.isDirectory == true {
                        let path = url.standardizedFileURL.path
                        visited.insert(path)
                        // An iCloud folder can be a placeholder its File Provider fills in first.
                        let children = try self.kind == .icloud ? CloudDriveFiles.coordinated(url, list) : list(url)
                        pending.append(contentsOf: children.map { ($0, path) })
                    } else if v.isRegularFile == true {
                        var size = v.fileSize
                        if size == nil {
                            // As before, an original without a size is fetched, then measured.
                            try Self.download(url, progress: progress)
                            var fetched = url
                            fetched.removeAllCachedResourceValues()
                            size = try fetched.resourceValues(forKeys: [.fileSizeKey]).fileSize
                        }
                        let bytes = UInt64(max(0, size ?? 0))
                        total.files += 1
                        total.bytes += bytes
                        // A file chosen on its own has no listing; its folder is only counted if that folder is walked too.
                        direct[listedFrom ?? url.deletingLastPathComponent().standardizedFileURL.path, default: 0] += bytes
                    }
                    // Progress is for people: a few updates a second, not one per file.
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - reported >= 0.25 {
                        reported = now
                        report(finished(), false)
                    }
                } catch {
                    guard Self.missingDuringScan(error) else { throw error }
                    // A disconnected disk must not look like an empty folder.
                    try self.validateAccess()
                }
            }
            try self.validateAccess()
            let folders = try Self.folderTotals(direct: direct, visited: visited) {
                let now = ProcessInfo.processInfo.systemUptime
                if now - reported >= 0.25 { reported = now; report(rootCount, false) }
            }
            total.folders = folders
            try CloudDriveFiles.checkCancellation()
            report(rootCount, true)
            return total
        }
    }

    /// Read capacity only when the selection covers a volume root, including
    /// Select All at that root. A subfolder never inherits the whole disk's total.
    private func usedDiskBytes(for roots: [URL], location: URL?) -> UInt64? {
        guard kind == .local, let first = roots.first,
              let volume = (try? first.resourceValues(forKeys: [.volumeURLKey]))?.volume?
                .standardizedFileURL.resolvingSymlinksInPath() else { return nil }
        let selected = Set(roots.map { $0.standardizedFileURL.path })
        if !selected.contains(volume.path) {
            guard location?.standardizedFileURL.resolvingSymlinksInPath().path == volume.path,
                  let children = try? FileManager.default.contentsOfDirectory(at: volume,
                    includingPropertiesForKeys: Array(Self.sizeKeys), options: [.skipsHiddenFiles]) else { return nil }
            var eligible = 0
            for child in children {
                if diskTrash?.contains(child) == true { continue }
                guard let values = try? child.resourceValues(forKeys: Self.sizeKeys) else { return nil }
                if values.isHidden == true || values.isSymbolicLink == true { continue }
                guard values.isDirectory == true || values.isRegularFile == true else { continue }
                eligible += 1
                guard selected.contains(child.standardizedFileURL.path) else { return nil }
            }
            guard eligible > 0 else { return nil }
        }
        guard let used = LocalVolumeCapacityReader.read(volume)?.used, used > 0 else { return nil }
        return used
    }

    private static func tally(_ size: FolderSizeProgress, kind: CloudDriveKind) -> String {
        let title: String
        switch size.phase {
        case .scanning: title = "Calculating \(kind.title) size"
        case .finalizing: title = "Finalizing folder sizes"
        case .complete: title = "Calculated \(kind.title) size"
        }
        guard size.files > 0 || size.usedDiskBytes != nil else { return title }
        return "\(title) · \(size.files.formatted()) \(size.files == 1 ? "file" : "files") · \(size.sizeSummary)"
    }

    /// The identity a folder row has in a listing; `item(listed:in:)` builds the same string.
    static func folderID(_ url: URL) -> String { URL(fileURLWithPath: url.path, isDirectory: true).absoluteString }

    /// Each walked folder's total: its own files plus every walked folder below it. A folder's
    /// bytes pass only to a walked parent, so hidden folders and symbolic links stay excluded,
    /// and a subfolder measured before its parent (overlapping selections) is still included.
    private static func folderTotals(direct: [String: UInt64], visited: Set<String>,
                                     progress: () -> Void) throws -> [String: UInt64] {
        var totals: [String: UInt64] = [:], deepestFirst: [(path: String, depth: Int)] = []
        totals.reserveCapacity(visited.count); deepestFirst.reserveCapacity(visited.count)
        func checkpoint(_ index: Int) throws {
            if index % 256 == 0 { try CloudDriveFiles.checkCancellation(); progress() }
        }
        for (index, path) in visited.enumerated() {
            try checkpoint(index)
            totals[path] = direct[path] ?? 0
            deepestFirst.append((path, path.utf8.reduce(0) { $1 == 0x2F ? $0 + 1 : $0 }))
        }
        deepestFirst.sort { $0.depth > $1.depth }
        for (index, entry) in deepestFirst.enumerated() {
            try checkpoint(index)
            let path = entry.path
            let parent = (path as NSString).deletingLastPathComponent
            if parent != path, let inherited = totals[path], totals[parent] != nil { totals[parent]! += inherited }
        }
        var result: [String: UInt64] = [:]; result.reserveCapacity(totals.count)
        for (index, entry) in totals.enumerated() {
            try checkpoint(index)
            // These paths are known directories. Omitting isDirectory makes
            // Foundation query the disk again for every folder after the walk.
            result[URL(fileURLWithPath: entry.key, isDirectory: true).absoluteString] = entry.value
        }
        return result
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
    private static func trashUndo(_ urls: [URL], title: String, diskTrash: DiskTrash? = nil) -> CloudDriveUndo {
        .init(title: title) { try await Self.trash(urls, title: title, progress: { _ in }, diskTrash: diskTrash) }
    }
    private static func trash(_ urls: [URL], title: String, progress: @escaping CloudDriveProgressHandler, diskTrash: DiskTrash? = nil,
                              validate: (@Sendable (URL) throws -> Void)? = nil) async throws -> CloudDriveUndo {
        if let diskTrash { return try await diskTrash.trash(urls, title: title, progress: progress, validate: validate) }
        return try await CloudDriveFiles.detached {
            var restore: [(URL, URL)] = []
            do {
                for (index, url) in urls.enumerated() {
                    try CloudDriveFiles.checkCancellation()
                    var trashed: NSURL?
                    try CloudDriveFiles.coordinated(url, writing: true) {
                        try validate?($0)
                        try FileManager.default.trashItem(at: $0, resultingItemURL: &trashed)
                    }
                    guard let trashed else { throw CloudDriveError.message("Finder did not return the Trash location.") }
                    restore.append((trashed as URL, url))
                    progress(.init(message: "Moving to Trash", completed: index + 1, total: urls.count))
                }
            } catch { for (from, to) in restore.reversed() { try? Self.move(from, to) }; throw error }
            // Redo uses Trash again instead of relying on an expired Trash name.
            return Self.restoreTrashUndo(restore, title: title)
        }
    }
    static func restoreTrashUndo(_ pairs: [(URL, URL)], title: String) -> CloudDriveUndo {
        .init(title: title) {
            try await CloudDriveFiles.detached {
                // Reject a known conflict before restoring any member of the batch.
                for (from, to) in pairs {
                    guard FileManager.default.fileExists(atPath: from.path), !FileManager.default.fileExists(atPath: to.path) else {
                        throw CloudDriveError.message("Some items could not be restored. Their original names may already be in use.")
                    }
                }
                var restored: [(URL, URL)] = []
                do {
                    for (from, to) in pairs { try CloudDriveFiles.checkCancellation(); try Self.move(from, to); restored.append((to, from)) }
                } catch {
                    for (from, to) in restored.reversed() { try? Self.move(from, to) }
                    throw CloudDriveError.message("Some items could not be restored. Their original names may already be in use. \(error.localizedDescription)")
                }
                return Self.trashUndo(restored.map { $0.0 }, title: title)
            }
        }
    }
    func createContainer(_ name: String, in location: CloudDriveLocation) async throws -> CloudDriveUndo? {
        let folder = try checked(location.url).appendingPathComponent(CloudDriveFiles.validName(name), isDirectory: true)
        return try await CloudDriveFiles.detached {
            try CloudDriveFiles.coordinated(folder, writing: true) { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: false) }
            return Self.trashUndo([folder], title: "New Folder", diskTrash: self.diskTrash)
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
        let validatedSource = try LocalFileAccess.validate(source)
        guard (try validatedSource.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else {
            throw CloudDriveError.message("Symbolic links are excluded from transfers.")
        }
        let source = validatedSource.resolvingSymlinksInPath()
        let parent = try LocalFileAccess.validate(destination.deletingLastPathComponent(), volumeID: destinationVolumeID, directory: true, writing: true).resolvingSymlinksInPath()
        let destination = parent.appendingPathComponent(destination.lastPathComponent)
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
                        let children = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
                        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
                        created = true
                        for file in children {
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
            return Self.trashUndo(copied, title: "Import", diskTrash: self.diskTrash)
        }
    }
    func delete(_ items: [CloudDriveItem], progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? {
        let urls = try items.map { try checked($0.url) }
        guard !urls.contains(root.url!) else { throw CloudDriveError.message("The connected drive root cannot be moved to Trash.") }
        return try await Self.trash(urls, title: "Move to Trash", progress: progress, diskTrash: diskTrash)
    }
    func deleteVerified(_ items: [CloudDriveItem], progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? {
        let urls = try items.map { try checked($0.url) }
        guard !urls.contains(root.url!), Set(urls.map(\.path)).count == urls.count,
              items.allSatisfy({ !$0.isFolder && $0.revision != nil }) else {
            throw CloudDriveError.message("Scan the group again before changing these files.")
        }
        let revisions = Dictionary(uniqueKeysWithValues: zip(urls.map(\.path), items.compactMap(\.revision)))
        return try await Self.trash(urls, title: "Move to Trash", progress: progress, diskTrash: diskTrash) { url in
            guard let expected = revisions[url.standardizedFileURL.resolvingSymlinksInPath().path],
                  Self.fileRevision(url) == expected else {
                throw CloudDriveError.message("A file changed after comparison. No more files were moved to Trash. Scan the group again.")
            }
        }
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
                    if self.diskTrash?.contains(child) == true { allEmpty = false; continue }
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
        return try await Self.trash(urls, title: empty ? "Remove Empty Folders" : "Remove .DS_Store Files", progress: progress, diskTrash: diskTrash) { url in
            let values = try url.resourceValues(forKeys: Self.keys)
            let safe: Bool
            if values.isSymbolicLink == true { safe = false }
            else if empty, values.isDirectory == true { safe = try Self.isEmptyTree(url) }
            else { safe = !empty && values.isRegularFile == true && url.lastPathComponent == ".DS_Store" }
            guard safe else { throw CloudDriveError.message("The cleanup scope changed. Review it again before removing items.") }
        }
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

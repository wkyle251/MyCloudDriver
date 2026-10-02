import AppKit
import Foundation
import Darwin
@preconcurrency import Photos
import UniformTypeIdentifiers

/// Keep permission checks separate from connecting a browser to its library.
/// Tests supply an in-memory client and never request access to personal Photos.
@MainActor struct PhotosAccessClient {
    var status: () -> PHAuthorizationStatus
    var request: () async -> PHAuthorizationStatus
    var provider: () -> any NativeCloudDrive

    static var system: Self {
        .init(status: { PHPhotoLibrary.authorizationStatus(for: .readWrite) },
              request: { await PHPhotoLibrary.requestAuthorization(for: .readWrite) },
              provider: { PhotosDriveProvider() })
    }
}

final class PhotosDriveProvider: NativeCloudDrive, @unchecked Sendable {
    let kind = CloudDriveKind.photos
    let supportsSimilarityPreviews = true
    let root = CloudDriveLocation(id: "photos:root", title: "Apple Photos", isLibrary: true)
    static var authorized: Bool { PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized || PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited }
    private func checkAccess() throws {
        guard Self.authorized else { throw CloudDriveError.message("Photos access is unavailable. Reconnect Apple Photos to review its permission.") }
    }
    func previewForSimilarity(_ item: CloudDriveItem, progress: @escaping CloudDriveProgressHandler) async throws -> Data {
        try checkAccess()
        let asset = try await CloudDriveFiles.detached { try Self.asset(item.id) }
        let request = PhotosSimilarityPreview()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { request.start(asset, progress: progress, continuation: $0) }
        }, onCancel: { request.cancel() })
    }
    private static func asset(_ id: String) throws -> PHAsset {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [String(id.dropFirst("asset:".count))], options: nil).firstObject else {
            throw CloudDriveError.message("This photo or video is no longer available in the library.")
        }
        return asset
    }
    private static func album(_ id: String) throws -> PHAssetCollection {
        guard let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [String(id.dropFirst("album:".count))], options: nil).firstObject else {
            throw CloudDriveError.message("This album is no longer available.")
        }
        return album
    }
    static func resource(_ asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        return resources.first { $0.type == (asset.mediaType == .video ? .video : .photo) }
            ?? resources.first { $0.type == (asset.mediaType == .video ? .fullSizeVideo : .fullSizePhoto) }
    }
    private static func item(_ asset: PHAsset) -> CloudDriveItem {
        let resource = resource(asset)
        return .init(id: "asset:" + asset.localIdentifier, name: resource?.originalFilename ?? "Untitled media",
            isFolder: false, modified: asset.modificationDate ?? asset.creationDate, mediaType: asset.mediaType == .video ? "video" : "image",
            canRename: false, canDelete: asset.canPerform(.delete))
    }
    private static func fetch(_ location: CloudDriveLocation) throws -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        if location.id == "photos:videos" { options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue) }
        else if location.id == "photos:images" { options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue) }
        else { options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue) }
        if location.id.hasPrefix("album:") { return PHAsset.fetchAssets(in: try album(location.id), options: options) }
        return PHAsset.fetchAssets(with: options)
    }
    func refreshedItems(_ items: [CloudDriveItem]) async throws -> [CloudDriveItem] {
        try checkAccess()
        return try await CloudDriveFiles.detached {
            try items.map { item in
                try CloudDriveFiles.checkCancellation()
                return Self.item(try Self.asset(item.id))
            }
        }
    }
    func list(_ location: CloudDriveLocation, offset: Int, search: String) async throws -> CloudDrivePage {
        try checkAccess()
        return try await CloudDriveFiles.detached {
            if location.isLibrary && search.isEmpty {
                var items = [("photos:all", "All Photos & Videos"), ("photos:images", "Photos"), ("photos:videos", "Videos")].map {
                    CloudDriveItem(id: $0.0, name: $0.1, isFolder: true, canRename: false, canDelete: false)
                }
                let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
                albums.enumerateObjects { album, _, _ in
                    items.append(.init(id: "album:" + album.localIdentifier, name: album.localizedTitle ?? "Untitled Album", isFolder: true,
                        canRename: album.canPerform(.rename), canDelete: album.canPerform(.delete)))
                }
                return .init(items: items, total: items.count)
            }
            let assets = try Self.fetch(location)
            var items: [CloudDriveItem] = [], cursor = max(0, offset)
            while cursor < assets.count && items.count < 500 {
                try CloudDriveFiles.checkCancellation()
                let item = Self.item(assets.object(at: cursor)); cursor += 1
                if search.isEmpty || item.name.localizedStandardContains(search) { items.append(item) }
            }
            return .init(items: items, total: search.isEmpty ? assets.count : items.count, nextOffset: cursor < assets.count ? cursor : nil)
        }
    }
    func scanItems(_ items: [CloudDriveItem], location: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> [CloudDriveItem] {
        let collector = CloudDriveScanCollector()
        try await discoverItems(items, location: location, progress: progress) { collector.append($0) }
        return collector.items
    }
    func discoverItems(_ items: [CloudDriveItem], location: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler,
                       found: @escaping @Sendable (CloudDriveItem) -> Void) async throws {
        try checkAccess()
        try await CloudDriveFiles.detached {
            var count = 0, seen = Set<String>()
            let scopes = items.isEmpty ? [CloudDriveItem(id: location.id, name: location.title, isFolder: true)] : items
            for item in scopes {
                if !item.isFolder {
                    // Selection metadata can outlive an edit or deletion.
                    guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [String(item.id.dropFirst("asset:".count))], options: nil).firstObject else { continue }
                    let current = Self.item(asset)
                    if seen.insert(current.id).inserted { count += 1; found(current) }
                    continue
                }
                if item.id.hasPrefix("album:"), PHAssetCollection.fetchAssetCollections(withLocalIdentifiers:
                    [String(item.id.dropFirst("album:".count))], options: nil).firstObject == nil { continue }
                let assets = try Self.fetch(item.location)
                for index in 0..<assets.count {
                    try CloudDriveFiles.checkCancellation()
                    let value = Self.item(assets.object(at: index))
                    if seen.insert(value.id).inserted { count += 1; found(value) }
                    if index % 50 == 0 { progress(.init(message: "Finding photos and videos", completed: count)) }
                }
            }
            try self.checkAccess()
        }
    }
    func materialize(_ item: CloudDriveItem, directory: URL, progress: @escaping CloudDriveProgressHandler) async throws -> URL {
        try checkAccess()
        let resource = try await CloudDriveFiles.detached { () -> PHAssetResource in
            guard let resource = Self.resource(try Self.asset(item.id)) else { throw CloudDriveError.message("Photos did not provide an original resource for this item.") }
            return resource
        }
        try Task.checkCancellation()
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try CloudDriveFiles.privateDirectory(folder)
        let output = folder.appendingPathComponent(FinderFileOpenStorage.safeFilename(resource.originalFilename))
        let request = PhotosResourceTransfer(output: output, progress: progress)
        do {
            return try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { request.begin(resource, continuation: $0) }
            }, onCancel: { request.cancel() })
        } catch { try? FileManager.default.removeItem(at: folder); throw error }
    }
    /// Similarity never exports a Photos original to a regular file. The
    /// helper owns this private pipe and admits its buffer against the RAM limit.
    func streamForSimilarity(_ item: CloudDriveItem, pipe: URL, capacity: UInt64,
                             progress: @escaping CloudDriveProgressHandler) async throws -> URL {
        try checkAccess()
        let resource = try await CloudDriveFiles.detached { () -> PHAssetResource in
            guard let resource = Self.resource(try Self.asset(item.id)) else {
                throw CloudDriveError.message("Photos did not provide this original.")
            }
            return resource
        }
        try Task.checkCancellation()
        let request = PhotosResourceTransfer(output: pipe, progress: progress, pipeLimit: capacity)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { request.begin(resource, continuation: $0) }
        }, onCancel: { request.cancel() })
    }
    private static func changes(_ block: @escaping () -> Void) async throws {
        try CloudDriveFiles.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges(block) { success, error in
                if success { continuation.resume() }
                else { continuation.resume(throwing: error ?? CloudDriveError.message("Photos could not complete the change.")) }
            }
        }
    }
    func createContainer(_ name: String, in location: CloudDriveLocation) async throws -> CloudDriveUndo? {
        try checkAccess(); let title = try CloudDriveFiles.validName(name)
        var identifier: String?
        try await Self.changes { identifier = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title).placeholderForCreatedAssetCollection.localIdentifier }
        guard let identifier else { throw CloudDriveError.message("Photos did not return the new album.") }
        let item = CloudDriveItem(id: "album:" + identifier, name: title, isFolder: true)
        return .init(title: "New Album") { try await self.delete([item], progress: { _ in }) ?? Self.unavailableUndo }
    }
    func rename(_ item: CloudDriveItem, to name: String) async throws -> CloudDriveUndo? {
        try checkAccess()
        guard item.id.hasPrefix("album:"), item.canRename else { throw CloudDriveError.message("Photos supports renaming albums. Original photo and video filenames are managed by Photos.") }
        let title = try CloudDriveFiles.validName(name), album = try Self.album(item.id)
        try await Self.changes { PHAssetCollectionChangeRequest(for: album)?.title = title }
        let renamed = CloudDriveItem(id: item.id, name: title, isFolder: true)
        return .init(title: "Rename Album") { try await self.rename(renamed, to: item.name) ?? CloudDriveUndo(title: "Rename Album", apply: { throw CocoaError(.userCancelled) }) }
    }
    func relocate(_ items: [CloudDriveItem], from: CloudDriveLocation, to: CloudDriveLocation, copy: Bool, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? {
        try checkAccess()
        guard items.allSatisfy({ !$0.isFolder }), to.id.hasPrefix("album:") else { throw CloudDriveError.message("Choose a user album for the selected photos and videos.") }
        let destination = try Self.album(to.id), source = from.id.hasPrefix("album:") ? try Self.album(from.id) : nil
        guard destination.canPerform(.addContent), copy || source?.canPerform(.removeContent) != false else { throw CloudDriveError.message("Photos does not allow editing this album.") }
        let assets = try items.map { try Self.asset($0.id) }
        // Preserve pre-existing membership when undoing an Add/Move operation.
        let existing = PHAsset.fetchAssets(in: destination, options: nil)
        var existingIDs = Set<String>(); existing.enumerateObjects { value, _, _ in existingIDs.insert(value.localIdentifier) }
        var sourceIDs = Set<String>()
        if let source { PHAsset.fetchAssets(in: source, options: nil).enumerateObjects { value, _, _ in sourceIDs.insert(value.localIdentifier) } }
        let plan = PhotosAlbumMembershipPlan(selected: Set(assets.map(\.localIdentifier)), source: sourceIDs, destination: existingIDs,
            move: !copy, sameAlbum: source?.localIdentifier == destination.localIdentifier)
        let added = assets.filter { plan.added.contains($0.localIdentifier) }, removed = assets.filter { plan.removed.contains($0.localIdentifier) }
        try await Self.changes {
            if !added.isEmpty { PHAssetCollectionChangeRequest(for: destination)?.addAssets(added as NSArray) }
            if let source, !removed.isEmpty { PHAssetCollectionChangeRequest(for: source)?.removeAssets(removed as NSArray) }
        }
        progress(.init(message: "Updated album", completed: assets.count, total: assets.count))
        return .init(title: copy ? "Add to Album" : "Move to Album") {
            try await Self.changes {
                if !added.isEmpty { PHAssetCollectionChangeRequest(for: destination)?.removeAssets(added as NSArray) }
                if let source, !removed.isEmpty { PHAssetCollectionChangeRequest(for: source)?.addAssets(removed as NSArray) }
            }
            return .init(title: copy ? "Add to Album" : "Move to Album") {
                try await self.relocate(items, from: from, to: to, copy: copy, progress: progress)
                    ?? CloudDriveUndo(title: "Album Change", apply: { throw CocoaError(.userCancelled) })
            }
        }
    }
    func importFiles(_ urls: [URL], into location: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? {
        try checkAccess()
        let files = try await CloudDriveFiles.detached { () -> [URL] in
            var result: [URL] = [], pending = urls
            while let url = pending.popLast() {
                try CloudDriveFiles.checkCancellation()
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true { continue }
                if values.isDirectory == true {
                    pending.append(contentsOf: try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))
                } else if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) || type.conforms(to: .movie) { result.append(url) }
            }
            guard !result.isEmpty else { throw CloudDriveError.message("Choose supported image or video files to import into Photos.") }
            return result
        }
        let album = location.id.hasPrefix("album:") ? try Self.album(location.id) : nil
        guard album?.canPerform(.addContent) != false else { throw CloudDriveError.message("Photos does not allow importing into this album.") }
        var createdCount = 0
        let control = NativeTransferControl.current
        for url in files {
            if control?.isCompleted(url.path) == true { createdCount += 1; continue }
            try await control?.wait()
            try CloudDriveFiles.checkCancellation()
            var identifier: String?
            try await Self.changes {
                let request = UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
                    ? PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                    : PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                if let placeholder = request?.placeholderForCreatedAsset {
                    identifier = placeholder.localIdentifier
                    if let album { PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray) }
                }
            }
            guard identifier != nil else { throw CloudDriveError.message("Photos did not accept \(url.lastPathComponent).") }
            // An acknowledged Photos transaction must not be repeated when a
            // later item fails or the task is cancelled just after commit.
            control?.markCompleted(url.path)
            createdCount += 1
            progress(.init(message: "Imported into Photos", completed: createdCount, total: files.count))
        }
        return nil
    }
    func delete(_ items: [CloudDriveItem], progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? {
        try checkAccess()
        guard items.allSatisfy(\.canDelete) else { throw CloudDriveError.message("This collection cannot be deleted through PhotoKit.") }
        let albums = try items.filter(\.isFolder).map { try Self.album($0.id) }
        let assets = try items.filter { !$0.isFolder }.map { try Self.asset($0.id) }
        let snapshots = albums.map { album -> (String, [String]) in
            var ids: [String] = []; PHAsset.fetchAssets(in: album, options: nil).enumerateObjects { value, _, _ in ids.append(value.localIdentifier) }
            return (album.localizedTitle ?? "Untitled Album", ids)
        }
        try await Self.changes {
            if !albums.isEmpty { PHAssetCollectionChangeRequest.deleteAssetCollections(albums as NSArray) }
            if !assets.isEmpty { PHAssetChangeRequest.deleteAssets(assets as NSArray) }
        }
        progress(.init(message: "Deleted. Recover media in Photos → Recently Deleted.", completed: items.count, total: items.count))
        guard assets.isEmpty else { return nil } // PhotoKit cannot restore deleted assets.
        return .init(title: "Delete Albums") { try await self.restoreAlbums(snapshots) }
    }
    private static var unavailableUndo: CloudDriveUndo { .init(title: "Album Change") { throw CloudDriveError.message("Photos could not restore this album change.") } }
    private func restoreAlbums(_ snapshots: [(String, [String])]) async throws -> CloudDriveUndo {
        var restored: [CloudDriveItem] = []
        try await Self.changes {
            for (title, ids) in snapshots {
                let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
                let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
                request.addAssets(assets)
                restored.append(.init(id: "album:" + request.placeholderForCreatedAssetCollection.localIdentifier, name: title, isFolder: true))
            }
        }
        let items = restored
        return .init(title: "Delete Albums") { try await self.delete(items, progress: { _ in }) ?? Self.unavailableUndo }
    }
    func emptyAlbums(progress: @escaping CloudDriveProgressHandler) async throws -> [CloudDriveItem] {
        let albums = try await list(root, offset: 0, search: "").items.filter { $0.id.hasPrefix("album:") && $0.canDelete }
        return try await CloudDriveFiles.detached {
            var result: [CloudDriveItem] = []
            for (index, item) in albums.enumerated() {
                try CloudDriveFiles.checkCancellation()
                if PHAsset.fetchAssets(in: try Self.album(item.id), options: nil).count == 0 { result.append(item) }
                progress(.init(message: "Checking albums", completed: index + 1, total: albums.count))
            }
            return result
        }
    }
    func removeEmptyAlbums(_ items: [CloudDriveItem], progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? {
        for item in items {
            guard PHAsset.fetchAssets(in: try Self.album(item.id), options: nil).count == 0 else { throw CloudDriveError.message("An album now contains media. Review empty albums again.") }
        }
        return try await delete(items, progress: progress)
    }
    func mergeAlbums(_ items: [CloudDriveItem], progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? {
        guard items.count > 1, items.allSatisfy({ $0.id.hasPrefix("album:") }) else { throw CloudDriveError.message("Choose at least two user albums.") }
        let destination = items[0], sources = Array(items.dropFirst())
        let media = try await scanItems(sources, location: root, progress: progress)
        let membership = try await relocate(media, from: root, to: destination.location, copy: true, progress: progress)
        do {
            let removed = try await delete(sources, progress: progress)
            return .sequence([removed, membership].compactMap { $0 }, title: "Merge Albums")
        } catch { if let membership { _ = try? await membership.apply() }; throw error }
    }
}

/// A lower bound from the next PhotoKit chunk, not an exact original size.
/// The scan discards this attempt before requesting a larger RAM allowance.
struct PhotosMemoryCapacityExceeded: Error {
    let requiredBytes: UInt64
}

private final class PhotosResourceTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private let output: URL
    private let transferControl = NativeTransferControl.current
    private let progress: CloudDriveProgressHandler
    private let pipeLimit: UInt64?
    private var continuation: CheckedContinuation<URL, Error>?
    private var requestID: PHAssetResourceDataRequestID?
    private var file: FileHandle?
    private var cancelled = false
    private var finished = false
    private var bytes: UInt64 = 0
    private var lastProgress = Date.distantPast
    init(output: URL, progress: @escaping CloudDriveProgressHandler, pipeLimit: UInt64? = nil) {
        self.output = output; self.progress = progress; self.pipeLimit = pipeLimit
    }
    func begin(_ resource: PHAssetResource, continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        do {
            if pipeLimit != nil {
                file = try SimilarityMemoryPipe.open(output)
            } else {
                guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
                file = try FileHandle(forWritingTo: output)
            }
        } catch { lock.unlock(); complete(error); return }
        lock.unlock()
        let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = true
        options.progressHandler = { [weak self] value in
            guard let self else { return }; self.lock.lock(); let bytes = self.bytes; self.lock.unlock()
            self.progress(.init(message: "Fetching \(resource.originalFilename)", fraction: value, bytes: bytes))
        }
        let id = PHAssetResourceManager.default().requestData(for: resource, options: options) { [weak self] data in
            guard let self else { return }
            do { try self.transferControl?.check() } catch { self.cancel(); return }
            if let limit = self.pipeLimit {
                do {
                    try data.withUnsafeBytes { buffer in
                        var offset = 0
                        while offset < buffer.count {
                            self.lock.lock()
                            guard !self.finished, !self.cancelled, let file = self.file else {
                                self.lock.unlock(); throw CancellationError()
                            }
                            guard UInt64(buffer.count - offset) <= limit - min(limit, self.bytes) else {
                                let required = self.bytes.addingReportingOverflow(UInt64(buffer.count - offset))
                                self.lock.unlock()
                                throw PhotosMemoryCapacityExceeded(requiredBytes: required.overflow ? UInt64.max : required.partialValue)
                            }
                            let written = Darwin.write(file.fileDescriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                            let code = errno
                            if written > 0 { self.bytes += UInt64(written); offset += written }
                            self.lock.unlock()
                            if written < 0 && code != EAGAIN && code != EINTR {
                                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
                            }
                            if written <= 0 { try SimilarityMemoryPipe.waitWritable(file.fileDescriptor) }
                        }
                    }
                } catch { self.complete(error); self.cancel(); return }
                self.lock.lock(); let bytes = self.bytes; self.lock.unlock()
                self.progress(.init(message: "Reading \(resource.originalFilename) into memory", bytes: bytes))
                return
            }
            self.lock.lock()
            guard !self.finished && !self.cancelled else { self.lock.unlock(); return }
            do {
                try self.file?.write(contentsOf: data); self.bytes += UInt64(data.count)
                let bytes = self.bytes, update = Date().timeIntervalSince(self.lastProgress) > 0.25
                if update { self.lastProgress = Date() }; self.lock.unlock()
                if update { self.progress(.init(message: "Fetching \(resource.originalFilename)", bytes: bytes)) }
            }
            catch { self.lock.unlock(); self.complete(error) }
        } completionHandler: { [weak self] error in self?.complete(error) }
        lock.lock(); requestID = id; let cancel = cancelled || finished; lock.unlock()
        if cancel { PHAssetResourceManager.default().cancelDataRequest(id) }
    }
    private func complete(_ error: Error?) {
        lock.lock(); guard !finished else { lock.unlock(); return }
        finished = true; try? file?.close(); file = nil
        let continuation = self.continuation; self.continuation = nil; let cancelled = self.cancelled; lock.unlock()
        if let error { continuation?.resume(throwing: error) }
        else if cancelled { continuation?.resume(throwing: CancellationError()) }
        else { continuation?.resume(returning: output) }
    }
    func cancel() {
        lock.lock(); cancelled = true; let id = requestID; lock.unlock()
        if let id { PHAssetResourceManager.default().cancelDataRequest(id) }
        complete(CancellationError())
    }
}

enum SimilarityMemoryPipe {
    static func waitWritable(_ descriptor: Int32) throws {
        var pending = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
        let result = Darwin.poll(&pending, 1, 100)
        if result < 0 && errno != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
    /// O_NOFOLLOW and fstat prevent replacing the requested pipe with a file.
    /// Nonblocking writes allow cancellation even when the helper stops reading.
    /// The pipe is nonblocking so a stalled helper cannot wedge the writer.
    /// Retry short writes until the chunk is delivered or the task is cancelled.
    static func write(_ bytes: Data, to handle: FileHandle) throws {
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try CloudDriveFiles.checkCancellation()
                let written = Darwin.write(handle.fileDescriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                let code = errno
                if written > 0 { offset += written; continue }
                if written < 0 && code != EAGAIN && code != EINTR {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
                }
                try waitWritable(handle.fileDescriptor)
            }
        }
    }
    static func open(_ url: URL) throws -> FileHandle {
        let fd = Darwin.open(url.path, O_WRONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFIFO,
              fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else {
            Darwin.close(fd); throw CocoaError(.fileWriteNoPermission)
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}

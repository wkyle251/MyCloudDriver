import AppKit
import Foundation
@preconcurrency import Photos
import UniformTypeIdentifiers

final class PhotosDriveProvider: NativeCloudDrive, @unchecked Sendable {
    let kind = CloudDriveKind.photos
    let root = CloudDriveLocation(id: "photos:root", title: "Apple Photos", isLibrary: true)
    static var authorized: Bool { PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized || PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited }
    static func connect() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw CloudDriveError.message("Allow MyCloudDriver to access Photos in System Settings → Privacy & Security → Photos, then reconnect.")
        }
    }
    private func checkAccess() throws {
        guard Self.authorized else { throw CloudDriveError.message("Photos access is unavailable. Reconnect Apple Photos to review its permission.") }
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
            isFolder: false, modified: asset.creationDate, mediaType: asset.mediaType == .video ? "video" : "image",
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
                try Task.checkCancellation()
                let item = Self.item(assets.object(at: cursor)); cursor += 1
                if search.isEmpty || item.name.localizedStandardContains(search) { items.append(item) }
            }
            return .init(items: items, total: search.isEmpty ? assets.count : items.count, nextOffset: cursor < assets.count ? cursor : nil)
        }
    }
    func scanItems(_ items: [CloudDriveItem], location: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> [CloudDriveItem] {
        try checkAccess()
        return try await CloudDriveFiles.detached {
            var result: [CloudDriveItem] = [], seen = Set<String>()
            let scopes = items.isEmpty ? [CloudDriveItem(id: location.id, name: location.title, isFolder: true)] : items
            for item in scopes {
                if !item.isFolder { if seen.insert(item.id).inserted { result.append(item) }; continue }
                let assets = try Self.fetch(item.location)
                for index in 0..<assets.count {
                    try Task.checkCancellation()
                    let value = Self.item(assets.object(at: index))
                    if seen.insert(value.id).inserted { result.append(value) }
                    if index % 50 == 0 { progress(.init(message: "Finding photos and videos", completed: result.count)) }
                }
            }
            return result
        }
    }
    func materialize(_ item: CloudDriveItem, directory: URL, progress: @escaping CloudDriveProgressHandler) async throws -> URL {
        try checkAccess()
        let resource = try await CloudDriveFiles.detached { () -> PHAssetResource in
            guard let resource = Self.resource(try Self.asset(item.id)) else { throw CloudDriveError.message("Photos did not provide an original resource for this item.") }
            return resource
        }
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
    private static func changes(_ block: @escaping () -> Void) async throws {
        try Task.checkCancellation()
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
                try Task.checkCancellation()
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
        try await Self.changes {
            var placeholders: [PHObjectPlaceholder] = []
            for url in files {
                let request = UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true
                    ? PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                    : PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                if let placeholder = request?.placeholderForCreatedAsset { placeholders.append(placeholder) }
            }
            createdCount = placeholders.count
            if let album { PHAssetCollectionChangeRequest(for: album)?.addAssets(placeholders as NSArray) }
        }
        progress(.init(message: "Imported into Photos", completed: createdCount, total: files.count))
        guard createdCount == files.count else { throw CloudDriveError.message("Imported \(createdCount) of \(files.count) items. Photos did not accept the remaining file formats.") }
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
                try Task.checkCancellation()
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

private final class PhotosResourceTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private let output: URL
    private let progress: CloudDriveProgressHandler
    private var continuation: CheckedContinuation<URL, Error>?
    private var requestID: PHAssetResourceDataRequestID?
    private var file: FileHandle?
    private var cancelled = false
    private var finished = false
    private var bytes: UInt64 = 0
    private var lastProgress = Date.distantPast
    init(output: URL, progress: @escaping CloudDriveProgressHandler) { self.output = output; self.progress = progress }
    func begin(_ resource: PHAssetResource, continuation: CheckedContinuation<URL, Error>) {
        lock.lock()
        if cancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation
        do {
            guard FileManager.default.createFile(atPath: output.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            file = try FileHandle(forWritingTo: output)
        } catch { lock.unlock(); complete(error); return }
        lock.unlock()
        let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = true
        options.progressHandler = { [weak self] value in
            guard let self else { return }; self.lock.lock(); let bytes = self.bytes; self.lock.unlock()
            self.progress(.init(message: "Fetching \(resource.originalFilename)", fraction: value, bytes: bytes))
        }
        let id = PHAssetResourceManager.default().requestData(for: resource, options: options) { [weak self] data in
            guard let self else { return }; self.lock.lock()
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

import Darwin
import Foundation

/// Only this private, marked staging folder is eligible for automatic cleanup.
/// The chosen parent folder and its other contents are never removed.
struct TorrentRelayStorage: Codable, Equatable {
    let owner: UUID
    let path: String
    let parentPath: String
    let volumeID: String?
    let bookmark: Data?
    var root: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var parent: URL { URL(fileURLWithPath: parentPath, isDirectory: true) }
    var payload: URL { root.appendingPathComponent("payload", isDirectory: true) }

    /// Check the entire manifest, including files outside the current window.
    /// RAM is case-sensitive; most Mac disks are not. Two later windows must
    /// never silently reuse the same file or merge distinct directories.
    static func validateLayout(_ files: [LocalTorrentFile], caseSensitive: Bool) throws {
        var names: [String: (path: String, file: Bool)] = [:]
        for file in files {
            let parts = file.path.split(separator: "/", omittingEmptySubsequences: false)
            guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  !file.path.contains("\\"), !file.path.contains("\0") else { throw CocoaError(.fileReadInvalidFileName) }
            var path = ""
            for (index, part) in parts.enumerated() {
                path += (path.isEmpty ? "" : "/") + part
                let normalized = path.precomposedStringWithCanonicalMapping
                let key = caseSensitive ? normalized : normalized.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
                let leaf = index == parts.count - 1
                if let existing = names[key], existing.path != path || existing.file != leaf || leaf {
                    throw LocalTorrentError.message("“\(existing.path)” and “\(path)” overlap on this disk. Choose a case-sensitive storage disk to keep the torrent’s filenames distinct.")
                }
                names[key] = (path, leaf)
            }
        }
    }

    static func create(in selectedParent: URL, owner: UUID) throws -> Self {
        let parent = selectedParent.resolvingSymlinksInPath().standardizedFileURL
        try LocalFileAccess.validate(parent, directory: true, writing: true)
        let root = parent.appendingPathComponent("MyCloudDriver-Torrent-\(owner.uuidString)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        guard mkdir(root.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        do {
            try LocalTorrentStore.write(Data(owner.uuidString.utf8), to: root.appendingPathComponent(".mycloud-owner"))
            try LocalTorrentStore.protect(root.appendingPathComponent("payload"))
            return .init(owner: owner, path: root.path, parentPath: parent.path, volumeID: LocalFileAccess.volumeID(parent),
                bookmark: try? selectedParent.bookmarkData(options: .withSecurityScope,
                    includingResourceValuesForKeys: [.volumeUUIDStringKey], relativeTo: nil))
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }

    func validate(owner expectedOwner: UUID) throws {
        guard owner == expectedOwner, root.deletingLastPathComponent().path == parent.path,
              root.lastPathComponent.hasPrefix("MyCloudDriver-Torrent-\(owner.uuidString)-"),
              parent.resolvingSymlinksInPath().standardizedFileURL.path == parent.path else {
            throw LocalTorrentError.message("The torrent storage folder changed. Restore its original location before resuming.")
        }
        try LocalFileAccess.validate(parent, volumeID: volumeID, directory: true, writing: true)
        for directory in [root, payload] {
            var info = stat()
            guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
                throw LocalTorrentError.message("The torrent storage folder is unavailable or was replaced. Reconnect its disk and Resume.")
            }
            try LocalFileAccess.validate(directory, volumeID: volumeID, directory: true, writing: true)
        }
        guard try LocalTorrentStore.read(root.appendingPathComponent(".mycloud-owner"), maximum: 128) == Data(owner.uuidString.utf8) else {
            throw LocalTorrentError.message("This storage folder does not belong to the torrent. Its files were kept.")
        }
    }

    /// Validate every component again before deleting a torrent-owned file.
    static func file(_ path: String, under root: URL) throws -> URL? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
              !path.contains("\\"), !path.contains("\0") else { throw CocoaError(.fileReadInvalidFileName) }
        var url = root
        for (index, part) in parts.enumerated() {
            url.appendPathComponent(String(part))
            var info = stat()
            if lstat(url.path, &info) != 0 {
                if errno == ENOENT { return nil }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            let expected = index == parts.count - 1 ? S_IFREG : S_IFDIR
            guard (info.st_mode & S_IFMT) == expected else { throw CocoaError(.fileReadNoPermission) }
        }
        return url
    }

    func space() throws -> (free: UInt64, used: UInt64) {
        try validate(owner: owner)
        var used: UInt64 = 0
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .totalFileAllocatedSizeKey]
        var enumerationError: Error?
        guard let entries = FileManager.default.enumerator(at: payload, includingPropertiesForKeys: Array(keys),
            errorHandler: { _, error in enumerationError = error; return false }) else { throw CocoaError(.fileReadUnknown) }
        for case let url as URL in entries {
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw CocoaError(.fileReadNoPermission) }
            if values.isRegularFile == true { used += UInt64(max(0, values.totalFileAllocatedSize ?? 0)) }
        }
        if let enumerationError { throw enumerationError }
        let available = try parent.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
        guard let available, available >= 0 else { throw CocoaError(.fileReadUnknown) }
        return (UInt64(available), used)
    }

    func clear() throws {
        try validate(owner: owner)
        try FileManager.default.removeItem(at: payload)
        try LocalTorrentStore.protect(payload)
    }

    func copy(from source: URL, progress: @escaping @Sendable (String) -> Void) async throws {
        let worker = Task.detached(priority: .utility) {
            try self.validate(owner: self.owner)
            var lastReport = Date.distantPast
            func copyDirectory(_ from: URL, _ to: URL) throws {
                try Task.checkCancellation()
                var directoryInfo = stat()
                guard lstat(from.path, &directoryInfo) == 0, (directoryInfo.st_mode & S_IFMT) == S_IFDIR else {
                    throw CocoaError(.fileReadNoPermission)
                }
                for file in try FileManager.default.contentsOfDirectory(at: from, includingPropertiesForKeys: nil) {
                    try Task.checkCancellation()
                    var info = stat()
                    guard lstat(file.path, &info) == 0 else { throw CocoaError(.fileReadUnknown) }
                    let destination = to.appendingPathComponent(file.lastPathComponent)
                    if (info.st_mode & S_IFMT) == S_IFDIR {
                        // Exclusive creation also detects case-colliding names
                        // when moving from case-sensitive RAM to another disk.
                        guard mkdir(destination.path, 0o700) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                        try copyDirectory(file, destination)
                    } else {
                        guard (info.st_mode & S_IFMT) == S_IFREG else { throw CocoaError(.fileReadNoPermission) }
                        if Date().timeIntervalSince(lastReport) >= 0.2 {
                            progress(file.lastPathComponent); lastReport = Date()
                        }
                        try Self.copyFile(file, to: destination)
                    }
                }
                try Self.synchronize(to)
            }
            try copyDirectory(source, self.payload)
            try Self.synchronize(self.root)
        }
        try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }

    private static func copyFile(_ source: URL, to destination: URL) throws {
        let input = open(source.path, O_RDONLY | O_NOFOLLOW)
        guard input >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(input) }
        let output = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard output >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(output) }
        var before = stat(), after = stat(), copied = stat()
        guard fstat(input, &before) == 0, (before.st_mode & S_IFMT) == S_IFREG,
              fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_DATA_SPARSE | COPYFILE_DATA)) == 0,
              fstat(input, &after) == 0, fstat(output, &copied) == 0,
              before.st_size == copied.st_size, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec, fsync(output) == 0 else {
            throw LocalTorrentError.message("The torrent data could not be copied to storage. Its RAM data has been kept. Check free space and folder access, then try again.")
        }
    }

    static func synchronize(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}

@MainActor extension LocalTorrentModel {
    func setStorageLimit(_ id: UUID, bytes: UInt64?) {
        guard job(id)?.relay?.storage != nil, job(id)?.phase != .completed, !busy.contains(id), !closed,
              bytes == nil || bytes! >= TorrentRelayDrain.storageGB else { return }
        edit(id) { $0.relay?.storageLimitBytes = bytes }
        relayStorageLimitChanged.insert(id)
        relayFileCensusAt[id] = nil
        saveOrReport()
    }

    func setKeepUploadedFiles(_ id: UUID, enabled: Bool) {
        guard job(id)?.relay?.storage != nil, job(id)?.phase != .completed, !busy.contains(id), !closed else { return }
        edit(id) { $0.relay?.keepUploadedFiles = enabled }
        relayFileCensusAt[id] = nil
        saveOrReport()
    }

    func pauseRelayWriter(_ gid: String) async throws {
        let status = try await engine.status(gid, files: false)
        if !["paused", "complete", "error", "removed"].contains(status.state) { try await engine.pauseAndWait(gid) }
    }

    func validateRelayBuffer(_ id: UUID, state: TorrentRelayState) async throws {
        if let storage = state.storage {
            if leases[id] == nil {
                leases[id] = LocalFileAccessLease([storage.parent], bookmarks: storage.bookmark.map { [storage.parentPath: $0] } ?? [:])
            }
            try storage.validate(owner: id)
        } else if let volume = state.volume { try await ram.validate(volume) }
        else { throw LocalTorrentError.message("The RAM buffer is unavailable. Restart Download to fetch unfinished files again.") }
    }

    func relayBufferSpace(_ state: TorrentRelayState) throws -> (free: UInt64, used: UInt64, capacity: UInt64) {
        if let storage = state.storage {
            let space = try storage.space()
            let total = space.free.addingReportingOverflow(space.used)
            return (space.free, space.used, total.overflow ? .max : total.partialValue)
        }
        guard let volume = state.volume else { throw LocalTorrentError.message("The RAM buffer is unavailable.") }
        let free = try ram.availableBytes(volume)
        return (free, state.memoryBytes - min(state.memoryBytes, free), state.memoryBytes)
    }

    func saveRelayMigration() throws {
        try save()
        try TorrentRelayStorage.synchronize(store.directory.appendingPathComponent("queue-v1.json"))
        try TorrentRelayStorage.synchronize(store.directory)
    }

    func switchRelayToStorage(_ id: UUID, parent: URL) async {
        guard let original = job(id), original.canSwitchRelayToStorage, !busy.contains(id), !closed else { return }
        busy.insert(id); error = nil; restoredResumeIDs.remove(id)
        var resume = false, pausedWriter = false
        var prepared: TorrentRelayStorage?
        let lease = LocalFileAccessLease([parent])
        defer { withExtendedLifetime(lease) {}; finishOperation(id) }
        do {
            try LocalFileAccess.validate(parent, directory: true, writing: true)
            let path = parent.resolvingSymlinksInPath().standardizedFileURL.path
            let forbidden = [store.directory] + jobs.compactMap { $0.relay?.volume?.root }
            guard !forbidden.contains(where: {
                let root = $0.resolvingSymlinksInPath().standardizedFileURL.path
                return path == root || path.hasPrefix(root + "/")
            }) else { throw LocalTorrentError.message("Choose a storage folder outside the torrent’s RAM buffer and app resume folder.") }
            let sensitive = try parent.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames ?? false
            try TorrentRelayStorage.validateLayout(original.files, caseSensitive: sensitive)
            if let gid = gids[id], engine.running { try await pauseRelayWriter(gid) }
            pausedWriter = true
            relayGenerations[id] = nil
            relayUploaders[id]?.stop(); relayTasks[id]?.cancel()
            if let task = relayTasks[id] { await task.value }
            relayTasks[id] = nil; relayUploaders[id] = nil
            guard !closed, let state = job(id)?.relay else { throw CancellationError() }
            edit(id) { $0.phase = .paused; $0.clearTransferStats(); $0.message = "Moving existing torrent data to storage…" }
            try save()
            if let gid = gids[id], engine.running { try await engine.remove(gid) }
            gids[id] = nil
            let storage = try TorrentRelayStorage.create(in: parent, owner: id)
            prepared = storage
            if let volume = state.volume {
                try await ram.validate(volume)
                try await storage.copy(from: volume.payload) { [weak self] filename in
                    Task { @MainActor in
                        guard let self, !self.closed, self.busy.contains(id), self.job(id)?.relay?.storage == nil else { return }
                        self.edit(id) { $0.message = "Moving to storage: \(filename)" }
                    }
                }
            }
            try TorrentRelayStorage.synchronize(storage.root.appendingPathComponent(".mycloud-owner"))
            try TorrentRelayStorage.synchronize(storage.payload)
            try TorrentRelayStorage.synchronize(storage.root)
            try TorrentRelayStorage.synchronize(storage.parent)
            guard !closed else { throw CancellationError() }
            // Persist the disk copy before releasing RAM. Keeping the volume
            // reference makes an interrupted release retryable after relaunch.
            leases[id] = lease
            let space = try storage.space()
            edit(id) {
                $0.relay?.storage = storage
                $0.relay?.bufferUsed = space.used; $0.relay?.bufferAvailable = space.free
            }
            try saveRelayMigration()
            if let volume = state.volume { try await ram.release(volume) }
            edit(id) {
                $0.relay?.volume = nil
                $0.message = "Using storage. Uploaded files stay available for sharing while space allows."
            }
            try saveRelayMigration()
            relayQueued[id] = nil; relayQueuedSince[id] = nil; relayFileCensusAt[id] = nil
            resume = original.phase.active
        } catch {
            if let prepared, job(id)?.relay?.storage == nil {
                // This is only an incomplete migration copy; RAM is intact.
                if (try? prepared.validate(owner: id)) != nil { try? FileManager.default.removeItem(at: prepared.root) }
            }
            if !closed {
                self.error = error.localizedDescription
                edit(id) { if pausedWriter { $0.phase = .paused }; $0.message = error.localizedDescription }
                saveOrReport()
            }
        }
        busy.remove(id)
        if resume, !closed, !pendingStops.contains(id) { await resumeRelay(id) }
    }
}

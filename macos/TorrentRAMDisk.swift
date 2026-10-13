import Darwin
import Foundation

private final class TorrentCommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

struct TorrentRAMVolume: Codable, Equatable {
    let device: String
    let image: String
    let volumeDevice: String
    let uuid: String
    let mount: String
    let owner: UUID
    let bytes: UInt64
    var root: URL { URL(fileURLWithPath: mount, isDirectory: true) }
    var payload: URL { root.appendingPathComponent("payload", isDirectory: true) }
}

@MainActor protocol TorrentRAMDriving {
    func acquire(id: UUID, bytes: UInt64, directory: URL) async throws -> TorrentRAMVolume
    func validate(_ volume: TorrentRAMVolume) async throws
    func availableBytes(_ volume: TorrentRAMVolume) throws -> UInt64
    /// Empty the volume without detaching it, at a window boundary.
    ///
    /// This used to detach and reattach instead, on the understanding that a
    /// `ram://` image never hands blocks back until it is detached. Measured
    /// on macOS 26.5 that does not hold: deleting a file returns its memory,
    /// and the freed blocks are reusable — a 512 MB volume took 800 MB of
    /// writes across a delete with memory returning to its pre-write level.
    /// Where an older system does hold the high-water mark, the volume simply
    /// stays at the budget the user chose, which is what a full window reaches
    /// anyway. Keeping it attached costs neither, and saves a reformat and a
    /// torn-down swarm at every boundary.
    func clear(_ volume: TorrentRAMVolume) async throws
    func release(_ volume: TorrentRAMVolume) async throws
}

extension TorrentRAMDriving {
    func availableBytes(_ volume: TorrentRAMVolume) throws -> UInt64 {
        let values = try volume.root.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        guard let available = values.volumeAvailableCapacity, available >= 0 else {
            throw LocalTorrentError.message("Could not measure free space in the RAM buffer. Resume to try again.")
        }
        return min(volume.bytes, UInt64(available))
    }
}

/// A real RAM-backed, case-sensitive APFS volume. The unmounted mountpoint is
/// read-only, so a vanished volume can never turn into an on-disk payload cache.
@MainActor final class TorrentRAMDisk: TorrentRAMDriving {
    static func command(_ executable: String, _ arguments: [String], timeout: TimeInterval = 30,
                        maximumOutput: Int = 16 * 1024 * 1024) async throws -> Data {
        let cancellation = TorrentCommandCancellation()
        let worker = Task.detached(priority: .utility) {
            guard timeout.isFinite, timeout > 0, maximumOutput > 0 else { throw CocoaError(.coderInvalidValue) }
            if cancellation.isCancelled { throw CancellationError() }
            let child = Process(), pipe = Pipe()
            child.executableURL = URL(fileURLWithPath: executable); child.arguments = arguments
            child.standardInput = FileHandle.nullDevice; child.standardOutput = pipe; child.standardError = FileHandle.nullDevice
            child.environment = ["PATH":"/usr/bin:/bin:/usr/sbin:/sbin", "LANG":"en_US.UTF-8"]
            try child.run()
            try? pipe.fileHandleForWriting.close()
            let descriptor = pipe.fileHandleForReading.fileDescriptor
            defer { try? pipe.fileHandleForReading.close() }
            let flags = fcntl(descriptor, F_GETFL)
            _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            var data = Data(), failure: Error?, stoppedAt: TimeInterval?
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            func signal(_ value: Int32) {
                guard child.isRunning else { return }
                let pid = child.processIdentifier
                // Signal a private process group only when the command owns it.
                // Never send a negative PID into the app's inherited group.
                Darwin.kill(getpgid(pid) == pid ? -pid : pid, value)
            }
            while true {
                let now = ProcessInfo.processInfo.systemUptime
                if failure == nil {
                    if cancellation.isCancelled { failure = CancellationError() }
                    else if now >= deadline { failure = LocalTorrentError.message("macOS took too long to prepare or release the RAM buffer. Try again after closing apps using it.") }
                }
                if failure != nil, stoppedAt == nil { stoppedAt = now; signal(SIGTERM) }
                if let stoppedAt, now - stoppedAt >= 1, child.isRunning { signal(SIGKILL) }
                if failure != nil && !child.isRunning { break }
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    if count > maximumOutput - data.count {
                        failure = LocalTorrentError.message("The RAM buffer command returned too much output.")
                    } else if failure == nil { data.append(contentsOf: buffer.prefix(count)) }
                    continue
                }
                if count < 0, errno != EAGAIN && errno != EINTR, failure == nil { failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                if !child.isRunning { break }
                var event = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                _ = poll(&event, 1, 20)
            }
            child.waitUntilExit()
            if cancellation.isCancelled { throw CancellationError() }
            if let failure { throw failure }
            guard child.terminationStatus == 0 else {
                throw LocalTorrentError.message("macOS could not prepare or release the RAM buffer (\(URL(fileURLWithPath: executable).lastPathComponent), code \(child.terminationStatus)). Close apps using the buffer and try again.")
            }
            return data
        }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { cancellation.cancel() })
    }
    static func plist(_ executable: String, _ arguments: [String]) async throws -> [String: Any] {
        let data = try await command(executable, arguments)
        guard let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }
    private func imageExists(_ volume: TorrentRAMVolume) async throws -> Bool {
        let info = try await Self.plist("/usr/bin/hdiutil", ["info", "-plist"])
        return (info["images"] as? [[String: Any]] ?? []).contains { image in
            image["image-path"] as? String == volume.image && volume.image.hasPrefix("ram://") &&
            (image["system-entities"] as? [[String: Any]] ?? []).contains { $0["dev-entry"] as? String == volume.device }
        }
    }
    func acquire(id: UUID, bytes: UInt64, directory: URL) async throws -> TorrentRAMVolume {
        try TorrentRelayState.validateBudget(bytes)
        try LocalTorrentStore.protect(directory)
        let record = directory.appendingPathComponent("ram-volume.json")
        if FileManager.default.fileExists(atPath: record.path) {
            let volume = try JSONDecoder().decode(TorrentRAMVolume.self, from: LocalTorrentStore.read(record, maximum: 16_384))
            guard volume.owner == id, volume.bytes == bytes, volume.mount == directory.appendingPathComponent("RAM").path else { throw CocoaError(.fileReadCorruptFile) }
            if try await imageExists(volume) {
                // Device numbers are reusable. Only a matching volume UUID AND
                // the private owner marker authorize reuse or ejection.
                try await validate(volume); return volume
            }
        }
        let mount = directory.appendingPathComponent("RAM", isDirectory: true)
        if FileManager.default.fileExists(atPath: mount.path) {
            let values = try mount.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .volumeUUIDStringKey])
            guard values.isDirectory == true, values.isSymbolicLink != true,
                  values.volumeUUIDString == (try directory.resourceValues(forKeys: [.volumeUUIDStringKey])).volumeUUIDString,
                  (try FileManager.default.contentsOfDirectory(atPath: mount.path)).isEmpty else {
                throw LocalTorrentError.message("The previous RAM mount could not be identified safely. Restart this Mac to release it, then Resume.")
            }
        } else { try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: false, attributes: [.posixPermissions:0o500]) }
        try FileManager.default.setAttributes([.posixPermissions:0o500], ofItemAtPath: mount.path)
        let image = "ram://\(bytes / 512)"
        let before = try await Self.plist("/usr/bin/hdiutil", ["info", "-plist"])
        let oldDevices = Set((before["images"] as? [[String: Any]] ?? []).flatMap { ($0["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["dev-entry"] as? String } })
        let attached = try await Self.plist("/usr/bin/hdiutil", ["attach", "-nomount", "-plist", image])
        guard let device = (attached["system-entities"] as? [[String: Any]])?.compactMap({ $0["dev-entry"] as? String }).first,
              device.range(of: #"^/dev/disk[0-9]+$"#, options: .regularExpression) != nil, !oldDevices.contains(device) else {
            throw LocalTorrentError.message("macOS did not return a new RAM device.")
        }
        // Format ONLY the new device returned by this attach call, never one
        // read from a saved record. The name is unique to this transfer.
        let name = "MCDRAM-" + id.uuidString.replacingOccurrences(of: "-", with: "")
        do {
            _ = try await Self.command("/usr/sbin/diskutil", ["eraseDisk", "APFSX", name, device])
            let automatic = "/Volumes/" + name
            let info = try await Self.plist("/usr/sbin/diskutil", ["info", "-plist", automatic])
            guard let uuid = info["VolumeUUID"] as? String, let volumeDevice = info["DeviceNode"] as? String else { throw CocoaError(.fileReadCorruptFile) }
            _ = try await Self.command("/usr/sbin/diskutil", ["unmount", volumeDevice])
            _ = try await Self.command("/usr/sbin/diskutil", ["mount", "nobrowse", "-mountOptions", "nodev,nosuid", "-mountPoint", mount.path, volumeDevice])
            let volume = TorrentRAMVolume(device: device, image: image, volumeDevice: volumeDevice, uuid: uuid, mount: mount.path, owner: id, bytes: bytes)
            try LocalTorrentStore.protect(mount)
            try LocalTorrentStore.write(Data(id.uuidString.utf8), to: mount.appendingPathComponent(".mycloud-owner"))
            try LocalTorrentStore.write(Data(), to: mount.appendingPathComponent(".metadata_never_index"))
            try LocalTorrentStore.write(JSONEncoder().encode(volume), to: record)
            try await validateMount(volume)
            try LocalTorrentStore.protect(volume.payload)
            try await validate(volume)
            return volume
        } catch {
            // We still own this fresh attachment; it has never been released or
            // recovered by device number. Best-effort cleanup on setup failure.
            _ = try? await Self.command("/usr/bin/hdiutil", ["detach", device])
            throw error
        }
    }
    func validate(_ volume: TorrentRAMVolume) async throws {
        try await validateMount(volume)
        let payload = try volume.payload.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .volumeUUIDStringKey])
        guard payload.isDirectory == true, payload.isSymbolicLink != true, payload.volumeUUIDString == volume.uuid else {
            throw LocalTorrentError.message("The download folder is no longer inside the RAM buffer. It was not used.")
        }
    }
    private func validateMount(_ volume: TorrentRAMVolume) async throws {
        guard try await imageExists(volume) else { throw LocalTorrentError.message("The RAM buffer was lost. Restart Download to fetch unfinished files again.") }
        let info = try await Self.plist("/usr/sbin/diskutil", ["info", "-plist", volume.mount])
        guard info["VolumeUUID"] as? String == volume.uuid, info["DeviceNode"] as? String == volume.volumeDevice,
              URL(fileURLWithPath: info["MountPoint"] as? String ?? "/").resolvingSymlinksInPath().path == volume.root.resolvingSymlinksInPath().path, info["FilesystemType"] as? String == "apfs",
              String(data: try LocalTorrentStore.read(volume.root.appendingPathComponent(".mycloud-owner"), maximum: 128), encoding: .utf8) == volume.owner.uuidString else {
            throw LocalTorrentError.message("The RAM volume changed. It was not written to or removed.")
        }
    }
    func clear(_ volume: TorrentRAMVolume) async throws {
        try await validate(volume)
        try TorrentRelayStorage.clearPayload(volume.payload)
    }
    func release(_ volume: TorrentRAMVolume) async throws {
        if try await !imageExists(volume) { return } // RAM was lost after a Mac restart.
        // Detaching an owned volume is safe even if its payload directory was
        // damaged. Stop/Restart must still be able to release that memory.
        try await validateMount(volume)
        _ = try await Self.command("/usr/bin/hdiutil", ["detach", volume.device])
    }
}

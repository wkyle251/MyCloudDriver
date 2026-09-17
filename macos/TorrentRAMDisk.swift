import Foundation

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
    func clear(_ volume: TorrentRAMVolume) async throws
    func release(_ volume: TorrentRAMVolume) async throws
    func recycle(_ volume: TorrentRAMVolume, id: UUID, bytes: UInt64, directory: URL) async throws -> TorrentRAMVolume
}

extension TorrentRAMDriving {
    /// Detach and reattach, rather than emptying in place.
    ///
    /// A `ram://` image allocates lazily but never hands blocks back: deleting
    /// files inside it returns only the page-cache copy, while the backing
    /// store stays at the high-water mark of bytes ever resident until the
    /// image is detached. Emptying a 43 GB window in place therefore leaves
    /// 43 GB of this Mac's memory claimed for every window that follows.
    func recycle(_ volume: TorrentRAMVolume, id: UUID, bytes: UInt64, directory: URL) async throws -> TorrentRAMVolume {
        try await release(volume)
        return try await acquire(id: id, bytes: bytes, directory: directory)
    }
}

/// A real RAM-backed, case-sensitive APFS volume. The unmounted mountpoint is
/// read-only, so a vanished volume can never turn into an on-disk payload cache.
@MainActor final class TorrentRAMDisk: TorrentRAMDriving {
    static func command(_ executable: String, _ arguments: [String]) async throws -> Data {
        try await Task.detached(priority: .utility) {
            let child = Process(), pipe = Pipe()
            child.executableURL = URL(fileURLWithPath: executable); child.arguments = arguments
            child.standardInput = FileHandle.nullDevice; child.standardOutput = pipe; child.standardError = FileHandle.nullDevice
            child.environment = ["PATH":"/usr/bin:/bin:/usr/sbin:/sbin", "LANG":"en_US.UTF-8"]
            try child.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            child.waitUntilExit()
            guard child.terminationStatus == 0, data.count < 16 * 1024 * 1024 else {
                throw LocalTorrentError.message("macOS could not prepare or release the RAM buffer (\(URL(fileURLWithPath: executable).lastPathComponent), code \(child.terminationStatus)). Close apps using the buffer and try again.")
            }
            return data
        }.value
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
            try await validate(volume)
            try LocalTorrentStore.protect(volume.payload)
            return volume
        } catch {
            // We still own this fresh attachment; it has never been released or
            // recovered by device number. Best-effort cleanup on setup failure.
            _ = try? await Self.command("/usr/bin/hdiutil", ["detach", device])
            throw error
        }
    }
    func validate(_ volume: TorrentRAMVolume) async throws {
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
        if FileManager.default.fileExists(atPath: volume.payload.path) { try FileManager.default.removeItem(at: volume.payload) }
        try LocalTorrentStore.protect(volume.payload)
    }
    func release(_ volume: TorrentRAMVolume) async throws {
        if try await !imageExists(volume) { return } // RAM was lost after a Mac restart.
        try await validate(volume)
        _ = try await Self.command("/usr/bin/hdiutil", ["detach", volume.device])
    }
}

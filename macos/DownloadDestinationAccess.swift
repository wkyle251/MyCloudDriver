import Darwin
import Foundation

/// A remembered path is not proof that an external disk is still mounted.
/// Keep the volume identity alongside the queued selection across app restarts.
struct DownloadDestinationCheckpoint: Codable, Equatable {
    let volumeID: String?
    var bookmark: Data? = nil
    var destinationKind: String? = nil
}

/// The folder is on a different disk than the one its downloads started on: another disk with the same
/// name, or the same disk reformatted. Unlike an unplugged disk, waiting for it can never succeed.
struct DownloadDestinationReplaced: LocalizedError {
    let path: String
    var errorDescription: String? {
        "The disk for “\(path)” is not the one these downloads started on; it was replaced or reformatted. If you restored the unfinished downloads onto it, choose Use This Disk. Otherwise reconnect the original disk."
    }
}

/// Evidence that unfinished downloads were put back on a disk: this app's own progress files for the queued
/// items, at the exact place their download would continue. Only that proves the disk is the one the user
/// restored, so an unrelated disk of the same name is never accepted this way. Bounded, so a huge destination
/// cannot stall a check; running out of budget just means asking instead.
enum DownloadRestoredProgress {
    struct Probe {
        let directory: URL
        let name: String
        let isFolder: Bool
    }
    private static let markers = [".part.resume.json", ".part.ranges.json", ".part"]

    static func found(_ probes: [Probe], limit: Int = 4000) -> Bool {
        var budget = limit
        for probe in probes {
            if probe.isFolder {
                if scan(probe.directory.appendingPathComponent(probe.name, isDirectory: true), budget: &budget) { return true }
            } else if markers.contains(where: { FileManager.default.fileExists(atPath: probe.directory.appendingPathComponent(probe.name + $0).path) }) {
                return true
            }
            if budget <= 0 { return false }
        }
        return false
    }

    /// Breadth first, so progress files near the top are found before a deep tree is walked.
    private static func scan(_ root: URL, budget: inout Int) -> Bool {
        var queue = [root], index = 0
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        while index < queue.count, budget > 0 {
            let folder = queue[index]; index += 1
            guard let entries = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: []) else { continue }
            for entry in entries {
                budget -= 1
                let values = try? entry.resourceValues(forKeys: Set(keys))
                if values?.isDirectory == true {
                    if values?.isSymbolicLink != true { queue.append(entry) }
                } else if markers.contains(where: { entry.lastPathComponent.hasSuffix($0) }) {
                    return true
                }
                if budget <= 0 { break }
            }
        }
        return false
    }
}

struct SavedDownloadPartialCleanup: Codable, Hashable {
    let path: String
    let destinationPath: String
    /// Nil identifies a folder tree; cleanup removes only owned partials.
    let sourceFileID: String?
}

/// Explicitly adding a selection supersedes a cancelled partial's cleanup.
/// New helpers wait for the old cleanup worker to finish before writing.
final class DownloadCleanupFence: @unchecked Sendable {
    private let lock = NSLock()
    private var revision: UInt64 = 0

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        revision &+= 1
    }

    func generation() -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return revision
    }

    func performIfCurrent(_ generation: UInt64, operation: () throws -> Void) throws -> Bool {
        lock.lock()
        let current = revision == generation
        lock.unlock()
        guard current else { return false }
        try operation()
        lock.lock(); defer { lock.unlock() }
        return revision == generation
    }
}

enum DownloadDestinationAccess {
    static func validate(_ destination: URL, checkpoint: DownloadDestinationCheckpoint? = nil) throws -> DownloadDestinationCheckpoint {
        guard destination.isFileURL else {
            throw CloudDriveError.waiting("Choose an available download folder on this Mac or a mounted disk.")
        }
        let destination = destination.standardizedFileURL
        let components = destination.pathComponents
        if components.count >= 3, components[1] == "Volumes" {
            let mount = URL(fileURLWithPath: "/Volumes").appendingPathComponent(components[2], isDirectory: true)
            var fresh = mount; fresh.removeAllCachedResourceValues()
            guard (try? fresh.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true else {
                throw CloudDriveError.waiting("The disk for “\(destination.path)” is disconnected. Reconnect the original disk; downloads will continue automatically.")
            }
        }
        var ancestor = destination
        while true {
            var info = stat()
            if lstat(ancestor.path, &info) == 0 { break }
            let code = errno
            guard code == ENOENT else { throw accessError(destination, code: code) }
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { throw accessError(destination, code: code) }
            ancestor = parent
        }
        var fresh = ancestor; fresh.removeAllCachedResourceValues()
        let values: URLResourceValues
        do {
            values = try fresh.resourceValues(forKeys: MountedVolumeIdentity.resourceKeys.union([
                .isDirectoryKey, .volumeIsReadOnlyKey, .volumeIsInternalKey
            ]))
        } catch { throw accessError(destination, code: EACCES) }
        guard values.isDirectory == true else {
            throw CloudDriveError.waiting("The download folder “\(destination.path)” was replaced by a file. Restore the folder or choose another download folder.")
        }
        let volumeID = MountedVolumeIdentity.identifier(values)
        if let expected = checkpoint?.volumeID, volumeID != expected {
            throw DownloadDestinationReplaced(path: destination.path)
        }
        guard values.volumeIsReadOnly != true,
              FileManager.default.isReadableFile(atPath: ancestor.path),
              FileManager.default.isWritableFile(atPath: ancestor.path),
              access(ancestor.path, W_OK | X_OK) == 0 else {
            throw accessError(destination, code: EACCES)
        }
        return DownloadDestinationCheckpoint(volumeID: volumeID,
            bookmark: checkpoint?.bookmark ?? (try? ancestor.bookmarkData(options: .withSecurityScope,
                includingResourceValuesForKeys: [.volumeUUIDStringKey], relativeTo: nil)),
            destinationKind: DownloadDestinationPolicy.destinationKind(
                ExternalVolume.bufferedKind(isInternal: values.volumeIsInternal, isLocal: values.volumeIsLocal)))
    }

    private static func accessError(_ destination: URL, code: Int32) -> CloudDriveError {
        if code == ENOENT || code == ENODEV || code == ENXIO || code == EIO {
            return .waiting("The download destination “\(destination.path)” is unavailable. Reconnect the original disk; downloads will continue automatically.")
        }
        return .waiting("Cannot write to “\(destination.path)”. Restore write access or choose this folder again to grant access in macOS. Downloads will continue when access returns.")
    }
}

import Foundation

/// Check the actual mounted volume, rather than treating a remembered path as
/// proof that a disk is present. Reads also work on read-only disks and shares.
enum LocalFileAccess {
    static func volumeID(_ url: URL) -> String? {
        var fresh = url; fresh.removeAllCachedResourceValues()
        guard let values = try? fresh.resourceValues(forKeys: MountedVolumeIdentity.resourceKeys) else { return nil }
        return MountedVolumeIdentity.identifier(values)
    }

    @discardableResult
    static func validate(_ url: URL, volumeID expected: String? = nil,
                         directory: Bool = false, writing: Bool = false) throws -> URL {
        guard url.isFileURL else { throw CloudDriveError.message("Choose a file or folder on this Mac or a mounted disk.") }
        var fresh = url.standardizedFileURL; fresh.removeAllCachedResourceValues()
        let components = fresh.pathComponents
        if components.count >= 3, components[1] == "Volumes" {
            var mount = URL(fileURLWithPath: "/Volumes").appendingPathComponent(components[2], isDirectory: true)
            mount.removeAllCachedResourceValues()
            guard (try? mount.resourceValues(forKeys: [.isVolumeKey]).isVolume) == true else {
                throw CloudDriveError.waiting("The disk for “\(url.lastPathComponent)” is unavailable. Reconnect it in Finder.")
            }
        }
        let values: URLResourceValues
        do { values = try fresh.resourceValues(forKeys: MountedVolumeIdentity.resourceKeys.union([.isDirectoryKey, .isRegularFileKey, .volumeIsReadOnlyKey])) }
        catch { throw CloudDriveError.waiting("“\(url.lastPathComponent)” is unavailable. Waiting for its disk to reconnect.") }
        if let expected, MountedVolumeIdentity.identifier(values) != expected {
            throw CloudDriveError.waiting("The original disk for “\(url.lastPathComponent)” is unavailable. Waiting for that disk to reconnect.")
        }
        guard values.isDirectory == true || (!directory && values.isRegularFile == true) else {
            throw CloudDriveError.message(directory ? "Choose an available folder." : "Choose a regular file or folder.")
        }
        guard FileManager.default.isReadableFile(atPath: fresh.path) else {
            throw CloudDriveError.waiting("Cannot read “\(url.lastPathComponent)”. Waiting for access to this disk or folder in macOS.")
        }
        if writing && (values.volumeIsReadOnly == true || !FileManager.default.isWritableFile(atPath: fresh.path)) {
            throw CloudDriveError.waiting("“\(url.lastPathComponent)” is read-only. Waiting for write access to the export folder.")
        }
        return fresh
    }

    static func validateUploadSources(_ urls: [URL], volumes: [String: String] = [:]) throws -> [String: String] {
        var result: [String: String] = [:]
        for url in urls {
            try validate(url, volumeID: volumes[url.path])
            if let id = volumeID(url) { result[url.path] = id }
        }
        return result
    }

    static func uploadBookmarks(_ urls: [URL]) -> [String: Data] {
        var result: [String: Data] = [:]
        for url in urls {
            result[url.path] = try? url.bookmarkData(options: .withSecurityScope,
                includingResourceValuesForKeys: [.volumeUUIDStringKey], relativeTo: nil)
        }
        return result
    }
}

/// Keep picker-granted access alive while an upload waits, runs or pauses.
final class LocalFileAccessLease {
    private let scoped: [URL]
    init(_ urls: [URL], bookmarks: [String: Data] = [:]) {
        let restored = bookmarks.values.compactMap { data -> URL? in
            var stale = false
            return try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting], bookmarkDataIsStale: &stale)
        }
        scoped = (restored + urls).filter { $0.startAccessingSecurityScopedResource() }
    }
    deinit { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
}

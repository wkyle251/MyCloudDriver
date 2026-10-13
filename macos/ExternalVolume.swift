import Foundation

/// A disk the Mac reads over a cable rather than from its own storage. One rule
/// for the sidebar's disk list and for media buffering: a volume whose
/// internal-ness is unknown, such as a mounted disk image, is not external.
enum ExternalVolume {
    /// Where media is read through RAM instead of straight from the volume.
    enum Kind: Equatable {
        case externalDisk, networkShare

        var bufferingMessage: String {
            switch self {
            case .externalDisk: return "Buffering from external disk…"
            case .networkShare: return "Buffering from network share…"
            }
        }
    }

    static func isExternal(isInternal: Bool?, isLocal: Bool?) -> Bool {
        isInternal == false && isLocal == true
    }

    /// A mount the Mac reaches over the network (SMB, NFS, AFP, WebDAV). An unknown locality is not one.
    static func isNetworkShare(isLocal: Bool?) -> Bool {
        isLocal == false
    }

    /// Which volumes play media from RAM: cabled external disks and network shares, both slower and less
    /// steady than the Mac's own storage. The startup disk and volumes of unknown kind are read directly.
    static func bufferedKind(isInternal: Bool?, isLocal: Bool?) -> Kind? {
        if isNetworkShare(isLocal: isLocal) { return .networkShare }
        return isExternal(isInternal: isInternal, isLocal: isLocal) ? .externalDisk : nil
    }

    /// Reads the volume's current flags, never a cached copy, so a disk that was
    /// swapped under the same path is judged by what is mounted now.
    static func bufferedKind(_ url: URL) -> Kind? {
        guard let values = freshValues(url) else { return nil }
        return bufferedKind(isInternal: values.volumeIsInternal, isLocal: values.volumeIsLocal)
    }

    static func isExternal(_ url: URL) -> Bool {
        guard let values = freshValues(url) else { return false }
        return isExternal(isInternal: values.volumeIsInternal, isLocal: values.volumeIsLocal)
    }

    private static func freshValues(_ url: URL) -> URLResourceValues? {
        guard url.isFileURL else { return nil }
        var fresh = url
        fresh.removeAllCachedResourceValues()
        return try? fresh.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsLocalKey])
    }
}

/// A download to a spinning external disk or a network share saves its progress every few seconds instead of every
/// second: each save is a full flush of the drive's cache. The helper reads this from its environment.
enum DownloadDestinationPolicy {
    static let environmentKey = "MYCLOUDDRIVER_DOWNLOAD_DESTINATION"

    /// The continuous queue carries this per destination, including roots
    /// appended after the helper starts. Unknown volumes keep frequent saves.
    static func destinationKind(_ kind: ExternalVolume.Kind?) -> String {
        switch kind {
        case .externalDisk: return "external"
        case .networkShare: return "network"
        case nil: return "internal"
        }
    }

    /// `environment` with the destination's kind recorded, or the key removed for an internal or unknown one.
    static func environment(applying kind: ExternalVolume.Kind?, to environment: [String: String]) -> [String: String] {
        var result = environment
        switch kind {
        case .externalDisk: result[environmentKey] = "external"
        case .networkShare: result[environmentKey] = "network"
        case nil: result.removeValue(forKey: environmentKey)
        }
        return result
    }
}

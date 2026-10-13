import Foundation

/// SMB shares often have no volume UUID. Their remount address identifies the
/// server and share without remembering login details or mistaking a reused
/// mount path for the original disk.
enum MountedVolumeIdentity {
    static let resourceKeys: Set<URLResourceKey> = [
        .volumeUUIDStringKey, .volumeIsLocalKey, .volumeURLForRemountingKey
    ]

    static func identifier(_ values: URLResourceValues) -> String? {
        identifier(uuid: values.volumeUUIDString, isLocal: values.volumeIsLocal,
                   remountURL: values.volumeURLForRemounting)
    }

    static func identifier(uuid: String?, isLocal: Bool?, remountURL: URL?) -> String? {
        if let uuid = uuid?.trimmingCharacters(in: .whitespacesAndNewlines), !uuid.isEmpty { return uuid }
        guard isLocal == false, let remountURL, !remountURL.isFileURL,
              let parts = URLComponents(url: remountURL, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme, !scheme.isEmpty,
              let host = parts.percentEncodedHost, !host.isEmpty else { return nil }
        var path = parts.percentEncodedPath
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        // Bonjour service names can contain spaces and Unicode. Reassigning
        // URLComponents.host makes Foundation reject some valid SMB addresses.
        // Keep its encoded host and include only the server, port and share.
        let port = parts.port.map { ":\($0)" } ?? ""
        return "network-volume:\(scheme.lowercased())://\(host.lowercased())\(port)\(path)"
    }
}

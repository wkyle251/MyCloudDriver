import AppKit
import Combine
import Foundation

/// One mounted external disk or network share. A name or mount path alone is
/// not its identity: another device or server can reuse either.
struct ExternalDisk: Identifiable, Equatable, Sendable {
    let url: URL
    let name: String
    let volumeUUID: String?
    let isReadOnly: Bool
    let isNetwork: Bool
    let volumeID: String?

    var symbol: String { isNetwork ? "network" : "externaldrive" }

    var id: String {
        // Snapshot construction has already standardized the mount URL. View
        // identity must not perform filesystem work during SwiftUI rendering.
        let location = url.absoluteString
        let kind = isNetwork ? "network" : "external"
        guard let volumeID else { return "\(kind)-path:\(location)" }
        let identity = volumeUUID == nil ? volumeID : volumeID.lowercased()
        return "\(kind)-volume:\(identity):\(location)"
    }
}

/// Metadata only; injectable so tests never need to enumerate a user's disks.
struct ExternalDiskSnapshot: Sendable {
    let url: URL
    var name: String?
    var volumeUUID: String?
    var isInternal: Bool?
    var isLocal: Bool?
    var isBrowsable: Bool?
    var isHidden: Bool?
    var isReadOnly: Bool?
    var remountURL: URL? = nil

    var disk: ExternalDisk? {
        let isNetwork = ExternalVolume.isNetworkShare(isLocal: isLocal)
        guard url.isFileURL, (isNetwork || ExternalVolume.isExternal(isInternal: isInternal, isLocal: isLocal)),
              isBrowsable == true, isHidden != true else { return nil }
        let root = url.standardizedFileURL
        let title = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let uuid = volumeUUID?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ExternalDisk(url: root,
            name: title.flatMap { $0.isEmpty ? nil : $0 } ?? (root.lastPathComponent.isEmpty ? (isNetwork ? "Network Disk" : "External Disk") : root.lastPathComponent),
            volumeUUID: uuid.flatMap { $0.isEmpty ? nil : $0 }, isReadOnly: isReadOnly == true,
            isNetwork: isNetwork,
            volumeID: MountedVolumeIdentity.identifier(uuid: uuid, isLocal: isLocal, remountURL: remountURL))
    }
}

@MainActor final class ExternalDiskCatalog: ObservableObject {
    @Published private(set) var disks: [ExternalDisk] = []
    var externalDisks: [ExternalDisk] { disks.filter { !$0.isNetwork } }
    var networkDisks: [ExternalDisk] { disks.filter(\.isNetwork) }
    private let snapshotLoader: (() -> [ExternalDiskSnapshot])?
    private let backgroundSnapshotLoader: @Sendable () -> [ExternalDiskSnapshot]
    private let notificationCenter: NotificationCenter
    private var observers: [NSObjectProtocol] = []
    private var refreshTask: Task<Void, Never>?
    private var refreshAgain = false
    private var isClosed = false

    init(snapshotLoader: (() -> [ExternalDiskSnapshot])? = nil,
         backgroundSnapshotLoader: @escaping @Sendable () -> [ExternalDiskSnapshot] = { ExternalDiskCatalog.systemSnapshot() },
         notificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        self.snapshotLoader = snapshotLoader
        self.backgroundSnapshotLoader = backgroundSnapshotLoader
        self.notificationCenter = notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            observers.append(notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        refresh()
    }

    /// Refresh the menu's metadata without opening any browser or changing a
    /// provider that may still own transfers, selections or scan results.
    func refresh() {
        guard !isClosed else { return }
        // Injected metadata stays synchronous for deterministic model fixtures.
        if let snapshotLoader { publish(Self.sortedDisks(snapshotLoader())); return }
        guard refreshTask == nil else { refreshAgain = true; return }
        let read = backgroundSnapshotLoader
        refreshTask = Task { [weak self] in
            let next = await Task.detached(priority: .utility) { Self.sortedDisks(read()) }.value
            guard let self, !self.isClosed, !Task.isCancelled else { return }
            self.refreshTask = nil
            if self.refreshAgain {
                self.refreshAgain = false
                self.refresh()
            } else {
                self.publish(next)
            }
        }
    }

    private func publish(_ next: [ExternalDisk]) {
        if disks != next { disks = next }
    }

    nonisolated private static func sortedDisks(_ snapshots: [ExternalDiskSnapshot]) -> [ExternalDisk] {
        var seen = Set<String>()
        return snapshots.compactMap(\.disk).filter { seen.insert($0.id).inserted }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    func close() {
        guard !isClosed else { return }
        isClosed = true
        refreshTask?.cancel(); refreshTask = nil; refreshAgain = false
        observers.forEach(notificationCenter.removeObserver)
        observers = []
    }

    deinit { refreshTask?.cancel(); observers.forEach(notificationCenter.removeObserver) }

    /// Reads volume resource values only. It never lists children, reads file
    /// contents, mounts an unavailable disk, or creates anything on a volume.
    nonisolated static func systemSnapshot() -> [ExternalDiskSnapshot] {
        let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeUUIDStringKey, .volumeURLForRemountingKey,
            .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsBrowsableKey,
            .volumeIsReadOnlyKey, .isHiddenKey]
        guard let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys),
                                                              options: [.skipHiddenVolumes]) else { return [] }
        return urls.compactMap { url in
            var fresh = url
            fresh.removeAllCachedResourceValues()
            guard let values = try? fresh.resourceValues(forKeys: keys) else { return nil }
            return ExternalDiskSnapshot(url: url, name: values.volumeName, volumeUUID: values.volumeUUIDString,
                isInternal: values.volumeIsInternal, isLocal: values.volumeIsLocal,
                isBrowsable: values.volumeIsBrowsable, isHidden: values.isHidden,
                isReadOnly: values.volumeIsReadOnly, remountURL: values.volumeURLForRemounting)
        }
    }
}

import AppKit
import Combine
import Foundation

private final class SnapshotReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.lock(); defer { lock.unlock() }; count += 1; return count }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

/// Generated metadata only: no disk enumeration, file listing or mounting.
@main @MainActor struct ExternalDiskCatalogTests {
    static func snapshot(_ path: String, name: String? = nil, uuid: String? = nil,
                         internalDisk: Bool? = false, local: Bool? = true,
                         browsable: Bool? = true, hidden: Bool? = false,
                         readOnly: Bool? = false, remount: String? = nil) -> ExternalDiskSnapshot {
        .init(url: URL(fileURLWithPath: path, isDirectory: true), name: name, volumeUUID: uuid,
              isInternal: internalDisk, isLocal: local, isBrowsable: browsable,
              isHidden: hidden, isReadOnly: readOnly, remountURL: remount.flatMap(URL.init(string:)))
    }

    static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(condition(), "Timed out waiting for a generated volume notification")
    }

    nonisolated static func waitForSignal(_ signal: DispatchSemaphore) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: signal.wait(timeout: .now() + 3) == .success)
            }
        }
    }

    static func main() async throws {
        setbuf(stdout, nil)
        let center = NotificationCenter()
        let alpha = snapshot("/Synthetic/Alpha", name: "Shared Name", uuid: "UUID-A")
        let beta = snapshot("/Synthetic/Beta", name: "Shared Name", uuid: "UUID-B", readOnly: true)
        let network = snapshot("/Synthetic/Network", name: "Shared Name", internalDisk: nil, local: false,
            readOnly: true, remount: "smb://generated-user:generated-password@SERVER.local/Share/")
        var input = [beta, alpha, alpha,
            snapshot("/Synthetic/Internal", internalDisk: true),
            snapshot("/Synthetic/Unknown", internalDisk: nil),
            network, network,
            snapshot("/Synthetic/Unknown Local", local: nil),
            snapshot("/Synthetic/Hidden", hidden: true),
            snapshot("/Synthetic/Not Browsable", browsable: false),
            snapshot("/Synthetic/Unknown Browsable", browsable: nil)]
        var loads = 0
        let catalog = ExternalDiskCatalog(snapshotLoader: { loads += 1; return input }, notificationCenter: center)
        defer { catalog.close() }
        precondition(loads == 1 && catalog.disks.count == 3)
        precondition(catalog.externalDisks.count == 2 && catalog.networkDisks.count == 1)
        precondition(Set(catalog.disks.compactMap(\.volumeUUID)) == ["UUID-A", "UUID-B"])
        precondition(catalog.disks.first(where: { $0.volumeUUID == "UUID-B" })?.isReadOnly == true)
        precondition(catalog.networkDisks[0].isReadOnly && catalog.networkDisks[0].symbol == "network")
        precondition(Set(catalog.disks.map(\.id)).count == 3, "Same-name disks and shares must be separate choices")
        precondition(!ExternalVolume.isExternal(isInternal: nil, isLocal: false), "A network share is not a cabled external disk, even though media on it is buffered too")
        print("PASS separate external/network groups, unknown metadata filtering, same-name identity, deduplication and read-only browsing")

        let networkID = network.disk!.volumeID!
        precondition(networkID == "network-volume:smb://server.local/Share")
        let equivalent = snapshot("/Synthetic/Network", internalDisk: nil, local: false,
            remount: "SMB://different-user:other-password@server.local/Share?login=ignored#ignored")
        precondition(equivalent.disk!.id == network.disk!.id, "Credentials and URL decoration must not change the share identity")
        var otherServer = network; otherServer.remountURL = URL(string: "smb://other.local/Share")
        var otherShare = network; otherShare.remountURL = URL(string: "smb://server.local/Other")
        var differentCase = network; differentCase.remountURL = URL(string: "smb://server.local/share")
        precondition(otherServer.disk!.id != network.disk!.id && otherShare.disk!.id != network.disk!.id
                     && differentCase.disk!.id != network.disk!.id, "The server and case-sensitive share path identify the disk")
        precondition(MountedVolumeIdentity.identifier(uuid: "UUID-EXISTING", isLocal: false, remountURL: network.remountURL) == "UUID-EXISTING",
                     "Existing UUID-based checkpoints remain compatible")
        precondition(MountedVolumeIdentity.identifier(uuid: nil, isLocal: true, remountURL: network.remountURL) == nil)
        precondition(MountedVolumeIdentity.identifier(uuid: nil, isLocal: false, remountURL: URL(fileURLWithPath: "/Synthetic")) == nil)
        let bonjour = URL(string: "smb://generated-user:generated-password@Family%E2%80%99s%20MacBook%20Pro._smb._tcp.local/Shared%20Disk/")!
        precondition(MountedVolumeIdentity.identifier(uuid: nil, isLocal: false, remountURL: bonjour)
                     == "network-volume:smb://family%e2%80%99s%20macbook%20pro._smb._tcp.local/Shared%20Disk")
        let ipv6 = URL(string: "smb://[2001:DB8::1]:445/Share")!
        precondition(MountedVolumeIdentity.identifier(uuid: nil, isLocal: false, remountURL: ipv6)
                     == "network-volume:smb://[2001:db8::1]:445/Share")
        print("PASS UUID-less network identity, credential removal, normalization, server/share replacement and existing UUID compatibility")

        let originalID = alpha.disk!.id
        var renamed = alpha; renamed.name = "Renamed Disk"
        precondition(renamed.disk!.id == originalID, "Display-name changes must not change identity")
        var replacement = alpha; replacement.volumeUUID = "UUID-REPLACEMENT"
        precondition(replacement.disk!.id != originalID, "A replacement at the same path must be a different disk")
        let alias = snapshot("/Synthetic/Alpha Alias", name: "Shared Name", uuid: "UUID-A")
        precondition(alias.disk!.id != originalID, "Repeated UUID metadata at different paths must not collapse entries")
        let noUUID = snapshot("/Synthetic/Folder/../No UUID", name: "  ", uuid: " ")
        precondition(noUUID.disk!.name == "No UUID" && noUUID.disk!.volumeUUID == nil)
        precondition(noUUID.disk!.id == snapshot("/Synthetic/No UUID").disk!.id)
        let remoteURL = ExternalDiskSnapshot(url: URL(string: "https://example.invalid/disk")!, name: "Invalid", volumeUUID: nil,
            isInternal: false, isLocal: true, isBrowsable: true, isHidden: false, isReadOnly: false)
        precondition(remoteURL.disk == nil)
        print("PASS rename stability, same-path replacement, UUID/path disambiguation and standardized fallback identity")

        var publications = 0
        let observation = catalog.$disks.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }
        catalog.refresh()
        precondition(loads == 2 && publications == 0, "Unchanged metadata must not invalidate the browser menu")
        input = [renamed, beta]
        center.post(name: NSWorkspace.didRenameVolumeNotification, object: nil)
        try await wait { catalog.disks.contains(where: { $0.name == "Renamed Disk" }) }
        input = [beta]
        center.post(name: NSWorkspace.didUnmountNotification, object: nil)
        try await wait { catalog.disks.count == 1 }
        input = [renamed, beta]
        center.post(name: NSWorkspace.didMountNotification, object: nil)
        try await wait { catalog.disks.count == 2 }
        precondition(publications == 3)
        print("PASS mount, unmount, rename and deduplicated explicit refresh")

        let secondCenter = NotificationCenter()
        let second = ExternalDiskCatalog(snapshotLoader: { [] }, notificationCenter: secondCenter)
        defer { second.close() }
        precondition(second.disks.isEmpty && catalog.disks.count == 2)
        input = []
        center.post(name: NSWorkspace.didUnmountNotification, object: nil)
        catalog.close()
        let closedLoads = loads
        center.post(name: NSWorkspace.didMountNotification, object: nil)
        center.post(name: NSWorkspace.didRenameVolumeNotification, object: nil)
        catalog.refresh()
        try await Task.sleep(nanoseconds: 30_000_000)
        precondition(loads == closedLoads && catalog.disks.count == 2,
                     "Close must reject queued callbacks and remove its volume observers")
        print("PASS injected empty catalogs are independent; closing removes observers and rejects queued refreshes")
        try await testBackgroundRefresh(alpha: alpha, beta: beta)
    }

    static func testBackgroundRefresh(alpha: ExternalDiskSnapshot, beta: ExternalDiskSnapshot) async throws {
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let reads = SnapshotReadCounter()
        let start = Date()
        let catalog = ExternalDiskCatalog(backgroundSnapshotLoader: {
            precondition(!Thread.isMainThread, "Mounted-volume metadata must not block the UI thread")
            if reads.next() == 1 {
                entered.signal()
                precondition(release.wait(timeout: .now() + 5) == .success)
                return [alpha]
            }
            return [beta]
        }, notificationCenter: NotificationCenter())
        defer { catalog.close() }
        precondition(Date().timeIntervalSince(start) < 0.5 && catalog.disks.isEmpty)
        var published: [[ExternalDisk]] = []
        let observation = catalog.$disks.dropFirst().sink { published.append($0) }
        defer { observation.cancel() }
        let didEnter = await waitForSignal(entered)
        precondition(didEnter)
        for _ in 0..<100 { catalog.refresh() }
        var heartbeat = false
        let mainTask = Task { @MainActor in heartbeat = true }
        await mainTask.value
        precondition(heartbeat && reads.value == 1, "Refresh must coalesce while a slow disk is being read")
        release.signal()
        try await wait { catalog.disks == [beta.disk!] }
        precondition(reads.value == 2 && published == [[beta.disk!]], "Superseded disk snapshots must not publish")
        print("PASS slow mounted-volume reads stay off MainActor, coalesce refreshes and discard stale results")

        let closeEntered = DispatchSemaphore(value: 0), closeRelease = DispatchSemaphore(value: 0), finished = DispatchSemaphore(value: 0)
        defer { closeRelease.signal() }
        let closed = ExternalDiskCatalog(backgroundSnapshotLoader: {
            closeEntered.signal()
            precondition(closeRelease.wait(timeout: .now() + 5) == .success)
            finished.signal()
            return [alpha]
        }, notificationCenter: NotificationCenter())
        let closeStarted = await waitForSignal(closeEntered)
        precondition(closeStarted)
        closed.close(); closeRelease.signal()
        let didFinish = await waitForSignal(finished)
        precondition(didFinish)
        await Task.yield()
        precondition(closed.disks.isEmpty, "A background result must not revive a closed catalog")
        print("PASS closing a catalog rejects a pending background disk result")
    }
}

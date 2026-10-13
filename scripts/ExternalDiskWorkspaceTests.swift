import AppKit
import Foundation
import Photos

/// Only generated folders and injected volume metadata are browsed.
@main @MainActor struct ExternalDiskWorkspaceTests {
    static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(condition(), "Timed out waiting for the generated disk browser")
    }
    static func main() async throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ExternalDiskWorkspace-\(UUID().uuidString)")
        let base = root.appendingPathComponent("This Mac"), first = root.appendingPathComponent("Disk A"), second = root.appendingPathComponent("Disk B")
        let network = root.appendingPathComponent("Network Share")
        for folder in [base, first.appendingPathComponent("Nested"), second, network] {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Data("Generated A".utf8).write(to: first.appendingPathComponent("A.txt"))
        try Data("Generated B".utf8).write(to: second.appendingPathComponent("B.txt"))
        try Data("Generated network file".utf8).write(to: network.appendingPathComponent("Network.txt"))
        defer { try? fm.removeItem(at: root) }
        func snapshot(_ url: URL, name: String, uuid: String? = nil, readOnly: Bool = false, network: Bool = false) -> ExternalDiskSnapshot {
            .init(url: url, name: name, volumeUUID: uuid ?? LocalFileAccess.volumeID(url), isInternal: false,
                  isLocal: !network, isBrowsable: true, isHidden: false, isReadOnly: readOnly)
        }
        var snapshots = [snapshot(first, name: "External A"), snapshot(second, name: "External B", readOnly: true)]
        let center = NotificationCenter()
        let catalog = ExternalDiskCatalog(snapshotLoader: { snapshots }, notificationCenter: center)
        let suite = "MyCloudDriver.ExternalDiskWorkspaceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let access = PhotosAccessClient(status: { .notDetermined }, request: { .denied }, provider: { PhotosDriveProvider() })
        let hub = CloudDriveHub(pikpak: DownloaderModel.finderWorkspaceFixture(defaults: defaults), defaults: defaults,
            restoreConnections: false, photosAccess: access, localRootURL: base, externalDisks: catalog)
        defer { hub.close() }
        try await wait { !hub.local.isLoading }
        let diskA = catalog.disks.first(where: { $0.url.path == first.path })!, diskB = catalog.disks.first(where: { $0.url.path == second.path })!
        hub.openExternalDisk(diskA)
        try await wait { !hub.local.isLoading }
        precondition(hub.selected == .local && hub.selectedDriveTitle == "External A" && hub.selectedDriveSymbol == "externaldrive")
        precondition(hub.local.provider?.root.url?.path == first.path && Set(hub.local.items.map(\.name)) == ["A.txt", "Nested"])
        precondition(defaults.data(forKey: "myCloudDriver.localBookmark") == nil, "Menu choice must not replace another window's saved local folder")
        hub.local.enter(hub.local.items.first(where: { $0.name == "Nested" })!)
        try await wait { !hub.local.isLoading }
        let history = hub.local.history
        catalog.refresh(); hub.openExternalDisk(diskA)
        precondition(hub.local.history == history, "Catalog refresh and reselect must retain navigation")
        hub.showCurrentDrive(.local)
        precondition(hub.local.history == history && hub.selectedExternalDisk?.id == diskA.id,
                     "Search and other internal navigation must not return to the Mac folder")
        print("PASS external selection opens its root and title without overwriting local settings or resetting an existing disk's folder")

        snapshots[0].name = "Renamed A"
        catalog.refresh()
        precondition(hub.selectedDriveTitle == "Renamed A" && hub.local.history == history)
        let file = SimilarityFile(id: "generated-result", name: "A.txt", path: first.appendingPathComponent("A.txt").path,
                                 bytes: 11, family: "text", localPath: first.appendingPathComponent("A.txt").path, cloudId: nil, ancestors: [])
        hub.open(.photos)
        hub.local.similarity.revealInBrowser?(.local, file)
        try await wait { !hub.local.isLoading }
        precondition(hub.local.provider?.root.url?.path == first.path && hub.local.selectedItems.first?.name == "A.txt"
                     && hub.selectedDriveTitle == "Renamed A", "Show in Folder must retain the external provider")
        hub.local.useSimilarityFolder(second)
        let sources = try await hub.local.similarity.local.inventoryExternalSources!()
        let scanned = sources[0]
        let otherResult = SimilarityFile(id: scanned.id, name: scanned.name, path: scanned.path, bytes: scanned.size,
                                        family: "text", localPath: scanned.localPath, cloudId: nil, ancestors: [])
        hub.local.similarity.revealInBrowser?(.local, otherResult)
        try await wait { !hub.local.isLoading }
        precondition(hub.local.provider?.root.url?.path == second.path && hub.selectedExternalDisk?.id == diskB.id
                     && hub.selectedDriveTitle == "External B", "Revealing a separately scanned disk must update its drive title")
        hub.local.similarity.local.clearSession()
        hub.openExternalDisk(diskB)
        try await wait { !hub.local.isLoading }
        precondition(hub.selectedDriveTitle == "External B" && hub.local.items.map(\.name) == ["B.txt"])
        hub.open(.local)
        try await wait { !hub.local.isLoading }
        precondition(hub.local.provider?.root.url?.path == base.path && hub.selectedExternalDisk == nil && hub.selectedDriveTitle == "Local Disk")
        print("PASS read-only disks remain selectable, display-name refresh preserves browsing, and Local Disk returns to this Mac")

        snapshots.append(snapshot(network, name: "Other Mac", network: true)); catalog.refresh()
        let networkDisk = catalog.networkDisks[0]
        hub.openExternalDisk(networkDisk)
        try await wait { !hub.local.isLoading }
        precondition(hub.local.isConnected && hub.selectedDriveTitle == "Other Mac" && hub.selectedDriveSymbol == "network")
        precondition(hub.local.items.map(\.name) == ["Network.txt"] && hub.local.provider?.root.url?.path == network.path)
        precondition(defaults.data(forKey: "myCloudDriver.localBookmark") == nil)
        let destination = network.appendingPathComponent("Downloads/not-created")
        let checkpoint = try DownloadDestinationAccess.validate(destination)
        precondition(checkpoint.volumeID == LocalFileAccess.volumeID(network))
        _ = try DownloadDestinationAccess.validate(destination, checkpoint: checkpoint)
        do {
            _ = try DownloadDestinationAccess.validate(destination, checkpoint: .init(volumeID: "different-share"))
            preconditionFailure("A different download destination identity was accepted")
        } catch is DownloadDestinationReplaced { }
        let offlineNetwork = root.appendingPathComponent("Offline Network")
        try fm.moveItem(at: network, to: offlineNetwork)
        snapshots.removeAll(where: { $0.url.path == network.path }); catalog.refresh(); hub.local.refreshAvailability()
        precondition(!hub.local.isConnected && hub.local.items.isEmpty && hub.selectedExternalDisk?.id == networkDisk.id)
        precondition(hub.selectedDriveSymbol == "network")
        try fm.moveItem(at: offlineNetwork, to: network)
        snapshots.append(snapshot(network, name: "Other Mac", network: true)); catalog.refresh(); hub.local.refreshAvailability()
        try await wait { hub.local.isConnected && !hub.local.isLoading }
        precondition(hub.local.items.map(\.name) == ["Network.txt"])
        hub.open(.local)
        try await wait { !hub.local.isLoading }
        precondition(hub.local.provider?.root.url?.path == base.path && hub.selectedExternalDisk == nil)
        print("PASS network selection, generated file browsing, destination identity checks and share disconnect/reconnect")

        // External disks and network shares are the same Local Disk model and workspace as this Mac,
        // so several selected folders expand together there under the same rule.
        for (label, disk, volume) in [("external disk", diskA, first), ("network share", networkDisk, network)] {
            let folders = ["Expand One", "Expand Two", "Left Closed"]
            for name in folders { try fm.createDirectory(at: volume.appendingPathComponent(name + "/Deeper"), withIntermediateDirectories: true) }
            defer { for name in folders { try? fm.removeItem(at: volume.appendingPathComponent(name)) } }
            try Data("one".utf8).write(to: volume.appendingPathComponent("Expand One/Deeper/Leaf One.txt"))
            try Data("two".utf8).write(to: volume.appendingPathComponent("Expand Two/Deeper/Leaf Two.txt"))
            try Data("closed".utf8).write(to: volume.appendingPathComponent("Left Closed/Closed Leaf.txt"))
            hub.openExternalDisk(disk)
            try await wait { hub.local.isConnected && !hub.local.isLoading }
            precondition(hub.local.canExpandAllLevels, "A \(label) must offer Expand All Levels like Local Disk")
            let one = hub.local.items.first(where: { $0.name == "Expand One" })!, two = hub.local.items.first(where: { $0.name == "Expand Two" })!
            let closed = hub.local.items.first(where: { $0.name == "Left Closed" })!
            hub.local.expandAllLevels([one, two])
            precondition(hub.local.isExpandingAllLevels(one) && hub.local.isExpandingAllLevels(two) && !hub.local.isExpandingAllLevels(closed))
            try await wait { !hub.local.isLoading && !hub.local.tree.isLoading }
            let names = Set(hub.local.tree.rows.map(\.item.name))
            precondition(names.isSuperset(of: ["Leaf One.txt", "Leaf Two.txt"]) && !names.contains("Closed Leaf.txt"),
                         "Both selected folders on a \(label) open to their deepest level and the unselected one stays closed")
        }
        hub.open(.local)
        try await wait { !hub.local.isLoading }
        precondition(hub.local.provider?.root.url?.path == base.path && hub.selectedExternalDisk == nil)
        print("PASS Expand All Levels over several folders works on an external disk and a network share through the shared Local Disk workspace")

        snapshots[0] = snapshot(first, name: "Wrong device", uuid: "different-volume")
        catalog.refresh()
        hub.openExternalDisk(catalog.disks.first(where: { $0.url.path == first.path })!)
        precondition(hub.connectionError != nil && hub.local.provider?.root.url?.path == base.path)
        snapshots = [snapshot(first, name: "External A"), snapshot(second, name: "External B")]
        catalog.refresh(); hub.openExternalDisk(diskA)
        try await wait { !hub.local.isLoading }
        snapshots.removeAll(where: { $0.url.path == second.path }); catalog.refresh()
        hub.openExternalDisk(diskB)
        precondition(hub.connectionError != nil && hub.local.provider?.root.url?.path == first.path && hub.selectedExternalDisk?.id == diskA.id)
        print("PASS mismatched-volume and stale menu selections preserve the currently browsed disk")

        let otherCatalog = ExternalDiskCatalog(snapshotLoader: { [snapshot(first, name: "External A"), snapshot(second, name: "External B")] }, notificationCenter: NotificationCenter())
        let secondHub = CloudDriveHub(pikpak: DownloaderModel.finderWorkspaceFixture(defaults: defaults), defaults: defaults,
            restoreConnections: false, photosAccess: access, localRootURL: base, externalDisks: otherCatalog)
        defer { secondHub.close() }
        secondHub.inheritLocalBrowser(from: hub); secondHub.selected = .local
        try await wait { !secondHub.local.isLoading }
        precondition(secondHub.selectedExternalDisk == hub.selectedExternalDisk && secondHub.local.provider !== hub.local.provider)
        secondHub.openExternalDisk(diskB)
        try await wait { !secondHub.local.isLoading }
        precondition(secondHub.local.provider?.root.url?.path == second.path && hub.local.provider?.root.url?.path == first.path)
        precondition(secondHub.selectedDriveTitle == "External B" && hub.selectedDriveTitle == "External A")
        print("PASS new-window disk inheritance uses independent providers and two workspaces browse different disks")

        let offline = root.appendingPathComponent("Offline A")
        try fm.moveItem(at: first, to: offline)
        snapshots = []; catalog.refresh(); hub.local.refreshAvailability()
        precondition(!hub.local.isConnected && hub.local.items.isEmpty && hub.selectedExternalDisk?.id == diskA.id)
        precondition(hub.selectedDriveTitle == "External A" && secondHub.local.isConnected)
        try fm.moveItem(at: offline, to: first)
        snapshots = [snapshot(first, name: "External A")]; catalog.refresh(); hub.local.refreshAvailability()
        try await wait { hub.local.isConnected && !hub.local.isLoading }
        precondition(Set(hub.local.items.map(\.name)) == ["A.txt", "Nested"] && secondHub.local.provider?.root.url?.path == second.path)
        print("PASS unplug simulation keeps the original disk identity, clears unavailable rows and reconnects independently")

        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let sessions = WorkspaceSessionManager(initialHub: hub, makeHub: { sessionID, settings in
            let generatedCatalog = ExternalDiskCatalog(snapshotLoader: {
                [snapshot(first, name: "External A"), snapshot(second, name: "External B")]
            }, notificationCenter: NotificationCenter())
            return CloudDriveHub(pikpak: DownloaderModel.finderWorkspaceFixture(defaults: defaults,
                workspaceSessionID: sessionID, settings: settings), defaults: defaults, restoreConnections: false,
                photosAccess: access, localRootURL: base, externalDisks: generatedCatalog)
        })
        sessions.presentsWindows = false
        let primary = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        primary.isReleasedWhenClosed = false
        sessions.register(primary, hub: hub)
        sessions.presentSearch(scope: .expanded)
        precondition(hub.local.provider?.root.url?.path == first.path && hub.selectedExternalDisk?.id == diskA.id,
                     "Cmd-F must keep the external disk selected")
        sessions.newWindow()
        let windowID = PikPakWorkspaceStorage.sessionID(for: 2)
        let newHub = sessions.hubForTesting(windowID)!, newWindow = sessions.windowForTesting(windowID)!
        defer { newWindow.close(); primary.close() }
        try await wait { !newHub.local.isLoading }
        precondition(primary.title.contains("External A") && newWindow.title.contains("External A")
                     && newHub.local.provider?.root.url?.path == first.path)
        newHub.openExternalDisk(diskB)
        try await wait { !newHub.local.isLoading }
        precondition(primary.title.contains("External A") && newWindow.title.contains("External B")
                     && hub.local.provider?.root.url?.path == first.path && newHub.local.provider?.root.url?.path == second.path)
        print("PASS actual window/session routing: search retains the external disk, New Window inherits it and drive titles update independently")
    }
}

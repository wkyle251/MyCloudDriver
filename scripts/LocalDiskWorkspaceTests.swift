import AppKit
import Foundation
import Photos

@main struct LocalDiskWorkspaceTests {
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(condition(), "Timed out waiting for the local browser")
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("LocalDiskWorkspace-\(UUID().uuidString)")
        let drive = directory.appendingPathComponent("Drive"), other = directory.appendingPathComponent("Drive-other")
        try manager.createDirectory(at: drive.appendingPathComponent("Folder/Nested"), withIntermediateDirectories: true)
        try manager.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let target = drive.appendingPathComponent("Folder/Nested/Example.txt")
        try Data("Synthetic local content".utf8).write(to: target)
        let suite = "com.wky.LocalDiskWorkspaceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = DownloaderModel.finderWorkspaceFixture(defaults: defaults)
        let hub = CloudDriveHub(pikpak: account, defaults: defaults, restoreConnections: false,
                               photosAccess: .init(status: { .notDetermined }, request: { .denied }, provider: { PhotosDriveProvider() }), localRootURL: drive)
        defer { hub.close() }
        try await wait { !hub.local.isLoading }
        precondition(hub.local.isConnected && hub.local.provider?.kind == .local)
        precondition(hub.local.items.map(\.name) == ["Folder"])
        precondition(Set(CloudDriveKind.allCases) == [.pikpak, .icloud, .photos, .local])
        for kind in CloudDriveKind.allCases {
            hub.pikpakNavigation.showImmediately(3)
            hub.nativeDrive(for: kind)?.section = 3
            hub.open(kind)
            precondition(hub.selected == kind && hub.pikpakNavigation.section == 0)
            precondition(hub.nativeDrive(for: kind)?.section ?? 0 == 0)
        }
        precondition(hub.local.similarity.presentationHost === account.fileSimilarity)
        account.fileSimilarity.selectDrive("local")
        precondition(account.fileSimilarity.activeCoordinator === hub.local.similarity)
        precondition(account.fileSimilarity.activeModel.canStart)
        account.fileSimilarity.selectDrive("icloud")
        precondition(account.fileSimilarity.activeModel.error?.contains("Connect iCloud Drive") == true)
        print("PASS Local Disk is connected, all four drive entries open Browser, and scan sources share one window host")

        let provider = hub.local.provider!
        do {
            _ = try await provider.list(.init(id: other.absoluteString, title: "Outside", url: other), offset: 0, search: "")
            preconditionFailure("A sibling path escaped the selected Local Disk root")
        } catch { }
        let link = drive.appendingPathComponent("Escape")
        try manager.createSymbolicLink(at: link, withDestinationURL: other)
        do {
            _ = try await provider.list(.init(id: link.absoluteString, title: "Escape", url: link), offset: 0, search: "")
            preconditionFailure("A symlink escaped the selected Local Disk root")
        } catch { }
        print("PASS Local Disk rejects sibling-prefix and symlink escapes from its selected folder")

        let file = SimilarityFile(id: "synthetic-result", name: target.lastPathComponent, path: target.path, bytes: 23,
                                  family: "text", localPath: target.path, cloudId: nil, ancestors: [])
        hub.open(.photos)
        hub.local.similarity.revealInBrowser?(.local, file)
        try await wait { !hub.local.isLoading }
        precondition(hub.selected == .local && hub.local.location.url == target.deletingLastPathComponent())
        precondition(hub.local.selectedItems.first?.url?.resolvingSymlinksInPath().path == target.resolvingSymlinksInPath().path,
                     "Selection \(hub.local.selection); rows \(hub.local.visibleRows.map { ($0.item.id, $0.item.url?.path ?? "") }); target \(target.absoluteString); error \(hub.local.error ?? "none")")
        precondition(hub.local.history.map(\.title) == ["Drive", "Folder", "Nested"])
        print("PASS Show in Folder switches to Local Disk, opens the containing folder and selects the file")

        let outsideFile = other.appendingPathComponent("Subfolder/Chosen.txt")
        try manager.createDirectory(at: outsideFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Chosen folder content".utf8).write(to: outsideFile)
        try Data("Ignored".utf8).write(to: other.appendingPathComponent(".gitignore"))
        let browserLocation = hub.local.location, browserSelection = hub.local.selection
        hub.local.useSimilarityFolder(other)
        precondition(hub.local.similarity.chooseFolderScope != nil && hub.photos.similarity.chooseFolderScope != nil
            && hub.icloud.similarity.chooseFolderScope != nil, "Every drive must offer a direct scope picker")
        precondition(hub.local.similarity.local.externalScopeNames == [other.path])
        precondition(hub.local.location == browserLocation && hub.local.selection == browserSelection)
        precondition(hub.local.provider?.root.url?.path == drive.path && !hub.local.similarity.local.isRunning)
        hub.local.useSimilarityFolder(nil)
        precondition(hub.local.similarity.local.externalScopeNames == [other.path])
        hub.local.useSimilarityFolder(outsideFile)
        precondition(hub.local.similarity.local.error != nil && hub.local.similarity.local.externalScopeNames == [other.path])
        hub.local.useSimilarityFolder(other)
        let sources = try await hub.local.similarity.local.inventoryExternalSources!()
        precondition(sources.count == 1 && sources[0].localPath == outsideFile.path)
        precondition(hub.local.location == browserLocation && hub.local.provider?.root.url?.path == drive.path)
        print("PASS direct folder choice includes descendants, ignores dotfiles, preserves Browser and survives cancelled or invalid choices")

        let chosenFile = SimilarityFile(id: sources[0].id, name: sources[0].name, path: sources[0].path,
            bytes: sources[0].size, family: "text", localPath: sources[0].localPath, cloudId: nil, ancestors: [])
        let preview = try await hub.local.similarity.preparePreview!(chosenFile, directory.appendingPathComponent("Preview"))
        precondition(preview == outsideFile)
        // Preparing the next scope must not break previews of existing results.
        hub.local.findSimilar([], presentWindow: false)
        let retainedPreview = try await hub.local.similarity.preparePreview!(chosenFile, directory.appendingPathComponent("Preview"))
        precondition(retainedPreview == outsideFile)
        hub.local.similarity.revealInBrowser?(.local, chosenFile)
        try await wait { !hub.local.isLoading }
        precondition(hub.local.provider?.root.url?.path == other.path && hub.local.location.url == outsideFile.deletingLastPathComponent())
        precondition(hub.local.selectedItems.first?.url == outsideFile)
        let unrelated = SimilarityFile(id: "unrelated", name: target.lastPathComponent, path: target.path,
            bytes: 23, family: "text", localPath: target.path, cloudId: nil, ancestors: [])
        hub.local.revealSimilarityFile(unrelated)
        precondition(hub.local.error != nil && hub.local.provider?.root.url?.path == other.path)
        hub.local.similarity.local.clearSession()
        precondition(!hub.local.similarity.local.canStart && hub.local.similarity.local.inventoryExternalSources == nil)
        // Show in Folder made this the current Browser root. Clearing the scan
        // releases its scope while ordinary previews from that root remain valid.
        let browserPreview = try await hub.local.similarity.preparePreview!(chosenFile, directory.appendingPathComponent("Preview"))
        precondition(browserPreview == outsideFile)
        print("PASS chosen-folder results preview and reveal outside Browser's old root; Clear releases scan state and current Browser originals remain available")

        // Folder choice also works before connecting Browser and keeps exact mode.
        let standalone = NativeDriveModel(kind: .local, temporaryRoot: directory.appendingPathComponent("Standalone"))
        standalone.similarity.duplicatesOnly = true
        standalone.useSimilarityFolder(other)
        precondition(!standalone.isConnected && standalone.similarity.local.canStart)
        precondition(standalone.similarity.local.externalDuplicatesOnly && standalone.similarity.local.prepareExternalScope != nil)
        let exactScope = try await standalone.similarity.local.prepareExternalScope!()
        precondition(exactScope.map(\.path) == [other.path])
        standalone.close()
        print("PASS disconnected Local Disk can choose a scan folder; duplicate-only scope stays duplicate-only")

        let cloudFile = SimilarityFile(id: "cloud-result", name: "Design.txt", path: "/Projects/Drafts/Design.txt", bytes: 24_576,
            family: "text", localPath: nil, cloudId: "Design.txt", ancestors: [.init(id: "Projects", name: "Projects"), .init(id: "Drafts", name: "Drafts")])
        hub.pikpak.fileSimilarity.revealInBrowser?(.cloud, cloudFile)
        try await wait { account.selectedBrowserItem?.id == "Design.txt" && account.browserStack.last?.id == "Drafts" }
        precondition(hub.selected == .pikpak && account.browserItems.map(\.id) == ["Design.txt"])
        print("PASS Show in Folder opens the real PikPak parent folder and selects the file")

        hub.connectLocalFolder(drive, remember: false)
        try await wait { !hub.local.isLoading }
        let before = hub.local.provider?.root.url
        hub.connectLocalFolder(other, remember: false)
        try await wait { !hub.local.isLoading }
        precondition(before != hub.local.provider?.root.url && hub.local.provider?.root.url?.resolvingSymlinksInPath().path == other.resolvingSymlinksInPath().path)
        let child = try await hub.local.provider!.createContainer("Destination", in: hub.local.location)
        precondition(child != nil && manager.fileExists(atPath: other.appendingPathComponent("Destination").path))
        print("PASS Local Disk can choose another folder/volume and create folders with the shared provider")
    }
}

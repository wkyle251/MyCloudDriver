import AppKit
import AVFoundation
import Foundation
import Photos

/// Uses only a newly created disk image and synthetic files. Never touches or
/// ejects a user's existing disk, and never starts a cloud upload.
@main @MainActor struct ExternalDiskTests {
    static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(condition(), "Timed out waiting for disk availability")
    }
    static func disk(_ arguments: [String]) throws {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments; process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CloudDriveError.message(String(decoding: data, as: UTF8.self))
        }
    }
    static func rejects(_ action: () async throws -> Void) async {
        do { try await action(); preconditionFailure("Unavailable disk operation unexpectedly succeeded") }
        catch { }
    }
    static func main() async throws {
        setbuf(stdout, nil)
        let manager = FileManager.default
        let root = manager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("ExternalDiskTests-\(UUID().uuidString)")
        let mount = root.appendingPathComponent("External Disk"), image = root.appendingPathComponent("Synthetic.dmg")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        var mounted = false
        defer {
            if mounted { try? disk(["detach", mount.path, "-force"]) }
            try? manager.removeItem(at: root)
        }
        try disk(["create", "-size", "64m", "-fs", "HFS+", "-volname", "MyCloudDriver Test Disk", image.path])
        try disk(["attach", image.path, "-nobrowse", "-mountpoint", mount.path]); mounted = true
        let folder = mount.appendingPathComponent("Source Folder")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = folder.appendingPathComponent("Example with spaces.txt")
        let contents = Data("Synthetic external disk original\n".utf8)
        try contents.write(to: source)
        let provider = ICloudDriveProvider(rootURL: folder, kind: .local)
        let volume = LocalFileAccess.volumeID(folder)
        precondition(volume != nil && volume != LocalFileAccess.volumeID(root), "Fixture must be a separate mounted volume")
        let item = try ICloudDriveProvider.item(source)
        let prepared = try await provider.materialize(item, directory: root.appendingPathComponent("Unused staging"), progress: { _ in })
        precondition(prepared == source && !manager.fileExists(atPath: root.appendingPathComponent("Unused staging").path))
        let urls = try provider.uploadSources([item])
        precondition(urls == [source])
        var batch = SavedUploadBatch(id: UUID(), sources: [source.path], destination: .root, workers: 4, createdAt: Date(),
            totalFiles: 3, completedFiles: 1, totalBytes: 90, completedBytes: 30,
            sourceVolumes: try LocalFileAccess.validateUploadSources(urls), sourceBookmarks: LocalFileAccess.uploadBookmarks(urls))
        let encoded = try JSONEncoder().encode(batch)
        let decoded = try JSONDecoder().decode(SavedUploadBatch.self, from: encoded)
        precondition(decoded == batch)
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "sourceVolumes"); legacy.removeValue(forKey: "sourceBookmarks")
        let old = try JSONDecoder().decode(SavedUploadBatch.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(old.sourceVolumes == nil && old.sourceBookmarks == nil && old.completedBytes == 30)
        #if BROWSER_DROP_TESTS
        batch = try DownloaderModel.testExternalDiskUploadSources(urls, available: true, saved: batch)
        #endif
        print("PASS mounted disk preview/upload sources and backward-compatible saved volume identity")

        let suite = "MyCloudDriver.ExternalDiskTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = DownloaderModel.finderWorkspaceFixture(defaults: defaults)
        let photos = PhotosAccessClient(status: { .notDetermined }, request: { .denied }, provider: { PhotosDriveProvider() })
        let hub = CloudDriveHub(pikpak: account, defaults: defaults, restoreConnections: false, photosAccess: photos, localRootURL: root)
        defer { hub.close() }
        hub.connectLocalFolder(folder)
        try await wait { !hub.local.isLoading }
        precondition(hub.local.isConnected && hub.local.items.count == 1 && hub.local.onSendToPikPak != nil)
        var handedOff: [URL] = []
        hub.local.onSendToPikPak = { handedOff = $0 }
        hub.local.sendToPikPak([item])
        precondition(handedOff == urls)
        hub.connectLocalFolder(root.appendingPathComponent("Missing Folder"))
        try await wait { !hub.local.isLoading }
        precondition(hub.local.provider?.root.url?.path == folder.path && hub.connectionError != nil,
                     "Invalid folder must preserve the selected disk: \(hub.local.provider?.root.url?.path ?? "nil"), \(hub.connectionError ?? "no error")")
        let output = root.appendingPathComponent("Export")
        try manager.createDirectory(at: output, withIntermediateDirectories: true)
        hub.local.export([item], to: output)
        try await wait { !hub.local.isBusy }
        let exported = try Data(contentsOf: output.appendingPathComponent(item.name))
        precondition(exported == contents && hub.local.activity.records.last?.state == "Completed")
        // Exercise the same direct-file media preparation used by video/audio.
        hub.local.mediaPreview.prepare(item, provider: provider)
        try await wait { hub.local.mediaPreview.ready }
        let asset = hub.local.mediaPreview.playback.player?.currentItem?.asset as? AVURLAsset
        precondition(asset?.url == source)
        print("PASS Local Disk upload handoff, invalid connection preservation, direct preview and export contents")

        try disk(["detach", mount.path, "-force"]); mounted = false
        try await wait { !hub.local.isConnected && !hub.local.mediaPreview.ready }
        precondition(hub.local.items.isEmpty && hub.local.selection.isEmpty && hub.local.availabilityMessage != nil)
        handedOff = []; hub.local.sendToPikPak([item]); precondition(handedOff.isEmpty)
        await rejects { _ = try await provider.materialize(item, directory: output, progress: { _ in }) }
        await rejects { _ = try LocalFileAccess.validateUploadSources(urls, volumes: batch.sourceVolumes!) }
        #if BROWSER_DROP_TESTS
        _ = try DownloaderModel.testExternalDiskUploadSources(urls, available: false, saved: batch)
        #endif
        let restored = CloudDriveHub(pikpak: DownloaderModel.finderWorkspaceFixture(defaults: defaults), defaults: defaults,
            photosAccess: photos)
        defer { restored.close() }
        try await wait { !restored.local.isLoading }
        precondition(!restored.local.isConnected && restored.local.provider?.root.url?.path == folder.path,
                     "Restart must retain the unavailable external folder instead of switching to Home")
        precondition(!manager.fileExists(atPath: source.path), "Restoring a bookmark must not mount its disk")
        print("PASS eject clears preview, blocks uploads and restores an offline saved disk without mounting it")

        try disk(["attach", image.path, "-readonly", "-nobrowse", "-mountpoint", mount.path]); mounted = true
        try await wait { hub.local.isConnected && restored.local.isConnected && !hub.local.isLoading }
        precondition(LocalFileAccess.volumeID(folder) == volume)
        _ = try LocalFileAccess.validateUploadSources(urls, volumes: batch.sourceVolumes!)
        let readOnlyPreview = try await provider.materialize(item, directory: output, progress: { _ in })
        precondition(readOnlyPreview == source)
        await rejects { try LocalFileAccess.validate(folder, directory: true, writing: true) }
        await rejects { try ICloudDriveProvider.copy(source, to: folder.appendingPathComponent("Rejected.txt"), progress: { _ in }) }
        #if BROWSER_DROP_TESTS
        _ = try DownloaderModel.testExternalDiskUploadSources(urls, available: true, saved: batch)
        #endif
        let readOnlyCopy = output.appendingPathComponent("Read-only source.txt")
        try ICloudDriveProvider.copy(source, to: readOnlyCopy, progress: { _ in })
        let original = try Data(contentsOf: source), copied = try Data(contentsOf: readOnlyCopy)
        precondition(original == contents && copied == contents)
        hub.local.mediaPreview.clear()
        print("PASS same disk remounts automatically; read-only media supports preview/upload/export but rejects writes")

        let changing = root.appendingPathComponent("Changing.bin"), incomplete = output.appendingPathComponent("Incomplete.bin")
        try Data(repeating: 7, count: 3 * 1024 * 1024).write(to: changing)
        await rejects {
            try ICloudDriveProvider.copy(changing, to: incomplete, progress: { _ in
                if let file = try? FileHandle(forWritingTo: changing) { try? file.truncate(atOffset: 0); try? file.close() }
            })
        }
        precondition(!manager.fileExists(atPath: incomplete.path) && manager.fileExists(atPath: changing.path))
        await rejects {
            try ICloudDriveProvider.copy(source, to: output.appendingPathComponent("Wrong disk.txt"), progress: { _ in }, destinationVolumeID: "different-volume")
        }
        print("PASS truncated export is removed, originals remain, and a replaced destination disk is rejected")
    }
}

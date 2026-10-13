import AppKit
import Foundation

/// Deletes only files created by this test. Existing disks are never listed or
/// ejected. The optional network argument gets its own uniquely named folder.
@main @MainActor struct NativeDiskDeletionTests {
    static let contents = Data("MyCloudDriver disposable deletion test\n".utf8)

    static func rejects(_ action: () async throws -> Void) async throws -> Error {
        do { try await action() }
        catch { return error }
        throw CloudDriveError.message("An operation that should have been rejected succeeded.")
    }

    static func disk(_ arguments: [String]) throws {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments
        process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CloudDriveError.message(String(decoding: data, as: UTF8.self))
        }
    }

    static func assertContents(_ file: URL) throws {
        let actual = try Data(contentsOf: file)
        precondition(actual == contents, "Generated file contents changed.")
    }

    static func roundTrip(_ provider: ICloudDriveProvider, file: URL) async throws {
        let fm = FileManager.default
        let item = try ICloudDriveProvider.item(file)
        guard let undo = try await provider.delete([item], progress: { _ in }) else {
            throw CloudDriveError.message("A successful Trash operation must return Undo.")
        }
        precondition(!fm.fileExists(atPath: file.path))
        let redo = try await undo.apply()
        try assertContents(file)
        let restore = try await redo.apply()
        precondition(!fm.fileExists(atPath: file.path))
        _ = try await restore.apply()
        try assertContents(file)
    }

    static func externalDisk(_ root: URL) async throws {
        let fm = FileManager.default
        let image = root.appendingPathComponent("Disposable.dmg", isDirectory: false)
        let mount = root.appendingPathComponent("Disposable Mount", isDirectory: true)
        var mounted = false
        defer { if mounted { try? disk(["detach", mount.path, "-force"]) } }
        try disk(["create", "-size", "64m", "-fs", "HFS+", "-volname", "MyCloudDriver Deletion Test", image.path])
        try disk(["attach", image.path, "-nobrowse", "-mountpoint", mount.path]); mounted = true
        let folder = mount.appendingPathComponent("Generated Files", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = folder.appendingPathComponent("Disposable.txt", isDirectory: false)
        try contents.write(to: file)
        // Disk images have unknown internal/external flags. Explicitly choose
        // this disposable mounted volume as Trash storage to exercise the app.
        let provider = ICloudDriveProvider(rootURL: folder, kind: .local, diskTrashRootURL: mount)
        precondition(provider.diskTrash != nil && provider.volumeID != nil && provider.volumeID != LocalFileAccess.volumeID(root))
        print("CHECK external volume: Trash, Undo and Redo")
        try await roundTrip(provider, file: file)
        print("PASS external volume: Trash, Undo and Redo preserve generated file contents")

        let child = folder.appendingPathComponent("Parent/Child.txt", isDirectory: false)
        try fm.createDirectory(at: child.deletingLastPathComponent(), withIntermediateDirectories: false)
        try contents.write(to: child)
        let model = NativeDriveModel(kind: .local)
        let parentItem = try ICloudDriveProvider.item(child.deletingLastPathComponent())
        let childItem = try ICloudDriveProvider.item(child)
        let selection = model.operationItems([childItem, parentItem, childItem])
        precondition(selection.map(\.id) == [parentItem.id])
        let undoFolder = try await provider.delete(selection, progress: { _ in })!
        precondition(!fm.fileExists(atPath: child.path))
        _ = try await undoFolder.apply()
        try assertContents(child)
        model.close()
        print("PASS expanded parent/child selection deletes once and Undo restores the complete folder")

        _ = try await rejects { _ = try await provider.delete([ICloudDriveProvider.item(folder)], progress: { _ in }) }
        let missing = folder.appendingPathComponent("Missing.txt", isDirectory: false)
        let missingItem = CloudDriveItem(id: missing.absoluteString, name: missing.lastPathComponent, isFolder: false, url: missing)
        _ = try await rejects { _ = try await provider.delete([ICloudDriveProvider.item(file), missingItem], progress: { _ in }) }
        try assertContents(file)
        print("PASS connected root is protected and a failed batch restores its earlier generated file")

        try disk(["detach", mount.path, "-force"]); mounted = false
        _ = try await rejects { _ = try await provider.delete([childItem], progress: { _ in }) }
        try disk(["attach", image.path, "-readonly", "-nobrowse", "-mountpoint", mount.path]); mounted = true
        _ = try await rejects { _ = try await provider.delete([ICloudDriveProvider.item(file)], progress: { _ in }) }
        try assertContents(file)
        print("PASS disconnected and read-only volumes reject deletion without changing the generated file")
    }

    static func networkDisk(_ mount: URL) async throws {
        let fm = FileManager.default
        let values = try mount.resourceValues(forKeys: [.isVolumeKey, .volumeIsLocalKey, .volumeIsReadOnlyKey])
        guard values.isVolume == true, values.volumeIsLocal == false, values.volumeIsReadOnly != true else {
            throw CloudDriveError.message("The test requires an already-mounted writable network share.")
        }
        let folder = mount.appendingPathComponent(".MyCloudDriver-Deletion-Test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Disposable.txt", isDirectory: false)
        try contents.write(to: file)
        let automatic = ICloudDriveProvider(rootURL: folder, kind: .local)
        precondition(automatic.diskTrash?.volumeRoot.path == mount.standardizedFileURL.path,
                     "Network connections automatically select on-disk Trash")
        let provider = ICloudDriveProvider(rootURL: folder, kind: .local, diskTrashRootURL: folder)
        precondition(provider.diskTrash != nil)
        print("CHECK mounted network share: app Trash using one generated file")
        try await roundTrip(provider, file: file)
        let remaining = try await provider.diskTrash!.list()
        precondition(remaining.isEmpty)
        print("PASS network share: on-disk Trash, Undo and Redo preserve generated file contents")
    }

    static func main() async throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("NativeDiskDeletion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        try await externalDisk(root)
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--network-root" {
            try await networkDisk(URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
        } else {
            precondition(CommandLine.arguments.count == 1, "Usage: NativeDiskDeletionTests [--network-root /Volumes/Share]")
            print("SKIP live network check; pass an already-mounted share explicitly to test generated files there")
        }
    }
}

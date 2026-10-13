import AppKit
import Foundation
import CryptoKit
import Darwin

@main struct TransferControlTests {
    @MainActor static func main() async throws {
        try DownloaderModel.testDownloadRetries()
        try DownloaderModel.testTransferControls()
        try DownloaderModel.testRestoredDownloadControlsStayCheapForLargeCancelledFolders()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MyCloudDriver-TransferControl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let locks = root.appendingPathComponent("locks"), tree = root.appendingPathComponent("requested")
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        func claimed(_ original: URL, owner: String, fileID: String) throws -> URL {
            let output = original.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(original.lastPathComponent)
            let key = SHA256.hash(data: Data(output.path.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
            let record = locks.appendingPathComponent(key)
            try JSONEncoder().encode(["owner": owner, "file_id": fileID, "output_path": output.path]).write(to: record)
            try Data("partial".utf8).write(to: output.appendingPathExtension("part"))
            try Data("pieces".utf8).write(to: URL(fileURLWithPath: output.path + ".part.ranges.data"))
            try Data("coverage".utf8).write(to: URL(fileURLWithPath: output.path + ".part.ranges.json"))
            return record
        }
        let owned = tree.appendingPathComponent("owned.bin"), active = tree.appendingPathComponent("active.bin")
        let other = tree.appendingPathComponent("other.bin"), outside = root.appendingPathComponent("outside.bin")
        _ = try claimed(owned, owner: "session-A", fileID: "owned")
        let resumeMetadata = URL(fileURLWithPath: owned.path + ".part.resume.json")
        try Data("validator".utf8).write(to: resumeMetadata)
        try FileManager.default.removeItem(at: owned.appendingPathExtension("part"))
        _ = try claimed(other, owner: "session-B", fileID: "other")
        _ = try claimed(outside, owner: "session-A", fileID: "outside")
        let activeLock = try claimed(active, owner: "session-A", fileID: "active")
        let descriptor = Darwin.open(activeLock.path, O_RDWR)
        precondition(descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        try Data("completed sentinel".utf8).write(to: owned)
        let unrelated = tree.appendingPathComponent("unrelated.bin.part")
        try Data("unrelated".utf8).write(to: unrelated)
        try TransferPartialCleanup.removeOwned(in: tree, owner: "session-A", ignoringActiveWriters: true, locksDirectory: locks)
        precondition(!FileManager.default.fileExists(atPath: owned.appendingPathExtension("part").path))
        precondition(!FileManager.default.fileExists(atPath: resumeMetadata.path))
        for suffix in [".part.ranges.data", ".part.ranges.json"] {
            precondition(!FileManager.default.fileExists(atPath: owned.path + suffix), "Cleanup must find ranges when no legacy .part exists")
            precondition(FileManager.default.fileExists(atPath: active.path + suffix))
            precondition(FileManager.default.fileExists(atPath: other.path + suffix))
        }
        precondition(FileManager.default.fileExists(atPath: owned.path) && FileManager.default.fileExists(atPath: active.appendingPathExtension("part").path))
        precondition(FileManager.default.fileExists(atPath: unrelated.path) && FileManager.default.fileExists(atPath: other.appendingPathExtension("part").path) && FileManager.default.fileExists(atPath: outside.appendingPathExtension("part").path))
        flock(descriptor, LOCK_UN); Darwin.close(descriptor)
        try TransferPartialCleanup.removeOwned(in: tree, owner: "session-A", locksDirectory: locks)
        precondition(!FileManager.default.fileExists(atPath: active.appendingPathExtension("part").path))
        precondition(!FileManager.default.fileExists(atPath: active.path + ".part.ranges.data"))
        print("PASS early folder cancel: owned partial manifest cleanup; busy writers, other sessions, outside paths, unrelated parts and completed files preserved")
        try TransferPartialCleanup.remove(other.appendingPathExtension("part"), owner: "shared-session", fileID: "wrong-file", locksDirectory: locks, importedOwners: ["session-B"])
        precondition(FileManager.default.fileExists(atPath: other.appendingPathExtension("part").path), "Imported ownership still requires the exact file ID")
        try TransferPartialCleanup.removeOwned(in: tree, owner: "shared-session", locksDirectory: locks, importedOwners: ["session-B"])
        precondition(!FileManager.default.fileExists(atPath: other.appendingPathExtension("part").path))
        precondition(!FileManager.default.fileExists(atPath: other.path + ".part.ranges.data"))
        precondition(FileManager.default.fileExists(atPath: unrelated.path) && FileManager.default.fileExists(atPath: outside.appendingPathExtension("part").path))
        print("PASS imported partial cleanup: previous session owners are accepted only for the imported account and exact destination")

        let finalizing = tree.appendingPathComponent("finalizing.bin")
        _ = try claimed(finalizing, owner: "session-A", fileID: "finalizing")
        let publication = URL(fileURLWithPath: finalizing.path + ".part.publication.json")
        try Data("saved publication fixture".utf8).write(to: publication)
        try Data("incomplete owned copy".utf8).write(to: finalizing)
        do {
            try TransferPartialCleanup.remove(finalizing.appendingPathExtension("part"), owner:"session-A", fileID:"finalizing", locksDirectory:locks)
            preconditionFailure("Native cleanup must defer to the publication journal")
        } catch let error as NSError { precondition(error.domain == "MyCloudDriver.Transfer" && error.code == 2) }
        precondition(FileManager.default.fileExists(atPath: finalizing.path + ".part"))
        precondition(FileManager.default.fileExists(atPath: publication.path))
        let finalizingBytes = try Data(contentsOf: finalizing)
        precondition(finalizingBytes == Data("incomplete owned copy".utf8))
        try FileManager.default.removeItem(at: publication)
        try TransferPartialCleanup.remove(finalizing.appendingPathExtension("part"), owner:"session-A", fileID:"finalizing", locksDirectory:locks)
        precondition(!FileManager.default.fileExists(atPath: finalizing.path + ".part"))
        precondition(FileManager.default.fileExists(atPath: finalizing.path))
        print("PASS interrupted publication cleanup: original and owned-copy journal remain recoverable until the helper reconciles them")

        let source = root.appendingPathComponent("original.bin"), destination = root.appendingPathComponent("copy.bin")
        try Data(repeating: 0x5a, count: 8 * 1024 * 1024).write(to: source)
        let gate = NativeTransferControl()
        let copy = Task {
            try await NativeTransferControl.$current.withValue(gate) {
                try await CloudDriveFiles.detached {
                    try ICloudDriveProvider.copy(source, to: destination) { progress in
                        if progress.bytes > 0 { gate.pause() }
                    }
                }
            }
        }
        for _ in 0..<200 {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: destination.path),
               (attributes[.size] as? NSNumber)?.uint64Value ?? 0 > 0 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        precondition(FileManager.default.fileExists(atPath: destination.path), "copy should reach its first chunk")
        let pausedSize = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as! NSNumber).uint64Value
        try await Task.sleep(nanoseconds: 150_000_000)
        let stillSize = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as! NSNumber).uint64Value
        precondition(pausedSize == stillSize && stillSize < 8 * 1024 * 1024, "paused copy must not advance")
        gate.cancel()
        do { try await copy.value; preconditionFailure("cancel must stop copy") }
        catch is CancellationError {}
        precondition(!FileManager.default.fileExists(atPath: destination.path), "cancel must remove its incomplete destination after closing writer")
        let originalData = try Data(contentsOf: source)
        precondition(originalData.count == 8 * 1024 * 1024)
        let resumeGate = NativeTransferControl(); resumeGate.pause()
        let waiting = Task { try await resumeGate.wait(); return 42 }
        try await Task.sleep(nanoseconds: 120_000_000); resumeGate.resume()
        let resumed = try await waiting.value
        precondition(resumed == 42)
        print("PASS native pause/resume/cancel: main actor remains responsive, paused copy does not advance, cancel removes only incomplete destination")
    }
}

import AppKit
import Darwin
import Foundation

/// Synthetic Photos streaming: exercises production pause/provider/FIFO paths
/// without accessing a Photos library or writing any original bytes to disk.
@main struct SimilarityRAMPauseTests {
    @MainActor static func until(_ condition: () -> Bool, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(condition(), "Timed out at line \(line)")
    }
    @MainActor static func main() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SimilarityRAMPause-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = FileSimilarityCoordinator(activity: FinderTaskActivityStore())
        owner.source = .local
        owner.configuration = { _ in .init(executable: resources.appendingPathComponent("pikpak"),
            models: resources.appendingPathComponent("FileTwinModels"), worker: resources.appendingPathComponent("filetwin-worker"),
            dataDirectory: root.appendingPathComponent("data"), temporaryDirectory: root.appendingPathComponent("temp"), environment: [:]) }
        let scan = owner.local
        scan.externalTitle = "Apple Photos"; scan.externalScopeNames = ["Synthetic album"]; scan.families = ["text"]
        let content = Data(String(repeating: "A garden with flowers, trees and green grass. ", count: 50_000).utf8)
        var starts = 0, written = 0
        var pipeURL: URL?
        scan.streamExternalSources = { emit in
            try await emit(.init(id: "asset:retained", name: "original.txt", path: "Photos/original.txt", size: UInt64(content.count), localPath: nil))
        }
        scan.resolveExternalSource = { _,_,_ in preconditionFailure("Original must use RAM") }
        scan.resolveExternalMemorySource = { _, pipe, capacity, _ in
            precondition(capacity >= content.count)
            starts += 1; pipeURL = pipe
            let handle = try SimilarityMemoryPipe.open(pipe)
            defer { try? handle.close() }
            while written < content.count {
                try Task.checkCancellation()
                let size = min(8192, content.count - written)
                let count = content.withUnsafeBytes { Darwin.write(handle.fileDescriptor, $0.baseAddress!.advanced(by: written), size) }
                if count > 0 { written += count }
                else { precondition(errno == EAGAIN || errno == EINTR, "Unexpected FIFO error") }
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            return pipe
        }
        owner.start(scan)
        try await until { scan.progress.originalMemoryBytes > 128 << 10 && written < content.count }
        let pid = scan.processIdentifier
        scan.pause(); try await until { scan.isPaused && !scan.isRunning }
        precondition(scan.retainsOriginalsInRAM && scan.processIdentifier == pid)
        try await Task.sleep(nanoseconds: 200_000_000) // Fill the remaining kernel pipe window.
        let held = scan.progress.originalMemoryBytes, pausedWritten = written
        precondition(held > 0 && pausedWritten < content.count)
        try await Task.sleep(nanoseconds: 400_000_000)
        precondition(written == pausedWritten && scan.progress.originalMemoryBytes == held, "Paused provider kept draining or lost its buffer")
        var info = stat()
        precondition(lstat(pipeURL!.path, &info) == 0 && info.st_mode & S_IFMT == S_IFIFO && info.st_size == 0)
        var resourcesEdit = SimilarityResourceSettings(limits: scan.savedSession!.resources)
        resourcesEdit.usesAutomatic = false
        resourcesEdit.memoryMiB = 1024; resourcesEdit.downloadMemoryMiB = 64
        try scan.updatePausedResources(resourcesEdit, sessionID: scan.savedSession!.id)
        precondition(scan.savedSession?.resources.automaticMemory == true)
        try await Task.sleep(nanoseconds: 200_000_000)
        precondition(scan.progress.originalMemoryLimit != 64 << 20, "Legacy manual limits must be ignored")
        precondition(scan.isPaused && scan.processIdentifier == pid && written == pausedWritten,
            "Automatic memory migration must retain the same paused provider and helper")
        owner.resume(scan)
        precondition(scan.processIdentifier == pid)
        try await until { !scan.isRunning }
        precondition(!scan.isPaused && scan.report?.analysedFiles == 1, scan.error ?? "Missing result")
        precondition(starts == 1 && written == content.count, "Pause restarted the provider")
        precondition(!FileManager.default.fileExists(atPath: pipeURL!.path))
        scan.clearSession()
        print("PASS Photos partial FIFO/RAM bytes survive pause, automatic memory and same-helper resume; provider starts once; no original file created")
    }
}

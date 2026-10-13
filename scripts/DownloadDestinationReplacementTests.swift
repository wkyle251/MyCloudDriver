import Foundation

/// A download disk that was backed up and reformatted. Uses newly created disk images mounted at the
/// same path, first ExFAT then APFS, with generated files. Never touches a real disk.
@main struct DownloadDestinationReplacementTests {
    static func hdiutil(_ arguments: [String]) throws {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments; process.standardOutput = output; process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CloudDriveError.message(String(decoding: data, as: UTF8.self)) }
    }
    static func write(_ path: String, in directory: URL) throws {
        let url = directory.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("generated".utf8).write(to: url)
    }

    static func main() throws {
        setbuf(stdout, nil)
        let manager = FileManager.default
        let root = manager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("DownloadReplacement-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        let mount = root.appendingPathComponent("Downloads"), backup = root.appendingPathComponent("Backup")
        var mounted = false
        defer { if mounted { try? hdiutil(["detach", mount.path, "-force"]) }; try? manager.removeItem(at: root) }
        func attach(_ filesystem: String) throws {
            let image = root.appendingPathComponent("\(filesystem.filter(\.isLetter)).dmg")
            try hdiutil(["create", "-size", "64m", "-fs", filesystem, "-volname", "Downloads", image.path])
            try hdiutil(["attach", image.path, "-nobrowse", "-mountpoint", mount.path]); mounted = true
        }

        // The disk the downloads started on: ExFAT, with unfinished files.
        try attach("ExFAT")
        let folder = mount.appendingPathComponent("Videos")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let saved = try DownloadDestinationAccess.validate(folder)
        precondition(saved.volumeID != nil)
        for path in ["movie.mp4.part", "movie.mp4.part.resume.json", "Series/Season 1/episode.mkv.part.ranges.json",
                     "Series/Season 1/episode.mkv.part.ranges.data", "Other/unrelated.txt"] {
            try write(path, in: folder)
        }
        // Back everything up, then reformat the disk as APFS and restore only the unfinished files.
        try manager.copyItem(at: folder, to: backup)
        try hdiutil(["detach", mount.path, "-force"]); mounted = false
        try attach("APFS")
        precondition(!manager.fileExists(atPath: folder.path), "A reformatted disk starts empty")

        // 1. The saved identity no longer matches, and the app says so rather than claiming the disk is merely unplugged.
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            _ = try DownloadDestinationAccess.validate(folder, checkpoint: saved)
            preconditionFailure("A reformatted disk must not match the saved volume identity")
        } catch let error as DownloadDestinationReplaced {
            precondition(error.path == folder.path)
            let message = error.localizedDescription
            precondition(message.contains("reformatted") && message.contains("Use This Disk"), message)
            precondition(!message.contains("Reconnect that disk"), "Not the unplugged-disk message: \(message)")
        } catch { preconditionFailure("Expected DownloadDestinationReplaced, got \(error)") }
        print("PASS a reformatted disk at the same path is reported as replaced, with what to do about it")

        // 2. Re-validating without the old identity is how a disk is accepted: it adopts the current volume.
        let adopted = try DownloadDestinationAccess.validate(folder)
        precondition(adopted.volumeID != nil && adopted.volumeID != saved.volumeID, "The new disk has its own identity")
        _ = try DownloadDestinationAccess.validate(folder, checkpoint: adopted)
        print("PASS accepting the disk rebinds the saved identity to it, and later checks match")

        // 3. An unplugged disk is still reported as unplugged, not as replaced.
        let missing = URL(fileURLWithPath: "/Volumes/MyCloudDriver-Missing-\(UUID())/Videos")
        do { _ = try DownloadDestinationAccess.validate(missing, checkpoint: saved); preconditionFailure("A missing disk was accepted") }
        catch { precondition(!(error is DownloadDestinationReplaced), "Missing disk reported as replaced") }

        // 4. Proof that the unfinished files were restored here: this app's own progress files for the queued items.
        let file = DownloadRestoredProgress.Probe(directory: folder, name: "movie.mp4", isFolder: false)
        let series = DownloadRestoredProgress.Probe(directory: folder, name: "Series", isFolder: true)
        precondition(!DownloadRestoredProgress.found([file, series]), "A freshly formatted disk has no restored progress")
        for path in ["movie.mp4.part.resume.json"] { try write(path, in: folder) }
        precondition(DownloadRestoredProgress.found([file]), "A restored checkpoint for the queued file proves it")
        precondition(!DownloadRestoredProgress.found([.init(directory: folder, name: "other.mp4", isFolder: false)]),
                     "Another file's name is not proof")
        precondition(!DownloadRestoredProgress.found([series]), "Nothing restored under the folder yet")
        try write("Series/Season 1/episode.mkv.part.ranges.json", in: folder)
        precondition(DownloadRestoredProgress.found([series]), "A parallel-range checkpoint nested in a queued folder proves it")
        print("PASS only this app's own restored progress files for the queued items count as proof")

        // 5. A partial staging file alone also shows the queued file was put back; unrelated files do not.
        try manager.removeItem(at: folder.appendingPathComponent("movie.mp4.part.resume.json"))
        precondition(!DownloadRestoredProgress.found([file]))
        try write("movie.mp4.part", in: folder)
        precondition(DownloadRestoredProgress.found([file]))
        try write("Other/unrelated.txt", in: folder)
        precondition(!DownloadRestoredProgress.found([.init(directory: folder.appendingPathComponent("Other"), name: "unrelated.txt", isFolder: false)]),
                     "A finished file is not progress")
        print("PASS a restored staging file counts; a finished file does not")

        // 6. A huge destination cannot stall the check: it gives up at its entry limit and falls back to asking.
        for index in 0..<60 { try write("Many/f\(index).bin", in: folder) }
        try write("Many/deep/after.mp4.part.resume.json", in: folder)
        precondition(!DownloadRestoredProgress.found([.init(directory: folder, name: "Many", isFolder: true)], limit: 20),
                     "The scan stops at its limit")
        precondition(DownloadRestoredProgress.found([.init(directory: folder, name: "Many", isFolder: true)], limit: 500))
        print("PASS the proof scan is bounded")
    }
}

import Foundation

@main struct NativeDuplicateScanTests {
    static func main() async throws {
        let manager = FileManager.default
        let directory = manager.temporaryDirectory.appendingPathComponent("NativeDuplicateScanTests-\(UUID())")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: directory) }
        let tree = directory.appendingPathComponent("Tree")
        for folder in ["A", "B", "C"] {
            try manager.createDirectory(at: tree.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let one = tree.appendingPathComponent("A/one.bin"), two = tree.appendingPathComponent("B/two.bin")
        let other = tree.appendingPathComponent("B/other.bin"), content = Data("abcdefgh".utf8)
        try content.write(to: one); try content.write(to: two)
        try Data("xxxxxxxx".utf8).write(to: other)
        try Data("unique size".utf8).write(to: tree.appendingPathComponent("C/unique.bin"))
        try content.write(to: tree.appendingPathComponent(".hidden.bin"))
        try manager.createSymbolicLink(at: tree.appendingPathComponent("linked.bin"), withDestinationURL: one)

        func scan() async throws -> (groups: [[String]], hashed: Int, files: UInt64) {
            let result = try await NativeDriveDuplicates.scanReporting([tree]) { _ in }
            precondition(result.report.status == "completed")
            return (result.report.groups.map { $0.members.map(\.name).sorted() },
                result.statistics.hashed, result.report.scannedFiles)
        }

        for _ in 0..<2 {
            let checked = try await scan()
            precondition(checked.groups == [["one.bin", "two.bin"]] && checked.hashed == 3 && checked.files == 4,
                "Every scan hashes matching-size files again; hidden files and symlinks stay excluded")
        }
        print("PASS repeated native duplicate checks read all matching-size candidates again")

        let oldModified = try other.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        try content.write(to: other)
        try manager.setAttributes([.modificationDate: oldModified], ofItemAtPath: other.path)
        let edited = try await scan()
        precondition(edited.groups == [["one.bin", "other.bin", "two.bin"]] && edited.hashed == 3,
            "Same-size edits are detected even when modification time is restored")
        try manager.removeItem(at: two)
        let removed = try await scan()
        precondition(removed.groups == [["one.bin", "other.bin"]] && removed.hashed == 2 && removed.files == 3)
        try content.write(to: tree.appendingPathComponent("new.bin"))
        let added = try await scan()
        precondition(added.groups == [["new.bin", "one.bin", "other.bin"]] && added.hashed == 3)
        print("PASS native duplicate checks detect edits, removals and additions without cached hashes")

        let scope = CrossDriveScope.object(cloudFolders: [("cloud", "/Folder")], localFolders: [tree])
        precondition(Set(scope.keys) == ["cloud_folders", "local_paths"])
        precondition((scope["local_paths"] as? [String]) == [tree.path] && JSONSerialization.isValidJSONObject(scope))
        print("PASS cross-drive scan requests carry selected folders without cache or volume metadata")
    }
}

import Foundation

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CloudDriveProgress] = []
    func add(_ value: CloudDriveProgress) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [CloudDriveProgress] { lock.lock(); defer { lock.unlock() }; return stored }
}

/// Generated folders only. Recalculate size shows what it has counted so far, and a bar over several folders.
@main struct NativeMeasureProgressTests {
    static func main() async throws {
        setbuf(stdout, nil)
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("NativeMeasureProgressTests-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        for path in ["A/Nested", "B", "C"] { try manager.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true) }
        for (path, size) in [("A/a1.bin", 1_000), ("A/a2.bin", 2_000), ("A/Nested/a3.bin", 3_000), ("B/b1.bin", 4_000), ("B/b2.bin", 5_000), ("C/c1.bin", 6_000)] {
            try Data(count: size).write(to: root.appendingPathComponent(path))
        }
        let provider = ICloudDriveProvider(rootURL: root, kind: .local)
        func item(_ name: String) throws -> CloudDriveItem { try ICloudDriveProvider.item(root.appendingPathComponent(name)) }
        let scratch = root.appendingPathComponent("scratch")

        // One folder has no total to measure against, so it shows what has been counted.
        let single = Events()
        let result = try await provider.measureFiles([try item("A")], location: provider.root, directory: scratch, progress: single.add)
        precondition(result.files == 3 && result.bytes == 6_000)
        let tallies = single.values.map(\.message).filter { $0.contains("so far") }
        precondition(!tallies.isEmpty && tallies.allSatisfy { $0.hasPrefix("Calculating Local Disk size · ") && $0.contains("file") },
                     "A running tally of files and size is shown: \(single.values.map(\.message))")
        precondition(tallies.last?.contains("3 files") == true && tallies.last?.contains("KB") == true, "The last tally has the final count: \(tallies.last ?? "")")
        precondition(single.values.allSatisfy { $0.total == 0 && $0.fraction == nil }, "One folder has no honest percentage")
        print("PASS size progress: one folder shows a running tally of files and size, with no invented percentage")

        // Several folders: a bar that advances as each one is finished.
        let several = Events()
        let all = try await provider.measureFiles([try item("A"), try item("B"), try item("C")], location: provider.root, directory: scratch, progress: several.add)
        precondition(all.files == 6 && all.bytes == 21_000)
        let steps = several.values.filter { $0.total == 3 }
        precondition(steps.count == several.values.count, "Every update reports the folder count once several are selected")
        precondition(Set(steps.map(\.completed)).isSuperset(of: [1, 2, 3]), "Each finished folder moves the bar: \(steps.map(\.completed))")
        let completed = steps.map(\.completed)
        precondition(completed == completed.sorted(), "The count of finished folders never goes backwards: \(completed)")
        precondition(steps.last?.completed == 3 && steps.last?.fraction == 1, "The bar ends full")
        precondition(steps.allSatisfy { ($0.fraction ?? -1) == Double($0.completed) / 3 }, "The bar is finished folders over selected folders")
        precondition(steps.contains { $0.message.contains("so far") }, "The tally is shown beside the bar")
        print("PASS size progress: several folders advance a bar one finished folder at a time and keep the tally")

        // A selection that overlaps itself, or holds a file, still ends at 100%.
        let mixed = Events()
        _ = try await provider.measureFiles([try item("A"), try item("A/a1.bin"), try item("A")], location: provider.root, directory: scratch, progress: mixed.add)
        precondition(mixed.values.last?.completed == 3 && mixed.values.last?.fraction == 1, "Repeated and file selections still complete the bar: \(mixed.values.map(\.completed))")
        print("PASS size progress: repeated folders and files in the selection still finish the bar")
    }
}

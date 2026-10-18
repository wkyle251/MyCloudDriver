import Foundation

private final class Events: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CloudDriveProgress] = []
    func add(_ value: CloudDriveProgress) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [CloudDriveProgress] { lock.lock(); defer { lock.unlock() }; return stored }
}

/// Generated folders and disposable disk images only. Folder scans count roots;
/// whole-disk scans use the disk's used space and estimate time from scan speed.
@main struct NativeMeasureProgressTests {
    static func rateTests() {
        let size = FolderSizeProgress(files: 1_200, bytes: 2_000_000_000, usedDiskBytes: 8_000_000_000, elapsedSeconds: 10)
        precondition(size.fraction == 0.25 && size.bytesPerSecond == 200_000_000 && size.filesPerSecond == 120)
        precondition(size.estimatedSecondsRemaining == 30)
        precondition(size.sizeSummary.contains(" / ≈ ") && size.sizeSummary.hasSuffix(" used"))
        precondition(size.speedSummary.contains("MB/s") && size.speedSummary.contains("120 files/s"))
        precondition(size.timeRemainingSummary == "Time left: ≈ 30s")
        let waiting = FolderSizeProgress(files: 0, bytes: 0, usedDiskBytes: 8_000, elapsedSeconds: 10)
        precondition(waiting.bytesPerSecond == nil && waiting.estimatedSecondsRemaining == nil)
        precondition(waiting.timeRemainingSummary == "Time left: estimating…")
        for elapsed in [0, 0.1, Double.nan, Double.infinity] {
            let early = FolderSizeProgress(files: 1, bytes: 1_000, usedDiskBytes: 8_000, elapsedSeconds: elapsed)
            precondition(early.bytesPerSecond == nil && early.filesPerSecond == nil && early.estimatedSecondsRemaining == nil)
        }
        let zero = FolderSizeProgress(files: 20, bytes: 0, usedDiskBytes: 8_000, elapsedSeconds: 1)
        precondition(zero.bytesPerSecond == 0 && zero.filesPerSecond == 20 && zero.estimatedSecondsRemaining == nil)
        let unknown = FolderSizeProgress(files: 100, bytes: 1_000, usedDiskBytes: nil, elapsedSeconds: 10)
        precondition(unknown.fraction == nil && unknown.estimatedSecondsRemaining == nil && unknown.bytesPerSecond == 100)
        precondition(unknown.sizeSummary.hasSuffix(" so far") && unknown.timeRemainingSummary.contains("unknown"))
        let over = FolderSizeProgress(files: 100, bytes: 9_000, usedDiskBytes: 8_000, elapsedSeconds: 10)
        precondition(over.fraction == 0.99 && over.estimatedSecondsRemaining == nil && over.timeRemainingSummary.contains("counting"),
                     "Logical bytes can exceed disk usage; do not promise completion before the walk ends")
        let finalizing = FolderSizeProgress(files: 100, bytes: 9_000, usedDiskBytes: 8_000, elapsedSeconds: 10, phase: .finalizing)
        precondition(finalizing.fraction == 0.99 && finalizing.estimatedSecondsRemaining == nil && finalizing.timeRemainingSummary.contains("finalizing"))
        let done = FolderSizeProgress(files: 100, bytes: 1_000, usedDiskBytes: 8_000, elapsedSeconds: 10, phase: .complete)
        precondition(done.fraction == 1 && done.estimatedSecondsRemaining == 0 && done.timeRemainingSummary == "Scan complete")
        let slower = FolderSizeProgress(files: size.files, bytes: size.bytes, usedDiskBytes: size.usedDiskBytes, elapsedSeconds: 20)
        precondition(slower.estimatedSecondsRemaining == 60, "Scan waits count toward the average and ETA")
        let huge = FolderSizeProgress(files: 1, bytes: .max, usedDiskBytes: .max, elapsedSeconds: 1)
        precondition(huge.bytesPerSecond?.isFinite == true && !huge.speedSummary.isEmpty)
        print("PASS scan speed and ETA: elapsed time, startup, unknown totals, zero-byte files, large values and estimated disk limits")
    }

    static func hdiutil(_ arguments: [String]) throws {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = arguments; process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw CloudDriveError.message(String(decoding: output, as: UTF8.self)) }
    }

    static func wholeDiskTests(in root: URL) async throws {
        let manager = FileManager.default
        for filesystem in ["APFS", "ExFAT"] {
            let mount = root.appendingPathComponent("Disk \(filesystem)"), image = root.appendingPathComponent("Synthetic-\(filesystem).dmg")
            let volumeName = String(UUID().uuidString.prefix(8))
            try hdiutil(["create", "-size", filesystem == "ExFAT" ? "128m" : "64m", "-fs", filesystem, "-volname", volumeName, image.path])
            try hdiutil(["attach", image.path, "-nobrowse", "-mountpoint", mount.path])
            defer { try? hdiutil(["detach", mount.path, "-force"]) }
            for folder in ["A", "B"] {
                let url = mount.appendingPathComponent(folder)
                try manager.createDirectory(at: url, withIntermediateDirectories: true)
                try Data(count: 1_000_000).write(to: url.appendingPathComponent("file.bin"))
            }
            try Data(count: 100_000).write(to: mount.appendingPathComponent(".hidden.bin"))
            if filesystem == "APFS" {
                try manager.createSymbolicLink(at: mount.appendingPathComponent("Alias"), withDestinationURL: mount.appendingPathComponent("A"))
            }
            let provider = ICloudDriveProvider(rootURL: mount, kind: .local)
            let scratch = root.appendingPathComponent("scratch")
            let allItems = try await provider.list(provider.root, offset: 0, search: "").items
            let rootEvents = Events(), selectedEvents = Events()
            for (selection, events) in [([], rootEvents), (allItems, selectedEvents)] {
                let total = try await provider.measureFiles(selection, location: provider.root, directory: scratch) { events.add($0) }
                precondition(total.files == 2 && total.bytes == 2_000_000, "Disk progress preserves visible-file measurement")
                precondition(events.values.allSatisfy { ($0.folderSize?.usedDiskBytes ?? 0) > 0 && $0.fraction != nil },
                             "Both the volume and Select All at its root use used disk space (\(filesystem))")
                precondition(events.values.last?.fraction == 1 && events.values.last?.folderSize?.isComplete == true)
                precondition(events.values.contains { $0.message.contains(" / ≈ ") && $0.message.contains(" used") })
                for event in events.values where event.folderSize?.isComplete == false {
                    let size = event.folderSize!
                    precondition(event.fraction == min(0.99, Double(event.bytes) / Double(size.usedDiskBytes!)),
                                 "Disk progress follows bytes, regardless of the completed folder count")
                }
            }
            let a = allItems.first { $0.name == "A" }!
            for (selection, location) in [([a], provider.root), ([], a.location)] {
                let partial = Events()
                _ = try await provider.measureFiles(selection, location: location, directory: scratch) { partial.add($0) }
                precondition(partial.values.allSatisfy { $0.folderSize?.usedDiskBytes == nil && $0.fraction == nil },
                             "A folder or incomplete root selection must not use the disk's total (\(filesystem))")
            }
            let cloud = ICloudDriveProvider(rootURL: mount, kind: .icloud), cloudEvents = Events()
            _ = try await cloud.measureFiles([], location: cloud.root, directory: scratch) { cloudEvents.add($0) }
            precondition(cloudEvents.values.allSatisfy { $0.folderSize?.usedDiskBytes == nil }, "iCloud does not use local disk capacity")
            print("PASS whole \(filesystem) disk and Select All use bytes/used space; partial folders and iCloud keep unknown totals")
        }
    }

    static func main() async throws {
        setbuf(stdout, nil)
        rateTests()
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
        let result = try await provider.measureFiles([try item("A")], location: provider.root, directory: scratch) { single.add($0) }
        precondition(result.files == 3 && result.bytes == 6_000)
        let tallies = single.values.map(\.message).filter { $0.contains("so far") }
        precondition(!tallies.isEmpty && tallies.allSatisfy { ($0.hasPrefix("Calculating Local Disk size · ") || $0.hasPrefix("Finalizing folder sizes · ")) && $0.contains("file") },
                     "A running tally of files and size is shown: \(single.values.map(\.message))")
        precondition(tallies.last?.contains("3 files") == true && tallies.last?.contains("KB") == true, "The last tally has the final count: \(tallies.last ?? "")")
        precondition(single.values.allSatisfy { $0.total == 0 && $0.fraction == nil }, "One folder has no honest percentage")
        precondition(single.values.last?.folderSize?.bytes == result.bytes && single.values.last?.folderSize?.files == result.files)
        print("PASS size progress: one folder shows a running tally of files and size, with no invented percentage")

        // Several folders: a bar that advances as each one is finished.
        let several = Events()
        let all = try await provider.measureFiles([try item("A"), try item("B"), try item("C")], location: provider.root, directory: scratch) { several.add($0) }
        precondition(all.files == 6 && all.bytes == 21_000)
        let steps = several.values.filter { $0.total == 3 }
        precondition(steps.count == several.values.count, "Every update reports the folder count once several are selected")
        precondition(Set(steps.map(\.completed)).isSuperset(of: [1, 2, 3]), "Each finished folder moves the bar: \(steps.map(\.completed))")
        let completed = steps.map(\.completed)
        precondition(completed == completed.sorted(), "The count of finished folders never goes backwards: \(completed)")
        precondition(steps.last?.completed == 3 && steps.last?.fraction == 1, "The bar ends full")
        precondition(steps.allSatisfy { ($0.fraction ?? -1) == ($0.folderSize?.isComplete == true ? 1 : min(0.99, Double($0.completed) / 3)) },
                     "The bar counts finished folders and reserves 100% until totals are ready")
        precondition(steps.contains { $0.folderSize?.phase == .finalizing && ($0.fraction ?? 1) < 1 && $0.message.hasPrefix("Finalizing folder sizes") },
                     "After every root is scanned, the finalizing phase is explicit and the bar is not full")
        precondition(steps.contains { $0.message.contains("so far") }, "The tally is shown beside the bar")
        print("PASS size progress: several folders advance a bar one finished folder at a time and keep the tally")

        let cancelled = Events()
        do {
            _ = try await provider.measureFiles([try item("A"), try item("B")], location: provider.root, directory: scratch) { event in
                cancelled.add(event)
                if event.folderSize?.phase == .finalizing { CloudDriveFiles.coordinationCancellation?.cancel() }
            }
            preconditionFailure("Cancellation during finalization must stop before publishing complete totals")
        } catch is CancellationError {
            precondition(cancelled.values.contains { $0.folderSize?.phase == .finalizing })
            precondition(cancelled.values.allSatisfy { $0.folderSize?.isComplete == false && ($0.fraction ?? 0) < 1 })
        }
        print("PASS finalizing folder totals can be cancelled without reporting 100%")

        // A selection that overlaps itself, or holds a file, still ends at 100%.
        let mixed = Events()
        _ = try await provider.measureFiles([try item("A"), try item("A/a1.bin"), try item("A")], location: provider.root, directory: scratch) { mixed.add($0) }
        precondition(mixed.values.last?.completed == 3 && mixed.values.last?.fraction == 1, "Repeated and file selections still complete the bar: \(mixed.values.map(\.completed))")
        print("PASS size progress: repeated folders and files in the selection still finish the bar")
        try await wholeDiskTests(in: root)
    }
}

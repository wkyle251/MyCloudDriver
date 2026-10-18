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
        let activities = await MainActor.run { TestDuplicateActivities() }

        func scan() async throws -> (groups: [[String]], hashed: Int, files: UInt64) {
            let result = try await NativeDriveDuplicates.scanReporting([tree], sleepPrevention: { activities.makeActivity() }) { _ in }
            precondition(result.report.status == "completed")
            return (result.report.groups.map { $0.members.map(\.name).sorted() },
                result.statistics.hashed, result.report.scannedFiles)
        }

        for _ in 0..<2 {
            let checked = try await scan()
            precondition(checked.groups == [["one.bin", "two.bin"]] && checked.hashed == 3 && checked.files == 4,
                "Every scan hashes matching-size files again; hidden files and symlinks stay excluded")
        }
        let initialActivities = await MainActor.run { (activities.begins, activities.ends) }
        precondition(initialActivities.0 == 2 && initialActivities.1 == 2,
            "Every completed native scan must synchronously release its own full-wake activity")
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

        let policyQueue = OperationQueue()
        let epoch = Date()
        let policy = NativeDriveDuplicates.MemoryGate(queue: policyQueue, workerLimit: nil,
            cpuCount: 18, memoryBytes: 8 << 30, descriptors: 512, now: epoch)
        precondition(policyQueue.maxConcurrentOperationCount == 2)
        var measuredBytes: UInt64 = 0, peakLimit = 0
        for tick in 1...100 {
            let active = policyQueue.maxConcurrentOperationCount
            measuredBytes += UInt64(active) * 4_000_000
            policy.update(level: 1, now: epoch.addingTimeInterval(Double(tick * 2)),
                bytes: measuredBytes, active: max(0, active - 1), waiting: true)
            peakLimit = max(peakLimit, policyQueue.maxConcurrentOperationCount)
        }
        precondition(peakLimit > 40 && peakLimit <= 256, "Useful throughput growth has no fixed file-count cap")
        let pressured = epoch.addingTimeInterval(201)
        policy.update(level: 4, now: pressured)
        precondition(policyQueue.isSuspended && policyQueue.maxConcurrentOperationCount == 1)
        policy.update(level: 1, now: pressured.addingTimeInterval(1))
        precondition(!policyQueue.isSuspended && policyQueue.maxConcurrentOperationCount == 1,
            "Critical pressure stops admission and recovery waits before growing again")
        print("PASS native adaptive admission grows beyond 40 and pauses/recoveries under memory pressure")

        let diskQueue = OperationQueue()
        let diskPolicy = NativeDriveDuplicates.MemoryGate(queue: diskQueue, workerLimit: nil,
            cpuCount: 18, memoryBytes: 8 << 30, descriptors: 512, now: epoch)
        var diskBytes: UInt64 = 0, lowest = 2
        for tick in 1...180 {
            let active = diskQueue.maxConcurrentOperationCount
            diskBytes += 40_000_000 / UInt64(active)
            diskPolicy.update(level: 1, now: epoch.addingTimeInterval(Double(tick * 2)),
                bytes: diskBytes, active: active, waiting: true)
            lowest = min(lowest, diskQueue.maxConcurrentOperationCount)
        }
        precondition(lowest == 1 && diskQueue.maxConcurrentOperationCount <= 2,
            "A disk slowed by concurrent seeks must try and retain fewer readers")
        let firstReader = diskPolicy.register(), parkedReader = diskPolicy.register()
        // Fixed resource pressure reduces this policy to one reader.
        diskPolicy.update(level: 4, now: epoch.addingTimeInterval(400))
        let parked = Task.detached { try diskPolicy.waitForRead(parkedReader) }
        diskPolicy.unregister(firstReader)
        try await parked.value
        diskPolicy.unregister(parkedReader)
        let cancelledReader = diskPolicy.register()
        diskPolicy.stop()
        diskPolicy.update(level: 4, now: epoch.addingTimeInterval(401))
        precondition(!diskQueue.isSuspended, "A queued pressure heartbeat cannot suspend a stopped queue while it drains")
        do { try diskPolicy.waitForRead(cancelledReader); preconditionFailure("Stopped readers must wake") }
        catch is CancellationError { }
        diskPolicy.unregister(cancelledReader)
        print("PASS native smaller-reader trials, promotion and cancellation")

        let parallelTree = directory.appendingPathComponent("Parallel")
        try manager.createDirectory(at: parallelTree, withIntermediateDirectories: true)
        let benchmark = CommandLine.arguments.contains("--benchmark")
        let fileCount = benchmark ? 16 : 8
        let block = Data(repeating: 0x5a, count: (benchmark ? 16 : 4) * 1024 * 1024)
        for index in 0..<fileCount {
            try block.write(to: parallelTree.appendingPathComponent("copy-\(index).bin"))
        }
        let serial = try await NativeDriveDuplicates.scanReporting([parallelTree], workerLimit: 1) { _ in }
        let parallel = try await NativeDriveDuplicates.scanReporting([parallelTree], workerLimit: 4) { _ in }
        precondition(serial.statistics.hashed == fileCount && parallel.statistics.hashed == fileCount)
        precondition(serial.statistics.peakHashing == 1)
        precondition((2...4).contains(parallel.statistics.peakHashing), "File hashing should overlap within the four-worker bound")
        precondition(serial.report.groups.map { $0.members.map(\.path) } == parallel.report.groups.map { $0.members.map(\.path) })
        precondition(serial.report.files?.map(\.id) == parallel.report.files?.map(\.id), "Completion order must not reorder the inventory")
        print("PASS native hashes overlap across \(parallel.statistics.peakHashing) workers with identical results")
        if benchmark {
            print(String(format: "Native SHA-256, 256 MiB: serial %.3fs, parallel %.3fs (%.2fx)",
                serial.report.elapsedSeconds, parallel.report.elapsedSeconds,
                serial.report.elapsedSeconds / parallel.report.elapsedSeconds))
        }

        let (events, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let reading = TestHashReadBarrier()
        let priorEnds = await MainActor.run { activities.ends }
        let cancelled = Task {
            try await NativeDriveDuplicates.scanReporting([parallelTree], sleepPrevention: { activities.makeActivity() }) { event in
                if event["operation"] as? String == "hashing" {
                    reading.holdFirstRead { continuation.yield(()) }
                }
            }
        }
        for await _ in events { break }
        cancelled.cancel()
        try await Task.sleep(nanoseconds: 50_000_000)
        let whileStopping = await MainActor.run { activities.ends }
        precondition(whileStopping == priorEnds && reading.isReading,
            "Cancellation must retain the activity while an actual hash worker is still draining")
        reading.release()
        do {
            _ = try await cancelled.value
            preconditionFailure("Cancelling a parallel scan must cancel its file workers")
        } catch is CancellationError { }
        let afterStopping = await MainActor.run { activities.ends }
        precondition(afterStopping == priorEnds + 1 && !reading.isReading,
            "Returning cancellation must mean physical workers and their activity have finished")
        continuation.finish()
        print("PASS cancelling native duplicate checks drains parallel workers before releasing full-wake activity")

        let pressure = TestMemoryPressure()
        let (pressureEvents, pressureContinuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let paused = Task {
            try await NativeDriveDuplicates.scanReporting([parallelTree], memoryPressure: {
                pressureContinuation.yield(())
                return pressure.read()
            }) { _ in pressure.recordProgress() }
        }
        for await _ in pressureEvents { break }
        precondition(pressure.progressCount == 0, "Critical pressure must prevent new hashing")
        pressure.set(1)
        let resumed = try await paused.value
        precondition(resumed.report.status == "completed" && resumed.statistics.hashed == fileCount)
        pressureContinuation.finish()
        print("PASS native scans resume every pending file when memory pressure clears")

        let (cancelEvents, cancelContinuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let pressureCancelled = Task {
            try await NativeDriveDuplicates.scanReporting([parallelTree], memoryPressure: {
                cancelContinuation.yield(())
                return 4
            }) { _ in }
        }
        for await _ in cancelEvents { break }
        pressureCancelled.cancel()
        do {
            _ = try await pressureCancelled.value
            preconditionFailure("A memory-paused scan must still cancel")
        } catch is CancellationError { }
        cancelContinuation.finish()
        print("PASS cancelling a memory-paused scan releases pending operations")
    }
}

@MainActor private final class TestDuplicateActivities {
    var begins = 0
    var ends = 0
    func makeActivity() -> DownloadSleepPrevention {
        DownloadSleepPrevention(begin: { self.begins += 1; return NSObject() }, end: { _ in self.ends += 1 })
    }
}

private final class TestHashReadBarrier: @unchecked Sendable {
    private let lock = NSCondition()
    private var held = false
    private var released = false
    private var reading = false
    var isReading: Bool { lock.lock(); defer { lock.unlock() }; return reading }
    func holdFirstRead(_ ready: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !held else { return }
        held = true; reading = true
        ready()
        while !released { lock.wait() }
        reading = false
    }
    func release() { lock.lock(); released = true; lock.broadcast(); lock.unlock() }
}

private final class TestMemoryPressure: @unchecked Sendable {
    private let lock = NSLock()
    private var level: UInt32 = 4
    private var progress = 0
    var progressCount: Int { lock.lock(); defer { lock.unlock() }; return progress }
    func read() -> UInt32 { lock.lock(); defer { lock.unlock() }; return level }
    func set(_ value: UInt32) { lock.lock(); defer { lock.unlock() }; level = value }
    func recordProgress() { lock.lock(); defer { lock.unlock() }; progress += 1 }
}

import CryptoKit
import Foundation
import Darwin

/// Exact checks need hashes, not media decoders or similarity vectors.
enum NativeDriveDuplicates {
    /// The number of candidate files read during this scan.
    struct Statistics: Equatable, CustomStringConvertible {
        var hashed = 0
        var peakHashing = 0
        var description: String { "hashed \(hashed)" }
    }

    static func scan(_ roots: [URL],
                     progress: @escaping @Sendable ([String: Any]) -> Void) async throws -> SimilarityReport {
        try await scanReporting(roots, progress: progress).report
    }

    static func scanReporting(_ roots: [URL], workerLimit: Int? = nil,
                              memoryPressure: @escaping @Sendable () -> UInt32 = { NativeDriveDuplicates.memoryPressure() },
                              sleepPrevention: (@MainActor @Sendable () -> DownloadSleepPrevention)? = nil,
                              progress: @escaping @Sendable ([String: Any]) -> Void) async throws -> (report: SimilarityReport, statistics: Statistics) {
        let activity = await MainActor.run {
            let activity = sleepPrevention?() ?? DownloadSleepPrevention(reason: "MyCloudDriver is comparing duplicate file contents")
            activity.setActive(true)
            return activity
        }
        do {
            let result = try await AutomaticRecovery.read { try await CloudDriveFiles.detached {
            let started = Date(), manager = FileManager.default
            var statistics = Statistics()
            var pending = roots, seen = Set<URL>()
            var files: [(url: URL, size: UInt64, modified: Date?)] = [], issues: [SimilarityIssue] = []
            while let source = pending.popLast() {
                try CloudDriveFiles.checkCancellation()
                guard seen.insert(source.standardizedFileURL).inserted else { continue }
                do {
                    let values = try source.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey, .fileSizeKey, .contentModificationDateKey])
                    if values.isSymbolicLink == true || values.isHidden == true { continue }
                    if values.isDirectory == true {
                        if DiskTrash.isManagedStorage(source) { continue }
                        pending.append(contentsOf: try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))
                    } else if values.isRegularFile == true {
                        files.append((source, UInt64(max(0, values.fileSize ?? 0)), values.contentModificationDate))
                    }
                } catch {
                    if TransferFailure.isRetryable(error) { throw error }
                    issues.append(.init(path: source.path, reason: error.localizedDescription))
                }
            }
            let sizeCounts = Dictionary(grouping: files, by: { $0.size }).mapValues(\.count)
            let results = HashResults(count: files.count)
            // Carry coordination cancellation into each operation, preserving
            // file-provider cancellation while the OS chooses worker capacity.
            let cancellation = CloudDriveFiles.coordinationCancellation
            let transferControl = NativeTransferControl.current
            let candidates = files
            let queue = OperationQueue()
            queue.name = "MyCloudDriver.duplicate-hashing"
            queue.qualityOfService = .utility
            let memoryGate = MemoryGate(queue: queue, workerLimit: workerLimit)
            memoryGate.update(level: memoryPressure())
            let monitor = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            monitor.schedule(deadline: .now(), repeating: .milliseconds(250))
            monitor.setEventHandler {
                let cancelled: Bool
                do { try cancellation?.check(); cancelled = false } catch { cancelled = true }
                if cancelled || results.withLock({ results.failure != nil }) {
                    memoryGate.stop()
                    queue.cancelAllOperations(); queue.isSuspended = false
                } else {
                    let snapshot = results.withLock { (results.bytesRead, results.active) }
                    let reading = memoryGate.activeReaders
                    memoryGate.update(level: memoryPressure(), bytes: snapshot.0, active: reading,
                        waiting: queue.operationCount > reading)
                }
            }
            monitor.resume()
            defer {
                monitor.cancel(); memoryGate.stop(); queue.cancelAllOperations(); queue.isSuspended = false
                // Cancellation can interrupt enqueueing before the normal wait.
                // Do not finish the job or release its activity while a hash is
                // still using the file provider or disk.
                queue.waitUntilAllOperationsAreFinished()
            }
            for index in candidates.indices {
                try CloudDriveFiles.checkCancellation()
                queue.addOperation {
                    NativeTransferControl.$current.withValue(transferControl) {
                        CloudDriveFiles.$coordinationCancellation.withValue(cancellation) {
                            let (url, size, modified) = candidates[index]
                            var record = SimilarityFile(id: url.absoluteString, name: url.lastPathComponent, path: url.path,
                                bytes: size, family: "other", localPath: url.path, cloudId: nil, ancestors: [], state: "ready", nativeRevision: ICloudDriveProvider.fileRevision(url))
                            do {
                                try CloudDriveFiles.checkCancellation()
                                var digest: String?
                                if sizeCounts[size, default: 0] > 1 {
                                    let reader = memoryGate.register()
                                    defer { memoryGate.unregister(reader) }
                                    results.withLock {
                                        results.active += 1
                                        results.statistics.peakHashing = max(results.statistics.peakHashing, results.active)
                                    }
                                    defer { results.withLock { results.active -= 1 } }
                                    digest = try CloudDriveFiles.coordinated(url) { coordinatedURL in
                                        let file = try FileHandle(forReadingFrom: coordinatedURL); defer { try? file.close() }
                                        var digest = SHA256(), read: UInt64 = 0
                                        while true {
                                            try memoryGate.waitForRead(reader)
                                            guard let chunk = try file.read(upToCount: 1024 * 1024), !chunk.isEmpty else { break }
                                            try CloudDriveFiles.checkCancellation()
                                            if let failure = results.withLock({ results.failure }) { throw failure }
                                            digest.update(data: chunk); read += UInt64(chunk.count)
                                            results.withLock {
                                                results.bytesRead += UInt64(chunk.count)
                                                if Date().timeIntervalSince(results.lastProgress) > 0.2 {
                                                    progress(["event":"progress", "stage":"analysing", "completed":results.checked, "total":candidates.count,
                                                        "current_file":["name":url.lastPathComponent, "bytes":size], "file_bytes_read":read,
                                                        "operation":"hashing", "counts":["files_ready":results.checked]])
                                                    results.lastProgress = Date()
                                                }
                                            }
                                        }
                                        // A fresh URL avoids cached resource values from discovery.
                                        let after = try URL(fileURLWithPath: coordinatedURL.path).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                                        guard read == size, UInt64(max(0, after.fileSize ?? 0)) == size, after.contentModificationDate == modified else {
                                            throw CloudDriveError.message("The file changed during comparison. Scan it again.")
                                        }
                                        return digest.finalize().map { String(format: "%02x", $0) }.joined()
                                    }
                                }
                                results.withLock {
                                    if let digest {
                                        results.statistics.hashed += 1
                                        results.byHash[digest, default: []].append(record)
                                    }
                                    results.checked += 1
                                    results.inventory[index] = record
                                }
                            } catch {
                                results.withLock {
                                    if error is CancellationError || TransferFailure.isRetryable(error) {
                                        if results.failure == nil { results.failure = error }
                                    } else {
                                        results.issues.append(.init(path: url.path, reason: error.localizedDescription))
                                        record.state = "failed"
                                        results.inventory[index] = record
                                    }
                                }
                            }
                            if results.withLock({ results.failure != nil }) {
                                queue.cancelAllOperations(); queue.isSuspended = false
                            }
                        }
                    }
                }
            }
            queue.waitUntilAllOperationsAreFinished()
            try CloudDriveFiles.checkCancellation()
            if let failure = results.failure { throw failure }
            statistics = results.statistics
            issues.append(contentsOf: results.issues)
            let checked = results.checked, byHash = results.byHash
            let inventory = results.inventory.compactMap { $0 }
            let matches = byHash.filter { $0.value.count > 1 }.sorted { $0.key < $1.key }
            var groups: [SimilarityGroup] = [], members = 0, truncated = false
            for (hash, files) in matches {
                if groups.count >= 2_000 || members + files.count > 20_000 { truncated = true; continue }
                members += files.count
                groups.append(.init(id: hash, matchKind: "byte_identical", family: "other", minimumScore: nil,
                    memberCount: UInt64(files.count), members: files.sorted { $0.path < $1.path }))
            }
            progress(["event":"progress", "stage":"grouping", "completed":groups.count, "total":groups.count, "counts":["files_ready":checked]])
            let coverage = "Files with equal sizes were compared using SHA-256. Hidden files and symbolic links are excluded."
            let report = SimilarityReport(source: .local, scope: roots.map(\.path), status: issues.isEmpty ? "completed" : "partial", threshold: 1,
                scannedFiles: UInt64(files.count), analysedFiles: UInt64(checked), skippedFiles: UInt64(issues.count), downloadedBytes: 0,
                totalGroups: UInt64(matches.count), groups: groups, issues: Array(issues.prefix(500)), truncated: truncated || issues.count > 500,
                coverage: coverage, elapsedSeconds: Date().timeIntervalSince(started), files: inventory)
            return (report, statistics)
            } }
            await MainActor.run { activity.setActive(false) }
            return result
        } catch {
            await MainActor.run { activity.setActive(false) }
            throw error
        }
    }

    /// Worker results and progress are published under the same lock, keeping
    /// counts monotonic while file reads and hashes run independently.
    private final class HashResults: @unchecked Sendable {
        private let lock = NSLock()
        var checked = 0
        var active = 0
        var bytesRead: UInt64 = 0
        var statistics = Statistics()
        var lastProgress = Date.distantPast
        var failure: Error?
        var byHash: [String: [SimilarityFile]] = [:]
        var inventory: [SimilarityFile?]
        var issues: [SimilarityIssue] = []

        init(count: Int) { inventory = Array(repeating: nil, count: count) }

        func withLock<T>(_ operation: () throws -> T) rethrows -> T {
            lock.lock(); defer { lock.unlock() }
            return try operation()
        }
    }

    static func memoryPressure() -> UInt32 {
        var level: UInt32 = 2
        var size = MemoryLayout.size(ofValue: level)
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return 2 }
        return level
    }

    static func descriptorLimit() -> UInt64 {
        var value = rlimit()
        return getrlimit(RLIMIT_NOFILE, &value) == 0 ? UInt64(value.rlim_cur) : 256
    }

    /// Capacity is derived from resources. Trials grow only when byte throughput
    /// improves; pressure affects admission while active hashes finish normally.
    final class MemoryGate: @unchecked Sendable {
        private let lock = NSCondition()
        private let queue: OperationQueue
        private let fixed: Bool
        private let capacity: Int
        private var limit: Int
        private var level: UInt32 = 1
        private var recoverAfter = Date.distantPast
        private var nextTrial = Date.distantPast
        private var sampledAt: Date
        private var sampledBytes: UInt64 = 0
        private var previousRate: Double?
        private var probe: (previous: Int, baseline: Double)?
        private var lowerNext = false
        private var settleUntil = Date.distantPast
        private var readers: [Int] = []
        private var nextReader = 0
        private var stopped = false

        init(queue: OperationQueue, workerLimit: Int?,
             cpuCount: Int = ProcessInfo.processInfo.activeProcessorCount,
             memoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
             descriptors: UInt64 = NativeDriveDuplicates.descriptorLimit(), now: Date = Date()) {
            self.queue = queue
            fixed = workerLimit != nil
            let resources = max(1, min(descriptors / 2, memoryBytes / (2 << 20), UInt64(Int.max)))
            capacity = min(workerLimit.map { max(1, $0) } ?? Int(resources), Int(resources))
            limit = min(capacity, max(1, workerLimit ?? min(2, cpuCount)))
            sampledAt = now
            queue.maxConcurrentOperationCount = limit
        }

        var activeReaders: Int {
            lock.lock(); defer { lock.unlock() }
            return min(readers.count, limit)
        }

        func register() -> Int {
            lock.lock(); defer { lock.unlock() }
            let id = nextReader; nextReader += 1; readers.append(id)
            return id
        }

        func unregister(_ id: Int) {
            lock.lock(); defer { lock.unlock() }
            readers.removeAll { $0 == id }; lock.broadcast()
        }

        func stop() {
            lock.lock(); defer { lock.unlock() }
            stopped = true; queue.isSuspended = false; lock.broadcast()
        }

        func waitForRead(_ id: Int) throws {
            while true {
                try CloudDriveFiles.checkCancellation()
                lock.lock()
                if stopped { lock.unlock(); throw CancellationError() }
                if readers.prefix(limit).contains(id) { lock.unlock(); return }
                _ = lock.wait(until: Date().addingTimeInterval(0.25))
                lock.unlock()
            }
        }

        func update(level current: UInt32, now: Date = Date(), bytes: UInt64 = 0,
                    active: Int = 0, waiting: Bool = false) {
            lock.lock(); defer { lock.broadcast(); lock.unlock() }
            guard !stopped else { return }
            if current >= 2 {
                recoverAfter = now.addingTimeInterval(30)
                if level < 2 {
                    limit = max(1, (probe?.previous ?? limit) / 2)
                    probe = nil; previousRate = nil
                }
                if current >= 4 { limit = 1 }
            }
            level = current
            queue.isSuspended = current >= 4
            if current >= 2 || now < recoverAfter || now < settleUntil {
                sampledAt = now; sampledBytes = bytes
            }
            if !fixed, current < 2, now >= recoverAfter, now >= settleUntil, now.timeIntervalSince(sampledAt) >= 5 {
                let elapsed = now.timeIntervalSince(sampledAt)
                let rate = Double(bytes >= sampledBytes ? bytes - sampledBytes : 0) / elapsed
                sampledAt = now; sampledBytes = bytes
                if !waiting || rate <= 0 {
                    if let trial = probe { limit = trial.previous; probe = nil }
                    previousRate = nil
                } else if active > limit {
                    previousRate = nil
                } else if let trial = probe {
                    let minimum = limit < trial.previous ? trial.baseline * 0.98 : trial.baseline + 1_000_000
                    if rate < minimum {
                        limit = trial.previous
                        nextTrial = now.addingTimeInterval(10)
                    }
                    probe = nil; previousRate = nil
                    settleUntil = now.addingTimeInterval(2)
                } else if let previous = previousRate, abs(rate - previous) <= previous * 0.2,
                          now >= nextTrial, limit < capacity || limit > 1 {
                    probe = (limit, rate)
                    let smaller = limit > 1 && (lowerNext || limit >= capacity)
                    lowerNext = !smaller
                    limit = smaller ? max(1, limit / 2) : min(capacity, limit * 2)
                    previousRate = nil
                    settleUntil = now.addingTimeInterval(2)
                } else { previousRate = rate }
            }
            queue.maxConcurrentOperationCount = limit
        }
    }

}

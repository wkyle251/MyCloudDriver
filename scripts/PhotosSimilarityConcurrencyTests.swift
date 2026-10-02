import AppKit
import Darwin
import Foundation

/// Exercises the Swift provider replies and actual Rust Photos RAM pipeline.
/// All originals are generated in memory; no Photos library or account is used.
@main struct PhotosSimilarityConcurrencyTests {
    @MainActor final class Feed {
        var capacities: [String: [UInt64]] = [:]
        var pipes: [URL] = []
        var active = 0, peak = 0, prefixes = 0
        var release = false
        var written: UInt64 = 0
        func begin(_ id: String, _ pipe: URL, _ capacity: UInt64) {
            capacities[id, default: []].append(capacity); pipes.append(pipe)
            active += 1; peak = max(peak, active)
            var info = stat()
            precondition(lstat(pipe.path, &info) == 0 && info.st_mode & S_IFMT == S_IFIFO && info.st_size == 0)
        }
        func checkCleanup() {
            precondition(active == 0)
            precondition(pipes.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }, "Attempt pipes were not removed")
            precondition(Set(pipes).count == pipes.count, "Every retry must own a fresh pipe")
        }
    }

    @MainActor static func until(_ condition: () -> Bool, scan: SimilarityScanModel, seconds: Double = 60, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(condition(), "Timed out at line \(line): \(scan.error ?? scan.message), fetching \(scan.progress.fetchingFiles), RAM waits \(scan.progress.waitingMemoryFiles)")
    }

    @MainActor static func write(_ content: Data, range: Range<Int>, handle: FileHandle, capacity: UInt64, feed: Feed) async throws {
        var offset = range.lowerBound
        while offset < range.upperBound {
            try Task.checkCancellation()
            let count = min(32 << 10, range.upperBound - offset)
            guard UInt64(offset + count) <= capacity else {
                throw PhotosMemoryCapacityExceeded(requiredBytes: UInt64(offset + count))
            }
            let written = content.withUnsafeBytes {
                Darwin.write(handle.fileDescriptor, $0.baseAddress!.advanced(by: offset), count)
            }
            if written > 0 { offset += written; feed.written += UInt64(written) }
            else { precondition(errno == EAGAIN || errno == EINTR, "Unexpected FIFO write failure") }
            // Yield the main actor to other providers and helper events.
            try await Task.sleep(nanoseconds: 500_000)
        }
    }

    @MainActor static func main() async throws {
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let engine = CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2]) : resources.appendingPathComponent("pikpak")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("PhotosSimilarityConcurrency-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = SimilarityResourceSettings.current

        func configuration(_ name: String) -> SimilarityConfiguration {
            .init(executable: engine, models: resources.appendingPathComponent("FileTwinModels"), worker: resources.appendingPathComponent("filetwin-worker"),
                dataDirectory: root.appendingPathComponent(name + "/data"), temporaryDirectory: root.appendingPathComponent(name + "/temp"), environment: [:])
        }
        func model() -> SimilarityScanModel {
            let scan = SimilarityScanModel(source: .local, activity: FinderTaskActivityStore())
            scan.externalTitle = "Apple Photos"; scan.externalScopeNames = ["Generated originals"]
            scan.families = ["text"]
            scan.resolveExternalSource = { _, _, _ in preconditionFailure("Photos originals must use RAM") }
            return scan
        }
        func start(_ scan: SimilarityScanModel, _ name: String) {
            // Supply isolated scan limits without changing the user's settings.
            let saved = SimilaritySavedSession(id: UUID().uuidString, source: .local, localURLs: [], cloudRoots: [], scope: "Generated originals",
                families: ["text"], threshold: 0.8, exactDuplicates: true,
                resources: .init(workers: 8, memoryBytes: 4 << 30, batchFiles: 8, batchBytes: 64 << 20,
                    downloadMemoryBytes: 64 << 20, acceleration: .cpu, memoryScheduling: true),
                state: "paused", startedAt: Date(), updatedAt: Date())
            scan.start(configuration(name), resuming: saved)
        }
        func finish(_ scan: SimilarityScanModel) async throws {
            try await until({ !scan.isRunning }, scan: scan, seconds: 120)
            precondition(!scan.isPaused && scan.error == nil && scan.report != nil, scan.error ?? "Missing scan result")
        }

        let small = Data(String(repeating: "A garden with flowers, trees and green grass. ", count: 4_000).utf8)
        let overlap = model(), peers = Feed()
        overlap.streamExternalSources = { emit in
            for index in 0..<8 {
                try await emit(.init(id: "asset:peer-\(index)", name: "peer-\(index).txt", path: "Photos/peer-\(index).txt", size: 0, localPath: nil))
            }
        }
        overlap.resolveExternalMemorySource = { id, pipe, capacity, _ in
            peers.begin(id, pipe, capacity); defer { peers.active -= 1 }
            let handle = try SimilarityMemoryPipe.open(pipe); defer { try? handle.close() }
            try await write(small, range: 0..<(64 << 10), handle: handle, capacity: capacity, feed: peers)
            peers.prefixes += 1
            while !peers.release { try await Task.sleep(nanoseconds: 5_000_000) }
            try await write(small, range: (64 << 10)..<small.count, handle: handle, capacity: capacity, feed: peers)
            return pipe
        }
        start(overlap, "overlap")
        try await until({ peers.prefixes == 8 && overlap.progress.fetchingFiles == 8 }, scan: overlap)
        precondition(peers.peak == 8 && overlap.progress.waitingMemoryFiles == 0)
        precondition(overlap.progress.originalMemoryBytes > 0 && overlap.progress.originalMemoryBytes <= 64 << 20)
        precondition(peers.capacities.values.allSatisfy { $0 == [8 << 20] })
        let pid = overlap.processIdentifier
        overlap.pause(); try await until({ overlap.isPaused && !overlap.isRunning }, scan: overlap)
        let held = overlap.progress.originalMemoryBytes
        precondition(held > 0 && overlap.retainsOriginalsInRAM && overlap.processIdentifier == pid)
        overlap.start(configuration("overlap"), resuming: overlap.savedSession!)
        precondition(overlap.processIdentifier == pid)
        peers.release = true
        try await finish(overlap)
        precondition(overlap.report?.analysedFiles == 8 && overlap.report?.failedFiles == 0)
        precondition(overlap.report?.groups.contains { $0.isExact && $0.memberCount == 8 } == true)
        precondition(peers.capacities.values.allSatisfy { $0.count == 1 }, "Pause must retain all eight provider requests")
        peers.checkCleanup(); overlap.clearSession()
        print("PASS eight unknown Photos originals overlap with free RAM; pause/resume retains their partial buffers and provider requests")

        let large = Data(String(repeating: "A garden with flowers, trees and green grass. ", count: 480_000).utf8)
        precondition(large.count > 16 << 20 && large.count < 32 << 20)
        let retry = model(), attempts = Feed()
        retry.streamExternalSources = { emit in
            for (id, size) in [("unknown", UInt64(0)), ("known", UInt64(large.count))] {
                try await emit(.init(id: "asset:" + id, name: id + ".txt", path: "Photos/" + id + ".txt", size: size, localPath: nil))
            }
        }
        retry.resolveExternalMemorySource = { id, pipe, capacity, _ in
            attempts.begin(id, pipe, capacity); defer { attempts.active -= 1 }
            let handle = try SimilarityMemoryPipe.open(pipe); defer { try? handle.close() }
            try await write(large, range: 0..<large.count, handle: handle, capacity: capacity, feed: attempts)
            return pipe
        }
        start(retry, "retry"); try await finish(retry)
        precondition(attempts.capacities["asset:unknown"] == [8 << 20, 16 << 20, 32 << 20])
        precondition(attempts.capacities["asset:known"] == [UInt64(large.count)])
        precondition(retry.report?.analysedFiles == 2 && retry.report?.failedFiles == 0)
        precondition(retry.report?.files?.allSatisfy { $0.bytes == UInt64(large.count) } == true)
        precondition(retry.report?.groups.contains { $0.isExact && $0.memberCount == 2 } == true, "Retries must deliver exactly the complete original, with no repeated prefix")
        precondition(retry.report!.downloadedBytes > UInt64(large.count * 2), "Fetched retry prefixes must remain counted")
        attempts.checkCleanup(); retry.clearSession()
        print("PASS oversized unknown original retries at 8/16/32 MiB; known-size original starts once; complete contents are byte-identical")

        let failures = model(), rejected = Feed()
        failures.streamExternalSources = { emit in
            for name in ["too-large", "invalid", "truncated", "healthy"] {
                try await emit(.init(id: "asset:" + name, name: name + ".txt", path: "Photos/" + name + ".txt",
                    size: name == "truncated" ? UInt64(small.count) : 0, localPath: nil))
            }
        }
        failures.resolveExternalMemorySource = { id, pipe, capacity, _ in
            rejected.begin(id, pipe, capacity); defer { rejected.active -= 1 }
            let handle = try SimilarityMemoryPipe.open(pipe); defer { try? handle.close() }
            let length = id == "asset:healthy" ? small.count : 32 << 10
            try await write(small, range: 0..<length, handle: handle, capacity: capacity, feed: rejected)
            if id == "asset:too-large" { throw PhotosMemoryCapacityExceeded(requiredBytes: capacity + 1) }
            if id == "asset:invalid" { throw PhotosMemoryCapacityExceeded(requiredBytes: capacity) }
            return pipe
        }
        start(failures, "failures"); try await finish(failures)
        precondition(rejected.capacities["asset:too-large"] == [8 << 20, 16 << 20, 32 << 20, 64 << 20])
        precondition(rejected.capacities["asset:invalid"]?.count == 1 && rejected.capacities["asset:truncated"]?.count == 1)
        precondition(failures.report?.analysedFiles == 1 && failures.report?.failedFiles == 3)
        precondition(failures.report?.issues.contains { $0.path.hasSuffix("too-large.txt") && $0.reason.contains("needs more RAM") && $0.reason.contains("Scan Resources") } == true)
        rejected.checkCleanup(); failures.clearSession()
        print("PASS full-pool overflow, invalid retry and truncated original fail without a retry loop; healthy peers finish; pipes are removed")

        let cancelled = model(), partials = Feed()
        cancelled.streamExternalSources = { emit in
            for index in 0..<2 {
                try await emit(.init(id: "asset:cancel-\(index)", name: "cancel-\(index).txt", path: "Photos/cancel-\(index).txt", size: 0, localPath: nil))
            }
        }
        cancelled.resolveExternalMemorySource = { id, pipe, capacity, _ in
            partials.begin(id, pipe, capacity); defer { partials.active -= 1 }
            let handle = try SimilarityMemoryPipe.open(pipe); defer { try? handle.close() }
            try await write(small, range: 0..<(64 << 10), handle: handle, capacity: capacity, feed: partials)
            partials.prefixes += 1
            while !partials.release { try await Task.sleep(nanoseconds: 5_000_000) }
            return pipe
        }
        start(cancelled, "cancel")
        try await until({ partials.prefixes == 2 && cancelled.progress.originalMemoryBytes > 0 }, scan: cancelled)
        cancelled.clearSession()
        try await until({ !cancelled.isRunning && cancelled.processIdentifier == nil && partials.active == 0 }, scan: cancelled)
        precondition(cancelled.progress.originalMemoryBytes == 0 && cancelled.savedSession == nil)
        partials.checkCleanup()
        precondition(SimilarityResourceSettings.current == defaults)
        print("PASS cancellation releases concurrent partial providers, pipes and helper RAM; user resource settings remain unchanged")

        let throughput = model(), fast = Feed()
        let generated = Data(repeating: 65, count: 4 << 20)
        var deliverySeconds = 0.0
        throughput.streamExternalSources = { emit in
            try await emit(.init(id: "asset:throughput", name: "throughput.txt", path: "Photos/throughput.txt", size: UInt64(generated.count), localPath: nil))
        }
        throughput.resolveExternalMemorySource = { id, pipe, capacity, _ in
            fast.begin(id, pipe, capacity); defer { fast.active -= 1 }
            let start = Date()
            try await CloudDriveFiles.detached {
                let handle = try SimilarityMemoryPipe.open(pipe); defer { try? handle.close() }
                try SimilarityMemoryPipe.write(generated, to: handle)
            }
            deliverySeconds = Date().timeIntervalSince(start)
            return pipe
        }
        start(throughput, "throughput"); try await finish(throughput)
        precondition(throughput.report?.downloadedBytes == UInt64(generated.count))
        precondition(deliverySeconds < 2.5, "A ready 4 MiB buffer must not be throttled by repeated 5 ms FIFO sleeps")
        fast.checkCleanup(); throughput.clearSession()
        print(String(format: "PASS production Swift/Rust pipe delivers generated 4 MiB in %.3f s without polling-sleep throttling", deliverySeconds))
    }
}

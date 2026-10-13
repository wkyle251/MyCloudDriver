import Foundation

/// A ceiling, never an up-front allocation. The helper can lower this under
/// system memory pressure without discarding bytes already received.
enum DownloadBufferPolicy {
    static let gib: UInt64 = 1_073_741_824
    static let capsMiB = [0, 128, 256, 512, 1_024, 2_048, 4_096, 8_192, 16_384, 32_768]
    static func limitBytes(memory: UInt64, capMiB: Int) -> UInt64 {
        capMiB == 0 ? memory : min(memory, UInt64(max(1, capMiB)) * 1_048_576)
    }
    static func environment(_ source: [String: String], capMiB: Int) -> [String: String] {
        var result = source
        result.removeValue(forKey: "MYCLOUDDRIVER_DOWNLOAD_RAM_RESERVE_BYTES")
        result["MYCLOUDDRIVER_DOWNLOAD_RAM_LIMIT_BYTES"] = capMiB > 0 ? String(UInt64(capMiB) * 1_048_576) : nil
        return result
    }
    static func text(_ bytes: UInt64) -> String {
        bytes >= gib ? String(format: "%.1f GiB", Double(bytes) / Double(gib))
            : String(format: "%.0f MiB", Double(bytes) / 1_048_576)
    }
}

struct DownloadBufferUsage: Equatable {
    var used: UInt64
    var peak: UInt64
    var limit: UInt64
    var configured: UInt64
    var reserve: UInt64
    var pressure: UInt64
    var receivedAt: Date
    var traffic: DownloadDiskTraffic? = nil

    /// Pause stops reception, but accepted data and verification still need the
    /// Mac awake until their disk work has finished.
    var hasPendingDiskWork: Bool {
        if used > 0 { return true }
        guard let traffic else { return false }
        return traffic.pendingReadTasks > 0 || traffic.readingTasks > 0
            || (traffic.activeReadTasks ?? 0) > 0 || (traffic.activeWriteTasks ?? 0) > 0
            || (traffic.waitingWriters ?? 0) > 0 || (traffic.checkpointBatchPending ?? 0) > 0
            || (traffic.ramDrainingTasks ?? 0) > 0 || (traffic.diskOnlyTasks ?? 0) > 0
            || (traffic.pendingWriteBytes ?? 0) > 0 || (traffic.writingBytes ?? 0) > 0
    }
}

struct DownloadDiskTraffic: Decodable, Equatable {
    let pendingReadBytes: UInt64
    let readingBytes: UInt64
    let pendingReadTasks: Int
    let readingTasks: Int
    let readDrives: Int
    let writeDrives: Int
    let batchRemainingBytes: UInt64
    // Optional for an older helper's heartbeat during upgrades.
    var oldestPendingMs: UInt64? = nil
    var waitingReadBytes: UInt64? = nil
    var waitingReadTasks: Int? = nil
    var oldestWaitingReadMs: UInt64? = nil
    var readTasksStarted: UInt64? = nil
    var readTasksFinished: UInt64? = nil
    var readWorkAddedBytes: UInt64? = nil
    var readWorkProcessedBytes: UInt64? = nil
    var readWorkRemovedBytes: UInt64? = nil
    var prefetchBytes: UInt64? = nil
    var prefetchTasks: Int? = nil
    var prefetchDiscardedBytes: UInt64? = nil
    var prefetchActiveSlots: Int? = nil
    var prefetchContexts: Int? = nil
    var prefetchReceiverLimit: Int? = nil
    var prefetchContextLimit: Int? = nil
    var prefetchFinished: UInt64? = nil
    var prefetchFailed: UInt64? = nil
    var prefetchEmptyEnds: UInt64? = nil
    var admittedReadTasks: Int? = nil
    var admittedReadBytes: UInt64? = nil
    var deferredReadTasks: Int? = nil
    var deferredReadBytes: UInt64? = nil
    var readAdmissionDeferrals: UInt64? = nil
    var receivingTasks: Int? = nil
    var ramDrainingTasks: Int? = nil
    var diskOnlyTasks: Int? = nil
    var pendingWriteBytes: UInt64? = nil
    var writingBytes: UInt64? = nil
    var writingTasks: Int? = nil
    var activeWriteTasks: Int? = nil
    var activeWriteBytes: UInt64? = nil
    var waitingWriters: Int? = nil
    var writeDispatchPolls: UInt64? = nil
    var eligibleWaitingWriters: Int? = nil
    var turnElapsedMs: UInt64? = nil
    var turnTargetMs: UInt64? = nil
    var readyReadTasks: Int? = nil
    var readyReadBytes: UInt64? = nil
    var activeReadTasks: Int? = nil
    var activeReadBytes: UInt64? = nil
    var switchWaitMs: UInt64? = nil
    var readTurns: UInt64? = nil
    var writeTurns: UInt64? = nil
    var backlogDrives: Int? = nil
    var fileWorkerLimit: Int? = nil
    var fileNetworkWorkers: Int? = nil
    var fileTaskCapacity: Int? = nil
    var fileTaskCapacityReached: Bool? = nil
    var receivingAdmissionWaiters: Int? = nil
    var readTurnTimeouts: UInt64? = nil
    var readTurnFinishes: UInt64? = nil
    var readTurnPressureHandoffs: UInt64? = nil
    var readTurnControlHandoffs: UInt64? = nil
    var lastReadHandoverSequence: UInt64? = nil
    var lastReadHandoverReason: UInt64? = nil
    var lastReadTurnMs: UInt64? = nil
    var lastReadRemainingBytes: UInt64? = nil
    var readWriteThresholdPercent: UInt64? = nil
    var readWriteThresholdBytes: UInt64? = nil
    var readTurnWriteHandoffs: UInt64? = nil
    var readTurnIdleHandoffs: UInt64? = nil
    var readTurnLatencyHandoffs: UInt64? = nil
    var lastReadPendingWriteBytes: UInt64? = nil
    var lastReadBufferLimitBytes: UInt64? = nil
    var queuedDownloads: Int? = nil
    var downloadHasReady: Bool? = nil
    var ramWaitingReceivers: Int? = nil
    var ramWaitCount: UInt64? = nil
    var ramWaitTotalMs: UInt64? = nil
    var ramWaitMaxMs: UInt64? = nil
    var checkpointBatches: UInt64? = nil
    var checkpointBatchedFiles: UInt64? = nil
    var checkpointBarriers: UInt64? = nil
    var checkpointBatchTotalMs: UInt64? = nil
    var checkpointBatchPending: UInt64? = nil
    var waitingCheckCount: Int {
        waitingReadTasks ?? max(0, pendingReadTasks + readingTasks - min(readingTasks, activeReadTasks ?? 0))
    }
    var waitingCheckBytes: UInt64 {
        if let bytes = waitingReadBytes { return bytes }
        let sum = pendingReadBytes.addingReportingOverflow(readingBytes)
        let total = sum.overflow ? UInt64.max : sum.partialValue
        return total - min(total, activeReadBytes ?? 0)
    }
    var turnSummary: String? {
        guard let elapsed = turnElapsedMs else { return nil }
        let text = "Turn \(elapsed / 1_000)s"
        if let percent = readWriteThresholdPercent, readDrives > 0 {
            if let target = turnTargetMs, target > 0 {
                return text + " • write batch after \(target / 1_000)s"
            }
            return text + " • writes above \(percent)% \((prefetchBytes ?? 0) > 0 ? "available RAM" : "RAM")"
        }
        guard let target = turnTargetMs else { return text }
        if target == 0 { return text + " • until written" }
        if readDrives > 0 && writeDrives > 0 { return "Reads: \(target / 1_000)s • writes: until written" }
        return text + " • target \(target / 1_000)s"
    }
    var phase: String { readDrives > 0 ? (writeDrives > 0 ? "Read/write turns on separate disks" : "Read turn • receiving into RAM") : "Write turn • draining RAM" }
    var lastReadHandoverSummary: String? {
        let reason: String
        switch lastReadHandoverReason {
        case 1: reason = "10s limit reached"
        case 2: reason = "selected checks finished"
        case 3: reason = "RAM pressure"
        case 4: reason = "pause, cancel or shutdown drain"
        case 5: reason = "pending writes exceeded \(readWriteThresholdPercent ?? 80)% RAM"
        case 6: reason = "receiving idle; draining waiting writes"
        case 7: reason = "waiting writes reached the read-turn limit"
        default: return nil
        }
        return "Last read turn: \((lastReadTurnMs ?? 0) / 1_000)s, \(reason), \(DownloadBufferPolicy.text(lastReadRemainingBytes ?? 0)) unfinished"
    }
}

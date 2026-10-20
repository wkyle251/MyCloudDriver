import AppKit
import Combine
import Darwin
import SwiftUI
import UniformTypeIdentifiers

enum SimilaritySource: String, Codable, CaseIterable, Identifiable {
    case cloud, local
    var id: Self { self }
    var title: String { self == .cloud ? "PikPak" : "Local Disk" }
    var symbol: String { self == .cloud ? "cloud" : "laptopcomputer" }
    var taskKind: FinderTaskKind { self == .cloud ? .similarityCloud : .similarityLocal }
}

struct SimilarityAncestor: Codable { let id: String; let name: String }
struct SimilarityCloudRoot: Codable, Identifiable {
    let id: String
    let name: String
    let path: String
    let isFolder: Bool
    let size: UInt64
    let ancestors: [SimilarityAncestor]
}
struct SimilarityFile: Codable, Identifiable {
    let id: String
    let name: String
    let path: String
    let bytes: UInt64
    let family: String
    let localPath: String?
    let cloudId: String?
    let ancestors: [SimilarityAncestor]
    var engineIndex: UInt64? = nil
    var engineId: String? = nil
    var state: String? = nil
    var nativeRevision: String? = nil
    var nativeScopeID: String? = nil
    var scoreID: String { engineId ?? id }
    var symbol: String {
        switch family { case "image": return "photo"; case "audio": return "waveform"; case "video": return "film"; default: return "doc.text" }
    }
}
struct SimilarityGroup: Codable, Identifiable {
    let id: String
    let matchKind: String
    let family: String
    let minimumScore: Double?
    let memberCount: UInt64
    let members: [SimilarityFile]
    var isExact: Bool { matchKind == "byte_identical" }
    var title: String { members.first?.name ?? "Match group" }
    var scoreLabel: String { isExact ? "Identical content" : String(format: "Score %.1f%%", (minimumScore ?? 0) * 100) }
}
struct SimilarityIssue: Codable { let path: String; let reason: String }
struct SimilarityIssueSummary: Codable {
    let category: String
    let reason: String
    let count: UInt64
}
struct SimilarityReport: Codable {
    let source: SimilaritySource
    let scope: [String]
    var status: String
    let threshold: Double
    let scannedFiles: UInt64
    let analysedFiles: UInt64
    let skippedFiles: UInt64
    var downloadedBytes: UInt64
    let totalGroups: UInt64
    let groups: [SimilarityGroup]
    let issues: [SimilarityIssue]
    let truncated: Bool
    var coverage: String
    var elapsedSeconds: Double
    var files: [SimilarityFile]? = nil
    var runId: String? = nil
    var resultRevision: UInt64? = nil
    var scoresRetained: UInt64? = nil
    var unsupportedFiles: UInt64? = nil
    var failedFiles: UInt64? = nil
    var issueSummary: [SimilarityIssueSummary]? = nil
    var outcomeSummary: String {
        if let unsupportedFiles, let failedFiles {
            return "\(analysedFiles.formatted()) analysed · \(unsupportedFiles.formatted()) unsupported · \(failedFiles.formatted()) failed"
        }
        return "\(analysedFiles.formatted()) analysed · \(skippedFiles.formatted()) skipped"
    }
}

struct SimilarityConfiguration {
    let executable: URL
    let models: URL
    let worker: URL
    let dataDirectory: URL
    let temporaryDirectory: URL
    let environment: [String: String]
}

private struct SimilarityRuntime: Encodable {
    let workerPath: String
    let ffmpegPath: String?
    let ffprobePath: String?
    let onnxruntimePath: String
    let pdfiumPath: String
}
private struct SimilarityRequest: Encodable {
    let checkpointId: String?
    let parentPid: Int32
    let source: SimilaritySource
    let localPaths: [String]
    let cloudItems: [SimilarityCloudRoot]
    let externalSources: [SimilarityExternalSource]
    let externalSourceStream: String?
    let refreshInventory = true
    let families: [String]
    let threshold: Double
    let exactDuplicates: Bool
    let includeHidden = false
    let dataDir: String
    let modelDir: String
    let tempDir: String
    let reportPath: String
    let runtime: SimilarityRuntime
    let resources: SimilarityResourceLimits
}

/// An inventory entry, not a downloaded/exported original. The ID belongs to
/// the captured provider and remains stable when temporary content is released.
struct SimilarityExternalSource: Encodable {
    let id: String
    let name: String
    let path: String
    let size: UInt64
    let localPath: String?
    var revision: String? = nil
    var contentKind: String? = nil
    var provider: String? = nil
}

struct SimilaritySourceRequest {
    let id: String
    let directory: URL
    let response: URL
    let memoryPipe: URL?
    let memoryCapacity: UInt64
    let downloadID: UInt64?

    init?(event: [String: Any], root: URL, allowedIDs: Set<String>) {
        guard let id = event["id"] as? String, allowedIDs.contains(id),
              let path = event["directory"] as? String, path.hasPrefix("/"),
              let reply = event["response_file"] as? String, reply.hasPrefix("/") else { return nil }
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        let directory = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        // The reply does not exist yet. Resolve its existing parent so /var
        // and /private/var aliases normalize just like the content directory.
        let rawResponse = URL(fileURLWithPath: reply).standardizedFileURL
        let response = rawResponse.deletingLastPathComponent().resolvingSymlinksInPath()
            .appendingPathComponent(rawResponse.lastPathComponent)
        let lease = directory.deletingLastPathComponent()
        let run = lease.deletingLastPathComponent()
        guard directory.lastPathComponent == "content", response.lastPathComponent == "source.json",
              response.deletingLastPathComponent() == lease,
              lease.lastPathComponent.hasPrefix("source-"), run.lastPathComponent.hasPrefix("similarity-"),
              run.deletingLastPathComponent() == root,
              FileManager.default.fileExists(atPath: directory.path) else { return nil }
        if let pipe = event["memory_pipe"] as? String {
            let url = URL(fileURLWithPath: pipe).standardizedFileURL
            guard url == directory.appendingPathComponent("original.pipe"),
                  let capacity = (event["memory_capacity"] as? NSNumber)?.uint64Value, capacity > 0 else { return nil }
            memoryPipe = url; memoryCapacity = capacity
        } else { memoryPipe = nil; memoryCapacity = 0 }
        if let number = event["download_id"] as? NSNumber, number.doubleValue.isFinite, number.doubleValue >= 0 {
            downloadID = number.uint64Value
        } else { downloadID = nil }
        self.id = id; self.directory = directory; self.response = response
    }
}

enum SimilarityScanStage: String, Codable, CaseIterable {
    case inventory, downloading, analysing, comparison, grouping, finishing, checking
    var title: String {
        switch self {
        case .checking: return "Checking for file changes"
        case .inventory: return "Finding files"
        case .downloading: return "Fetching cloud files"
        case .analysing: return "Analysing file content"
        case .comparison: return "Comparing files"
        case .grouping: return "Grouping matches"
        case .finishing: return "Preparing results"
        }
    }
    var stepTitle: String {
        switch self {
        case .checking: return "Check changes"
        case .inventory: return "Find files"
        case .downloading: return "Fetch copies"
        case .analysing: return "Analyse"
        case .comparison: return "Compare"
        case .grouping, .finishing: return "Results"
        }
    }
}

struct SimilarityScanProgress: Codable {
    var stage: SimilarityScanStage = .inventory
    var completed: UInt64 = 0
    var total: UInt64?
    var analysed: UInt64 = 0
    var skipped: UInt64 = 0
    var matches: UInt64 = 0
    var downloadedBytes: UInt64 = 0
    var currentName: String?
    var currentBytes: UInt64 = 0
    var currentSize: UInt64 = 0
    var operation = ""
    var bytesRead: UInt64 = 0
    var bytesHashed: UInt64 = 0
    // Optional additions keep snapshots from older installed versions readable.
    var originalBytesRead: UInt64? = nil
    var hashingFiles: UInt64? = nil
    var waitingReadFiles: UInt64? = nil
    var pairsCompared: UInt64 = 0
    var scoresRetained: UInt64 = 0
    var vectorsEncoded: UInt64 = 0
    var cacheHits: UInt64 = 0
    var foundFiles: UInt64 = 0
    var listingFoldersDiscovered: UInt64? = nil
    var listingFoldersCompleted: UInt64? = nil
    var listingFoldersPending: UInt64? = nil
    var listingPagesCompleted: UInt64? = nil
    var listingFilesFound: UInt64? = nil
    var activeFiles: UInt64 = 0
    var fetchingFiles: UInt64 = 0
    var readingFiles: UInt64 = 0
    var encodingFiles: UInt64 = 0
    var acceleratorActive: UInt64 = 0
    var acceleratorLimit: UInt64 = 0
    var waitingAcceleratorFiles: UInt64 = 0
    var waitingProcessingFiles: UInt64 = 0
    var waitingMemoryFiles: UInt64 = 0
    var waitingReuseFiles: UInt64 = 0
    var waitingDownloadFiles: UInt64 = 0
    var retryingDownloadFiles: UInt64 = 0
    var downloadLimit: UInt64 = 0
    var downloads: [SimilarityDownload] = []
    var downloadCount: UInt64 = 0
    var omittedDownloads: UInt64 = 0
    var downloadSpeed: Double = 0
    var downloadForecastBytes: UInt64 = 0
    var downloadForecastSeconds: Double = 0
    var downloadsUpdatedAt = Date()
    var hasDownloadTelemetry = false
    var readyFiles: UInt64 = 0
    var resolvingFiles: UInt64 = 0
    var independentDownloads = false
    var originalMemoryBytes: UInt64 = 0
    var originalMemoryLimit: UInt64 = 0
    var retainedDownloadMinimum: UInt64 = 0
    var analysisMemoryLimit: UInt64 = 0
    var analysisMemoryBytes: UInt64 = 0
    var memoryLimit: UInt64? = nil
    var analysisMemoryRequired: UInt64? = nil
    var analysisMemoryForecast: UInt64? = nil
    var analysisGrowthBytes: UInt64? = nil
    var analysisTransferBytes: UInt64? = nil
    var stagingMemoryRequired: UInt64? = nil
    var stagingMemoryLimit: UInt64? = nil
    var memoryScheduling = false
    var memoryPressure: UInt64? = nil
    var analysisMemoryLabel: String { "\(Self.memoryGB(analysisMemoryBytes)) / \(Self.memoryGB(analysisMemoryLimit))" }
    var analysisMemoryFraction: Double {
        analysisMemoryLimit > 0 ? min(1, Double(analysisMemoryBytes) / Double(analysisMemoryLimit)) : 0
    }
    var originalMemoryFraction: Double {
        originalMemoryLimit > 0 ? min(1, Double(originalMemoryBytes) / Double(originalMemoryLimit)) : 0
    }
    static func memoryGB(_ bytes: UInt64) -> String {
        (Double(bytes) / 1_073_741_824).formatted(.number.precision(.fractionLength(0...2))) + " GB"
    }
    var originalMemoryLabel: String { "\(Self.memoryGB(originalMemoryBytes)) / \(Self.memoryGB(originalMemoryLimit))" }
    var availableOriginalMemoryLabel: String { Self.memoryGB(originalMemoryLimit > originalMemoryBytes ? originalMemoryLimit - originalMemoryBytes : 0) }
    var workerLimit: UInt64 = 0
    var unsupportedFiles: UInt64 = 0
    var failedFiles: UInt64 = 0
    var hasWorkPhases = false
    var discoveryComplete = false
    var cloudBytesReady: UInt64?
    var cloudBytesTotal: UInt64?
    var cloudByteInventoryComplete = false
    var cloudOnDemand: Bool? = nil
    var sampledOriginals: UInt64? = nil
    var sampledReceivedBytes: UInt64? = nil
    var usesOnDemandCloudProgress: Bool { stage == .analysing && cloudOnDemand == true }
    var usesCloudByteProgress: Bool { stage == .analysing && cloudBytesTotal != nil && cloudOnDemand != true }
    var progressTitle: String { usesCloudByteProgress ? "Cloud download progress" : "\(stage.stepTitle) progress" }
    var cloudByteLabel: String? {
        if usesOnDemandCloudProgress {
            return "\((sampledOriginals ?? 0).formatted()) sampled originals · \(Self.bytes(sampledReceivedBytes ?? 0)) range data fetched"
        }
        guard let ready = cloudBytesReady, let total = cloudBytesTotal else { return nil }
        let amount = cloudByteInventoryComplete ? "\(Self.bytes(ready)) of \(Self.bytes(total))"
            : "\(Self.bytes(ready)) ready · \(Self.bytes(total)) found so far"
        return amount + " · Includes cached and skipped files"
    }
    func cloudDownloadSecondsRemaining(at date: Date) -> TimeInterval? {
        // The helper already smooths aggregate speed across all downloads,
        // including rows beyond the visible list. Use unresolved content bytes;
        // cumulative traffic also contains retries and earlier helper runs.
        guard usesCloudByteProgress, cloudByteInventoryComplete,
              let ready = cloudBytesReady, let total = cloudBytesTotal, total > ready,
              hasDownloadTelemetry, downloadSpeed.isFinite, downloadSpeed >= 1,
              max(0, date.timeIntervalSince(downloadsUpdatedAt)) < 5 else { return nil }
        return Double(total - ready) / downloadSpeed
    }
    func cloudDownloadTimeLabel(at date: Date, running: Bool, restoring: Bool = false) -> String? {
        guard usesCloudByteProgress else { return nil }
        guard running else { return "Download time estimate paused" }
        guard !restoring else { return "Estimating download time…" }
        guard cloudByteInventoryComplete else { return "Counting files to estimate download time…" }
        if let ready = cloudBytesReady, let total = cloudBytesTotal, ready >= total {
            return "Cloud downloads complete"
        }
        guard let seconds = cloudDownloadSecondsRemaining(at: date) else { return "Estimating download time…" }
        var minutes = Int((seconds / 60).rounded(.up))
        guard minutes >= 2 else { return "Less than 2 mins left to download" }
        var parts: [String] = []
        // Approximate months use 30 days. A unit with value 1 rolls into the
        // next smaller unit, so hiding it does not discard that duration.
        for (unit, length) in [("months", 30 * 24 * 60), ("weeks", 7 * 24 * 60),
                               ("days", 24 * 60), ("hours", 60), ("mins", 1)] {
            let amount = minutes / length
            if amount > 1 {
                parts.append("\(amount.formatted()) \(unit)")
                minutes -= amount * length
            }
        }
        return "About \(parts.joined(separator: " ")) left to download"
    }
    var queuedFiles: UInt64 { foundFiles > completed + activeFiles + waitingReuseFiles ? foundFiles - completed - activeFiles - waitingReuseFiles : 0 }
    var phaseSummary: String {
        if encodingFiles > 0 { return "\(encodingFiles.formatted()) files analysing · \(readingFiles.formatted()) reading · \(fetchingFiles.formatted()) fetching" }
        if readingFiles > 0 { return "Reading \(readingFiles.formatted()) files into RAM" }
        if fetchingFiles > 0 { return "Fetching \(fetchingFiles.formatted()) originals from the drive" }
        if readyFiles > 0 { return "\(readyFiles.formatted()) files ready for analysis" }
        if resolvingFiles > 0 { return "Connecting to \(resolvingFiles.formatted()) originals" }
        if retryingDownloadFiles > 0 { return "Retrying temporary download interruptions" }
        if waitingDownloadFiles > 0 { return "Waiting for the next download slot" }
        if waitingMemoryFiles > 0 { return "Waiting for available memory within this scan’s allowance" }
        if waitingReuseFiles > 0 { return "Reusing analysis for identical files" }
        return discoveryComplete ? "Finishing the file inventory" : "Waiting for files from discovery"
    }
    var waitingSummary: String {
        var parts: [String] = []
        if resolvingFiles > 0 { parts.append("\(resolvingFiles.formatted()) connecting") }
        if let count = waitingReadFiles, count > 0 { parts.append("\(count.formatted()) waiting to read") }
        if waitingDownloadFiles > 0 { parts.append("\(waitingDownloadFiles.formatted()) waiting to download") }
        if retryingDownloadFiles > 0 { parts.append("\(retryingDownloadFiles.formatted()) retrying download") }
        if waitingMemoryFiles > 0 { parts.append("\(waitingMemoryFiles.formatted()) waiting for memory") }
        if waitingAcceleratorFiles > 0 { parts.append("\(waitingAcceleratorFiles.formatted()) waiting for accelerated processing") }
        if waitingProcessingFiles > 0 { parts.append("\(waitingProcessingFiles.formatted()) waiting for a processing slot") }
        if waitingReuseFiles > 0 { parts.append("\(waitingReuseFiles.formatted()) reusing an identical file’s result") }
        return parts.joined(separator: " · ")
    }
    var displayTitle: String {
        if stage == .analysing {
            if !discoveryComplete { return "Finding and analysing files" }
            if encodingFiles == 0 && readingFiles > 0 { return "Reading files into RAM" }
            if let hashingFiles, hashingFiles > 0 && hashingFiles == encodingFiles { return "Hashing file content" }
        }
        return stage.title
    }

    mutating func applyListing(_ event: [String: Any]) {
        listingFoldersDiscovered = (event["folders_discovered"] as? NSNumber)?.uint64Value
        listingFoldersCompleted = (event["folders_completed"] as? NSNumber)?.uint64Value
        listingFoldersPending = (event["folders_pending"] as? NSNumber)?.uint64Value
        listingPagesCompleted = (event["pages_completed"] as? NSNumber)?.uint64Value
        listingFilesFound = (event["found"] as? NSNumber)?.uint64Value
    }
    init() {}
    init(event: [String: Any]) {
        let rawStage = event["stage"] as? String ?? ""
        stage = rawStage == "comparing" ? .comparison : SimilarityScanStage(rawValue: rawStage) ?? .analysing
        let counts = event["counts"] as? [String: Any] ?? [:]
        let completedKey = stage == .comparison ? "pairs_processed" : "files_processed"
        let totalKey = stage == .comparison ? "pairs_total" : "files_total"
        completed = (event["completed"] as? NSNumber)?.uint64Value ?? (counts[completedKey] as? NSNumber)?.uint64Value ?? 0
        total = (event["total"] as? NSNumber)?.uint64Value ?? ((stage == .analysing || stage == .comparison) ? (counts[totalKey] as? NSNumber)?.uint64Value : nil)
        analysed = (counts["files_ready"] as? NSNumber)?.uint64Value ?? 0
        skipped = ((counts["files_failed"] as? NSNumber)?.uint64Value ?? 0)
            + ((counts["files_skipped"] as? NSNumber)?.uint64Value ?? (counts["files_excluded"] as? NSNumber)?.uint64Value ?? 0)
            + ((event["skipped"] as? NSNumber)?.uint64Value ?? 0)
        matches = ((counts["similar_pairs"] as? NSNumber)?.uint64Value ?? 0)
            + ((counts["exact_pairs"] as? NSNumber)?.uint64Value ?? 0)
        downloadedBytes = (event["downloaded_bytes"] as? NSNumber)?.uint64Value ?? 0
        let file = event["current_file"] as? [String: Any]
        currentName = file?["name"] as? String
        currentSize = (file?["bytes"] as? NSNumber)?.uint64Value ?? 0
        currentBytes = (event["file_bytes_read"] as? NSNumber)?.uint64Value ?? 0
        operation = event["operation"] as? String ?? ""
        if let list = event["downloads"] as? [String: Any] {
            hasDownloadTelemetry = true
            var seen = Set<UInt64>()
            downloads = (list["items"] as? [[String: Any]] ?? []).compactMap(SimilarityDownload.init)
                .filter { seen.insert($0.id).inserted }
            downloadCount = SimilarityDownload.count(list["total"])
            omittedDownloads = SimilarityDownload.count(list["omitted"])
            let rate = (list["speed"] as? NSNumber)?.doubleValue ?? 0
            downloadSpeed = rate.isFinite ? max(0, rate) : 0
            downloadForecastBytes = SimilarityDownload.count(list["forecast_bytes"])
            let horizon = (list["forecast_seconds"] as? NSNumber)?.doubleValue ?? 0
            downloadForecastSeconds = horizon.isFinite ? min(60, max(0, horizon)) : 0
        }
        bytesRead = (counts["bytes_read"] as? NSNumber)?.uint64Value ?? 0
        bytesHashed = (counts["bytes_hashed"] as? NSNumber)?.uint64Value ?? 0
        pairsCompared = (counts["pairs_compared"] as? NSNumber)?.uint64Value ?? 0
        scoresRetained = (counts["scores_retained"] as? NSNumber)?.uint64Value ?? 0
        vectorsEncoded = (counts["vectors_encoded"] as? NSNumber)?.uint64Value ?? 0
        cacheHits = (counts["cache_hits"] as? NSNumber)?.uint64Value ?? 0
        if let saved = event["session_statistics"] as? [String: Any] {
            vectorsEncoded = (saved["newly_analysed"] as? NSNumber)?.uint64Value ?? vectorsEncoded
            cacheHits = (saved["reused"] as? NSNumber)?.uint64Value ?? cacheHits
        }
        if let bytes = event["cloud_data"] as? [String: Any] {
            cloudBytesReady = (bytes["ready_bytes"] as? NSNumber)?.uint64Value
            cloudBytesTotal = (bytes["total_bytes"] as? NSNumber)?.uint64Value
            cloudByteInventoryComplete = bytes["inventory_complete"] as? Bool ?? false
            cloudOnDemand = bytes["on_demand"] as? Bool
            sampledOriginals = (bytes["sampled_files"] as? NSNumber)?.uint64Value
            sampledReceivedBytes = (bytes["sampled_received_bytes"] as? NSNumber)?.uint64Value
        }
        foundFiles = (counts["files_discovered"] as? NSNumber)?.uint64Value ?? (stage == .inventory ? completed : total ?? 0)
        activeFiles = (event["active"] as? NSNumber)?.uint64Value ?? 0
        unsupportedFiles = (counts["files_skipped"] as? NSNumber)?.uint64Value ?? 0
        failedFiles = ((counts["files_failed"] as? NSNumber)?.uint64Value ?? 0) + ((event["skipped"] as? NSNumber)?.uint64Value ?? 0)
        if let work = event["work"] as? [String: Any] {
            hasWorkPhases = true
            fetchingFiles = (work["fetching"] as? NSNumber)?.uint64Value ?? 0
            readingFiles = (work["reading"] as? NSNumber)?.uint64Value ?? 0
            hashingFiles = (work["hashing"] as? NSNumber)?.uint64Value
            encodingFiles = Self.cumulative((work["encoding"] as? NSNumber)?.uint64Value ?? 0, hashingFiles ?? 0)
            originalBytesRead = (work["original_bytes_read"] as? NSNumber)?.uint64Value
            waitingReadFiles = (work["waiting_read"] as? NSNumber)?.uint64Value
            acceleratorActive = (work["accelerator_active"] as? NSNumber)?.uint64Value ?? 0
            acceleratorLimit = (work["accelerator_limit"] as? NSNumber)?.uint64Value ?? 0
            waitingAcceleratorFiles = (work["waiting_accelerator"] as? NSNumber)?.uint64Value ?? 0
            waitingProcessingFiles = (work["waiting_worker"] as? NSNumber)?.uint64Value ?? 0
            waitingMemoryFiles = (work["waiting_memory"] as? NSNumber)?.uint64Value ?? 0
            waitingReuseFiles = (work["waiting_reuse"] as? NSNumber)?.uint64Value ?? 0
            waitingDownloadFiles = (work["waiting_download"] as? NSNumber)?.uint64Value ?? 0
            retryingDownloadFiles = (work["retrying_download"] as? NSNumber)?.uint64Value ?? 0
            downloadLimit = (work["download_limit"] as? NSNumber)?.uint64Value ?? 0
            readyFiles = (work["ready"] as? NSNumber)?.uint64Value ?? 0
            resolvingFiles = (work["resolving"] as? NSNumber)?.uint64Value ?? 0
            independentDownloads = work["independent_downloads"] as? Bool ?? false
            originalMemoryBytes = (work["original_memory_bytes"] as? NSNumber)?.uint64Value ?? 0
            originalMemoryLimit = (work["original_memory_limit"] as? NSNumber)?.uint64Value ?? 0
            retainedDownloadMinimum = (work["retained_download_minimum"] as? NSNumber)?.uint64Value ?? 0
            analysisMemoryLimit = (work["analysis_memory_limit"] as? NSNumber)?.uint64Value ?? 0
            analysisMemoryBytes = (work["analysis_memory_bytes"] as? NSNumber)?.uint64Value ?? 0
            memoryLimit = (work["memory_limit"] as? NSNumber)?.uint64Value
            analysisMemoryRequired = (work["analysis_memory_required"] as? NSNumber)?.uint64Value
            analysisMemoryForecast = (work["analysis_memory_forecast"] as? NSNumber)?.uint64Value
            analysisGrowthBytes = (work["analysis_growth_bytes"] as? NSNumber)?.uint64Value
            analysisTransferBytes = (work["analysis_transfer_bytes"] as? NSNumber)?.uint64Value
            stagingMemoryRequired = (work["staging_memory_required"] as? NSNumber)?.uint64Value
            stagingMemoryLimit = (work["staging_memory_limit"] as? NSNumber)?.uint64Value
            memoryScheduling = work["memory_scheduling"] as? Bool ?? false
            memoryPressure = (work["memory_pressure"] as? NSNumber)?.uint64Value
            workerLimit = (work["worker_limit"] as? NSNumber)?.uint64Value ?? 0
        }
        discoveryComplete = event["discovery_complete"] as? Bool ?? (total != nil || stage == .comparison || stage == .finishing)
    }
    var fraction: Double? {
        if stage == .checking { return nil }
        if usesCloudByteProgress, let ready = cloudBytesReady, let total = cloudBytesTotal, total > 0 {
            guard cloudByteInventoryComplete else { return nil }
            return min(1, Double(ready) / Double(total))
        }
        if stage == .analysing && !discoveryComplete { return nil }
        guard let total, total > 0 else { return nil }
        return min(1, max(0, Double(completed) / Double(total)))
    }
    var percentLabel: String? {
        fraction.map { "\(Int(($0 * 100).rounded(.down)))%" }
    }
    var completedLabel: String {
        let count = total.map { "\(completed.formatted()) of \($0.formatted())" } ?? completed.formatted()
        switch stage {
        case .checking:
            guard let folders = listingFoldersCompleted, let discovered = listingFoldersDiscovered,
                  let pages = listingPagesCompleted else { return "Looking for added, changed or removed files" }
            return "\(folders.formatted()) of \(discovered.formatted()) folders checked · \(pages.formatted()) pages · \((listingFilesFound ?? 0).formatted()) files found"
        case .inventory: return "\(count) files found"
        case .downloading: return "\(count) files processed"
        case .analysing: return discoveryComplete ? "\(count) items processed" : "\(foundFiles.formatted()) found · \(completed.formatted()) processed"
        case .comparison: return "\(count) pairs checked"
        case .grouping: return "\(count) match entries grouped"
        case .finishing: return "Saving the report and clearing temporary files"
        }
    }
    var currentOperation: String {
        switch operation {
        case "fetching": return "Fetching this original"
        case "downloading": return "Downloading temporary copy"
        case "decoding": return "Decoding and analysing content"
        case "hashing": return "Checking identical content"
        default: return "Reading file content"
        }
    }
    static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
    var currentByteLabel: String {
        guard currentSize > 0 else { return Self.bytes(currentBytes) }
        return "\(Self.bytes(min(currentBytes, currentSize))) of \(Self.bytes(currentSize))"
    }
}

/// Each source owns its process and published state. Progress never causes
/// DownloaderModel to invalidate the Browser's potentially large outline.
@MainActor
final class SimilarityScanModel: ObservableObject {
    let source: SimilaritySource
    let activity: FinderTaskActivityStore
    @Published var localURLs: [URL] = []
    @Published var cloudRoots: [SimilarityCloudRoot] = []
    static var supportedFamilies: Set<String> { visualSimilarityAvailable ? ["text", "image", "audio", "video"] : ["text", "audio"] }
    @Published var families: Set<String> = SimilarityScanModel.supportedFamilies
    @Published private(set) var sessionID = UUID()
    private var resetWhenFinished = false
    @Published var threshold = 0.9
    @Published var exactDuplicates = true
    @Published var photosPreviewsSupported = false
    @Published private(set) var photosUsePreviews = true
    var usesPhotosPreviews: Bool {
        nativeScope?.drive == .photos && photosPreviewsSupported && photosUsePreviews && !externalDuplicatesOnly
    }
    var hasRemoteSources: Bool {
        source == .cloud || nativeScope?.drive == .photos || acrossDriveScopes?.contains(where: { $0.drive == .pikpak || $0.drive == .photos }) == true
    }
    var canChoosePhotosMode: Bool { !isRunning && !isPaused && savedSession == nil && report == nil }
    func choosePhotosPreviews(_ value: Bool) {
        guard canChoosePhotosMode else { return }
        photosUsePreviews = value
        if usesPhotosPreviews { exactDuplicates = false }
    }
    func configurePhotosPreviews(supported: Bool, enabled: Bool) {
        photosPreviewsSupported = supported; photosUsePreviews = enabled
    }
    @Published private(set) var isRunning = false { didSet { updateSleepPrevention(); if oldValue != isRunning { recordProcessingSpeed(); onRunningChanged() } } }
    @Published private(set) var isCancelling = false { didSet { updateSleepPrevention() } }
    @Published private(set) var isFinishing = false { didSet { updateSleepPrevention() } }
    @Published private(set) var isPaused = false { didSet { updateSleepPrevention() } }
    @Published private(set) var isPausing = false { didSet { updateSleepPrevention() } }
    @Published private(set) var interrupted = false
    @Published private(set) var waitingForNetwork = false
    @Published private(set) var inventoryWaitReason: String?
    @Published private(set) var recoverableSessions: [SimilaritySavedSession] = []
    private(set) var savedSession: SimilaritySavedSession?
    var nativeScope: SimilarityNativeScope?
    var acrossDriveScopes: [SimilarityAcrossDriveScope]?
    private var preserveOnClose = false
    private var pauseReason: String?
    private var manualResumeRequired = false
    private var cancelRequested = false
    @Published private(set) var processingLabel = ""
    @Published private(set) var processingBackend: TaskResourceProcessing.Backend?
    var resourceProcessing: TaskResourceProcessing? {
        processingBackend.map { .init(backend: $0, activeJobs: progress.acceleratorActive, jobLimit: progress.acceleratorLimit) }
    }
    @Published private(set) var message = "Ready to scan"
    @Published private(set) var detail = ""
    @Published private(set) var fraction: Double?
    @Published private(set) var progress = SimilarityScanProgress()
    @Published private(set) var processingSpeed = DownloadSpeedSnapshot()
    private var processingHistory = SimilarityProcessingHistory()
    @Published private(set) var readSpeed: Double = 0
    private var readHistory = SimilarityReadHistory()
    private var processingSpeedTask: Task<Void, Never>?
    @Published private(set) var startedAt: Date?
    @Published private var scanClock = SimilarityScanClock()
    private var lastClockSave = Date.distantPast
    private var runProgressBaseline: SimilarityScanProgress?
    private var helperRestoresReport = false
    private var liveFoundFiles: UInt64 = 0
    private var liveDiscoveryComplete = false
    @Published private(set) var isRestoringProgress = false
    @Published private(set) var runResources: SimilarityResourceLimits?
    var externalTitle: String?
    var externalDuplicatesOnly = false
    @Published var externalScopeNames: [String] = []
    var prepareExternalScope: (() async throws -> [URL])?
    var inventoryExternalSources: (() async throws -> [SimilarityExternalSource])?
    var streamExternalSources: ((@escaping (SimilarityExternalSource) async throws -> Void) async throws -> Void)?
    private var inventoryTask: Task<Void, Never>?
    private var inventoryGeneration = UUID()
    var resolveExternalSource: ((String, URL, @escaping CloudDriveProgressHandler) async throws -> URL)?
    var resolveExternalMemorySource: ((String, URL, UInt64, @escaping CloudDriveProgressHandler) async throws -> URL)?
    var cleanupExternalScope: () -> Void = {}
    // Detach a specific run's directory now; remove it only after its provider
    // writers stop. A later Resume must never have its directory removed.
    var takeExternalScopeCleanup: (() -> (() -> Void)?)?
    var transformExternalReport: ((SimilarityReport) -> SimilarityReport)?
    private var preparationTask: Task<Void, Never>? { didSet { updateSleepPrevention() } }
    private var externalSources: [SimilarityExternalSource] = []
    private var externalSourceIDs: Set<String> = []
    private var sourceTasks: [String: Task<Void, Never>] = [:]
    private var providerProgress = SimilarityProviderProgress()
    private var sourceRequestRoot: URL?
    @Published private(set) var report: SimilarityReport?
    @Published var error: String?
    private var process: Process? { didSet { updateSleepPrevention() } }
    private let sleepPrevention: DownloadSleepPrevention
    private var sleepWorkDepth = 0 { didSet { updateSleepPrevention() } }
    private var retiringProviderWork = 0 { didSet { updateSleepPrevention() } }
    private var generation = UUID()
    private var scopes: [URL] = []
    var onRunningChanged: () -> Void = {}
    var onSessionReset: () -> Void = {}
    let results = SimilarityResultsModel()
    private(set) var resultConfiguration: SimilarityConfiguration?

    /// Delays before each automatic attempt to recover an interrupted scan.
    /// They grow so a drive that is genuinely away is not hammered, and the
    /// last one is long enough to outlast a brief outage or a token rotation.
    static let autoResumeDelays = AutomaticRecovery.delays
    var autoResumeDelays = SimilarityScanModel.autoResumeDelays
    /// Supplied by the coordinator, which owns the account configuration and
    /// the drive reconnection needed to restart a saved scan.
    var performAutoResume: (() -> Void)?
    @Published private(set) var autoResumeAttempt = 0
    @Published private(set) var autoResumeDeadline: Date?
    private var autoResumeTask: Task<Void, Never>?
    private var autoResumeProgressBaseline: UInt64 = 0
    var isAutoResuming: Bool { autoResumeDeadline != nil }
    /// Work the helper has finished. Any increase proves a resumed run is
    /// making headway, which returns the recovery budget to full.
    var completedUnits: UInt64 {
        progress.analysed + progress.unsupportedFiles + progress.failedFiles + progress.pairsCompared
    }

    init(source: SimilaritySource, activity: FinderTaskActivityStore, sleepPrevention: DownloadSleepPrevention? = nil) {
        self.source = source; self.activity = activity
        self.sleepPrevention = sleepPrevention ?? DownloadSleepPrevention(fullWake: true,
            reason: "MyCloudDriver is finding similar files or checking duplicates")
    }
    private func updateSleepPrevention() {
        // A paused live helper owns volatile originals. After helper exit,
        // retain protection until pipes, saved results and providers drain.
        // A durable paused checkpoint without live work may sleep normally.
        sleepPrevention.setActive(isRunning || isPausing || isCancelling || isFinishing || process != nil
            || preparationTask != nil || retainsOriginalsInRAM || sleepWorkDepth > 0 || retiringProviderWork > 0)
    }
    func elapsedSeconds(at date: Date) -> TimeInterval { scanClock.elapsed(at: date) }

    private func recordProcessingSpeed() {
        let active = isRunning && !isPausing && !isCancelling
        let now = Date()
        if readHistory.observe(progress, running: active, restoring: isRestoringProgress, at: now) {
            readSpeed = readHistory.bytesPerSecond
        }
        if processingHistory.observe(progress, running: active, restoring: isRestoringProgress, at: now) {
            processingSpeed = processingHistory.snapshot(for: progress)
        }
        if active, processingSpeedTask == nil {
            processingSpeedTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                    guard let self else { return }
                    self.recordProcessingSpeed()
                }
            }
        } else if !active { processingSpeedTask?.cancel(); processingSpeedTask = nil }
    }

    /// An interruption the user did not ask for recovers on its own. Deliberate
    /// pauses, cancellation and shutdown leave `interrupted` false and never
    /// reach here, so intent is preserved without a separate flag.
    func scheduleAutoResume() {
        guard !manualResumeRequired, performAutoResume != nil, savedSession != nil, isPaused, interrupted,
              !cancelRequested, !preserveOnClose else { return }
        let delay = AutomaticRecovery.delay(attempt: autoResumeAttempt, schedule: autoResumeDelays)
        autoResumeAttempt = AutomaticRecovery.nextAttempt(autoResumeAttempt)
        autoResumeDeadline = Date().addingTimeInterval(delay)
        autoResumeTask?.cancel()
        autoResumeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.autoResumeTask = nil; self.autoResumeDeadline = nil
            guard self.isPaused, self.interrupted, self.savedSession != nil, !self.cancelRequested else { return }
            self.performAutoResume?()
        }
    }

    /// Any user action on the scan, and every finished run, ends recovery.
    /// Repeated faults keep their backoff until useful progress is made.
    func cancelAutoResume(resettingAttempts: Bool = false) {
        autoResumeTask?.cancel(); autoResumeTask = nil; autoResumeDeadline = nil
        if resettingAttempts { autoResumeAttempt = 0 }
    }

    private func checkpointProgress(force: Bool = false) {
        let date = Date()
        let savedProgress = savedSession?.progress
        let changedWhilePaused = (isPaused || isPausing) && (savedProgress == nil
            || savedProgress?.analysed != progress.analysed || savedProgress?.unsupportedFiles != progress.unsupportedFiles
            || savedProgress?.failedFiles != progress.failedFiles || savedProgress?.scoresRetained != progress.scoresRetained
            || savedProgress?.downloadedBytes != progress.downloadedBytes || savedProgress?.bytesRead != progress.bytesRead
            || savedProgress?.bytesHashed != progress.bytesHashed || savedProgress?.pairsCompared != progress.pairsCompared
            || savedProgress?.vectorsEncoded != progress.vectorsEncoded || savedProgress?.cacheHits != progress.cacheHits
            || savedProgress?.originalMemoryBytes != progress.originalMemoryBytes || savedProgress?.analysisMemoryBytes != progress.analysisMemoryBytes
            || savedProgress?.downloadCount != progress.downloadCount)
        guard force || (!preserveOnClose && (isRunning || isPaused || isPausing)
                && (changedWhilePaused || date.timeIntervalSince(lastClockSave) >= 5)),
              var saved = savedSession, let configuration = resultConfiguration else { return }
        saved.activeElapsedSeconds = scanClock.elapsed(at: date); saved.updatedAt = date
        saved.progress = progress
        lastClockSave = date
        do { try SimilaritySessionStore.save(saved, configuration: configuration); savedSession = saved }
        catch { self.error = "Could not save scan progress. Check available storage before closing the app." }
    }
    var retainsOriginalsInRAM: Bool {
        #if FINDER_WORKSPACE_TESTS
        if fixtureRetainsOriginalsInRAM { return isPaused || isPausing }
        #endif
        return process?.isRunning == true && (isPaused || isPausing)
    }
    var processIdentifier: Int32? { process.flatMap { $0.isRunning ? $0.processIdentifier : nil } }
    var scopeLabel: String {
        let names = externalTitle != nil ? externalScopeNames : source == .local ? localURLs.map(\.lastPathComponent) : cloudRoots.map { $0.path == "/" ? "All PikPak files" : $0.path }
        return names.isEmpty ? "No scope selected" : names.count == 1 ? names[0] : "\(names.count) selected locations"
    }
    var canStart: Bool {
        !isRunning && !isPaused && (externalDuplicatesOnly || !families.isEmpty) && (externalTitle != nil ? !externalScopeNames.isEmpty : source == .local ? !localURLs.isEmpty : !cloudRoots.isEmpty)
            && threshold.isFinite && (0.05...1).contains(threshold)
    }
    static func mediaTool(_ name: String) -> String? {
        ["/opt/homebrew/bin/", "/usr/local/bin/"].map { $0 + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    static var visualSimilarityAvailable: Bool {
        // The pinned ONNX Runtime dylib has LC_BUILD_VERSION minos 14.0.
        // Keep the rest of the app and text/audio scans usable on macOS 13.
        if #available(macOS 14, *) { return true }
        return false
    }

    func chooseLocalFiles() {
        guard !isRunning else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose files or folders to compare"
        panel.prompt = "Add to Scan"
        panel.canChooseFiles = true; panel.canChooseDirectories = true; panel.allowsMultipleSelection = true
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in
                guard let self, !self.isRunning else { return }
                let existing = Set(self.localURLs.map(\.standardizedFileURL))
                self.localURLs.append(contentsOf: panel.urls.filter { !existing.contains($0.standardizedFileURL) })
                self.error = nil
            }
        }
    }

    func start(_ configuration: SimilarityConfiguration, resuming session: SimilaritySavedSession? = nil) {
        guard !isRunning, session != nil || canStart else { return }
        sleepWorkDepth += 1
        defer { sleepWorkDepth -= 1 }
        let resumesCurrentSession = session != nil && session?.id == savedSession?.id
        manualResumeRequired = false
        if var session, session.id == savedSession?.id, let child = process, child.isRunning {
            guard let previous = resultConfiguration, SimilaritySessionStore.sameAccount(previous, configuration) else {
                error = "Switch back to the account that started this scan, then resume."; return
            }
            do {
                session.state = "running"; session.updatedAt = Date()
                session.activeElapsedSeconds = scanClock.elapsed(at: session.updatedAt)
                session.progress = progress
                try SimilaritySessionStore.save(session, configuration: configuration)
                try SimilaritySessionStore.removePause(configuration, id: session.id)
                scanClock.resume(at: Date()); lastClockSave = Date()
                savedSession = session; isPaused = false; isPausing = false; isRunning = true
                isCancelling = false; interrupted = false; cancelRequested = false; pauseReason = nil; error = nil
                autoResumeDeadline = nil; autoResumeProgressBaseline = completedUnits
                message = "Resuming retained downloads and analysis…"
                activity.begin(source.taskKind, scope: scopeLabel, message: message)
            } catch { self.error = "Could not resume this scan. Its downloaded data is still retained in RAM." }
            return
        }
        if let session, session.id != savedSession?.id, SimilaritySessionStore.isClaimed(configuration,id:session.id) {
            error = "This scan is already open in another window."; return
        }
        if let session {
            localURLs=session.localURLs; cloudRoots=session.cloudRoots; nativeScope=session.nativeScope
            acrossDriveScopes = session.acrossDriveScopes
            families=session.families; threshold=session.threshold; exactDuplicates=session.exactDuplicates
            photosUsePreviews = session.nativeScope?.photosUsePreviews ?? false
            savedSession=session
        } else if let savedSession, let previous=resultConfiguration {
            SimilaritySessionStore.release(previous,id:savedSession.id)
            self.savedSession=nil
        }
        let previews = usesPhotosPreviews
        if session == nil { nativeScope?.photosUsePreviews = previews }
        if usesPhotosPreviews { exactDuplicates = false }
        providerProgress = SimilarityProviderProgress()
        startedAt = session?.startedAt ?? Date()
        scanClock = SimilarityScanClock(elapsedSeconds: session?.elapsedSeconds ?? 0)
        runProgressBaseline = session?.progress
        helperRestoresReport = false; liveFoundFiles = 0; liveDiscoveryComplete = false
        isRestoringProgress = runProgressBaseline != nil
        progress = runProgressBaseline?.afterHelperRestart() ?? SimilarityScanProgress()
        if !resumesCurrentSession { processingHistory = SimilarityProcessingHistory() }
        processingHistory.restart(progress, at: Date())
        processingSpeed = processingHistory.snapshot(for: progress)
        readHistory = SimilarityReadHistory(); readSpeed = 0
        resultConfiguration = configuration; results.reset()
        // Saved RAM preferences are migrated to the automatic governor.
        // Keep only the checkpoint's backend so cached vectors stay compatible.
        runResources = SimilarityResourceSettings.current.limits
        // Resource amounts may change on Resume; the encoding backend is
        // pinned by the original checkpoint to keep cached vectors compatible.
        if let session { runResources?.acceleration = session.resources.acceleration ?? .cpu }
        generation = UUID()
        cancelRequested=false; isFinishing=false; processingLabel=""; processingBackend=nil
        isPaused=false; isPausing=false; interrupted=false; waitingForNetwork=false; inventoryWaitReason=nil; pauseReason=nil; preserveOnClose=false
        // The countdown is over; the attempt count stays until this run proves
        // itself by finishing work, so a crash loop still reaches its limit.
        autoResumeDeadline = nil
        autoResumeProgressBaseline = completedUnits
        if !externalDuplicatesOnly {
            var saved=session ?? SimilaritySavedSession(id:UUID().uuidString,source:source,localURLs:localURLs,
                cloudRoots:cloudRoots,nativeScope:nativeScope,scope:scopeLabel,families:families,threshold:threshold,
                exactDuplicates:exactDuplicates,resources:runResources!,state:"running",startedAt:startedAt!,updatedAt:Date())
            saved.acrossDriveScopes = acrossDriveScopes
            saved.state="running"; saved.updatedAt=Date(); saved.resources=runResources!
            saved.activeElapsedSeconds = scanClock.elapsed(at: saved.updatedAt)
            saved.progress = progress
            do {
                try SimilaritySessionStore.save(saved,configuration:configuration)
                try SimilaritySessionStore.removeFinish(configuration,id:saved.id)
                try SimilaritySessionStore.removePause(configuration,id:saved.id)
                SimilaritySessionStore.claim(configuration,id:saved.id); savedSession=saved
                recoverableSessions.removeAll { $0.id == saved.id }
            } catch { self.error="Could not save this scan for recovery. Check available storage and try again."; isPaused=session != nil; return }
        }
        scanClock.resume(at: Date()); lastClockSave = Date()
        externalSources = []
        externalSourceIDs = []
        if streamExternalSources != nil && !externalDuplicatesOnly { localURLs = []; launch(configuration); return }
        if let inventoryExternalSources, !externalDuplicatesOnly {
            isRunning = true; isCancelling = false; report = nil; error = nil
            message = "Finding \(externalTitle ?? "drive") files…"; detail = scopeLabel
            if runProgressBaseline == nil { progress = SimilarityScanProgress() }
            activity.begin(source.taskKind, scope: scopeLabel, message: message)
            let preparationID = generation
            preparationTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let sources = try await inventoryExternalSources()
                    guard self.generation == preparationID else { return }
                    try Task.checkCancellation()
                    guard !sources.isEmpty else {
                        self.preparationTask = nil
                        self.finish(.init(source: self.source, scope: self.externalScopeNames, status: "completed",
                            threshold: self.threshold, scannedFiles: 0, analysedFiles: 0, skippedFiles: 0,
                            downloadedBytes: 0, totalGroups: 0, groups: [], issues: [], truncated: false,
                            coverage: "No visible files were found in this scope.", elapsedSeconds: self.elapsedSeconds(at: Date()), files: []),
                            diagnostic: "", exitCode: 0)
                        return
                    }
                    self.externalSources = sources; self.localURLs = []
                    self.externalSourceIDs = Set(sources.map(\.id))
                    self.preparationTask = nil; self.launch(configuration)
                } catch {
                    guard self.generation == preparationID else { return }
                    self.isCancelling = self.isCancelling || (error is CancellationError && !self.isPausing)
                    self.preparationTask = nil; self.finish(nil, diagnostic: error.localizedDescription, exitCode: 1)
                }
            }
            return
        }
        guard let prepareExternalScope else { launch(configuration); return }
        isRunning = true; isCancelling = false; report = nil; error = nil
        message = "Preparing \(externalTitle ?? "drive") files…"; detail = scopeLabel
        progress = SimilarityScanProgress(event: ["stage":"downloading"])
        activity.begin(source.taskKind, scope: scopeLabel, message: message)
        let preparationID = generation
        preparationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let urls = try await prepareExternalScope()
                guard self.generation == preparationID else { return }
                try Task.checkCancellation()
                guard !urls.isEmpty else { throw CloudDriveError.message("No readable files were found in this scope.") }
                self.localURLs = urls
                if self.externalDuplicatesOnly {
                    // Apple Photos hashes temporary exports, whose paths mean nothing the next time.
                    let report = try await NativeDriveDuplicates.scan(urls) { [weak self] event in
                        Task { @MainActor in
                            guard let self, self.isRunning, !self.isCancelling else { return }; self.receive(event)
                        }
                    }
                    guard self.generation == preparationID else { return }
                    self.preparationTask = nil; self.finish(report, diagnostic: "", exitCode: 0)
                } else { self.preparationTask = nil; self.launch(configuration) }
            } catch {
                guard self.generation == preparationID else { return }
                self.isCancelling = self.isCancelling || (error is CancellationError && !self.isPausing)
                self.preparationTask = nil
                self.finish(nil, diagnostic: error.localizedDescription, exitCode: 1)
            }
        }
    }

    func externalProgress(_ value: CloudDriveProgress) {
        guard isRunning, !isCancelling else { return }
        let stage = inventoryExternalSources != nil && !externalDuplicatesOnly ? "inventory" : value.total > 0 ? "downloading" : "inventory"
        var event: [String: Any] = ["event":"progress", "stage":stage, "completed":value.completed,
            "current_file":["name":value.message, "bytes":value.fileSize], "file_bytes_read":value.bytes, "operation":"downloading"]
        if value.total > 0 { event["total"] = value.total }
        receive(event, preparing: true)
    }

    private func launch(_ configuration: SimilarityConfiguration) {
        let runID = UUID()
        let directory = configuration.temporaryDirectory.appendingPathComponent(runID.uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: configuration.temporaryDirectory.path)
            let reportURL = directory.appendingPathComponent("report.json")
            let stream = externalDuplicatesOnly ? nil : streamExternalSources
            let streamURL = stream == nil ? nil : directory.appendingPathComponent("inventory.jsonl")
            let writer = try streamURL.map { try SimilarityInventoryWriter(url: $0) }
            let request = SimilarityRequest(checkpointId:savedSession?.id,parentPid:ProcessInfo.processInfo.processIdentifier,
                source: source, localPaths: source == .local ? localURLs.map(\.path) : [],
                cloudItems: source == .cloud || acrossDriveScopes != nil ? cloudRoots : [], externalSources: externalSources, externalSourceStream: streamURL?.path,
                families: families.sorted(), threshold: threshold,
                exactDuplicates: exactDuplicates,
                dataDir: configuration.dataDirectory.path, modelDir: configuration.models.path,
                tempDir: directory.appendingPathComponent("copies", isDirectory: true).path,
                reportPath: reportURL.path,
                runtime: SimilarityRuntime(workerPath: configuration.worker.path, ffmpegPath: Self.mediaTool("ffmpeg"),
                    ffprobePath: Self.mediaTool("ffprobe"), onnxruntimePath: configuration.models.appendingPathComponent("runtime/libonnxruntime.dylib").path,
                    pdfiumPath: configuration.models.appendingPathComponent("runtime/libpdfium.dylib").path),
                resources: runResources ?? SimilarityResourceSettings.current.limits)
            let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
            let requestURL = directory.appendingPathComponent("request.json")
            try encoder.encode(request).write(to: requestURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestURL.path)
            let child = Process(); let output = Pipe(); let errors = Pipe()
            child.executableURL = configuration.executable
            child.currentDirectoryURL = directory
            child.arguments = ["similarity-scan", "--request-file", requestURL.path]
            child.environment = configuration.environment
            child.standardOutput = output; child.standardError = errors; child.standardInput = FileHandle.nullDevice
            generation = runID; process = child
            sourceRequestRoot = directory.appendingPathComponent("copies", isDirectory: true)
            scopes = localURLs.filter { $0.startAccessingSecurityScopedResource() }
            isRunning = true; isCancelling = false; report = nil; error = nil; fraction = nil
            if runProgressBaseline == nil {
                progress = externalTitle == nil ? SimilarityScanProgress() : SimilarityScanProgress(event: ["stage":"analysing"])
            }
            message = "Starting \(externalTitle ?? source.title) scan…"; detail = ""
            activity.begin(source.taskKind, scope: scopeLabel, message: message)
            let reader = SimilarityProcessReader()
            reader.start(output: output, errors: errors) { [weak self] event in
                Task { @MainActor in
                    // Pipes can deliver the final counters after the process
                    // exits. Keep those events until finish() drains the reader.
                    guard let self, self.generation == runID, self.process != nil, !self.isCancelling else { return }
                    self.receive(event)
                }
            }
            let runSleepPrevention = sleepPrevention
            child.terminationHandler = { [weak self, runSleepPrevention] child in
                let exitCode = child.terminationStatus
                child.terminationHandler = nil
                // Wait for both pipes and decode the report away from the GUI.
                // The run retains its activity even if its model/window closes.
                reader.finish(reportURL: reportURL) { [weak self, runSleepPrevention] report, diagnostic in
                    Task { @MainActor [weak self, runSleepPrevention] in
                        guard let self else { runSleepPrevention.setActive(false); return }
                        guard self.generation == runID else { self.updateSleepPrevention(); return }
                        self.finish(report, diagnostic: diagnostic, exitCode: exitCode, temporaryDirectory: directory)
                    }
                }
            }
            do { try child.run() }
            catch {
                child.terminationHandler = nil
                try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
                throw error
            }
            if let stream, let writer { beginInventory(stream, writer: writer, runID: runID) }
            try? output.fileHandleForWriting.close(); try? errors.fileHandleForWriting.close()
        } catch {
            try? FileManager.default.removeItem(at: directory)
            finish(nil, diagnostic: error.localizedDescription, exitCode: 1)
        }
    }

    private func beginInventory(_ stream: @escaping (@escaping (SimilarityExternalSource) async throws -> Void) async throws -> Void,
                                writer: SimilarityInventoryWriter, runID: UUID) {
        let previous = inventoryTask
        let inventoryID = UUID(); inventoryGeneration = inventoryID
        inventoryTask = Task { [weak self] in
            await previous?.value
            guard let self, self.generation == runID, self.process?.isRunning == true, !Task.isCancelled else {
                await writer.close(); return
            }
            self.externalSourceIDs = []
            var emittedIDs = Set<String>()
            var retryAttempt = 0
            while !Task.isCancelled {
              do {
                try await stream { [weak self] file in
                    try Task.checkCancellation()
                    guard let self else { throw CancellationError() }
                    while self.generation == runID && (self.isPaused || self.isPausing) && !self.isCancelling {
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                    guard self.generation == runID, self.process?.isRunning == true, !self.isCancelling else { throw CancellationError() }
                    if self.inventoryWaitReason != nil {
                        self.inventoryWaitReason = nil; self.waitingForNetwork = false
                    }
                    guard !emittedIDs.contains(file.id) else { return }
                    self.externalSourceIDs.insert(file.id)
                    try await writer.append(file)
                    emittedIDs.insert(file.id)
                }
                try Task.checkCancellation()
                try await writer.finish()
                self.inventoryWaitReason = nil
                self.waitingForNetwork = false
                break
              } catch {
                if Task.isCancelled || self.isCancelling || self.generation != runID || self.process?.isRunning != true {
                    await writer.close(); break
                }
                if TransferFailure.isRetryable(error) {
                    self.waitingForNetwork = true
                    if case .waiting(let reason) = error as? CloudDriveError {
                        self.inventoryWaitReason = reason
                    } else {
                        self.inventoryWaitReason = "File discovery is waiting for the drive. Completed analysis is saved."
                    }
                    let seconds = min(30, 1 << min(retryAttempt, 5))
                    retryAttempt = AutomaticRecovery.nextAttempt(retryAttempt)
                    do { try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000) }
                    catch { await writer.close(); break }
                    // Repeat discovery with stable IDs; already queued
                    // files are filtered by emittedIDs above.
                } else if self.savedSession != nil {
                    self.pause(reason: "The drive could not finish finding files. Check its connection or access, then resume.")
                    await writer.close(); break
                } else {
                    do { try await writer.finish(error: error.localizedDescription) }
                    catch { self.error = "Could not send the scan inventory. Check available disk space and retry."; self.cancel() }
                    break
                }
              }
            }
            if self.inventoryGeneration == inventoryID { self.inventoryTask = nil }
        }
    }

    private func refreshInventory(_ event: [String: Any]) {
        guard let stream = streamExternalSources, let root = sourceRequestRoot,
              let url = SimilarityInventoryWriter.refreshURL(event: event, sourceRoot: root) else {
            pause(reason: "The drive could not verify file changes. Resume to retry."); return
        }
        do { beginInventory(stream, writer: try SimilarityInventoryWriter(url: url), runID: generation) }
        catch { pause(reason: "Could not save the current file inventory. Check available storage, then resume.") }
    }

    private func receive(_ event: [String: Any], preparing: Bool = false) {
        defer { checkpointProgress(force: event["event"] as? String == "pause_state"); recordProcessingSpeed() }
        if event["event"] as? String == "refresh_inventory" { if !isFinishing { refreshInventory(event) }; return }
        if event["event"] as? String == "inventory_check" {
            isRestoringProgress = false
            progress = progress.afterHelperRestart(); progress.stage = .checking
            progress.total = nil; progress.discoveryComplete = false
            updateProgressStatus(); return
        }
        if event["event"] as? String == "discovery_listing" {
            progress.applyListing(event)
            updateProgressStatus(); return
        }
        if event["event"] as? String == "inventory_changed" {
            let count = (event["total"] as? NSNumber)?.uint64Value ?? 0
            let traffic = progress.downloadedBytes
            progress = SimilarityScanProgress(); progress.stage = .analysing
            progress.downloadedBytes = traffic; progress.foundFiles = count; progress.total = count
            progress.discoveryComplete = true
            liveFoundFiles = count; liveDiscoveryComplete = true; isRestoringProgress = false
            updateProgressStatus(); return
        }
        if event["event"] as? String == "restored_inventory" {
            helperRestoresReport = true; isRestoringProgress = false; return
        }
        if event["event"] as? String == "pause_state" {
            guard event["paused"] as? Bool == true, isPausing || isPaused else { return }
            isPaused = true; isPausing = false; isRunning = false; interrupted = !manualResumeRequired && pauseReason != nil
            message = cancelRequested ? "Scan cancelled · downloads retained" : pauseReason ?? "Scan paused · downloads retained"
            detail = "Partial downloads and queued originals stay in RAM. Resume continues this scan."
            if cancelRequested { savedSession?.state = "cancelled" }
            if let saved = savedSession, let configuration = resultConfiguration { try? SimilaritySessionStore.save(saved, configuration: configuration) }
            activity.finish(source.taskKind, state: cancelRequested ? .cancelled : .paused, message: message, detail: detail)
            if interrupted { scheduleAutoResume() }
            return
        }
        if event["event"] as? String == "resources_rejected" {
            scanClock.pause(at: Date())
            isPaused = true; isPausing = false; isRunning = false
            message = "Scan paused · downloads retained"
            error = event["message"] as? String
            if let configuration = resultConfiguration, var saved = savedSession {
                saved.resources.memoryBytes = progress.analysisMemoryLimit + progress.originalMemoryLimit
                saved.resources.downloadMemoryBytes = progress.originalMemoryLimit
                saved.state = "paused"; saved.updatedAt = Date()
                saved.activeElapsedSeconds = scanClock.elapsed(at: saved.updatedAt)
                savedSession = saved; runResources = saved.resources
                try? SimilaritySessionStore.save(saved, configuration: configuration)
                try? SimilaritySessionStore.updateLiveResources(saved.resources, configuration: configuration, id: saved.id)
            }
            activity.finish(source.taskKind, state: .paused, message: message, detail: error)
            return
        }
        if event["event"] as? String == "acceleration" {
            processingLabel=event["message"] as? String ?? ""
            processingBackend=(event["backend"] as? String).flatMap(TaskResourceProcessing.Backend.init(rawValue:))
            if event["backend"] as? String == "checking" { message=processingLabel; activity.update(source.taskKind,message:message) }
            return
        }
        if event["event"] as? String == "interrupted" {
            if event["automatic_resume"] as? Bool == false { manualResumeRequired = true }
            pause(reason:event["reason"] as? String ?? "The drive needs attention. Reconnect it, then resume."); return
        }
        if event["event"] as? String == "network_wait" {
            waitingForNetwork=event["waiting"] as? Bool == true; return
        }
        if event["event"] as? String == "resolve_source" { resolveSource(event); return }
        if event["event"] as? String == "discovery" {
            if progress.stage == .checking { return }
            liveFoundFiles = max(liveFoundFiles, (event["found"] as? NSNumber)?.uint64Value ?? 0)
            liveDiscoveryComplete = liveDiscoveryComplete || event["complete"] as? Bool == true
            progress.foundFiles = isRestoringProgress ? max(progress.foundFiles, liveFoundFiles) : liveFoundFiles
            progress.discoveryComplete = liveDiscoveryComplete
            if !externalDuplicatesOnly && progress.stage == .inventory { progress.stage = .analysing }
            if progress.stage == .analysing && progress.discoveryComplete { progress.total = progress.foundFiles }
            updateProgressStatus(); return
        }
        guard event["event"] as? String == "progress" else { return }
        var event = event
        if externalTitle != nil && !preparing && event["stage"] as? String == "inventory" { event["stage"] = "analysing" }
        var next = SimilarityScanProgress(event: event)
        next.listingFoldersDiscovered = progress.listingFoldersDiscovered
        next.listingFoldersCompleted = progress.listingFoldersCompleted
        next.listingFoldersPending = progress.listingFoldersPending
        next.listingPagesCompleted = progress.listingPagesCompleted
        next.listingFilesFound = progress.listingFilesFound
        liveFoundFiles = max(liveFoundFiles, next.foundFiles)
        liveDiscoveryComplete = liveDiscoveryComplete || next.discoveryComplete
        next.foundFiles = liveFoundFiles
        next.discoveryComplete = liveDiscoveryComplete
        if next.stage == .analysing && next.discoveryComplete { next.total = next.foundFiles }
        if event["active"] == nil && next.stage == .analysing { next.activeFiles = progress.activeFiles }
        let base = runProgressBaseline ?? SimilarityScanProgress()
        next.downloadedBytes = event["downloaded_bytes"] == nil ? progress.downloadedBytes
            : helperRestoresReport ? max(base.downloadedBytes, next.downloadedBytes)
            : SimilarityScanProgress.cumulative(base.downloadedBytes, next.downloadedBytes)
        let counts = event["counts"] as? [String: Any] ?? [:]
        next.bytesRead = counts["bytes_read"] == nil ? progress.bytesRead
            : helperRestoresReport ? max(base.bytesRead, next.bytesRead) : SimilarityScanProgress.cumulative(base.bytesRead, next.bytesRead)
        next.bytesHashed = counts["bytes_hashed"] == nil ? progress.bytesHashed
            : helperRestoresReport ? max(base.bytesHashed, next.bytesHashed) : SimilarityScanProgress.cumulative(base.bytesHashed, next.bytesHashed)
        if isRestoringProgress {
            let savedCount = base.analysed + base.unsupportedFiles + base.failedFiles
            let currentCount = next.analysed + next.unsupportedFiles + next.failedFiles
            if currentCount >= savedCount || [.comparison, .grouping, .finishing].contains(next.stage) {
                isRestoringProgress = false
            } else { next.restoreSummary(from: base) }
        }
        providerProgress.apply(to: &next.downloads, photos: nativeScope?.drive == .photos)
        progress = next
        // Headway proves the fault that interrupted this scan has passed, so a
        // long run that hiccups occasionally never exhausts its recovery budget.
        if autoResumeAttempt > 0 && completedUnits > autoResumeProgressBaseline { autoResumeAttempt = 0 }
        updateProgressStatus()
    }
    func recordDiscovery(found: Int, complete: Bool = false) {
        guard isRunning, !isCancelling, !isFinishing else { return }
        receive(["event":"discovery", "found":found, "complete":complete])
    }
    private func updateProgressStatus() {
        guard !isPaused, !isPausing else { return }
        message = isFinishing ? (progress.stage == .comparison || progress.stage == .finishing ? "Preparing report…" : "Finishing current analysis…")
            : isRestoringProgress ? "Restoring saved progress…" : progress.displayTitle + "…"
        fraction = progress.fraction
        detail = progress.completedLabel
        if let name = progress.currentName { detail += " · \(name)" }
        if progress.downloadedBytes > 0 { detail += " · \(SimilarityScanProgress.bytes(progress.downloadedBytes)) fetched" }
        activity.update(source.taskKind, message: message, detail: detail, fraction: fraction)
    }

    private func resolveSource(_ event: [String: Any]) {
        guard !isFinishing else { return }
        guard let resolver = resolveExternalSource, let root = sourceRequestRoot,
              let request = SimilaritySourceRequest(event: event, root: root, allowedIDs: externalSourceIDs) else {
            error = "The drive received an invalid file request. Please restart the scan."
            cancel(); return
        }
        guard sourceTasks[request.id] == nil else { return }
        let run = generation
        let attempt = UUID()
        if let id = request.downloadID { providerProgress.begin(id, attempt: attempt) }
        sourceTasks[request.id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.generation == run {
                    self.sourceTasks[request.id] = nil
                    if let id = request.downloadID { self.providerProgress.end(id, attempt: attempt) }
                }
            }
            let update: CloudDriveProgressHandler = { [weak self] value in
                Task { @MainActor in
                    guard let self, self.generation == run, self.isRunning, !self.isCancelling else { return }
                    if let id = request.downloadID {
                        self.providerProgress.update(id, attempt: attempt, fraction: value.fraction)
                        self.providerProgress.apply(to: &self.progress.downloads, photos: self.nativeScope?.drive == .photos)
                    }
                    guard self.sourceTasks.count == 1 else { return }
                    // Fetching overlaps analysis; retain analysed counts and the
                    // overall percentage rather than starting another stage.
                    self.progress.currentBytes = value.bytes
                    if value.fileSize > 0 { self.progress.currentSize = value.fileSize }
                }
            }
            var reply: [String: String] = ["id": request.id]
            do {
                let url: URL
                if let pipe = request.memoryPipe {
                    guard let memoryResolver = self.resolveExternalMemorySource else { throw CocoaError(.featureUnsupported) }
                    url = try await memoryResolver(request.id, pipe, request.memoryCapacity, update)
                } else { url = try await resolver(request.id, request.directory, update) }
                try Task.checkCancellation()
                reply["path"] = url.path
            } catch {
                reply["error"] = self.usesPhotosPreviews ? "Photos could not provide this preview. Try Originals mode in a new scan."
                    : "This original could not be fetched from the drive."
                if request.memoryPipe != nil, let capacity = error as? PhotosMemoryCapacityExceeded {
                    reply["memory_required"] = String(capacity.requiredBytes)
                } else if TransferFailure.isRetryable(error) { reply["retryable"]="true" }
            }
            guard !Task.isCancelled, self.generation == run, !self.isCancelling,
                  self.process?.isRunning == true,
                  FileManager.default.fileExists(atPath: request.directory.path) else { return }
            do {
                let data = try JSONSerialization.data(withJSONObject: reply)
                // No parent directories are recreated: a cancelled/finished
                // helper may already have removed its owned temporary files.
                let pending = request.response.appendingPathExtension("pending")
                defer { try? FileManager.default.removeItem(at: pending) }
                try data.write(to: pending, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.path)
                // Publish last: the helper can immediately consume the reply
                // and remove this attempt's directory before a capacity retry.
                try FileManager.default.moveItem(at: pending, to: request.response)
            } catch {
                self.error = "The drive could not return this file to the scan. Please retry."
                if self.savedSession != nil { self.pause(reason:"The drive could not return this file. Check its connection, then resume.") }
                else { self.cancel() }
            }
        }
    }

    private func retireProviders(temporaryDirectory: URL?) {
        retiringProviderWork += 1
        let pending = Array(sourceTasks.values)
        let inventory = inventoryTask, preparation = preparationTask
        pending.forEach { $0.cancel() }; inventory?.cancel(); preparation?.cancel()
        sourceTasks = [:]; inventoryTask = nil; preparationTask = nil
        let cleanup = takeExternalScopeCleanup?()
        let heldScopes = scopes; scopes = []
        generation = UUID(); inventoryGeneration = UUID()
        Task {
            for task in pending { await task.value }
            await inventory?.value; await preparation?.value
            await Task.detached(priority: .utility) {
                if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
                cleanup?()
                heldScopes.forEach { $0.stopAccessingSecurityScopedResource() }
            }.value
            self.retiringProviderWork -= 1
        }
    }

    private func finish(_ result: SimilarityReport?, diagnostic: String, exitCode: Int32, temporaryDirectory: URL? = nil) {
        sleepWorkDepth += 1
        defer { sleepWorkDepth -= 1 }
        retireProviders(temporaryDirectory: temporaryDirectory)
        let finishedEarly = isFinishing || result?.status == "finished"
        isFinishing = false
        scanClock.pause(at: Date())
        if let result {
            let base = runProgressBaseline?.downloadedBytes ?? 0
            progress.downloadedBytes = max(progress.downloadedBytes, helperRestoresReport
                ? max(base, result.downloadedBytes) : SimilarityScanProgress.cumulative(base, result.downloadedBytes))
        }
        inventoryTask?.cancel(); inventoryTask = nil; inventoryWaitReason = nil
        sourceTasks.values.forEach { $0.cancel() }; sourceTasks = [:]; sourceRequestRoot = nil; providerProgress = SimilarityProviderProgress()
        externalSources = []; externalSourceIDs = []
        let cancelled = cancelRequested || isCancelling || result?.status == "cancelled"
        if savedSession != nil && !resetWhenFinished && !cancelRequested && !finishedEarly && (isCancelling || isPausing || exitCode != 0 || result == nil || result?.status == "paused" || result?.status == "cancelled") {
            scopes.forEach { $0.stopAccessingSecurityScopedResource() }; scopes=[]
            process=nil; isRunning=false; isPaused=true; interrupted = !manualResumeRequired && (!isPausing || pauseReason != nil)
            isPausing=false; isCancelling=false; waitingForNetwork=false; fraction=nil; cleanupExternalScope()
            message=pauseReason ?? (interrupted ? "Scan interrupted — ready to resume" : "Scan paused")
            let reported = FileSearchIndex.withoutStatusNotes(diagnostic)
            if interrupted && !reported.isEmpty { error=String(FileSearchIndex.redacted(reported).prefix(2_000)) }
            detail="Completed files and comparisons are saved. Unfinished originals will be fetched again."
            savedSession?.state = interrupted ? "interrupted" : "paused"; savedSession?.updatedAt=Date()
            savedSession?.activeElapsedSeconds = scanClock.elapsed(at: Date())
            savedSession?.progress = progress
            if let savedSession, let configuration=resultConfiguration {
                // Shutdown can produce a partial report while preserving the
                // pause. Keep it for review if the user later cancels recovery.
                if var result {
                    result.elapsedSeconds = scanClock.elapsed(at: Date())
                    result.downloadedBytes = progress.downloadedBytes
                    try? SimilaritySessionStore.saveReport(result,configuration:configuration,id:savedSession.id)
                }
                try? SimilaritySessionStore.save(savedSession,configuration:configuration)
            }
            progress = progress.afterHelperRestart()
            activity.finish(source.taskKind,state:.paused,message:message,detail:detail)
            if interrupted { scheduleAutoResume() } else { cancelAutoResume() }
            return
        }
        isPaused=false; isPausing=false; interrupted=false; waitingForNetwork=false; pauseReason=nil
        // The scan reached a real ending: results, a hard failure or a clear.
        cancelAutoResume(resettingAttempts: true)
        if resetWhenFinished {
            // Clear can arrive while the final report is in transit from the helper.
            // Remove that report's matrix even if it has not been archived yet.
            if let savedSession, let configuration=resultConfiguration { SimilaritySessionStore.discard(configuration,id:savedSession.id,report:result) }
            savedSession=nil
            scopes.forEach { $0.stopAccessingSecurityScopedResource() }; scopes = []
            process = nil; isRunning = false; isCancelling = false
            cleanupExternalScope()
            activity.finish(source.taskKind, state: .cancelled, message: "Scan cleared")
            resetWhenFinished = false; resetIdleState()
            activity.dismiss(source.taskKind)
            return
        }
        scopes.forEach { $0.stopAccessingSecurityScopedResource() }; scopes = []
        process = nil; isRunning = false; isCancelling = false; fraction = nil
        var finalReport = result ?? ((cancelled || finishedEarly) ? cancelledReport() : nil)
        if finishedEarly {
            finalReport?.status = "finished"
            if !(finalReport?.coverage.contains("Finished early") ?? false) {
                finalReport?.coverage = "Finished early at your request. Resume Scan continues the remaining files. " + (result?.coverage ?? "No files were analysed before finishing.")
            }
        } else if cancelled {
            finalReport?.status = "cancelled"
            let notice = "The scan was cancelled; these results are incomplete."
            let coverage = finalReport?.coverage ?? ""
            if !coverage.contains(notice) {
                finalReport?.coverage = notice + " " + coverage
            }
        }
        report = finalReport.map { transformExternalReport?($0) ?? $0 }
        report?.elapsedSeconds = scanClock.elapsed(at: Date())
        report?.downloadedBytes = progress.downloadedBytes
        if let report {
            progress.analysed = report.analysedFiles; progress.skipped = report.skippedFiles
            progress.unsupportedFiles = report.unsupportedFiles ?? progress.unsupportedFiles
            progress.failedFiles = report.failedFiles ?? progress.failedFiles
            progress.scoresRetained = report.scoresRetained ?? progress.scoresRetained
        }
        if var saved=savedSession, let configuration=resultConfiguration {
            saved.state=report?.status ?? "interrupted"; saved.updatedAt=Date()
            saved.activeElapsedSeconds = scanClock.elapsed(at: saved.updatedAt)
            saved.progress = progress
            do {
                if let report { try SimilaritySessionStore.saveReport(report,configuration:configuration,id:saved.id) }
                try SimilaritySessionStore.save(saved,configuration:configuration); savedSession=saved
            } catch { self.error="Results are open, but could not be saved. Check available storage before closing the app." }
        }
        if let report { results.load(report, configuration: resultConfiguration, allowsSizeBasedCleanup: !usesPhotosPreviews) }
        cleanupExternalScope()
        if let result = report, exitCode == 0 || cancelled || finishedEarly {
            let state: FinderTaskActivity.State = cancelled ? .cancelled : result.status == "failed" ? .failed : ["partial", "finished"].contains(result.status) ? .partial : .completed
            message = finishedEarly ? "Scan finished early · \(result.analysedFiles.formatted()) files ready to review" : cancelled ? "Scan cancelled · \(result.analysedFiles.formatted()) files ready to review" : state == .failed ? "Scan could not finish" : "\(result.analysedFiles.formatted()) files ready to review"
            if state == .failed { error = result.issues.first?.reason ?? "The selected scope could not be scanned. Check access and try again." }
            detail = "\(result.analysedFiles.formatted()) analysed · \(result.skippedFiles.formatted()) skipped"
            activity.finish(source.taskKind, state: state, message: "\(source.title): \(message)", detail: detail)
        } else {
            message = cancelled ? "Scan cancelled" : "Scan could not finish"
            let reported = FileSearchIndex.withoutStatusNotes(diagnostic)
            if !cancelled { error = reported.isEmpty ? "The scan engine could not finish (exit \(exitCode)). Try a smaller scope or check the selected files." : FileSearchIndex.redacted(reported) }
            activity.finish(source.taskKind, state: cancelled ? .cancelled : .failed, message: message, detail: error)
        }
    }

    /// Cancellation before the helper starts still opens a report. If a
    /// stopped helper could not publish its inventory, report the known counts
    /// and say explicitly that file details are unavailable.
    private func cancelledReport() -> SimilarityReport {
        if let savedSession, let configuration=resultConfiguration,
           let archived=SimilaritySessionStore.loadReport(configuration,id:savedSession.id) { return archived }
        return .init(source:source,scope:[savedSession?.scope ?? scopeLabel],status:"cancelled",threshold:threshold,
            scannedFiles:max(progress.foundFiles,SimilarityScanProgress.cumulative(progress.analysed,progress.skipped)),
            analysedFiles:progress.analysed,skippedFiles:progress.skipped,downloadedBytes:progress.downloadedBytes,
            totalGroups:0,groups:[],issues:[],truncated:false,
            coverage:progress.analysed == 0 ? "No files were analysed before cancellation."
                : "The scan engine stopped before it could publish file details. Resume to recover the saved analysis.",
            elapsedSeconds:scanClock.elapsed(at:Date()),files:[],
            unsupportedFiles:progress.unsupportedFiles,failedFiles:progress.failedFiles)
    }

    var canFinish: Bool { !externalDuplicatesOnly && !isFinishing && !isCancelling && (isRunning || isPaused) }
    var canResumeReport: Bool { savedSession != nil && ["finished", "cancelled"].contains(report?.status ?? "") }

    func finishScan() {
        guard canFinish else { return }
        sleepWorkDepth += 1
        defer { sleepWorkDepth -= 1 }
        cancelAutoResume(resettingAttempts: true)
        guard var saved = savedSession, let configuration = resultConfiguration else { return }
        saved.state = "finished"; saved.updatedAt = Date(); saved.progress = progress
        saved.activeElapsedSeconds = scanClock.elapsed(at: saved.updatedAt)
        do { try SimilaritySessionStore.finish(saved, configuration: configuration) }
        catch { self.error = "Could not save the finish request. Check available storage and try again."; return }
        savedSession = saved; isFinishing = true; isPaused = false; isPausing = false; isRunning = true
        interrupted = false; waitingForNetwork = false; inventoryWaitReason = nil; pauseReason = nil; error = nil
        scanClock.resume(at: Date())
        message = "Finishing current analysis and preparing report…"
        detail = "No more files will start analysis. You can resume from the report."
        activity.stopping(source.taskKind, message: message)
        inventoryTask?.cancel(); sourceTasks.values.forEach { $0.cancel() }
        if process == nil { finish(nil, diagnostic: "", exitCode: 0) }
    }

    func cancel() {
        cancelAutoResume(resettingAttempts: true)
        guard !isCancelling, isRunning || isPaused || process != nil else { return }
        sleepWorkDepth += 1
        defer { sleepWorkDepth -= 1 }
        cancelRequested = !resetWhenFinished
        isCancelling=true; isPausing=false; isPaused=false; isRunning=true
        interrupted=false; waitingForNetwork=false; inventoryWaitReason=nil; pauseReason=nil; error=nil
        recordProcessingSpeed()
        // A pause marker would make the helper return a paused report. Cancel
        // ends the helper and publishes its partial inventory and comparisons.
        if let savedSession, let configuration=resultConfiguration { try? SimilaritySessionStore.removePause(configuration,id:savedSession.id) }
        message = resetWhenFinished ? "Stopping and removing temporary copies…" : "Stopping scan and preparing report…"
        activity.stopping(source.taskKind, message: message)
        inventoryTask?.cancel()
        sourceTasks.values.forEach { $0.cancel() }
        if preparationTask != nil {
            finish(nil, diagnostic: "", exitCode: 0); return
        }
        guard let child=process else { finish(nil,diagnostic:"",exitCode:0); return }
        // An exited child may still be draining its report; let its existing
        // termination handler finish instead of replacing it with an empty one.
        guard child.isRunning else { return }
        child.terminate()
        // A crashed decoder must not keep the operation active indefinitely.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 3) {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }

    /// Only the explicit Clear action removes persisted work and results.
    func clearSession() {
        sessionID = UUID()
        if isRunning || process?.isRunning == true {
            resetWhenFinished = true
            isPaused = false; isRunning = true
            cancel()
            results.reset(); report = nil; error = nil
            localURLs = []; cloudRoots = []; externalScopeNames = []
        } else {
            if let savedSession, let configuration=resultConfiguration { SimilaritySessionStore.discard(configuration,id:savedSession.id) }
            savedSession=nil; isPaused=false; isFinishing=false; resetIdleState()
            activity.dismiss(source.taskKind)
        }
    }

    private func resetIdleState() {
        cancelAutoResume(resettingAttempts: true)
        processingLabel=""; processingBackend=nil; cancelRequested=false; isFinishing=false
        nativeScope = nil; acrossDriveScopes = nil; waitingForNetwork = false; inventoryWaitReason = nil; isPausing = false; pauseReason = nil; manualResumeRequired = false
        results.reset(); resultConfiguration = nil
        report = nil; error = nil; message = "Ready to scan"; detail = ""
        fraction = nil; progress = SimilarityScanProgress(); startedAt = nil; runResources = nil
        processingSpeedTask?.cancel(); processingSpeedTask = nil
        processingHistory = SimilarityProcessingHistory(); processingSpeed = DownloadSpeedSnapshot()
        readHistory = SimilarityReadHistory(); readSpeed = 0
        scanClock = SimilarityScanClock()
        runProgressBaseline = nil; helperRestoresReport = false; isRestoringProgress = false
        liveFoundFiles = 0; liveDiscoveryComplete = false
        localURLs = []; cloudRoots = []; externalScopeNames = []
        threshold = 0.9; exactDuplicates = true; families = Self.supportedFamilies
        externalDuplicatesOnly = false; prepareExternalScope = nil
        inventoryExternalSources = nil; streamExternalSources = nil; resolveExternalSource = nil; resolveExternalMemorySource = nil; externalSources = []
        externalSourceIDs = []
        sourceTasks.values.forEach { $0.cancel() }; sourceTasks = [:]; sourceRequestRoot = nil; providerProgress = SimilarityProviderProgress()
        transformExternalReport = nil; cleanupExternalScope = {}; takeExternalScopeCleanup = nil
        onSessionReset()
        sessionID = UUID()
    }

    var canPause: Bool { isRunning && !isFinishing && !isCancelling && !isPausing && savedSession != nil }
    func updatePausedResources(_ settings: SimilarityResourceSettings, sessionID: String) throws {
        guard !isRunning, isPaused, var saved = savedSession, saved.id == sessionID,
              let configuration = resultConfiguration else {
            throw CloudDriveError.message("Pause this scan and wait for it to finish saving before changing its resources.")
        }
        if let message = settings.validationMessage { throw CloudDriveError.message(message) }
        var limits = settings.limits
        // Worker/memory allowances are scheduling decisions. Encoding profiles
        // must stay compatible with the vectors already in this checkpoint.
        limits.acceleration = saved.resources.acceleration ?? .cpu
        if limits.automaticMemory != true && retainsOriginalsInRAM && limits.downloadBudgetBytes < max(progress.retainedDownloadMinimum, progress.originalMemoryBytes) {
            throw CloudDriveError.message("Retained downloads need at least \(SimilarityScanProgress.memoryGB(max(progress.retainedDownloadMinimum, progress.originalMemoryBytes))) of Download RAM to finish. Resume before reducing it further.")
        }
        saved.resources = limits; saved.updatedAt = Date()
        try SimilaritySessionStore.save(saved, configuration: configuration)
        if retainsOriginalsInRAM { try SimilaritySessionStore.updateLiveResources(limits, configuration: configuration, id: saved.id) }
        savedSession = saved; runResources = limits
    }

    func pause(reason: String? = nil) {
        // A pause the user asked for returns the recovery budget; a fault-driven
        // one keeps counting so a repeating fault still reaches its limit.
        cancelAutoResume(resettingAttempts: reason == nil)
        guard canPause, var saved=savedSession, let configuration=resultConfiguration else { return }
        sleepWorkDepth += 1
        defer { sleepWorkDepth -= 1 }
        saved.state="paused"; saved.updatedAt=Date()
        var pausedClock = scanClock; pausedClock.pause(at: saved.updatedAt)
        saved.activeElapsedSeconds = pausedClock.elapsed(at: saved.updatedAt)
        saved.progress = progress
        do { try SimilaritySessionStore.pause(saved,configuration:configuration) }
        catch { self.error="Could not save the pause point. Check available storage and try again."; return }
        scanClock = pausedClock
        savedSession=saved; isPausing=true; pauseReason=reason; message="Pausing · keeping downloads in RAM…"
        recordProcessingSpeed()
        activity.stopping(source.taskKind,message:message)
        // The marker pauses the helper cooperatively. Keep provider tasks,
        // security scopes, FIFO writers and all original buffers alive.
        if process?.isRunning != true {
            preparationTask?.cancel()
            if preparationTask == nil { finish(nil,diagnostic:"",exitCode:0) }
        }
    }
    func preserveForShutdown() {
        cancelAutoResume(resettingAttempts: true)
        guard savedSession != nil else { return }
        sleepWorkDepth += 1
        defer { sleepWorkDepth -= 1 }
        pause()
        checkpointProgress(force: true)
        // App shutdown cannot retain volatile RAM. Keep the durable checkpoint
        // and end the helper; ordinary window close only calls pause().
        inventoryTask?.cancel(); sourceTasks.values.forEach { $0.cancel() }
        if let child = process, child.isRunning { child.terminate() }
        preserveOnClose=true
        if let savedSession, let configuration=resultConfiguration { SimilaritySessionStore.release(configuration,id:savedSession.id) }
    }
    func detachPausedForRecovery() {
        guard !isRunning else { return }
        guard process?.isRunning != true else {
            error = "This scan is retaining downloads in RAM. Use File → New Window to start another scan, or Delete Scan to discard this one."; return
        }
        if let savedSession, let configuration=resultConfiguration { SimilaritySessionStore.release(configuration,id:savedSession.id) }
        self.savedSession=nil; isPaused=false; preserveOnClose=false; resetIdleState()
    }
    func findRecoverable(_ configuration: SimilarityConfiguration) {
        recoverableSessions=SimilaritySessionStore.available(configuration,source:source)
        if !isRunning && !isPaused && report == nil && !recoverableSessions.isEmpty {
            message="\(recoverableSessions.count) saved scan(s) available"
            activity.begin(source.taskKind,scope:recoverableSessions.first?.scope ?? "",message:message)
            activity.finish(source.taskKind,state:.paused,message:message,detail:"Open the scan window to resume saved work.")
        }
    }

    func openSaved(_ saved: SimilaritySavedSession, configuration: SimilarityConfiguration) {
        guard !isRunning, !SimilaritySessionStore.isClaimed(configuration,id:saved.id),
              let report=SimilaritySessionStore.loadReport(configuration,id:saved.id) else { return }
        if let current=savedSession, let previous=resultConfiguration { SimilaritySessionStore.release(previous,id:current.id) }
        savedSession=saved; resultConfiguration=configuration; localURLs=saved.localURLs; cloudRoots=saved.cloudRoots
        nativeScope=saved.nativeScope; acrossDriveScopes=saved.acrossDriveScopes
        threshold=saved.threshold; exactDuplicates=saved.exactDuplicates; families=saved.families
        photosUsePreviews = saved.nativeScope?.photosUsePreviews ?? false
        isPaused=false; isPausing=false; isFinishing=false; isCancelling=false; interrupted=false; cancelRequested=false; error=nil
        cancelAutoResume(resettingAttempts: true)
        self.report=report; runResources=saved.resources; startedAt=saved.startedAt
        progress = saved.progress?.afterHelperRestart() ?? SimilarityScanProgress()
        scanClock = SimilarityScanClock(elapsedSeconds: saved.activeElapsedSeconds ?? report.elapsedSeconds)
        results.load(report,configuration:configuration,allowsSizeBasedCleanup:!usesPhotosPreviews); message="\(report.analysedFiles.formatted()) files ready to review"
        SimilaritySessionStore.claim(configuration,id:saved.id); recoverableSessions.removeAll { $0.id == saved.id }
        activity.begin(source.taskKind,scope:saved.scope,message:message)
        let state: FinderTaskActivity.State = report.status == "failed" ? .failed : ["partial", "finished"].contains(report.status) ? .partial : .completed
        activity.finish(source.taskKind,state:state,message:message)
    }

    func clearAccount() {
        guard !isRunning, process?.isRunning != true else { return }
        cancelAutoResume(resettingAttempts: true)
        if let savedSession, let configuration=resultConfiguration { SimilaritySessionStore.release(configuration,id:savedSession.id) }
        savedSession=nil; isPaused=false; recoverableSessions=[]
        results.reset(); resultConfiguration = nil
        cloudRoots = []; report = nil; error = nil; message = "Ready to scan"; detail = ""
        startedAt = nil; scanClock = SimilarityScanClock()
    }

    func exportReport() {
        guard let report else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Similarity-\(source.rawValue).json"
        panel.title = "Export similarity results"; panel.allowedContentTypes = [.json]
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            DispatchQueue.global(qos: .utility).async {
                do {
                    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                    encoder.keyEncodingStrategy = .convertToSnakeCase
                    try encoder.encode(report).write(to: url, options: .atomic)
                } catch { Task { @MainActor in self?.error = error.localizedDescription } }
            }
        }
    }

    #if FINDER_WORKSPACE_TESTS
    /// Reproduce the interrupted-paused state a stopped helper leaves behind,
    /// so recovery can be exercised without killing a real scan process.
    func setFixtureInterrupted() {
        if savedSession == nil {
            savedSession = SimilaritySavedSession(id: UUID().uuidString, source: source, localURLs: localURLs,
                cloudRoots: cloudRoots, nativeScope: nil, scope: scopeLabel, families: families,
                threshold: threshold, exactDuplicates: exactDuplicates,
                resources: SimilarityResourceSettings.current.limits, state: "interrupted",
                startedAt: Date(), updatedAt: Date())
        }
        isRunning = false; isPaused = true; interrupted = true
        cancelRequested = false; preserveOnClose = false
        message = "Scan interrupted — ready to resume"
        scheduleAutoResume()
    }

    /// Report the headway a resumed helper makes, which returns the budget.
    func setFixtureResumedProgress(analysed: Int) {
        isPaused = false; isRunning = true; interrupted = false
        receive(["event": "progress", "stage": "analysing", "counts": ["files_ready": analysed]])
    }

    private var fixtureRetainsOriginalsInRAM = false { didSet { updateSleepPrevention() } }
    func setFixtureReport(_ value: SimilarityReport) { report = value; results.load(value, configuration: resultConfiguration); message = "\(value.analysedFiles) files ready to review" }
    func setFixtureProgress(_ event: [String: Any], paused: Bool = false) {
        report = nil; isRunning = !paused; isPaused = paused
        fixtureRetainsOriginalsInRAM = paused
        if startedAt == nil {
            startedAt = Date().addingTimeInterval(-72)
            scanClock = SimilarityScanClock(elapsedSeconds: 72)
        }
        if paused { scanClock.pause(at: Date()) } else { scanClock.resume(at: Date()) }
        if let work = event["work"] as? [String: Any], let workers = work["worker_limit"] as? NSNumber, let memory = work["memory_limit"] as? NSNumber {
            runResources = SimilarityResourceLimits(workers: workers.intValue, memoryBytes: memory.uint64Value, batchFiles: 128, batchBytes: 4 * 1_024 * 1_024 * 1_024)
            runResources?.downloadMemoryBytes = (work["original_memory_limit"] as? NSNumber)?.uint64Value
            runResources?.memoryScheduling = work["memory_scheduling"] as? Bool ?? false
        }
        activity.begin(source.taskKind, scope: scopeLabel, message: "Starting scan")
        receive(event)
    }
    #endif
}

/// Pipe decoding is bounded and performed off the main queue, including the
/// final potentially large result. stdout never carries original file content.
final class SimilarityProcessReader {
    private let group = DispatchGroup()
    private var diagnostic = Data()
    private static func readChunk(_ handle: FileHandle, size: Int) -> Data? {
        var buffer = [UInt8](repeating: 0, count: size)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress!, $0.count) }
            if count > 0 { return Data(buffer.prefix(count)) }
            if count < 0 && errno == EINTR { continue }
            return nil
        }
    }
    func start(output: Pipe, errors: Pipe, receive: @escaping ([String: Any]) -> Void) {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { group.leave(); try? output.fileHandleForReading.close() }
            var buffer = Data()
            // Foundation read(upToCount:) can wait for the requested byte
            // count on macOS pipes. A small source request must be delivered
            // immediately: the helper waits for its reply before writing more.
            while let chunk = Self.readChunk(output.fileHandleForReading, size: 16_384) {
                buffer.append(chunk)
                while let newline = buffer.firstIndex(of: 10) {
                    let line = buffer.prefix(upTo: newline); buffer.removeSubrange(...newline)
                    if let event = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] { receive(event) }
                }
                if buffer.count > 1_048_576 { buffer.removeAll(keepingCapacity: false) }
            }
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { group.leave(); try? errors.fileHandleForReading.close() }
            while let chunk = Self.readChunk(errors.fileHandleForReading, size: 8192) {
                if diagnostic.count < 16_384 { diagnostic.append(chunk.prefix(16_384 - diagnostic.count)) }
            }
        }
    }
    func finish(reportURL: URL, completion: @escaping (SimilarityReport?, String) -> Void) {
        group.notify(queue: .global(qos: .utility)) { [self] in
            let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
            var report: SimilarityReport?
            var message = String(data: diagnostic, encoding: .utf8) ?? ""
            do {
                guard let bytes = SimilaritySessionStore.readBoundedFile(reportURL,
                    maximumBytes: SimilarityReportStorage.maximumBytes) else { throw CocoaError(.fileReadUnknown) }
                report = try decoder.decode(SimilarityReport.self, from: bytes)
            } catch { if message.isEmpty { message = "The scan did not produce a readable report. \(error.localizedDescription)" } }
            completion(report, message)
        }
    }
}

struct SimilarityDriveOption: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let source: SimilaritySource
}

@MainActor
final class FileSimilarityCoordinator: NSObject, ObservableObject, NSWindowDelegate {
    let cloud: SimilarityScanModel
    let local: SimilarityScanModel
    @Published var source: SimilaritySource = .cloud
    @Published var selectedDriveID = "pikpak"
    @Published var driveOptions: [SimilarityDriveOption] = [
        .init(id: "pikpak", title: "PikPak", symbol: "cloud", source: .cloud),
        .init(id: "local", title: "Local Disk", symbol: "internaldrive", source: .local)
    ]
    var resolveDrive: (String) -> FileSimilarityCoordinator? = { _ in nil }
    var preferredDriveID: String?
    weak var presentationHost: FileSimilarityCoordinator?
    var chooseDriveScope: ((SimilaritySource, Bool) -> Void)?
    var chooseFolderScope: (() -> Void)?
    var newScanPresentation: (() -> Void)?
    var scopePickerButtonTitle = "Choose Folder…"
    @Published var scopePicker: SimilarityScopePicker?
    var revealInBrowser: ((SimilaritySource, SimilarityFile) -> Void)?
    var moveToTrash: ((SimilarityFile) async throws -> Void)?
    var keepSmallest: ((SimilarityKeepSmallestPlan) async throws -> Set<String>)?
    var configuration: (SimilaritySource) throws -> SimilarityConfiguration = { _ in throw CocoaError(.fileNoSuchFile) }
    var restoreNativeScope: ((SimilarityNativeScope) throws -> Void)?
    var prepareScan: ((SimilarityScanModel) throws -> Void)?
    var restoreAcrossDriveScopes: (([SimilarityAcrossDriveScope]) throws -> Void)?
    weak var acrossDrives: SimilarityAcrossDrives?
    var cloudScope: (Bool) throws -> [SimilarityCloudRoot] = { _ in [] }
    var openCloudFile: (SimilarityFile) -> Void = { _ in }
    var externalTitle: String?
    var externalSymbol = "externaldrive"
    @Published var duplicatesOnly = false
    var openExternalFile: ((SimilarityFile) -> Void)?
    var preparePreview: ((SimilarityFile, URL) async throws -> URL)?
    let preview = SimilarityPreviewModel()
    var browserRevealTask: Task<Void, Never>?
    private var window: NSWindow?
    var presentedWindow: NSWindow? { window }
    var onWindowClosed: () -> Void = {}
    private var visitedDrives: Set<String> = []
    var runs: [SimilarityScanModel] { [cloud, local] }
    var selectedDrive: SimilarityDriveOption? { driveOptions.first { $0.id == selectedDriveID } }
    var activeCoordinator: FileSimilarityCoordinator { resolveDrive(selectedDriveID) ?? self }
    var activeModel: SimilarityScanModel {
        let target = activeCoordinator
        return (selectedDrive?.source ?? source) == .cloud ? target.cloud : target.local
    }

    init(activity: FinderTaskActivityStore) {
        cloud = SimilarityScanModel(source: .cloud, activity: activity)
        local = SimilarityScanModel(source: .local, activity: activity)
        super.init()
        // Restarting a saved scan needs the account configuration and the drive
        // reconnection this coordinator owns, so it performs the attempt the
        // model schedules.
        for model in runs {
            model.performAutoResume = { [weak self, weak model] in
                guard let self, let model else { return }
                self.resume(model, automatic: true)
            }
        }
        let priorDismiss = activity.onDismiss
        activity.onDismiss = { [weak self] kind in
            priorDismiss(kind)
            guard let self else { return }
            if kind == .similarityCloud || kind == .similarityLocal { self.preview.close(); self.duplicatesOnly = false }
        }
    }
    func chooseScope(_ selection: Bool) {
        if let chooseDriveScope { chooseDriveScope(source, selection) }
        else if source == .cloud { useBrowserSelection(selection) }
        else { local.chooseLocalFiles() }
    }
    func selectDrive(_ id: String) {
        guard let option = driveOptions.first(where: { $0.id == id }) else { return }
        activeCoordinator.preview.close()
        selectedDriveID = id; visitedDrives.insert(id)
        let target = activeCoordinator
        target.source = option.source
        // The drive picker also enters a coordinator. Discover its saved scans
        // here so opening from Home on Local Disk does not hide cloud recovery.
        target.refreshRecovery()
        target.autoResumeRecoveredSessions()
        if !activeModel.isRunning && activeModel.report == nil {
            if option.source == .cloud && target.cloud.cloudRoots.isEmpty { target.useBrowserSelection(false) }
            else if target.externalTitle != nil && target.local.externalScopeNames.isEmpty {
                target.chooseDriveScope?(option.source, false)
            }
        }
        window?.title = target.duplicatesOnly ? "Check for Duplicates" : target.acrossDrives != nil ? "Find Similarity Across Drives" : "Find Similar Files"
    }
    func reveal(_ file: SimilarityFile) {
        preview.close()
        revealInBrowser?(source, file)
    }
    func useBrowserSelection(_ selection: Bool) {
        guard !cloud.isRunning else { return }
        do { cloud.cloudRoots = try cloudScope(selection); cloud.error = nil }
        catch { cloud.error = error.localizedDescription }
    }
    func start(_ model: SimilarityScanModel) {
        do { try prepareScan?(model); model.start(try configuration(model.source)) }
        catch { model.error = error.localizedDescription }
    }
    func refreshRecovery() {
        for model in runs where !model.isRunning {
            if let config=try? configuration(model.source) { model.findRecoverable(config) }
        }
    }
    func discardRecovery(_ model: SimilarityScanModel, session: SimilaritySavedSession) {
        do {
            let config=try configuration(model.source)
            guard !SimilaritySessionStore.isClaimed(config,id:session.id) else {
                throw CloudDriveError.message("This scan is open in another window.")
            }
            SimilaritySessionStore.discard(config,id:session.id)
            model.findRecoverable(config)
            if model.recoverableSessions.isEmpty && !model.isRunning && !model.isPaused && model.report == nil {
                model.clearSession(); model.activity.dismiss(model.source.taskKind)
            }
        } catch { model.error=error.localizedDescription }
    }
    func resume(_ model: SimilarityScanModel, session: SimilaritySavedSession? = nil, automatic: Bool = false) {
        // Pressing Resume is the user taking over, which returns the budget.
        if !automatic { model.cancelAutoResume(resettingAttempts: true) }
        guard let saved=session ?? model.savedSession else { present(source:model.source); return }
        do {
            if let scopes = saved.acrossDriveScopes, !model.retainsOriginalsInRAM {
                guard let restoreAcrossDriveScopes else { throw CloudDriveError.message("Open Across Drives to resume this scan.") }
                try restoreAcrossDriveScopes(scopes)
            }
            let config=try configuration(model.source)
            if model.savedSession != nil, let previous=model.resultConfiguration, !SimilaritySessionStore.sameAccount(previous,config) {
                throw CloudDriveError.message("Switch back to the account that started this scan, then resume.")
            }
            if (["completed","partial","failed"].contains(saved.state) || (session != nil && saved.state == "finished")), SimilaritySessionStore.loadReport(config,id:saved.id) != nil {
                model.openSaved(saved,configuration:config); return
            }
            if !model.retainsOriginalsInRAM, let scope=saved.nativeScope {
                guard let restoreNativeScope else { throw CloudDriveError.message("Reconnect this drive before resuming.") }
                try restoreNativeScope(scope)
            }
            model.start(config,resuming:saved)
        } catch {
            model.error=error.localizedDescription
            // A missing drive or a rotated account may return shortly, so keep
            // recovering on the remaining schedule rather than stopping here.
            if automatic { model.scheduleAutoResume() }
        }
    }

    /// A scan that was still running when its window or the app went away is
    /// picked up again as soon as its drive is opened. A scan the user paused
    /// or cancelled stays waiting, and an ambiguous set of candidates is left
    /// for them to choose from.
    private func autoResumeRecoveredSessions() {
        for model in runs where !model.isRunning && !model.isPaused && model.report == nil {
            let candidates = model.recoverableSessions.filter { ["running","interrupted"].contains($0.state) }
            guard candidates.count == 1, let session = candidates.first else { continue }
            resume(model, session: session, automatic: true)
        }
    }
    func present(source requested: SimilaritySource? = nil) {
        if let requested { source = requested }
        let id = preferredDriveID ?? (source == .cloud ? "pikpak" : "local")
        if let host = presentationHost, host !== self { host.presentDrive(id); return }
        presentDrive(id)
    }
    func presentNewScan() {
        if let newScanPresentation { newScanPresentation() }
        else { present() }
    }
    func presentDrive(_ id: String) {
        selectDrive(id)
        if window == nil {
            let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 1000)
            let size = NSSize(width: min(1320, max(940, screen.width - 80)), height: min(900, max(740, screen.height - 80)))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "Find Similar Files"
            window.minSize = NSSize(width: 940, height: 740)
            window.isReleasedWhenClosed = false; window.delegate = self
            window.contentView = NSHostingView(rootView: FileSimilarityView(coordinator: self))
            window.center(); self.window = window
        }
        window?.title = activeCoordinator.duplicatesOnly ? "Check for Duplicates" : activeCoordinator.acrossDrives != nil ? "Find Similarity Across Drives" : "Find Similar Files"
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        resetWindowSession()
        window?.contentView = nil; window = nil
        onWindowClosed()
    }
    private func resetWindowSession() {
        var targets: [FileSimilarityCoordinator] = [self]
        for id in visitedDrives {
            if let target = resolveDrive(id), !targets.contains(where: { $0 === target }) { targets.append(target) }
        }
        for target in targets {
            target.scopePicker?.close(); target.scopePicker = nil
            target.runs.forEach { model in
                model.pause()
            }
            target.browserRevealTask?.cancel(); target.browserRevealTask = nil
            target.preview.close(); target.duplicatesOnly = false
        }
        visitedDrives = []
    }
    func close(preservingScans: Bool = false) {
        if preservingScans {
            runs.forEach { $0.preserveForShutdown() }
            for id in visitedDrives { resolveDrive(id)?.runs.forEach { $0.preserveForShutdown() } }
        }
        if let window { window.close() }
        else { resetWindowSession() }
    }
}

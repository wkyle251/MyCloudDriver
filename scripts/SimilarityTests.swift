import Darwin
import AppKit
import Foundation

#if !SIMILARITY_QUERY_TEST_LIBRARY
@main
#endif
struct SimilarityTests {
    @MainActor static func main() async throws {
        let suite = "com.wky.PikPakSimilarityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try DownloaderModel.testSimilarityScope(defaults: defaults)
        try DownloaderModel.testTaskActivity(defaults: defaults)
        let activity = FinderTaskActivityStore()
        let coordinator = FileSimilarityCoordinator(activity: activity)
        coordinator.local.localURLs = [URL(fileURLWithPath: "/tmp/synthetic.txt")]
        coordinator.local.threshold = 0.8
        precondition(coordinator.cloud.localURLs.isEmpty && coordinator.cloud.threshold == 0.9)
        precondition(coordinator.local.canStart && !coordinator.cloud.canStart)
        let processing = SimilarityScanModel(source: .cloud, activity: FinderTaskActivityStore())
        processing.setFixtureProgress(["event":"acceleration", "backend":"coreml", "message":"CoreML acceleration"])
        processing.setFixtureProgress(["event":"progress", "stage":"analysing",
            "work":["accelerator_active":2, "accelerator_limit":2, "encoding":4, "worker_limit":8]])
        precondition(processing.resourceProcessing?.backend == .coreml && processing.resourceProcessing?.activeJobs == 2)
        precondition(processing.resourceProcessing?.jobLimit == 2)
        processing.setFixtureProgress(["event":"progress", "stage":"comparison"])
        precondition(processing.resourceProcessing?.activeJobs == 0, "Completed visual jobs must not appear active while comparing")
        processing.setFixtureProgress(["event":"acceleration", "backend":"cpu", "message":"CPU processing"])
        precondition(processing.resourceProcessing?.backend == .cpu && processing.resourceProcessing?.detail.isEmpty == true)
        print("PASS resource processing status uses the actual backend and current CoreML job counts")
        coordinator.local.threshold = 0.05; precondition(coordinator.local.canStart)
        coordinator.local.threshold = 0.04; precondition(!coordinator.local.canStart)
        coordinator.local.threshold = 0.8
        let analysing = SimilarityScanProgress(event: ["stage":"analysing", "completed":15, "total":16,
            "current_file":["name":"Example.mov", "bytes":1000], "file_bytes_read":500, "operation":"decoding",
            "counts":["files_ready":14, "files_failed":1]])
        precondition(analysing.fraction == 15.0 / 16 && analysing.analysed == 14 && analysing.skipped == 1)
        precondition(analysing.currentName == "Example.mov" && analysing.currentBytes == 500)
        precondition(SimilarityScanProgress(event: ["stage":"inventory", "completed":16]).fraction == nil)
        precondition(SimilarityScanProgress(event: ["stage":"comparison", "completed":50, "total":100]).fraction == 0.5)
        precondition(SimilarityScanProgress(event: ["stage":"analysing", "completed":999, "total":1000]).percentLabel == "99%")
        precondition(SimilarityScanProgress(event: ["stage":"grouping", "completed":0, "total":0]).fraction == nil)
        let raw = SimilarityScanProgress(event: ["stage":"comparing", "counts":["pairs_processed":35, "pairs_total":70, "pairs_compared":12, "scores_retained":12, "bytes_read":1024]])
        precondition(raw.fraction == 0.5 && raw.pairsCompared == 12 && raw.scoresRetained == 12 && raw.bytesRead == 1024)
        let discovering = SimilarityScanProgress(event: ["stage":"discovery", "counts":["files_processed":15, "files_total":NSNull(), "files_ready":14, "files_failed":1]])
        precondition(discovering.total == nil && discovering.completed == 15 && discovering.fraction == nil)
        let reused = SimilarityScanProgress(event: ["stage":"analysing", "counts":["files_processed":12, "files_total":16, "files_ready":10, "files_skipped":1, "files_failed":1, "vectors_encoded":3, "cache_hits":7]])
        precondition(reused.fraction == 0.75 && reused.skipped == 2 && reused.vectorsEncoded == 3 && reused.cacheHits == 7)
        let pipeline = SimilarityScanProgress(event: ["stage":"analysing", "completed":852, "total":1593, "active":52,
            "counts":["files_discovered":1593,"files_ready":800,"files_failed":2,"files_skipped":50],
            "work":["fetching":8,"reading":12,"encoding":27,"waiting_memory":5,"waiting_reuse":14,"worker_limit":52]])
        precondition(pipeline.hasWorkPhases && pipeline.fetchingFiles == 8 && pipeline.readingFiles == 12 && pipeline.encodingFiles == 27)
        precondition(pipeline.activeFiles == 52 && pipeline.workerLimit == 52 && pipeline.queuedFiles == 675)
        precondition(pipeline.unsupportedFiles == 50 && pipeline.failedFiles == 2 && pipeline.skipped == 52)
        precondition(pipeline.phaseSummary.contains("27 files analysing") && pipeline.waitingReuseFiles == 14)
        print("PASS actual pipeline phases, shared worker limit, duplicate waiters and separate unsupported/failure counts")
        let retrying = SimilarityScanProgress(event: ["stage":"analysing", "completed":20, "active":52,
            "counts":["files_discovered":100,"files_failed":0],
            "work":["fetching":8,"encoding":20,"waiting_download":22,"retrying_download":2,"download_limit":8,"worker_limit":52]])
        precondition(retrying.waitingDownloadFiles == 22 && retrying.retryingDownloadFiles == 2 && retrying.downloadLimit == 8)
        precondition(retrying.failedFiles == 0 && retrying.queuedFiles == 28)
        precondition(retrying.waitingSummary.contains("22 waiting to download") && retrying.waitingSummary.contains("2 retrying download"))
        print("PASS waiting downloads and retries are visible without counting them as failed or queued twice")
        let downloads = SimilarityScanProgress(event: ["stage":"analysing", "downloads":[
            "total":3, "speed":524_288, "forecast_bytes":UInt64(8 << 30), "forecast_seconds":2,
            "items":[
                ["id":1,"name":"Video.mp4","received":1_000,"total":2_000,"speed":500,"state":"downloading"],
                ["id":2,"name":"Photo.jpg","received":100,"total":0,"speed":400,"state":"waiting_memory"],
                ["id":3,"name":"Retry.jpg","received":0,"total":300,"speed":Double.nan,"state":"retrying","retry_seconds":3],
                ["id":1,"name":"Duplicate event","received":0,"total":1],
            ]
        ]])
        precondition(downloads.hasDownloadTelemetry && downloads.downloads.count == 3 && downloads.downloadCount == 3)
        precondition(downloads.downloadForecastBytes == UInt64(8 << 30) && downloads.downloadForecastSeconds == 2)
        let video = downloads.downloads[0]
        precondition(video.fraction == 0.5 && video.currentSpeed(age: 0, running: true) == 500)
        precondition(video.remainingLabel(speed: 500) == "2s")
        precondition(video.currentSpeed(age: 6, running: true) == 0 && video.currentSpeed(age: 0, running: false) == 0)
        precondition(downloads.downloads[1].fraction == nil && downloads.downloads[1].currentSpeed(age: 0, running: true) == 0)
        precondition(downloads.downloads[2].speed == 0 && downloads.downloads[2].status(age: 2, running: true) == "Retrying in 1s")
        precondition(SimilarityScanProgress(event: ["stage":"comparison"]).downloads.isEmpty)
        precondition(SimilarityDownload.count(-1) == 0)
        print("PASS per-file bytes, speed, ETA, unknown sizes, retries, duplicate rows and stopped/stale telemetry")
        let independent = SimilarityScanProgress(event: ["stage":"analysing", "completed":14, "active":9,
            "counts":["files_discovered":200],
            "work":["independent_downloads":true,"ready":12,"fetching":4,"resolving":1,"reading":2,"encoding":2,
                    "waiting_memory":4,"waiting_download":162,"retrying_download":1,"download_limit":8,"worker_limit":52]])
        precondition(independent.independentDownloads && independent.readyFiles == 12 && independent.encodingFiles == 2)
        precondition(independent.activeFiles == 9 && independent.queuedFiles == 177 && independent.resolvingFiles == 1)
        precondition(independent.waitingSummary.contains("1 connecting") && independent.workerLimit == 52)
        print("PASS independent RAM-ready queue and active analysis count exclude download/memory waits")
        let acceleratedQueue = SimilarityScanProgress(event: ["stage":"analysing", "completed":14,"total":83,"active":2,
            "counts":["files_discovered":83],"work":["encoding":2,"ready":67,"waiting_memory":0,
                "waiting_accelerator":67,"accelerator_active":2,"accelerator_limit":2,
                "analysis_memory_bytes":UInt64(1 << 30),"analysis_memory_limit":UInt64(52 << 30)]])
        precondition(acceleratedQueue.queuedFiles == 67 && acceleratedQueue.waitingAcceleratorFiles == 67)
        precondition(acceleratedQueue.waitingSummary == "67 waiting for accelerated processing")
        precondition(!acceleratedQueue.waitingSummary.contains("memory"), "An occupied accelerator must not be described as full RAM")
        let mixedWaits = SimilarityScanProgress(event: ["stage":"analysing", "work":["waiting_memory":2,"waiting_worker":3]])
        precondition(mixedWaits.waitingSummary == "2 waiting for memory · 3 waiting for a processing slot")
        print("PASS accelerator, processing-slot and memory waits report their actual constraint")
        let ram = SimilarityScanProgress(event: ["stage":"analysing", "work":[
            "original_memory_bytes":UInt64(6 << 30),"original_memory_limit":UInt64(12 << 30),"analysis_memory_limit":UInt64(52 << 30)]])
        precondition(ram.originalMemoryFraction == 0.5 && ram.originalMemoryLabel == "6 GB / 12 GB")
        precondition(ram.availableOriginalMemoryLabel == "6 GB" && ram.analysisMemoryLimit == 52 << 30)
        precondition(SimilarityScanProgress().originalMemoryFraction == 0)
        let streaming = SimilarityScanProgress(event: ["stage":"analysing", "completed":5, "active":2, "discovery_complete":false,
            "counts":["files_discovered":20, "files_total":NSNull(), "files_ready":5]])
        precondition(streaming.foundFiles == 20 && streaming.queuedFiles == 13 && streaming.activeFiles == 2)
        precondition(streaming.fraction == nil && streaming.displayTitle == "Finding and analysing files")
        let draining = SimilarityScanProgress(event: ["stage":"analysing", "completed":5, "active":2, "discovery_complete":true,
            "counts":["files_discovered":20, "files_total":20, "files_ready":5]])
        precondition(draining.fraction == 0.25 && draining.queuedFiles == 13)
        activity.begin(.similarityLocal, scope: "/Local", message: "Comparing local files")
        activity.begin(.similarityCloud, scope: "/Cloud", message: "Comparing cloud files")
        activity.reset(keeping: [.similarityLocal])
        precondition(activity.activeTasks.map(\.kind) == [.similarityLocal])
        print("PASS 5% minimum score, honest stage progress, independent state and local activity surviving account reset")

        // Automatic recovery from an interrupted scan. Real delays are minutes;
        // these run on a compressed schedule past its final delay.
        precondition(coordinator.cloud.performAutoResume != nil && coordinator.local.performAutoResume != nil,
                     "The coordinator must supply the resume action each model schedules")
        func settle(_ seconds: Double = 0.2) async throws {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        let recovering = SimilarityScanModel(source: .cloud, activity: FinderTaskActivityStore())
        var recoveryAttempts = 0
        recovering.autoResumeDelays = [0.02, 0.02, 0.02]
        recovering.performAutoResume = { recoveryAttempts += 1 }
        recovering.setFixtureInterrupted()
        precondition(recovering.isAutoResuming && recovering.autoResumeAttempt == 1)
        try await settle()
        precondition(recoveryAttempts == 1 && !recovering.isAutoResuming, "An interrupted scan must resume itself")

        // A long outage keeps retrying at the last delay.
        recovering.setFixtureInterrupted(); try await settle()
        recovering.setFixtureInterrupted(); try await settle()
        precondition(recoveryAttempts == 3 && recovering.autoResumeAttempt == 3)
        recovering.setFixtureInterrupted(); try await settle()
        precondition(recoveryAttempts == 4 && recovering.autoResumeAttempt == 4,
                     "Recovery must keep trying after the final backoff interval")

        // Headway on a resumed run returns the whole budget.
        recovering.setFixtureResumedProgress(analysed: 40)
        precondition(recovering.autoResumeAttempt == 0, "Progress must restore the recovery budget")
        recovering.setFixtureInterrupted()
        precondition(recovering.autoResumeAttempt == 1 && recovering.isAutoResuming)

        // A pause the user asked for is intent, not a fault: nothing resumes.
        let held = SimilarityScanModel(source: .local, activity: FinderTaskActivityStore())
        var heldAttempts = 0
        held.autoResumeDelays = [0.02]
        held.performAutoResume = { heldAttempts += 1 }
        held.setFixtureInterrupted()
        held.cancelAutoResume(resettingAttempts: true)
        try await settle()
        precondition(heldAttempts == 0 && held.autoResumeAttempt == 0 && !held.isAutoResuming,
                     "A user action must end automatic recovery")

        // Cancelling mid-countdown must not let a queued attempt through.
        let cancelled = SimilarityScanModel(source: .cloud, activity: FinderTaskActivityStore())
        var cancelledAttempts = 0
        cancelled.autoResumeDelays = [0.05]
        cancelled.performAutoResume = { cancelledAttempts += 1 }
        cancelled.setFixtureInterrupted()
        cancelled.cancel()
        try await settle()
        precondition(cancelledAttempts == 0, "Cancel Scan must stop a pending automatic resume")
        precondition(!cancelled.isPaused && !cancelled.interrupted && cancelled.report?.status == "cancelled",
                     "Cancelling an interrupted scan must open its report even without a live helper")
        print("PASS interrupted scans retry beyond the final backoff, reset on progress and obey user intent")

        // Engine status notes must never mask or replace a real failure.
        let noisy = """
            error: the drive refused this request
            note: refresh token rotated; shared session updated
            """
        precondition(FileSearchIndex.withoutStatusNotes(noisy) == "error: the drive refused this request")
        precondition(FileSearchIndex.withoutStatusNotes("note: refresh token rotated; shared session updated").isEmpty)
        let secretive = """
            note: refresh token rotated; update PIKPAK_REFRESH_TOKEN to:
              super-secret-token-value
            warning: storage quota unavailable
            """
        let filtered = FileSearchIndex.withoutStatusNotes(secretive)
        precondition(filtered == "warning: storage quota unavailable",
                     "A note's indented continuation can carry a token and must go with it")
        precondition(FileSearchIndex.withoutStatusNotes("warning: disk almost full") == "warning: disk almost full")
        print("PASS benign engine notes are dropped from diagnostics without hiding warnings or tokens")

        // Exercise the real async process/JSONL/report adapter without a login.
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("similarity-ui-model-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let files = root.appendingPathComponent("files")
        try manager.createDirectory(at: files, withIntermediateDirectories: true)
        let text = String(repeating: "The garden plan includes a pond, flowers and oak trees. ", count: 50)
        for name in ["one.txt", "two.txt"] { try text.write(to: files.appendingPathComponent(name), atomically: true, encoding: .utf8) }
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let scan = coordinator.local
        scan.localURLs = [files]; scan.families = ["text"]; scan.threshold = 0.05
        coordinator.configuration = { source in
            SimilarityConfiguration(executable: resources.appendingPathComponent("pikpak"), models: resources.appendingPathComponent("FileTwinModels"),
                worker: resources.appendingPathComponent("filetwin-worker"), dataDirectory: root.appendingPathComponent(source.rawValue),
                temporaryDirectory: root.appendingPathComponent("temporary"), environment: [:])
        }
        coordinator.start(scan)
        precondition(scan.isRunning)
        let deadline = Date().addingTimeInterval(30)
        while scan.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        precondition(!scan.isRunning && scan.error == nil, scan.error ?? "Scan timed out")
        let groupDeadline = Date().addingTimeInterval(15)
        while (scan.results.isIndexing || scan.results.isGrouping) && Date() < groupDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(!scan.results.isGrouping && scan.results.groupingError == nil && scan.results.groups.count == 1,
                     scan.results.groupingError ?? "Expected a saved-matrix group")
        precondition(scan.report?.analysedFiles == 2 && scan.report?.totalGroups == 1 && scan.report?.files?.count == 2)
        precondition(scan.report?.threshold == 0.05)
        precondition(coordinator.cloud.report == nil)
        precondition(activity.tasks.first(where: { $0.kind == .similarityLocal })?.state == .completed)
        let leftovers = try manager.contentsOfDirectory(atPath: root.appendingPathComponent("temporary").path)
        precondition(leftovers.isEmpty)
        while scan.results.isIndexing { try await Task.sleep(nanoseconds: 10_000_000) }
        let reference = scan.report!.files![0]
        scan.results.select(reference.id)
        let queryDeadline = Date().addingTimeInterval(10)
        while scan.results.isLoading && Date() < queryDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(scan.results.error == nil && scan.results.related.count == 1, scan.results.error ?? "Expected a saved score row")
        precondition(scan.results.related[0].score == 1 && scan.results.related[0].identical)
        scan.results.minimumScore = 0.05; precondition(scan.results.selectedID == reference.id && scan.results.related.count == 1)
        let finishedScanTime = scan.report?.elapsedSeconds
        for cutoff in [0.25, 0.65, 0.99, 0.9] { scan.results.minimumScore = cutoff }
        let regroupDeadline = Date().addingTimeInterval(15)
        while scan.results.isGrouping && Date() < regroupDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(scan.results.groups.count == 1 && scan.results.groups[0].members.count == 2 && scan.results.groupingError == nil)
        precondition(scan.results.minimumScore == 0.9 && scan.results.selectedID == reference.id)
        precondition(!scan.isRunning && scan.report?.elapsedSeconds == finishedScanTime, "Regrouping must not restart analysis")
        scan.results.selectNode(scan.results.groups[0].id)
        precondition(scan.results.selectedGroup != nil && scan.results.selectedFile == nil)
        scan.results.showAllFiles(); precondition(!scan.results.browseGroups && scan.results.selectedFile != nil)
        print("PASS real local scan, saved per-file scores, 5% filtering without a rescan, footer completion and cleanup")
        print("PASS saved-matrix groups, rapid threshold cancellation, latest result only and selection across group/file modes")

        let treeFiles = (0..<5).map { index in
            SimilarityFile(id: "tree-\(index)", name: index < 2 ? "Same name.txt" : "File \(index).txt",
                path: "/Projects/\(index % 2 == 0 ? "Drafts" : "Final")/File \(index).txt", bytes: 100,
                family: "text", localPath: nil, cloudId: nil, ancestors: [], state: index == 4 ? "unsupported" : "ready")
        }
        let fixtureReport = SimilarityReport(source: .local, scope: ["/Projects"], status: "partial", threshold: 0.9,
            scannedFiles: 5, analysedFiles: 4, skippedFiles: 1, downloadedBytes: 0, totalGroups: 0, groups: [], issues: [], truncated: false,
            coverage: "Partial", elapsedSeconds: 1, files: treeFiles)
        let review = SimilarityResultsModel(); review.load(fixtureReport, configuration: nil)
        while review.isIndexing { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(review.index?.files.count == 5 && review.index?.byID.count == 5)
        precondition(review.index?.filteredRoots("Drafts").first?.fileCount == 3)
        review.setFixtureRow(.init(fileId: "tree-0", entries: [.init(fileId: "tree-1", score: 0.9123), .init(fileId: "tree-2", score: 0.0599), .init(fileId: "tree-3", score: 0)], unavailable: ["file_unavailable":1], omitted: 0))
        review.select("tree-0")
        while review.isLoading { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(review.related.map(\.id) == ["tree-1"])
        review.minimumScore = 0.05; precondition(review.related.map(\.id) == ["tree-1", "tree-2"])
        review.minimumScore = 0.06; precondition(review.related.map(\.id) == ["tree-1"], "Filter full-precision scores, not rounded display percentages")
        review.setMinimumScoreFromSlider(0.8700000000000001); precondition(review.minimumScore == 0.87)
        review.minimumScore = 0.06
        review.showAllScores = true; precondition(review.related.map(\.id) == ["tree-1", "tree-2", "tree-3"], "All scores includes the saved zero score")
        review.showAllScores = false
        review.identicalOnly = true; precondition(review.related.isEmpty)
        review.identicalOnly = false; review.select("tree-4"); precondition(review.selectedFile?.state == "unsupported")
        review.setFixtureGroups([.init(id: "group:small", members: [treeFiles[0], treeFiles[1]], minimumScore: 0.95, identical: false)], at: 0.9)
        review.browseGroups = true; review.minimumScore = 0.9; review.selectNode("group:small")
        review.setFixtureGroups([.init(id: "group:merged", members: [treeFiles[0], treeFiles[1], treeFiles[2]], minimumScore: 0.85, identical: false)], at: 0.8)
        review.minimumScore = 0.8
        precondition(review.selectedGroupID == "group:merged", "The selected group must follow its members when groups merge")
        review.reset(); precondition(review.index == nil && review.selectedID == nil)
        print("PASS file-tree identity, unmatched/failed files, true pair scores, precision filtering, unknown scores and account reset")

        // Keep discovery open until cancellation, rather than racing a sleep
        // against a tiny scan that can finish first in an optimized build.
        let streamedFile = files.appendingPathComponent("proposal.txt")
        try text.write(to: streamedFile, atomically: true, encoding: .utf8)
        scan.streamExternalSources = { emit in
            try await emit(.init(id: "streamed-text", name: "proposal.txt", path: streamedFile.path,
                                 size: UInt64(text.utf8.count), localPath: streamedFile.path))
            try await Task.sleep(nanoseconds: 30_000_000_000)
        }
        scan.resolveExternalSource = { _, _, _ in streamedFile }
        coordinator.start(scan)
        let firstFileDeadline = Date().addingTimeInterval(10)
        while scan.isRunning && scan.progress.analysed == 0 && Date() < firstFileDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(scan.isRunning && scan.progress.analysed == 1 && !scan.progress.discoveryComplete)
        scan.cancel()
        let cancelDeadline = Date().addingTimeInterval(20)
        while scan.isRunning && Date() < cancelDeadline { try await Task.sleep(nanoseconds: 50_000_000) }
        precondition(!scan.isRunning && scan.error == nil)
        precondition(scan.report?.status == "cancelled" && scan.report?.analysedFiles == 1,
                     "Cancel must open the partial report instead of remaining paused")
        precondition(scan.report?.files?.contains(where: { $0.id == "streamed-text" }) == true,
                     "Cancelled scans must preserve the analysed file inventory")
        precondition(scan.report?.coverage.contains("incomplete") == true)
        precondition(activity.tasks.first(where: { $0.kind == .similarityLocal })?.state == .cancelled)
        precondition(!scan.isPaused && scan.savedSession?.state == "cancelled", "Cancel opens results and retains a resumable checkpoint")
        precondition(!scan.retainsOriginalsInRAM && scan.processIdentifier == nil, "Cancel must finish the helper before opening its report")
        precondition(scan.autoResumeDeadline == nil && !scan.isAutoResuming)
        while scan.results.isIndexing { try await Task.sleep(nanoseconds:10_000_000) }
        precondition(scan.results.index?.files.count == 1, "The partial inventory must be available in the results browser")
        precondition(SimilaritySessionStore.loadReport(scan.resultConfiguration!,id:scan.savedSession!.id)?.status == "cancelled")
        scan.clearSession()
        for _ in 0..<500 { if scan.processIdentifier == nil { break }; try await Task.sleep(nanoseconds:20_000_000) }
        precondition(scan.processIdentifier == nil)
        let cancelledLeftovers = try manager.contentsOfDirectory(atPath: root.appendingPathComponent("temporary").path)
        precondition(cancelledLeftovers.isEmpty)
        print("PASS Cancel opens the saved partial report, stops providers and removes temporary copies; Clear removes saved results")
        scan.detachPausedForRecovery()

        // Exercise the Photos transport with synthetic bytes, without opening
        // a personal Photos library or exporting an original to disk.
        let memoryContent = Data((text + "Memory-only Photos fixture.").utf8)
        var pipeUsed: URL?
        scan.externalTitle = "Apple Photos"; scan.externalScopeNames = ["Synthetic album"]
        scan.streamExternalSources = { emit in
            try await emit(.init(id: "asset:memory-fixture", name: "memory.txt", path: "Photos/memory.txt",
                                 size: UInt64(memoryContent.count), localPath: nil))
        }
        scan.resolveExternalSource = { _, _, _ in
            preconditionFailure("Photos similarity must not invoke the file-export resolver")
        }
        scan.resolveExternalMemorySource = { _, pipe, capacity, _ in
            precondition(capacity >= memoryContent.count)
            pipeUsed = pipe
            let handle = try SimilarityMemoryPipe.open(pipe)
            defer { try? handle.close() }
            try handle.write(contentsOf: memoryContent)
            let attributes = try manager.attributesOfItem(atPath: pipe.path)
            var pipeStat = stat()
            precondition(lstat(pipe.path, &pipeStat) == 0 && pipeStat.st_mode & S_IFMT == S_IFIFO)
            precondition((attributes[.size] as? NSNumber)?.intValue == 0)
            return pipe
        }
        coordinator.start(scan)
        let memoryDeadline = Date().addingTimeInterval(15)
        while scan.isRunning && Date() < memoryDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(!scan.isRunning && scan.error == nil && scan.report?.analysedFiles == 1, scan.error ?? "Memory pipe did not finish")
        precondition(pipeUsed != nil && !manager.fileExists(atPath: pipeUsed!.path))
        do {
            let handle = try SimilarityMemoryPipe.open(streamedFile)
            try? handle.close(); preconditionFailure("A regular file must not be accepted as an IPC pipe")
        } catch { }
        let unchangedOriginal = try String(contentsOf: streamedFile)
        precondition(unchangedOriginal == text)
        print("PASS Photos bytes streamed through a zero-size pipe, analysed from RAM, cleaned up, and regular-file replacement rejected")

    }
}

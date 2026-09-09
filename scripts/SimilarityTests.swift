import AppKit
import Foundation

@main struct SimilarityTests {
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
        activity.begin(.similarityLocal, scope: "/Local", message: "Comparing local files")
        activity.begin(.similarityCloud, scope: "/Cloud", message: "Comparing cloud files")
        activity.reset(keeping: [.similarityLocal])
        precondition(activity.activeTasks.map(\.kind) == [.similarityLocal])
        print("PASS 5% minimum score, honest stage progress, independent state and local activity surviving account reset")

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
        print("PASS real local scan, saved per-file scores, 5% filtering without a rescan, footer completion and cleanup")

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
        review.identicalOnly = true; precondition(review.related.isEmpty)
        review.identicalOnly = false; review.select("tree-4"); precondition(review.selectedFile?.state == "unsupported")
        review.reset(); precondition(review.index == nil && review.selectedID == nil)
        print("PASS file-tree identity, unmatched/failed files, true pair scores, precision filtering, unknown scores and account reset")

        let largeText = String(repeating: text, count: 200)
        for index in 0..<25 { try largeText.write(to: files.appendingPathComponent("long-\(index).txt"), atomically: true, encoding: .utf8) }
        coordinator.start(scan)
        try await Task.sleep(nanoseconds: 80_000_000)
        scan.cancel()
        let cancelDeadline = Date().addingTimeInterval(20)
        while scan.isRunning && Date() < cancelDeadline { try await Task.sleep(nanoseconds: 50_000_000) }
        precondition(!scan.isRunning && scan.error == nil)
        precondition(activity.tasks.first(where: { $0.kind == .similarityLocal })?.state == .cancelled)
        let cancelledLeftovers = try manager.contentsOfDirectory(atPath: root.appendingPathComponent("temporary").path)
        precondition(cancelledLeftovers.isEmpty)
        print("PASS cancelling a real scan while reading content, with terminal footer status and cleanup")
    }
}

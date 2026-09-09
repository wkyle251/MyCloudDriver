import AppKit
import Foundation

@main struct SimilarityTests {
    @MainActor static func main() async throws {
        let suite = "com.wky.PikPakSimilarityTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try DownloaderModel.testSimilarityScope(defaults: defaults)
        try DownloaderModel.testTaskActivity(defaults: defaults)
        precondition(SimilarityScanModel.numericInput("1.2a٣-4") == "124")
        precondition(SimilarityScanModel.integer("0", maximum: 1000) == nil)
        precondition(SimilarityScanModel.integer("1.5", maximum: 1000) == nil)
        precondition(SimilarityScanModel.integer("1001", maximum: 1000) == nil)
        precondition(SimilarityScanModel.integer("20", maximum: 1000) == 20)
        let activity = FinderTaskActivityStore()
        let coordinator = FileSimilarityCoordinator(activity: activity)
        coordinator.local.localURLs = [URL(fileURLWithPath: "/tmp/synthetic.txt")]
        coordinator.local.threshold = 0.8
        precondition(coordinator.cloud.localURLs.isEmpty && coordinator.cloud.threshold == 0.9)
        precondition(coordinator.local.canStart && !coordinator.cloud.canStart)
        coordinator.local.maxFileMB = "0"; precondition(!coordinator.local.canStart)
        coordinator.local.maxFileMB = "1024"
        activity.begin(.similarityLocal, scope: "/Local", message: "Comparing local files")
        activity.begin(.similarityCloud, scope: "/Cloud", message: "Comparing cloud files")
        activity.reset(keeping: [.similarityLocal])
        precondition(activity.activeTasks.map(\.kind) == [.similarityLocal])
        print("PASS numeric limits, independent scan state and local activity surviving account reset")

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
        scan.localURLs = [files]; scan.families = ["text"]
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
        precondition(scan.report?.analysedFiles == 2 && scan.report?.totalGroups == 2)
        precondition(coordinator.cloud.report == nil)
        precondition(activity.tasks.first(where: { $0.kind == .similarityLocal })?.state == .completed)
        let leftovers = try manager.contentsOfDirectory(atPath: root.appendingPathComponent("temporary").path)
        precondition(leftovers.isEmpty)
        print("PASS real local scan process, streamed progress, decoded groups, footer completion and cleanup")

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

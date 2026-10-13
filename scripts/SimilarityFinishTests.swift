import AppKit
import Foundation

/// Real helper, generated text and a deliberately uncooperative inventory.
/// No mounted disk or existing user file is opened.
@main struct SimilarityFinishTests {
    @MainActor final class Feed {
        var hold = true
        var waiter: CheckedContinuation<Void, Never>?
        var resolved: [String: Int] = [:]
        func release() { hold = false; waiter?.resume(); waiter = nil }
    }
    @MainActor static func until(_ condition: () -> Bool, seconds: Double = 15, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(condition(), "Timed out at line \(line)")
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        let fm = FileManager.default, resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = fm.temporaryDirectory.appendingPathComponent("SimilarityFinish-\(UUID())").resolvingSymlinksInPath()
        let inputs = root.appendingPathComponent("inputs")
        try fm.createDirectory(at: inputs, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let content = String(repeating: "A garden with green trees and flowers. ", count: 30)
        for name in ["one.txt", "two.txt", "three.txt"] {
            try content.write(to: inputs.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let configuration = SimilarityConfiguration(executable: resources.appendingPathComponent("pikpak"),
            models: resources.appendingPathComponent("FileTwinModels"), worker: resources.appendingPathComponent("filetwin-worker"),
            dataDirectory: root.appendingPathComponent("data"), temporaryDirectory: root.appendingPathComponent("temp"), environment: [:])
        func configure(_ owner: FileSimilarityCoordinator, _ feed: Feed) {
            owner.configuration = { _ in configuration }
            let scan = owner.local
            scan.externalTitle = "Fixture Drive"; scan.externalScopeNames = ["Generated files"]
            scan.localURLs = [inputs]; scan.families = ["text"]
            scan.streamExternalSources = { emit in
                for (index, name) in ["one.txt", "two.txt", "three.txt"].enumerated() {
                    if index == 1 && feed.hold { await withCheckedContinuation { feed.waiter = $0 } }
                    try Task.checkCancellation()
                    let file = inputs.appendingPathComponent(name)
                    try await emit(.init(id: name, name: name, path: file.path, size: UInt64(content.utf8.count), localPath: file.path))
                }
            }
            scan.resolveExternalSource = { id, _, _ in feed.resolved[id, default: 0] += 1; return inputs.appendingPathComponent(id) }
        }
        let owner = FileSimilarityCoordinator(activity: FinderTaskActivityStore()), feed = Feed()
        configure(owner, feed)
        let scan = owner.local
        let owned = root.appendingPathComponent("provider-owned")
        try fm.createDirectory(at: owned, withIntermediateDirectories: false)
        scan.takeExternalScopeCleanup = { { try? fm.removeItem(at: owned) } }
        owner.start(scan)
        try await until { scan.progress.analysed == 1 && feed.waiter != nil }
        let sessionID = scan.savedSession!.id, pid = scan.processIdentifier!
        let checkpoint = SimilaritySessionStore.directory(configuration, id: sessionID)
        scan.pause()
        try await until { scan.isPaused && !scan.isRunning }
        precondition(scan.processIdentifier == pid && scan.canFinish)
        owner.resume(scan)
        precondition(scan.processIdentifier == pid && scan.isRunning)
        scan.pause()
        try await until { scan.isPaused }
        let finishingAt = Date()
        scan.finishScan()
        precondition(scan.isFinishing && !scan.canPause && !scan.canFinish)
        try await until({ !scan.isRunning }, seconds: 3)
        precondition(Date().timeIntervalSince(finishingAt) < 3)
        precondition(scan.report?.status == "finished" && scan.report?.analysedFiles == 1 && scan.canResumeReport)
        precondition(scan.processIdentifier == nil && !scan.isPaused && !scan.isFinishing && scan.error == nil)
        precondition(scan.savedSession?.state == "finished" && scan.report?.files?.count == 1)
        precondition(SimilaritySessionStore.loadReport(configuration, id: sessionID)?.status == "finished")
        precondition(fm.fileExists(atPath: owned.path), "Provider cleanup must wait for its writer, without blocking the report")
        feed.release()
        try await until { !fm.fileExists(atPath: owned.path) }
        print("PASS Pause/Resume keeps the helper; Finish while paused returns a saved resumable report without waiting for blocked inventory; cleanup waits safely")

        scan.detachPausedForRecovery()
        let reopened = FileSimilarityCoordinator(activity: FinderTaskActivityStore()), resumedFeed = Feed()
        resumedFeed.hold = false; configure(reopened, resumedFeed)
        reopened.refreshRecovery()
        let saved = reopened.local.recoverableSessions.first { $0.id == sessionID }!
        reopened.resume(reopened.local, session: saved)
        precondition(!reopened.local.isRunning && reopened.local.report?.status == "finished" && reopened.local.canResumeReport)
        precondition(resumedFeed.resolved.isEmpty, "Opening a report must not start the scanner")
        reopened.resume(reopened.local)
        try await until { !reopened.local.isRunning }
        precondition(reopened.local.report?.status == "completed" && reopened.local.report?.analysedFiles == 3)
        precondition(reopened.local.report?.scoresRetained == 3)
        precondition(resumedFeed.resolved["one.txt"] == nil && resumedFeed.resolved["two.txt"] == 1 && resumedFeed.resolved["three.txt"] == 1)
        precondition(!fm.fileExists(atPath: checkpoint.appendingPathComponent("finish").path))
        precondition(!reopened.local.canResumeReport && reopened.local.error == nil)
        let matrix = configuration.dataDirectory.appendingPathComponent("runs").appendingPathComponent(reopened.local.report!.runId! + ".sqlite3")
        precondition(fm.fileExists(atPath: matrix.path))
        reopened.local.clearSession()
        precondition(reopened.local.report == nil && reopened.local.savedSession == nil)
        precondition(!fm.fileExists(atPath: checkpoint.path) && !fm.fileExists(atPath: matrix.path))
        for name in ["one.txt", "two.txt", "three.txt"] {
            let value = try String(contentsOf: inputs.appendingPathComponent(name), encoding: .utf8)
            precondition(value == content)
        }
        print("PASS saved reports open without scanning; Resume reuses completed files and compares all results; Delete Report removes record and scores while preserving originals")

        let preparing = SimilarityScanModel(source: .local, activity: FinderTaskActivityStore()), blocked = Feed()
        preparing.externalTitle = "Fixture"; preparing.externalScopeNames = ["Generated files"]
        preparing.inventoryExternalSources = {
            await withCheckedContinuation { blocked.waiter = $0 }
            return [.init(id: "unused", name: "unused.txt", path: "unused.txt", size: 1, localPath: nil)]
        }
        preparing.start(configuration)
        try await until { blocked.waiter != nil }
        preparing.finishScan()
        precondition(!preparing.isRunning && preparing.report?.status == "finished" && preparing.canResumeReport)
        preparing.clearSession(); blocked.release()
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(preparing.report == nil && !preparing.isRunning && preparing.savedSession == nil)
        print("PASS Finish during blocked preparation returns promptly; deleting the record fences stale callbacks")
    }
}

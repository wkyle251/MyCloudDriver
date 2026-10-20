import AppKit
import Foundation

@main struct SimilarityInventoryTests {
    @MainActor static func main() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("similarity-inventory-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }

        let refresh = root.appendingPathComponent("inventory-generated.jsonl")
        try Data().write(to: refresh)
        let sourceRoot = root.appendingPathComponent("copies")
        precondition(SimilarityInventoryWriter.refreshURL(event: ["inventory_file":refresh.path], sourceRoot: sourceRoot) != nil)
        let alias = root.appendingPathComponent("inventory-alias.jsonl")
        try manager.createSymbolicLink(at: alias, withDestinationURL: refresh)
        precondition(SimilarityInventoryWriter.refreshURL(event: ["inventory_file":alias.path], sourceRoot: sourceRoot) == nil)
        precondition(SimilarityInventoryWriter.refreshURL(event: ["inventory_file":refresh.path], sourceRoot: sourceRoot.appendingPathComponent("outside")) == nil)
        try Data("occupied".utf8).write(to: refresh)
        precondition(SimilarityInventoryWriter.refreshURL(event: ["inventory_file":refresh.path], sourceRoot: sourceRoot) == nil)
        print("PASS provider refresh accepts only an empty regular inventory in the owning request directory")

        let progress = SimilarityScanModel(source: .local, activity: FinderTaskActivityStore())
        progress.setFixtureProgress(["event":"progress","stage":"analysing","completed":100,"total":100,
            "counts":["files_discovered":100,"files_ready":100]])
        progress.setFixtureProgress(["event":"inventory_check"])
        precondition(progress.progress.stage == .checking && progress.progress.fraction == nil)
        progress.setFixtureProgress(["event":"discovery","found":0,"complete":false])
        precondition(progress.progress.stage == .checking)
        progress.setFixtureProgress(["event":"inventory_changed","total":2,"added":0,"removed":98,"changed":0])
        precondition(progress.progress.foundFiles == 2 && progress.progress.total == 2 && progress.progress.completed == 0)
        print("PASS checking progress stays indeterminate and deleted files reduce the displayed inventory")

        let providerRoot = root.appendingPathComponent("provider")
        try manager.createDirectory(at: providerRoot, withIntermediateDirectories: true)
        let gone = providerRoot.appendingPathComponent("gone.txt"), kept = providerRoot.appendingPathComponent("kept.txt")
        try Data("gone".utf8).write(to: gone); try Data("kept".utf8).write(to: kept)
        let selected = try [ICloudDriveProvider.item(gone), ICloudDriveProvider.item(kept)]
        let provider = ICloudDriveProvider(rootURL: providerRoot, kind: .local)
        try manager.removeItem(at: gone)
        let listed = try await provider.scanItems(selected, location: provider.root, progress: { _ in })
        precondition(listed.map(\.name) == ["kept.txt"])
        let disconnected = root.appendingPathComponent("disconnected")
        try manager.moveItem(at: providerRoot, to: disconnected)
        do {
            _ = try await provider.scanItems([], location: provider.root, progress: { _ in })
            preconditionFailure("An unavailable scan root must not certify an empty inventory")
        } catch {}
        print("PASS selected-file deletion is skipped and an unavailable drive stays an error")

        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let engine = CommandLine.arguments.count > 2 ? URL(fileURLWithPath: CommandLine.arguments[2]) : resources.appendingPathComponent("pikpak")
        let files = root.appendingPathComponent("files")
        try manager.createDirectory(at: files, withIntermediateDirectories: true)
        let original = String(repeating: "The garden has a pond, flowers, oak trees and a wooden bench. ", count: 60)
        let edited = String(repeating: "The station has a train, platforms, signals and a ticket office. ", count: 60)
        for name in ["keep.txt", "remove.txt", "edit.txt"] {
            try original.write(to: files.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let scan = SimilarityScanModel(source: .local, activity: FinderTaskActivityStore())
        scan.externalTitle = "Generated local files"; scan.externalScopeNames = [files.path]
        scan.families = ["text"]; scan.threshold = 0.8
        var rounds = 0, resolves: [String:Int] = [:]
        scan.streamExternalSources = { emit in
            rounds += 1
            if rounds == 2 {
                try manager.removeItem(at: files.appendingPathComponent("remove.txt"))
                try original.write(to: files.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
                try edited.write(to: files.appendingPathComponent("edit.txt"), atomically: true, encoding: .utf8)
            } else if rounds == 4 {
                // This refresh follows comparison: changes here must also
                // invalidate its ordinals before the final report is returned.
                try manager.removeItem(at: files.appendingPathComponent("new.txt"))
                try original.write(to: files.appendingPathComponent("late.txt"), atomically: true, encoding: .utf8)
            }
            for url in try manager.contentsOfDirectory(at: files, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
                let item = try ICloudDriveProvider.item(url)
                try await emit(.init(id:item.id, name:item.name, path:url.path, size:item.bytes ?? 0,
                    localPath:url.path, revision:item.modified.map { String($0.timeIntervalSince1970) }))
            }
        }
        scan.resolveExternalSource = { id, _, _ in
            let url = URL(string: id)!
            resolves[url.lastPathComponent, default: 0] += 1
            return url
        }
        let config = SimilarityConfiguration(executable:engine, models:resources.appendingPathComponent("FileTwinModels"),
            worker:resources.appendingPathComponent("filetwin-worker"), dataDirectory:root.appendingPathComponent("index"),
            temporaryDirectory:root.appendingPathComponent("temporary"), environment:[:])
        func finish() async throws {
            let deadline = Date().addingTimeInterval(90)
            while scan.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 25_000_000) }
            precondition(!scan.isRunning && !scan.isPaused && scan.error == nil, scan.error ?? "Generated scan did not complete")
        }
        scan.start(config)
        try await finish()
        precondition(rounds == 6, "Expected initial listing and checks around both changed analysis/comparison passes: \(rounds)")
        precondition(Set(scan.report?.files?.map(\.name) ?? []) == ["keep.txt", "edit.txt", "late.txt"])
        precondition(scan.report?.analysedFiles == 3 && scan.report?.failedFiles == 0)
        precondition(resolves["keep.txt"] == 1 && resolves["edit.txt"] == 2, "Unchanged originals must reuse analysis; edited ones must be read again: \(resolves)")
        precondition(scan.report?.scoresRetained == 3)
        print("PASS actual helper catches additions, deletions and edits during analysis and after comparison; unchanged originals are acquired once")

        let saved = scan.savedSession!
        try manager.removeItem(at: files.appendingPathComponent("late.txt"))
        scan.start(config, resuming:saved)
        try await finish()
        precondition(Set(scan.report?.files?.map(\.name) ?? []) == ["keep.txt", "edit.txt"])
        precondition(scan.report?.analysedFiles == 2 && scan.report?.scoresRetained == 1)
        precondition(resolves["keep.txt"] == 1 && resolves["edit.txt"] == 2)
        print("PASS a resumed sealed comparison refreshes membership and never reuses scores for removed files")

        for url in try manager.contentsOfDirectory(at: files, includingPropertiesForKeys: nil) { try manager.removeItem(at: url) }
        scan.start(config, resuming:scan.savedSession!)
        try await finish()
        precondition(scan.report?.files?.isEmpty == true && scan.report?.analysedFiles == 0 && scan.report?.scoresRetained == 0)
        print("PASS deleting the entire file set produces an empty result without stale groups or comparisons")

        let stable = root.appendingPathComponent("stable-volume")
        try manager.createDirectory(at: stable, withIntermediateDirectories: true)
        for name in ["one.txt", "two.txt", "three.txt"] {
            try original.write(to: stable.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let stableScan = SimilarityScanModel(source: .local, activity: FinderTaskActivityStore())
        stableScan.externalTitle = "Generated remount metadata"
        stableScan.externalScopeNames = [stable.path]; stableScan.families = ["text"]
        var stableRounds = 0, stableResolves = 0
        stableScan.streamExternalSources = { emit in
            stableRounds += 1
            for url in try manager.contentsOfDirectory(at: stable, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
                let item = try ICloudDriveProvider.item(url)
                var revision = item.revision!.split(separator: ":").map(String.init)
                if stableRounds == 1 { revision[0] = String(UInt64(revision[0])! + 4) }
                try await emit(.init(id: item.id, name: item.name, path: url.path, size: item.bytes ?? 0,
                    localPath: url.path, revision: revision.joined(separator: ":"), provider: "local"))
            }
        }
        stableScan.resolveExternalSource = { id, _, _ in stableResolves += 1; return URL(string: id)! }
        stableScan.start(config)
        let stableDeadline = Date().addingTimeInterval(60)
        while stableScan.isRunning && Date() < stableDeadline { try await Task.sleep(nanoseconds: 25_000_000) }
        precondition(!stableScan.isRunning && !stableScan.isPaused && stableScan.error == nil, stableScan.error ?? "Scan did not publish results")
        precondition(stableScan.report?.status == "completed" && stableScan.report?.analysedFiles == 3)
        precondition(stableScan.report?.files?.count == 3 && stableScan.report?.scoresRetained == 3)
        precondition(stableRounds == 3, "Unchanged files must finish after checks around comparison, without another analysis pass: \(stableRounds)")
        precondition(stableResolves == 3)
        precondition(SimilaritySessionStore.loadReport(config, id: stableScan.savedSession!.id)?.status == "completed")
        print("PASS stale mount metadata completes one analysis pass, saves the comparison report and exposes results in the native model")

        let retries = root.appendingPathComponent("reconcile-once")
        try manager.createDirectory(at: retries, withIntermediateDirectories: true)
        for name in ["keep.txt", "edit.txt", "unavailable.txt"] {
            try original.write(to: retries.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try String(repeating: " ", count: 128).write(to: retries.appendingPathComponent("blank.txt"), atomically: true, encoding: .utf8)
        let once = SimilarityScanModel(source: .local, activity: FinderTaskActivityStore())
        once.externalTitle = "Generated reuse across changing inventories"
        once.externalScopeNames = [retries.path]; once.families = ["text"]
        var onceRounds = 0, onceResolves: [String:Int] = [:]
        once.streamExternalSources = { emit in
            onceRounds += 1
            if onceRounds == 2 || onceRounds == 4 {
                try (onceRounds == 2 ? edited : original).write(to: retries.appendingPathComponent("edit.txt"), atomically: true, encoding: .utf8)
            }
            for url in try manager.contentsOfDirectory(at: retries, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
                let item = try ICloudDriveProvider.item(url)
                try await emit(.init(id: item.id, name: item.name, path: url.path, size: item.bytes ?? 0,
                    localPath: url.path, revision: item.revision, provider: "local"))
            }
        }
        once.resolveExternalSource = { id, _, _ in
            let url = URL(string: id)!
            onceResolves[url.lastPathComponent, default: 0] += 1
            if url.lastPathComponent == "unavailable.txt" { throw CloudDriveError.message("Generated unavailable original") }
            return url
        }
        once.start(config)
        let onceDeadline = Date().addingTimeInterval(90)
        while once.isRunning && Date() < onceDeadline { try await Task.sleep(nanoseconds: 25_000_000) }
        precondition(!once.isRunning && !once.isPaused && once.error == nil, once.error ?? "Reconciliation did not publish results")
        precondition(onceRounds == 6 && once.report?.analysedFiles == 2 && once.report?.unsupportedFiles == 1 && once.report?.failedFiles == 1)
        precondition(onceResolves == ["keep.txt":1, "edit.txt":3, "blank.txt":1, "unavailable.txt":1],
            "Only the file that actually changed may be acquired again: \(onceResolves)")
        precondition(once.report?.scoresRetained == 1 && once.report?.status == "partial")
        precondition(SimilaritySessionStore.loadReport(config, id: once.savedSession!.id)?.failedFiles == 1)
        print("PASS repeated inventory changes process only the changed file; unchanged successes, exclusions and failures are acquired once and results retain diagnostics")

        let restartRoot = root.appendingPathComponent("resume-completed-outcomes")
        try manager.createDirectory(at: restartRoot, withIntermediateDirectories: true)
        for name in ["keep.txt", "pending.txt", "unavailable.txt"] {
            try original.write(to: restartRoot.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try String(repeating: " ", count: 128).write(to: restartRoot.appendingPathComponent("blank.txt"), atomically: true, encoding: .utf8)
        var holdPending = true, driveOffline = false, restartedResolves: [String:Int] = [:]
        func restartModel() -> SimilarityScanModel {
            let model = SimilarityScanModel(source: .local, activity: FinderTaskActivityStore())
            model.externalTitle = "Generated completed outcomes on restart"
            model.externalScopeNames = [restartRoot.path]; model.families = ["text"]
            model.streamExternalSources = { emit in
                if driveOffline { throw CloudDriveError.waiting("Generated drive is disconnected. Reconnect it to continue.") }
                for url in try manager.contentsOfDirectory(at: restartRoot, includingPropertiesForKeys: nil) {
                    let item = try ICloudDriveProvider.item(url)
                    try await emit(.init(id: item.id, name: item.name, path: url.path, size: item.bytes ?? 0,
                        localPath: url.path, revision: item.revision, provider: "local"))
                }
            }
            model.resolveExternalSource = { id, _, _ in
                let url = URL(string: id)!
                restartedResolves[url.lastPathComponent, default: 0] += 1
                if url.lastPathComponent == "unavailable.txt" { throw CloudDriveError.message("Generated final failure") }
                while url.lastPathComponent == "pending.txt" && holdPending { try await Task.sleep(nanoseconds: 25_000_000) }
                return url
            }
            return model
        }
        let interrupted = restartModel(); interrupted.start(config)
        let restartDeadline = Date().addingTimeInterval(90)
        while interrupted.progress.completed < 3 && Date() < restartDeadline { try await Task.sleep(nanoseconds: 25_000_000) }
        precondition(interrupted.progress.completed == 3)
        interrupted.preserveForShutdown()
        while (interrupted.processIdentifier != nil || interrupted.isRunning) && Date() < restartDeadline { try await Task.sleep(nanoseconds: 25_000_000) }
        precondition(interrupted.processIdentifier == nil && interrupted.isPaused)
        holdPending = false; driveOffline = true; restartedResolves = [:]
        let resumed = restartModel(); resumed.start(config, resuming: interrupted.savedSession!)
        while resumed.inventoryWaitReason == nil && resumed.isRunning && Date() < restartDeadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        precondition(resumed.inventoryWaitReason == "Generated drive is disconnected. Reconnect it to continue.")
        precondition(resumed.isRunning && resumed.report == nil && restartedResolves.isEmpty,
            "A disconnected drive must retain the scan, not certify an empty result or reacquire originals")
        driveOffline = false
        while resumed.isRunning && Date() < restartDeadline { try await Task.sleep(nanoseconds: 25_000_000) }
        precondition(!resumed.isRunning && !resumed.isPaused && resumed.error == nil, resumed.error ?? "Restart did not publish results")
        precondition(restartedResolves == ["pending.txt":1], "Restart must acquire only the unfinished original: \(restartedResolves)")
        precondition(resumed.report?.analysedFiles == 2 && resumed.report?.unsupportedFiles == 1 && resumed.report?.failedFiles == 1)
        precondition(resumed.inventoryWaitReason == nil)
        print("PASS a replacement helper explains a disconnected drive and recovers by reading only unfinished originals; completed successful, unsupported and failed results survive restart without reacquisition")

        let changing = root.appendingPathComponent("continuously-changing")
        try manager.createDirectory(at: changing, withIntermediateDirectories: true)
        for name in ["keep.txt", "changing.txt"] {
            try original.write(to: changing.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let bounded = SimilarityScanModel(source: .local, activity: FinderTaskActivityStore())
        bounded.externalTitle = "Generated bounded change recovery"
        bounded.externalScopeNames = [changing.path]; bounded.families = ["text"]
        bounded.autoResumeDelays = [0.01]
        var boundedRounds = 0, boundedResolves: [String:Int] = [:], automaticRestarts = 0
        bounded.performAutoResume = { automaticRestarts += 1 }
        bounded.streamExternalSources = { emit in
            boundedRounds += 1
            try (original + " Change number \(boundedRounds).").write(to: changing.appendingPathComponent("changing.txt"), atomically: true, encoding: .utf8)
            for url in try manager.contentsOfDirectory(at: changing, includingPropertiesForKeys: nil) {
                let item = try ICloudDriveProvider.item(url)
                try await emit(.init(id: item.id, name: item.name, path: url.path, size: item.bytes ?? 0,
                    localPath: url.path, revision: item.revision, provider: "local"))
            }
        }
        bounded.resolveExternalSource = { id, _, _ in
            let url = URL(string: id)!
            boundedResolves[url.lastPathComponent, default: 0] += 1
            return url
        }
        bounded.start(config)
        let boundedDeadline = Date().addingTimeInterval(90)
        while bounded.isRunning && Date() < boundedDeadline { try await Task.sleep(nanoseconds: 25_000_000) }
        try await Task.sleep(nanoseconds: 250_000_000)
        precondition(bounded.isPaused && !bounded.isAutoResuming && automaticRestarts == 0)
        precondition(boundedRounds == 10 && boundedResolves == ["keep.txt":1, "changing.txt":9], "Repeated changes must stop after the bounded passes: \(boundedRounds), \(boundedResolves)")
        precondition(bounded.savedSession?.state == "paused")
        let pausedFile = SimilaritySessionStore.directory(config, id: bounded.savedSession!.id).appendingPathComponent("session.json")
        let persistedPause = try JSONDecoder().decode(SimilaritySavedSession.self, from: Data(contentsOf: pausedFile))
        precondition(persistedPause.state == "paused")
        print("PASS constantly changing files reach the pass limit once, preserve unchanged analysis and remain paused without automatic restart")

        let largeCount = 50_000
        let prefix = "/Generated/" + String(repeating: "long-generated-folder/", count: 22)
        let largeFiles: [SimilarityFile] = (0..<largeCount).map { index in
            let name = "generated-\(index).txt", path = prefix + name
            return .init(id: "cross-native:local:" + Data(path.utf8).base64EncodedString(), name: name,
                path: path, bytes: 100, family: "text", localPath: path, cloudId: nil, ancestors: [])
        }
        let large = SimilarityReport(source: .local, scope: ["Generated large inventory"], status: "completed",
            threshold: 0.9, scannedFiles: UInt64(largeCount), analysedFiles: UInt64(largeCount), skippedFiles: 0,
            downloadedBytes: 0, totalGroups: 0, groups: [], issues: [], truncated: false,
            coverage: "Generated completed inventory", elapsedSeconds: 1, files: largeFiles)
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
        let bytes = try encoder.encode(large)
        precondition(bytes.count > 64 * 1_024 * 1_024 && bytes.count < SimilarityReportStorage.maximumBytes)
        let largeURL = root.appendingPathComponent("large-report.json")
        try bytes.write(to: largeURL)
        let loaded: (SimilarityReport?, String) = await withCheckedContinuation { continuation in
            SimilarityProcessReader().finish(reportURL: largeURL) { report, message in continuation.resume(returning: (report, message)) }
        }
        precondition(loaded.0?.files?.count == largeCount && loaded.1.isEmpty, loaded.1)
        try SimilaritySessionStore.saveReport(loaded.0!, configuration: config, id: stableScan.savedSession!.id)
        precondition(SimilaritySessionStore.loadReport(config, id: stableScan.savedSession!.id)?.files?.count == largeCount)
        print("PASS a completed report over 64 MiB loads from the helper and reopens from its saved checkpoint without restarting the scan")
    }
}

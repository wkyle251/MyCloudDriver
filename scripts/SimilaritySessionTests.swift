import AppKit
import Foundation

@main struct SimilaritySessionTests {
    @MainActor static func main() async throws {
        try recoveryWhenSelectingDrive()
        let activity = FinderTaskActivityStore()
        let cloud = FileSimilarityCoordinator(activity: activity)
        let icloud = FileSimilarityCoordinator(activity: FinderTaskActivityStore())
        let photos = FileSimilarityCoordinator(activity: FinderTaskActivityStore())
        let local = FileSimilarityCoordinator(activity: FinderTaskActivityStore())
        let options: [SimilarityDriveOption] = [
            .init(id: "pikpak", title: "PikPak", symbol: "cloud", source: .cloud),
            .init(id: "icloud", title: "iCloud Drive", symbol: "icloud", source: .local),
            .init(id: "photos", title: "Apple Photos", symbol: "photo", source: .local),
            .init(id: "local", title: "Local Disk", symbol: "internaldrive", source: .local)
        ]
        let drives = ["pikpak": cloud, "icloud": icloud, "photos": photos, "local": local]
        cloud.driveOptions = options
        cloud.resolveDrive = { drives[$0] }
        cloud.cloudScope = { _ in [.init(id: "root", name: "Cloud", path: "/", isFolder: true, size: 0, ancestors: [])] }
        var selectedScope: [Bool] = []
        icloud.externalTitle = "iCloud Drive"
        icloud.chooseDriveScope = { source, selected in
            precondition(source == .local)
            selectedScope.append(selected)
            icloud.local.externalScopeNames = ["Documents"]
        }
        cloud.selectDrive("pikpak")
        precondition(cloud.activeModel === cloud.cloud && cloud.cloud.cloudRoots.count == 1)
        cloud.cloud.threshold = 0.77
        cloud.selectDrive("icloud")
        precondition(cloud.activeCoordinator === icloud && cloud.activeModel === icloud.local)
        precondition(selectedScope == [false])
        icloud.chooseScope(true)
        precondition(selectedScope == [false, true])
        icloud.local.threshold = 0.6
        cloud.selectDrive("photos")
        precondition(cloud.activeModel === photos.local && cloud.activeModel.threshold == 0.9)
        cloud.selectDrive("local")
        precondition(cloud.activeModel === local.local)
        local.local.localURLs = [URL(fileURLWithPath: "/tmp/synthetic-local-folder")]
        cloud.selectDrive("icloud")
        precondition(cloud.activeModel.threshold == 0.6 && selectedScope == [false, true])
        cloud.selectDrive("pikpak")
        precondition(cloud.activeModel.threshold == 0.77)
        let file = SimilarityFile(id: "synthetic", name: "Example.jpg", path: "/Photos/Example.jpg", bytes: 10,
                                  family: "image", localPath: nil, cloudId: "synthetic", ancestors: [])
        var reveal: (SimilaritySource, String)?
        cloud.revealInBrowser = { reveal = ($0, $1.id) }
        cloud.reveal(file)
        precondition(reveal?.0 == .cloud && reveal?.1 == file.id)
        print("PASS four drive scopes/results are separate, scope routing and reveal use the selected drive")

        cloud.cloud.threshold = 0.5; cloud.cloud.exactDuplicates = false
        cloud.cloud.results.query = "previous search"
        cloud.cloud.results.minimumScore = 0.55; cloud.cloud.results.identicalOnly = true
        cloud.cloud.results.showAllScores = true; cloud.cloud.results.browseGroups = false
        cloud.cloud.error = "previous error"
        let oldID = cloud.cloud.sessionID
        activity.begin(.similarityCloud, scope: "/", message: "Scanning")
        activity.finish(.similarityCloud, state: .completed, message: "Complete")
        activity.dismiss(.similarityCloud)
        precondition(cloud.cloud.sessionID == oldID && cloud.cloud.threshold == 0.5, "Dismiss does not clear a scan")
        cloud.cloud.clearSession()
        precondition(cloud.cloud.sessionID != oldID && cloud.cloud.threshold == 0.9 && cloud.cloud.exactDuplicates)
        precondition(cloud.cloud.cloudRoots.isEmpty && cloud.cloud.results.query.isEmpty && cloud.cloud.error == nil)
        precondition(cloud.cloud.results.minimumScore == 0.9 && !cloud.cloud.results.identicalOnly
                     && !cloud.cloud.results.showAllScores && cloud.cloud.results.browseGroups)
        precondition(icloud.local.threshold == 0.6, "Dismissing cloud results leaves iCloud results alone")
        cloud.close()
        precondition(icloud.local.threshold == 0.6)
        precondition(!local.local.localURLs.isEmpty)
        print("PASS Clear resets the complete scan session; dismissal and closing retain drive state")

        // Clear during async preparation must cancel, clean up, and discard
        // the pending result without allowing an old callback to resurrect it.
        let active = SimilarityScanModel(source: .local, activity: FinderTaskActivityStore())
        active.externalTitle = "Test Drive"; active.externalScopeNames = ["Test Folder"]
        var cleanup = false, reset = false
        active.prepareExternalScope = {
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return [URL(fileURLWithPath: "/tmp/not-opened")]
        }
        active.cleanupExternalScope = { cleanup = true }
        active.onSessionReset = { reset = true }
        let unused = URL(fileURLWithPath: "/tmp/not-opened")
        active.start(.init(executable: unused, models: unused, worker: unused, dataDirectory: unused, temporaryDirectory: unused, environment: [:]))
        precondition(active.isRunning)
        active.clearSession()
        let deadline = Date().addingTimeInterval(3)
        while active.isRunning && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!active.isRunning && cleanup && reset && active.report == nil && active.localURLs.isEmpty)
        precondition(active.externalScopeNames.isEmpty && active.prepareExternalScope == nil && active.activity.tasks.isEmpty)
        print("PASS explicit Clear stops active preparation, cleans up, and prevents stale results")

        let inventory = SimilarityScanModel(source: .local, activity: FinderTaskActivityStore())
        inventory.externalTitle = "Test Drive"; inventory.externalScopeNames = ["Test Folder"]
        var fetched = false
        inventory.inventoryExternalSources = {
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return [.init(id: "one", name: "one.jpg", path: "Test/one.jpg", size: 1, localPath: nil)]
        }
        inventory.resolveExternalSource = { _, _, _ in fetched = true; return unused }
        inventory.start(.init(executable: unused, models: unused, worker: unused, dataDirectory: unused, temporaryDirectory: unused, environment: [:]))
        inventory.clearSession()
        while inventory.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!fetched && inventory.inventoryExternalSources == nil && inventory.resolveExternalSource == nil)
        print("PASS explicit Clear stops inventory without fetching an original and removes pending provider callbacks")

        let cancelRoot = FileManager.default.temporaryDirectory.appendingPathComponent("SimilarityEarlyCancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: cancelRoot) }
        let cancelConfiguration = SimilarityConfiguration(executable: unused, models: unused, worker: unused,
            dataDirectory: cancelRoot.appendingPathComponent("data"), temporaryDirectory: cancelRoot.appendingPathComponent("temp"), environment: [:])
        let earlyCancel = SimilarityScanModel(source: .local, activity: FinderTaskActivityStore())
        earlyCancel.externalTitle = "Test Drive"; earlyCancel.externalScopeNames = ["Test Folder"]
        var cancelCleanup = false, cancelFetched = false
        earlyCancel.cleanupExternalScope = { cancelCleanup = true }
        earlyCancel.inventoryExternalSources = {
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return [.init(id: "one", name: "one.txt", path: "Test/one.txt", size: 1, localPath: nil)]
        }
        earlyCancel.resolveExternalSource = { _, _, _ in cancelFetched = true; return unused }
        earlyCancel.start(cancelConfiguration)
        let earlyID = earlyCancel.savedSession!.id
        earlyCancel.cancel()
        let earlyDeadline = Date().addingTimeInterval(3)
        while earlyCancel.isRunning && Date() < earlyDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(!earlyCancel.isRunning && !earlyCancel.isPaused && cancelCleanup && !cancelFetched)
        precondition(earlyCancel.report?.status == "cancelled" && earlyCancel.report?.analysedFiles == 0)
        precondition(earlyCancel.report?.coverage.contains("No files were analysed") == true && earlyCancel.error == nil)
        precondition(earlyCancel.savedSession?.state == "cancelled" && earlyCancel.processIdentifier == nil)
        precondition(earlyCancel.activity.tasks.first?.state == .cancelled && earlyCancel.autoResumeDeadline == nil)
        precondition(SimilaritySessionStore.loadReport(cancelConfiguration,id:earlyID)?.status == "cancelled")
        let cancelledDuration = earlyCancel.report!.elapsedSeconds
        earlyCancel.cancel()
        precondition(earlyCancel.report?.elapsedSeconds == cancelledDuration, "Repeated Cancel must not replace the report")
        earlyCancel.clearSession()
        precondition(earlyCancel.report == nil && !FileManager.default.fileExists(atPath:SimilaritySessionStore.directory(cancelConfiguration,id:earlyID).path))
        print("PASS Cancel during inventory opens and saves an empty cancelled report, stops providers and obeys Clear")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SourceRequest-\(UUID())")
        let content = root.appendingPathComponent("similarity-test/source-one/content")
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let reply = content.deletingLastPathComponent().appendingPathComponent("source.json")
        let event: [String: Any] = ["id": "one", "directory": content.path, "response_file": reply.path]
        precondition(SimilaritySourceRequest(event: event, root: root, allowedIDs: ["one"]) != nil)
        if content.path.hasPrefix("/var/") {
            var canonicalEvent = event
            canonicalEvent["directory"] = "/private" + content.path
            canonicalEvent["response_file"] = "/private" + reply.path
            precondition(SimilaritySourceRequest(event: canonicalEvent, root: root, allowedIDs: ["one"]) != nil,
                         "An absent reply must use the same macOS path alias as its existing parent")
        }
        precondition(SimilaritySourceRequest(event: event, root: root, allowedIDs: ["another"]) == nil)
        precondition(SimilaritySourceRequest(event: event, root: root.appendingPathComponent("different-run"), allowedIDs: ["one"]) == nil)
        var escaping = event; escaping["response_file"] = root.appendingPathComponent("source.json").path
        precondition(SimilaritySourceRequest(event: escaping, root: root, allowedIDs: ["one"]) == nil)
        let redirected = root.appendingPathComponent("similarity-other/source-other")
        try FileManager.default.createDirectory(at: redirected, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: redirected.appendingPathComponent("content"), withDestinationURL: root)
        escaping["directory"] = redirected.appendingPathComponent("content").path
        escaping["response_file"] = redirected.appendingPathComponent("source.json").path
        precondition(SimilaritySourceRequest(event: escaping, root: root, allowedIDs: ["one"]) == nil)
        print("PASS provider replies are restricted to selected IDs and the current scan's owned request directory")

        let reader = SimilarityProcessReader(), output = Pipe(), errors = Pipe()
        var delivered = false, drained = false
        reader.start(output: output, errors: errors) { event in
            Task { @MainActor in delivered = event["event"] as? String == "resolve_source" }
        }
        try output.fileHandleForWriting.write(contentsOf: Data("{\"event\":\"resolve_source\",\"id\":\"one\"}\n".utf8))
        let deliveryDeadline = Date().addingTimeInterval(2)
        while !delivered && Date() < deliveryDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(delivered, "A small source request must arrive while the helper pipe is still open")
        try output.fileHandleForWriting.close(); try errors.fileHandleForWriting.close()
        reader.finish(reportURL: root.appendingPathComponent("absent-report.json")) { _, _ in
            Task { @MainActor in drained = true }
        }
        while !drained { try await Task.sleep(nanoseconds: 10_000_000) }
        print("PASS small helper events arrive immediately without waiting for a full buffer or process exit")
    }

    @MainActor private static func recoveryWhenSelectingDrive() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SimilarityDriveRecovery-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        func configuration(_ directory: String) -> SimilarityConfiguration {
            .init(executable: root, models: root, worker: root,
                  dataDirectory: root.appendingPathComponent(directory), temporaryDirectory: root, environment: [:])
        }
        let accountA = configuration("Cloud/account-a"), accountB = configuration("Cloud/account-b")
        let localConfig = configuration("Native/local"), photosConfig = configuration("Native/photos")
        let limits = SimilarityResourceLimits(workers: 52, memoryBytes: 64 << 30,
            batchFiles: 128, batchBytes: 4 << 30, downloadMemoryBytes: 40 << 30,
            acceleration: .automatic, memoryScheduling: true)
        func saved(_ source: SimilaritySource, scope: String, in config: SimilarityConfiguration) throws -> SimilaritySavedSession {
            let session = SimilaritySavedSession(id: UUID().uuidString, source: source, localURLs: [], cloudRoots: [],
                scope: scope, families: ["text", "image", "audio", "video"], threshold: 0.9, exactDuplicates: true,
                resources: limits, state: "paused", startedAt: Date(timeIntervalSince1970: 1_000),
                updatedAt: Date(timeIntervalSince1970: 70_000), activeElapsedSeconds: 68_488)
            try SimilaritySessionStore.pause(session, configuration: config)
            return session
        }
        let cloudSaved = try saved(.cloud, scope: "All PikPak files", in: accountA)
        let otherAccountSaved = try saved(.cloud, scope: "Another account", in: accountB)
        let localSaved = try saved(.local, scope: "Local folder", in: localConfig)
        let photosSaved = try saved(.local, scope: "Photos library", in: photosConfig)
        let host = FileSimilarityCoordinator(activity: FinderTaskActivityStore())
        let local = FileSimilarityCoordinator(activity: FinderTaskActivityStore())
        let photos = FileSimilarityCoordinator(activity: FinderTaskActivityStore())
        var currentAccount = accountA
        host.configuration = { $0 == .cloud ? currentAccount : configuration("Local") }
        local.configuration = { _ in localConfig }; photos.configuration = { _ in photosConfig }
        host.driveOptions = [
            .init(id: "pikpak", title: "PikPak", symbol: "cloud", source: .cloud),
            .init(id: "local", title: "Local Disk", symbol: "internaldrive", source: .local),
            .init(id: "photos", title: "Apple Photos", symbol: "photo", source: .local)
        ]
        host.resolveDrive = { [weak host] id in id == "local" ? local : id == "photos" ? photos : host }

        // A fresh app opens Find Similar Files from Home on Local Disk. The
        // initial window lookup must not be the only chance to find a scan.
        host.selectDrive("local")
        host.activeCoordinator.refreshRecovery()
        precondition(local.local.recoverableSessions.map(\.id) == [localSaved.id])
        precondition(host.cloud.recoverableSessions.isEmpty)
        host.selectDrive("pikpak")
        precondition(host.activeModel.recoverableSessions.map(\.id) == [cloudSaved.id],
                     "Changing Scan drive to PikPak must discover its paused scan after relaunch")
        let recovered = host.cloud.recoverableSessions[0]
        precondition(recovered.resources == limits && recovered.elapsedSeconds == 68_488)
        precondition(recovered.resources.analysisMemoryBytes == 24 << 30 && recovered.resources.downloadBudgetBytes == 40 << 30)
        host.selectDrive("photos")
        precondition(host.activeModel.recoverableSessions.map(\.id) == [photosSaved.id],
                     "Native drives need the same recovery refresh as PikPak")

        // Revisit after another window owns/releases the scan, then after an
        // account change. Recovery must remain current and account scoped.
        SimilaritySessionStore.claim(accountA, id: cloudSaved.id)
        host.selectDrive("pikpak")
        precondition(host.cloud.recoverableSessions.isEmpty)
        SimilaritySessionStore.release(accountA, id: cloudSaved.id)
        host.selectDrive("local"); host.selectDrive("pikpak")
        precondition(host.cloud.recoverableSessions.map(\.id) == [cloudSaved.id])
        currentAccount = accountB
        host.selectDrive("local"); host.selectDrive("pikpak")
        precondition(host.cloud.recoverableSessions.map(\.id) == [otherAccountSaved.id])
        print("PASS Home → drive selection discovers paused scans, preserves RAM/time settings, refreshes claims and keeps accounts separate")
    }
}

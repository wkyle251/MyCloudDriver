import AppKit
import Darwin
import Foundation

@main struct SimilarityResumeTests {
    @MainActor final class Feed {
        let namespace: String
        init(_ namespace: String = "manual") { self.namespace = namespace }
        var hold = true
        var inventoryFailures = 0
        var fetchFailures = 0
        var resolved: [String:Int] = [:]
    }
    @MainActor static var debugScan: SimilarityScanModel?
    @MainActor static func until(_ condition: () -> Bool, seconds: Double = 25, line: UInt = #line) async throws {
        let deadline=Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds:20_000_000) }
        if !condition(), let scan = debugScan {
            let value = "line \(line), PID \(String(describing: scan.processIdentifier)), running \(scan.isRunning), paused \(scan.isPaused), analysed \(scan.progress.analysed), RAM \(scan.progress.analysisMemoryLimit), scheduling \(scan.progress.memoryScheduling), error \(scan.error ?? "none"), \(scan.message)\n"
            FileHandle.standardError.write(Data(value.utf8))
        }
        precondition(condition(),"Timed out waiting for scan state at line \(line)")
    }
    @MainActor static func main() async throws {
        let resources=URL(fileURLWithPath:CommandLine.arguments[1])
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("SimilarityResumeTests-\(UUID().uuidString)").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let inputs=root.appendingPathComponent("inputs")
        try FileManager.default.createDirectory(at:inputs,withIntermediateDirectories:true)
        let text=String(repeating:"Trees, flowers and a garden with paths through the green lawn. ",count:30)
        for name in ["one.txt","two.txt"] { try text.write(to:inputs.appendingPathComponent(name),atomically:true,encoding:.utf8) }
        let config=SimilarityConfiguration(executable:resources.appendingPathComponent("pikpak"),models:resources.appendingPathComponent("FileTwinModels"),
            worker:resources.appendingPathComponent("filetwin-worker"),dataDirectory:root.appendingPathComponent("account-A"),
            temporaryDirectory:root.appendingPathComponent("temp"),environment:[:])
        func coordinator(_ feed:Feed) -> FileSimilarityCoordinator {
            let owner=FileSimilarityCoordinator(activity:FinderTaskActivityStore())
            // Reconstruct the URL on each call as a drive connection does.
            // Foundation adds a directory slash once the folder exists.
            owner.configuration={ _ in SimilarityConfiguration(executable:config.executable,models:config.models,worker:config.worker,
                dataDirectory:URL(fileURLWithPath:config.dataDirectory.path),temporaryDirectory:config.temporaryDirectory,environment:[:]) }
            owner.source = .local
            let model=owner.local; model.localURLs=[inputs]; model.families=["text"]
            model.streamExternalSources={ emit in
                if feed.inventoryFailures > 0 { feed.inventoryFailures-=1; throw URLError(.notConnectedToInternet) }
                for (index,name) in ["one.txt","two.txt"].enumerated() {
                    if index == 1 { while feed.hold { try await Task.sleep(nanoseconds:20_000_000) } }
                    let url=inputs.appendingPathComponent(name)
                    // Separate scenario identities keep the shared source cache
                    // from bypassing the acquisition/retry paths under test.
                    try await emit(.init(id:feed.namespace + ":" + name,name:name,path:url.path,size:UInt64(text.utf8.count),localPath:url.path))
                }
            }
            model.resolveExternalSource={ id,_,_ in
                let name = String(id.dropFirst(feed.namespace.count + 1))
                feed.resolved[name,default:0]+=1
                if feed.fetchFailures > 0 { feed.fetchFailures-=1; throw URLError(.networkConnectionLost) }
                return inputs.appendingPathComponent(name)
            }
            return owner
        }

        let first=Feed(), owner=coordinator(first), scan=owner.local
        debugScan = scan
        owner.start(scan)
        try await until { scan.progress.analysed == 1 }
        let id=scan.savedSession!.id
        let defaultsBeforeEdit = SimilarityResourceSettings.current
        var adjusted = SimilarityResourceSettings(limits: scan.savedSession!.resources)
        adjusted.workers = 3; adjusted.memoryMiB = 4_096; adjusted.downloadMemoryMiB = 1_024
        let initialResources = scan.savedSession!.resources
        do { try scan.updatePausedResources(adjusted, sessionID: id); preconditionFailure("A running helper must keep its resource snapshot") }
        catch { precondition(scan.savedSession!.resources == initialResources) }
        let retainedPID = scan.processIdentifier
        scan.pause(); try await until { !scan.isRunning }
        precondition(scan.isPaused && !scan.interrupted && scan.processIdentifier == retainedPID && scan.retainsOriginalsInRAM)
        precondition(FileManager.default.fileExists(atPath:SimilaritySessionStore.directory(config,id:id).appendingPathComponent("checkpoint.sqlite3").path))
        var invalid = adjusted; invalid.downloadMemoryMiB = invalid.memoryMiB
        do { try scan.updatePausedResources(invalid, sessionID: id); preconditionFailure("Download RAM must leave memory for analysis") }
        catch { precondition(scan.savedSession!.resources == initialResources) }
        do { try scan.updatePausedResources(adjusted, sessionID: UUID().uuidString); preconditionFailure("An old editor must not change a different scan") }
        catch { precondition(scan.savedSession!.resources == initialResources) }
        // Resource edits may not replace the original vector backend.
        adjusted.processingMode = initialResources.acceleration == .cpu ? .automatic : .cpu
        try scan.updatePausedResources(adjusted, sessionID: id)
        let editedResources = scan.savedSession!.resources
        precondition(editedResources.workers == 3 && editedResources.memoryBytes == 4 << 30 && editedResources.downloadBudgetBytes == 1 << 30)
        precondition(editedResources.acceleration == (initialResources.acceleration ?? .cpu))
        let descriptor = SimilaritySessionStore.directory(config,id:id).appendingPathComponent("session.json")
        let persisted = try JSONDecoder().decode(SimilaritySavedSession.self,from:Data(contentsOf:descriptor))
        precondition(persisted.id == id && persisted.resources == editedResources && scan.runResources == editedResources)
        precondition(SimilarityResourceSettings.current == defaultsBeforeEdit,"Editing one scan must not change defaults for other windows")
        let originalConfiguration=owner.configuration
        owner.configuration={ _ in SimilarityConfiguration(executable:config.executable,models:config.models,worker:config.worker,
            dataDirectory:root.appendingPathComponent("account-B"),temporaryDirectory:config.temporaryDirectory,environment:[:]) }
        owner.resume(scan)
        precondition(scan.isPaused && !scan.isRunning && scan.error?.contains("account") == true)
        owner.configuration=originalConfiguration
        let other=coordinator(Feed())
        other.resume(other.local,session:scan.savedSession)
        precondition(!other.local.isRunning && other.local.error?.contains("another window") == true)
        owner.resume(scan)
        precondition(scan.processIdentifier == retainedPID, "Resume must keep the RAM-owning helper")
        try await until { scan.progress.analysed == 1 && scan.progress.memoryScheduling && scan.progress.analysisMemoryLimit == 3 << 30 }
        precondition(scan.progress.workerLimit > 3,"The saved worker count must not constrain memory scheduling")
        precondition(scan.runResources == editedResources,"Resume must use this scan's limits instead of app-wide defaults")
        scan.pause(); try await until { !scan.isRunning }
        adjusted.workers = 2; adjusted.memoryMiB = 2_048; adjusted.downloadMemoryMiB = 512
        try scan.updatePausedResources(adjusted, sessionID: id)
        first.hold=false; owner.resume(scan)
        precondition(scan.runResources?.workers == 2 && scan.runResources?.memoryBytes == 2 << 30 && scan.runResources?.downloadBudgetBytes == 512 << 20)
        try await until { !scan.isRunning }
        precondition(!scan.isPaused && scan.report?.analysedFiles == 2 && scan.report?.scoresRetained == 1,scan.error ?? "Missing completed results")
        precondition(first.resolved["one.txt"] == 1,"Completed files must bypass fetching when resumed")
        precondition(FileManager.default.fileExists(atPath:SimilaritySessionStore.directory(config,id:id).path))
        precondition(SimilaritySessionStore.loadReport(config,id:id)?.analysedFiles == 2)
        owner.close(); precondition(scan.report?.analysedFiles == 2)
        scan.preserveForShutdown()
        let reviewOwner=coordinator(Feed()); reviewOwner.refreshRecovery()
        reviewOwner.resume(reviewOwner.local,session:reviewOwner.local.recoverableSessions.first { $0.id == id }!)
        precondition(!reviewOwner.local.isRunning && reviewOwner.local.report?.analysedFiles == 2)
        let archivedReport=reviewOwner.local.report!, run=archivedReport.runId!
        reviewOwner.local.clearSession()
        precondition(!FileManager.default.fileExists(atPath:SimilaritySessionStore.directory(config,id:id).path))
        precondition(!FileManager.default.fileExists(atPath:config.dataDirectory.appendingPathComponent("runs").appendingPathComponent(run+".sqlite3").path))
        // Clear can race the final helper response, before report.json has been archived.
        let pendingID=UUID().uuidString, pendingDirectory=SimilaritySessionStore.directory(config,id:pendingID)
        try FileManager.default.createDirectory(at:pendingDirectory,withIntermediateDirectories:true)
        let pendingMatrix=config.dataDirectory.appendingPathComponent("runs").appendingPathComponent(run+".sqlite3")
        try Data().write(to:pendingMatrix)
        SimilaritySessionStore.discard(config,id:pendingID,report:archivedReport)
        precondition(!FileManager.default.fileExists(atPath:pendingDirectory.path) && !FileManager.default.fileExists(atPath:pendingMatrix.path))
        print("PASS manual pause/resume keeps the same helper and originals; duplicate window claims are refused")
        print("PASS pause/edit/save/resume applies RAM budgets, ignores old worker limits, keeps vectors/backend, and isolates defaults")

        let crashFeed=Feed("crash"), crashOwner=coordinator(crashFeed), crashed=crashOwner.local
        crashOwner.start(crashed); try await until { crashed.progress.analysed == 1 }
        kill(crashed.processIdentifier!,SIGKILL)
        try await until { !crashed.isRunning }
        precondition(crashed.isPaused && crashed.interrupted)
        let recoveredID=crashed.savedSession!.id
        try crashed.updatePausedResources(adjusted, sessionID: recoveredID)
        let recoveryResources = crashed.savedSession!.resources
        crashed.preserveForShutdown()
        let afterRestart=Feed("crash"); afterRestart.hold=false
        let restoredOwner=coordinator(afterRestart), restored=restoredOwner.local
        restoredOwner.refreshRecovery()
        let saved=restored.recoverableSessions.first { $0.id == recoveredID }!
        precondition(saved.resources == recoveryResources)
        restoredOwner.resume(restored,session:saved)
        precondition(restored.runResources == recoveryResources,"Edited limits must survive app restarts")
        try await until { !restored.isRunning }
        precondition(restored.report?.analysedFiles == 2 && !restored.isPaused,restored.error ?? "Recovery did not complete")
        precondition(afterRestart.resolved["one.txt"] == nil && afterRestart.resolved["two.txt"] == 1)
        print("PASS forced helper termination leaves durable progress; a new session recovers without fetching completed originals")

        let offline=Feed("offline"); offline.hold=false; offline.inventoryFailures=1; offline.fetchFailures=1
        let networkOwner=coordinator(offline), network=networkOwner.local
        networkOwner.start(network)
        try await until { network.waitingForNetwork }
        try await until { !network.isRunning }
        precondition(!network.isPaused && network.report?.analysedFiles == 2 && network.report?.failedFiles == 0,network.error ?? "Network retry failed")
        precondition(offline.inventoryFailures == 0 && offline.fetchFailures == 0)
        print("PASS discovery and original acquisition automatically recover from temporary network failures")

        let last=Feed("cancel"), cancelOwner=coordinator(last), cancelled=cancelOwner.local
        cancelOwner.start(cancelled); try await until { cancelled.progress.analysed == 1 }
        let cancelledID=cancelled.savedSession!.id
        cancelOwner.close(); try await until { !cancelled.isRunning }
        precondition(cancelled.isPaused && cancelled.savedSession?.id == cancelledID)
        cancelled.cancel()
        precondition(cancelled.isPaused && cancelled.savedSession?.state == "cancelled")
        precondition(FileManager.default.fileExists(atPath:SimilaritySessionStore.directory(config,id:cancelledID).path))
        last.hold=false; cancelOwner.resume(cancelled); try await until { !cancelled.isRunning }
        precondition(cancelled.report?.analysedFiles == 2)
        cancelled.clearSession()
        precondition(!cancelled.isPaused && cancelled.savedSession == nil)
        precondition(!FileManager.default.fileExists(atPath:SimilaritySessionStore.directory(config,id:cancelledID).path))
        let retainedFeed = Feed("clear"), retainedOwner = coordinator(retainedFeed), retained = retainedOwner.local
        retainedOwner.start(retained); try await until { retained.progress.analysed == 1 }
        let clearedID = retained.savedSession!.id, clearedPID = retained.processIdentifier!
        retained.pause(); try await until { retained.isPaused }
        retained.clearSession(); try await until { retained.processIdentifier == nil && retained.savedSession == nil }
        precondition(kill(clearedPID, 0) != 0, "Clear must stop the paused helper")
        precondition(!FileManager.default.fileExists(atPath:SimilaritySessionStore.directory(config,id:clearedID).path))
        print("PASS Clear stops a paused live helper and releases its provider tasks")
        restored.clearSession(); network.clearSession()
        precondition(SimilaritySessionStore.available(config,source:.local).isEmpty)
        let original=try String(contentsOf:inputs.appendingPathComponent("one.txt"),encoding:.utf8)
        precondition(original == text)
        print("PASS close and Cancel preserve progress; resume succeeds; only Clear deletes saved state and results")
    }
}

import AppKit
import Foundation

/// Generated helper protocol and metadata-only providers; no existing files,
/// accounts, mounted volumes or real scans are accessed.
@main struct SimilaritySleepPreventionTests {
    @MainActor final class Counts {
        var begins = 0, ends = 0
        func token() -> DownloadSleepPrevention {
            DownloadSleepPrevention(begin: { self.begins += 1; return NSObject() },
                                    end: { _ in self.ends += 1 })
        }
    }
    @MainActor final class Feed {
        var waiter: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { waiter = $0 } }
        func release() { waiter?.resume(); waiter = nil }
    }
    @MainActor static func until(_ condition: () -> Bool, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(condition(), "Generated sleep lifecycle timed out at line \(line)")
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        let options = DownloadSleepPrevention.activityOptions(fullWake: true)
        precondition(options.contains(.userInitiated) && options.contains(.idleSystemSleepDisabled)
                     && options.contains(.idleDisplaySleepDisabled),
                     "Full-wake scans must suppress App Nap and both idle system and display sleep")
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("SimilaritySleep-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let helper = root.appendingPathComponent("generated-helper")
        try #"""
        #!/usr/bin/python3
        import json, pathlib, subprocess, sys, time
        request=json.loads(pathlib.Path(sys.argv[-1]).read_text())
        data=pathlib.Path(request['data_dir']); data.mkdir(parents=True,exist_ok=True)
        checkpoint=data/'checkpoints'/request['checkpoint_id'] if request.get('checkpoint_id') else None
        paused=False; pause_revision=None
        def emit(value): print(json.dumps(value),flush=True)
        def progress():
            emit(dict(event='progress',stage='analysing',completed=1,total=2,
                counts=dict(files_ready=1,files_processed=1,files_discovered=2),
                work=dict(original_memory_bytes=1024,original_memory_limit=4096,
                    analysis_memory_bytes=0,analysis_memory_limit=8192)))
        progress()
        deadline=time.monotonic()+20
        while time.monotonic()<deadline:
            try:
                marker=(checkpoint/'pause').stat() if checkpoint is not None else None
                revision=(marker.st_ino,marker.st_mtime_ns) if marker is not None else None
            except FileNotFoundError:
                revision=None
            pause=revision is not None
            # The real control watcher also acknowledges an atomically replaced
            # pause marker when Resume/Pause occur within one polling interval.
            if pause and (not paused or revision != pause_revision):
                paused=True; emit(dict(event='pause_state',paused=True))
            elif not pause and paused:
                paused=False; progress()
            pause_revision=revision
            if (data/'crash').exists(): sys.exit(7)
            finish=checkpoint is not None and (checkpoint/'finish').exists()
            if finish or (data/'complete').exists():
                status='finished' if finish else 'completed'
                pathlib.Path(request['report_path']).write_text(json.dumps(dict(
                    source=request['source'],scope=['Generated'],status=status,threshold=.9,
                    scanned_files=2,analysed_files=1,skipped_files=0,downloaded_bytes=1024,
                    total_groups=0,groups=[],issues=[],truncated=False,coverage='Generated',
                    elapsed_seconds=1,files=[])))
                # The helper exits while a generated child holds both pipes.
                # The GUI must retain its activity until report drain ends.
                subprocess.Popen(['/bin/sleep','0.8'],stdout=sys.stdout,stderr=sys.stderr)
                sys.exit(0)
            time.sleep(.01)
        sys.exit(8)
        """#.write(to: helper, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        func configuration(_ name: String) -> SimilarityConfiguration {
            .init(executable: helper, models: root, worker: helper,
                dataDirectory: root.appendingPathComponent(name),
                temporaryDirectory: root.appendingPathComponent(name + "-temp"), environment: [:])
        }
        func prepare(_ scan: SimilarityScanModel) {
            scan.cloudRoots = [.init(id: "generated-root", name: "Generated", path: "/", isFolder: true, size: 0, ancestors: [])]
        }
        let counts = Counts(), token = counts.token(), config = configuration("retained")
        let scan = SimilarityScanModel(source: .cloud, activity: FinderTaskActivityStore(), sleepPrevention: token)
        prepare(scan)
        precondition(!token.isActive)
        scan.start(config)
        precondition(token.isActive && counts.begins == 1 && counts.ends == 0)
        try await until { scan.progress.analysed == 1 }
        scan.pause()
        precondition(token.isActive && scan.isPausing)
        try await until { scan.isPaused && !scan.isRunning }
        precondition(scan.retainsOriginalsInRAM && token.isActive && counts.begins == 1 && counts.ends == 0,
                     "Pausing with a live RAM-retaining helper must remain fully awake")
        let pid = scan.processIdentifier, saved = scan.savedSession!
        scan.start(config, resuming: saved)
        precondition(scan.processIdentifier == pid && token.isActive && counts.begins == 1)
        scan.pause(); try await until { scan.isPaused }
        scan.finishScan()
        precondition(token.isActive && scan.isRunning)
        try await until { scan.processIdentifier == nil && scan.isRunning }
        precondition(token.isActive, "Helper exit must retain full wake while its pipes and report drain")
        try await until { !scan.isRunning && scan.report?.status == "finished" && !token.isActive }
        precondition(counts.begins == 1 && counts.ends == 1)
        scan.clearSession()
        print("PASS active scan, pause/save, retained RAM, same-helper Resume, Finish and final pipe/report drain own one balanced activity")

        let interruptedCounts = Counts(), interruptedToken = interruptedCounts.token(), interruptedConfig = configuration("interrupted")
        let interrupted = SimilarityScanModel(source: .cloud, activity: FinderTaskActivityStore(), sleepPrevention: interruptedToken)
        prepare(interrupted); interrupted.start(interruptedConfig)
        try await until { interrupted.progress.analysed == 1 }
        try Data().write(to: interruptedConfig.dataDirectory.appendingPathComponent("crash"))
        try await until { interrupted.isPaused && interrupted.processIdentifier == nil && !interruptedToken.isActive }
        precondition(!interrupted.retainsOriginalsInRAM && interruptedCounts.begins == interruptedCounts.ends,
                     "A durable interrupted checkpoint without live work must release full wake")
        interrupted.clearSession()
        print("PASS durable interrupted checkpoints do not retain sleep assertions")

        let preparingCounts = Counts(), preparingToken = preparingCounts.token(), preparation = Feed()
        let preparing = SimilarityScanModel(source: .local, activity: FinderTaskActivityStore(), sleepPrevention: preparingToken)
        preparing.externalTitle = "Generated Drive"; preparing.externalScopeNames = ["Generated location"]
        preparing.inventoryExternalSources = { await preparation.wait(); return [] }
        preparing.start(configuration("preparing"))
        precondition(preparingToken.isActive)
        try await until { preparation.waiter != nil }
        preparing.cancel()
        precondition(!preparing.isRunning && preparingToken.isActive,
                     "Cancellation must keep protection while an uncooperative provider is still retiring")
        preparing.clearSession()
        precondition(preparingToken.isActive, "Deleting the visible session must not release a pending provider's protection")
        preparation.release()
        try await until { !preparingToken.isActive }
        precondition(preparingCounts.begins == 1 && preparingCounts.ends == 1)
        print("PASS preparation cancellation and session deletion retain full wake until provider cleanup completes")

        let firstCounts = Counts(), firstToken = firstCounts.token(), secondCounts = Counts(), secondToken = secondCounts.token()
        let first = SimilarityScanModel(source: .cloud, activity: FinderTaskActivityStore(), sleepPrevention: firstToken)
        let second = SimilarityScanModel(source: .cloud, activity: FinderTaskActivityStore(), sleepPrevention: secondToken)
        prepare(first); prepare(second)
        first.start(configuration("first")); second.start(configuration("second"))
        try await until { first.progress.analysed == 1 && second.progress.analysed == 1 }
        first.cancel()
        try await until { !first.isRunning && !firstToken.isActive }
        precondition(secondToken.isActive && secondCounts.begins == 1 && secondCounts.ends == 0,
                     "Finishing one model cannot release another model's full-wake activity")
        second.pause(); try await until { second.isPaused }
        second.preserveForShutdown()
        precondition(secondToken.isActive)
        try await until { second.processIdentifier == nil && !secondToken.isActive }
        precondition(firstCounts.begins == firstCounts.ends && secondCounts.begins == secondCounts.ends)
        first.clearSession(); second.clearSession()
        print("PASS independent scan owners and shutdown preserve sleep protection until their own work has stopped")

        let duplicateCounts = Counts(), duplicateToken = duplicateCounts.token(), duplicateConfig = configuration("duplicate")
        let duplicate = SimilarityScanModel(source: .local, activity: FinderTaskActivityStore(), sleepPrevention: duplicateToken)
        duplicate.externalDuplicatesOnly = true; duplicate.localURLs = [root]
        duplicate.start(duplicateConfig)
        try await until { duplicate.progress.analysed == 1 }
        precondition(duplicateToken.isActive && duplicate.savedSession == nil)
        try Data().write(to: duplicateConfig.dataDirectory.appendingPathComponent("complete"))
        try await until { !duplicate.isRunning && duplicate.report != nil && !duplicateToken.isActive }
        precondition(duplicateCounts.begins == duplicateCounts.ends)
        duplicate.clearSession()
        print("PASS duplicate-only scans retain full wake without a resumable similarity session and release after completion")

        let releasedCounts = Counts(), releasedToken = releasedCounts.token(), releasedConfig = configuration("released-model")
        var released: SimilarityScanModel? = SimilarityScanModel(source: .cloud,
            activity: FinderTaskActivityStore(), sleepPrevention: releasedToken)
        weak var releasedModel = released
        prepare(released!); released!.start(releasedConfig)
        try await until { released?.progress.analysed == 1 }
        let releasedPID = released!.processIdentifier!
        released = nil
        try await until { releasedModel == nil }
        precondition(releasedToken.isActive && releasedCounts.begins == 1 && releasedCounts.ends == 0,
                     "A running helper must retain full wake after its model is released")
        try Data().write(to: releasedConfig.dataDirectory.appendingPathComponent("complete"))
        try await until { kill(releasedPID, 0) != 0 }
        precondition(releasedToken.isActive && releasedCounts.ends == 0,
                     "The released model's run must retain its activity after helper exit until pipe/report drain")
        try await until { !releasedToken.isActive }
        precondition(releasedCounts.begins == 1 && releasedCounts.ends == 1,
                     "A model-free drained run must release its captured activity exactly once")
        print("PASS releasing a scan model preserves its helper-owned activity through exit and report drain, then releases exactly once")
    }
}

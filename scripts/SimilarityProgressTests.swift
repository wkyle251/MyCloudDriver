import AppKit
import Foundation

/// Exercises production save, pause acknowledgements, shutdown and restore
/// with a local protocol fixture. No account or original file is accessed.
@main struct SimilarityProgressTests {
    @MainActor static func until(_ condition: () -> Bool, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(15)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(condition(), "Timed out at line \(line)")
    }
    @MainActor static func main() async throws {
        try fractionsAndSnapshots()
        try listingProgress()
        try onDemandProgress()
        downloadTimeEstimates()
        processingSpeeds()
        try sourceTransferProgress()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SimilarityProgress-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("fixture-helper")
        try #"""
        #!/usr/bin/python3
        import json, pathlib, sys, time
        request=json.loads(pathlib.Path(sys.argv[-1]).read_text())
        data=pathlib.Path(request['data_dir'])
        launches=data/'launches'
        launch=int(launches.read_text())+1 if launches.exists() else 1
        launches.write_text(str(launch))
        pause=data/'checkpoints'/request['checkpoint_id']/'pause'
        amount=1000 if launch==1 else 200
        analysed=5 if launch==1 else 7
        def emit(value): print(json.dumps(value),flush=True)
        def progress(stage='analysing'):
            emit(dict(event='progress',stage=stage,completed=analysed+5,total=20,discovery_complete=True,
                downloaded_bytes=amount, counts=dict(files_ready=analysed,files_processed=analysed+5,
                files_discovered=20,files_total=20,files_skipped=3,files_failed=2,bytes_read=amount*2,
                bytes_hashed=amount,cache_hits=analysed,vectors_encoded=0,scores_retained=42),
                session_statistics=dict(newly_analysed=analysed-1,reused=1),
                cloud_data=dict(ready_bytes=800,total_bytes=2000,inventory_complete=True),
                work=dict(original_memory_bytes=500,original_memory_limit=10000,
                    analysis_memory_bytes=100,analysis_memory_limit=20000,fetching=1,encoding=1),
                downloads=dict(total=1,omitted=0,speed=50,items=[dict(id=1,name='large.bin',
                    received=500,total=2000,speed=50,state='downloading',attempt=1,retry_seconds=0)])))
        if launch==3:
            emit(dict(event='inventory_check'))
            emit(dict(event='discovery_listing',folders_discovered=9,folders_completed=4,
                folders_pending=5,pages_completed=11,found=25,complete=False))
            deadline=time.monotonic()+10
            while not (data/'allow-comparison').exists() and time.monotonic()<deadline:
                time.sleep(.02)
            emit(dict(event='restored_inventory'))
            progress('comparison')
            # Exit immediately: the UI must drain queued final events too.
            pathlib.Path(request['report_path']).write_text(json.dumps(dict(source='cloud',scope=['Fixture'],
                status='completed',threshold=.9,scanned_files=20,analysed_files=7,skipped_files=5,
                downloaded_bytes=300,total_groups=0,groups=[],issues=[],truncated=False,
                coverage='Fixture',elapsed_seconds=1,files=[],unsupported_files=3,failed_files=2,scores_retained=42)))
            sys.exit(0)
        progress()
        paused=False
        while True:
            if pause.exists() and not paused:
                paused=True
                emit(dict(event='pause_state',paused=True))
                time.sleep(.15)
                amount+=100; analysed+=1
                progress()  # An in-flight analysis completes after pause acknowledgement.
            elif not pause.exists() and paused:
                paused=False
                amount+=200
                progress()
            time.sleep(.02)
        """#.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
        let config = SimilarityConfiguration(executable: helper, models: root, worker: helper,
            dataDirectory: root.appendingPathComponent("data"), temporaryDirectory: root.appendingPathComponent("temp"), environment: [:])
        func descriptor(_ id: String) throws -> SimilaritySavedSession {
            try JSONDecoder().decode(SimilaritySavedSession.self,
                from: Data(contentsOf: SimilaritySessionStore.directory(config,id:id).appendingPathComponent("session.json")))
        }
        let first = SimilarityScanModel(source: .cloud, activity: FinderTaskActivityStore())
        first.cloudRoots = [.init(id:"root",name:"Fixture",path:"/",isFolder:true,size:0,ancestors:[])]
        first.start(config)
        try await until { first.progress.downloadedBytes == 1000 }
        let id = first.savedSession!.id, pid = first.processIdentifier
        first.pause()
        try await until { first.isPaused && first.progress.downloadedBytes == 1100 }
        var saved = try descriptor(id)
        precondition(saved.progress?.downloadedBytes == 1100 && saved.progress?.analysed == 6,
            "Work completed after pause acknowledgement must be saved")
        precondition(saved.progress?.unsupportedFiles == 3 && saved.progress?.failedFiles == 2
            && saved.progress?.scoresRetained == 42 && saved.progress?.vectorsEncoded == 5
            && saved.progress?.cacheHits == 1 && saved.progress?.downloads.count == 1)
        let pausedTime = first.elapsedSeconds(at: Date())
        first.start(config,resuming:saved)
        try await until { first.progress.downloadedBytes == 1300 }
        precondition(first.processIdentifier == pid && first.elapsedSeconds(at: Date()) >= pausedTime)
        first.pause()
        try await until { first.isPaused && first.progress.downloadedBytes == 1400 }
        first.preserveForShutdown()
        try await until { first.processIdentifier == nil && first.progress.originalMemoryBytes == 0 }
        saved = try descriptor(id)
        precondition(saved.progress?.downloadedBytes == 1400)

        let second = SimilarityScanModel(source:.cloud,activity:FinderTaskActivityStore())
        second.start(config,resuming:saved)
        precondition(second.progress.downloadedBytes == 1400 && second.progress.analysed == 7,
            "Saved cards must be restored before fresh helper telemetry arrives")
        precondition(second.progress.originalMemoryBytes == 0 && second.progress.downloadSpeed == 0,
            "A saved snapshot must not claim lost RAM or an old speed is still live")
        precondition(second.progress.cloudDownloadSecondsRemaining(at: Date()) == nil,
            "An app restart must wait for a fresh download speed before estimating time")
        try await until { second.progress.downloadedBytes == 1600 }
        precondition(second.progress.vectorsEncoded == 6 && second.progress.cacheHits == 1)
        second.pause()
        try await until { second.isPaused && second.progress.downloadedBytes == 1700 }
        second.preserveForShutdown()
        try await until { second.processIdentifier == nil && second.progress.originalMemoryBytes == 0 }
        saved = try descriptor(id)
        precondition(saved.progress?.downloadedBytes == 1700)

        let third = SimilarityScanModel(source:.cloud,activity:FinderTaskActivityStore())
        third.start(config,resuming:saved)
        try await until { third.progress.stage == .checking && third.progress.listingFoldersCompleted == 4 }
        precondition(third.progress.listingPagesCompleted == 11 && third.progress.listingFilesFound == 25,
            "The model must retain numeric discovery progress during the final change check")
        try Data().write(to:config.dataDirectory.appendingPathComponent("allow-comparison"))
        try await until { !third.isRunning && third.report != nil }
        precondition(third.report?.downloadedBytes == 1700 && third.progress.downloadedBytes == 1700,
            "Resuming a sealed comparison must not add its historical report bytes again")
        let finalSaved = try descriptor(id)
        precondition(finalSaved.progress?.downloadedBytes == 1700)
        third.clearSession()
        print("PASS every progress card and queue snapshot saved on pause, including late analysis completion")
        print("PASS same-helper pause, two restarts and sealed comparisons preserve cumulative totals without double counting")
    }
    static func onDemandProgress() throws {
        let event: [String:Any] = ["stage":"analysing", "completed":9, "total":10, "discovery_complete":true,
            "cloud_data":["ready_bytes":1000, "total_bytes":1000, "inventory_complete":true,
                "on_demand":true, "sampled_files":2, "sampled_received_bytes":1_048_576]]
        let progress = SimilarityScanProgress(event:event)
        precondition(progress.usesOnDemandCloudProgress && !progress.usesCloudByteProgress)
        precondition(progress.fraction == 0.9, "Sampled originals use file-analysis progress, not whole-file byte readiness")
        precondition(progress.cloudDownloadSecondsRemaining(at:Date()) == nil)
        precondition(progress.cloudDownloadTimeLabel(at:Date(), running:true) == nil)
        precondition(progress.cloudByteLabel?.contains("2 sampled originals") == true)
        let restored = try JSONDecoder().decode(SimilarityScanProgress.self, from:JSONEncoder().encode(progress))
        precondition(restored.cloudOnDemand == true && restored.sampledReceivedBytes == 1_048_576)
        var summary = SimilarityScanProgress(); summary.restoreSummary(from:restored)
        precondition(summary.cloudOnDemand == true && summary.sampledOriginals == 2)
        let row = SimilarityDownload(event:["id":1, "name":"generated.mp4", "received":1_048_576,
            "total":1_073_741_824, "speed":1024, "state":"downloading", "on_demand":true])!
        precondition(row.fraction == nil && row.remainingLabel(speed:1024) == "—")
        precondition(row.status(age:0, running:true) == "Fetching ranges")
        precondition(row.byteLabel.contains("fetched as needed"))
        let oldRow = SimilarityDownload(event:["id":2, "name":"generated.txt", "received":10, "total":100])!
        precondition(oldRow.onDemand == nil && oldRow.fraction == 0.1)
        print("PASS sampled cloud originals show range traffic without whole-file readiness or download ETA")
    }
    static func listingProgress() throws {
        var progress = SimilarityScanProgress()
        progress.stage = .checking
        progress.applyListing(["folders_discovered":9, "folders_completed":4,
            "folders_pending":5, "pages_completed":11, "found":25])
        precondition(progress.completedLabel == "4 of 9 folders checked · 11 pages · 25 files found")
        precondition(progress.fraction == nil, "A growing folder inventory must remain indeterminate")
        let data = try JSONEncoder().encode(progress)
        let restored = try JSONDecoder().decode(SimilarityScanProgress.self, from:data)
        precondition(restored.listingFoldersCompleted == 4 && restored.listingPagesCompleted == 11)
        precondition(restored.afterHelperRestart().listingFoldersCompleted == nil)
        var old = try JSONSerialization.jsonObject(with:data) as! [String:Any]
        for key in ["listingFoldersDiscovered", "listingFoldersCompleted", "listingFoldersPending", "listingPagesCompleted", "listingFilesFound"] { old.removeValue(forKey:key) }
        let legacy = try JSONDecoder().decode(SimilarityScanProgress.self, from:JSONSerialization.data(withJSONObject:old))
        precondition(legacy.listingFoldersCompleted == nil, "Older snapshots remain readable")
        print("PASS final inventory checks show folder/page/file progress and keep old snapshots readable")
    }
    static func fractionsAndSnapshots() throws {
        let event: [String:Any] = ["stage":"analysing","completed":9,"total":10,"discovery_complete":true,
            "counts":["files_ready":9],"cloud_data":["ready_bytes":100,"total_bytes":1000,"inventory_complete":true]]
        var progress = SimilarityScanProgress(event:event)
        precondition(progress.fraction == 0.1 && progress.percentLabel == "10%",
            "Nine small files out of ten must not show 90% when the large file remains")
        progress.cloudByteInventoryComplete = false
        precondition(progress.fraction == nil,"Do not present a partial inventory size as the total")
        progress.cloudByteInventoryComplete = true; progress.stage = .comparison; progress.completed = 2
        precondition(progress.fraction == 0.2 && !progress.usesCloudByteProgress)
        progress.stage = .analysing; progress.cloudBytesTotal = nil; progress.completed = 9
        precondition(progress.fraction == 0.9,"Local scans retain file-count progress")
        var saved = SimilaritySavedSession(id:UUID().uuidString,source:.cloud,localURLs:[],cloudRoots:[],scope:"Fixture",
            families:["text"],threshold:0.9,exactDuplicates:true,resources:SimilarityResourceSettings.current.limits,
            state:"paused",startedAt:Date(),updatedAt:Date())
        saved.progress = SimilarityScanProgress(event:event)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let copy = try JSONDecoder().decode(SimilaritySavedSession.self,from:encoder.encode(saved))
        let copiedProgress = try encoder.encode(copy.progress!)
        let originalProgress = try encoder.encode(saved.progress!)
        precondition(copiedProgress == originalProgress)
        saved.progressSnapshot = Data("{\"future_format\":true}".utf8)
        let future = try JSONDecoder().decode(SimilaritySavedSession.self,from:encoder.encode(saved))
        precondition(future.id == saved.id && future.progress == nil,"Unknown snapshots must not hide Resume")
        print("PASS byte-weighted cloud progress, local/comparison fallback and recoverable snapshot decoding")
    }
    static func sourceTransferProgress() throws {
        let start = Date(timeIntervalSince1970: 2000)
        var progress = SimilarityScanProgress(event: ["stage":"analysing", "discovery_complete":true,
            "counts":["files_discovered":91,"files_processed":9],
            "work":["reading":4,"hashing":0,"encoding":0,"ready":0,"waiting_read":78,"original_bytes_read":0]])
        precondition(progress.readyFiles == 0 && progress.waitingReadFiles == 78 && progress.encodingFiles == 0)
        precondition(progress.displayTitle == "Reading files into RAM" && progress.waitingSummary.contains("78 waiting to read"))
        precondition(progress.phaseSummary == "Reading 4 files into RAM")
        var history = SimilarityReadHistory()
        history.observe(progress,running:true,at:start)
        progress.originalBytesRead = 1_048_576
        history.observe(progress,running:true,at:start.addingTimeInterval(2))
        precondition(history.bytesPerSecond == 524_288)
        progress.bytesRead += 20 * 1_048_576; progress.bytesHashed += 20 * 1_048_576
        history.observe(progress,running:true,at:start.addingTimeInterval(4))
        precondition(history.bytesPerSecond == 0,"Hashing and calculations must never inflate source download speed")
        history.observe(progress,running:false,at:start.addingTimeInterval(4))
        progress.originalBytesRead = 20 * 1_048_576
        history.observe(progress,running:false,at:start.addingTimeInterval(24))
        history.observe(progress,running:true,at:start.addingTimeInterval(26))
        precondition(history.bytesPerSecond == 0)
        progress.originalBytesRead! += 2 * 1_048_576
        history.observe(progress,running:true,at:start.addingTimeInterval(28))
        precondition(history.bytesPerSecond == 1_048_576,"Paused bytes and time must not appear in resumed speed")
        history.observe(progress,running:true,restoring:true,at:start.addingTimeInterval(30))
        precondition(history.bytesPerSecond == 0)
        progress = SimilarityScanProgress(event: ["stage":"analysing","discovery_complete":true,
            "work":["reading":0,"hashing":2,"encoding":0]])
        precondition(progress.encodingFiles == 2 && progress.displayTitle == "Hashing file content")
        var old = try JSONSerialization.jsonObject(with:JSONEncoder().encode(progress)) as! [String:Any]
        for key in ["originalBytesRead","hashingFiles","waitingReadFiles"] { old.removeValue(forKey:key) }
        let restored = try JSONDecoder().decode(SimilarityScanProgress.self,from:JSONSerialization.data(withJSONObject:old))
        precondition(restored.hashingFiles == nil && restored.originalBytesRead == nil,"Old saved progress must remain decodable")
        print("PASS acquisition speed excludes RAM hashing, pauses and restored counters; queue labels and old snapshots remain correct")
    }
    static func processingSpeeds() {
        let start = Date(timeIntervalSince1970: 1_000)
        var progress = SimilarityScanProgress()
        progress.stage = .analysing; progress.foundFiles = 20; progress.total = 20; progress.discoveryComplete = true
        progress.cloudBytesReady = 900; progress.cloudBytesTotal = 1_000; progress.cloudByteInventoryComplete = true
        var history = SimilarityProcessingHistory()
        history.restart(progress, at: start)
        history.observe(progress, running: true, at: start)
        progress.analysed = 4; progress.skipped = 1; progress.unsupportedFiles = 1
        history.observe(progress, running: true, at: start.addingTimeInterval(2))
        precondition(history.snapshot(for: progress).averageBytesPerSecond == 2.5)
        let work = SimilarityProcessingWork(progress)
        precondition(work.completed == 5 && work.fraction == 0.25 && progress.fraction == 0.9,
                     "Processing progress must measure finished files separately from cloud download bytes")
        history.observe(progress, running: true, at: start.addingTimeInterval(4))
        precondition(history.snapshot(for: progress).averageBytesPerSecond == 1.25,
                     "Analysis stalls must lower the average instead of retaining a stale rate")
        precondition(history.snapshot(for: progress).samples.last?.bytesPerSecond == 0)
        history.observe(progress, running: false, at: start.addingTimeInterval(4))
        progress.analysed = 6
        history.observe(progress, running: false, at: start.addingTimeInterval(104))
        history.observe(progress, running: true, at: start.addingTimeInterval(106))
        progress.analysed = 9
        history.observe(progress, running: true, at: start.addingTimeInterval(108))
        let resumed = history.snapshot(for: progress)
        precondition(resumed.activeSeconds == 6 && resumed.transferredBytes == 8,
                     "Paused time and analyses finishing during Pause must not inflate resumed throughput")

        progress.stage = .comparison; progress.pairsCompared = 100; progress.total = 1_000
        history.observe(progress, running: true, at: start.addingTimeInterval(109))
        precondition(history.snapshot(for: progress).averageBytesPerSecond == 0, "Saved pair counts are a baseline, not work just performed")
        progress.pairsCompared = 150
        history.observe(progress, running: true, at: start.addingTimeInterval(111))
        let comparison = history.snapshot(for: progress)
        precondition(comparison.averageBytesPerSecond == 25 && comparison.estimatedSeconds(remainingBytes: 850) == 34)
        precondition(SimilarityProcessingWork(progress).unit == .pairs && SimilarityProcessingWork(progress).fraction == 0.15)
        progress.pairsCompared = 500
        history.observe(progress, running: true, restoring: true, at: start.addingTimeInterval(112))
        progress.pairsCompared = 600
        history.observe(progress, running: true, at: start.addingTimeInterval(113))
        progress.pairsCompared = 620
        history.observe(progress, running: true, at: start.addingTimeInterval(115))
        precondition(history.snapshot(for: progress).transferredBytes == 70, "Checkpoint replay must not create a processing-speed spike")
        progress.discoveryComplete = false; progress.stage = .analysing
        precondition(SimilarityProcessingWork(progress).fraction == nil && SimilarityProcessingWork(progress).remaining == nil)
        precondition(SimilarityProcessingHistory.rateLabel(.nan,unit:.files) == "0 files/s")

        var long = SimilarityProcessingHistory(), fresh = SimilarityScanProgress()
        fresh.stage = .analysing; long.restart(fresh,at:start); long.observe(fresh,running:true,at:start)
        for second in 1...20_000 {
            fresh.analysed = UInt64(second * 2)
            long.observe(fresh,running:true,at:start.addingTimeInterval(Double(second)))
        }
        let compacted = long.snapshot(for:fresh)
        precondition(compacted.samples.count <= DownloadSpeedHistory.maximumChartSamples && compacted.averageBytesPerSecond == 2)
        precondition(SimilarityProcessingHistory().snapshot(for:fresh).samples.isEmpty)
        print("PASS processing progress separates files from downloaded bytes; files/s and pairs/s have independent histories, accurate averages/ETA, stalls, pauses, restore baselines and bounded charts")
    }

    static func downloadTimeEstimates() {
        let now = Date(timeIntervalSince1970: 1000)
        var progress = SimilarityScanProgress(event: ["stage":"analysing", "completed":9, "total":10,
            "cloud_data":["ready_bytes":1_000_000, "total_bytes":10_000_000, "inventory_complete":true],
            // Retried/previous traffic is deliberately larger than the inventory.
            // The visible row is slower than the aggregate across all downloads.
            "downloaded_bytes":100_000_000,
            "downloads":["total":140, "omitted":139, "speed":1000,
                "items":[["id":1, "name":"fixture.bin", "received":10, "total":100, "speed":1]]]])
        progress.downloadsUpdatedAt = now
        precondition(progress.cloudDownloadSecondsRemaining(at: now) == 9000)
        precondition(progress.cloudDownloadTimeLabel(at: now, running: true) == "About 2 hours 30 mins left to download")
        progress.cloudBytesReady = 9_970_000
        precondition(progress.cloudDownloadTimeLabel(at: now, running: true) == "Less than 2 mins left to download",
            "Cached, skipped and partially downloaded bytes reduce the remaining work")
        for date in [now, now.addingTimeInterval(3600)] {
            precondition(progress.cloudDownloadTimeLabel(at: date, running: false) == "Download time estimate paused")
        }
        precondition(progress.cloudDownloadTimeLabel(at: now, running: true, restoring: true) == "Estimating download time…")
        precondition(progress.cloudDownloadSecondsRemaining(at: now.addingTimeInterval(5)) == nil,
            "A silent helper must not leave a stale estimate on screen")
        for rate in [0.0, -1, Double.nan, Double.infinity] {
            progress.downloadSpeed = rate
            precondition(progress.cloudDownloadSecondsRemaining(at: now) == nil)
        }
        progress.downloadSpeed = 1000; progress.cloudByteInventoryComplete = false
        precondition(progress.cloudDownloadSecondsRemaining(at: now) == nil)
        precondition(progress.cloudDownloadTimeLabel(at: now, running: true) == "Counting files to estimate download time…")
        progress.cloudByteInventoryComplete = true; progress.cloudBytesReady = 0
        progress.cloudBytesTotal = 172_800_000
        precondition(progress.cloudDownloadTimeLabel(at: now, running: true) == "About 2 days left to download")
        let durationParts: [UInt64] = [2 * 30 * 1440, 2 * 7 * 1440, 2 * 1440, 2 * 60, 2]
        progress.cloudBytesTotal = durationParts.reduce(0, +) * 60 * 1000
        precondition(progress.cloudDownloadTimeLabel(at: now, running: true)
            == "About 2 months 2 weeks 2 days 2 hours 2 mins left to download")
        progress.cloudBytesTotal = 5_400_000
        precondition(progress.cloudDownloadTimeLabel(at: now, running: true) == "About 90 mins left to download",
            "A hidden one-hour unit must carry into minutes instead of understating the remaining duration")
        progress.cloudBytesTotal = UInt64((30 + 7 + 2) * 86_400 * 1000)
        precondition(progress.cloudDownloadTimeLabel(at: now, running: true) == "About 5 weeks 4 days left to download")
        progress.cloudBytesTotal = UInt64.max; progress.downloadSpeed = 1
        precondition(progress.cloudDownloadTimeLabel(at: now, running: true)!.contains(" months"),
            "Very large byte counts must format safely without overflowing")
        progress.cloudBytesTotal = 0; progress.downloadSpeed = 0
        precondition(progress.cloudDownloadTimeLabel(at: now, running: true) == "Cloud downloads complete")
        progress.cloudBytesReady = 1
        precondition(progress.cloudDownloadTimeLabel(at: now, running: true) == "Cloud downloads complete")
        progress.stage = .comparison
        precondition(progress.cloudDownloadTimeLabel(at: now, running: true) == nil,
            "A completed download estimate must not claim the comparison is finished")
        progress.stage = .analysing; progress.cloudBytesTotal = nil
        precondition(progress.cloudDownloadTimeLabel(at: now, running: true) == nil)
        print("PASS cloud download ETA uses remaining bytes and aggregate speed, handles pause/restart/stalls and stays within the download stage")
    }
}

import Foundation

struct TorrentRelayState: Codable {
    let identity: UUID
    let accountID: String
    let credentialKind: PikPakCredentialKind
    let accountName: String
    let parentID: String
    let parentName: String
    let rootName: String
    let memoryBytes: UInt64
    let batches: [[Int]]
    var batch = 0
    var uploaded: Set<Int> = []
    var volume: TorrentRAMVolume?
    var batchReady = false
    var batchDownloaded: UInt64 = 0
    var batchTotal: UInt64 = 0
    /// Files unlinked from the RAM volume. Distinct from `uploaded`, which
    /// records files saved to PikPak: a file is uploaded first and only later
    /// becomes safe to delete. Optional so a queue written by an earlier build,
    /// which has no such key, still decodes.
    var drained: [Int]?
    var currentIndex: Int?
    var currentBytes: UInt64 = 0
    var stage = ""
    static let gib: UInt64 = 1024 * 1024 * 1024
    static let minimumBudget: UInt64 = 256 * 1024 * 1024
    static var budgets: [UInt64] { budgetOptions(physicalMemory: ProcessInfo.processInfo.physicalMemory) }
    static var defaultBudget: UInt64 { min(4 * gib, budgets.last ?? gib) }

    static func maximumBudget(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> UInt64 {
        // Leave a quarter of installed memory outside the RAM volume, and
        // align its size to the sectors expected by hdiutil.
        (physicalMemory / 4 * 3) / 512 * 512
    }
    static func budgetOptions(physicalMemory: UInt64) -> [UInt64] {
        let maximumGiB = maximumBudget(physicalMemory: physicalMemory) / gib
        var sizes: [UInt64] = [1, 2, 4, 8].filter { $0 <= maximumGiB }
        var size: UInt64 = 16
        while size <= maximumGiB {
            sizes.append(size)
            let intermediate = size + size / 2
            if intermediate <= maximumGiB { sizes.append(intermediate) }
            size *= 2
        }
        if maximumGiB > 0, sizes.last != maximumGiB { sizes.append(maximumGiB) }
        return sizes.map { $0 * gib }
    }
    static func validateBudget(_ budget: UInt64, physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) throws {
        let maximum = maximumBudget(physicalMemory: physicalMemory)
        guard budget >= minimumBudget, budget <= maximum, budget % 512 == 0 else {
            let limit = ByteCountFormatter.string(fromByteCount: Int64(clamping: maximum), countStyle: .memory)
            throw LocalTorrentError.message("Choose a RAM buffer between 256 MB and \(limit) (75% of this Mac’s memory).")
        }
    }
    static func plan(files: [LocalTorrentFile], budget: UInt64, pieceLength: UInt64,
                     physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) throws -> [[Int]] {
        try validateBudget(budget, physicalMemory: physicalMemory)
        let capacity = budget / 100 * 85
        // Include APFS metadata and unselected pieces at each selected run.
        // Adjacent files share boundary pieces; counting them once per file
        // would waste most of the buffer on torrents containing small files.
        let piece = max(16_384, pieceLength == 0 ? 16 * 1024 * 1024 : pieceLength)
        guard piece <= capacity / 4 else { throw LocalTorrentError.message("This torrent uses large pieces. Choose a larger RAM buffer.") }
        let overhead = piece * 2 + 4096
        var result: [[Int]] = [], current: [Int] = [], used: UInt64 = 0
        for file in files.sorted(by: { $0.index < $1.index }) {
            guard file.length <= capacity - overhead else {
                throw LocalTorrentError.message("“\(file.path)” needs \(LocalTorrentFormat.bytes(file.length)) plus torrent overhead. Increase the RAM buffer or deselect this file. File contents stay in RAM only.")
            }
            guard file.index > 0 else { throw LocalTorrentError.message("The torrent contains an invalid file index.") }
            let adjacent = current.last.map { $0 == file.index - 1 } ?? false
            var size = file.length + 4096 + (adjacent ? 0 : piece * 2)
            if used + size > capacity {
                result.append(current); current = []; used = 0; size = file.length + overhead
            }
            current.append(file.index); used += size
        }
        if !current.isEmpty { result.append(current) }
        guard !result.isEmpty else { throw LocalTorrentError.message("Select at least one file to download.") }
        return result
    }
}

extension LocalTorrentJob {
    /// The relay download line. A stall explanation is appended to it rather
    /// than replacing it, so the card never loses which batch is running.
    func relayProgressMessage(portMapping: TorrentPortMapState) -> String {
        let batch = relay.map { "Downloading batch \($0.batch + 1) of \($0.batches.count) into RAM" } ?? ""
        guard let note = stallNote(portMapping: portMapping) else { return batch }
        return batch.isEmpty ? note : batch + " — " + note
    }
}

@MainActor extension LocalTorrentModel {
    func configureRelayAccount(_ account: DownloaderModel) {
        relayFilesChanged = { [weak account] in account?.pikpakManagement.onFilesChanged?() }
        relayContextProvider = { [weak account] in
            account?.preparePikPakManagement()
            return account?.pikpakManagement.context
        }
    }
    func relayContext(_ state: TorrentRelayState) throws -> PikPakManagementContext {
        guard let context = relayContextProvider?(), context.identity == state.identity,
              context.accountID == state.accountID, context.credentialKind == state.credentialKind else {
            throw LocalTorrentError.message("Select \(state.accountName) with \(state.credentialKind.loginTitle.lowercased()) in the sidebar, then Resume this torrent.")
        }
        return context
    }
    func downloadToPikPak(_ id: UUID, selected: Set<Int>, context: PikPakManagementContext, accountName: String,
                         parentID: String, parentName: String, memoryBytes: UInt64) async {
        guard let value = job(id), value.canChoose, !busy.contains(id), !closed else { return }
        error = nil
        do {
            guard !selected.isEmpty, selected.isSubset(of: Set(value.files.map(\.index))) else { throw LocalTorrentError.message("Select files from this torrent.") }
            let files = value.files.filter { selected.contains($0.index) }
            let batches = try TorrentRelayState.plan(files: files, budget: memoryBytes, pieceLength: value.pieceLength ?? 0)
            let total = try selectedTotal(files)
            let state = TorrentRelayState(identity: context.identity, accountID: context.accountID, credentialKind: context.credentialKind,
                accountName: accountName, parentID: parentID, parentName: parentName,
                rootName: LocalTorrentSource.folderName(value.name, id: id), memoryBytes: memoryBytes, batches: batches)
            _ = try relayContext(state)
            edit(id) { $0.relay = state; $0.selected = selected.sorted(); $0.total = total; $0.completed = 0; $0.phase = .paused }
            try save()
            await resumeRelay(id)
        } catch { self.error = error.localizedDescription }
    }
    func resumeRelay(_ id: UUID) async {
        guard let value = job(id), let state = value.relay, !busy.contains(id), !closed else { return }
        error = nil
        do {
            _ = try relayContext(state)
            if relayTasks[id] != nil {
                try relayUploaders[id]?.pause(false)
                edit(id) { $0.phase = .uploading; $0.message = "" }
                try save(); return
            }
            if let other = jobs.first(where: { $0.id != id && ($0.relay?.volume != nil || ($0.relay != nil && $0.phase.active)) && $0.phase != .completed && $0.phase != .stopped }) {
                throw LocalTorrentError.message("“\(other.name)” holds the RAM buffer. Finish or Stop it to release memory before starting another PikPak torrent.")
            }
            launchRelay(id, reconcile: true)
        } catch { self.error = error.localizedDescription; edit(id) { $0.message = error.localizedDescription }; saveOrReport() }
    }
    private func launchRelay(_ id: UUID, reconcile: Bool) {
        guard relayTasks[id] == nil, !closed else { return }
        let generation = UUID(); relayGenerations[id] = generation
        edit(id) { $0.phase = .uploading; $0.message = reconcile ? "Checking saved uploads…" : "Preparing upload…" }
        relayTasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                if reconcile { try await self.runRelayUpload(id, reconcile: true, generation: generation) }
                try self.checkRelay(id, generation)
                try await self.advanceRelay(id, generation: generation)
            } catch {
                if !self.closed, self.relayGenerations[id] == generation {
                    // An unpause response can be lost after aria2 accepts it.
                    // Keep that download monitored until status confirms pause,
                    // completion or failure; never leave a live writer hidden.
                    let mayBeDownloading = self.job(id)?.phase == .downloading && self.gids[id] != nil && self.engine.running
                    self.edit(id) { if !mayBeDownloading { $0.phase = .failed }; $0.downloadSpeed = 0; $0.uploadSpeed = 0; $0.message = error.localizedDescription }
                    self.error = error.localizedDescription; self.saveOrReport()
                }
            }
            if self.relayGenerations[id] == generation { self.relayTasks[id] = nil; self.relayUploaders[id] = nil }
        }
        saveOrReport(); startPolling()
    }
    private func checkRelay(_ id: UUID, _ generation: UUID) throws {
        guard !closed, !Task.isCancelled, relayGenerations[id] == generation, let state = job(id)?.relay else { throw CancellationError() }
        _ = try relayContext(state)
    }
    private func waitForRelayResume(_ id: UUID, generation: UUID) async throws {
        while job(id)?.phase == .paused {
            try checkRelay(id, generation)
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        try checkRelay(id, generation)
    }
    private func advanceRelay(_ id: UUID, generation: UUID) async throws {
        try await waitForRelayResume(id, generation: generation)
        guard let value = job(id), var state = value.relay else { return }
        while state.batch < state.batches.count && state.batches[state.batch].allSatisfy({ state.uploaded.contains($0) }) {
            state.batch += 1; state.batchReady = false
        }
        edit(id) { $0.relay = state }
        if state.batch == state.batches.count {
            if let gid = gids[id], engine.running { try await engine.remove(gid); gids[id] = nil }
            if let volume = state.volume { try await ram.release(volume) }
            edit(id) { $0.phase = .completed; $0.completed = $0.total; $0.relay?.volume = nil; $0.downloadSpeed = 0; $0.uploadSpeed = 0; $0.message = "Saved to PikPak. RAM buffer released." }
            try save(); return
        }
        busy.insert(id); defer { finishOperation(id) }
        let advancedBatch = state.batch != value.relay?.batch
        let oldVolume = state.volume
        let volume = try await ram.acquire(id: id, bytes: state.memoryBytes, directory: store.jobDirectory(id))
        try checkRelay(id, generation)
        if oldVolume?.uuid != volume.uuid { state.batchReady = false; state.batchDownloaded = 0 }
        state.volume = volume
        if advancedBatch { try await ram.clear(volume) }
        edit(id) { $0.relay = state }
        try save()
        if state.batchReady {
            busy.remove(id)
            let remaining = Set(state.batches[state.batch]).subtracting(state.uploaded)
            if !remaining.isEmpty { try await runRelayUpload(id, reconcile: false, generation: generation, indexes: remaining) }
            try checkRelay(id, generation)
            try await ram.clear(volume)
            edit(id) { $0.relay?.batchReady = false; $0.relay?.batch += 1; $0.relay?.batchDownloaded = 0; $0.relay?.currentBytes = 0 }
            try save()
            try await advanceRelay(id, generation: generation)
            return
        }
        let selection = state.batches[state.batch].filter { !state.uploaded.contains($0) }
        // Retain an existing partial aria2 job for an ordinary Pause/Resume.
        // Reconstructing after app exit uses the RAM volume's .aria2 bitfield.
        try await connect()
        if let gid = gids[id] {
            let status = try await engine.status(gid, files: false)
            if ["error", "removed", "complete"].contains(status.state) { try await engine.remove(gid); gids[id] = nil }
        }
        if gids[id] == nil {
            let source = try LocalTorrentStore.read(store.jobDirectory(id).appendingPathComponent("source.torrent"), maximum: LocalTorrentStore.maximumMetadataBytes)
            gids[id] = try await engine.addTorrent(source, directory: volume.payload, selection: selection)
        }
        try await ram.validate(volume); try checkRelay(id, generation)
        let total = try selectedTotal(value.files.filter { selection.contains($0.index) })
        edit(id) { $0.phase = .downloading; $0.relay?.batchTotal = total; $0.message = "Downloading batch \(state.batch + 1) of \(state.batches.count) into RAM" }
        try save(); startPolling()
        try await engine.begin(gids[id]!, directory: volume.payload, selection: selection)
    }
    private func runRelayUpload(_ id: UUID, reconcile: Bool, generation: UUID, indexes: Set<Int>? = nil) async throws {
        try checkRelay(id, generation)
        guard let value = job(id), let state = value.relay else { return }
        let context = try relayContext(state), directory = try store.jobDirectory(id)
        let selected = indexes ?? Set(reconcile ? value.selected : state.batches[state.batch])
        let files = value.files.filter { selected.contains($0.index) && !state.uploaded.contains($0.index) }
        if files.isEmpty { return }
        if !reconcile {
            guard let volume = state.volume else { throw LocalTorrentError.message("The RAM buffer was lost. Restart Download to fetch unfinished files again.") }
            try await ram.validate(volume)
        }
        let request: [String: Any] = ["version":1, "account_id":state.accountID, "job_id":id.uuidString,
            "parent_id":state.parentID, "root_name":state.rootName,
            "ram_root":state.volume?.payload.path ?? directory.appendingPathComponent("RAM/payload").path,
            "checkpoint_dir":directory.appendingPathComponent("CloudReceipts").path,
            "reconcile_only":reconcile, "parent_pid":ProcessInfo.processInfo.processIdentifier,
            "files":files.map { ["index":$0.index, "path":$0.path, "size":$0.length] as [String: Any] }]
        let uploader = relayUploaderFactory(); relayUploaders[id] = uploader
        edit(id) { $0.phase = .uploading; $0.downloadSpeed = 0; $0.uploadSpeed = 0; $0.message = reconcile ? "Checking files already saved to PikPak…" : "Uploading verified files from RAM…" }
        try save()
        try await uploader.run(request: request, directory: directory, context: context) { [weak self] event in
            guard let self, self.relayGenerations[id] == generation, !self.closed else { return }
            self.receiveRelay(id, event: event)
        }
        relayUploaders[id] = nil
        try checkRelay(id, generation)
        if !reconcile, !files.allSatisfy({ job(id)?.relay?.uploaded.contains($0.index) == true }) {
            throw LocalTorrentError.message("PikPak did not confirm every file. Resume to check saved uploads before releasing RAM.")
        }
        if !reconcile { relayFilesChanged?() }
    }
    /// Queue files aria2 has finished, and hand them to the uploader once the
    /// queue is worth a spawn. Returns true when an upload ran, so the caller
    /// stops touching a job whose phase it no longer owns.
    private func drainCompletedFiles(_ id: UUID, gid: String) async throws -> Bool {
        let due = relayFileCensusAt[id].map { Date().timeIntervalSince($0) >= relayFileCensusInterval } ?? true
        guard due else { return false }
        relayFileCensusAt[id] = Date()
        let detail = try await engine.status(gid, files: true)
        guard let value = job(id), let state = value.relay, value.phase == .downloading,
              gids[id] == gid, !busy.contains(id), state.batch < state.batches.count else { return false }
        let done = Set(detail.files.filter { $0.completedLength >= $0.length }.map(\.index))
        let window = Set(state.batches[state.batch])
        let fresh = done.intersection(window).subtracting(state.uploaded)
        if !fresh.isEmpty {
            if (relayQueued[id] ?? []).isEmpty { relayQueuedSince[id] = Date() }
            relayQueued[id, default: []].formUnion(fresh)
        }
        // A file becomes removable when a *neighbour* finishes, which is a
        // download event, so this runs every census rather than only on commit.
        await reclaimRelayRAM(id, complete: done)
        guard job(id)?.phase == .downloading, gids[id] == gid, !busy.contains(id) else { return false }
        let queued = relayQueued[id] ?? []
        let bytes = value.files.filter { queued.contains($0.index) }.reduce(UInt64(0)) { $0 + $1.length }
        let waiting = relayQueuedSince[id].map { Date().timeIntervalSince($0) } ?? 0
        guard TorrentRelayDrain.shouldFlush(count: queued.count, bytes: bytes, waiting: waiting, windowComplete: false) else { return false }
        relayQueued[id] = []; relayQueuedSince[id] = nil
        try await flushRelayUploads(id, indexes: queued)
        return true
    }

    /// Deselect and unlink committed files whose pieces no longer serve any
    /// file still being downloaded, returning their RAM to the volume.
    ///
    /// Order matters: aria2 rewrites a file that is still selected, so the
    /// selection is narrowed first and the unlink follows. A file sharing a
    /// piece with an unfinished neighbour is left alone — deleting it would
    /// only fetch it a second time, which is measurably what aria2 does.
    private func reclaimRelayRAM(_ id: UUID, complete: Set<Int>) async {
        guard !closed, let value = job(id), let state = value.relay, let volume = state.volume,
              let gid = gids[id], let pieceLength = value.pieceLength, pieceLength > 0,
              engine.running, state.batch < state.batches.count else { return }
        let window = Set(state.batches[state.batch])
        let removed = Set(state.drained ?? [])
        let layout = TorrentRelayDrain.Layout(files: value.files, pieceLength: pieceLength)
        let ready = TorrentRelayDrain.removable(layout: layout, complete: complete,
                                                committed: state.uploaded, removed: removed)
            .filter { window.contains($0) }
        guard !ready.isEmpty else { return }
        let keep = window.subtracting(removed).subtracting(ready).sorted()
        do {
            // Never hand aria2 an empty selection; the window boundary tears the
            // download down instead.
            if !keep.isEmpty { try await engine.reselect(gid, selection: keep) }
            guard job(id)?.relay?.volume == volume, gids[id] == gid else { return }
            var unlinked: [Int] = []
            for index in ready {
                guard let file = value.files.first(where: { $0.index == index }) else { continue }
                let path = volume.payload.appendingPathComponent(file.path)
                if FileManager.default.fileExists(atPath: path.path) {
                    // Leave a stubborn file for the window boundary rather than
                    // failing the transfer; its bytes are already in PikPak.
                    do { try FileManager.default.removeItem(at: path) } catch { continue }
                }
                unlinked.append(index)
            }
            guard !unlinked.isEmpty else { return }
            edit(id) { job in
                let current = job.relay?.drained ?? []
                job.relay?.drained = current.appendingUnique(unlinked)
            }
            saveOrReport()
        } catch {
            // Reclaim is opportunistic: a failure costs memory, never data.
            return
        }
    }

    /// Upload completed files while the rest of the window keeps downloading.
    /// The torrent is deliberately left running: BitTorrent and the PikPak
    /// upload share this Mac's link rather than taking turns.
    private func flushRelayUploads(_ id: UUID, indexes: Set<Int>) async throws {
        guard let generation = relayGenerations[id], relayUploaders[id] == nil, !indexes.isEmpty else { return }
        let resume = job(id)?.phase
        do {
            try await runRelayUpload(id, reconcile: false, generation: generation, indexes: indexes)
        } catch {
            // Keep them queued so the next census retries. A failed upload must
            // never silently drop a file out of its window.
            relayQueued[id, default: []].formUnion(indexes)
            if relayQueuedSince[id] == nil { relayQueuedSince[id] = Date() }
            throw error
        }
        if let resume, job(id)?.phase == .uploading { edit(id) { $0.phase = resume } }
        saveOrReport()
        relayFilesChanged?()
    }

    private func receiveRelay(_ id: UUID, event: [String: Any]) {
        guard let kind = event["event"] as? String, let index = event["index"] as? Int,
              let value = job(id), let file = value.files.first(where: { $0.index == index }), value.selected.contains(index) else { return }
        let bytes = (event["bytes"] as? NSNumber)?.uint64Value ?? 0
        edit(id) { job in
            if kind == "committed" {
                if job.relay?.uploaded.insert(index).inserted == true { job.completed += file.length }
                job.relay?.currentBytes = 0; job.uploadSpeed = 0
            } else {
                job.relay?.currentIndex = index
                job.relay?.currentBytes = min(bytes, file.length)
                job.relay?.stage = kind.hasPrefix("hash") ? "hashing" : "uploading"
                job.message = (kind.hasPrefix("hash") ? "Preparing " : "Uploading ") + file.path
            }
        }
        if kind == "upload_progress" {
            let now = Date()
            if let (time, previous) = relayLastProgress[id], bytes >= previous {
                let elapsed = now.timeIntervalSince(time)
                if elapsed >= 0.2 { edit(id) { $0.uploadSpeed = UInt64(Double(bytes - previous) / elapsed) }; relayLastProgress[id] = (now, bytes) }
            } else { relayLastProgress[id] = (now, bytes) }
        } else if kind == "uploading" || kind == "committed" { relayLastProgress[id] = nil }
        if kind == "committed" { saveOrReport() }
    }
    func refreshRelay(_ id: UUID) async {
        guard let value = job(id), let state = value.relay, !busy.contains(id) else { return }
        do {
            _ = try relayContext(state)
            guard value.phase == .downloading, let gid = gids[id] else { return }
            let status = try await engine.status(gid, files: false)
            guard job(id)?.phase == .downloading, gids[id] == gid, !busy.contains(id) else { return }
            let mapping = portMapping
            edit(id) {
                $0.relay?.batchDownloaded = status.completed
                // uploadSpeed on a relay job measures the PikPak upload, not BitTorrent.
                $0.downloadSpeed = status.downloadSpeed; $0.uploadSpeed = 0
                $0.attempted = status.connections; $0.seeders = status.seeders
                $0.peers = min($0.peers, status.connections)
                if status.downloadSpeed > 0 { $0.stalledSince = nil } else if $0.stalledSince == nil { $0.stalledSince = Date() }
                $0.message = $0.relayProgressMessage(portMapping: mapping)
            }
            if status.state == "active" { await refreshCensus(id, gid: gid, attempted: status.connections) }
            guard job(id)?.phase == .downloading, gids[id] == gid, !busy.contains(id) else { return }
            if status.state == "active", try await drainCompletedFiles(id, gid: gid) { return }
            if status.state == "complete" {
                try await engine.remove(gid); gids[id] = nil
                edit(id) { $0.relay?.batchReady = true; $0.downloadSpeed = 0 }
                try save(); launchRelay(id, reconcile: false)
            } else if status.state == "error" { throw LocalTorrentError.message(status.error) }
            else if status.state == "paused" { edit(id) { $0.phase = .paused }; saveOrReport() }
        } catch {
            await pauseRelay(id)
            edit(id) { $0.message = error.localizedDescription }; saveOrReport()
        }
    }
    func pauseRelay(_ id: UUID) async {
        guard !busy.contains(id), job(id)?.phase.active == true else { return }
        busy.insert(id); defer { finishOperation(id) }
        do {
            if let uploader = relayUploaders[id] { try uploader.pause(true) }
            if let gid = gids[id], engine.running { try await engine.pause(gid) }
            edit(id) { $0.phase = .paused; $0.downloadSpeed = 0; $0.uploadSpeed = 0; $0.message = "Paused. RAM contents are kept. Stop releases the buffer." }
            try save()
        } catch { self.error = error.localizedDescription }
    }
    func stopRelay(_ id: UUID) async {
        if busy.contains(id) { pendingStops.insert(id); return }
        busy.insert(id); defer { busy.remove(id) }
        relayGenerations[id] = nil
        relayUploaders[id]?.stop(); relayTasks[id]?.cancel()
        if let task = relayTasks[id] { await task.value }
        relayTasks[id] = nil; relayUploaders[id] = nil
        do {
            if let gid = gids[id], engine.running { try await engine.remove(gid) }; gids[id] = nil
            if let volume = job(id)?.relay?.volume { try await ram.release(volume) }
            edit(id) { $0.phase = .stopped; $0.relay?.volume = nil; $0.relay?.batchReady = false; $0.relay?.batchDownloaded = 0; $0.relay?.currentBytes = 0; $0.downloadSpeed = 0; $0.uploadSpeed = 0; $0.message = "RAM released. Completed PikPak files are kept; Resume downloads unfinished files again." }
            try save()
        } catch { self.error = error.localizedDescription; edit(id) { $0.phase = .failed; $0.message = error.localizedDescription }; saveOrReport() }
    }
    func restartRelay(_ id: UUID) async {
        guard !busy.contains(id), job(id)?.relay != nil else { return }
        await stopRelay(id)
        guard job(id)?.phase == .stopped else { return }
        edit(id) { $0.relay?.batch = 0 }
        saveOrReport(); await resumeRelay(id)
    }
}

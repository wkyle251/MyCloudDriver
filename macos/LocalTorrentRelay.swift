import Foundation

struct TorrentRelayUploadFailure: Codable {
    let message: String
    let retryAt: Date?
    let awaitingAccount: Bool
}

struct TorrentRelayState: Codable {
    /// The saved login this transfer is currently running under. Followed
    /// rather than enforced: macOS re-issues account-entry UUIDs when a session
    /// is re-registered, and the login method is the user's to change.
    var identity: UUID
    let accountID: String
    var credentialKind: PikPakCredentialKind
    let accountName: String
    let parentID: String
    let parentName: String
    let rootName: String
    let memoryBytes: UInt64
    let batches: [[Int]]
    var batch = 0
    var uploaded: Set<Int> = []
    var volume: TorrentRAMVolume?
    /// Optional so existing RAM-only queues remain readable.
    var storage: TorrentRelayStorage?
    var payload: URL? { storage?.payload ?? volume?.payload }
    var bufferName: String { storage == nil ? "RAM" : "storage" }
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
    /// Optional additions preserve queues written by the batch scheduler.
    var selection: [Int]?
    var downloadedBytes: UInt64?
    var bufferUsed: UInt64?
    /// Last measured free space. Optional for queues saved by older builds.
    var bufferAvailable: UInt64?
    /// Nil also enables retention for queues saved before this option existed.
    var keepUploadedFiles: Bool?
    var keepsUploadedFiles: Bool { storage != nil && keepUploadedFiles != false }
    /// Total staging usage, including partial downloads and retained uploads.
    /// Nil uses the drive's free space plus our allocation, less 100 GB.
    var storageLimitBytes: UInt64?
    var effectiveStorageLimit: UInt64 {
        TorrentRelayDrain.storageLimit(capacity: bufferCapacity, configured: storageLimitBytes)
    }
    /// Upload availability is independent of the torrent writer. Optional for
    /// saved queues from earlier builds; unconfirmed files stay in the buffer.
    var uploadFailure: TorrentRelayUploadFailure?
    var paddingCleanup: TorrentPaddingCleanupState?
    var waitingForUploadSpace: Bool?
    /// The RAM scheduler uses its 85% ceiling; storage accounts for its total
    /// disk limit separately against allocated bytes and live free space.
    var admissionBudget: UInt64? { storage == nil ? memoryBytes : nil }
    var bufferCapacity: UInt64 {
        guard storage != nil else { return memoryBytes }
        let total = (bufferUsed ?? 0).addingReportingOverflow(bufferAvailable ?? 0)
        return total.overflow ? .max : total.partialValue
    }
    func usesLogin(_ context: PikPakManagementContext) -> Bool {
        accountID == context.accountID && identity == context.identity && credentialKind == context.credentialKind
    }
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
    /// Progress describes the current sliding window, not a fixed batch.
    func relayProgressMessage(portMapping: TorrentPortMapState, dns: TorrentDNSState) -> String {
        if checkingPieces == true { return checkingPiecesMessage }
        if relay?.waitingForUploadSpace == true { return "Waiting for PikPak uploads to free \(relay?.bufferName ?? "buffer") space. Downloaded files are kept." }
        if relay != nil, total > 0, downloadedBytes >= total { return "Downloaded files are waiting to be saved to PikPak." }
        let count = relay.map { Set($0.selection ?? []).subtracting($0.uploaded).count } ?? 0
        let target = relay?.storage == nil ? "into RAM" : "to storage"
        let batch = "Downloading \(count) \(count == 1 ? "file" : "files") \(target)"
        guard let note = stallNote(portMapping: portMapping, dns: dns) else { return batch }
        return batch.isEmpty ? note : batch + " — " + note
    }
}

@MainActor extension LocalTorrentModel {
    func resumeRestoredTransfers() async {
        guard !closed else { return }
        for value in jobs where restoredResumeIDs.contains(value.id) && value.phase == .paused {
            if let state = value.relay {
                if state.storage == nil {
                    guard !jobs.contains(where: { $0.id != value.id && $0.relay != nil &&
                        (($0.relay?.storage == nil && $0.phase.active) || ($0.relay?.volume != nil && $0.phase != .completed && $0.phase != .stopped)) }) else { continue }
                }
            }
            await resume(value.id, automatic: true)
        }
    }

    func configureRelayAccount(_ account: DownloaderModel) {
        relayFilesChanged = { [weak account] in account?.pikpakManagement.onFilesChanged?() }
        relayContextProvider = { [weak account] in
            account?.preparePikPakManagement()
            return account?.pikpakManagement.context
        }
        // Completed jobs also need the one-time legacy padding migration.
        if jobs.contains(where: { $0.relay != nil && $0.files.contains(where: \.isPadding) }) { startPolling() }
    }
    /// The PikPak account this transfer belongs to — not one of this Mac's
    /// saved login entries.
    ///
    /// Entry UUIDs are re-issued whenever a session is re-registered, so a
    /// transfer that runs for days cannot be pinned to one; and the login
    /// method is the user's to change mid-transfer, which is how an upload
    /// moves off a personal access token's 25% allowance onto the full account
    /// allowance. The account is what must not change, and the upload helper
    /// re-verifies it against the server before any cloud mutation.
    func relayContext(_ state: TorrentRelayState) throws -> PikPakManagementContext {
        guard let context = relayContextProvider?(), context.accountID == state.accountID else {
            throw LocalTorrentError.message("Sign in to \(state.accountName) to resume PikPak uploads. Downloaded files are kept.")
        }
        return context
    }

    /// Record the login a transfer is now running under, so its card and its
    /// saved state name the credentials actually being used.
    private func adoptRelayLogin(_ id: UUID, _ context: PikPakManagementContext) {
        guard let state = job(id)?.relay, state.accountID == context.accountID,
              state.identity != context.identity || state.credentialKind != context.credentialKind else { return }
        edit(id) { $0.relay?.identity = context.identity; $0.relay?.credentialKind = context.credentialKind }
        saveOrReport()
    }

    private func deferRelayUpload(_ id: UUID, error: Error) {
        guard let state = job(id)?.relay else { return }
        let context = try? relayContext(state)
        let awaitingAccount = context == nil
        let changedLogin = context.map { !state.usesLogin($0) } ?? false
        let attempts = min(5, (relayUploadFailures[id] ?? 0) + 1)
        if !changedLogin { relayUploadFailures[id] = attempts }
        let delay = changedLogin ? 0 : min(300, relayUploadRetryDelay * pow(2, Double(attempts - 1)))
        let failure = TorrentRelayUploadFailure(message: changedLogin ? "Switching PikPak upload login…" : String(error.localizedDescription.prefix(500)),
            retryAt: awaitingAccount ? nil : Date().addingTimeInterval(delay), awaitingAccount: awaitingAccount)
        edit(id) {
            $0.relay?.uploadFailure = failure
            $0.relay?.currentBytes = 0; $0.relay?.currentIndex = nil; $0.relay?.stage = ""
            $0.relayUploadSpeed = nil
            if $0.phase == .uploading, gids[id] != nil { $0.phase = .downloading }
            if $0.phase == .downloading { $0.message = $0.relayProgressMessage(portMapping: portMapping, dns: dnsState) }
        }
        relayLastProgress[id] = nil
        saveOrReport()
    }

    private func clearRelayUploadFailure(_ id: UUID, resetAttempts: Bool = true) {
        if resetAttempts { relayUploadFailures[id] = nil }
        guard job(id)?.relay?.uploadFailure != nil else { return }
        edit(id) { $0.relay?.uploadFailure = nil }
        saveOrReport()
    }

    /// Account availability controls only the cloud worker. Torrent pieces
    /// can keep arriving into the original buffer while sign-in is unavailable.
    private func relayUploadReady(_ id: UUID) -> Bool {
        guard let value = job(id), value.phase.active, let state = value.relay else { return false }
        guard let context = try? relayContext(state) else {
            relayUploaders[id]?.stop()
            if state.uploadFailure?.awaitingAccount != true {
                deferRelayUpload(id, error: LocalTorrentError.message("Sign in to \(state.accountName) to resume PikPak uploads."))
            }
            return false
        }
        let changedLogin = !state.usesLogin(context)
        if changedLogin, relayTasks[id] != nil {
            // The helper captured the old credentials at launch. Restart only
            // that helper; its receipts recover any commit whose reply is lost.
            // Keep the old identity until it exits so the retry skips backoff.
            relayUploaders[id]?.stop()
            return false
        }
        if changedLogin { adoptRelayLogin(id, context) }
        if let failure = state.uploadFailure, failure.awaitingAccount || changedLogin {
            edit(id) {
                $0.relay?.uploadFailure = .init(message: failure.message, retryAt: .distantPast, awaitingAccount: false)
            }
            saveOrReport()
            return true
        }
        return state.uploadFailure?.retryAt.map { $0 <= Date() } ?? true
    }
    func downloadToPikPak(_ id: UUID, selected: Set<Int>, context: PikPakManagementContext, accountName: String,
                         parentID: String, parentName: String, memoryBytes: UInt64) async {
        guard let value = job(id), value.canChoose, !busy.contains(id), !closed else { return }
        error = nil
        do {
            guard !selected.isEmpty, selected.isSubset(of: Set(value.payloadFiles.map(\.index))) else { throw LocalTorrentError.message("Select files from this torrent.") }
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
        edit(id) { $0.automaticallyResume = true; $0.retryAt = nil }
        do {
            let uploadContext = try? relayContext(state)
            if let task = relayTasks[id], !engine.running || gids[id] == nil {
                busy.insert(id)
                relayGenerations[id] = nil
                relayUploaders[id]?.stop(); task.cancel()
                await task.value
                relayTasks[id] = nil; relayUploaders[id] = nil
                finishOperation(id)
                guard !closed, job(id)?.automaticallyResume != false else { return }
            }
            if relayTasks[id] != nil {
                busy.insert(id); defer { finishOperation(id) }
                if let gid = gids[id], let payload = state.payload, let selection = state.selection, !selection.isEmpty {
                    try await validateRelayBuffer(id, state: state)
                    try await engine.beginRelay(gid, directory: payload, selection: selection)
                }
                let sameLogin = uploadContext.map { state.usesLogin($0) } ?? false
                if sameLogin { try relayUploaders[id]?.pause(false) }
                else { relayUploaders[id]?.stop() }
                edit(id) { $0.phase = sameLogin ? .uploading : .downloading; $0.message = "" }
                try save(); return
            }
            if let uploadContext { adoptRelayLogin(id, uploadContext) }
            if state.storage == nil, let other = jobs.first(where: { $0.id != id && ($0.relay?.volume != nil || ($0.relay != nil && $0.relay?.storage == nil && $0.phase.active)) && $0.phase != .completed && $0.phase != .stopped }) {
                throw LocalTorrentError.message("“\(other.name)” holds the RAM buffer. Finish or Stop it to release memory before starting another PikPak torrent.")
            }
            launchRelay(id, reconcile: true)
        } catch { self.error = error.localizedDescription; queueRecovery(id, message: error.localizedDescription) }
    }
    private func launchRelay(_ id: UUID, reconcile: Bool) {
        guard relayTasks[id] == nil, !closed else { return }
        let generation = UUID(); relayGenerations[id] = generation
        edit(id) { $0.phase = .uploading; $0.message = reconcile ? "Checking saved uploads…" : "Preparing upload…" }
        relayTasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                if reconcile {
                    do {
                        try await self.runRelayUpload(id, reconcile: true, generation: generation)
                        self.clearRelayUploadFailure(id)
                    } catch {
                        try self.checkRelay(id, generation)
                        self.deferRelayUpload(id, error: error)
                    }
                }
                try self.checkRelay(id, generation)
                try await self.advanceRelay(id, generation: generation)
            } catch {
                if !self.closed, self.relayGenerations[id] == generation {
                    // An unpause response can be lost after aria2 accepts it.
                    // Keep that download monitored until status confirms pause,
                    // completion or failure; never leave a live writer hidden.
                    let mayBeDownloading = self.job(id)?.phase == .downloading && self.gids[id] != nil && self.engine.running &&
                        (error as? LocalTorrentError) != .ramDestinationMismatch
                    self.edit(id) { if !mayBeDownloading { $0.phase = .failed }; $0.downloadSpeed = 0; $0.uploadSpeed = 0; $0.relayUploadSpeed = nil; $0.message = error.localizedDescription }
                    self.error = error.localizedDescription
                    self.queueRecovery(id, message: error.localizedDescription)
                }
            }
            if self.relayGenerations[id] == generation { self.relayTasks[id] = nil; self.relayUploaders[id] = nil }
        }
        saveOrReport(); startPolling()
    }
    private func checkRelay(_ id: UUID, _ generation: UUID) throws {
        guard !closed, !Task.isCancelled, relayGenerations[id] == generation, job(id)?.relay != nil else { throw CancellationError() }
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
        if Set(value.selected).isSubset(of: state.uploaded) {
            try await finishRelay(id)
            return
        }
        busy.insert(id); defer { finishOperation(id) }
        if state.storage != nil {
            try await validateRelayBuffer(id, state: state)
            // A crash can leave both copies recorded. Make the storage record
            // durable before retrying the release of the original RAM volume.
            try saveRelayMigration()
            if let volume = state.volume { try await ram.release(volume); state.volume = nil }
        } else {
            let volume = try await ram.acquire(id: id, bytes: state.memoryBytes, directory: store.jobDirectory(id))
            try checkRelay(id, generation)
            if state.volume?.uuid != volume.uuid {
                state.selection = []; state.downloadedBytes = value.completed; state.drained = []
            }
            state.volume = volume
        }
        if state.selection == nil {
            // Legacy queues retain their in-flight files and partial pieces.
            state.selection = state.batches.indices.contains(state.batch) ? state.batches[state.batch] : []
        }
        guard let payload = state.payload else { throw LocalTorrentError.message("The torrent buffer is unavailable.") }
        try checkRelay(id, generation)
        edit(id) { $0.relay = state }
        try save()
        try await connect()
        if let gid = gids[id] {
            let status = try await engine.status(gid, files: false)
            if ["error", "removed", "complete"].contains(status.state) { try await engine.remove(gid); gids[id] = nil }
        }
        try await validateRelayBuffer(id, state: state); try checkRelay(id, generation)
        _ = try await refillRelayWindow(id, progress: [:], start: true)
        guard let selection = job(id)?.relay?.selection, !selection.isEmpty else {
            throw LocalTorrentError.message("The \(state.bufferName) buffer has no room for the next file. Resume to try again.")
        }
        if gids[id] == nil {
            let source = try LocalTorrentStore.read(store.jobDirectory(id).appendingPathComponent("source.torrent"), maximum: LocalTorrentStore.maximumMetadataBytes)
            gids[id] = try await engine.addTorrent(source, directory: payload, selection: selection)
        }
        try checkRelay(id, generation)
        edit(id) { $0.phase = .downloading; $0.message = $0.relayProgressMessage(portMapping: portMapping, dns: dnsState) }
        try save(); startPolling()
        try await engine.beginRelay(gids[id]!, directory: payload, selection: selection)
        try? await engine.limitUpload(gids[id]!, bytesPerSecond: Aria2TorrentEngine.relayUploadLimit)
    }

    private func finishRelay(_ id: UUID) async throws {
        while busy.contains(id), !closed { try await Task.sleep(nanoseconds: 50_000_000) }
        try Task.checkCancellation()
        guard !closed, let state = job(id)?.relay else { return }
        busy.insert(id); defer { finishOperation(id) }
        if let gid = gids[id], engine.running {
            if state.storage != nil { try await pauseRelayWriter(gid) }
            try await engine.remove(gid); gids[id] = nil
        }
        if let storage = state.storage {
            try await validateRelayBuffer(id, state: state)
            try saveRelayMigration()
            try storage.clear()
        }
        if let volume = state.volume { try await ram.release(volume) }
        edit(id) {
            $0.phase = .completed; $0.completed = $0.total; $0.clearTransferStats()
            $0.relay?.volume = nil; $0.relay?.selection = []; $0.relay?.downloadedBytes = $0.total
            $0.relay?.bufferUsed = 0
            $0.message = state.storage == nil ? "Saved to PikPak. RAM buffer released." : "Saved to PikPak. Downloaded files removed from storage."
        }
        relayQueued[id] = nil; relayQueuedSince[id] = nil
        try save()
        Task { await resumeRestoredTransfers() }
    }

    private func runRelayUpload(_ id: UUID, reconcile: Bool, generation: UUID, indexes: Set<Int>? = nil) async throws {
        // Both helpers share the receipt lock. Downloads keep running.
        if let cleanup = paddingCleanupTasks[id] { await cleanup.value }
        try await waitForRelayResume(id, generation: generation)
        guard let value = job(id), let state = value.relay else { return }
        let selected = indexes ?? Set(reconcile ? value.selected : (state.selection ?? []))
        let files = value.files.filter { !$0.isPadding && selected.contains($0.index) && !state.uploaded.contains($0.index) }
        if files.isEmpty { return }
        if !reconcile { try await validateRelayBuffer(id, state: state) }
        // A Pause may arrive during reconciliation or buffer validation. Do
        // not launch the next helper until Resume, and use the current login.
        try await waitForRelayResume(id, generation: generation)
        let context = try relayContext(state), directory = try store.jobDirectory(id)
        adoptRelayLogin(id, context)
        let request: [String: Any] = ["version":1, "account_id":state.accountID, "job_id":id.uuidString,
            "parent_id":state.parentID, "root_name":state.rootName,
            "ram_root":state.payload?.path ?? directory.appendingPathComponent("RAM/payload").path,
            "checkpoint_dir":directory.appendingPathComponent("CloudReceipts").path,
            "reconcile_only":reconcile, "parent_pid":ProcessInfo.processInfo.processIdentifier,
            "files":files.map { ["index":$0.index, "path":$0.path, "size":$0.length] as [String: Any] }]
        let uploader = relayUploaderFactory(); relayUploaders[id] = uploader
        defer { if relayGenerations[id] == generation { relayUploaders[id] = nil } }
        edit(id) { $0.phase = .uploading; $0.relayUploadSpeed = 0; $0.message = reconcile ? "Checking files already saved to PikPak…" : "Uploading verified files from \(state.bufferName)…" }
        try save()
        try await uploader.run(request: request, directory: directory, context: context) { [weak self] event in
            guard let self, self.relayGenerations[id] == generation, !self.closed else { return }
            self.receiveRelay(id, event: event)
        }
        try checkRelay(id, generation)
        if !reconcile, !files.allSatisfy({ job(id)?.relay?.uploaded.contains($0.index) == true }) {
            throw LocalTorrentError.message("PikPak did not confirm every file. Saved uploads will be checked again before clearing the buffer.")
        }
        if !reconcile { relayFilesChanged?() }
    }
    /// A census advances the window independently of the upload worker.
    private func drainCompletedFiles(_ id: UUID, gid: String, force: Bool = false) async throws {
        let due = relayFileCensusAt[id].map { Date().timeIntervalSince($0) >= relayFileCensusInterval } ?? true
        guard due || force else { return }
        guard let detail = try await pollStatus(id, gid: gid, files: true) else { return }
        // A partial hash-check result is not a complete inventory of pieces.
        // Reselecting here interrupts verification and starts it over again.
        guard !detail.checkingPieces else { return }
        let padding = Set(detail.files.filter(\.padding).map(\.index))
        if var value = job(id), value.excludePaddingFiles(padding) {
            edit(id) { $0 = value }
            relayQueued[id]?.subtract(padding)
            saveOrReport()
        }
        relayFileCensusAt[id] = Date()
        guard let value = job(id), let state = value.relay, value.phase.active,
              gids[id] == gid, !busy.contains(id) else { return }
        await releaseRelayPadding(id, gid: gid, state: state)
        guard !closed, job(id)?.phase.active == true, gids[id] == gid, !busy.contains(id) else { return }
        if Set(value.selected).isSubset(of: state.uploaded), relayTasks[id] == nil, relayUploaders[id] == nil {
            try await finishRelay(id)
            return
        }
        let progress = Dictionary(detail.files.map { ($0.index, min($0.length, $0.completedLength)) }, uniquingKeysWith: max)
        let done = Set(detail.files.filter { !$0.padding && $0.completedLength >= $0.length }.map(\.index))
        let window = Set(state.selection ?? [])
        let fresh = done.intersection(window).subtracting(state.uploaded)
        if !fresh.isEmpty {
            if (relayQueued[id] ?? []).isEmpty { relayQueuedSince[id] = Date() }
            relayQueued[id, default: []].formUnion(fresh)
        }
        let wanted = Set(value.selected)
        let downloaded = value.files.filter { wanted.contains($0.index) && !state.uploaded.contains($0.index) }
            .reduce(value.completed) { $0 + min($1.length, progress[$1.index] ?? 0) }
        edit(id) {
            let previous = $0.relay?.downloadedBytes ?? 0
            $0.relay?.downloadedBytes = min($0.total, max(previous, downloaded))
        }
        busy.insert(id)
        let admission: TorrentRelayDrain.Admission
        do { admission = try await refillRelayWindow(id, progress: progress); finishOperation(id) }
        catch { finishOperation(id); throw error }
        guard job(id)?.phase.active == true, gids[id] == gid, !busy.contains(id) else { return }
        relayQueued[id]?.subtract(job(id)?.relay?.uploaded ?? [])
        let queued = relayQueued[id] ?? []
        let bytes = value.files.filter { queued.contains($0.index) }.reduce(UInt64(0)) { $0 + $1.length }
        let waiting = relayQueuedSince[id].map { Date().timeIntervalSince($0) } ?? 0
        let noMorePieces = Set(admission.selection).subtracting(job(id)?.relay?.uploaded ?? []).isSubset(of: done)
        edit(id) { $0.relay?.waitingForUploadSpace = admission.blockedOnSpace && noMorePieces }
        if job(id)?.relay?.uploadFailure != nil {
            launchRelayDrain(id, indexes: queued)
            return
        }
        guard TorrentRelayDrain.shouldFlush(count: queued.count, bytes: bytes, waiting: waiting,
            windowComplete: noMorePieces, wait: relayFlushWait,
            used: job(id)?.relay?.bufferUsed ?? 0, capacity: job(id)?.relay?.bufferCapacity ?? 0,
            blockedOnSpace: admission.blockedOnSpace) else { return }
        launchRelayDrain(id, indexes: queued)
    }

    /// Storage releases committed, piece-safe files through the live engine.
    /// RAM reclamation and selection growth still stop the writer before
    /// changing its file filter, with reservations for unfinished files.
    @discardableResult
    private func refillRelayWindow(_ id: UUID, progress: [Int: UInt64], start: Bool = false) async throws -> TorrentRelayDrain.Admission {
        guard let value = job(id), let state = value.relay, let payload = state.payload else {
            throw LocalTorrentError.message("The torrent buffer is unavailable.")
        }
        if state.storage != nil { try await validateRelayBuffer(id, state: state) }
        let wanted = Set(value.selected), active = Set(state.selection ?? []).intersection(wanted)
        func admission(_ space: (free: UInt64, used: UInt64, capacity: UInt64), active: Set<Int>) -> TorrentRelayDrain.Admission {
            if state.storage != nil {
                return TorrentRelayDrain.admitStorage(files: value.files, wanted: wanted, uploaded: state.uploaded,
                    active: active, progress: progress, available: space.free, used: space.used,
                    limit: TorrentRelayDrain.storageLimit(capacity: space.capacity, configured: state.storageLimitBytes),
                    pieceLength: value.pieceLength ?? 0, starting: start)
            }
            return TorrentRelayDrain.admit(files: value.files, wanted: wanted, uploaded: state.uploaded,
                active: active, progress: progress, available: space.free, budget: state.admissionBudget, pieceLength: value.pieceLength ?? 0)
        }
        let discardable = state.uploaded.union(value.files.filter { !wanted.contains($0.index) }.map(\.index))
        let done = Set(value.files.filter { (progress[$0.index] ?? 0) >= $0.length }.map(\.index)).union(discardable)
        let layout = TorrentRelayDrain.Layout(files: value.files, pieceLength: value.pieceLength ?? 16 * 1024 * 1024)
        // Reconsider committed boundary stubs too: aria2 may recreate them
        // when the next unadmitted neighbour enters the window.
        let ready = Set(TorrentRelayDrain.removable(layout: layout, complete: done,
            committed: discardable, removed: [], active: active.subtracting(state.uploaded)))
        var spaceBefore = try relayBufferSpace(state)
        if !start, state.storage != nil, let gid = gids[id], engine.running {
            let space = spaceBefore
            let plannedActive = Set(admission(space, active: active).selection).intersection(active)
            let reserved = TorrentRelayDrain.admit(files: value.files, wanted: plannedActive, uploaded: state.uploaded,
                active: plannedActive, progress: progress, available: 0, budget: nil, pieceLength: value.pieceLength ?? 0).reservedBytes
            let next = value.files.first { wanted.contains($0.index) && !active.contains($0.index) && !state.uploaded.contains($0.index) }
            let target = state.keepsUploadedFiles ? TorrentRelayDrain.storageReleaseTarget(available: space.free,
                used: space.used, limit: TorrentRelayDrain.storageLimit(capacity: space.capacity, configured: state.storageLimitBytes),
                reserved: reserved, nextFile: next?.length,
                pieceLength: value.pieceLength ?? 0) : UInt64.max
            if try await releaseStoredRelayFiles(id, gid: gid, state: state, ready: ready, target: target) {
                // Even a lost RPC reply may have freed files. Re-read after
                // cleanup, but reuse the first scan when nothing was attempted.
                spaceBefore = try relayBufferSpace(state)
            }
        }
        let freeBefore = spaceBefore.free
        let preview = admission(spaceBefore, active: active)
        let shrinking = !active.isSubset(of: Set(preview.selection))
        if !start {
            let used = spaceBefore.used
            let pending = wanted.subtracting(active).subtracting(state.uploaded)
            func retainWindow(blocked: Bool) -> TorrentRelayDrain.Admission {
                edit(id) { $0.relay?.bufferUsed = used; $0.relay?.bufferAvailable = freeBefore }
                return .init(selection: state.selection ?? [], blockedOnSpace: blocked)
            }
            if state.storage != nil {
                // Cleanup alone never reopens a storage torrent, even when
                // every admitted file is complete. Only admitting NEW files
                // can require the existing selection-growth path below.
                if !shrinking && (pending.isEmpty || preview.selection == (state.selection ?? [])) {
                    return retainWindow(blocked: preview.blockedOnSpace)
                }
            }
            if !shrinking, ready.isDisjoint(with: active) {
                // aria2 recreates unselected shared-piece stubs when reopening
                // its files. Removing those again with the same selection
                // causes a pause/reconnect loop at the census interval.
                if preview.selection == (state.selection ?? []), !preview.selection.isEmpty || pending.isEmpty {
                    return retainWindow(blocked: preview.blockedOnSpace)
                }
            }
            let remaining = value.files.filter { active.contains($0.index) && !state.uploaded.contains($0.index) }
                .reduce(UInt64(0)) { $0 + $1.length - min($1.length, progress[$1.index] ?? 0) }
            let reclaimable = value.files.filter { active.contains($0.index) && ready.contains($0.index) }
                .reduce(UInt64(0)) { $0 + $1.length }
            // Coalesce selection growth and RAM cleanup while useful work
            // still fits. Storage cleanup already happened without a pause.
            if !shrinking, !relayStorageLimitChanged.contains(id), !TorrentRelayDrain.shouldAdvanceWindow(hasPendingFiles: !pending.isEmpty, remainingBytes: remaining,
                reclaimableBytes: reclaimable, used: used, capacity: spaceBefore.capacity) {
                return retainWindow(blocked: !pending.isEmpty)
            }
        }
        // Serialize pauses, file removal and reselection with a storage move.
        // An unchanged window does not need a lock or a RAM volume recheck.
        if !start { busy.insert(id) }
        defer { if !start { finishOperation(id) } }
        // A cold start may have only uploaded files in its saved selection.
        // Reclaim excess confirmed copies before admitting the next file,
        // otherwise an over-limit cache could prevent the engine from starting.
        var startupRelease: UInt64 = 0
        if start, state.keepsUploadedFiles {
            let next = active.subtracting(state.uploaded).isEmpty
                ? value.files.first { wanted.contains($0.index) && !state.uploaded.contains($0.index) }?.length : nil
            startupRelease = TorrentRelayDrain.storageReleaseTarget(available: spaceBefore.free, used: spaceBefore.used,
                limit: TorrentRelayDrain.storageLimit(capacity: spaceBefore.capacity, configured: state.storageLimitBytes),
                reserved: 0, nextFile: next, pieceLength: value.pieceLength ?? 0)
        }
        var removableFiles: [LocalTorrentFile] = []
        for file in value.files where ready.contains(file.index) {
            // Native padding is virtual. Legacy stubs go through live engine
            // cleanup, which checkpoints the deletion. Unlinking them here
            // before resume would needlessly invalidate the saved manifest.
            if state.storage != nil, file.isPadding { continue }
            let retained = state.keepsUploadedFiles && state.uploaded.contains(file.index)
            guard !retained || startupRelease > 0 else { continue }
            let url = try TorrentRelayStorage.file(file.path, under: payload)
            guard active.contains(file.index) || url != nil else { continue }
            removableFiles.append(file)
            if retained, let url {
                let allocated = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0
                startupRelease -= min(startupRelease, UInt64(max(0, allocated)))
            }
        }
        let gid = gids[id]
        var suspended = false
        if !removableFiles.isEmpty, let gid, engine.running {
            try await engine.pauseAndWait(gid); suspended = true
        }
        if !removableFiles.isEmpty { try await validateRelayBuffer(id, state: state) }
        guard !closed, job(id)?.relay?.payload == payload else { throw CancellationError() }
        for file in removableFiles {
            if let url = try TorrentRelayStorage.file(file.path, under: payload) { try FileManager.default.removeItem(at: url) }
        }
        // Live storage cleanup preserves the engine's current selection to
        // keep its peers. On a later start, exclude durable cloud receipts
        // from that saved selection even before piece progress is available.
        // aria2 still checks/fetches boundaries needed by selected neighbours.
        let remaining = active.subtracting(ready).subtracting(start ? state.uploaded : [])
        let space = try relayBufferSpace(state)
        let plan = admission(space, active: remaining)
        let changed = plan.selection != (state.selection ?? [])
        if changed, !suspended, !start, let gid { try await engine.pauseAndWait(gid); suspended = true }
        guard !closed, job(id)?.relay?.payload == payload else { throw CancellationError() }
        edit(id) {
            let drained = $0.relay?.drained ?? []
            $0.relay?.selection = plan.selection
            $0.relay?.bufferUsed = space.used
            $0.relay?.bufferAvailable = space.free
            $0.relay?.drained = drained.appendingUnique(removableFiles.map(\.index))
        }
        if changed || !removableFiles.isEmpty { try save() }
        guard !plan.selection.isEmpty || wanted.isSubset(of: state.uploaded) else {
            throw LocalTorrentError.message("The \(state.bufferName) buffer has no room for the next file. Increase its storage limit or free space, then Resume.")
        }
        if !start, suspended, let gid, !plan.selection.isEmpty {
            try await validateRelayBuffer(id, state: state)
            try await engine.reselect(gid, selection: plan.selection)
            try await engine.beginRelay(gid, directory: payload, selection: plan.selection)
        }
        relayStorageLimitChanged.remove(id)
        return plan
    }

    /// Whether cleanup was attempted and storage usage must be measured again.
    private func releaseStoredRelayFiles(_ id: UUID, gid: String, state: TorrentRelayState, ready: Set<Int>, target: UInt64) async throws -> Bool {
        guard target > 0, let value = job(id), let payload = state.payload else { return false }
        var candidates: [Int] = []
        var remaining = target
        for file in value.files where ready.contains(file.index) && state.uploaded.contains(file.index) {
            // Persisted `drained` is history, not evidence about this engine
            // session: a later piece check may recreate a boundary stub.
            if let url = try TorrentRelayStorage.file(file.path, under: payload) {
                candidates.append(file.index)
                let allocated = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize ?? 0
                remaining -= min(remaining, UInt64(max(0, allocated)))
            }
            if candidates.count == 128 || remaining == 0 { break }
        }
        guard !candidates.isEmpty else { return false }
        let released: Set<Int>
        do {
            // The cloud receipt must be durable before deleting its local copy.
            try save()
            released = try await engine.releaseFiles(gid, directory: payload, indexes: candidates)
        } catch {
            // A failed/lost cleanup RPC is retried at the next census. It
            // must never pause downloading or fall back to unlinking live FDs.
            return true
        }
        guard !closed, gids[id] == gid, job(id)?.relay?.payload == payload, !released.isEmpty else { return true }
        edit(id) {
            let drained = $0.relay?.drained ?? []
            $0.relay?.drained = drained.appendingUnique(Array(released))
        }
        saveOrReport()
        return true
    }

    private func launchRelayDrain(_ id: UUID, indexes: Set<Int>) {
        guard paddingCleanupTasks[id] == nil, relayTasks[id] == nil, relayUploaders[id] == nil, let generation = relayGenerations[id], relayUploadReady(id) else { return }
        relayQueued[id]?.subtract(indexes); relayQueuedSince[id] = nil
        relayTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.relayGenerations[id] == generation { self.relayTasks[id] = nil; self.relayUploaders[id] = nil }
            }
            do {
                do {
                    if self.job(id)?.relay?.uploadFailure != nil {
                        // A cloud commit may have succeeded despite a lost
                        // reply. Reconcile receipts before sending files again.
                        try await self.runRelayUpload(id, reconcile: true, generation: generation)
                        self.clearRelayUploadFailure(id, resetAttempts: false)
                    }
                    try await self.flushRelayUploads(id, indexes: indexes)
                } catch {
                    try self.checkRelay(id, generation)
                    // A missing or unsafe local destination still stops its
                    // writer. Cloud failures alone never pause BitTorrent.
                    if let state = self.job(id)?.relay { try await self.validateRelayBuffer(id, state: state) }
                    try self.checkRelay(id, generation)
                    self.relayQueued[id, default: []].formUnion(indexes.subtracting(self.job(id)?.relay?.uploaded ?? []))
                    if self.relayQueuedSince[id] == nil { self.relayQueuedSince[id] = Date() }
                    self.deferRelayUpload(id, error: error)
                    return
                }
                self.clearRelayUploadFailure(id)
                self.edit(id) {
                    if $0.phase == .uploading { $0.phase = .downloading; $0.relayUploadSpeed = nil }
                }
                self.saveOrReport()
                try await self.waitForRelayResume(id, generation: generation)
                if let value = self.job(id), Set(value.selected).isSubset(of: value.relay?.uploaded ?? []) {
                    try await self.finishRelay(id)
                }
            } catch {
                if !self.closed, self.relayGenerations[id] == generation {
                    await self.pauseRelay(id, automatic: true)
                    self.queueRecovery(id, message: error.localizedDescription)
                }
            }
        }
    }

    /// Upload completed files while the rest of the window keeps downloading.
    /// The torrent is deliberately left running: BitTorrent and the PikPak
    /// upload share this Mac's link rather than taking turns.
    private func flushRelayUploads(_ id: UUID, indexes: Set<Int>) async throws {
        guard let generation = relayGenerations[id], relayUploaders[id] == nil, !indexes.isEmpty else { return }
        try await runRelayUpload(id, reconcile: false, generation: generation, indexes: indexes)
        if job(id)?.phase == .uploading { edit(id) { $0.phase = .downloading; $0.relayUploadSpeed = nil } }
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
                job.relay?.currentBytes = 0; job.relayUploadSpeed = 0
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
                if elapsed >= 0.2 { edit(id) { $0.relayUploadSpeed = UInt64(Double(bytes - previous) / elapsed) }; relayLastProgress[id] = (now, bytes) }
            } else { relayLastProgress[id] = (now, bytes) }
        } else if kind == "uploading" || kind == "committed" { relayLastProgress[id] = nil }
        if kind == "committed" { saveOrReport() }
    }
    func refreshRelay(_ id: UUID) async {
        guard job(id)?.relay != nil, !busy.contains(id) else { return }
        let uploadReady = relayUploadReady(id)
        guard let value = job(id) else { return }
        // A restored login or expired retry backoff is actionable now. It
        // must not wait for the slower routine file census to start recovery.
        let retryUpload = uploadReady && value.relay?.uploadFailure != nil
            && relayTasks[id] == nil && relayUploaders[id] == nil
        do {
            // A drain uploads finished files while the torrent keeps running,
            // so its telemetry is still live and worth refreshing every poll.
            // File admission keeps running while completed files upload.
            let draining = value.phase == .uploading
            guard value.phase == .downloading || draining, let gid = gids[id] else { return }
            guard let status = try await pollStatus(id, gid: gid, files: false) else {
                edit(id) { $0.downloadSpeed = 0; $0.uploadSpeed = 0
                           if !draining { $0.message = "Reconnecting to download status…" } }
                return
            }
            guard job(id)?.phase == value.phase, gids[id] == gid, !busy.contains(id) else { return }
            let mapping = portMapping
            edit(id) {
                if status.completed > ($0.relay?.batchDownloaded ?? 0) { $0.retryAttempt = nil; $0.retryAt = nil }
                $0.relay?.batchDownloaded = status.completed
                $0.applyCheckingState(status)
                // Both BitTorrent rates; the PikPak upload is reported on its own.
                $0.downloadSpeed = status.checkingPieces ? 0 : status.downloadSpeed
                $0.uploadSpeed = status.checkingPieces ? 0 : status.uploadSpeed
                $0.attempted = status.connections; $0.seeders = status.seeders
                $0.peers = min($0.peers, status.connections)
                if status.checkingPieces || status.downloadSpeed > 0 { $0.stalledSince = nil } else if $0.stalledSince == nil { $0.stalledSince = Date() }
                // The uploader owns the line while it runs: it names the file.
                if !draining { $0.message = $0.relayProgressMessage(portMapping: mapping, dns: dnsState) }
            }
            if status.state == "active", !status.checkingPieces { await refreshCensus(id, gid: gid, attempted: status.connections) }
            guard job(id)?.phase.active == true, gids[id] == gid, !busy.contains(id) else { return }
            if ["active", "complete"].contains(status.state), !status.checkingPieces {
                try await drainCompletedFiles(id, gid: gid, force: status.state == "complete" || retryUpload)
            } else if ["error", "paused", "removed"].contains(status.state) {
                throw LocalTorrentError.message(status.error.isEmpty ? "Torrent transfer was interrupted." : status.error)
            }
        } catch {
            await pauseRelay(id, automatic: true)
            queueRecovery(id, message: error.localizedDescription)
        }
    }
    func pauseRelay(_ id: UUID, automatic: Bool = false) async {
        if !automatic { holdRecovery(id) }
        guard !busy.contains(id), job(id)?.phase.active == true else { return }
        busy.insert(id); defer { finishOperation(id) }
        do {
            cancelPaddingCleanup(id)
            if let uploader = relayUploaders[id] { try uploader.pause(true) }
            if let gid = gids[id], engine.running { try await engine.pause(gid) }
            statusFailures[id] = nil
            edit(id) { $0.phase = .paused; $0.downloadSpeed = 0; $0.uploadSpeed = 0; $0.relayUploadSpeed = nil; $0.message = $0.relay?.storage == nil ? "Paused. RAM contents are kept. Stop releases the buffer." : "Paused. Downloaded files are kept in storage for Resume." }
            try save()
        } catch { self.error = error.localizedDescription }
    }
    func stopRelay(_ id: UUID) async {
        holdRecovery(id)
        if busy.contains(id) { pendingStops.insert(id); return }
        busy.insert(id); defer { busy.remove(id) }
        relayGenerations[id] = nil; statusFailures[id] = nil
        relayUploadFailures[id] = nil
        cancelPaddingCleanup(id)
        if let cleanup = paddingCleanupTasks[id] { await cleanup.value }
        relayUploaders[id]?.stop(); relayTasks[id]?.cancel()
        if let task = relayTasks[id] { await task.value }
        relayTasks[id] = nil; relayUploaders[id] = nil
        do {
            if let gid = gids[id], engine.running {
                if job(id)?.relay?.storage != nil { try await pauseRelayWriter(gid) }
                try await engine.remove(gid)
            }
            gids[id] = nil
            if job(id)?.relay?.storage != nil { try saveRelayMigration() }
            if let volume = job(id)?.relay?.volume { try await ram.release(volume) }
            edit(id) {
                $0.phase = .stopped; $0.relay?.volume = nil; $0.relay?.currentBytes = 0; $0.clearTransferStats()
                if $0.relay?.storage == nil {
                    $0.relay?.batchReady = false; $0.relay?.batchDownloaded = 0; $0.relay?.selection = []; $0.relay?.downloadedBytes = $0.completed
                    $0.message = "RAM released. Completed PikPak files are kept; Resume downloads unfinished files again."
                } else { $0.message = "Stopped. Downloaded files stay in storage. Resume continues uploading to PikPak." }
            }
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

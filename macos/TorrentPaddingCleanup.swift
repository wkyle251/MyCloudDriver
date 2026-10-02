import Foundation

struct TorrentPaddingCleanupState: Codable {
    var checked: Set<Int> = []
    var removed: Set<Int> = []
    var failure: String?
    var retryAt: Date?
    var attempt = 0
}

@MainActor extension LocalTorrentModel {
    /// Padding is virtual, so even partial legacy stubs can be reclaimed
    /// without a cloud receipt or storage pressure. The live engine flushes
    /// and checkpoints the change without withdrawing neighboring real pieces.
    func releaseRelayPadding(_ id: UUID, gid: String, state: TorrentRelayState) async {
        guard let value = job(id), let payload = state.payload, engine.running,
              gids[id] == gid, value.checkingPieces != true,
              value.files.contains(where: \.isPadding) else { return }
        do {
            try await validateRelayBuffer(id, state: state)
            guard !closed, gids[id] == gid, job(id)?.phase.active == true else { return }
            var indexes: [Int] = []
            for file in value.files where file.isPadding {
                if try TorrentRelayStorage.file(file.path, under: payload) != nil { indexes.append(file.index) }
                if indexes.count == 128 { break }
            }
            if !indexes.isEmpty { _ = try await engine.releaseFiles(gid, directory: payload, indexes: indexes) }
        } catch {
            // Retry on the next census. Never unlink behind the writer or
            // pause an otherwise healthy transfer for cleanup.
        }
    }

    func cancelPaddingCleanup(_ id: UUID) {
        paddingCleanupUploaders[id]?.stop()
        paddingCleanupTasks[id]?.cancel()
    }

    func launchPaddingCleanup(_ id: UUID) {
        guard !closed, !busy.contains(id), paddingCleanupTasks[id] == nil,
              relayTasks[id] == nil, relayUploaders[id] == nil,
              let value = job(id), value.phase.active || value.phase == .completed,
              let state = value.relay else { return }
        let cleanup = state.paddingCleanup ?? .init()
        guard cleanup.retryAt.map({ $0 <= Date() }) ?? true else { return }
        let files = value.files.filter { $0.isPadding && !cleanup.checked.contains($0.index) }
        guard !files.isEmpty else { return }
        let context: PikPakManagementContext
        do { context = try relayContext(state) }
        catch { deferPaddingCleanup(id, error: error); return }
        let allowed = Set(files.map(\.index))
        let uploader = paddingCleanupUploaderFactory()
        paddingCleanupUploaders[id] = uploader
        paddingCleanupTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.paddingCleanupTasks[id] = nil; self.paddingCleanupUploaders[id] = nil }
            do {
                try Task.checkCancellation()
                let directory = try self.store.jobDirectory(id)
                let request: [String: Any] = ["version": 1, "account_id": state.accountID,
                    "job_id": id.uuidString, "parent_id": state.parentID, "root_name": state.rootName,
                    "ram_root": state.payload?.path ?? directory.appendingPathComponent("RAM/payload").path,
                    "checkpoint_dir": directory.appendingPathComponent("CloudReceipts").path,
                    "cleanup_padding": true, "reconcile_only": true,
                    "parent_pid": ProcessInfo.processInfo.processIdentifier,
                    "files": files.map { ["index": $0.index, "path": $0.path, "size": $0.length] as [String: Any] }]
                // Separate request/control files keep a held uploader's request
                // intact. The Rust helper shares its durable receipt lock.
                try await uploader.run(request: request, directory: directory.appendingPathComponent("PaddingCleanup"), context: context) { [weak self] event in
                    guard let self, !self.closed, self.job(id)?.relay?.accountID == state.accountID,
                          event["event"] as? String == "padding_cleaned" else { return }
                    let checked = Set(event["checked"] as? [Int] ?? []).intersection(allowed)
                    let removed = Set(event["removed"] as? [Int] ?? []).intersection(checked)
                    self.edit(id) {
                        var progress = $0.relay?.paddingCleanup ?? .init()
                        progress.checked.formUnion(checked); progress.removed.formUnion(removed)
                        $0.relay?.paddingCleanup = progress
                    }
                }
                try Task.checkCancellation()
                guard allowed.isSubset(of: self.job(id)?.relay?.paddingCleanup?.checked ?? []) else {
                    throw LocalTorrentError.message("Padding cleanup was interrupted; confirmed removals are saved and the remaining files will be checked again.")
                }
                self.edit(id) { $0.relay?.paddingCleanup?.failure = nil; $0.relay?.paddingCleanup?.retryAt = nil; $0.relay?.paddingCleanup?.attempt = 0 }
                self.saveOrReport(); self.relayFilesChanged?()
            } catch {
                if !self.closed, !Task.isCancelled {
                    self.deferPaddingCleanup(id, error: error)
                    self.relayFilesChanged?()
                } else if !self.closed { self.saveOrReport() }
            }
        }
    }

    private func deferPaddingCleanup(_ id: UUID, error: Error) {
        edit(id) {
            var progress = $0.relay?.paddingCleanup ?? .init()
            progress.failure = PikPakManagementError.safeMessage(error.localizedDescription)
            progress.retryAt = Date().addingTimeInterval(AutomaticRecovery.delay(attempt: progress.attempt, schedule: recoveryDelays))
            progress.attempt = AutomaticRecovery.nextAttempt(progress.attempt)
            $0.relay?.paddingCleanup = progress
        }
        saveOrReport()
    }
}

import Darwin
import CryptoKit
import Foundation

@main struct NativeAuditRegressionTests {
    @MainActor static func main() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("NativeAuditRegression-\(UUID())")
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: root) }
        try await aliasedCopy(root)
        try await cancellation(root)
        try await archiveCancellation(root)
        try await partialUndo(root)
        try await staleFiles(root)
        try await pausedConnections(root)
        try sessionLeases(root)
        try boundedReports(root)
        try cacheBudget(root)
        try unicodePartialLease(root)
        var login = PikPakLoginAttemptState()
        login.begin(active: true)
        let dismissed = login.id
        precondition(login.accepts(dismissed))
        login.begin(active: false)
        precondition(!login.accepts(dismissed))
        login.begin(active: true)
        let reloaded = login.id
        login.begin(active: true)
        precondition(!login.accepts(reloaded) && login.accepts(login.id))
        print("PASS dismissed and reloaded login attempts reject queued broker/token callbacks")
        let now = Date(), elapsed = SimilarityRecoveryCountdown.interval(until: now.addingTimeInterval(-10), now: now)
        precondition(elapsed.lowerBound == now && elapsed.upperBound == now)
        print("PASS expired recovery countdown produces a valid zero-duration range")
        let uncertain = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut,
            userInfo: [NSLocalizedDescriptionKey: "Cloud operation outcome is unknown: connection timed out"])
        precondition(!TransferFailure.isRetryable(uncertain))
        let wrapped = NSError(domain: "Synthetic", code: 1, userInfo: [NSUnderlyingErrorKey: uncertain])
        precondition(!TransferFailure.isRetryable(wrapped))
        var nested: NSError = uncertain
        for _ in 0..<8 { nested = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut, userInfo: [NSUnderlyingErrorKey: nested]) }
        precondition(!TransferFailure.isRetryable(nested) && !SimilarityNetworkFailure.isTemporary(nested))
        print("PASS accepted-or-lost cloud mutations do not automatically retry through nested network errors")
    }
    static func aliasedCopy(_ root: URL) async throws {
        let real = root.appendingPathComponent("Real"), alias = root.appendingPathComponent("Alias")
        let source = real.appendingPathComponent("Source"), nested = source.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let started = Date()
        do {
            try await CloudDriveFiles.detached {
                try ICloudDriveProvider.copy(alias.appendingPathComponent("Source"), to: nested.appendingPathComponent("Source"), progress: { _ in })
            }
            preconditionFailure("An aliased self-copy must be rejected")
        } catch { precondition(!(error is CancellationError) && Date().timeIntervalSince(started) < 2) }
        precondition(!FileManager.default.fileExists(atPath: nested.appendingPathComponent("Source").path))
        print("PASS aliased self-copy rejects promptly and creates no destination")
    }
    static func cancellation(_ root: URL) async throws {
        let folder = root.appendingPathComponent("Cancellation")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        for name in ["one", "two"] { try Data(repeating: 71, count: 4 << 20).write(to: folder.appendingPathComponent(name)) }
        let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let scan = Task.detached { try await NativeDriveDuplicates.scan([folder]) { value in
            if value["operation"] as? String == "hashing" { entered.signal(); resume.wait() }
        } }
        let signalled = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now() + 5) == .success) }
        }
        precondition(signalled)
        scan.cancel(); resume.signal()
        do { _ = try await scan.value; preconditionFailure("Canceled hash traversal must stop") }
        catch { precondition(error is CancellationError) }
        print("PASS native duplicate hashing observes cancellation on its coordinated dispatch worker")
    }
    static func archiveCancellation(_ root: URL) async throws {
        let source = root.appendingPathComponent("ArchiveSource"), archive = root.appendingPathComponent("fixture.tar")
        let destination = root.appendingPathComponent("ArchiveResult")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        try Data(repeating: 31, count: 4 << 20).write(to: source.appendingPathComponent("generated.bin"))
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-cf", archive.path, "-C", source.path, "generated.bin"]
        try tar.run(); tar.waitUntilExit(); precondition(tar.terminationStatus == 0)
        let entered = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        let extraction = Task.detached { try await NativeDriveArchive.extract(archive, to: destination, password: nil) { _ in
            entered.signal(); resume.wait()
        } }
        let signalled = await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: entered.wait(timeout: .now() + 5) == .success) }
        }
        precondition(signalled)
        extraction.cancel(); resume.signal()
        do { try await extraction.value; preconditionFailure("Canceled extraction must stop") }
        catch { precondition(error is CancellationError) }
        precondition(!FileManager.default.fileExists(atPath: destination.path))
        print("PASS native archive callback observes coordinated-worker cancellation and removes incomplete extraction")
    }
    static func partialUndo(_ root: URL) async throws {
        let originals = root.appendingPathComponent("Originals"), trash = root.appendingPathComponent("SyntheticTrash")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        let pairs = ["first", "second"].map { (trash.appendingPathComponent($0), originals.appendingPathComponent($0)) }
        for pair in pairs { try Data("fixture".utf8).write(to: pair.0) }
        try Data("conflict".utf8).write(to: pairs[1].1)
        let undo = ICloudDriveProvider.restoreTrashUndo(pairs, title: "Synthetic restore")
        do { _ = try await undo.apply(); preconditionFailure("Conflict must reject the complete restore") } catch {}
        precondition(pairs.allSatisfy { FileManager.default.fileExists(atPath: $0.0.path) })
        precondition(!FileManager.default.fileExists(atPath: pairs[0].1.path))
        try FileManager.default.removeItem(at: pairs[1].1)
        _ = try await undo.apply()
        precondition(pairs.allSatisfy { FileManager.default.fileExists(atPath: $0.1.path) })
        print("PASS native restore preflights a batch; removing a conflict makes the retained Undo succeed without OS Trash")
    }
    static func staleFiles(_ root: URL) async throws {
        let folder = root.appendingPathComponent("Changed")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let file = folder.appendingPathComponent("same-size.txt")
        try Data("before".utf8).write(to: file)
        let provider = ICloudDriveProvider(rootURL: folder, kind: .local)
        let original = try ICloudDriveProvider.item(file)
        try Data("edited".utf8).write(to: file)
        let changed = try ICloudDriveProvider.item(file)
        precondition(original.bytes == changed.bytes && original.revision != changed.revision)
        do { _ = try await provider.deleteVerified([original], progress: { _ in }); preconditionFailure("Changed original must stay intact") } catch {}
        let edited = try Data(contentsOf: file)
        precondition(edited == Data("edited".utf8))
        let empty = folder.appendingPathComponent("was-empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        let candidate = try ICloudDriveProvider.item(empty)
        try Data("new content".utf8).write(to: empty.appendingPathComponent("arrived.txt"))
        do { _ = try await provider.cleanup([candidate], empty: true, progress: { _ in }); preconditionFailure("New content must not be trashed") } catch {}
        precondition(FileManager.default.fileExists(atPath: empty.appendingPathComponent("arrived.txt").path))
        print("PASS same-size native edits change revision, refuse verified deletion, and nonempty cleanup candidates stay intact")
    }
    static func sessionLeases(_ root: URL) throws {
        let store = try PikPakAccountStore(directory: root.appendingPathComponent("Accounts"))
        let profile = PikPakAccountProfile(sub: "generated-account", name: "Generated")
        let original = try store.stage(token: "synthetic-old", deviceID: String(repeating: "a", count: 32))
        _ = try store.commit(original, profile: profile)
        let other = try PikPakAccountStore(directory: store.directory)
        try store.retainWorkerSession(original); try other.retainWorkerSession(original)
        let replacement = try store.stage(token: "synthetic-new", deviceID: String(repeating: "b", count: 32))
        _ = try store.commit(replacement, profile: profile)
        let captured = try original.load().token
        precondition(captured == "synthetic-old")
        store.releaseWorkerSessions()
        let stillCaptured = try original.load().token
        precondition(stillCaptured == "synthetic-old", "Another workspace's lease must still protect credentials")
        other.releaseWorkerSessions()
        precondition(!FileManager.default.fileExists(atPath: original.directory.path))
        let current = try replacement.load().token
        precondition(current == "synthetic-new")
        print("PASS independent session leases retain captured credentials across reauthentication and clean up only after the final release")
    }
    @MainActor static func pausedConnections(_ root: URL) async throws {
        let first = root.appendingPathComponent("PausedFirst"), second = root.appendingPathComponent("PausedSecond")
        try FileManager.default.createDirectory(at: first, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: false)
        let model = NativeDriveModel(kind: .local)
        defer { model.close() }
        model.connect(ICloudDriveProvider(rootURL: first, kind: .local))
        while model.isLoading { try await Task.sleep(nanoseconds: 10_000_000) }
        model.findSimilar([], presentWindow: false)
        let scope = model.similarity.local.nativeScope
        model.similarity.local.setFixtureProgress(["stage":"analysing"], paused: true)
        precondition(model.isBusy && model.similarity.local.retainsOriginalsInRAM)
        model.connect(ICloudDriveProvider(rootURL: second, kind: .local)); model.disconnect(); model.useSimilarityFolder(second)
        precondition(model.provider?.root.url == first.standardizedFileURL.resolvingSymlinksInPath())
        precondition(model.similarity.local.nativeScope?.providerRoot == scope?.providerRoot)
        model.similarity.local.clearSession()
        print("PASS paused native helper prevents reconnect, disconnect and scan-scope replacement")
    }
    @MainActor static func boundedReports(_ root: URL) throws {
        let url = root.appendingPathComponent("oversized-report")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 257 << 20); try handle.close()
        precondition(SimilaritySessionStore.readBoundedFile(url, maximumBytes: 256 << 20) == nil)
        let alias = root.appendingPathComponent("report-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
        precondition(SimilaritySessionStore.readBoundedFile(alias, maximumBytes: 512 << 20) == nil)
        try Data("small".utf8).write(to: url)
        precondition(SimilaritySessionStore.readBoundedFile(url, maximumBytes: 5) == Data("small".utf8))
        print("PASS saved report reads reject oversized sparse files and symlinks before allocating content")
    }
    static func cacheBudget(_ root: URL) throws {
        let cache = try PreviewResourceCache(maximumBytes: 8, minimumFreeDiskBytes: 0, directory: root.appendingPathComponent("Preview"))
        precondition(cache.store(Data("12345678".utf8), at: 0) != nil && !cache.permitsBackgroundPrefetch)
        precondition(cache.store(Data("x".utf8), at: 8, allowsEviction: false) == nil)
        precondition(cache.store(Data("next".utf8), at: 8) != nil)
        precondition(cache.snapshot.cachedBytes == 4 && cache.read(at: 0, maximumLength: 1) == nil)
        precondition(cache.read(at: 8, maximumLength: 4) == Data("next".utf8))
        print("PASS preview cache stops prefetch at its disk budget and evicts old ranges for interactive playback")
    }
    static func unicodePartialLease(_ root: URL) throws {
        let folder = root.appendingPathComponent("UnicodeLease"), locks = root.appendingPathComponent("UnicodeLocks")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: false)
        let composed = folder.appendingPathComponent("caf\u{e9}.bin"), decomposed = folder.appendingPathComponent("cafe\u{301}.bin")
        let partial = composed.appendingPathExtension("part")
        try Data("owned partial".utf8).write(to: partial)
        let canonical = composed.path.decomposedStringWithCanonicalMapping.lowercased().decomposedStringWithCanonicalMapping
        let key = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        let descriptor = Darwin.open(locks.appendingPathComponent(key).path, O_CREAT | O_RDWR, 0o600)
        precondition(descriptor >= 0 && flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        defer { Darwin.close(descriptor) }
        do {
            try TransferPartialCleanup.remove(decomposed.appendingPathExtension("part"), owner: "generated", fileID: "generated", locksDirectory: locks)
            preconditionFailure("Canonical-equivalent destination must respect the active writer lease")
        } catch let error as NSError { precondition(error.domain == "MyCloudDriver.Transfer" && error.code == 1) }
        precondition(FileManager.default.fileExists(atPath: partial.path))
        print("PASS canonical-equivalent Unicode partial paths use the same active-writer lease")
    }
}

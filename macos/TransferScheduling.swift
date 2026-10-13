import AppKit
import CryptoKit
import Darwin
import Foundation
import Photos
import UniformTypeIdentifiers

/// Download admission is determined by measured throughput and OS resources.
/// Uploads retain their own ceiling; saved preferences do not constrain either.
enum TransferConcurrency {
    static let automaticLimit = 64
    static let downloadAutomaticLimit = Int.max
}

/// Average speed over the trailing five seconds, from samples of a cumulative byte counter.
/// A burst therefore lingers for the whole window and a stall fades to zero as the window
/// empties, instead of jumping. Samples closer than `minimumSpacing` change nothing, so the
/// published speed refreshes about once a second however often it is asked.
struct RollingRate {
    static let window: TimeInterval = 5
    /// Just under the one-second timer tick, so ordinary timer jitter cannot skip a refresh.
    static let minimumSpacing: TimeInterval = 0.9
    private var samples: [(date: Date, bytes: UInt64)] = []
    private(set) var bytesPerSecond: Double = 0

    /// Begin measuring from `bytes` at `now`, reporting no speed until the next sample.
    mutating func restart(bytes: UInt64, at now: Date) {
        samples = [(now, bytes)]
        bytesPerSecond = 0
    }

    /// Record the counter and return the average over the last `window` seconds, or over the
    /// history so far when there is less. A counter that moves backwards starts over. Returns nil,
    /// recording nothing, when called again before `minimumSpacing` has passed.
    @discardableResult
    mutating func sample(bytes: UInt64, at now: Date) -> Double? {
        guard let last = samples.last, now >= last.date, bytes >= last.bytes else {
            restart(bytes: bytes, at: now)
            return 0
        }
        guard now.timeIntervalSince(last.date) >= Self.minimumSpacing else { return nil }
        samples.append((now, bytes))
        let start = now.addingTimeInterval(-Self.window)
        // Keep the newest sample at or before the window start; it anchors the interpolation below.
        while samples.count > 2, samples[1].date <= start { samples.removeFirst() }
        var baseDate = samples[0].date
        // Subtract integer counters before converting to Double, so a small
        // delta remains accurate even after a very large cumulative baseline.
        var receivedBytes = Double(bytes - samples[0].bytes)
        if baseDate < start {
            let next = samples[1]
            let fraction = start.timeIntervalSince(baseDate) / next.date.timeIntervalSince(baseDate)
            baseDate = start
            receivedBytes -= Double(next.bytes - samples[0].bytes) * fraction
        }
        // Date arithmetic is only good to about 100 ns, so a base within a millisecond of the window edge
        // counts as exactly one window; an unchanged transfer then reports an identical speed every time.
        var elapsed = now.timeIntervalSince(baseDate)
        if elapsed > Self.window - 0.001 { elapsed = Self.window }
        bytesPerSecond = elapsed > 0 ? max(receivedBytes, 0) / elapsed : 0
        return bytesPerSecond
    }
}

/// Sample one transfer's network counter, excluding any resumed local prefix.
/// Each file has its own baseline and five-second average.
struct DownloadFileRate {
    private var rate = RollingRate()
    private var wasTransferring = false
    var bytesPerSecond: Double { rate.bytesPerSecond }

    mutating func sample(networkBytes: UInt64, at now: Date, transferring: Bool) -> Double {
        let continues = transferring && wasTransferring
        wasTransferring = transferring
        guard continues else {
            rate.restart(bytes: networkBytes, at: now)
            return 0
        }
        return rate.sample(bytes: networkBytes, at: now) ?? rate.bytesPerSecond
    }
}

/// Preserve each selection's local layout in the continuous download queue.
enum DownloadDestinationLayout {
    /// Detect overlapping trees when consolidating legacy selection fixtures.
    /// The live engine serializes actual writes with destination leases.
    static func destinationsOverlap(_ first: [[String]], _ second: [[String]]) -> Bool {
        func key(_ components: [String]) -> [String] {
            components.map { ($0 as NSString).lastPathComponent.precomposedStringWithCanonicalMapping.lowercased() }
        }
        let first = first.map(key), second = second.map(key)
        return first.contains { a in second.contains { b in a.starts(with: b) || b.starts(with: a) } }
    }

    /// Compute destinations before merging clicks, so combining selections
    /// from different source folders never changes their local folder layout.
    static func relativeParents(for paths: [String]) -> [[String]] {
        let parents = paths.map { Array($0.split(separator: "/").map(String.init).dropLast()) }
        guard let first = parents.first else { return [] }
        let commonDepth = first.indices.prefix { index in
            parents.allSatisfy { $0.indices.contains(index) && $0[index] == first[index] }
        }.count
        return parents.map { Array($0.dropFirst(commonDepth)) }
    }


}

enum UploadAvailability {
    /// Downloads and read-only scans are deliberately not inputs. They own
    /// different processes and share the app's locked token-rotation store.
    static func allowsStart(hasSession: Bool, uploadActive: Bool,
                            conflictingMutation: Bool, foregroundAllows: Bool) -> Bool {
        hasSession && !uploadActive && !conflictingMutation && foregroundAllows
    }
}

/// Finder may supply NSURL, URL, serialized file-URL data or an NSString.
/// Preserve provider order, wait for every provider, and complete on main so
/// the captured cloud destination and transfer-tab callback remain consistent.
enum LocalUploadFileURLLoader {
    static func load(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) {
        loadResult(providers) { completion((try? $0.get()) ?? []) }
    }

    static func loadResult(_ providers: [NSItemProvider], completion: @escaping (Result<[URL], Error>) -> Void) {
        guard !providers.isEmpty else {
            DispatchQueue.main.async { completion(.failure(FinderDropError("The drop contains no local files or folders."))) }
            return
        }
        let batch = FinderURLBatch(count: providers.count, completion: completion)
        for (index, provider) in providers.enumerated() {
            // Start both supported representations while performDrop still
            // grants access. Some data providers advertise NSURL reading but
            // cannot coerce their result; others need the typed URL reader.
            // Starting a fallback only after an async error can be too late.
            let canReadURL = provider.canLoadObject(ofClass: NSURL.self)
            let read = FinderURLProviderRead(count: canReadURL ? 2 : 1) { url, error in
                batch.receive(index: index, url: url, error: error)
            }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                read.receive(url: localFileURL(from: item), error: error)
            }
            if canReadURL {
                provider.loadObject(ofClass: NSURL.self) { object, error in
                    read.receive(url: object as? URL, error: error)
                }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 20) { batch.timeOut() }
    }

    /// All-or-nothing validation prevents a "successful" drop silently losing
    /// some of the selected files. Folder selection already includes children,
    /// so a child selected alongside its parent must not upload twice.
    static func validatedRoots(_ items: [URL]) throws -> [URL] {
        var roots: [(url: URL, isDirectory: Bool)] = []
        var seen = Set<String>()
        for item in items {
            guard item.isFileURL, item.host == nil || item.host == "" || item.host == "localhost" else {
                throw FinderDropError("The drop contains a non-local URL. Drag files or folders from Finder instead.")
            }
            let url = item.standardizedFileURL
            guard seen.insert(url.path).inserted else { continue }
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &directory),
                  FileManager.default.isReadableFile(atPath: url.path) else {
                throw FinderDropError("Cannot read \(url.lastPathComponent). No files from this drop were uploaded. Check Finder permissions and try again.")
            }
            roots.append((url, directory.boolValue))
        }
        guard !roots.isEmpty else { throw FinderDropError("The drop contains no readable local files or folders.") }
        return roots.filter { entry in
            !roots.contains { parent in
                parent.isDirectory && parent.url != entry.url
                    && entry.url.pathComponents.starts(with: parent.url.pathComponents)
            }
        }.map(\.url)
    }

    static func localFileURL(from item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let url = item as? NSURL { return url as URL }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        if let value = item as? String { return URL(string: value) }
        return nil
    }
}

private struct FinderDropError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Either URL representation may win, but one provider must complete exactly
/// once. A failed representation cannot discard another still-valid read.
private final class FinderURLProviderRead: @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: Int
    private var failure: Error?
    private var finished = false
    private let completion: (URL?, Error?) -> Void

    init(count: Int, completion: @escaping (URL?, Error?) -> Void) {
        remaining = count
        self.completion = completion
    }

    func receive(url: URL?, error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        remaining -= 1
        if error == nil, let url, url.isFileURL {
            finished = true
            lock.unlock()
            completion(url, nil)
        } else {
            if let error { failure = error }
            guard remaining == 0 else { lock.unlock(); return }
            finished = true
            let error = failure
            lock.unlock()
            completion(nil, error)
        }
    }
}

private final class FinderURLBatch: @unchecked Sendable {
    private let lock = NSLock()
    private let count: Int
    private let completion: (Result<[URL], Error>) -> Void
    private var received = Set<Int>()
    private var urls: [Int: URL] = [:]
    private var failure: Error?
    private var finished = false

    init(count: Int, completion: @escaping (Result<[URL], Error>) -> Void) {
        self.count = count
        self.completion = completion
    }

    func receive(index: Int, url: URL?, error: Error?) {
        lock.lock()
        guard !finished, received.insert(index).inserted else { lock.unlock(); return }
        if error == nil, let url, url.isFileURL {
            urls[index] = url
        } else {
            failure = error ?? FinderDropError("Finder could not supply every selected file. Nothing from this drop was uploaded; try dragging the selection again.")
        }
        guard received.count == count else { lock.unlock(); return }
        finished = true
        let result: Result<[URL], Error> = failure.map { .failure($0) }
            ?? .success((0..<count).compactMap { urls[$0] })
        lock.unlock()
        DispatchQueue.main.async { self.completion(result) }
    }

    func timeOut() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        lock.unlock()
        DispatchQueue.main.async {
            self.completion(.failure(FinderDropError("Finder took too long to supply the selected files. Nothing from this drop was uploaded; try again.")))
        }
    }
}

/// Deletes only regular partial data and its resume journals. The caller must first stop its writer;
/// originals, directories, aliases and symbolic links are never eligible.
enum TransferPartialCleanup {
    static func remove(_ url: URL, owner: String, fileID: String, locksDirectory: URL? = nil, importedOwners: Set<String> = [], checkCancellation: () throws -> Void = {}) throws {
        try checkCancellation()
        guard url.lastPathComponent.hasSuffix(".part") else { throw CocoaError(.fileWriteNoPermission) }
        let locks = try locksDirectory ?? LocalCredentialStore.applicationSupportDirectoryURL().appendingPathComponent("TransferLocks", isDirectory: true)
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let outputName = String(url.lastPathComponent.dropLast(5))
        let output = url.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(outputName).path
            .decomposedStringWithCanonicalMapping.lowercased().decomposedStringWithCanonicalMapping
        let key = SHA256.hash(data: Data(output.utf8)).map { String(format: "%02x", $0) }.joined()
        let descriptor = Darwin.open(locks.appendingPathComponent(key).path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { Darwin.close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw NSError(domain: "MyCloudDriver.Transfer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Another window is writing this destination. Its partial file was kept."])
        }
        defer { flock(descriptor, LOCK_UN) }
        guard let data = try? Data(contentsOf: locks.appendingPathComponent(key)),
              let claim = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let previousOwner = claim["owner"], previousOwner == owner || importedOwners.contains(previousOwner),
              claim["file_id"] == fileID else { return }
        // An interrupted ExFAT finalization owns a second, partially copied
        // file. Keep its original and journal for the helper to reconcile;
        // removing only the original would strand that safe-copy recovery.
        if FileManager.default.fileExists(atPath: url.path + ".publication.json") {
            throw NSError(domain: "MyCloudDriver.Transfer", code: 2, userInfo:
                [NSLocalizedDescriptionKey: "Download finalization cleanup is waiting for its saved publication journal."])
        }
        for sibling in [url, URL(fileURLWithPath: url.path + ".resume.json", isDirectory: false),
                        URL(fileURLWithPath: url.path + ".ranges.data", isDirectory: false), URL(fileURLWithPath: url.path + ".ranges.json", isDirectory: false)] {
            try checkCancellation()
            guard FileManager.default.fileExists(atPath: sibling.path) else { continue }
            let values = try sibling.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileWriteNoPermission) }
            try checkCancellation()
            try FileManager.default.removeItem(at: sibling)
        }
    }

    /// An interrupted folder can have owned partials before its resumed cloud
    /// discovery reaches those children. The private ownership manifest supplies
    /// exact output paths; every deletion still reacquires that output's lock.
    static func removeOwned(in tree: URL, owner: String, ignoringActiveWriters: Bool = false, locksDirectory: URL? = nil, importedOwners: Set<String> = [], checkCancellation: () throws -> Void = {}) throws {
        try checkCancellation()
        let locks = try locksDirectory ?? LocalCredentialStore.applicationSupportDirectoryURL().appendingPathComponent("TransferLocks", isDirectory: true)
        guard FileManager.default.fileExists(atPath: locks.path) else { return }
        let root = tree.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        for manifest in try FileManager.default.contentsOfDirectory(at: locks, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) {
            try checkCancellation()
            let attributes = try manifest.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard attributes.isRegularFile == true, attributes.isSymbolicLink != true, (attributes.fileSize ?? 0) < 64 * 1024,
                  let data = try? Data(contentsOf: manifest),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let previousOwner = record["owner"], previousOwner == owner || importedOwners.contains(previousOwner),
                  let fileID = record["file_id"], let path = record["output_path"] else { continue }
            // A directory hint avoids probing every historical output on SMB
            // before finding out whether it belongs to the cancelled folder.
            let output = URL(fileURLWithPath: path, isDirectory: false).standardizedFileURL
            guard output.pathComponents.starts(with: root), output.pathComponents.count > root.count else { continue }
            let partial = output.appendingPathExtension("part")
            do { try remove(partial, owner: owner, fileID: fileID, locksDirectory: locks, importedOwners: importedOwners, checkCancellation: checkCancellation) }
            catch let error as NSError where ignoringActiveWriters && error.domain == "MyCloudDriver.Transfer" && error.code == 1 {
                // The helper sees the same cancellation and cleans its active
                // writer after flushing. Never unlink while it holds the lock.
            }
        }
    }
}

enum TransferFailure {
    static func isRetryable(_ error: Error, depth: Int = 0) -> Bool {
        guard !hasUncertainMutation(error) else { return false }
        // Callers check their own cancellation first. A provider cancelling a
        // request without a user cancellation is an interruption to recover.
        if error is CancellationError { return true }
        if case .waiting = error as? CloudDriveError { return true }
        if (error as? PikPakAccountError) == .unavailable { return true }
        if case .api(let status, _, _) = error as? PikPakManagementError,
           [408, 425, 429].contains(status) || (500...599).contains(status) { return true }
        if SimilarityNetworkFailure.isTemporary(error) { return true }
        let value = error as NSError
        if value.domain == PHPhotosErrorDomain, [PHPhotosError.Code.libraryVolumeOffline.rawValue,
            PHPhotosError.Code.relinquishingLibraryBundleToWriter.rawValue, PHPhotosError.Code.networkError.rawValue,
            PHPhotosError.Code.operationInterrupted.rawValue, PHPhotosError.Code.notEnoughSpace.rawValue].contains(value.code) { return true }
        if value.domain == "ImagePreview.HTTP", [408, 425, 429].contains(value.code) || (500...599).contains(value.code) { return true }
        if value.domain == "PikPakOpen", value.code == 3 { return true }
        if value.domain == NSURLErrorDomain && value.code == NSURLErrorCancelled { return true }
        if value.domain == NSCocoaErrorDomain && [NSFileWriteOutOfSpaceError, NSFileReadNoSuchFileError,
            NSFileNoSuchFileError, NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(value.code) { return true }
        if value.domain == NSPOSIXErrorDomain && [EAGAIN, EINTR, EMFILE, ENFILE, ENETDOWN, ENETUNREACH,
            ECONNABORTED, ECONNRESET, ENOTCONN, ETIMEDOUT, ECONNREFUSED, EHOSTDOWN, EHOSTUNREACH,
            ENOSPC, EDQUOT, ENODEV, ENXIO, EBUSY, EIO, ENOENT, EACCES, EPERM].contains(Int32(value.code)) { return true }
        if depth < 3, let underlying = value.userInfo[NSUnderlyingErrorKey] as? Error { return isRetryable(underlying, depth: depth + 1) }
        return false
    }
    static func hasUncertainMutation(_ error: Error) -> Bool {
        var pending = [error as NSError], visited = Set<ObjectIdentifier>()
        while let value = pending.popLast() {
            guard visited.insert(ObjectIdentifier(value)).inserted else { continue }
            if value.localizedDescription.localizedCaseInsensitiveContains("Cloud operation outcome is unknown") { return true }
            if let underlying = value.userInfo[NSUnderlyingErrorKey] as? NSError { pending.append(underlying) }
            if let underlying = value.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] { pending.append(contentsOf: underlying) }
        }
        return false
    }
}

/// Shared with detached filesystem workers. Waiting here never blocks AppKit;
/// cancellation wakes paused workers so they close their file before cleanup.
final class NativeTransferControl: @unchecked Sendable {
    @TaskLocal static var current: NativeTransferControl?
    private let condition = NSCondition()
    private var paused = false
    private var cancelled = false
    private var completedItems = Set<String>()
    func isCompleted(_ id: String) -> Bool { condition.lock(); defer { condition.unlock() }; return completedItems.contains(id) }
    func markCompleted(_ id: String) { condition.lock(); completedItems.insert(id); condition.unlock() }
    func pause() { condition.lock(); paused = true; condition.unlock() }
    func resume() { condition.lock(); paused = false; condition.broadcast(); condition.unlock() }
    func cancel() { condition.lock(); cancelled = true; condition.broadcast(); condition.unlock() }
    func check() throws {
        condition.lock()
        while paused && !cancelled && !Task.isCancelled { _ = condition.wait(until: Date(timeIntervalSinceNow: 0.1)) }
        let cancelled = cancelled
        condition.unlock()
        if cancelled { throw CancellationError() }
        try Task.checkCancellation()
    }
    var isPaused: Bool { snapshot().paused }
    var isCancelled: Bool { snapshot().cancelled }
    func wait(ignoringPause: Bool = false) async throws {
        while true {
            let state = snapshot()
            if state.cancelled { throw CancellationError() }
            try Task.checkCancellation()
            if ignoringPause || !state.paused { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }
    private func snapshot() -> (paused: Bool, cancelled: Bool) {
        condition.lock(); defer { condition.unlock() }; return (paused, cancelled)
    }
}


actor NativeTransferAdmission {
    static let shared = NativeTransferAdmission()
    private var active = Set<UUID>()
    private var waiting: [UUID] = []
    private let limit: Int
    init(limit: Int = min(8, max(2, ProcessInfo.processInfo.activeProcessorCount / 2))) { self.limit = max(1, limit) }
    var activeCount: Int { active.count }
    func acquire(control: NativeTransferControl, ignoringPause: Bool = false) async throws -> UUID {
        let permit = UUID()
        var admitted = false
        defer {
            waiting.removeAll { $0 == permit }
            if !admitted { active.remove(permit) }
        }
        while true {
            if !ignoringPause, control.isPaused { waiting.removeAll { $0 == permit } }
            try await control.wait(ignoringPause: ignoringPause)
            if !waiting.contains(permit) { waiting.append(permit) }
            if waiting.first == permit, active.count < limit {
                active.insert(permit); admitted = true
                return permit
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }
    // Identity makes late or duplicate releases harmless during rapid
    // pause/resume/cancel; an old release cannot free a new transfer's slot.
    func release(_ permit: UUID) { active.remove(permit) }
}

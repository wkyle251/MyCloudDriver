import AVFoundation
import Darwin
import Foundation
import UniformTypeIdentifiers

/// Read throughput counts bytes received from the volume, including rereads after RAM eviction. The cache's
/// resident size can stay constant while reading, so its growth is not a measure of speed.
struct FilePreviewReadActivity {
    static let averagingInterval: TimeInterval = 5
    private struct Sample { let time: TimeInterval; var bytes: Int64 }
    private var samples: [Sample] = []
    private var beganAt: TimeInterval = 0
    private(set) var bytesRead: Int64 = 0
    private(set) var isReading = false

    mutating func begin(at time: TimeInterval) {
        guard !isReading else { return }
        isReading = true; beganAt = time; samples = []
    }
    mutating func record(bytes: Int, at time: TimeInterval) {
        guard isReading, bytes > 0 else { return }
        bytesRead += Int64(bytes)
        samples.removeAll { $0.time <= time - Self.averagingInterval }
        if let last = samples.last, time - last.time < 0.1 {
            samples[samples.count - 1].bytes += Int64(bytes)
        } else { samples.append(Sample(time: time, bytes: Int64(bytes))) }
    }
    func bytesPerSecond(at time: TimeInterval) -> Double {
        guard isReading else { return 0 }
        let recent = samples.filter { $0.time > time - Self.averagingInterval }
        return Double(recent.reduce(Int64(0)) { $0 + $1.bytes }) / min(Self.averagingInterval, max(0.001, time - beganAt))
    }
    mutating func end() { isReading = false; samples = [] }
}

struct FilePreviewBufferStatus: Equatable {
    let cache: PreviewResourceCacheSnapshot
    let budgetBytes: Int64
    let bytesRead: Int64
    let bytesPerSecond: Double
    let isReading: Bool
    let failed: Bool
    var memoryPressure = false

    var title: String {
        if failed { return "Read failed" }
        if cache.fraction == 1 { return "Fully buffered" }
        if memoryPressure { return "Waiting for memory" }
        return isReading ? "Buffering" : "Buffer ready"
    }
}

/// A stalled volume is different from an unsupported media codec. The UI
/// offers Retry Preview rather than retrying the same bytes through a decoder.
struct FilePreviewReadTimeout: LocalizedError, Sendable {
    var errorDescription: String? {
        "The disk or network share stopped supplying preview data. Check its connection, then retry the preview."
    }
}

/// Plays local, external, network and materialized cloud media from shared RAM. AVPlayer is given a custom-scheme
/// asset; this delegate answers its byte-range requests from a `MemoryRangeBuffer`
/// that a background reader fills from the volume: first what the player is waiting
/// for, then what lies ahead of it. The file is opened read-only and never copied
/// to storage, and a volume whose reads fail fails the request instead of hanging it.
final class FilePreviewResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "mycloud-media"
    static let maximumConcurrentReads = 4
    /// A cancelled SMB read may stay inside the kernel. Share this limit
    /// across previews, and yield after each block so another loader gets a turn.
    private static let readWorkers: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "MyCloudDriver.file-preview-reads"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = maximumConcurrentReads
        return queue
    }()
    /// AVFoundation calls the delegate here; the same serial queue is passed to `setDelegate`.
    let delegateQueue = DispatchQueue(label: "com.wky.PikPakDownloader.file-preview-loader.\(UUID().uuidString)", qos: .userInitiated)
    let assetURL: URL

    private let fileURL: URL
    private let buffer: MemoryRangeBuffer
    private let publisher: PreviewCacheProgressPublisher
    private let contentType: String
    /// Injectable system calls let generated tests hold a read or close without
    /// touching a user's disk or depending on a disconnected network share.
    struct IO: Sendable {
        var read: @Sendable (Int32, UnsafeMutableRawPointer, Int, off_t) -> Int = { pread($0, $1, $2, $3) }
        var close: @Sendable (Int32) -> Void = { _ = Darwin.close($0) }
    }
    private let io: IO
    /// Handed to AVFoundation in pieces this size, so its cancellations can run between pieces.
    private static let responseTurn = 4 << 20
    private static let responseChunk = 256 << 10

    private let lock = NSLock()
    private var descriptor: Int32
    private var demand: [Int] = []
    private var priority: [Int] = []
    private var readerRunning = false
    private var readerActive = false
    private var readerID: UUID?
    private var readOperation: Operation?
    private var readsAhead = false
    private var retryTimer: DispatchSourceTimer?
    private var retryNotBefore: TimeInterval = 0
    private let readAheadBlocks: Int
    private var invalidated = false
    private var readFailure: Error?
    /// Guarded by `lock`, alongside the reader state. Uses monotonic time so clock changes cannot spike the rate.
    private var readActivity = FilePreviewReadActivity()
    /// Touched only on `delegateQueue`.
    private var pending: [AVAssetResourceLoadingRequest] = []

    /// `contentType` names the container when the file's own name says otherwise: the player is then told what the
    /// bytes are, and the asset is named for it.
    /// `readAheadBytes` bounds how far beyond the playhead the reader goes once `setReadingAhead(true)` is called.
    /// Until then only the head and tail (`prime`) and what the player is waiting for are read, so selecting a video
    /// does not spin up a disk for hundreds of megabytes it may never play.
    init(fileURL: URL, contentType: UTType? = nil, budgetBytes: Int64 = .max, blockSize: Int = 1 << 20,
         readAheadBytes: Int64 = .max, memoryBudget: PreviewMemoryBudget = .shared,
         io: IO = .init(),
         onSnapshot: @escaping @MainActor (PreviewResourceCacheSnapshot) -> Void = { _ in }) throws {
        let descriptor = open(fileURL.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            io.close(descriptor); throw CloudDriveError.message("Choose a regular file to preview.")
        }
        guard info.st_size > 0 else { io.close(descriptor); throw CloudDriveError.message("This file is empty.") }
        self.descriptor = descriptor
        self.fileURL = fileURL
        self.io = io
        buffer = MemoryRangeBuffer(contentLength: Int64(info.st_size), budgetBytes: budgetBytes, blockSize: blockSize,
            memoryBudget: memoryBudget)
        readAheadBlocks = max(1, Int(max(0, readAheadBytes) / Int64(max(1, blockSize))))
        publisher = PreviewCacheProgressPublisher(onProgress: onSnapshot)
        self.contentType = (contentType ?? UTType(filenameExtension: fileURL.pathExtension))?.identifier ?? UTType.data.identifier
        var components = URLComponents()
        components.scheme = Self.scheme; components.host = "file"
        components.path = "/" + (contentType.map { "media." + ($0.preferredFilenameExtension ?? fileURL.pathExtension) } ?? fileURL.lastPathComponent)
        assetURL = components.url ?? URL(string: "\(Self.scheme)://file/media")!
        super.init()
        let timer = DispatchSource.makeTimerSource(queue: delegateQueue)
        retryTimer = timer
        timer.schedule(deadline: .now() + .milliseconds(250), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.scheduleReads() }
        timer.activate()
    }
    // Not `invalidate()`: its cancellation closure forms a weak reference, which is not allowed while deallocating.
    deinit { release() }

    /// Invalidated buffers may be unmapping on the cleanup queue. Never wait
    /// for that memory destruction from a UI status query.
    private var stoppedSnapshot: PreviewResourceCacheSnapshot {
        .init(cachedBytes: 0, contentLength: buffer.contentLength, ranges: [])
    }
    var snapshot: PreviewResourceCacheSnapshot {
        lock.lock(); defer { lock.unlock() }
        return invalidated ? stoppedSnapshot : buffer.snapshot
    }
    var status: FilePreviewBufferStatus {
        lock.lock(); defer { lock.unlock() }
        return FilePreviewBufferStatus(cache: invalidated ? stoppedSnapshot : buffer.snapshot,
            budgetBytes: min(Int64(buffer.maximumBlocks) * Int64(buffer.blockSize), buffer.memoryBudget.limitBytes), bytesRead: readActivity.bytesRead,
            bytesPerSecond: readActivity.bytesPerSecond(at: ProcessInfo.processInfo.systemUptime),
            isReading: readActivity.isReading, failed: readFailure != nil, memoryPressure: buffer.memoryBudget.isUnderPressure)
    }
    /// Why reads stopped, once the disk or file failed.
    var failure: Error? { lock.lock(); defer { lock.unlock() }; return readFailure }

    /// Reads the start of the file, and its end where many movies keep their header, before playback begins.
    func prime(headBlocks: Int = 16, tailBlocks: Int = 2, noProgressTimeout: TimeInterval = 30,
               invalidateOnCancel: Bool = true,
               progress: @escaping @Sendable (Double) -> Void) async throws {
        try await withTaskCancellationHandler {
            try await primeBlocks(headBlocks: headBlocks, tailBlocks: tailBlocks, noProgressTimeout: noProgressTimeout, progress: progress)
        } onCancel: { if invalidateOnCancel { self.invalidate() } }
    }

    private func primeBlocks(headBlocks: Int, tailBlocks: Int, noProgressTimeout: TimeInterval,
                             progress: @escaping @Sendable (Double) -> Void) async throws {
        let noProgressTimeout = noProgressTimeout.isFinite && noProgressTimeout > 0 ? noProgressTimeout : 30
        let count = buffer.blockCount
        // Leave room in the budget for the playhead and the block being read next.
        let tail = min(tailBlocks, count, buffer.maximumBlocks / 4)
        let head = max(1, min(headBlocks, count - tail, buffer.maximumBlocks - tail - 1))
        let wanted = Array(0 ..< head) + Array((count - tail) ..< count).filter { $0 >= head }
        setPriority(wanted)
        scheduleReads()
        defer { setPriority([]) }
        var lastProgress = ProcessInfo.processInfo.systemUptime
        var previousBytes: Int64 = 0, previousBlocks = 0, reportedBlocks = -1
        while true {
            try Task.checkCancellation()
            let state = primingState()
            if let failure = state.failure { throw failure }
            if state.invalidated { throw CancellationError() }
            let done = wanted.filter { buffer.contains($0) }.count
            if done != reportedBlocks {
                progress(Double(done) / Double(wanted.count)); reportedBlocks = done
            }
            if done == wanted.count { return }
            let now = ProcessInfo.processInfo.systemUptime
            // A slow but progressing partial pread must not time out merely
            // because it has not filled a whole cache block yet.
            if state.bytes > previousBytes || done > previousBlocks {
                lastProgress = now; previousBytes = state.bytes; previousBlocks = done
            } else if now - lastProgress >= noProgressTimeout {
                let error = FilePreviewReadTimeout()
                stop(with: error)
                throw error
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func primingState() -> (bytes: Int64, failure: Error?, invalidated: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (readActivity.bytesRead, readFailure, invalidated)
    }

    private func setPriority(_ blocks: [Int]) { lock.lock(); priority = blocks; lock.unlock() }

    /// Selection enables read-ahead independently of AVPlayer's paused state.
    /// A retired selection disables it during its two-second grace period.
    func setReadingAhead(_ enabled: Bool) {
        lock.lock()
        let changed = readsAhead != enabled
        readsAhead = enabled
        let active = !invalidated
        lock.unlock()
        if enabled, changed, active { scheduleReads() }
    }
    func setCachePriority(_ priority: Int, gracePeriod: TimeInterval = 0) {
        buffer.setPriority(priority, gracePeriod: gracePeriod)
    }
    private func release() {
        retryTimer?.cancel()
        publisher.invalidate()
        lock.lock()
        let first = !invalidated
        invalidated = true; demand = []; priority = []; readActivity.end()
        // A queued turn has not borrowed the descriptor yet. Detach it now,
        // rather than retaining an FD behind other volumes' blocked syscalls.
        let queued = readerActive ? nil : readOperation
        if !readerActive {
            readOperation = nil; readerID = nil; readerRunning = false
        }
        lock.unlock()
        queued?.cancel()
        if first {
            let buffer = buffer
            NativeFileWork.performMemoryCleanup { buffer.removeAll() }
        }
        closeDescriptorIfIdle()
    }

    /// Frees the RAM, stops reading and ends any request the player is waiting on.
    func invalidate() {
        stop(with: nil)
    }

    private func stop(with error: Error?) {
        if let error {
            lock.lock()
            if readFailure == nil { readFailure = error }
            lock.unlock()
        }
        release()
        delegateQueue.async { [weak self] in
            guard let self else { return }
            let failure = self.stoppedFailure()
            for request in self.pending where !request.isFinished { request.finishLoading(with: failure) }
            self.pending = []
        }
    }

    private func stoppedFailure() -> Error {
        failure ?? NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled,
            userInfo: [NSLocalizedDescriptionKey: "The media preview was cancelled."])
    }
    private var isInvalidated: Bool { lock.lock(); defer { lock.unlock() }; return invalidated }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard loadingRequest.request.url?.scheme == Self.scheme else { return false }
        guard !isInvalidated else { loadingRequest.finishLoading(with: stoppedFailure()); return true }
        if let information = loadingRequest.contentInformationRequest {
            information.contentType = contentType
            information.contentLength = buffer.contentLength
            information.isByteRangeAccessSupported = true
        }
        guard loadingRequest.dataRequest != nil else { loadingRequest.finishLoading(); return true }
        pending.append(loadingRequest)
        pump()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        pending.removeAll { $0 === loadingRequest }
        updateDemand()
    }

    // MARK: Serving the player

    /// Answers every waiting request from RAM as far as the data goes, then asks the reader for what is missing.
    private func pump() {
        guard !isInvalidated else {
            let error = stoppedFailure()
            for request in pending where !request.isFinished { request.finishLoading(with: error) }
            pending = []
            return
        }
        var more = false
        for request in pending {
            guard !request.isFinished, !request.isCancelled, let data = request.dataRequest else { continue }
            let end = data.requestsAllDataToEndOfResource ? buffer.contentLength
                : min(buffer.contentLength, data.requestedOffset + Int64(data.requestedLength))
            var given = 0
            while !isInvalidated, data.currentOffset < end, given < Self.responseTurn,
                  let chunk = buffer.data(from: data.currentOffset, maxLength: Int(min(end - data.currentOffset, Int64(Self.responseChunk)))) {
                data.respond(with: chunk); given += chunk.count
            }
            if data.currentOffset >= end { request.finishLoading(); continue }
            buffer.setAnchor(data.currentOffset)
            // More is ready, so come back after AVFoundation has had a chance to cancel or finish.
            if given >= Self.responseTurn { more = true }
            else if let failure, !buffer.contains(Int(data.currentOffset / Int64(buffer.blockSize))) { request.finishLoading(with: failure) }
        }
        pending.removeAll { $0.isFinished || $0.isCancelled }
        updateDemand()
        if more { delegateQueue.asyncAfter(deadline: .now() + .milliseconds(2)) { [weak self] in self?.pump() } }
    }

    private func updateDemand() {
        guard !isInvalidated else { return }
        let needed = pending.compactMap { request -> Int? in
            guard let data = request.dataRequest, data.currentOffset < buffer.contentLength else { return nil }
            let index = Int(data.currentOffset / Int64(buffer.blockSize))
            return buffer.contains(index) ? nil : index
        }
        lock.lock(); demand = needed; lock.unlock()
        scheduleReads()
    }

    // MARK: Reading the disk

    private func scheduleReads() {
        lock.lock()
        guard !readerRunning, !invalidated, readFailure == nil else { lock.unlock(); return }
        guard ProcessInfo.processInfo.systemUptime >= retryNotBefore else { lock.unlock(); return }
        guard nextReadLocked() != nil else { readActivity.end(); lock.unlock(); return }
        let request = UUID()
        let operation = BlockOperation { [weak self] in self?.readTurn(request) }
        readerID = request; readOperation = operation; readerRunning = true
        lock.unlock()
        Self.readWorkers.addOperation(operation)
    }

    private func readTurn(_ request: UUID) {
        lock.lock()
        // Invalidation can close a queued turn's FD before its closure runs.
        // Only the current turn may borrow it, atomically with becoming active.
        guard readerID == request else { lock.unlock(); return }
        guard !invalidated, readFailure == nil, let index = nextReadLocked() else {
            readerID = nil; readOperation = nil; readerRunning = false; readActivity.end()
            lock.unlock(); closeDescriptorIfIdle(); return
        }
        readerActive = true
        let essential = demand.contains(index) || priority.contains(index)
        lock.unlock()
        let result = read(block: index)
        lock.lock()
        let publish = !invalidated
        var stored = true
        if publish {
            switch result {
            case .success(let data): stored = buffer.store(data, block: index, allowsEviction: essential)
            case .failure(let error): readFailure = error; readActivity.end()
            }
        }
        readerActive = false; readerRunning = false; readerID = nil; readOperation = nil
        if !stored { retryNotBefore = ProcessInfo.processInfo.systemUptime + 0.25; readActivity.end() }
        lock.unlock()
        if publish {
            publisher.publish(buffer.snapshot)
            delegateQueue.async { [weak self] in self?.pump() }
        }
        closeDescriptorIfIdle()
        if stored { scheduleReads() }
    }

    /// Called with `lock` held, both before queueing and when the turn starts:
    /// demand may change while a different volume occupies a shared worker.
    private func nextReadLocked() -> Int? {
        if let index = demand.first(where: { !buffer.contains($0) }) ?? priority.first(where: { !buffer.contains($0) }) { return index }
        guard readsAhead, buffer.memoryBudget.permitsReadAhead,
              buffer.residentBytes < min(Int64(buffer.maximumBlocks) * Int64(buffer.blockSize), buffer.memoryBudget.limitBytes) else { return nil }
        let fits = buffer.blockCount <= buffer.maximumBlocks
        let ahead = min(readAheadBlocks, buffer.blockCount, buffer.maximumBlocks)
        if let index = buffer.firstMissing(from: buffer.playheadBlock, count: ahead, wrapping: fits),
           Int64(buffer.blockRange(index).count) <= buffer.memoryBudget.availableBytes { return index }
        return nil
    }

    private func read(block index: Int) -> Result<Data, Error> {
        lock.lock()
        let descriptor = self.descriptor
        guard !invalidated else { lock.unlock(); return .failure(CancellationError()) }
        readActivity.begin(at: ProcessInfo.processInfo.systemUptime)
        lock.unlock()
        let range = buffer.blockRange(index)
        let length = Int(range.count)
        // Each block is its own mapping, not malloc memory: when a block is dropped its pages go straight back to
        // the system, so closing a preview gives its RAM back instead of leaving it in the allocator's cache.
        guard let mapping = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0), mapping != MAP_FAILED else {
            return .failure(POSIXError(.ENOMEM))
        }
        var done = 0
        while done < length {
            if isInvalidated { munmap(mapping, length); return .failure(CancellationError()) }
            let count = io.read(descriptor, mapping + done, length - done, off_t(range.lowerBound) + off_t(done))
            if count > 0 {
                done += count
                lock.lock()
                readActivity.record(bytes: count, at: ProcessInfo.processInfo.systemUptime)
                lock.unlock()
                continue
            }
            if count < 0, errno == EINTR { continue }
            munmap(mapping, length)
            return .failure(count < 0 ? readError(errno) : readError(nil))
        }
        return .success(Data(bytesNoCopy: mapping, count: length, deallocator: .unmap))
    }

    /// A disk that has gone away reads as an error or as an early end of file. Say so the way the rest of the
    /// app does, so the preview offers to retry once the disk is back.
    private func readError(_ code: Int32?) -> Error {
        do { try LocalFileAccess.validate(fileURL) }
        catch { return error }
        if let code, let posix = POSIXErrorCode(rawValue: code) { return POSIXError(posix) }
        return CloudDriveError.waiting("“\(fileURL.lastPathComponent)” ended unexpectedly. Waiting for its disk to reconnect.")
    }

    /// The descriptor outlives a read in flight, so a reused descriptor number can never be read by mistake.
    private func closeDescriptorIfIdle() {
        lock.lock()
        guard invalidated, !readerRunning, descriptor >= 0 else { lock.unlock(); return }
        let descriptor = descriptor, close = io.close
        self.descriptor = -1
        lock.unlock()
        // Ownership is transferred once, after all reads have stopped. A slow
        // SMB close holds neither the UI nor the loader's state lock.
        NativeFileWork.performDescriptorCleanup { close(descriptor) }
    }
}

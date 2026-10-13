import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Read throughput counts bytes received from the volume, including rereads after RAM eviction. The cache's
/// resident size can stay constant while reading, so its growth is not a measure of speed.
struct FilePreviewReadActivity {
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
        samples.removeAll { $0.time <= time - 1 }
        if let last = samples.last, time - last.time < 0.1 {
            samples[samples.count - 1].bytes += Int64(bytes)
        } else { samples.append(Sample(time: time, bytes: Int64(bytes))) }
    }
    func bytesPerSecond(at time: TimeInterval) -> Double {
        guard isReading else { return 0 }
        let recent = samples.filter { $0.time > time - 1 }
        return Double(recent.reduce(Int64(0)) { $0 + $1.bytes }) / min(1, max(0.001, time - beganAt))
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

    var title: String {
        if failed { return "Read failed" }
        if cache.fraction == 1 { return "Fully buffered" }
        return isReading ? "Buffering" : "Buffer ready"
    }
}

/// Plays a file on an external disk or a network share from RAM. AVPlayer is given a custom-scheme
/// asset; this delegate answers its byte-range requests from a `MemoryRangeBuffer`
/// that a background reader fills from the volume: first what the player is waiting
/// for, then what lies ahead of it. The file is opened read-only and never copied
/// to storage, and a volume whose reads fail fails the request instead of hanging it.
final class FilePreviewResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "mycloud-media"
    /// AVFoundation calls the delegate here; the same serial queue is passed to `setDelegate`.
    let delegateQueue = DispatchQueue(label: "com.wky.PikPakDownloader.file-preview-loader.\(UUID().uuidString)", qos: .userInitiated)
    let assetURL: URL

    private let readQueue = DispatchQueue(label: "com.wky.PikPakDownloader.file-preview-reader.\(UUID().uuidString)", qos: .userInitiated)
    private let fileURL: URL
    private let buffer: MemoryRangeBuffer
    private let publisher: PreviewCacheProgressPublisher
    private let contentType: String
    /// Handed to AVFoundation in pieces this size, so its cancellations can run between pieces.
    private static let responseTurn = 4 << 20
    private static let responseChunk = 256 << 10

    private let lock = NSLock()
    private var descriptor: Int32
    private var demand: [Int] = []
    private var priority: [Int] = []
    private var readerRunning = false
    private var readsAhead = false
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
    init(fileURL: URL, contentType: UTType? = nil, budgetBytes: Int64 = MemoryRangeBuffer.automaticBudget(), blockSize: Int = 1 << 20,
         readAheadBytes: Int64 = 128 << 20,
         onSnapshot: @escaping @MainActor (PreviewResourceCacheSnapshot) -> Void = { _ in }) throws {
        let descriptor = open(fileURL.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            close(descriptor); throw CloudDriveError.message("Choose a regular file to preview.")
        }
        guard info.st_size > 0 else { close(descriptor); throw CloudDriveError.message("This file is empty.") }
        self.descriptor = descriptor
        self.fileURL = fileURL
        buffer = MemoryRangeBuffer(contentLength: Int64(info.st_size), budgetBytes: budgetBytes, blockSize: blockSize)
        readAheadBlocks = max(1, Int(max(0, readAheadBytes) / Int64(max(1, blockSize))))
        publisher = PreviewCacheProgressPublisher(onProgress: onSnapshot)
        self.contentType = (contentType ?? UTType(filenameExtension: fileURL.pathExtension))?.identifier ?? UTType.data.identifier
        var components = URLComponents()
        components.scheme = Self.scheme; components.host = "file"
        components.path = "/" + (contentType.map { "media." + ($0.preferredFilenameExtension ?? fileURL.pathExtension) } ?? fileURL.lastPathComponent)
        assetURL = components.url ?? URL(string: "\(Self.scheme)://file/media")!
        super.init()
    }
    // Not `invalidate()`: its cancellation closure forms a weak reference, which is not allowed while deallocating.
    deinit { release() }

    var snapshot: PreviewResourceCacheSnapshot { buffer.snapshot }
    var status: FilePreviewBufferStatus {
        lock.lock(); defer { lock.unlock() }
        return FilePreviewBufferStatus(cache: buffer.snapshot,
            budgetBytes: Int64(buffer.maximumBlocks) * Int64(buffer.blockSize), bytesRead: readActivity.bytesRead,
            bytesPerSecond: readActivity.bytesPerSecond(at: ProcessInfo.processInfo.systemUptime),
            isReading: readActivity.isReading, failed: readFailure != nil)
    }
    /// Why reads stopped, once the disk or file failed.
    var failure: Error? { lock.lock(); defer { lock.unlock() }; return readFailure }

    /// Reads the start of the file, and its end where many movies keep their header, before playback begins.
    func prime(headBlocks: Int = 16, tailBlocks: Int = 2, progress: @escaping @Sendable (Double) -> Void) async throws {
        let count = buffer.blockCount
        // Leave room in the budget for the playhead and the block being read next.
        let tail = min(tailBlocks, count, buffer.maximumBlocks / 4)
        let head = max(1, min(headBlocks, count - tail, buffer.maximumBlocks - tail - 1))
        let wanted = Array(0 ..< head) + Array((count - tail) ..< count).filter { $0 >= head }
        setPriority(wanted)
        scheduleReads()
        defer { setPriority([]) }
        while true {
            try Task.checkCancellation()
            if let failure { throw failure }
            let done = wanted.filter { buffer.contains($0) }.count
            progress(Double(done) / Double(wanted.count))
            if done == wanted.count { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func setPriority(_ blocks: [Int]) { lock.lock(); priority = blocks; lock.unlock() }

    /// Starts or stops reading ahead of the playhead. Playback turns it on; pausing or leaving it off leaves the
    /// disk alone once what the player asked for has been read.
    func setReadingAhead(_ enabled: Bool) {
        lock.lock()
        let changed = readsAhead != enabled
        readsAhead = enabled
        let active = !invalidated
        lock.unlock()
        if enabled, changed, active { scheduleReads() }
    }
    private func release() {
        publisher.invalidate()
        lock.lock(); invalidated = true; demand = []; priority = []; readActivity.end(); lock.unlock()
        buffer.removeAll()
        closeDescriptorIfIdle()
    }

    /// Frees the RAM, stops reading and ends any request the player is waiting on.
    func invalidate() {
        release()
        delegateQueue.async { [weak self] in
            guard let self else { return }
            let cancellation = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled,
                                       userInfo: [NSLocalizedDescriptionKey: "The media preview was cancelled."])
            for request in self.pending where !request.isFinished { request.finishLoading(with: cancellation) }
            self.pending = []
        }
    }

    // MARK: AVAssetResourceLoaderDelegate

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard loadingRequest.request.url?.scheme == Self.scheme else { return false }
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
        var more = false
        for request in pending {
            guard !request.isFinished, !request.isCancelled, let data = request.dataRequest else { continue }
            let end = data.requestsAllDataToEndOfResource ? buffer.contentLength
                : min(buffer.contentLength, data.requestedOffset + Int64(data.requestedLength))
            var given = 0
            while data.currentOffset < end, given < Self.responseTurn,
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
        readerRunning = true; lock.unlock()
        readQueue.async { [weak self] in self?.readLoop() }
    }

    private func readLoop() {
        while let index = takeNextRead() {
            let result = read(block: index)
            lock.lock()
            if invalidated { readerRunning = false; lock.unlock(); closeDescriptorIfIdle(); return }
            switch result {
            case .success(let data): buffer.store(data, block: index)
            case .failure(let error): readFailure = error; readActivity.end()
            }
            lock.unlock()
            publisher.publish(buffer.snapshot)
            delegateQueue.async { [weak self] in self?.pump() }
        }
        closeDescriptorIfIdle()
    }

    /// The next block to read, or nil (ending the reader) when nothing is wanted. Decided under the lock so a
    /// request that arrives while the reader is finishing cannot be missed.
    private func takeNextRead() -> Int? {
        lock.lock(); defer { lock.unlock() }
        guard !invalidated, readFailure == nil else { readerRunning = false; readActivity.end(); return nil }
        if let index = demand.first(where: { !buffer.contains($0) }) ?? priority.first(where: { !buffer.contains($0) }) { return index }
        // Read ahead of the playhead, but only while playing, and only a bounded window: what fits in RAM with room
        // to spare, and never more than `readAheadBlocks`.
        guard readsAhead else { readerRunning = false; readActivity.end(); return nil }
        let fits = buffer.blockCount <= buffer.maximumBlocks
        let ahead = min(readAheadBlocks, fits ? buffer.blockCount : max(1, buffer.maximumBlocks * 3 / 4))
        if let index = buffer.firstMissing(from: buffer.playheadBlock, count: ahead, wrapping: false) { return index }
        readerRunning = false; readActivity.end()
        return nil
    }

    private func read(block index: Int) -> Result<Data, Error> {
        lock.lock()
        let descriptor = self.descriptor
        if !invalidated { readActivity.begin(at: ProcessInfo.processInfo.systemUptime) }
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
            let count = pread(descriptor, mapping + done, length - done, off_t(range.lowerBound) + off_t(done))
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
        lock.lock(); defer { lock.unlock() }
        guard invalidated, !readerRunning, descriptor >= 0 else { return }
        close(descriptor); descriptor = -1
    }
}

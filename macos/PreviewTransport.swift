import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Native previews follow the engine's direct-by-default network policy.
/// Only a proxy explicitly entered in the app may override that route.
enum PreviewTransport {
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/117.0.0.0 Safari/537.36"

    static let mediaHeaders = [
        "User-Agent": userAgent,
        "Referer": "https://mypikpak.com/",
        "Origin": "https://mypikpak.com",
        "Accept": "video/*, audio/*, */*;q=0.8",
        "Accept-Encoding": "identity",
    ]

    /// A whole-object GET can arrive as HTTP 206. Prove that it includes every
    /// byte before passing the file to a decoder or another application.
    @discardableResult
    static func completeDownloadSize(at file: URL, response: URLResponse?, purpose: String) throws -> UInt64 {
        try MediaFileDownload.completeSize(at: file, response: response, purpose: purpose)
    }

    /// PikPak can issue HTTP original-file links even though its download CDN
    /// serves the same signed resource over HTTPS. Promote only that CDN; the
    /// native image, player and Open/Quick Look transports still require TLS.
    static func secureContentURL(_ rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil else { return nil }

        switch scheme {
        case "https":
            break
        case "http":
            guard host.hasPrefix("dl-"), host.hasSuffix(".mypikpak.com"),
                  components.port == nil || components.port == 80 else { return nil }
            components.port = nil
        default:
            return nil
        }
        // Leave the percent-encoded path and query intact: they carry the
        // CDN signature and must not be decoded/re-encoded during promotion.
        components.scheme = "https"
        return components.url
    }

    static func effectiveProxyURL(_ configuredValue: String) -> String {
        configuredValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func configuration(proxyURL: String) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 6 * 60 * 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldUsePipelining = true
        configuration.httpAdditionalHeaders = mediaHeaders
        // nil inherits macOS proxy/PAC settings. An explicit empty dictionary
        // keeps previews and Open With downloads on the direct route.
        configuration.connectionProxyDictionary =
            proxyDictionary(for: effectiveProxyURL(proxyURL)) ?? [:]
        return configuration
    }

    static func usesProxy(_ configuredValue: String) -> Bool {
        proxyDictionary(for: effectiveProxyURL(configuredValue)) != nil
    }

    static func isSecureConnectionFailure(_ error: Error?) -> Bool {
        guard let error else { return false }
        var pending = [error as NSError]
        var visited = Set<ObjectIdentifier>()

        while let current = pending.popLast() {
            let identity = ObjectIdentifier(current)
            guard visited.insert(identity).inserted else { continue }
            if current.domain == NSURLErrorDomain,
               current.code == NSURLErrorSecureConnectionFailed {
                return true
            }
            if let underlying = current.userInfo[NSUnderlyingErrorKey] as? NSError {
                pending.append(underlying)
            }
            if let multiple = current.userInfo[NSMultipleUnderlyingErrorsKey] as? [NSError] {
                pending.append(contentsOf: multiple)
            }
        }
        return false
    }

    private static func proxyDictionary(for rawValue: String) -> [AnyHashable: Any]? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let normalized = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: normalized),
              let host = url.host,
              !host.isEmpty else { return nil }

        let scheme = (url.scheme ?? "http").lowercased()
        let defaultPort: Int
        switch scheme {
        case "socks", "socks5", "socks5h": defaultPort = 1080
        case "https": defaultPort = 443
        default: defaultPort = 80
        }
        let port = url.port ?? defaultPort

        switch scheme {
        case "socks", "socks5", "socks5h":
            return [
                "SOCKSEnable": 1,
                "SOCKSProxy": host,
                "SOCKSPort": port,
            ]
        case "http", "https":
            // PikPak media URLs are HTTPS. Configure only CFNetwork's secure
            // destination route: some local mixed proxies (including xray)
            // stall when the same endpoint is simultaneously installed as
            // both HTTPProxy and HTTPSProxy, even though HTTPS-only CONNECT is
            // successful. This was verified with native URLSession, not curl.
            return [
                "HTTPSEnable": 1,
                "HTTPSProxy": host,
                "HTTPSPort": port,
            ]
        default:
            return nil
        }
    }
}

struct PreviewResourceCacheSnapshot: Equatable {
    let cachedBytes: Int64
    let contentLength: Int64?
    /// Received bytes include overlapping requests and survive cache eviction.
    let receivedBytes: Int64?
    /// The retained byte ranges, ordered and disjoint. `cachedBytes` alone is a
    /// total and cannot say *where* the data is: AVFoundation routinely fetches
    /// a movie header near the end of a file before any media at the start, so
    /// a single left-anchored fill would paint tail bytes as if they were at
    /// the head.
    let ranges: [Range<Int64>]

    init(cachedBytes: Int64, contentLength: Int64?, ranges: [Range<Int64>] = [], receivedBytes: Int64? = nil) {
        self.cachedBytes = cachedBytes
        self.contentLength = contentLength
        self.ranges = ranges
        self.receivedBytes = receivedBytes
    }

    var fraction: Double? {
        guard let contentLength, contentLength > 0 else { return nil }
        return min(max(Double(cachedBytes) / Double(contentLength), 0), 1)
    }

    /// Normalized 0...1 spans for drawing, clamped to the known content length.
    var normalizedRanges: [ClosedRange<Double>] {
        guard let contentLength, contentLength > 0 else { return [] }
        let total = Double(contentLength)
        return ranges.compactMap { range in
            let start = min(max(Double(range.lowerBound) / total, 0), 1)
            let end = min(max(Double(range.upperBound) / total, 0), 1)
            return end > start ? start ... end : nil
        }
    }

    /// How far playback can run uninterrupted from `offset` before hitting a
    /// gap. Zero when `offset` itself is not retained.
    func contiguousEnd(from offset: Int64) -> Int64? {
        guard let range = ranges.first(where: {
            $0.lowerBound <= offset && offset < $0.upperBound
        }) else { return nil }
        return range.upperBound
    }
}

fileprivate struct PreviewResourceMetadata {
    let typeIdentifier: String?
    let contentLength: Int64?
    let supportsByteRanges: Bool
}

/// Sparse byte ranges in RAM. All sources and windows share the same budget.
/// A disk copy is created only when a complete file is handed to a converter.
final class PreviewResourceCache: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [Int64: Data] = [:]
    private var chunkStarts: [Int64] = []
    private var cachedRanges: [Range<Int64>] = []
    private var metadata = PreviewResourceMetadata(typeIdentifier: nil, contentLength: nil, supportsByteRanges: false)
    private var isClosed = false
    private var resident: Int64 = 0
    private var received: Int64 = 0
    private let maximumBytes: Int64
    let memoryBudget: PreviewMemoryBudget
    private var cleanupID: UUID?

    // Keep the storage parameters source-compatible with existing callers.
    init(maximumBytes: Int64 = .max, minimumFreeDiskBytes: Int64 = 0, directory: URL? = nil,
         memoryBudget: PreviewMemoryBudget = .shared) throws {
        self.maximumBytes = max(1, maximumBytes)
        self.memoryBudget = memoryBudget
        cleanupID = memoryBudget.registerCleanup(residentBytes: { [weak self] in self?.snapshot.cachedBytes ?? 0 },
            reclaim: { [weak self] in self?.reclaim() }) { [weak self] in self?.purge() }
    }
    deinit {
        if let cleanupID { memoryBudget.unregisterCleanup(cleanupID) }
        memoryBudget.release(resident)
    }
    var snapshot: PreviewResourceCacheSnapshot {
        lock.lock(); defer { lock.unlock() }; return snapshotLocked()
    }
    fileprivate var contentMetadata: PreviewResourceMetadata {
        lock.lock(); defer { lock.unlock() }; return metadata
    }
    @discardableResult func updateMetadata(typeIdentifier: String?, contentLength: Int64?,
                                          supportsByteRanges: Bool) -> PreviewResourceCacheSnapshot {
        lock.lock(); defer { lock.unlock() }
        guard !isClosed else { return snapshotLocked() }
        metadata = .init(typeIdentifier: typeIdentifier ?? metadata.typeIdentifier,
                         contentLength: contentLength ?? metadata.contentLength,
                         supportsByteRanges: supportsByteRanges || metadata.supportsByteRanges)
        return snapshotLocked()
    }
    @discardableResult func store(_ data: Data, at offset: Int64, allowsEviction: Bool = true) -> PreviewResourceCacheSnapshot? {
        guard !data.isEmpty, offset >= 0 else { return snapshot }
        let (end, overflow) = offset.addingReportingOverflow(Int64(data.count))
        guard !overflow else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard !isClosed, Int64(data.count) <= maximumBytes else { return nil }
        var missing: [Range<Int64>] = [], cursor = offset
        for range in cachedRanges where range.upperBound > cursor && range.lowerBound < end {
            if range.lowerBound > cursor { missing.append(cursor..<min(end, range.lowerBound)) }
            cursor = max(cursor, range.upperBound)
        }
        if cursor < end { missing.append(cursor..<end) }
        var added = missing.reduce(Int64(0)) { $0 + Int64($1.count) }
        if added == 0 { received += Int64(data.count); return snapshotLocked() }
        if resident + added > maximumBytes || !memoryBudget.reserve(added, background: !allowsEviction) {
            guard allowsEviction else { return nil }
            purgeLocked()
            missing = [offset..<end]; added = Int64(data.count)
            guard memoryBudget.reserve(added, background: false) else {
                if let cleanupID { memoryBudget.requestRoom(excluding: cleanupID) }
                return nil
            }
        }
        var incoming: [Int64: Data] = [:]
        for range in missing {
            // Keep chunks small so reads/seeks never copy the rest of a large file.
            var start = range.lowerBound
            while start < range.upperBound {
                let stop = min(range.upperBound, start + (1 << 20))
                let lower = data.startIndex + Int(start - offset), upper = data.startIndex + Int(stop - offset)
                guard let mapped = PreviewMemoryBudget.copy(data.subdata(in: lower..<upper)) else {
                    memoryBudget.release(added); return nil
                }
                incoming[start] = mapped; start = stop
            }
        }
        chunks.merge(incoming) { _, new in new }; resident += added
        for start in incoming.keys.sorted() {
            if chunkStarts.last.map({ $0 < start }) ?? true { chunkStarts.append(start); continue }
            var low = 0, high = chunkStarts.count
            while low < high {
                let middle = (low + high) / 2
                if chunkStarts[middle] < start { low = middle + 1 } else { high = middle }
            }
            chunkStarts.insert(start, at: low)
        }
        insertCachedRange(offset..<end)
        received += Int64(data.count)
        return snapshotLocked()
    }
    var permitsBackgroundPrefetch: Bool {
        lock.lock(); defer { lock.unlock() }
        return !isClosed && resident < maximumBytes && memoryBudget.permitsReadAhead
    }
    func read(at offset: Int64, maximumLength: Int) -> Data? {
        guard offset >= 0, maximumLength > 0 else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard !isClosed else { return nil }
        var result = Data(), cursor = offset
        // Binary search over sorted chunk offsets avoids scanning GB of ranges for every player read.
        let starts = chunkStarts
        var low = 0, high = starts.count
        while low < high {
            let middle = (low + high) / 2
            if starts[middle] <= offset { low = middle + 1 } else { high = middle }
        }
        var index = max(0, low - 1)
        while index < starts.count, result.count < maximumLength {
            let start = starts[index]
            guard let data = chunks[start], start <= cursor, cursor < start + Int64(data.count) else { break }
            let from = Int(cursor - start), count = min(data.count - from, maximumLength - result.count)
            result.append(data.subdata(in: from..<(from + count))); cursor += Int64(count); index += 1
        }
        return result.isEmpty ? nil : result
    }
    func firstMissingOffset() -> Int64? {
        lock.lock(); defer { lock.unlock() }
        guard !isClosed else { return nil }
        var cursor: Int64 = 0
        for range in cachedRanges {
            if range.lowerBound > cursor { return cursor }
            cursor = max(cursor, range.upperBound)
        }
        return metadata.contentLength.map { cursor >= $0 } == true ? nil : cursor
    }
    /// Only decoder recovery needs a complete input file. Call from a worker,
    /// keeping the RAM owner alive until the write has finished.
    func takeCompleteFile(expectedSize: UInt64 = 0) throws -> VideoPreviewCopy? {
        lock.lock(); defer { lock.unlock() }
        guard !isClosed, let length = metadata.contentLength, length > 0,
              cachedRanges == [0..<length], expectedSize == 0 || UInt64(length) == expectedSize else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Prepared-\(UUID().uuidString)", isDirectory: true)
        try CloudDriveFiles.privateDirectory(directory)
        let input = directory.appendingPathComponent("source")
        do {
            guard FileManager.default.createFile(atPath: input.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            let handle = try FileHandle(forWritingTo: input)
            defer { try? handle.close() }
            for start in chunkStarts {
                try handle.seek(toOffset: UInt64(start)); try handle.write(contentsOf: chunks[start]!)
            }
            purgeLocked(); isClosed = true
            return VideoPreviewCopy(url: input, directory: directory)
        } catch { try? FileManager.default.removeItem(at: directory); throw error }
    }
    func removeFromDisk() {
        lock.lock()
        isClosed = true
        let discarded = chunks, bytes = resident, budget = memoryBudget
        chunks = [:]; chunkStarts = []; cachedRanges = []; resident = 0
        lock.unlock()
        NativeFileWork.performMemoryCleanup {
            withExtendedLifetime(discarded) {}
            budget.release(bytes)
        }
    }
    func setPriority(_ priority: Int, gracePeriod: TimeInterval = 0) {
        lock.lock(); defer { lock.unlock() }
        if let cleanupID { memoryBudget.setPriority(priority, for: cleanupID, gracePeriod: gracePeriod) }
    }
    private func reclaim() {
        lock.lock(); defer { lock.unlock() }
        guard let cleanupID, memoryBudget.canReclaim(cleanupID) else { return }
        purgeLocked()
    }
    private func purge() { lock.lock(); defer { lock.unlock() }; purgeLocked() }
    private func purgeLocked() {
        chunks = [:]; chunkStarts = []; cachedRanges = []; memoryBudget.release(resident); resident = 0
    }
    private func insertCachedRange(_ incoming: Range<Int64>) {
        var lower = incoming.lowerBound, upper = incoming.upperBound
        var result: [Range<Int64>] = [], inserted = false
        for range in cachedRanges {
            if range.upperBound < lower { result.append(range) }
            else if upper < range.lowerBound {
                if !inserted { result.append(lower..<upper); inserted = true }
                result.append(range)
            } else { lower = min(lower, range.lowerBound); upper = max(upper, range.upperBound) }
        }
        if !inserted { result.append(lower..<upper) }; cachedRanges = result
    }
    private func snapshotLocked() -> PreviewResourceCacheSnapshot {
        .init(cachedBytes: resident, contentLength: metadata.contentLength, ranges: cachedRanges, receivedBytes: received)
    }
}

/// Both cache readers and the background writer can report progress faster than
/// SwiftUI can consume it. Keep one latest snapshot and at most one queued main
/// queue delivery, including when a completed cache is read repeatedly.
final class PreviewCacheProgressPublisher {
    private let lock = NSLock()
    private let onProgress: @MainActor (PreviewResourceCacheSnapshot) -> Void
    private let interval: TimeInterval
    private var pending: PreviewResourceCacheSnapshot?
    private var lastDelivered: PreviewResourceCacheSnapshot?
    private var nextDelivery = DispatchTime.now()
    private var deliveryScheduled = false
    private var invalidated = false

    init(
        interval: TimeInterval = 0.25,
        onProgress: @escaping @MainActor (PreviewResourceCacheSnapshot) -> Void
    ) {
        precondition(interval.isFinite && interval > 0)
        self.interval = interval
        self.onProgress = onProgress
    }

    func publish(_ snapshot: PreviewResourceCacheSnapshot) {
        lock.lock()
        guard !invalidated, snapshot != (pending ?? lastDelivered) else {
            lock.unlock()
            return
        }
        pending = snapshot
        guard !deliveryScheduled else { lock.unlock(); return }
        deliveryScheduled = true
        let deadline = nextDelivery
        lock.unlock()
        DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
            self?.deliver()
        }
    }

    func invalidate() {
        lock.lock()
        invalidated = true
        pending = nil
        lastDelivered = nil
        lock.unlock()
    }

    @MainActor private func deliver() {
        lock.lock()
        deliveryScheduled = false
        guard !invalidated, let snapshot = pending else { lock.unlock(); return }
        pending = nil
        guard snapshot != lastDelivered else { lock.unlock(); return }
        lastDelivered = snapshot
        nextDelivery = .now() + interval
        lock.unlock()
        onProgress(snapshot)
    }
}

/// Continues filling the current progressive media cache even when AVPlayer has
/// enough data for its own immediate needs or the user pauses playback. The
/// interactive resource-loader requests keep normal priority; this sequential
/// fill is deliberately low priority and resumes at the first uncached byte.
final class PreviewResourcePrefetcher: NSObject, URLSessionDataDelegate {
    private let originalURL: URL
    private let headers: [String: String]
    private let cache: PreviewResourceCache
    private let onCacheProgress: (PreviewResourceCacheSnapshot) -> Void
    private let delegateQueue: DispatchQueue
    private let sessionDelegateQueue: OperationQueue
    private var session: URLSession!
    private var task: URLSessionDataTask?
    private var requestedOffset: Int64 = 0
    private var responseStartOffset: Int64 = 0
    private var receivedBytes: Int64 = 0
    private var cachedBytesAtTaskStart: Int64 = 0
    private var retryCount = 0
    private var taskCanRetry = true
    private var taskCancellationShouldRetry = false
    private var isInvalidated = false
    private var startIsScheduled = false
    private var retryTimer: DispatchSourceTimer?
    private var terminalFailure = false
    private let mayPrefetch: @Sendable () -> Bool
    var hasTerminalFailure: Bool { delegateQueue.sync { terminalFailure } }

    init(
        originalURL: URL,
        proxyURL: String,
        cache: PreviewResourceCache,
        onCacheProgress: @escaping (PreviewResourceCacheSnapshot) -> Void,
        headers: [String: String] = PreviewTransport.mediaHeaders,
        mayPrefetch: @escaping @Sendable () -> Bool = { true }
    ) {
        self.originalURL = originalURL
        self.headers = headers
        self.cache = cache
        self.mayPrefetch = mayPrefetch
        self.onCacheProgress = onCacheProgress
        delegateQueue = DispatchQueue(
            label: "com.wky.PikPakDownloader.preview-prefetch.\(UUID().uuidString)",
            qos: .utility
        )
        sessionDelegateQueue = OperationQueue()
        sessionDelegateQueue.name =
            "com.wky.PikPakDownloader.preview-prefetch-session.\(UUID().uuidString)"
        sessionDelegateQueue.maxConcurrentOperationCount = 1
        sessionDelegateQueue.qualityOfService = .utility
        sessionDelegateQueue.underlyingQueue = delegateQueue
        super.init()
        session = URLSession(
            configuration: PreviewTransport.configuration(proxyURL: proxyURL),
            delegate: self,
            delegateQueue: sessionDelegateQueue
        )
        let timer = DispatchSource.makeTimerSource(queue: delegateQueue)
        retryTimer = timer
        timer.schedule(deadline: .now() + .milliseconds(750), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in
            guard let self, !self.isInvalidated else { return }
            if self.cache.memoryBudget.isUnderPressure || !self.mayPrefetch() {
                self.task?.cancel()
            } else if !self.startIsScheduled { self.startTaskIfNeeded() }
        }
        timer.activate()
    }

    deinit {
        retryTimer?.cancel()
        session?.invalidateAndCancel()
    }

    func start(after delay: TimeInterval = 0.75) {
        delegateQueue.async { [weak self] in
            guard let self,
                  !self.isInvalidated,
                  !self.startIsScheduled,
                  self.task == nil else { return }
            self.startIsScheduled = true
            self.delegateQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                self.startIsScheduled = false
                self.startTaskIfNeeded()
            }
        }
    }

    func invalidate() {
        delegateQueue.async { [weak self] in
            guard let self, !self.isInvalidated else { return }
            self.isInvalidated = true
            self.retryTimer?.cancel()
            self.startIsScheduled = false
            self.task?.cancel()
            self.task = nil
            self.session.invalidateAndCancel()
        }
    }

    private func startTaskIfNeeded() {
        guard !isInvalidated, !terminalFailure, mayPrefetch(), task == nil, cache.permitsBackgroundPrefetch,
              let offset = cache.firstMissingOffset() else {
            publishCacheProgress(cache.snapshot)
            return
        }

        let metadata = cache.contentMetadata
        if let length = metadata.contentLength, offset >= length {
            publishCacheProgress(cache.snapshot)
            return
        }

        var request = URLRequest(url: originalURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 90
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let length = metadata.contentLength, length > offset {
            request.setValue("bytes=\(offset)-\(length - 1)", forHTTPHeaderField: "Range")
        } else {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }

        requestedOffset = offset
        responseStartOffset = offset
        receivedBytes = 0
        cachedBytesAtTaskStart = cache.snapshot.cachedBytes
        taskCanRetry = true
        taskCancellationShouldRetry = false
        let nextTask = session.dataTask(with: request)
        nextTask.priority = URLSessionTask.lowPriority
        task = nextTask
        nextTask.resume()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard dataTask.taskIdentifier == task?.taskIdentifier,
              !isInvalidated else {
            completionHandler(.cancel)
            return
        }

        if let http = response as? HTTPURLResponse,
           !(http.statusCode == 200 || http.statusCode == 206) {
            taskCanRetry = http.statusCode == 408
                || http.statusCode == 429
                || (500...599).contains(http.statusCode)
            taskCancellationShouldRetry = taskCanRetry
            terminalFailure = !taskCanRetry
            completionHandler(.cancel)
            return
        }

        let typeIdentifier = response.mimeType.flatMap { UTType(mimeType: $0)?.identifier }
            ?? UTType(filenameExtension: originalURL.pathExtension)?.identifier
        let totalLength: Int64?
        if let http = response as? HTTPURLResponse,
           let total = contentRangeTotal(http) {
            totalLength = total
        } else if let http = response as? HTTPURLResponse,
                  http.statusCode == 200,
                  response.expectedContentLength >= 0 {
            totalLength = response.expectedContentLength
        } else {
            totalLength = nil
        }
        let supportsRanges: Bool
        if let http = response as? HTTPURLResponse {
            supportsRanges = http.statusCode == 206
                || (http.value(forHTTPHeaderField: "Accept-Ranges") ?? "")
                    .lowercased().contains("bytes")
            if http.statusCode == 200 {
                responseStartOffset = 0
            } else {
                responseStartOffset = contentRangeStart(http) ?? requestedOffset
            }
        } else {
            supportsRanges = true
            responseStartOffset = requestedOffset
        }
        let snapshot = cache.updateMetadata(
            typeIdentifier: typeIdentifier,
            contentLength: totalLength,
            supportsByteRanges: supportsRanges
        )
        publishCacheProgress(snapshot)
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard dataTask.taskIdentifier == task?.taskIdentifier,
              !isInvalidated else { return }
        let (offset, offsetOverflow) = responseStartOffset.addingReportingOverflow(receivedBytes)
        let (newReceivedBytes, countOverflow) = receivedBytes.addingReportingOverflow(
            Int64(data.count)
        )
        guard !offsetOverflow, !countOverflow,
              let snapshot = cache.store(data, at: offset, allowsEviction: false) else {
            taskCanRetry = false
            dataTask.cancel()
            return
        }
        receivedBytes = newReceivedBytes
        publishCacheProgress(snapshot)
    }

    func urlSession(
        _ session: URLSession,
        task completedTask: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard completedTask.taskIdentifier == task?.taskIdentifier else { return }
        task = nil
        let snapshot = cache.snapshot
        publishCacheProgress(snapshot)
        guard !isInvalidated,
              cache.firstMissingOffset() != nil else { return }

        if snapshot.cachedBytes > cachedBytesAtTaskStart {
            retryCount = 0
        }
        let wasCancelled = (error as NSError?)?.code == NSURLErrorCancelled
        if error == nil, snapshot.cachedBytes > cachedBytesAtTaskStart {
            start(after: 0); return
        }
        guard taskCanRetry,
              (!wasCancelled || taskCancellationShouldRetry) else { return }
        let delay = AutomaticRecovery.delay(attempt: retryCount, schedule: [1, 3, 8, 30, 60])
        retryCount = AutomaticRecovery.nextAttempt(retryCount)
        start(after: delay)
    }

    private func publishCacheProgress(
        _ snapshot: PreviewResourceCacheSnapshot
    ) {
        onCacheProgress(snapshot)
    }

    private func contentRangeStart(_ response: HTTPURLResponse) -> Int64? {
        guard let value = response.value(forHTTPHeaderField: "Content-Range"),
              let rangePart = value.split(separator: " ").last?.split(separator: "/").first,
              let startPart = rangePart.split(separator: "-").first else { return nil }
        return Int64(startPart)
    }

    private func contentRangeTotal(_ response: HTTPURLResponse) -> Int64? {
        guard let value = response.value(forHTTPHeaderField: "Content-Range"),
              let totalPart = value.split(separator: "/").last,
              totalPart != "*" else { return nil }
        return Int64(totalPart)
    }
}

/// Supplies progressive media to AVPlayer through a configured URLSession.
/// AVURLAsset has no public per-asset proxy option, so a resource loader is the
/// supported way to retain seeking/range requests while routing the bytes via
/// the app's own transport. It deliberately implements no trust challenge
/// override; server certificates still receive normal system validation.
final class PreviewResourceLoader: NSObject, AVAssetResourceLoaderDelegate,
    URLSessionDataDelegate {
    let delegateQueue: DispatchQueue
    let assetURL: URL

    private final class RequestContext {
        let loadingRequest: AVAssetResourceLoadingRequest
        let networkOffset: Int64
        var responseStartOffset: Int64
        var receivedNetworkBytes: Int64 = 0

        init(
            loadingRequest: AVAssetResourceLoadingRequest,
            networkOffset: Int64
        ) {
            self.loadingRequest = loadingRequest
            self.networkOffset = networkOffset
            responseStartOffset = networkOffset
        }
    }

    private let originalURL: URL
    private let headers: [String: String]
    private let cache: PreviewResourceCache
    private let progressPublisher: PreviewCacheProgressPublisher
    private let prefetcher: PreviewResourcePrefetcher
    private let sessionDelegateQueue: OperationQueue
    private var session: URLSession!
    private var requestsByTaskID: [Int: RequestContext] = [:]
    private var isInvalidated = false

    init(
        originalURL: URL,
        proxyURL: String,
        cache: PreviewResourceCache,
        onCacheProgress: @escaping @MainActor (PreviewResourceCacheSnapshot) -> Void,
        headers: [String: String] = PreviewTransport.mediaHeaders
    ) {
        self.originalURL = originalURL
        self.headers = headers
        self.cache = cache
        let publisher = PreviewCacheProgressPublisher(onProgress: onCacheProgress)
        progressPublisher = publisher
        prefetcher = PreviewResourcePrefetcher(
            originalURL: originalURL,
            proxyURL: proxyURL,
            cache: cache,
            onCacheProgress: { publisher.publish($0) },
            headers: headers
        )
        delegateQueue = DispatchQueue(
            label: "com.wky.PikPakDownloader.preview-resource-loader.\(UUID().uuidString)",
            qos: .userInitiated
        )
        sessionDelegateQueue = OperationQueue()
        sessionDelegateQueue.name =
            "com.wky.PikPakDownloader.preview-resource-session.\(UUID().uuidString)"
        sessionDelegateQueue.maxConcurrentOperationCount = 1
        sessionDelegateQueue.qualityOfService = .userInitiated
        sessionDelegateQueue.underlyingQueue = delegateQueue

        var components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false)
        components?.scheme = "pikpak-preview"
        assetURL = components?.url ?? URL(string: "pikpak-preview://media")!

        super.init()
        session = URLSession(
            configuration: PreviewTransport.configuration(proxyURL: proxyURL),
            delegate: self,
            delegateQueue: sessionDelegateQueue
        )
        prefetcher.start()
    }

    deinit {
        progressPublisher.invalidate()
        prefetcher.invalidate()
        session?.invalidateAndCancel()
    }

    func invalidate() {
        progressPublisher.invalidate()
        prefetcher.invalidate()
        delegateQueue.async { [weak self] in
            guard let self, !self.isInvalidated else { return }
            self.isInvalidated = true
            let cancellation = NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorCancelled,
                userInfo: [NSLocalizedDescriptionKey: "The media preview request was cancelled."]
            )
            let contexts = Array(self.requestsByTaskID.values)
            self.requestsByTaskID.removeAll()
            for context in contexts where !context.loadingRequest.isFinished {
                context.loadingRequest.finishLoading(with: cancellation)
            }
            self.session.invalidateAndCancel()
        }
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard loadingRequest.request.url?.scheme == assetURL.scheme else { return false }
        guard !isInvalidated else {
            loadingRequest.finishLoading(with: URLError(.cancelled))
            return true
        }

        let cachedMetadata = cache.contentMetadata
        populateContentInformation(
            loadingRequest.contentInformationRequest,
            metadata: cachedMetadata
        )

        if loadingRequest.dataRequest == nil,
           cachedMetadata.contentLength != nil {
            loadingRequest.finishLoading()
            publishCacheProgress(cache.snapshot)
            return true
        }

        let requestedEndOffset = requestedEndOffset(for: loadingRequest.dataRequest)
        if respondFromCache(
            to: loadingRequest,
            requestedEndOffset: requestedEndOffset
        ) {
            publishCacheProgress(cache.snapshot)
            return true
        }

        let dataRequest = loadingRequest.dataRequest
        let offset = nextOffset(for: dataRequest)
        let requestedLength = requestedEndOffset.map { max($0 - offset, 0) }
        if requestedLength == 0 {
            loadingRequest.finishLoading()
            return true
        }

        var request = URLRequest(url: originalURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 90
        for (field, value) in headers {
            request.setValue(value, forHTTPHeaderField: field)
        }

        if dataRequest == nil {
            request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        } else if let requestedLength, requestedLength > 0 {
            let (candidateEnd, overflow) = offset.addingReportingOverflow(requestedLength - 1)
            let end = overflow ? Int64.max : candidateEnd
            request.setValue("bytes=\(offset)-\(end)", forHTTPHeaderField: "Range")
        } else {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }

        let task = session.dataTask(with: request)
        requestsByTaskID[task.taskIdentifier] = RequestContext(
            loadingRequest: loadingRequest,
            networkOffset: offset
        )
        task.resume()
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        guard let entry = requestsByTaskID.first(where: {
            $0.value.loadingRequest === loadingRequest
        }) else { return }
        requestsByTaskID.removeValue(forKey: entry.key)
        session.getAllTasks { tasks in
            tasks.first(where: { $0.taskIdentifier == entry.key })?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let context = requestsByTaskID[dataTask.taskIdentifier] else {
            completionHandler(.cancel)
            return
        }

        if let http = response as? HTTPURLResponse,
           !(http.statusCode == 200 || http.statusCode == 206) {
            requestsByTaskID.removeValue(forKey: dataTask.taskIdentifier)
            let error = NSError(
                domain: "PikPakPreviewTransport",
                code: http.statusCode,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "PikPak media server returned HTTP \(http.statusCode).",
                ]
            )
            context.loadingRequest.finishLoading(with: error)
            completionHandler(.cancel)
            return
        }

        let metadata = responseMetadata(response)
        let snapshot = cache.updateMetadata(
            typeIdentifier: metadata.typeIdentifier,
            contentLength: metadata.contentLength,
            supportsByteRanges: metadata.supportsByteRanges
        )
        publishCacheProgress(snapshot)

        if let http = response as? HTTPURLResponse, http.statusCode == 200 {
            context.responseStartOffset = 0
        } else if let http = response as? HTTPURLResponse,
                  let responseOffset = contentRangeStart(http) {
            context.responseStartOffset = responseOffset
        }

        context.loadingRequest.response = response
        populateContentInformation(
            context.loadingRequest.contentInformationRequest,
            metadata: metadata
        )

        if context.loadingRequest.dataRequest == nil {
            requestsByTaskID.removeValue(forKey: dataTask.taskIdentifier)
            context.loadingRequest.finishLoading()
            completionHandler(.cancel)
            return
        }

        if respondFromCache(
            to: context.loadingRequest,
            requestedEndOffset: requestedEndOffset(for: context.loadingRequest.dataRequest)
        ) {
            requestsByTaskID.removeValue(forKey: dataTask.taskIdentifier)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        guard let context = requestsByTaskID[dataTask.taskIdentifier],
              !context.loadingRequest.isCancelled else { return }

        let (chunkOffset, offsetOverflow) = context.responseStartOffset
            .addingReportingOverflow(context.receivedNetworkBytes)
        let (receivedBytes, countOverflow) = context.receivedNetworkBytes
            .addingReportingOverflow(Int64(data.count))
        guard !offsetOverflow, !countOverflow,
              let snapshot = cache.store(data, at: chunkOffset) else {
            let error = NSError(
                domain: "PikPakPreviewCache",
                code: CocoaError.fileWriteUnknown.rawValue,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The downloaded preview bytes could not be retained in the temporary cache.",
                ]
            )
            requestsByTaskID.removeValue(forKey: dataTask.taskIdentifier)
            context.loadingRequest.finishLoading(with: error)
            dataTask.cancel()
            return
        }
        context.receivedNetworkBytes = receivedBytes
        publishCacheProgress(snapshot)

        if respondFromCache(
            to: context.loadingRequest,
            requestedEndOffset: requestedEndOffset(for: context.loadingRequest.dataRequest)
        ) {
            finish(dataTask: dataTask, context: context)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let context = requestsByTaskID.removeValue(
            forKey: task.taskIdentifier
        ) else { return }
        guard !context.loadingRequest.isCancelled,
              !context.loadingRequest.isFinished else { return }
        // The content length is commonly unknown when a request arrives and
        // known by the time its response ends. Reading it again here keeps a
        // response that stopped short of the resource from being reported as a
        // complete one, which would leave AVFoundation reading bytes that never
        // arrived.
        let requestedEnd = requestedEndOffset(for: context.loadingRequest.dataRequest)
        if respondFromCache(
            to: context.loadingRequest,
            requestedEndOffset: requestedEnd
        ) {
            publishCacheProgress(cache.snapshot)
            return
        }
        if let error {
            context.loadingRequest.finishLoading(with: error)
        } else if let requestedEnd,
                  nextOffset(for: context.loadingRequest.dataRequest) < requestedEnd {
            let truncated = NSError(
                domain: NSURLErrorDomain,
                code: NSURLErrorNetworkConnectionLost,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The media response ended before the requested byte range was complete.",
                ]
            )
            context.loadingRequest.finishLoading(with: truncated)
        } else {
            context.loadingRequest.finishLoading()
        }
        publishCacheProgress(cache.snapshot)
    }

    private func finish(dataTask: URLSessionDataTask, context: RequestContext) {
        requestsByTaskID.removeValue(forKey: dataTask.taskIdentifier)
        if !context.loadingRequest.isFinished {
            context.loadingRequest.finishLoading()
        }
        publishCacheProgress(cache.snapshot)
        dataTask.cancel()
    }

    private func populateContentInformation(
        _ information: AVAssetResourceLoadingContentInformationRequest?,
        metadata: PreviewResourceMetadata
    ) {
        guard let information else { return }

        var typeIdentifier = metadata.typeIdentifier
        if typeIdentifier == nil, !originalURL.pathExtension.isEmpty {
            typeIdentifier = UTType(filenameExtension: originalURL.pathExtension)?.identifier
        }
        if let allowed = information.allowedContentTypes, !allowed.isEmpty {
            if let resolvedType = typeIdentifier, !allowed.contains(resolvedType) {
                typeIdentifier = allowed.first
            } else if typeIdentifier == nil {
                typeIdentifier = allowed.first
            }
        }
        information.contentType = typeIdentifier
        if let contentLength = metadata.contentLength {
            information.contentLength = contentLength
        }
        information.isByteRangeAccessSupported = metadata.supportsByteRanges
    }

    private func nextOffset(
        for dataRequest: AVAssetResourceLoadingDataRequest?
    ) -> Int64 {
        guard let dataRequest else { return 0 }
        return max(dataRequest.currentOffset, dataRequest.requestedOffset, 0)
    }

    private func requestedEndOffset(
        for dataRequest: AVAssetResourceLoadingDataRequest?
    ) -> Int64? {
        guard let dataRequest else { return nil }
        if dataRequest.requestsAllDataToEndOfResource {
            return cache.contentMetadata.contentLength
        }
        let length = max(Int64(dataRequest.requestedLength), 0)
        let start = max(dataRequest.requestedOffset, 0)
        let (end, overflow) = start.addingReportingOverflow(length)
        return overflow ? Int64.max : end
    }

    /// Respond synchronously with every contiguous byte already retained. A
    /// cache hit finishes without creating another CDN request.
    private func respondFromCache(
        to loadingRequest: AVAssetResourceLoadingRequest,
        requestedEndOffset: Int64?
    ) -> Bool {
        guard !loadingRequest.isCancelled,
              !loadingRequest.isFinished,
              let dataRequest = loadingRequest.dataRequest else { return false }

        let maximumChunkLength = 1_048_576
        while !loadingRequest.isCancelled, !loadingRequest.isFinished {
            let offset = nextOffset(for: dataRequest)
            let remaining: Int
            if let requestedEndOffset {
                let byteCount = requestedEndOffset - offset
                if byteCount <= 0 {
                    loadingRequest.finishLoading()
                    return true
                }
                remaining = Int(min(Int64(maximumChunkLength), byteCount))
            } else {
                remaining = maximumChunkLength
            }

            guard let data = cache.read(at: offset, maximumLength: remaining),
                  !data.isEmpty else { break }
            dataRequest.respond(with: data)
            guard nextOffset(for: dataRequest) > offset else { break }
        }

        let offset = nextOffset(for: dataRequest)
        if let requestedEndOffset, offset >= requestedEndOffset {
            loadingRequest.finishLoading()
            return true
        }
        return false
    }

    private func responseMetadata(_ response: URLResponse) -> PreviewResourceMetadata {
        let typeIdentifier = response.mimeType.flatMap { UTType(mimeType: $0)?.identifier }
            ?? UTType(filenameExtension: originalURL.pathExtension)?.identifier

        guard let http = response as? HTTPURLResponse else {
            return PreviewResourceMetadata(
                typeIdentifier: typeIdentifier,
                contentLength: response.expectedContentLength >= 0
                    ? response.expectedContentLength
                    : nil,
                supportsByteRanges: true
            )
        }

        let acceptsRanges = (http.value(forHTTPHeaderField: "Accept-Ranges") ?? "")
            .lowercased().contains("bytes")
        let contentLength: Int64?
        if let total = contentRangeTotal(http) {
            contentLength = total
        } else if http.statusCode == 200, response.expectedContentLength >= 0 {
            contentLength = response.expectedContentLength
        } else {
            contentLength = nil
        }
        return PreviewResourceMetadata(
            typeIdentifier: typeIdentifier,
            contentLength: contentLength,
            supportsByteRanges: http.statusCode == 206 || acceptsRanges
        )
    }

    private func publishCacheProgress(
        _ snapshot: PreviewResourceCacheSnapshot
    ) {
        progressPublisher.publish(snapshot)
    }

    private func contentRangeStart(_ response: HTTPURLResponse) -> Int64? {
        guard let value = response.value(forHTTPHeaderField: "Content-Range"),
              let rangePart = value.split(separator: " ").last?.split(separator: "/").first,
              let startPart = rangePart.split(separator: "-").first else { return nil }
        return Int64(startPart)
    }

    private func contentRangeTotal(_ response: HTTPURLResponse) -> Int64? {
        guard let value = response.value(forHTTPHeaderField: "Content-Range"),
              let totalPart = value.split(separator: "/").last,
              totalPart != "*" else { return nil }
        return Int64(totalPart)
    }
}

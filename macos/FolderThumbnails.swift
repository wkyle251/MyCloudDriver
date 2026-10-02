import AppKit
import ImageIO
import SwiftUI

/// A single pool serves grid cells, the inspector and folder prefetch across
/// windows. Each URL/proxy pair has one transfer, even with multiple consumers.
/// Publishing individual images here would invalidate the entire file browser;
/// instead only the views awaiting that image receive its completion.
@MainActor
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    enum Priority: Int { case prefetch, visible }
    struct Key: Hashable {
        let url: URL
        let proxy: String
    }
    typealias Loader = (URL, String) async throws -> NSImage
    private struct Waiter {
        let priority: Priority
        let continuation: CheckedContinuation<NSImage, Error>
    }
    private final class Job {
        let id = UUID()
        var waiters: [UUID: Waiter] = [:]
        var task: Task<Void, Never>?
        var priority: Priority { waiters.values.contains { $0.priority == .visible } ? .visible : .prefetch }
    }
    private struct Cached {
        let image: NSImage
        let cost: Int
        var accessed: UInt64
    }
    private let load: Loader
    let concurrency: Int
    let prefetchConcurrency: Int
    private let memoryLimit: Int
    private var images: [Key: Cached] = [:]
    private var memoryUsed = 0
    private var clock: UInt64 = 0
    private var failures: [Key: Date] = [:]
    private var jobs: [Key: Job] = [:]
    private var queue: [Key] = []
    // Cancelled transports retain their slot until they actually finish.
    private var active: Set<UUID> = []

    init(concurrency: Int = 8, memoryLimit: Int = 96 * 1_024 * 1_024,
         load: @escaping Loader = ThumbnailTransport.load) {
        self.concurrency = max(1, concurrency)
        prefetchConcurrency = max(1, concurrency - 2)
        self.memoryLimit = max(0, memoryLimit)
        self.load = load
    }

    func image(at url: URL, proxyURL: String, priority: Priority = .visible) async throws -> NSImage {
        try Task.checkCancellation()
        let key = Key(url: url, proxy: PreviewTransport.effectiveProxyURL(proxyURL))
        clock &+= 1
        if var cached = images[key] {
            cached.accessed = clock
            images[key] = cached
            return cached.image
        }
        if let failed = failures[key], Date().timeIntervalSince(failed) < 20 {
            throw URLError(.resourceUnavailable)
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let job = jobs[key] ?? Job()
                if jobs[key] == nil { jobs[key] = job; queue.append(key) }
                job.waiters[waiterID] = Waiter(priority: priority, continuation: continuation)
                pump()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(key, waiterID: waiterID) }
        }
    }

    private func cancel(_ key: Key, waiterID: UUID) {
        guard let job = jobs[key], let waiter = job.waiters.removeValue(forKey: waiterID) else { return }
        waiter.continuation.resume(throwing: CancellationError())
        if job.waiters.isEmpty {
            jobs.removeValue(forKey: key)
            queue.removeAll { $0 == key }
            job.task?.cancel()
        }
        pump()
    }

    private func pump() {
        while active.count < concurrency {
            // Visible images jump ahead, with two slots reserved so an entire
            // folder cannot delay the image the user has just selected.
            let index = queue.firstIndex { jobs[$0]?.priority == .visible }
                ?? (active.count < prefetchConcurrency ? queue.indices.first : nil)
            guard let index else { return }
            let key = queue.remove(at: index)
            guard let job = jobs[key], job.task == nil else { continue }
            active.insert(job.id)
            let id = job.id, load = self.load
            job.task = Task { [weak self] in
                let result: Result<NSImage, Error>
                do { result = .success(try await AutomaticRecovery.read { try await load(key.url, key.proxy) }) }
                catch { result = .failure(error) }
                self?.finish(key, id: id, result: result)
            }
        }
    }

    private func finish(_ key: Key, id: UUID, result: Result<NSImage, Error>) {
        active.remove(id)
        defer { pump() }
        guard let job = jobs[key], job.id == id else { return }
        jobs.removeValue(forKey: key)
        switch result {
        case .success(let image):
            failures.removeValue(forKey: key)
            // NSCGImageSnapshotRep reports display-scaled dimensions on
            // Retina screens; count the actual decoded bitmap's allocation.
            let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            let cost = bitmap.map { $0.bytesPerRow * $0.height }
                ?? max(1, Int(image.size.width * image.size.height * 4))
            if cost <= memoryLimit {
                while memoryUsed + cost > memoryLimit || images.count >= 1_024 {
                    guard let oldest = images.min(by: { $0.value.accessed < $1.value.accessed }) else { break }
                    memoryUsed -= oldest.value.cost
                    images.removeValue(forKey: oldest.key)
                }
                clock &+= 1
                images[key] = Cached(image: image, cost: cost, accessed: clock)
                memoryUsed += cost
            }
        case .failure(let error):
            if !(error is CancellationError), (error as NSError).code != NSURLErrorCancelled {
                failures = failures.filter { Date().timeIntervalSince($0.value) < 20 }
                if failures.count >= 1_024 { failures.removeAll(keepingCapacity: true) }
                failures[key] = Date()
            }
        }
        for waiter in job.waiters.values { waiter.continuation.resume(with: result) }
    }
}

/// Reuse connections and HTTP caching. A thumbnail is one small request:
/// parallelism is across files, without extra byte-range requests per image.
@MainActor
enum ThumbnailTransport {
    private static var sessions: [String: URLSession] = [:]

    static func configuration(proxyURL: String) -> URLSessionConfiguration {
        let configuration = PreviewTransport.configuration(proxyURL: proxyURL)
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.urlCache = URLCache(memoryCapacity: 16 * 1_024 * 1_024,
                                          diskCapacity: 0, diskPath: nil)
        return configuration
    }

    static func load(_ url: URL, proxyURL: String) async throws -> NSImage {
        guard url.scheme?.lowercased() == "https" else { throw URLError(.unsupportedURL) }
        let proxy = PreviewTransport.effectiveProxyURL(proxyURL)
        let session: URLSession
        if let existing = sessions[proxy] { session = existing }
        else {
            // Proxy changes are rare; don't retain an unbounded set of pools.
            if sessions.count >= 4, let old = sessions.keys.first,
               let retired = sessions.removeValue(forKey: old) { retired.finishTasksAndInvalidate() }
            session = URLSession(configuration: configuration(proxyURL: proxy))
            sessions[proxy] = session
        }
        return try await load(url, using: session)
    }

    static func load(_ url: URL, using session: URLSession) async throws -> NSImage {
        guard url.scheme?.lowercased() == "https" else { throw URLError(.unsupportedURL) }
        var request = URLRequest(url: url)
        request.setValue("image/*, */*;q=0.5", forHTTPHeaderField: "Accept")
        let (file, response) = try await session.download(for: request, delegate: ThumbnailSizeLimit())
        defer { try? FileManager.default.removeItem(at: file) }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let bitmap = try await Task.detached(priority: .utility) {
            try ImagePreviewTransport.decodeBitmap(file, maximumPixelSize: 512)
        }.value
        try Task.checkCancellation()
        return NSImage(cgImage: bitmap, size: NSSize(width: bitmap.width, height: bitmap.height))
    }
}

private final class ThumbnailSizeLimit: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if max(totalBytesWritten, totalBytesExpectedToWrite) > 8 * 1_024 * 1_024 { downloadTask.cancel() }
    }
}

/// The clicked file's direct siblings, including pages not yet visible in the
/// outline. Page reads run independently from preview/expand/download helpers.
@MainActor
final class FolderThumbnailPrefetcher {
    struct Context: Equatable {
        let source: String
        let folderID: String
        let proxyURL: String
    }
    struct Page {
        let urls: [URL]
        let nextPageToken: String?
    }
    typealias PageLoader = (String) async throws -> Page
    private(set) var context: Context?
    private(set) var isRunning = false
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private let cache: ThumbnailCache

    init(cache: ThumbnailCache) { self.cache = cache }

    func start(context: Context, urls: [URL], nextPageToken: String?, loadPage: @escaping PageLoader) {
        guard self.context != context else { return }
        cancel()
        self.context = context
        isRunning = true
        let generation = self.generation, cache = self.cache
        task = Task { [weak self] in
            var page = Page(urls: urls, nextPageToken: nextPageToken)
            var visited = Set<String>(), seen = Set<URL>()
            do {
                while !Task.isCancelled {
                    let unique = page.urls.filter { seen.insert($0).inserted }
                    await Self.load(unique, cache: cache, proxy: context.proxyURL)
                    try Task.checkCancellation()
                    guard let token = page.nextPageToken, !token.isEmpty, visited.insert(token).inserted else { break }
                    page = try await AutomaticRecovery.read { try await loadPage(token) }
                }
            } catch {
                // A later click can retry a failed page without disturbing the
                // current preview or turning a thumbnail into a sign-in dialog.
                if self?.generation == generation { self?.context = nil }
            }
            if self?.generation == generation { self?.isRunning = false; self?.task = nil }
        }
    }

    private static func load(_ urls: [URL], cache: ThumbnailCache, proxy: String) async {
        await withTaskGroup(of: Void.self) { group in
            var remaining = urls.makeIterator()
            func add(_ url: URL) {
                group.addTask { _ = try? await cache.image(at: url, proxyURL: proxy, priority: .prefetch) }
            }
            for _ in 0..<cache.prefetchConcurrency {
                if let url = remaining.next() { add(url) }
            }
            while await group.next() != nil {
                if Task.isCancelled { group.cancelAll(); break }
                if let url = remaining.next() { add(url) }
            }
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel(); task = nil
        context = nil
        isRunning = false
    }

    deinit { task?.cancel() }
}

import AppKit

/// Grid, list and preview requests share decoded thumbnails. A folder warms
/// the same pool with one background reader, leaving capacity for selection.
@MainActor final class NativeThumbnailCache {
    static let shared = NativeThumbnailCache()
    enum Priority { case prefetch, visible }
    typealias Loader = (NativeMediaSourceIdentity) async -> NSImage?
    private struct Waiter {
        let priority: Priority
        let continuation: CheckedContinuation<NSImage?, Never>
    }
    private final class Job {
        let id = UUID()
        var waiters: [UUID: Waiter] = [:]
        var task: Task<Void, Never>?
        var visible: Bool { waiters.values.contains { $0.priority == .visible } }
    }
    private struct Cached {
        let image: NSImage
        let cost: Int
        var accessed: UInt64
    }
    private let load: Loader
    private let concurrency: Int
    private let memoryLimit: Int
    private let entryLimit: Int
    private var images: [NativeMediaSourceIdentity: Cached] = [:]
    private var failures: [NativeMediaSourceIdentity: Date] = [:]
    private var jobs: [NativeMediaSourceIdentity: Job] = [:]
    private var queue: [NativeMediaSourceIdentity] = []
    private var active = Set<UUID>()
    private var memoryUsed = 0
    private var clock: UInt64 = 0

    init(concurrency: Int = 3, memoryLimit: Int = 64 << 20, entryLimit: Int = 512,
         load: @escaping Loader = NativeThumbnailGenerator.load) {
        self.concurrency = max(2, concurrency); self.memoryLimit = max(0, memoryLimit)
        self.entryLimit = max(1, entryLimit); self.load = load
    }

    static func canLoad(_ identity: NativeMediaSourceIdentity) -> Bool {
        !identity.isFolder && ((identity.url != nil && identity.isDownloaded)
            || (identity.kind == .photos && identity.itemID.hasPrefix("asset:")))
    }

    func cachedImage(for identity: NativeMediaSourceIdentity) -> NSImage? {
        guard var cached = images[identity] else { return nil }
        clock &+= 1; cached.accessed = clock; images[identity] = cached
        return cached.image
    }

    func image(for identity: NativeMediaSourceIdentity, priority: Priority = .visible) async -> NSImage? {
        guard !Task.isCancelled, Self.canLoad(identity) else { return nil }
        if let image = cachedImage(for: identity) { return image }
        if let failed = failures[identity], Date().timeIntervalSince(failed) < 20 { return nil }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let job = jobs[identity] ?? Job()
                if jobs[identity] == nil { jobs[identity] = job; queue.append(identity) }
                job.waiters[waiterID] = Waiter(priority: priority, continuation: continuation)
                pump()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(identity, waiterID: waiterID) }
        }
    }

    private func cancel(_ identity: NativeMediaSourceIdentity, waiterID: UUID) {
        guard let job = jobs[identity], let waiter = job.waiters.removeValue(forKey: waiterID) else { return }
        waiter.continuation.resume(returning: nil)
        if job.waiters.isEmpty {
            jobs.removeValue(forKey: identity); queue.removeAll { $0 == identity }
            job.task?.cancel()
        }
        // A cancelled reader keeps its slot until it actually stops.
        pump()
    }

    private func pump() {
        while active.count < concurrency {
            let index = queue.firstIndex { jobs[$0]?.visible == true }
                ?? (active.isEmpty ? queue.indices.first : nil)
            guard let index else { return }
            let identity = queue.remove(at: index)
            guard let job = jobs[identity], job.task == nil else { continue }
            let id = job.id, load = self.load
            active.insert(id)
            job.task = Task(priority: job.visible ? .userInitiated : .utility) { [weak self] in
                let image = await load(identity)
                self?.finish(identity, id: id, image: Task.isCancelled ? nil : image)
            }
        }
    }

    private func finish(_ identity: NativeMediaSourceIdentity, id: UUID, image: NSImage?) {
        active.remove(id)
        defer { pump() }
        guard let job = jobs[identity], job.id == id else { return }
        jobs.removeValue(forKey: identity)
        if let image {
            failures.removeValue(forKey: identity)
            let bitmap = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            let cost = bitmap.map { $0.bytesPerRow * $0.height }
                ?? max(1, Int(image.size.width * image.size.height * 4))
            if cost <= memoryLimit {
                while memoryUsed + cost > memoryLimit || images.count >= entryLimit {
                    guard let oldest = images.min(by: { $0.value.accessed < $1.value.accessed }) else { break }
                    memoryUsed -= oldest.value.cost; images.removeValue(forKey: oldest.key)
                }
                clock &+= 1; images[identity] = Cached(image: image, cost: cost, accessed: clock)
                memoryUsed += cost
            }
        } else {
            failures = failures.filter { Date().timeIntervalSince($0.value) < 20 }
            if failures.count >= entryLimit { failures.removeAll(keepingCapacity: true) }
            failures[identity] = Date()
        }
        for waiter in job.waiters.values { waiter.continuation.resume(returning: image) }
    }
}

/// Only direct siblings are prefetched, including the folder's remaining
/// metadata pages. Navigation cancels this consumer without cancelling a
/// thumbnail still requested by a visible cell or another window.
@MainActor final class NativeFolderThumbnailPrefetcher {
    struct Context: Equatable {
        let kind: CloudDriveKind
        let rootID: String
        let folderID: String
        let query: String
    }
    struct Page {
        let items: [CloudDriveItem]
        let nextOffset: Int?
    }
    private(set) var context: Context?
    private(set) var isRunning = false
    private let cache: NativeThumbnailCache
    /// The cache keeps only a few hundred images, so warming more of a big folder would evict what it just
    /// loaded, and on a network share read every file to do it. What scrolls into view loads on demand.
    private let maximumLoads: Int
    private var task: Task<Void, Never>?
    private var generation = UUID()

    init(cache: NativeThumbnailCache, maximumLoads: Int = 256) {
        self.cache = cache
        self.maximumLoads = max(1, maximumLoads)
    }

    /// The folder's files starting at the selected one and wrapping, so warming begins where the user is.
    static func order(_ items: [CloudDriveItem], startingAt id: String?) -> [CloudDriveItem] {
        guard let id, let start = items.firstIndex(where: { $0.id == id }), start > 0 else { return items }
        return Array(items[start...]) + Array(items[..<start])
    }

    func start(context: Context, items: [CloudDriveItem], nextOffset: Int?,
               loadPage: @escaping (Int) async throws -> Page) {
        guard self.context != context else { return }
        cancel(); self.context = context; isRunning = true
        let generation = self.generation, cache = self.cache, maximumLoads = self.maximumLoads
        task = Task { [weak self] in
            var page = Page(items: items, nextOffset: nextOffset)
            var seen = Set<NativeMediaSourceIdentity>(), offsets = Set<Int>()
            do {
                while !Task.isCancelled {
                    for item in page.items {
                        try Task.checkCancellation()
                        let identity = NativeMediaSourceIdentity(item: item, kind: context.kind, rootID: context.rootID)
                        if NativeThumbnailCache.canLoad(identity), seen.insert(identity).inserted {
                            _ = await cache.image(for: identity, priority: .prefetch)
                            if seen.count >= maximumLoads { page = Page(items: [], nextOffset: nil); break }
                        }
                    }
                    try Task.checkCancellation()
                    guard let offset = page.nextOffset, offset > 0, offsets.insert(offset).inserted else { break }
                    page = try await loadPage(offset)
                }
            } catch {
                if self?.generation == generation { self?.context = nil }
            }
            if self?.generation == generation { self?.isRunning = false; self?.task = nil }
        }
    }

    func cancel() {
        generation = UUID(); task?.cancel(); task = nil; context = nil; isRunning = false
    }
    deinit { task?.cancel() }
}

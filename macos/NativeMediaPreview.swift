import AVFoundation
import Combine
import SwiftUI

/// A provider ID alone cannot distinguish a replaced local file or a source
/// rebound after reconnect. Views use the same key before deferred tasks run.
struct NativeMediaSourceIdentity: Hashable {
    let kind: CloudDriveKind
    let rootID: String?
    let itemID: String
    let name: String
    let url: URL?
    let revision: String?
    let modified: Date?
    let bytes: UInt64?
    let mediaType: String
    let isFolder: Bool
    let isDownloaded: Bool

    init(item: CloudDriveItem, kind: CloudDriveKind, rootID: String? = nil) {
        self.kind = kind; self.rootID = rootID
        itemID = item.id; name = item.name; url = item.url
        revision = item.revision; modified = item.modified; bytes = item.bytes
        mediaType = item.mediaType; isFolder = item.isFolder; isDownloaded = item.isDownloaded
    }
    func matches(_ item: CloudDriveItem) -> Bool {
        self == Self(item: item, kind: kind, rootID: rootID)
    }
}

enum NativeMediaBufferSource: Equatable {
    case cloud(CloudDriveKind), volume(ExternalVolume.Kind)

    static func source(kind: CloudDriveKind, volume: ExternalVolume.Kind?) -> Self? {
        kind == .local ? volume.map(Self.volume) : .cloud(kind)
    }
    var title: String {
        switch self {
        case .cloud(let kind): return kind.title
        case .volume(.externalDisk): return "External disk"
        case .volume(.networkShare): return "Network share"
        }
    }
}

/// Provider originals and compatible copies can require local preparation.
/// This tracks their availability separately from the shared loader's retained RAM ranges.
struct NativeMediaSourceBufferStatus: Equatable {
    enum Phase: Equatable { case loading, available, failed }
    let source: NativeMediaBufferSource
    var phase = Phase.loading
    var fraction: Double?
    var receivedBytes: UInt64?
    var totalBytes: UInt64?
    /// Nil when the provider has not reported byte counts; a percentage alone cannot establish throughput.
    var bytesPerSecond: Double?
    var message: String
    var title: String {
        switch phase {
        case .loading: return "Buffering"
        case .available: return "Fully buffered"
        case .failed: return "Buffer unavailable"
        }
    }
}

/// Prioritize the selected media, then buffer visible successors; cancellation never deletes a
/// user's iCloud original, nor a staging directory with a writer still active.
@MainActor final class NativeMediaPreviewModel: ObservableObject {
    let playback: MediaPlaybackController
    @Published private(set) var message = "Preparing preview…"
    @Published private(set) var fraction: Double?
    @Published private(set) var failure: String?
    @Published private(set) var ready = false
    @Published private(set) var bufferStatus: FilePreviewBufferStatus?
    @Published private(set) var sourceBufferStatus: NativeMediaSourceBufferStatus?
    private(set) var bufferSource: ExternalVolume.Kind?
    private(set) var memorySource: NativeMediaBufferSource?
    /// A repackaged or converted copy is being made, which can take a while: another player is offered meanwhile.
    @Published private(set) var isPreparingCopy = false
    private var generation = UUID()
    private var ownedDirectory: NativePreviewDirectory?
    private var task: Task<Void, Never>?
    private var aviCopy: VideoPreviewCopy?
    private var sourceURL: URL?
    private var sourceProvider: (any NativeCloudDrive)?
    /// The file being previewed, where it is, once it has been materialized.
    var originalURL: URL? { sourceURL }
    private(set) var itemID: String?
    private(set) var sourceIdentity: NativeMediaSourceIdentity?
    /// Volume classification supplies the source label; all media use the same RAM budget.
    var bufferedVolume: @Sendable (URL) -> ExternalVolume.Kind? = { ExternalVolume.bufferedKind($0) }
    var preparationTimeout: TimeInterval = 30
    var materializationTimeout: TimeInterval = 300
    var selectionDelayNanoseconds: UInt64 = 80_000_000
    private var sourceContainer: MediaContainer?
    var memoryBudget: Int64 = .max
    var memoryBlockSize = 1 << 20
    var memoryIO = FilePreviewResourceLoader.IO()
    /// Read-ahead fills the shared RAM allowance, independently of playback.
    var memoryReadAheadBytes: Int64 = .max
    private(set) var memoryLoader: FilePreviewResourceLoader?
    private var memoryBufferAttached = false
    private var bufferStatusTask: Task<Void, Never>?
    private var sourceProgressID = UUID()
    private var sourceReadActivity = FilePreviewReadActivity()
    private var sourceProgressActivity: CloudDriveProgress.Activity?
    private var sourceRateTask: Task<Void, Never>?
    /// How the playing copy was made when the original could not be played as it is.
    enum Preparation: Equatable { case repackaged, transcoded }
    private(set) var preparation: Preparation?
    /// Recover a video reader that remains unopened this long without read progress.
    /// Slow but advancing sources keep their chance to open.
    var openTimeout: TimeInterval = 8
    var openStatus: (AVPlayer) -> AVPlayerItem.Status = { $0.currentItem?.status ?? .unknown }
    private var openWatchdog: Task<Void, Never>?
    private struct BufferedFile {
        let loader: FilePreviewResourceLoader
        let source: NativeMediaBufferSource
        let originalURL: URL
        let directory: NativePreviewDirectory?
        let container: MediaContainer?
        let copy: VideoPreviewCopy?
        let preparation: Preparation?
    }
    private let retiredBuffers = PreviewBufferRetention<NativeMediaSourceIdentity, BufferedFile> { $0.loader.invalidate() }
    var nextItems: (() -> [(CloudDriveItem, any NativeCloudDrive)])?
    var bufferingContext: (() -> String?)?
    private var nextBufferIdentity: NativeMediaSourceIdentity?
    private var nextBuffer: BufferedFile?
    private var nextBufferTask: Task<Void, Never>?
    private var queuedBuffers: [NativeMediaSourceIdentity: BufferedFile] = [:]
    private var nextBufferOrder: [NativeMediaSourceIdentity] = []
    private var nextBufferOwner: NativeMediaSourceIdentity?
    private var nextBufferContext: String?
    private var failedNextBuffers = Set<NativeMediaSourceIdentity>()
    private var nextBufferRequest = UUID()
    private var pendingBufferedFile: (NativeMediaSourceIdentity, BufferedFile)?
    #if FINDER_WORKSPACE_TESTS
    var prefetchedItemID: String? { nextBufferOrder.first(where: { queuedBuffers[$0] != nil || nextBufferIdentity == $0 })?.itemID }
    var prefetchedLoader: FilePreviewResourceLoader? { nextBufferOrder.compactMap { queuedBuffers[$0]?.loader ?? (nextBufferIdentity == $0 ? nextBuffer?.loader : nil) }.first }
    var prefetchedLoaders: [String: FilePreviewResourceLoader] {
        var result = Dictionary(uniqueKeysWithValues: queuedBuffers.map { ($0.key.itemID, $0.value.loader) })
        if let nextBufferIdentity, let nextBuffer { result[nextBufferIdentity.itemID] = nextBuffer.loader }
        return result
    }
    #endif
    init(settings: MediaPlaybackSettings) { playback = MediaPlaybackController(settings: settings) }

    func prepare(_ item: CloudDriveItem, provider: any NativeCloudDrive, force: Bool = false) {
        let identity = NativeMediaSourceIdentity(item: item, kind: provider.kind, rootID: provider.root.id)
        guard identity != sourceIdentity || force else { return }
        let retained: BufferedFile?
        if !force, nextBufferIdentity == identity {
            retained = nextBuffer; nextBuffer = nil; stopNextBuffer(retaining: false)
        } else { retained = force ? nil : queuedBuffers.removeValue(forKey: identity) ?? retiredBuffers.take(identity) }
        clear(preservingRAM: true, keeping: identity)
        if force { retiredBuffers.remove(identity) }
        itemID = item.id; sourceIdentity = identity
        sourceProvider = provider
        if let retained { pendingBufferedFile = (identity, retained) }
        if provider.kind != .local, !item.isFolder, item.mediaType == "video" || item.mediaType == "audio" {
            sourceBufferStatus = .init(source: .cloud(provider.kind), totalBytes: item.bytes, message: "Preparing preview…")
        }
        let request = generation, delay = selectionDelayNanoseconds
        task = Task { [weak self] in
            // Coalesce held arrow keys before touching a new source. The old
            // player is hidden immediately, and cancellation never waits for IO.
            do { if delay > 0 { try await Task.sleep(nanoseconds: delay) } }
            catch { return }
            if let retained { await self?.loadBuffered(retained, item: item, provider: provider, request: request) }
            else { await self?.load(item, provider: provider, request: request) }
        }
    }
    func matches(_ item: CloudDriveItem, provider: any NativeCloudDrive) -> Bool {
        sourceIdentity == NativeMediaSourceIdentity(item: item, kind: provider.kind, rootID: provider.root.id)
    }
    private func load(_ item: CloudDriveItem, provider: any NativeCloudDrive, request: UUID) async {
        guard generation == request, !Task.isCancelled else { return }
        let directory = NativePreviewDirectory(FileManager.default.temporaryDirectory
            .appendingPathComponent("MyCloudDriver-Media-\(UUID().uuidString)", isDirectory: true))
        defer { withExtendedLifetime(directory) {} }
        let preparingMessage = provider.kind == .photos ? "Preparing media from Photos…"
            : provider.kind == .local ? "Opening local media…" : "Loading from \(provider.kind.title)…"
        message = preparingMessage
        let timeout = preparationTimeout
        do {
            try await NativeFileWork.run(timeout: timeout, priority: .high) {
                try CloudDriveFiles.privateDirectory(directory.url)
            }
            try Task.checkCancellation()
            guard generation == request else { return }
            let materializeLimit = provider.kind == .local && item.isDownloaded ? timeout : materializationTimeout
            let url = try await NativeFileWork.asyncRun(timeout: materializeLimit) { [weak self] in
                try await AutomaticRecovery.read(onRetry: { [weak self] _, delay in
                    guard let self, self.generation == request else { return }
                    self.message = "Retrying preview in \(Int(delay))s…"
                    self.stopSourceProgress()
                    self.sourceBufferStatus?.message = "Retrying preview in \(Int(delay))s…"
                }) {
                    guard let progress = await self?.sourceProgressHandler(request: request, message: preparingMessage) else {
                        throw CancellationError()
                    }
                    try Task.checkCancellation()
                    return try await provider.materialize(item, directory: directory.url, progress: progress)
                }
            }
            try Task.checkCancellation()
            guard generation == request else { return }
            let classify = bufferedVolume, local = provider.kind == .local
            let metadata = try await NativeFileWork.run(timeout: timeout, priority: .high) {
                let volume = local ? classify(url) : nil
                let container = MediaContainer.sniff(url)
                let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { UInt64(max(0, $0)) }
                return (volume, container, bytes)
            }
            try Task.checkCancellation()
            guard generation == request else { return }
            let volume = metadata.0, container = metadata.1
            sourceContainer = container
            var availableBytes = metadata.2
            if local {
                sourceBufferStatus = volume.map { .init(source: .volume($0), totalBytes: item.bytes, message: preparingMessage) }
            }
            let isAVI = container.map { $0 == .avi } ?? ((item.name as NSString).pathExtension.lowercased() == "avi")
            let playableURL: URL
            if isAVI {
                let (copy, kind) = try await makeCopy(from: url, format: .avi, repackageFirst: true, request: request)
                try Task.checkCancellation()
                guard generation == request else { return }
                aviCopy = copy; preparation = kind; playableURL = copy.url
                availableBytes = try await NativeFileWork.run(timeout: timeout) {
                    (try? copy.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { UInt64(max(0, $0)) }
                }
                try Task.checkCancellation()
                guard generation == request else { return }
            } else { playableURL = url }
            sourceURL = url
            ownedDirectory = directory
            let named = aviCopy == nil ? container.flatMap { $0.matches(fileExtension: url.pathExtension) ? nil : $0 } : nil
            if let player = try await bufferedPlayer(for: item, provider: provider, url: playableURL, container: named, volume: volume, request: request) {
                playback.attach(player); memoryBufferAttached = true
                if let loader = memoryLoader {
                    playback.updateMemoryBuffer(loader.snapshot)
                    loader.setReadingAhead(true)
                }
            } else {
                let player = try await NativeFileWork.run(timeout: timeout, priority: .high) {
                    let playerURL = try Self.correctlyNamed(playableURL, as: named, in: directory.url)
                    return AVPlayer(url: playerURL)
                }
                try Task.checkCancellation()
                guard generation == request else { return }
                playback.attach(player)
            }
            finishSourceProgress(availableURL: playableURL, availableBytes: availableBytes)
            ready = true
            // A damaged index or unsupported reader can stay unknown indefinitely,
            // even when most of a file is in RAM.
            if aviCopy == nil, item.mediaType == "video", let player = playback.player {
                watchOpening(player, item: item, request: request)
            }
        } catch {
            guard generation == request, !Task.isCancelled else { return }
            releaseMemoryBuffer()
            finishSourceProgress(availableURL: nil)
            failure = error.localizedDescription
        }
    }

    /// A player that reads `url` through RAM, or nil for non-media items. The
    /// start and end of the file are read first, with progress, so playback starts from memory instead of waiting on it.
    private func bufferedPlayer(for item: CloudDriveItem, provider: any NativeCloudDrive, url: URL, container: MediaContainer?,
                                volume: ExternalVolume.Kind?, request: UUID,
                                reusing: FilePreviewResourceLoader? = nil) async throws -> AVPlayer? {
        guard item.mediaType == "video" || item.mediaType == "audio" else { return nil }
        let budget = memoryBudget, blockSize = memoryBlockSize, ahead = memoryReadAheadBytes, io = memoryIO
        let snapshot: @MainActor (PreviewResourceCacheSnapshot) -> Void = { [weak self] value in
            guard let self, self.generation == request, self.memoryBufferAttached else { return }
            self.playback.updateMemoryBuffer(value)
        }
        let loader: FilePreviewResourceLoader
        if let reusing { loader = reusing }
        else {
            loader = try await NativeFileWork.run(timeout: preparationTimeout, priority: .high) {
                try FilePreviewResourceLoader(fileURL: url, contentType: container?.contentType,
                    budgetBytes: budget, blockSize: blockSize, readAheadBytes: ahead, io: io, onSnapshot: snapshot)
            }
        }
        guard generation == request, !Task.isCancelled else { loader.invalidate(); throw CancellationError() }
        memoryLoader = loader
        loader.setCachePriority(1)
        bufferSource = volume
        memorySource = volume.map(NativeMediaBufferSource.volume) ?? .cloud(provider.kind)
        updateBufferStatus(loader)
        // Keep speed and the idle state current even when the retained ranges do not change (a full RAM window,
        // a slow read, or paused playback). One update per quarter second, only for the selected preview.
        bufferStatusTask = Task { [weak self, weak loader] in
            while !Task.isCancelled {
                guard let loader, self?.generation == request, self?.memoryLoader === loader else { return }
                self?.updateBufferStatus(loader)
                self?.refreshNextBuffer()
                do { try await Task.sleep(nanoseconds: 250_000_000) }
                catch { return }
            }
        }
        message = volume?.bufferingMessage ?? "Buffering from \(provider.kind.title)…"; fraction = 0
        do {
            // The player needs the header/index, not a fixed 18 MB admission
            // window. Fetch one block at each end, then let its range requests
            // take priority over whole-file read-ahead, even on a slow share.
            try await loader.prime(headBlocks: 1, tailBlocks: 1, noProgressTimeout: preparationTimeout, invalidateOnCancel: false) { [weak self] value in
                Task { @MainActor in
                    guard let self, self.generation == request else { return }
                    self.fraction = value
                }
            }
            // Superseded while buffering: end quietly, and never fall back to reading the disk directly.
            try Task.checkCancellation()
            guard generation == request else { throw CancellationError() }
            updateBufferStatus(loader)
        } catch {
            if generation == request { loader.invalidate() }
            if memoryLoader === loader {
                updateBufferStatus(loader)
                bufferStatusTask?.cancel(); bufferStatusTask = nil
                memoryLoader = nil
            }
            throw error
        }
        let player = try await NativeFileWork.run(timeout: preparationTimeout, priority: .high) {
            let asset = AVURLAsset(url: loader.assetURL)
            asset.resourceLoader.setDelegate(loader, queue: loader.delegateQueue)
            return AVPlayer(playerItem: AVPlayerItem(asset: asset))
        }
        try Task.checkCancellation()
        guard generation == request else { throw CancellationError() }
        return player
    }
    private func updateBufferStatus(_ loader: FilePreviewResourceLoader) {
        let status = loader.status
        if bufferStatus != status { bufferStatus = status }
        if memoryBufferAttached, playback.memoryBuffer != status.cache { playback.updateMemoryBuffer(status.cache) }
    }
    private func loadBuffered(_ retained: BufferedFile, item: CloudDriveItem, provider: any NativeCloudDrive, request: UUID) async {
        guard generation == request, !Task.isCancelled else { retained.loader.invalidate(); return }
        pendingBufferedFile = nil
        sourceURL = retained.originalURL; ownedDirectory = retained.directory; sourceContainer = retained.container
        aviCopy = retained.copy; preparation = retained.preparation
        let volume: ExternalVolume.Kind?
        if case .volume(let kind) = retained.source { volume = kind } else { volume = nil }
        do {
            if let player = try await bufferedPlayer(for: item, provider: provider, url: retained.originalURL,
                container: retained.container, volume: volume, request: request, reusing: retained.loader) {
                try Task.checkCancellation()
                guard generation == request else { return }
                playback.attach(player); memoryBufferAttached = true; retained.loader.setReadingAhead(true)
                finishSourceProgress(availableURL: retained.originalURL,
                    availableBytes: retained.loader.snapshot.contentLength.map { UInt64(max(0, $0)) })
                updateBufferStatus(retained.loader); ready = true
                if item.mediaType == "video" { watchOpening(player, item: item, request: request) }
            }
        } catch {
            if generation == request { retained.loader.invalidate() }
            guard generation == request, !Task.isCancelled else { return }
            failure = error.localizedDescription
        }
    }

    private func bufferContext(for identity: NativeMediaSourceIdentity) -> String {
        bufferingContext?() ?? "\(identity.kind.rawValue)|\(identity.rootID ?? "")"
    }
    /// Detach the active speculative reader without discarding already downloaded bytes.
    private func stopNextBuffer(retaining: Bool) {
        nextBufferRequest = UUID()
        nextBufferTask?.cancel(); nextBufferTask = nil
        if let nextBuffer {
            nextBuffer.loader.setReadingAhead(false)
            if retaining, let nextBufferIdentity { queuedBuffers[nextBufferIdentity] = nextBuffer }
            else { nextBuffer.loader.invalidate() }
        }
        nextBuffer = nil; nextBufferIdentity = nil
    }
    private func cancelNextBuffer(unless identity: NativeMediaSourceIdentity? = nil) {
        if let identity, !identity.isFolder, identity.mediaType == "video" || identity.mediaType == "audio",
           nextBufferContext == bufferContext(for: identity) {
            stopNextBuffer(retaining: true)
            return
        }
        stopNextBuffer(retaining: false)
        for buffer in queuedBuffers.values { buffer.loader.invalidate() }
        queuedBuffers.removeAll(); nextBufferOrder = []; failedNextBuffers = []
        nextBufferOwner = nil; nextBufferContext = nil
    }
    private func refreshNextBuffer() {
        guard let owner = sourceIdentity else { return }
        var seen = Set<NativeMediaSourceIdentity>()
        let candidates = (nextItems?() ?? []).compactMap { item, provider -> (CloudDriveItem, any NativeCloudDrive, NativeMediaSourceIdentity)? in
            let id = NativeMediaSourceIdentity(item: item, kind: provider.kind, rootID: provider.root.id)
            guard id != owner, !item.isFolder, (item.mediaType == "video" || item.mediaType == "audio"), seen.insert(id).inserted else { return nil }
            return (item, provider, id)
        }
        let order = candidates.map { $0.2 }, context = bufferContext(for: owner)
        // A new filter/sort can change which file is next. Restart in that visible
        // order; moving to a later file in the same folder preserves its successors.
        if nextBufferContext != context || (nextBufferOwner == owner && nextBufferOrder != order) {
            cancelNextBuffer()
        }
        nextBufferContext = context; nextBufferOwner = owner; nextBufferOrder = order
        let desired = Set(order)
        if let nextBufferIdentity, !desired.contains(nextBufferIdentity) { stopNextBuffer(retaining: false) }
        for id in Array(queuedBuffers.keys) where !desired.contains(id) {
            queuedBuffers.removeValue(forKey: id)?.loader.invalidate()
        }
        failedNextBuffers.formIntersection(desired)
        guard memoryLoader?.snapshot.fraction == 1 else {
            nextBuffer?.loader.setReadingAhead(false)
            return
        }
        if let nextBuffer, nextBuffer.loader.status.failed {
            if let nextBufferIdentity { failedNextBuffers.insert(nextBufferIdentity) }
            stopNextBuffer(retaining: false)
        } else if nextBuffer?.loader.snapshot.fraction == 1 {
            stopNextBuffer(retaining: true)
        }
        if nextBufferIdentity != nil {
            nextBuffer?.loader.setReadingAhead(true)
            return
        }
        guard PreviewMemoryBudget.shared.permitsReadAhead,
              let (item, provider, identity) = candidates.first(where: {
                  !failedNextBuffers.contains($0.2) && queuedBuffers[$0.2]?.loader.snapshot.fraction != 1
              }) else { return }
        nextBufferIdentity = identity
        if let retained = queuedBuffers.removeValue(forKey: identity) {
            nextBuffer = retained; retained.loader.setReadingAhead(true)
            return
        }
        let request = UUID(); nextBufferRequest = request
        let classify = bufferedVolume, budget = memoryBudget, blockSize = memoryBlockSize, io = memoryIO
        nextBufferTask = Task { [weak self] in
            let directory = NativePreviewDirectory(FileManager.default.temporaryDirectory
                .appendingPathComponent("MyCloudDriver-NextMedia-\(UUID().uuidString)", isDirectory: true))
            defer { withExtendedLifetime(directory) {} }
            do {
                try await NativeFileWork.run { try CloudDriveFiles.privateDirectory(directory.url) }
                let url = try await NativeFileWork.asyncRun(timeout: self?.materializationTimeout ?? 300) {
                    try await provider.materialize(item, directory: directory.url, progress: { _ in })
                }
                try Task.checkCancellation()
                let prepared = try await NativeFileWork.run {
                    let container = MediaContainer.sniff(url)
                    let loader = try FilePreviewResourceLoader(fileURL: url, contentType: container?.contentType,
                        budgetBytes: budget, blockSize: blockSize, io: io)
                    loader.setCachePriority(0)
                    let source = (provider.kind == .local ? classify(url) : nil).map(NativeMediaBufferSource.volume)
                        ?? .cloud(provider.kind)
                    return BufferedFile(loader: loader, source: source, originalURL: url, directory: directory,
                        container: container, copy: nil, preparation: nil)
                }
                guard let self, !Task.isCancelled, self.nextBufferRequest == request,
                      self.nextBufferIdentity == identity else { prepared.loader.invalidate(); return }
                self.nextBuffer = prepared
                if self.memoryLoader?.snapshot.fraction == 1 { prepared.loader.setReadingAhead(true) }
            } catch {
                guard let self, !Task.isCancelled, self.nextBufferRequest == request else { return }
                self.failedNextBuffers.insert(identity); self.stopNextBuffer(retaining: false)
            }
        }
    }
    private func stopSourceProgress() {
        sourceProgressID = UUID()
        sourceRateTask?.cancel(); sourceRateTask = nil
        sourceReadActivity.end()
        if sourceBufferStatus?.bytesPerSecond != nil { sourceBufferStatus?.bytesPerSecond = 0 }
    }
    private func sourceProgressHandler(request: UUID, message: String, makingCopy: Bool = false) -> CloudDriveProgressHandler {
        guard generation == request else { return { _ in } }
        stopSourceProgress()
        let phase = sourceProgressID
        self.message = message; fraction = nil
        sourceReadActivity = FilePreviewReadActivity()
        sourceReadActivity.begin(at: ProcessInfo.processInfo.systemUptime)
        sourceProgressActivity = nil
        if var status = sourceBufferStatus {
            status.phase = .loading; status.fraction = nil; status.receivedBytes = nil; status.bytesPerSecond = nil
            status.message = message
            if makingCopy { status.totalBytes = nil }
            sourceBufferStatus = status
            sourceRateTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard self?.generation == request, self?.sourceProgressID == phase else { return }
                    self?.updateSourceRate()
                    do { try await Task.sleep(nanoseconds: 250_000_000) }
                    catch { return }
                }
            }
        }
        return { [weak self] progress in
            Task { @MainActor in
                guard let self, self.generation == request, self.sourceProgressID == phase else { return }
                guard !(self.sourceProgressActivity == .processing && progress.activity == .transferring) else { return }
                if let activity = progress.activity { self.sourceProgressActivity = activity }
                self.message = progress.message
                if progress.activity == .processing { self.fraction = nil }
                if let value = progress.fraction, value.isFinite { self.fraction = min(1, max(0, value)) }
                guard var status = self.sourceBufferStatus else { return }
                status.message = progress.message
                if progress.activity == .processing {
                    self.sourceReadActivity.end()
                    status.fraction = nil; status.receivedBytes = nil; status.totalBytes = nil; status.bytesPerSecond = nil
                }
                if let value = progress.fraction, value.isFinite { status.fraction = min(1, max(0, value)) }
                if progress.fileSize > 0 { status.totalBytes = progress.fileSize }
                if progress.bytes > 0 || progress.activity == .transferring {
                    let previous = status.receivedBytes ?? 0
                    if progress.bytes > previous {
                        self.sourceReadActivity.record(bytes: Int(clamping: progress.bytes - previous),
                            at: ProcessInfo.processInfo.systemUptime)
                    }
                    let received = max(previous, progress.bytes)
                    status.receivedBytes = received
                    if let total = status.totalBytes, total > 0 {
                        status.fraction = min(1, Double(received) / Double(total))
                    }
                    status.bytesPerSecond = self.sourceReadActivity.bytesPerSecond(at: ProcessInfo.processInfo.systemUptime)
                }
                self.sourceBufferStatus = status
            }
        }
    }
    private func updateSourceRate() {
        guard var status = sourceBufferStatus, status.receivedBytes != nil else { return }
        let rate = sourceReadActivity.bytesPerSecond(at: ProcessInfo.processInfo.systemUptime)
        if status.bytesPerSecond != rate { status.bytesPerSecond = rate; sourceBufferStatus = status }
    }
    private func finishSourceProgress(availableURL: URL?, availableBytes: UInt64? = nil) {
        stopSourceProgress()
        guard var status = sourceBufferStatus else { return }
        status.phase = availableURL == nil ? .failed : .available
        status.bytesPerSecond = 0
        status.message = "The preview could not be buffered. Use Retry Preview to try again."
        if availableURL != nil {
            status.fraction = 1; status.message = "Preview available on this Mac."
            if let availableBytes {
                status.receivedBytes = availableBytes; status.totalBytes = availableBytes
            }
        }
        sourceBufferStatus = status
    }
    /// The file as the player should see it. When its name disagrees with its content, a link with the right
    /// extension in the preview's private folder: the original is neither moved nor renamed, and the link goes
    /// with the preview.
    nonisolated private static func correctlyNamed(_ url: URL, as container: MediaContainer?, in directory: URL) throws -> URL {
        guard let container else { return url }
        let link = directory.appendingPathComponent("media.\(container.canonicalExtension)")
        try? FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        return link
    }
    /// A playable copy: repackaged without re-encoding where that works, which takes seconds because it only reads
    /// the file; otherwise converted, which is a real conversion.
    private func makeCopy(from source: URL, format: VideoPreviewPreparation.InputFormat, repackageFirst: Bool,
                          request: UUID) async throws -> (VideoPreviewCopy, Preparation) {
        let report = sourceProgressHandler(request: request, message: "Preparing compatible video preview…", makingCopy: true)
        isPreparingCopy = true
        defer { if generation == request { isPreparingCopy = false } }
        if repackageFirst {
            do { return (try await VideoPreviewPreparation.prepare(source: source, format: format, mode: .repackage, progress: report), .repackaged) }
            catch is CancellationError { throw CancellationError() }
            catch { /* Its reason matters only if the conversion fails as well. */ }
        }
        return (try await VideoPreviewPreparation.prepare(source: source, format: format, mode: .transcode, progress: report), .transcoded)
    }

    private func watchOpening(_ player: AVPlayer, item: CloudDriveItem, request: UUID) {
        openWatchdog?.cancel()
        openWatchdog = Task { [weak self, weak player] in
            let timeout = self?.openTimeout ?? 8
            var lastProgress = Date(), previousBytes: Int64 = 0
            while Date().timeIntervalSince(lastProgress) < timeout {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled, let self, let player, self.generation == request, self.playback.player === player else { return }
                let status = self.openStatus(player)
                if status != .unknown { return }
                let bytes = self.memoryLoader?.status.bytesRead ?? 0
                if bytes > previousBytes { previousBytes = bytes; lastProgress = Date() }
            }
            guard !Task.isCancelled, let self, let player, self.generation == request, self.playback.player === player else { return }
            self.recoverVideo(NSError(domain: AVFoundationErrorDomain, code: AVError.Code.fileFormatNotRecognized.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "The player did not finish opening this file."]), player: player, item: item)
        }
    }
    private func releaseMemoryBuffer() {
        bufferStatusTask?.cancel(); bufferStatusTask = nil
        bufferStatus = nil; bufferSource = nil; memorySource = nil
        memoryLoader?.invalidate(); memoryLoader = nil; memoryBufferAttached = false
    }

    func recoverVideo(_ error: Error, player: AVPlayer, item: CloudDriveItem) {
        guard sourceIdentity?.matches(item) == true, playback.player === player else { return }
        let resume = playback.position, autoplay = playback.wantsPlayback
        task?.cancel(); openWatchdog?.cancel(); openWatchdog = nil
        // A disk that stopped answering explains the failure better than the player's generic error.
        let diskFailure = memoryLoader?.failure, volume = bufferSource
        let provider = sourceProvider
        playback.attach(nil); ready = false
        releaseMemoryBuffer()
        // A repackaged copy that fails as well is converted; a converted copy has nothing further to try.
        let convertOnly = preparation == .repackaged
        guard aviCopy == nil || convertOnly, diskFailure == nil, VideoPreviewPreparation.isFormatFailure(error), let sourceURL,
              let format = sourceContainer?.inputFormat
                ?? VideoPreviewPreparation.InputFormat(fileExtension: (item.name as NSString).pathExtension.lowercased()) else {
            finishSourceProgress(availableURL: nil)
            failure = (diskFailure ?? error).localizedDescription
            return
        }
        let request = generation
        let sourceDirectory = ownedDirectory
        message = convertOnly ? "Converting video for preview…" : "Preparing compatible video preview…"; fraction = nil
        task = Task { [weak self, sourceDirectory] in
            defer { withExtendedLifetime(sourceDirectory) {} }
            do {
                guard let self else { return }
                let (copy, kind) = try await self.makeCopy(from: sourceURL, format: format, repackageFirst: !convertOnly && format.repackagingCanHelp, request: request)
                try Task.checkCancellation()
                guard self.generation == request else { return }
                self.aviCopy = copy; self.preparation = kind
                let bytes = try await NativeFileWork.run(timeout: self.preparationTimeout, priority: .high) {
                    let bytes = (try? copy.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { UInt64(max(0, $0)) }
                    return bytes
                }
                guard let provider, let player = try await self.bufferedPlayer(for: item, provider: provider,
                    url: copy.url, container: nil, volume: volume, request: request) else { throw CancellationError() }
                try Task.checkCancellation()
                guard self.generation == request else { return }
                self.finishSourceProgress(availableURL: copy.url, availableBytes: bytes)
                self.playback.attach(player); self.memoryBufferAttached = true
                self.memoryLoader?.setReadingAhead(true); self.ready = true
                if resume > 0 || autoplay {
                    for _ in 0..<100 {
                        if self.playback.canPlay { break }
                        try await Task.sleep(nanoseconds: 50_000_000)
                        guard self.generation == request else { return }
                    }
                    if resume > 0 { self.playback.seek(to: resume) }
                    if autoplay { self.playback.togglePlayback() }
                }
            } catch {
                guard let self, self.generation == request, !Task.isCancelled else { return }
                self.finishSourceProgress(availableURL: nil)
                self.failure = error.localizedDescription
            }
        }
    }
    func clear(preservingRAM: Bool = false, keeping identity: NativeMediaSourceIdentity? = nil) {
        if let (identity, pending) = pendingBufferedFile {
            if preservingRAM {
                pending.loader.setCachePriority(-1, gracePeriod: 2)
                retiredBuffers.insert(pending, for: identity)
            } else { pending.loader.invalidate() }
            pendingBufferedFile = nil
        }
        if preservingRAM, let sourceIdentity, let loader = memoryLoader, let sourceURL, let memorySource {
            loader.setReadingAhead(false)
            loader.setCachePriority(-1, gracePeriod: 2)
            retiredBuffers.insert(.init(loader: loader, source: memorySource, originalURL: sourceURL,
                directory: ownedDirectory, container: sourceContainer, copy: aviCopy, preparation: preparation), for: sourceIdentity)
            memoryLoader = nil
        }
        if !preservingRAM { retiredBuffers.removeAll() }
        cancelNextBuffer(unless: identity)
        task?.cancel(); task = nil; itemID = nil; sourceIdentity = nil
        generation = UUID(); playback.attach(nil); ready = false; failure = nil; fraction = nil
        stopSourceProgress(); sourceBufferStatus = nil
        releaseMemoryBuffer()
        openWatchdog?.cancel(); openWatchdog = nil
        aviCopy = nil; preparation = nil; sourceURL = nil; sourceProvider = nil; sourceContainer = nil; isPreparingCopy = false
        ownedDirectory = nil
    }
}

struct NativeMediaPreview: View {
    let item: CloudDriveItem
    let provider: any NativeCloudDrive
    @ObservedObject var model: NativeMediaPreviewModel
    var thumbnailCache: NativeThumbnailCache = .shared
    /// Offered when the preview cannot play the file smoothly, and only if IINA is installed.
    @ViewBuilder private var playInIINA: some View {
        if let original = model.originalURL, let iina = ExternalMediaPlayer.iinaURL() {
            Button("Play in IINA") { ExternalMediaPlayer.open(original, in: iina) }
                .buttonStyle(.link)
                .help("Open the original file in IINA, which plays most formats directly. The file is not copied or changed.")
        }
    }
    private var thumbnail: some View {
        NativeMediaThumbnail(item: item, kind: provider.kind, rootID: provider.root.id, cache: thumbnailCache)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.accentColor.opacity(0.05))
    }

    private func transferState(matches: Bool) -> MediaPreviewTransferState {
        let status = matches ? model.bufferStatus : nil
        let source = matches ? model.sourceBufferStatus : nil
        return MediaPreviewTransferState(
            bytesPerSecond: status?.bytesPerSecond ?? source?.bytesPerSecond,
            ranges: status?.cache.normalizedRanges ?? MediaPreviewTransferState.ranges(fraction: source?.fraction ?? (matches ? model.fraction : nil)),
            preparing: !matches || !model.ready,
            complete: status?.cache.fraction == 1,
            waitingForMemory: status?.memoryPressure == true && status?.cache.fraction != 1)
    }

    var body: some View {
        let identity = NativeMediaSourceIdentity(item: item, kind: provider.kind, rootID: provider.root.id)
        let matches = model.matches(item, provider: provider)
        let transfer = transferState(matches: matches)
        return VStack(spacing: 0) {
            if matches && model.ready {
                MediaPreviewView(playback: model.playback, isAudio: item.mediaType == "audio", transfer: transfer,
                    placeholder: AnyView(thumbnail),
                    onVideoFailure: { model.recoverVideo($0, player: $1, item: item) })
            } else {
                thumbnail
                if matches, let failure = model.failure {
                    HStack(spacing: 8) {
                        Label("Preview unavailable", systemImage: "exclamationmark.triangle")
                            .font(.caption).lineLimit(1).help(failure).accessibilityHint(failure)
                        Spacer(minLength: 0)
                        Button("Retry Preview") { model.prepare(item, provider: provider, force: true) }
                        playInIINA
                    }.padding(10)
                } else if matches && model.isPreparingCopy {
                    HStack { Spacer(); playInIINA }.padding(.horizontal, 10)
                }
                MediaTransportBar(playback: model.playback, settings: model.playback.settings, transfer: transfer)
            }
        // Rebuild the task for the current identity; a deferred onChange can capture the previous item.
        }.task(id: identity) { model.prepare(item, provider: provider) }
    }
}

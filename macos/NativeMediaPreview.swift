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

/// Cloud originals and compatible preview copies are made available locally before AVPlayer opens them.
/// This is availability on this Mac, separate from the external-volume loader's retained RAM ranges.
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

/// Download/materialize only the selected media; cancellation never deletes a
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
    /// A repackaged or converted copy is being made, which can take a while: another player is offered meanwhile.
    @Published private(set) var isPreparingCopy = false
    private var generation = UUID()
    private var ownedDirectory: NativePreviewDirectory?
    private var task: Task<Void, Never>?
    private var aviCopy: VideoPreviewCopy?
    private var sourceURL: URL?
    /// The file being previewed, where it is, once it has been materialized.
    var originalURL: URL? { sourceURL }
    private(set) var itemID: String?
    private(set) var sourceIdentity: NativeMediaSourceIdentity?
    /// A file on an external disk or a network share is read into RAM and played from there. Tests replace all three settings.
    var bufferedVolume: @Sendable (URL) -> ExternalVolume.Kind? = { ExternalVolume.bufferedKind($0) }
    var preparationTimeout: TimeInterval = 30
    var materializationTimeout: TimeInterval = 300
    var selectionDelayNanoseconds: UInt64 = 80_000_000
    private var sourceContainer: MediaContainer?
    var memoryBudget = MemoryRangeBuffer.automaticBudget()
    var memoryBlockSize = 1 << 20
    /// How far past the playhead RAM is filled once playback starts. Selecting a video reads only its head and tail.
    var memoryReadAheadBytes: Int64 = 128 << 20
    private var readAheadObservation: AnyCancellable?
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
    /// A player that has not opened a transport stream within this long is abandoned for a repackaged copy. Tests
    /// shorten the wait and simulate a stalled player.
    var openTimeout: TimeInterval = 8
    var openStatus: (AVPlayer) -> AVPlayerItem.Status = { $0.currentItem?.status ?? .unknown }
    private var openWatchdog: Task<Void, Never>?
    init(settings: MediaPlaybackSettings) { playback = MediaPlaybackController(settings: settings) }

    func prepare(_ item: CloudDriveItem, provider: any NativeCloudDrive, force: Bool = false) {
        let identity = NativeMediaSourceIdentity(item: item, kind: provider.kind, rootID: provider.root.id)
        guard identity != sourceIdentity || force else { return }
        clear()
        itemID = item.id; sourceIdentity = identity
        if provider.kind != .local, !item.isFolder, item.mediaType == "video" || item.mediaType == "audio" {
            sourceBufferStatus = .init(source: .cloud(provider.kind), totalBytes: item.bytes, message: "Preparing preview…")
        }
        let request = generation, delay = selectionDelayNanoseconds
        task = Task { [weak self] in
            // Coalesce held arrow keys before touching a new source. The old
            // player is hidden immediately, and cancellation never waits for IO.
            do { if delay > 0 { try await Task.sleep(nanoseconds: delay) } }
            catch { return }
            await self?.load(item, provider: provider, request: request)
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
            if aviCopy == nil, let player = try await bufferedPlayer(for: item, provider: provider, url: playableURL, container: named, volume: volume, request: request) {
                playback.attach(player); memoryBufferAttached = true
                if let loader = memoryLoader {
                    playback.updateMemoryBuffer(loader.snapshot)
                    // Reading beyond what the player asks for follows playback, so flicking through a folder of
                    // videos does not read each of them ahead.
                    readAheadObservation = playback.$wantsPlayback.removeDuplicates().sink { [weak loader] wants in loader?.setReadingAhead(wants) }
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
            // Apple's transport-stream reader can stall on a damaged stream without ever failing.
            if aviCopy == nil, container == .mpegTransportStream || named != nil, let player = playback.player {
                watchOpening(player, item: item, request: request)
            }
        } catch {
            guard generation == request, !Task.isCancelled else { return }
            releaseMemoryBuffer()
            finishSourceProgress(availableURL: nil)
            failure = error.localizedDescription
        }
    }

    /// A player that reads `url` through RAM, or nil when the file is not on an external disk or network share. The
    /// start and end of the file are read first, with progress, so playback starts from memory instead of waiting on it.
    private func bufferedPlayer(for item: CloudDriveItem, provider: any NativeCloudDrive, url: URL, container: MediaContainer?,
                                volume: ExternalVolume.Kind?, request: UUID) async throws -> AVPlayer? {
        guard provider.kind == .local, item.mediaType == "video" || item.mediaType == "audio",
              let volume else { return nil }
        let budget = memoryBudget, blockSize = memoryBlockSize, ahead = memoryReadAheadBytes
        let snapshot: @MainActor (PreviewResourceCacheSnapshot) -> Void = { [weak self] value in
            guard let self, self.generation == request, self.memoryBufferAttached else { return }
            self.playback.updateMemoryBuffer(value)
        }
        let loader = try await NativeFileWork.run(timeout: preparationTimeout, priority: .high) {
            try FilePreviewResourceLoader(fileURL: url, contentType: container?.contentType,
                budgetBytes: budget, blockSize: blockSize, readAheadBytes: ahead, onSnapshot: snapshot)
        }
        guard generation == request, !Task.isCancelled else { loader.invalidate(); throw CancellationError() }
        memoryLoader = loader
        bufferSource = volume
        updateBufferStatus(loader)
        // Keep speed and the idle state current even when the retained ranges do not change (a full RAM window,
        // a slow read, or paused playback). One update per quarter second, only for the selected preview.
        bufferStatusTask = Task { [weak self, weak loader] in
            while !Task.isCancelled {
                guard let loader, self?.generation == request, self?.memoryLoader === loader else { return }
                self?.updateBufferStatus(loader)
                do { try await Task.sleep(nanoseconds: 250_000_000) }
                catch { return }
            }
        }
        message = volume.bufferingMessage; fraction = 0
        do {
            try await loader.prime(noProgressTimeout: preparationTimeout) { [weak self] value in
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
            loader.invalidate()
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
            let deadline = Date().addingTimeInterval(self?.openTimeout ?? 8)
            while Date() < deadline {
                try? await Task.sleep(nanoseconds: 50_000_000)
                guard !Task.isCancelled, let self, let player, self.generation == request, self.playback.player === player else { return }
                if self.openStatus(player) != .unknown { return }
            }
            guard !Task.isCancelled, let self, let player, self.generation == request, self.playback.player === player else { return }
            self.recoverVideo(NSError(domain: AVFoundationErrorDomain, code: AVError.Code.fileFormatNotRecognized.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "The player did not finish opening this file."]), player: player, item: item)
        }
    }
    private func releaseMemoryBuffer() {
        bufferStatusTask?.cancel(); bufferStatusTask = nil
        bufferStatus = nil; bufferSource = nil
        readAheadObservation = nil
        memoryLoader?.invalidate(); memoryLoader = nil; memoryBufferAttached = false
    }

    func recoverVideo(_ error: Error, player: AVPlayer, item: CloudDriveItem) {
        guard sourceIdentity?.matches(item) == true, playback.player === player else { return }
        let resume = playback.position, autoplay = playback.wantsPlayback
        task?.cancel(); openWatchdog?.cancel(); openWatchdog = nil
        // A disk that stopped answering explains the failure better than the player's generic error.
        let diskFailure = memoryLoader?.failure
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
                let prepared = try await NativeFileWork.run(timeout: self.preparationTimeout, priority: .high) {
                    let bytes = (try? copy.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { UInt64(max(0, $0)) }
                    return (AVPlayer(url: copy.url), bytes)
                }
                try Task.checkCancellation()
                guard self.generation == request else { return }
                self.finishSourceProgress(availableURL: copy.url, availableBytes: prepared.1)
                self.playback.attach(prepared.0); self.ready = true
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
    func clear() {
        task?.cancel(); task = nil; itemID = nil; sourceIdentity = nil
        generation = UUID(); playback.attach(nil); ready = false; failure = nil; fraction = nil
        stopSourceProgress(); sourceBufferStatus = nil
        releaseMemoryBuffer()
        openWatchdog?.cancel(); openWatchdog = nil
        aviCopy = nil; preparation = nil; sourceURL = nil; sourceContainer = nil; isPreparingCopy = false
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
    var body: some View {
        let identity = NativeMediaSourceIdentity(item: item, kind: provider.kind, rootID: provider.root.id)
        let matches = model.matches(item, provider: provider)
        return VStack(spacing: 0) {
            if matches && model.ready {
                MediaPreviewView(playback: model.playback, isAudio: item.mediaType == "audio",
                    onVideoFailure: { model.recoverVideo($0, player: $1, item: item) })
            }
            else {
                ZStack {
                    NativeMediaThumbnail(item: item, kind: provider.kind, rootID: provider.root.id, cache: thumbnailCache)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    VStack(spacing: 12) {
                        if matches, let failure = model.failure {
                            Image(systemName: "exclamationmark.triangle").font(.title2)
                            Text("Preview unavailable").font(.headline)
                            Text(failure).font(.caption).multilineTextAlignment(.center).lineLimit(4)
                            Button("Retry Preview") { model.prepare(item, provider: provider, force: true) }
                            playInIINA
                        } else {
                            ProgressView(value: matches ? (model.bufferStatus?.cache.fraction ?? model.sourceBufferStatus?.fraction ?? model.fraction) : nil)
                                .progressViewStyle(.linear).controlSize(.small)
                            Text(matches ? model.message : "Preparing preview…").font(.caption).multilineTextAlignment(.center).lineLimit(3)
                            if matches, let status = model.bufferStatus {
                                MediaPreviewTransferMetricsView(fraction: status.cache.fraction, bytesPerSecond: status.bytesPerSecond,
                                    receivedBytes: UInt64(max(0, status.cache.cachedBytes)),
                                    totalBytes: status.cache.contentLength.flatMap { $0 > 0 ? UInt64($0) : nil })
                            } else if matches, let status = model.sourceBufferStatus {
                                MediaPreviewTransferMetricsView(fraction: status.fraction, bytesPerSecond: status.bytesPerSecond,
                                    receivedBytes: status.receivedBytes, totalBytes: status.totalBytes)
                            }
                            if matches, model.isPreparingCopy { playInIINA }
                        }
                    }.padding(16).frame(maxWidth: 320)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10)).padding(20)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.accentColor.opacity(0.05))
            }
            if matches, let status = model.bufferStatus, let source = model.bufferSource {
                NativeMediaBufferStatusView(status: status, source: source)
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .overlay(alignment: .top) { Divider() }
            } else if matches, let status = model.sourceBufferStatus {
                NativeMediaSourceBufferStatusView(status: status)
                    .padding(10)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .overlay(alignment: .top) { Divider() }
            }
        // `.onChange` runs a closure that captured the previous item, which left
        // the model one selection behind. `.task(id:)` is rebuilt for each identity.
        }.task(id: identity) { model.prepare(item, provider: provider) }
    }
}

/// Compact transfer details stay inside the loading card, where they remain visible before a player exists.
struct MediaPreviewTransferMetricsView: View {
    let fraction: Double?
    let bytesPerSecond: Double?
    let receivedBytes: UInt64?
    let totalBytes: UInt64?

    private func amount(_ bytes: UInt64) -> String {
        bytes == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
    private var speedText: String {
        bytesPerSecond.map { "\(amount(SafeDisplayNumber.bytes($0)))/s" } ?? "—"
    }
    private var progressText: String {
        fraction.map { $0.formatted(.percent.precision(.fractionLength(0...1))) } ?? "Loading…"
    }

    var body: some View {
        VStack(spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(bytesPerSecond == nil ? "Speed: —" : speedText)
                    .accessibilityLabel("Transfer speed: \(speedText)")
                Spacer(minLength: 4)
                Text(progressText).accessibilityLabel("Preparation progress: \(progressText)")
            }
            if let receivedBytes {
                Text(totalBytes.flatMap { $0 > 0 ? "\(amount(receivedBytes)) of \(amount($0)) received" : nil }
                    ?? "\(amount(receivedBytes)) received")
                    .fixedSize(horizontal: false, vertical: true)
            } else if let totalBytes, totalBytes > 0 {
                Text("File size: \(amount(totalBytes))")
            }
        }.font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
    }
}

struct MediaPreviewLoadingStatusView: View {
    let isAudio: Bool
    let message: String?
    let fraction: Double?
    let bytesPerSecond: Double?
    let receivedBytes: UInt64?
    let totalBytes: UInt64?

    var body: some View {
        VStack(spacing: 10) {
            ProgressView(value: fraction).progressViewStyle(.linear).controlSize(.large)
            Text("Loading \(isAudio ? "audio" : "video") preview…").font(.callout.weight(.semibold))
            if let message { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            MediaPreviewTransferMetricsView(fraction: fraction, bytesPerSecond: bytesPerSecond,
                receivedBytes: receivedBytes, totalBytes: totalBytes)
        }
        .padding(.horizontal, 22).padding(.vertical, 18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
}

struct MediaPreviewBufferDetails<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        DisclosureGroup {
            content
        } label: {
            Text("Buffering details").font(.caption2.weight(.medium))
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct NativeMediaSourceBufferStatusView: View {
    let status: NativeMediaSourceBufferStatus
    private func amount(_ bytes: UInt64) -> String {
        bytes == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file)
    }
    private var byteDetail: String {
        if status.phase == .available {
            return (status.receivedBytes ?? status.totalBytes).map { "\(amount($0)) available on this Mac" }
                ?? "Preview available on this Mac"
        }
        if let bytes = status.receivedBytes {
            return status.totalBytes.map { "\(amount(bytes)) of \(amount($0)) received" } ?? "\(amount(bytes)) received"
        }
        return status.totalBytes.map { "File size: \(amount($0))" } ?? "Waiting for media data"
    }

    var body: some View {
        MediaPreviewBufferDetails {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Label(status.title, systemImage: status.phase == .failed ? "exclamationmark.triangle" : "arrow.down.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(status.phase == .failed ? Color.orange : Color.cyan)
                    Spacer(minLength: 4)
                    Text(status.source.title).font(.caption2).foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(status.bytesPerSecond.map { "Transfer speed: \(amount(SafeDisplayNumber.bytes($0)))/s" }
                        ?? "Transfer speed: —")
                        .monospacedDigit()
                        .help("Speed is shown when the source reports transferred bytes.")
                    Spacer(minLength: 4)
                    Text(status.fraction.map { $0.formatted(.percent.precision(.fractionLength(0...1))) }
                        ?? (status.phase == .failed ? "—" : "Loading…"))
                        .monospacedDigit()
                }.font(.caption2).foregroundStyle(.secondary)
                ProgressView(value: status.phase == .failed ? status.fraction ?? 0 : status.fraction)
                    .progressViewStyle(.linear).tint(.cyan)
                    .accessibilityLabel("Preview buffering")
                    .accessibilityValue(status.fraction.map { $0.formatted(.percent) } ?? "Preparing")
                Text(byteDetail).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(status.message)
                    Text("The bar shows preparation progress. Fully buffered means the preview is available on this Mac.")
                }.font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The same byte-based buffer information as a streaming drive, kept visible while loading and playing.
struct NativeMediaBufferStatusView: View {
    let status: FilePreviewBufferStatus
    let source: ExternalVolume.Kind
    private var isNetwork: Bool { source == .networkShare }
    private func amount(_ bytes: Int64) -> String {
        bytes == 0 ? "0 B" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
    private var activityDescription: String {
        if status.failed { return "Reading stopped. Retry the preview when the drive is available." }
        if status.cache.fraction == 1 { return "The entire file is available from RAM." }
        if status.isReading { return "Reading from \(isNetwork ? "the network share" : "the external disk")…" }
        return "No \(isNetwork ? "network" : "disk") reads. More data loads as playback needs it."
    }

    var body: some View {
        MediaPreviewBufferDetails {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Label(status.title, systemImage: status.failed ? "exclamationmark.triangle" : "memorychip")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(status.failed ? Color.orange : Color.cyan)
                    Spacer(minLength: 4)
                    Text(isNetwork ? "Network share" : "External disk").font(.caption2).foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Read speed: \(amount(Int64(SafeDisplayNumber.integer(status.bytesPerSecond))))/s")
                        .monospacedDigit()
                    Spacer(minLength: 4)
                    Text((status.cache.fraction ?? 0).formatted(.percent.precision(.fractionLength(0...1))))
                        .monospacedDigit()
                }.font(.caption2).foregroundStyle(.secondary)
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08))
                        ForEach(Array(status.cache.normalizedRanges.enumerated()), id: \.offset) { _, range in
                            RoundedRectangle(cornerRadius: 3).fill(Color.cyan.opacity(0.7))
                                .frame(width: geometry.size.width * (range.upperBound - range.lowerBound))
                                .offset(x: geometry.size.width * range.lowerBound)
                        }
                    }
                }.frame(height: 6)
                    .accessibilityLabel("File held in RAM")
                    .accessibilityValue((status.cache.fraction ?? 0).formatted(.percent))
                Text("\(amount(status.cache.cachedBytes)) of \(amount(status.cache.contentLength ?? 0)) in RAM")
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("RAM limit: \(amount(status.budgetBytes)) · Total read: \(amount(status.bytesRead))")
                        .monospacedDigit()
                    Text(activityDescription)
                    Text("Cyan segments show parts of this file held in memory. Large files use a moving window. Reading ahead pauses with playback; choosing another file clears the buffer.")
                }.font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

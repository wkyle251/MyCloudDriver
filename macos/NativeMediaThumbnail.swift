import AppKit
import SwiftUI
@preconcurrency import QuickLookThumbnailing
@preconcurrency import Photos

/// A snapshot belongs to an exact file revision and provider root, including
/// when a reused view receives a late thumbnail from the previous selection.
struct NativeMediaThumbnailSnapshot {
    let identity: NativeMediaSourceIdentity
    let image: NSImage
    func image(for identity: NativeMediaSourceIdentity) -> NSImage? {
        self.identity == identity ? image : nil
    }
}

@MainActor final class NativeMediaThumbnailModel: ObservableObject {
    @Published private(set) var snapshot: NativeMediaThumbnailSnapshot?
    private var generation = UUID()

    func load(identity: NativeMediaSourceIdentity, operation: () async -> NSImage?) async {
        let request = UUID(); generation = request
        snapshot = nil
        let image = await operation()
        guard generation == request, !Task.isCancelled, let image else { return }
        snapshot = NativeMediaThumbnailSnapshot(identity: identity, image: image)
    }
    func clear() {
        generation = UUID(); snapshot = nil
    }
}

@MainActor struct NativeMediaThumbnail: View {
    let item: CloudDriveItem
    let kind: CloudDriveKind
    var rootID: String? = nil
    var cache: NativeThumbnailCache = .shared
    var compact = false
    @StateObject private var model = NativeMediaThumbnailModel()
    var body: some View {
        let identity = NativeMediaSourceIdentity(item: item, kind: kind, rootID: rootID)
        return ZStack {
            if !compact { RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.025)) }
            if let image = model.snapshot?.image(for: identity) ?? cache.cachedImage(for: identity) {
                Image(nsImage: image).resizable().scaledToFit().padding(compact ? 0 : 4)
            } else { Image(systemName: item.symbol).font(.system(size: compact ? 14 : 42)).foregroundStyle(FinderAppearance.accent.opacity(0.8)) }
        }
        .task(id: identity) {
            await model.load(identity: identity) { await cache.image(for: identity) }
        }
        .onDisappear { model.clear() }
        .accessibilityLabel("Thumbnail for \(item.name)")
    }
}

@MainActor enum NativeThumbnailGenerator {
    static func load(_ identity: NativeMediaSourceIdentity) async -> NSImage? {
        guard NativeThumbnailCache.canLoad(identity), !Task.isCancelled else { return nil }
        if let url = identity.url, identity.isDownloaded {
            let transfer = NativeQuickLookThumbnailTransfer()
            defer { withExtendedLifetime(transfer) {} }
            let result = await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { transfer.start(url: url, continuation: $0) }
            }, onCancel: { transfer.cancel() })
            guard !Task.isCancelled, let result else { return nil }
            // Use the bitmap representation, avoiding a lazy NSImage whose
            // first SwiftUI draw could perform representation work on main.
            return try? await NativeFileWork.run {
                NSImage(cgImage: result.cgImage, size: .zero)
            }
        } else if identity.kind == .photos, PhotosDriveProvider.authorized {
            let request = PhotosThumbnailTransfer()
            defer { withExtendedLifetime(request) {} }
            let id = String(identity.itemID.dropFirst(6))
            return await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { request.start(id: id, continuation: $0) }
            }, onCancel: { request.cancel() })
        }
        return nil
    }
}

/// Request creation and submission may enter file-provider/Quick Look IPC.
/// The bounded worker owns those calls; cancellation never waits for them.
final class NativeQuickLookThumbnailTransfer: @unchecked Sendable {
    typealias Completion = @Sendable (QLThumbnailRepresentation?) -> Void
    typealias Generate = @Sendable (QLThumbnailGenerator.Request, @escaping Completion) -> Void
    private let lock = NSLock()
    private let timeout: TimeInterval
    private let generate: Generate
    private let cancelRequest: @Sendable (QLThumbnailGenerator.Request) -> Void
    private var request: QLThumbnailGenerator.Request?
    private var continuation: CheckedContinuation<QLThumbnailRepresentation?, Never>?
    private var timer: DispatchWorkItem?
    private var submitted = false
    private var cancelled = false
    private var finished = false
    init(timeout: TimeInterval = 30,
         generate: @escaping Generate = { request, complete in
             QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { result, _ in complete(result) }
         }, cancel: @escaping @Sendable (QLThumbnailGenerator.Request) -> Void = { QLThumbnailGenerator.shared.cancel($0) }) {
        self.timeout = timeout.isFinite && timeout > 0 ? timeout : 30
        self.generate = generate; self.cancelRequest = cancel
    }
    func start(url: URL, continuation: CheckedContinuation<QLThumbnailRepresentation?, Never>) {
        lock.lock()
        guard !finished else { lock.unlock(); continuation.resume(returning: nil); return }
        let timer = DispatchWorkItem { [weak self] in self?.expire() }
        self.continuation = continuation; self.timer = timer; lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: timer)
        Task {
            do { try await NativeFileWork.run(onCancel: { [weak self] in self?.cancel() }) { self.submit(url) } }
            catch { self.complete(nil) }
        }
    }
    private func submit(_ url: URL) {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: .init(width: 360, height: 360),
            scale: 1, representationTypes: .thumbnail)
        lock.lock()
        guard !finished, !cancelled else { lock.unlock(); return }
        self.request = request; submitted = true; lock.unlock()
        generate(request) { [weak self] result in self?.complete(result) }
        // A cancellation can arrive just before the framework accepts the
        // request. Cancel again after submission to cover that ordering.
        lock.lock(); let cancelled = cancelled; lock.unlock()
        if cancelled { cancelRequest(request) }
    }
    private func complete(_ result: QLThumbnailRepresentation?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = continuation; self.continuation = nil; request = nil
        let timer = timer; self.timer = nil
        let result = cancelled ? nil : result; lock.unlock()
        timer?.cancel()
        continuation?.resume(returning: result)
    }
    func cancel() {
        lock.lock(); cancelled = true
        let request = request, submitted = submitted; lock.unlock()
        if !submitted { complete(nil) }
        let cancelRequest = cancelRequest
        if let request { NativeFileWork.performCancellation { cancelRequest(request) } }
    }
    private func expire() { cancel(); complete(nil) }
}

private final class PhotosThumbnailTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private var id: PHImageRequestID?
    private var continuation: CheckedContinuation<NSImage?, Never>?
    private var timer: DispatchWorkItem?
    private var finished = false
    private var submitted = false
    private var cancelled = false
    func start(id assetID: String, continuation: CheckedContinuation<NSImage?, Never>) {
        lock.lock()
        if finished { lock.unlock(); continuation.resume(returning: nil); return }
        let timer = DispatchWorkItem { [weak self] in self?.expire() }
        self.continuation = continuation; self.timer = timer; lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30, execute: timer)
        Task {
            do { try await NativeFileWork.run(onCancel: { [weak self] in self?.cancel() }) { self.submit(assetID) } }
            catch { self.complete(nil) }
        }
    }
    private func submit(_ assetID: String) {
        lock.lock(); let finished = finished; lock.unlock()
        guard !finished else { return }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else { complete(nil); return }
        let options = PHImageRequestOptions(); options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat; options.resizeMode = .fast
        lock.lock()
        guard !self.finished, !cancelled else { lock.unlock(); return }
        submitted = true; lock.unlock()
        let request = PHImageManager.default().requestImage(for: asset, targetSize: .init(width: 360, height: 360), contentMode: .aspectFit, options: options) { [weak self] image, info in
            if (info?[PHImageResultIsDegradedKey] as? Bool) != true { self?.complete(image) }
        }
        lock.lock(); id = request; let shouldCancel = self.finished || cancelled; lock.unlock()
        if shouldCancel { PHImageManager.default().cancelImageRequest(request) }
    }
    private func complete(_ image: NSImage?) {
        lock.lock(); guard !finished else { lock.unlock(); return }; finished = true
        let continuation = self.continuation; self.continuation = nil
        let timer = timer; self.timer = nil
        let image = cancelled ? nil : image; lock.unlock()
        timer?.cancel()
        continuation?.resume(returning: image)
    }
    func cancel() {
        lock.lock(); cancelled = true
        let request = id, submitted = submitted; lock.unlock()
        if !submitted { complete(nil) }
        if let request { NativeFileWork.performCancellation { PHImageManager.default().cancelImageRequest(request) } }
    }
    private func expire() { cancel(); complete(nil) }
}

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
            let request = QLThumbnailGenerator.Request(fileAt: url, size: .init(width: 360, height: 360), scale: 1, representationTypes: .thumbnail)
            let result = await withTaskCancellationHandler(operation: {
                try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            }, onCancel: { QLThumbnailGenerator.shared.cancel(request) })
            return result?.nsImage
        } else if identity.kind == .photos, PhotosDriveProvider.authorized {
            let request = PhotosThumbnailTransfer()
            return await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { request.start(id: String(identity.itemID.dropFirst(6)), continuation: $0) }
            }, onCancel: { request.cancel() })
        }
        return nil
    }
}

private final class PhotosThumbnailTransfer: @unchecked Sendable {
    private let lock = NSLock()
    private var id: PHImageRequestID?
    private var continuation: CheckedContinuation<NSImage?, Never>?
    private var finished = false
    func start(id assetID: String, continuation: CheckedContinuation<NSImage?, Never>) {
        lock.lock()
        if finished { lock.unlock(); continuation.resume(returning: nil); return }
        self.continuation = continuation; lock.unlock()
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else { complete(nil); return }
        let options = PHImageRequestOptions(); options.isNetworkAccessAllowed = true
        options.deliveryMode = .highQualityFormat; options.resizeMode = .fast
        let request = PHImageManager.default().requestImage(for: asset, targetSize: .init(width: 360, height: 360), contentMode: .aspectFit, options: options) { [weak self] image, info in
            if (info?[PHImageResultIsDegradedKey] as? Bool) != true { self?.complete(image) }
        }
        lock.lock(); id = request; let shouldCancel = finished; lock.unlock()
        if shouldCancel { PHImageManager.default().cancelImageRequest(request) }
    }
    private func complete(_ image: NSImage?) {
        lock.lock(); guard !finished else { lock.unlock(); return }; finished = true
        let continuation = self.continuation; self.continuation = nil; lock.unlock()
        continuation?.resume(returning: image)
    }
    func cancel() {
        complete(nil)
        lock.lock(); let request = id; lock.unlock()
        if let request { PHImageManager.default().cancelImageRequest(request) }
    }
}

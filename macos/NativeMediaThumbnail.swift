import AppKit
import SwiftUI
@preconcurrency import QuickLookThumbnailing
@preconcurrency import Photos

/// Thumbnails are requested only for visible grid cells and the inspector.
/// The list uses inexpensive symbols and never decodes media while scrolling.
struct NativeMediaThumbnail: View {
    let item: CloudDriveItem
    let kind: CloudDriveKind
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.025))
            if let image { Image(nsImage: image).resizable().scaledToFit().padding(4) }
            else { Image(systemName: item.symbol).font(.system(size: 42)).foregroundStyle(FinderAppearance.accent.opacity(0.8)) }
        }
        .task(id: item.id) {
            image = nil
            guard !item.isFolder else { return }
            if let url = item.url, item.isDownloaded {
                let request = QLThumbnailGenerator.Request(fileAt: url, size: .init(width: 360, height: 360), scale: 1, representationTypes: .thumbnail)
                let result = await withTaskCancellationHandler(operation: {
                    try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
                }, onCancel: { QLThumbnailGenerator.shared.cancel(request) })
                if !Task.isCancelled { image = result?.nsImage }
            } else if kind == .photos, item.id.hasPrefix("asset:"), PhotosDriveProvider.authorized {
                let request = PhotosThumbnailTransfer()
                let result = await withTaskCancellationHandler(operation: {
                    await withCheckedContinuation { request.start(id: String(item.id.dropFirst(6)), continuation: $0) }
                }, onCancel: { request.cancel() })
                if !Task.isCancelled { image = result }
            }
        }
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

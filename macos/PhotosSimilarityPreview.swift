import AppKit
@preconcurrency import Photos

/// PhotoKit previews, including video poster frames. This requests an image
/// representation rather than a PHAssetResource original.
final class PhotosSimilarityPreview: @unchecked Sendable {
    static let contentKind = "photos_preview_1024_v1"
    static let maximumBytes = 8 << 20
    private let lock = NSLock()
    private var requestID: PHImageRequestID?
    private var continuation: CheckedContinuation<Data, Error>?
    private var finished = false
    private var encoding = false

    func start(_ asset: PHAsset, progress: @escaping CloudDriveProgressHandler,
               continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        self.continuation = continuation; lock.unlock()
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .fastFormat
        options.resizeMode = .fast
        options.version = .current
        options.progressHandler = { value, _, _, _ in
            progress(.init(message: "Fetching preview from iCloud", fraction: value))
        }
        let id = PHImageManager.default().requestImage(for: asset, targetSize: .init(width: 1024, height: 1024),
            contentMode: .aspectFit, options: options) { [weak self] image, info in
            guard let self else { return }
            self.lock.lock()
            guard !self.finished, !self.encoding else { self.lock.unlock(); return }
            self.encoding = true; self.lock.unlock()
            if info?[PHImageCancelledKey] as? Bool == true { self.complete(.failure(CancellationError())); return }
            guard let image else {
                self.complete(.failure(info?[PHImageErrorKey] as? Error
                    ?? CloudDriveError.message("Photos could not provide a preview. Try Originals mode for this asset.")))
                return
            }
            // Fast delivery may return a lower-quality cached image. Accept
            // that result; waiting for a non-degraded callback can never finish
            // with fastFormat. Bound and encode it off PhotoKit's callback queue.
            DispatchQueue.global(qos: .utility).async {
                self.complete(Result { try Self.jpeg(image) })
            }
        }
        lock.lock(); requestID = id; let stop = finished; lock.unlock()
        if stop { PHImageManager.default().cancelImageRequest(id) }
    }

    static func jpeg(_ image: NSImage) throws -> Data {
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              source.width > 0, source.height > 0 else { throw CocoaError(.fileReadCorruptFile) }
        let scale = min(1, 1024.0 / Double(max(source.width, source.height)))
        let width = max(1, Int(Double(source.width) * scale)), height = max(1, Int(Double(source.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileReadTooLarge)
        }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(.init(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.draw(source, in: .init(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage(),
              let bytes = NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.82]),
              bytes.count <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        return bytes
    }

    private func complete(_ result: Result<Data, Error>) {
        lock.lock(); guard !finished else { lock.unlock(); return }
        finished = true; let continuation = self.continuation; self.continuation = nil; lock.unlock()
        continuation?.resume(with: result)
    }
    func cancel() {
        complete(.failure(CancellationError()))
        lock.lock(); let id = requestID; lock.unlock()
        if let id { PHImageManager.default().cancelImageRequest(id) }
    }
}

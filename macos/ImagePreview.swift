import AppKit
import ImageIO
import SwiftUI

struct ImagePreviewRequest: Equatable {
    let fileID: String
    let thumbnailURL: URL?
    let contentURL: URL?
    let generation: UUID
    let proxyURL: String
}

/// One presentation survives the thumbnail → metadata → original sequence.
/// Only a different selection clears the displayed bitmap; loading, retries,
/// errors and layout changes keep the most recently decoded image visible.
@MainActor
final class ImagePreviewModel: ObservableObject {
    enum Quality { case thumbnail, original }
    struct Frame {
        let fileID: String
        let image: NSImage
        let quality: Quality
    }
    typealias Loader = (URL, String) async throws -> NSImage

    @Published private(set) var frame: Frame?
    @Published private(set) var isLoading = false
    @Published private(set) var error: NSError?
    private(set) var request: ImagePreviewRequest?
    private let load: Loader
    private var thumbnailTask: Task<Void, Never>?
    private var originalTask: Task<Void, Never>?
    private var thumbnailGeneration = UUID()
    private var originalGeneration = UUID()

    init(load: @escaping Loader = ImagePreviewTransport.load) { self.load = load }

    func reset(unlessFileID retainedFileID: String? = nil) {
        if let retainedFileID, request?.fileID == retainedFileID { return }
        thumbnailGeneration = UUID()
        originalGeneration = UUID()
        thumbnailTask?.cancel(); thumbnailTask = nil
        originalTask?.cancel(); originalTask = nil
        request = nil
        frame = nil
        error = nil
        isLoading = false
    }

    func update(_ next: ImagePreviewRequest, onFailure: @escaping (Error) -> Void = { _ in }) {
        guard request != next else { return }
        let old = request
        if old?.fileID != next.fileID { reset() }
        request = next

        let thumbnailChanged = old?.fileID != next.fileID || old?.thumbnailURL != next.thumbnailURL
            || old?.proxyURL != next.proxyURL
        if thumbnailChanged {
            thumbnailTask?.cancel(); thumbnailTask = nil
            thumbnailGeneration = UUID()
            if let url = next.thumbnailURL, frame?.quality != .original,
               url != next.contentURL {
                start(url: url, quality: .thumbnail, request: next, onFailure: onFailure)
            }
        }

        let originalChanged = old?.fileID != next.fileID || old?.contentURL != next.contentURL
            || old?.generation != next.generation || old?.proxyURL != next.proxyURL
        if originalChanged {
            originalTask?.cancel(); originalTask = nil
            originalGeneration = UUID()
            error = nil
            if let url = next.contentURL {
                start(url: url, quality: .original, request: next, onFailure: onFailure)
            }
        }
        updateLoading()
    }

    private func start(url: URL, quality: Quality, request: ImagePreviewRequest,
                       onFailure: @escaping (Error) -> Void) {
        let generation = quality == .original ? originalGeneration : thumbnailGeneration
        let load = self.load
        let task = Task { [weak self] in
            do {
                let image = try await load(url, request.proxyURL)
                guard !Task.isCancelled, let self,
                      self.request?.fileID == request.fileID,
                      generation == (quality == .original ? self.originalGeneration : self.thumbnailGeneration) else { return }
                if quality == .original || self.frame?.quality != .original {
                    self.frame = Frame(fileID: request.fileID, image: image, quality: quality)
                }
                if quality == .original {
                    self.originalTask = nil
                    self.error = nil
                    // A slow thumbnail must never replace the finished original.
                    self.thumbnailGeneration = UUID()
                    self.thumbnailTask?.cancel(); self.thumbnailTask = nil
                } else { self.thumbnailTask = nil }
                self.updateLoading()
            } catch {
                guard !Task.isCancelled, let self,
                      self.request?.fileID == request.fileID,
                      generation == (quality == .original ? self.originalGeneration : self.thumbnailGeneration) else { return }
                if quality == .original {
                    self.originalTask = nil
                    self.error = error as NSError
                    onFailure(error)
                } else { self.thumbnailTask = nil }
                self.updateLoading()
            }
        }
        if quality == .original { originalTask = task } else { thumbnailTask = task }
    }

    private func updateLoading() { isLoading = thumbnailTask != nil || originalTask != nil }

    deinit { thumbnailTask?.cancel(); originalTask?.cancel() }
}

enum ImagePreviewTransport {
    /// Stage bytes privately on disk and decode off the UI thread. Retaining an
    /// undecoded NSImage can still cause a hitch/blank frame on first display.
    static func load(_ url: URL, proxyURL: String) async throws -> NSImage {
        guard url.scheme?.lowercased() == "https" else {
            throw NSError(domain: "ImagePreview", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The image source is not a secure HTTPS URL."])
        }
        let configuration = PreviewTransport.configuration(proxyURL: proxyURL)
        configuration.timeoutIntervalForResource = 180
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("image/*, */*;q=0.5", forHTTPHeaderField: "Accept")
        let (file, response) = try await session.download(for: request)
        defer { try? FileManager.default.removeItem(at: file) }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "ImagePreview.HTTP", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "Image download failed: HTTP \(status) (\(HTTPURLResponse.localizedString(forStatusCode: status)))."])
        }
        let bitmap = try await Task.detached(priority: .userInitiated) { try decodeBitmap(file) }.value
        try Task.checkCancellation()
        return NSImage(cgImage: bitmap, size: NSSize(width: bitmap.width, height: bitmap.height))
    }

    static func decode(_ file: URL) throws -> NSImage {
        let bitmap = try decodeBitmap(file)
        return NSImage(cgImage: bitmap, size: NSSize(width: bitmap.width, height: bitmap.height))
    }

    private static func decodeBitmap(_ file: URL) throws -> CGImage {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            // Bounds decompression memory for unusually large originals while
            // keeping native-quality detail on Retina preview canvases.
            kCGImageSourceThumbnailMaxPixelSize: 8192,
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(file as CFURL, sourceOptions),
              let bitmap = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            throw NSError(domain: "ImagePreview", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "macOS could not decode this image. Try Quick Look or download the original."])
        }
        return bitmap
    }
}

struct ImagePreviewSurface: View {
    @ObservedObject var model: ImagePreviewModel
    let request: ImagePreviewRequest
    let onFailure: (Error) -> Void

    var body: some View {
        ZStack {
            if let frame = model.frame, frame.fileID == request.fileID {
                Image(nsImage: frame.image)
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "photo")
                    .resizable().scaledToFit()
                    .foregroundStyle(.secondary).padding(40)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottomTrailing) {
            if model.request?.fileID == request.fileID, model.isLoading {
                ProgressView().controlSize(.small)
                    .padding(8).background(.regularMaterial, in: Circle()).padding(10)
                    .allowsHitTesting(false)
            }
        }
        // No implicit fade, blank intermediate branch, or thumbnail behind a
        // transparent PNG: precisely one decoded image is drawn at a time.
        .transaction { $0.animation = nil; $0.disablesAnimations = true }
        .onAppear { model.update(request, onFailure: onFailure) }
        .onChange(of: request) { model.update($0, onFailure: onFailure) }
        .accessibilityLabel("Image preview")
    }
}

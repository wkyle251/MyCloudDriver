import AppKit
import SwiftUI

@MainActor final class SimilarityPreviewModel: ObservableObject {
    let quickLook = QuickLookPreviewCoordinator()
    private var task: Task<Void, Never>?
    private var directory: NativePreviewDirectory?
    private var generation = UUID()
    private var file: SimilarityFile?
    private var prepare: ((SimilarityFile, URL) async throws -> URL)?
    var move: ((Int) -> Void)?
    init() {
        quickLook.onClose = { [weak self] in self?.close() }
        quickLook.onMove = { [weak self] offset in self?.move?(offset) }
        quickLook.onRetry = { [weak self] in
            guard let self, let file = self.file else { return }
            self.show(file, prepare: self.prepare)
        }
    }
    var isActive: Bool { quickLook.isActive }
    func show(_ file: SimilarityFile, prepare: ((SimilarityFile, URL) async throws -> URL)?, in window: NSWindow? = nil) {
        task?.cancel(); generation = UUID(); let token = generation
        self.file = file; self.prepare = prepare
        quickLook.showLoading(fileID: file.id, name: file.name, in: window)
        directory = nil
        task = Task { [weak self] in
            guard let self else { return }
            var created: NativePreviewDirectory?
            do {
                let url: URL
                if let path = file.localPath {
                    url = URL(fileURLWithPath: path)
                    let exists = try await NativeFileWork.run { FileManager.default.fileExists(atPath: path) }
                    guard exists else { throw CloudDriveError.message("This file has moved or is no longer available. Run a new scan to update its location.") }
                } else {
                    guard let prepare else { throw CloudDriveError.message("Open this file from its drive to preview it.") }
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyCloudDriver-SimilarityPreview-\(UUID().uuidString)")
                    let staging = NativePreviewDirectory(folder); created = staging
                    try await NativeFileWork.run {
                        defer { withExtendedLifetime(staging) {} }
                        try CloudDriveFiles.privateDirectory(staging.url)
                    }
                    try Task.checkCancellation()
                    url = try await NativeFileWork.asyncRun(timeout: 300) {
                        defer { withExtendedLifetime(staging) {} }
                        return try await AutomaticRecovery.read { try await prepare(file, staging.url) }
                    }
                }
                try Task.checkCancellation()
                guard self.generation == token else { throw CancellationError() }
                self.directory = created; created = nil
                _ = self.quickLook.present(url, name: file.name)
            } catch {
                if !Task.isCancelled && self.generation == token { self.quickLook.showFailure(FileSearchIndex.redacted(error.localizedDescription)) }
            }
            created = nil
        }
    }
    func close() {
        task?.cancel(); task = nil; generation = UUID(); file = nil; prepare = nil; move = nil
        quickLook.dismiss()
        directory = nil
    }
}

struct SimilarityFileThumbnail: View {
    let file: SimilarityFile
    let photos: Bool
    var body: some View {
        NativeMediaThumbnail(item: .init(id: file.id, name: file.name, isFolder: false, bytes: file.bytes,
            url: file.localPath.map { URL(fileURLWithPath: $0) }, mediaType: file.family), kind: photos ? .photos : .icloud)
    }
}

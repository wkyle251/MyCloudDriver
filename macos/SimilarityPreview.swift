import AppKit
import SwiftUI

@MainActor final class SimilarityPreviewModel: ObservableObject {
    let quickLook = QuickLookPreviewCoordinator()
    private var task: Task<Void, Never>?
    private var directory: URL?
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
        if let old = directory { try? FileManager.default.removeItem(at: old); directory = nil }
        task = Task { [weak self] in
            guard let self else { return }
            var created: URL?
            do {
                let url: URL
                if let path = file.localPath {
                    url = URL(fileURLWithPath: path)
                    guard FileManager.default.fileExists(atPath: path) else { throw CloudDriveError.message("This file has moved or is no longer available. Run a new scan to update its location.") }
                } else {
                    guard let prepare else { throw CloudDriveError.message("Open this file from its drive to preview it.") }
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MyCloudDriver-SimilarityPreview-\(UUID().uuidString)")
                    try CloudDriveFiles.privateDirectory(folder); created = folder
                    url = try await prepare(file, folder)
                }
                try Task.checkCancellation()
                guard self.generation == token else { throw CancellationError() }
                self.directory = created; created = nil
                _ = self.quickLook.present(url, name: file.name)
            } catch {
                if !Task.isCancelled && self.generation == token { self.quickLook.showFailure(FileSearchIndex.redacted(error.localizedDescription)) }
            }
            if let created { try? FileManager.default.removeItem(at: created) }
        }
    }
    func close() {
        task?.cancel(); task = nil; generation = UUID(); file = nil; prepare = nil; move = nil
        quickLook.dismiss()
        if let directory { try? FileManager.default.removeItem(at: directory) }; directory = nil
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

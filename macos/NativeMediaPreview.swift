import AVFoundation
import SwiftUI

/// Download/materialize only the selected media; cancellation never deletes a
/// user's iCloud original, nor a staging directory with a writer still active.
@MainActor final class NativeMediaPreviewModel: ObservableObject {
    let playback: MediaPlaybackController
    @Published private(set) var message = "Preparing preview…"
    @Published private(set) var fraction: Double?
    @Published private(set) var failure: String?
    @Published private(set) var ready = false
    private var generation = UUID()
    private var ownedDirectory: URL?
    private var task: Task<Void, Never>?
    private var aviCopy: VideoPreviewCopy?
    private var sourceURL: URL?
    private(set) var itemID: String?
    init(settings: MediaPlaybackSettings) { playback = MediaPlaybackController(settings: settings) }

    func prepare(_ item: CloudDriveItem, provider: any NativeCloudDrive, force: Bool = false) {
        guard item.id != itemID || force else { return }
        clear()
        itemID = item.id
        let request = generation
        task = Task { [weak self] in await self?.load(item, provider: provider, request: request) }
    }
    private func load(_ item: CloudDriveItem, provider: any NativeCloudDrive, request: UUID) async {
        guard generation == request, !Task.isCancelled else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MyCloudDriver-Media-\(UUID().uuidString)", isDirectory: true)
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: directory) } }
        message = provider.kind == .photos ? "Preparing media from Photos…"
            : provider.kind == .local ? "Opening local media…" : "Loading from iCloud Drive…"
        do {
            try CloudDriveFiles.privateDirectory(directory)
            let url = try await AutomaticRecovery.read(onRetry: { [weak self] _, delay in
                guard self?.generation == request else { return }
                self?.message = "Retrying preview in \(Int(delay))s…"
            }) { try await provider.materialize(item, directory: directory, progress: { [weak self] progress in
                Task { @MainActor in
                    guard let self, self.generation == request else { return }
                    self.message = progress.message
                    if let fraction = progress.fraction, fraction.isFinite { self.fraction = min(1, max(0, fraction)) }
                }
            }) }
            try Task.checkCancellation()
            guard generation == request else { return }
            let playableURL: URL
            if (item.name as NSString).pathExtension.lowercased() == "avi" {
                let copy = try await VideoPreviewPreparation.prepare(source: url) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.generation == request else { return }
                        self.message = progress.message; self.fraction = progress.fraction
                    }
                }
                try Task.checkCancellation()
                guard generation == request else { return }
                aviCopy = copy; playableURL = copy.url
            } else { playableURL = url }
            sourceURL = url
            ownedDirectory = directory; retained = true
            playback.attach(AVPlayer(url: playableURL)); ready = true
        } catch {
            guard generation == request, !Task.isCancelled else { return }
            failure = error.localizedDescription
        }
    }

    func recoverVideo(_ error: Error, player: AVPlayer, item: CloudDriveItem) {
        guard itemID == item.id, playback.player === player else { return }
        let resume = playback.position, autoplay = playback.wantsPlayback
        task?.cancel()
        playback.attach(nil); ready = false
        guard aviCopy == nil, VideoPreviewPreparation.isFormatFailure(error), let sourceURL,
              let format = VideoPreviewPreparation.InputFormat(fileExtension: (item.name as NSString).pathExtension.lowercased()) else {
            failure = error.localizedDescription
            return
        }
        let request = generation
        message = "Preparing compatible video preview…"; fraction = nil
        task = Task { [weak self] in
            do {
                let copy = try await VideoPreviewPreparation.prepare(source: sourceURL, format: format) { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.generation == request else { return }
                        self.message = progress.message; self.fraction = progress.fraction
                    }
                }
                try Task.checkCancellation()
                guard let self, self.generation == request else { return }
                self.aviCopy = copy
                self.playback.attach(AVPlayer(url: copy.url)); self.ready = true
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
                self.failure = error.localizedDescription
            }
        }
    }
    func clear() {
        task?.cancel(); task = nil; itemID = nil
        generation = UUID(); playback.attach(nil); ready = false; failure = nil; fraction = nil
        aviCopy = nil; sourceURL = nil
        if let ownedDirectory { try? FileManager.default.removeItem(at: ownedDirectory) }
        ownedDirectory = nil
    }
}

struct NativeMediaPreview: View {
    let item: CloudDriveItem
    let provider: any NativeCloudDrive
    @ObservedObject var model: NativeMediaPreviewModel
    var body: some View {
        Group {
            if model.ready {
                MediaPreviewView(playback: model.playback, isAudio: item.mediaType == "audio",
                    onVideoFailure: { model.recoverVideo($0, player: $1, item: item) })
            }
            else {
                VStack(spacing: 12) {
                    if let failure = model.failure {
                        Image(systemName: "exclamationmark.triangle").font(.title2)
                        Text("Preview unavailable").font(.headline)
                        Text(failure).font(.caption).multilineTextAlignment(.center).lineLimit(4)
                        Button("Retry Preview") { model.prepare(item, provider: provider, force: true) }
                    } else {
                        ProgressView(value: model.fraction).controlSize(.small)
                        Text(model.message).font(.caption).multilineTextAlignment(.center).lineLimit(3)
                    }
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.accentColor.opacity(0.05))
            }
        }.onAppear { model.prepare(item, provider: provider) }
            .onChange(of: item.id) { _ in model.prepare(item, provider: provider) }
    }
}

import Foundation
import AppKit
import AVFoundation

private actor Requests {
    var paths: [URL] = []
    var completed = 0
    func start(_ path: URL) { paths.append(path) }
    func finish() { completed += 1 }
}
private final class MediaProvider: NativeCloudDrive, @unchecked Sendable {
    let kind: CloudDriveKind
    let root: CloudDriveLocation
    let requests = Requests()
    let items: [CloudDriveItem]
    let delays: [String: UInt64]
    init(kind: CloudDriveKind = .photos, rootID: String = "test", items: [CloudDriveItem] = [], delays: [String: UInt64] = [:]) {
        self.kind = kind; root = .init(id: rootID, title: "Test")
        self.items = items; self.delays = delays
    }
    func materialize(_ item: CloudDriveItem, directory: URL, progress: @escaping CloudDriveProgressHandler) async throws -> URL {
        if let url = item.url {
            if let delay = delays[item.id] {
                await requests.start(url)
                // Simulate a decoder/provider that ignores caller cancellation.
                await Task.detached { try? await Task.sleep(nanoseconds: delay) }.value
                await requests.finish()
            }
            return url
        } // iCloud-style direct original
        let output = directory.appendingPathComponent(item.name)
        await requests.start(output)
        progress(.init(message: "Preparing test media", fraction: 0.4,
            bytes: item.id == "percentage" ? 0 : 40, fileSize: item.id == "percentage" ? 0 : 100,
            activity: item.id == "processing" ? .transferring : nil))
        if item.id == "processing" {
            try await Task.sleep(nanoseconds: 100_000_000)
            progress(.init(message: "Preparing a copy", activity: .processing))
            try await Task.sleep(nanoseconds: 100_000_000)
            progress(.init(message: "Late download", fraction: 1, bytes: 100, fileSize: 100, activity: .transferring))
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        if item.id == "slow" || item.id == "percentage" || item.id == "telemetry" {
            // Simulate a provider that finishes a write after cancellation.
            try? await Task.sleep(nanoseconds: item.id == "telemetry" ? 1_600_000_000 : 300_000_000)
            progress(.init(message: "Original ready", fraction: 1, bytes: 100, fileSize: 100))
        }
        if item.id == "error" { throw CloudDriveError.message("Test source unavailable") }
        try Data("synthetic placeholder".utf8).write(to: output)
        await requests.finish()
        return output
    }
    func list(_ location: CloudDriveLocation, offset: Int, search: String) async throws -> CloudDrivePage { .init(items: items, total: items.count) }
    func scanItems(_ items: [CloudDriveItem], location: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> [CloudDriveItem] { items }
    func createContainer(_ name: String, in location: CloudDriveLocation) async throws -> CloudDriveUndo? { nil }
    func rename(_ item: CloudDriveItem, to name: String) async throws -> CloudDriveUndo? { nil }
    func relocate(_ items: [CloudDriveItem], from: CloudDriveLocation, to: CloudDriveLocation, copy: Bool, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { nil }
    func importFiles(_ urls: [URL], into: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { nil }
    func delete(_ items: [CloudDriveItem], progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { nil }
}
@main @MainActor struct NativeMediaPreviewTests {
    static func wait(_ check: () async -> Bool) async {
        for _ in 0..<100 {
            if await check() { return }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        preconditionFailure("Timed out waiting for native preview")
    }
    static func main() async throws {
        let suite = "MyCloudDriver.NativeMediaTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = NativeMediaPreviewModel(settings: MediaPlaybackSettings(defaults: defaults))
        let provider = MediaProvider()
        let first = CloudDriveItem(id: "first", name: "First.mov", isFolder: false, mediaType: "video")
        model.prepare(first, provider: provider)
        await wait { model.ready }
        let player = model.playback.player
        model.prepare(first, provider: provider)
        precondition(model.playback.player === player, "Resizing/reappearing must not prepare the same file again")
        let initial = await provider.requests.paths
        precondition(initial.count == 1 && FileManager.default.fileExists(atPath: initial[0].path))
        precondition(model.sourceBufferStatus?.source == .cloud(.photos) && model.sourceBufferStatus?.phase == .available
            && model.sourceBufferStatus?.fraction == 1 && model.sourceBufferStatus?.bytesPerSecond == 0,
            "Photos keeps its buffering panel after the original is ready")
        model.clear()
        precondition(model.sourceBufferStatus == nil)
        precondition(!FileManager.default.fileExists(atPath: initial[0].deletingLastPathComponent().path))
        print("PASS native preview reuses its player across layout changes and cleans only its staging area")

        let slow = CloudDriveItem(id: "slow", name: "Slow.mov", isFolder: false, mediaType: "video")
        model.prepare(slow, provider: provider)
        await wait { model.fraction == 0.4 && model.sourceBufferStatus?.receivedBytes == 40 }
        precondition(model.sourceBufferStatus?.fraction == 0.4 && (model.sourceBufferStatus?.bytesPerSecond ?? 0) > 0)
        model.prepare(first, provider: provider)
        await wait {
            let completed = await provider.requests.completed
            return model.ready && model.itemID == first.id && completed == 3
        }
        let paths = await provider.requests.paths
        precondition(!FileManager.default.fileExists(atPath: paths[1].deletingLastPathComponent().path))
        precondition(model.itemID == first.id && model.ready)
        let preparedBytes = UInt64(try Data(contentsOf: paths[2]).count)
        precondition(model.sourceBufferStatus?.phase == .available && model.sourceBufferStatus?.fraction == 1
            && model.sourceBufferStatus?.receivedBytes == preparedBytes,
            "Late progress from a previous source cannot replace the completed buffer status")
        print("PASS progress, selection cancellation and cleanup after a late provider completion")

        let icloud = MediaProvider(kind: .icloud)
        let percentage = CloudDriveItem(id: "percentage", name: "Percentage.mov", isFolder: false, mediaType: "video")
        model.prepare(percentage, provider: icloud)
        precondition(model.sourceBufferStatus?.source == .cloud(.icloud), "iCloud has a panel from the start of preparation")
        await wait { model.sourceBufferStatus?.fraction == 0.4 }
        precondition(model.sourceBufferStatus?.bytesPerSecond == nil && model.sourceBufferStatus?.receivedBytes == nil,
            "A provider percentage without bytes must not invent transfer speed or byte counts")
        await wait { model.ready }
        precondition(model.sourceBufferStatus?.phase == .available && model.sourceBufferStatus?.fraction == 1)
        let telemetry = CloudDriveItem(id: "telemetry", name: "Telemetry.mov", isFolder: false, mediaType: "audio")
        model.prepare(telemetry, provider: provider)
        await wait { (model.sourceBufferStatus?.bytesPerSecond ?? 0) > 0 }
        await wait { model.sourceBufferStatus?.bytesPerSecond == 0 }
        precondition(model.sourceBufferStatus?.phase == .loading && model.sourceBufferStatus?.receivedBytes == 40,
            "Transfer speed decays during a source stall while preparation is still active")
        await wait { model.ready }
        model.clear()
        print("PASS iCloud and Photos panels show source progress, unknown throughput, idle decay and local availability for video and audio")

        model.prepare(.init(id: "processing", name: "Processing.mov", isFolder: false, mediaType: "video"), provider: provider)
        await wait { model.message == "Preparing a copy" }
        precondition(model.fraction == nil && model.sourceBufferStatus?.fraction == nil
            && model.sourceBufferStatus?.receivedBytes == nil && model.sourceBufferStatus?.bytesPerSecond == nil,
            "Processing must clear the preceding download percentage and rate")
        await wait { model.ready }
        precondition(model.sourceBufferStatus?.phase == .available)
        model.clear()
        print("PASS processing clears transfer metrics and ignores queued download updates")

        let original = FileManager.default.temporaryDirectory.appendingPathComponent("MediaOriginal-\(UUID().uuidString).mov")
        try Data("untouched original".utf8).write(to: original)
        defer { try? FileManager.default.removeItem(at: original) }
        model.prepare(.init(id: "original", name: "Original.mov", isFolder: false, url: original, mediaType: "video"), provider: provider)
        await wait { model.ready }
        model.clear()
        let contents = try String(contentsOf: original)
        precondition(contents == "untouched original")
        model.prepare(.init(id: "error", name: "Unavailable.mov", isFolder: false, mediaType: "video"), provider: provider)
        await wait { model.failure != nil }
        precondition(!model.ready && model.playback.player == nil)
        precondition(model.sourceBufferStatus?.phase == .failed && model.sourceBufferStatus?.bytesPerSecond == 0)
        model.clear()
        print("PASS direct originals survive cleanup; preparation errors remain retryable")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MediaIdentity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urlA = directory.appendingPathComponent("A.mov"), urlB = directory.appendingPathComponent("B.mov")
        try Data("generated A".utf8).write(to: urlA)
        try Data("generated B".utf8).write(to: urlB)
        let local = MediaProvider(kind: .local, rootID: directory.absoluteString)
        let a = CloudDriveItem(id: "same-id", name: "Selected.mov", isFolder: false, url: urlA, mediaType: "video", revision: "revision-A")
        var b = a; b.url = urlB
        model.prepare(a, provider: local)
        await wait { model.ready }
        let firstPlayer = model.playback.player
        precondition(model.matches(a, provider: local) && !model.matches(b, provider: local),
                     "A changed view must suppress the old player before its deferred prepare callback")
        model.prepare(b, provider: local)
        precondition(!model.ready && model.playback.player == nil)
        await wait { model.ready }
        precondition(model.playback.player !== firstPlayer && model.matches(b, provider: local))
        var changed = b; changed.revision = "revision-B"
        precondition(!model.matches(changed, provider: local))
        let secondPlayer = model.playback.player
        model.prepare(changed, provider: local)
        await wait { model.ready }
        precondition(model.playback.player !== secondPlayer, "Same-path file replacement must prepare a new player")
        let reconnected = MediaProvider(kind: .local, rootID: "reconnected-generated-root")
        precondition(!model.matches(changed, provider: reconnected), "Provider rebound cannot reuse another root's media")
        model.prepare(changed, provider: reconnected)
        await wait { model.ready }
        precondition(model.matches(changed, provider: reconnected) && !model.matches(changed, provider: local))
        model.clear()
        precondition(!model.matches(changed, provider: reconnected))
        print("PASS media source binding hides old players before prepare, including same-ID URL/revision and reconnected roots")

        func bitmap(_ color: NSColor) -> NSImage {
            let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            for x in 0..<2 { for y in 0..<2 { pixels.setColor(color, atX: x, y: y) } }
            let image = NSImage(size: .init(width: 2, height: 2)); image.addRepresentation(pixels)
            return image
        }
        let red = bitmap(.red), blue = bitmap(.blue)
        let identityA = NativeMediaSourceIdentity(item: a, kind: .local)
        let identityB = NativeMediaSourceIdentity(item: b, kind: .local)
        let identityChanged = NativeMediaSourceIdentity(item: changed, kind: .local)
        let oldImage = NativeMediaThumbnailSnapshot(identity: identityA, image: red)
        precondition(oldImage.image(for: identityA) === red)
        precondition(oldImage.image(for: identityB) == nil,
                     "A reused inspector must hide its old bitmap before the new thumbnail task starts")
        let newImage = NativeMediaThumbnailSnapshot(identity: identityB, image: blue)
        precondition(newImage.image(for: identityB) === blue && newImage.image(for: identityChanged) == nil)
        precondition(oldImage.image(for: identityB) == nil && oldImage.image(for: identityChanged) == nil,
                     "Even a late completion cannot label A's bitmap as B or a replaced file")
        precondition(oldImage.image(for: NativeMediaSourceIdentity(item: a, kind: .icloud)) == nil)
        print("PASS thumbnail snapshots bind generated bitmaps to the selected URL/revision/provider instead of reused view state")

        let late = MediaProvider()
        model.prepare(slow, provider: late)
        await wait { model.fraction == 0.4 }
        model.clear()
        await wait { await late.requests.completed == 1 }
        precondition(!model.ready && model.itemID == nil && model.sourceIdentity == nil && model.playback.player == nil,
                     "A provider completing after close cannot restore media or source identity")
        precondition(model.sourceBufferStatus == nil, "Late progress after close cannot restore a buffering panel")
        let latePaths = await late.requests.paths
        precondition(latePaths.count == 1 && !FileManager.default.fileExists(atPath: latePaths[0].deletingLastPathComponent().path))
        print("PASS late completion after preview close preserves the cleared selection and removes only generated staging")

        let colors: [NSColor] = [.red, .green, .blue, .purple, .orange, .cyan, .magenta]
        let images = colors.map(bitmap)
        let rows: [CloudDriveItem] = try (0..<7).map { index in
            let url = directory.appendingPathComponent("RoundTrip-\(index).mov")
            try Data("generated distinct media \(index)".utf8).write(to: url)
            return .init(id: "roundtrip-\(index)", name: "Repeated title.mov", isFolder: false,
                url: url, mediaType: "video", revision: "generated-\(index)")
        }
        let delays = Dictionary(uniqueKeysWithValues: rows.enumerated().map {
            ($0.element.id, $0.offset == 3 ? UInt64(40_000_000) : UInt64(200_000_000 + $0.offset * 10_000_000))
        })
        for offsets in [[-1, -1, 1, 1], [1, 1, -1, -1]] {
            let provider = MediaProvider(kind: .local, rootID: directory.absoluteString, items: rows, delays: delays)
            let browser = NativeDriveModel(kind: .local, temporaryRoot: directory.appendingPathComponent("RoundTripStaging-\(UUID())"),
                playbackSettings: .init(defaults: defaults))
            defer { browser.close() }
            browser.connect(provider)
            await wait { !browser.isLoading && browser.visibleRows.count == 7 }
            browser.select(browser.visibleRows[3], extending: false, toggling: false)
            let originalRow = browser.focusedRowID!, originalItem = browser.inspectorItem!
            let originalIdentity = browser.inspectorPreviewIdentity!
            browser.mediaPreview.prepare(originalItem, provider: provider)
            await wait { browser.mediaPreview.ready }
            let thumbnail = NativeMediaThumbnailModel(), thumbnailRequests = Requests()
            await thumbnail.load(identity: originalIdentity) { images[3] }
            var decoders: [Task<Void, Never>] = []
            for (step, offset) in offsets.enumerated() {
                browser.moveSelection(offset)
                let current = browser.inspectorItem!, identity = browser.inspectorPreviewIdentity!
                let index = rows.firstIndex(where: { $0.id == current.id })!
                precondition(index > 0 && index < 6, "Fixture navigation must never clamp at an edge")
                precondition(!browser.mediaPreview.matches(current, provider: provider)
                    && thumbnail.snapshot?.image(for: identity) == nil,
                    "The new title cannot render the previous row's media before its async task starts")
                browser.selectionChanged(); browser.mediaPreview.prepare(current, provider: provider)
                // Leave older requests running deliberately: their decoder
                // completion must not overwrite the final selected bitmap.
                decoders.append(Task {
                    await thumbnail.load(identity: identity) {
                        await thumbnailRequests.start(current.url!)
                        await Task.detached { try? await Task.sleep(nanoseconds: delays[current.id]!) }.value
                        await thumbnailRequests.finish()
                        return images[index]
                    }
                })
                await wait {
                    let mediaCount = await provider.requests.paths.count
                    let imageCount = await thumbnailRequests.paths.count
                    return mediaCount == step + 2 && imageCount == step + 1
                }
            }
            await wait { browser.mediaPreview.ready && thumbnail.snapshot?.image(for: originalIdentity) != nil }
            for decoder in decoders { await decoder.value }
            await wait { await provider.requests.completed == 5 }
            let playerURL = (browser.mediaPreview.playback.player!.currentItem!.asset as! AVURLAsset).url
            precondition(browser.focusedRowID == originalRow && browser.inspectorPreviewIdentity == originalIdentity
                && browser.mediaPreview.matches(originalItem, provider: provider) && playerURL == originalItem.url
                && thumbnail.snapshot?.identity == originalIdentity && thumbnail.snapshot?.image(for: originalIdentity) === images[3],
                "Up/Up/Down/Down and reverse must restore the same file, player and generated bitmap after late out-of-order completions")
            let content = try Data(contentsOf: playerURL)
            precondition(content == Data("generated distinct media 3".utf8))
            thumbnail.clear()
        }
        print("PASS exact Up/Up/Down/Down and Down/Down/Up/Up round trips restore occurrence, source, player content and bitmap despite repeated titles and out-of-order loaders")

        let closedThumbnail = NativeMediaThumbnailModel()
        let closingRequests = Requests()
        let closing = Task {
            await closedThumbnail.load(identity: identityA) {
                await closingRequests.start(urlA)
                await Task.detached { try? await Task.sleep(nanoseconds: 60_000_000) }.value
                return red
            }
        }
        await wait { await closingRequests.paths.count == 1 }
        closedThumbnail.clear(); await closing.value
        precondition(closedThumbnail.snapshot == nil, "A thumbnail completion after close cannot restore its bitmap")
        print("PASS thumbnail clear rejects late decoder completion independently of task cancellation")
    }
}

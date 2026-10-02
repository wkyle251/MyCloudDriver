import Foundation

private actor Requests {
    var paths: [URL] = []
    var completed = 0
    func start(_ path: URL) { paths.append(path) }
    func finish() { completed += 1 }
}
private final class MediaProvider: NativeCloudDrive, @unchecked Sendable {
    let kind = CloudDriveKind.photos
    let root = CloudDriveLocation(id: "test", title: "Test")
    let requests = Requests()
    func materialize(_ item: CloudDriveItem, directory: URL, progress: @escaping CloudDriveProgressHandler) async throws -> URL {
        if let url = item.url { return url } // iCloud-style direct original
        let output = directory.appendingPathComponent(item.name)
        await requests.start(output)
        progress(.init(message: "Preparing test media", fraction: 0.4))
        if item.id == "slow" {
            // Simulate a provider that finishes a write after cancellation.
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        if item.id == "error" { throw CloudDriveError.message("Test source unavailable") }
        try Data("synthetic placeholder".utf8).write(to: output)
        await requests.finish()
        return output
    }
    func list(_ location: CloudDriveLocation, offset: Int, search: String) async throws -> CloudDrivePage { .init(items: [], total: 0) }
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
        model.clear()
        precondition(!FileManager.default.fileExists(atPath: initial[0].deletingLastPathComponent().path))
        print("PASS native preview reuses its player across layout changes and cleans only its staging area")

        let slow = CloudDriveItem(id: "slow", name: "Slow.mov", isFolder: false, mediaType: "video")
        model.prepare(slow, provider: provider)
        await wait { model.fraction == 0.4 }
        model.prepare(first, provider: provider)
        await wait {
            let completed = await provider.requests.completed
            return model.ready && model.itemID == first.id && completed == 3
        }
        let paths = await provider.requests.paths
        precondition(!FileManager.default.fileExists(atPath: paths[1].deletingLastPathComponent().path))
        precondition(model.itemID == first.id && model.ready)
        print("PASS progress, selection cancellation and cleanup after a late provider completion")

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
        model.clear()
        print("PASS direct originals survive cleanup; preparation errors remain retryable")
    }
}

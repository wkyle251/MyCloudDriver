import AppKit
import Foundation
@preconcurrency import QuickLookThumbnailing

/// Synthetic image representation that blocks until the test releases it.
/// A synchronous main-actor decode would prevent the heartbeat from running.
private final class BitmapGate: @unchecked Sendable {
    private let lock = NSLock()
    private let release = DispatchGroup()
    private var entered = false
    private var mainThread = false
    private var released = false
    init() { release.enter() }
    var started: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    var ranOnMain: Bool { lock.lock(); defer { lock.unlock() }; return mainThread }
    func draw() -> Bool {
        lock.lock(); entered = true; mainThread = mainThread || Thread.isMainThread; lock.unlock()
        precondition(release.wait(timeout: .now() + 5) == .success, "Generated bitmap fixture was not released")
        NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        return true
    }
    func finish() {
        lock.lock()
        guard !released else { lock.unlock(); return }
        released = true; lock.unlock(); release.leave()
    }
}

private actor SimilarityWriterGate {
    private(set) var folders: [String: URL] = [:]
    private var pending: [String: CheckedContinuation<URL, Error>] = [:]
    func prepare(_ file: SimilarityFile, folder: URL) async throws -> URL {
        folders[file.id] = folder
        // Deliberately ignore task cancellation while this writer owns its
        // lease, just as an in-progress File Provider export may do.
        return try await withCheckedThrowingContinuation { pending[file.id] = $0 }
    }
    func finish(_ id: String) throws {
        let output = folders[id]!.appendingPathComponent("Generated.txt")
        try Data("generated preview".utf8).write(to: output)
        pending.removeValue(forKey: id)!.resume(returning: output)
    }
}

private final class QuickLookGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: NativeQuickLookThumbnailTransfer.Completion?
    private var request: QLThumbnailGenerator.Request?
    private var count = 0
    private var cancellations = 0
    private var mainThread = false
    var starts: Int { lock.lock(); defer { lock.unlock() }; return count }
    var cancels: Int { lock.lock(); defer { lock.unlock() }; return cancellations }
    var ranOnMain: Bool { lock.lock(); defer { lock.unlock() }; return mainThread }
    func generate(_ request: QLThumbnailGenerator.Request,
                  completion: @escaping NativeQuickLookThumbnailTransfer.Completion) {
        lock.lock(); count += 1; mainThread = Thread.isMainThread
        self.request = request; self.completion = completion; lock.unlock()
    }
    func cancel(_ request: QLThumbnailGenerator.Request) { lock.lock(); cancellations += 1; lock.unlock() }
    func finish() {
        lock.lock(); let completion = completion; self.completion = nil; request = nil; lock.unlock()
        completion?(nil)
    }
}

@main @MainActor struct NativePreviewFreezeTests {
    static func until(_ check: () async -> Bool, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await check()) && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        let passed = await check()
        precondition(passed, "Generated preview fixture timed out at line \(line)")
    }
    static func identity(_ id: String) -> NativeMediaSourceIdentity {
        .init(item: .init(id: id, name: "Generated.png", isFolder: false, bytes: 256,
            url: URL(fileURLWithPath: "/private/tmp/generated-preview-\(id).png"), mediaType: "image"),
            kind: .local, rootID: "generated-root")
    }
    static func file(_ id: String, localPath: String? = nil) -> SimilarityFile {
        .init(id: id, name: "Generated.txt", path: "Generated.txt", bytes: 17,
            family: "document", localPath: localPath, cloudId: localPath == nil ? id : nil, ancestors: [])
    }
    static func main() async throws {
        _ = NSApplication.shared
        let gate = BitmapGate()
        defer { gate.finish() }
        let image = NSImage(size: .init(width: 8, height: 8), flipped: false) { _ in gate.draw() }
        var loads = 0
        let cache = NativeThumbnailCache(concurrency: 2) { _ in loads += 1; return image }
        let first = Task { await cache.image(for: identity("first")) }
        try await until { gate.started }
        precondition(!gate.ranOnMain, "Bitmap representation work must stay off AppKit's thread")
        var heartbeats = 0
        for _ in 0..<6 { try await Task.sleep(nanoseconds: 10_000_000); heartbeats += 1 }
        precondition(heartbeats == 6)
        first.cancel()
        let cancelled = await first.value
        precondition(cancelled == nil)
        let next = Task { await cache.image(for: identity("next"), priority: .prefetch) }
        try await Task.sleep(nanoseconds: 40_000_000)
        precondition(loads == 1, "A cancelled bitmap reader retains its slot until its representation work stops")
        gate.finish()
        let completed = await next.value
        precondition(completed != nil && completed !== image && cache.cachedImage(for: identity("first")) == nil,
            "A drawing-backed representation must become a bitmap-only image before publication")
        precondition(cache.cachedImage(for: identity("next")) === completed)
        print("PASS blocked bitmap conversion leaves main responsive, cancels its consumer promptly, retains reader capacity and rejects stale artwork")

        let callbacks = QuickLookGate()
        var transfer: NativeQuickLookThumbnailTransfer? = NativeQuickLookThumbnailTransfer(timeout: 0.25,
            generate: callbacks.generate, cancel: callbacks.cancel)
        weak var expiredTransfer = transfer
        var returned = 0
        var callbackTask: Task<QLThumbnailRepresentation?, Never>? = Task { [request = transfer!] in
            defer { withExtendedLifetime(request) {} }
            let result = await withTaskCancellationHandler(operation: {
                await withCheckedContinuation { continuation in
                    request.start(url: URL(fileURLWithPath: "/private/tmp/generated-callback-thumbnail.png"), continuation: continuation)
                }
            }, onCancel: { request.cancel() })
            returned += 1
            return result
        }
        try await until { callbacks.starts == 1 }
        precondition(!callbacks.ranOnMain)
        callbackTask!.cancel()
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(returned == 0, "A submitted request keeps its reader until callback/deadline")
        let expired = await callbackTask!.value
        precondition(expired == nil && returned == 1)
        try await until { callbacks.cancels > 0 }
        callbackTask = nil; transfer = nil
        try await until { expiredTransfer == nil }
        callbacks.finish()
        try await Task.sleep(nanoseconds: 10_000_000)
        precondition(returned == 1, "Late framework callbacks must not resume a completed waiter twice")
        let cancelledBeforeStart = NativeQuickLookThumbnailTransfer(timeout: 0.1,
            generate: callbacks.generate, cancel: callbacks.cancel)
        cancelledBeforeStart.cancel()
        let beforeStart = await withCheckedContinuation { continuation in
            cancelledBeforeStart.start(url: URL(fileURLWithPath: "/private/tmp/generated-cancelled-thumbnail.png"), continuation: continuation)
        }
        precondition(beforeStart == nil && callbacks.starts == 1)
        print("PASS stalled Quick Look callbacks hit a deadline, cancel their request, release expired state despite a retained framework callback, reject late completion and skip pre-cancelled work")

        let writers = SimilarityWriterGate(), model = SimilarityPreviewModel()
        let old = file("old"), current = file("current")
        let prepare: (SimilarityFile, URL) async throws -> URL = { file, folder in
            try await writers.prepare(file, folder: folder)
        }
        model.show(old, prepare: prepare)
        try await until { await writers.folders[old.id] != nil }
        let oldFolder = await writers.folders[old.id]!
        model.show(current, prepare: prepare)
        try await until { await writers.folders[current.id] != nil }
        let currentFolder = await writers.folders[current.id]!
        precondition(FileManager.default.fileExists(atPath: oldFolder.path), "Cancellation must retain a folder while its provider still writes")
        try await writers.finish(old.id)
        try await until { !FileManager.default.fileExists(atPath: oldFolder.path) }
        precondition(model.quickLook.itemID == current.id && FileManager.default.fileExists(atPath: currentFolder.path))
        model.close()
        precondition(!model.isActive && FileManager.default.fileExists(atPath: currentFolder.path))
        try await writers.finish(current.id)
        try await until { !FileManager.default.fileExists(atPath: currentFolder.path) }
        precondition(!model.isActive)
        print("PASS similarity selection/close discard late providers and preserve staging folders until their last writer stops")

        let original = FileManager.default.temporaryDirectory.appendingPathComponent("Generated-original-\(UUID()).txt")
        try Data("generated original".utf8).write(to: original)
        defer { try? FileManager.default.removeItem(at: original) }
        model.show(file("local", localPath: original.path), prepare: nil)
        try await Task.sleep(nanoseconds: 50_000_000)
        model.close()
        precondition(FileManager.default.fileExists(atPath: original.path), "Preview cleanup must never remove an original")
        print("PASS similarity local preview cleanup preserves the generated original")
    }
}

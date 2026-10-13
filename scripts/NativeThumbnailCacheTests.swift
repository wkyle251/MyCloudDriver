import AppKit
import Foundation

@main @MainActor struct NativeThumbnailCacheTests {
    final class Gate {
        var requests: [NativeMediaSourceIdentity] = []
        var pending: [Int: CheckedContinuation<NSImage?, Never>] = [:]
        func load(_ identity: NativeMediaSourceIdentity) async -> NSImage? {
            let index = requests.count; requests.append(identity)
            // Deliberately ignore cancellation to exercise late readers.
            return await withCheckedContinuation { pending[index] = $0 }
        }
        func finish(_ index: Int, _ image: NSImage?) { pending.removeValue(forKey: index)!.resume(returning: image) }
    }
    static func until(_ condition: () -> Bool, line: UInt = #line) async throws {
        let end = Date().addingTimeInterval(3)
        while !condition() && Date() < end { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(condition(), "Timed out at line \(line)")
    }
    static func bitmap(_ color: NSColor) -> NSImage {
        let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32)!
        for x in 0..<2 { for y in 0..<2 { pixels.setColor(color, atX: x, y: y) } }
        let image = NSImage(size: .init(width: 2, height: 2)); image.addRepresentation(pixels); return image
    }
    static func item(_ id: String) -> CloudDriveItem {
        .init(id: id, name: "\(id).png", isFolder: false, bytes: 16,
            url: URL(fileURLWithPath: "/private/tmp/generated-thumbnail-\(id).png"), mediaType: "image", revision: "one")
    }
    static func identity(_ id: String, root: String = "generated-root") -> NativeMediaSourceIdentity {
        .init(item: item(id), kind: .local, rootID: root)
    }
    static func main() async throws {
        let red = bitmap(.red), blue = bitmap(.blue)
        let gate = Gate(), cache = NativeThumbnailCache(load: gate.load)
        let a = identity("a")
        var backgroundImage: NSImage?, selected: NSImage?
        let background = Task { backgroundImage = await cache.image(for: a, priority: .prefetch) }
        try await until { gate.requests.count == 1 }
        let visible = Task { selected = await cache.image(for: a) }
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(gate.requests.count == 1, "Grid, inspector and prefetch must share one reader")
        background.cancel()
        await background.value
        precondition(backgroundImage == nil)
        gate.finish(0, red)
        await visible.value
        precondition(selected === red && cache.cachedImage(for: a) === red)
        let cached = await cache.image(for: a)
        precondition(cached === red && gate.requests.count == 1)
        print("PASS thumbnail request coalescing, shared-consumer cancellation and immediate RAM reuse")

        let slow = Gate(), priority = NativeThumbnailCache(concurrency: 2, load: slow.load)
        let warming = Task { _ = await priority.image(for: identity("slow"), priority: .prefetch) }
        try await until { slow.requests.count == 1 }
        let queued = Task { _ = await priority.image(for: identity("queued"), priority: .prefetch) }
        let clicked = Task { _ = await priority.image(for: identity("clicked")) }
        try await until { slow.requests.count == 2 }
        precondition(slow.requests.map(\.itemID) == ["slow", "clicked"], "Selected images must pass background prefetch")
        warming.cancel(); _ = await warming.value
        slow.finish(0, red)
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(slow.requests.count == 2, "Cancelled readers retain capacity until they finish; only one background read runs")
        slow.finish(1, blue); _ = await clicked.value
        try await until { slow.requests.count == 3 }
        slow.finish(2, red); _ = await queued.value
        precondition(priority.cachedImage(for: identity("slow")) == nil, "A cancelled late reader must not refill the cache")
        print("PASS bounded background readers, visible priority and rejection of late cancelled thumbnails")

        var reads: [NativeMediaSourceIdentity: Int] = [:]
        let bitmap = red.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let tiny = NativeThumbnailCache(memoryLimit: bitmap.bytesPerRow * bitmap.height, entryLimit: 2) { key in reads[key, default: 0] += 1; return red }
        _ = await tiny.image(for: a); _ = await tiny.image(for: identity("b"))
        precondition(tiny.cachedImage(for: a) == nil && tiny.cachedImage(for: identity("b")) != nil)
        _ = await tiny.image(for: a)
        precondition(reads[a] == 2, "Eviction must obey decoded bitmap memory cost")
        var replaced = item("a"); replaced.revision = "two"
        let revised = NativeMediaSourceIdentity(item: replaced, kind: .local, rootID: "generated-root")
        _ = await tiny.image(for: revised); _ = await tiny.image(for: identity("a", root: "reconnected-root"))
        precondition(reads[revised] == 1 && reads[identity("a", root: "reconnected-root")] == 1)
        var unavailable = item("placeholder"); unavailable.isDownloaded = false
        let placeholder = await tiny.image(for: .init(item: unavailable, kind: .icloud))
        precondition(placeholder == nil)
        precondition(reads.count == 4, "Cloud placeholders must not download originals to make a thumbnail")
        var failures = 0
        let missing = NativeThumbnailCache { _ in failures += 1; return nil }
        _ = await missing.image(for: a); _ = await missing.image(for: a)
        precondition(failures == 1, "Unavailable artwork must not repeatedly hit the disk while scrolling")
        print("PASS memory eviction, revision/root isolation, cloud placeholders and bounded failure caching")

        var loaded: [String] = [], pages: [Int] = []
        let folderCache = NativeThumbnailCache { key in loaded.append(key.itemID); return red }
        let folder = NativeFolderThumbnailPrefetcher(cache: folderCache)
        let context = NativeFolderThumbnailPrefetcher.Context(kind: .local, rootID: "generated-root", folderID: "folder", query: "")
        let container = CloudDriveItem(id: "subfolder", name: "Subfolder", isFolder: true)
        folder.start(context: context, items: [item("a"), item("a"), container], nextOffset: 2) { offset in
            pages.append(offset); return .init(items: [item("b"), item("a")], nextOffset: 2)
        }
        try await until { !folder.isRunning }
        precondition(loaded == ["a", "b"] && pages == [2], "Prefetch must cover sibling pages once without entering subfolders")
        folder.start(context: context, items: [item("a")], nextOffset: 2) { _ in preconditionFailure("Same folder should reuse prefetch") }
        precondition(!folder.isRunning && pages == [2])

        // Warming a huge folder stops at a bounded number of images, which would only evict one another.
        var capLoads: [String] = []
        let cappedCache = NativeThumbnailCache { key in capLoads.append(key.itemID); return red }
        let capped = NativeFolderThumbnailPrefetcher(cache: cappedCache, maximumLoads: 40)
        capped.start(context: context, items: (0..<500).map { item("many-\($0)") }, nextOffset: 10) { _ in
            preconditionFailure("A capped prefetch must not read further pages")
        }
        try await until { !capped.isRunning }
        precondition(capLoads.count == 40 && capLoads.first == "many-0" && capLoads.last == "many-39", "Only the first \(capLoads.count) images were warmed")
        let siblings = (0..<6).map { item("s\($0)") }
        precondition(NativeFolderThumbnailPrefetcher.order(siblings, startingAt: "s3").map(\.id) == ["s3", "s4", "s5", "s0", "s1", "s2"],
                     "Warming starts at the selected file and wraps")
        precondition(NativeFolderThumbnailPrefetcher.order(siblings, startingAt: "missing").map(\.id) == siblings.map(\.id))
        precondition(NativeFolderThumbnailPrefetcher.order(siblings, startingAt: nil).map(\.id) == siblings.map(\.id))
        print("PASS folder warming is bounded and starts at the selected file")

        let switching = Gate(), switchingCache = NativeThumbnailCache(load: switching.load)
        let navigation = NativeFolderThumbnailPrefetcher(cache: switchingCache)
        var obsoletePage = false
        navigation.start(context: context, items: [item("old")], nextOffset: 2) { _ in obsoletePage = true; return .init(items: [], nextOffset: nil) }
        try await until { switching.requests.count == 1 }
        navigation.cancel()
        let next = NativeFolderThumbnailPrefetcher.Context(kind: .local, rootID: "generated-root", folderID: "other-folder", query: "")
        navigation.start(context: next, items: [item("new")], nextOffset: nil) { _ in preconditionFailure() }
        switching.finish(0, red)
        try await until { switching.requests.count == 2 }
        switching.finish(1, blue)
        try await until { !navigation.isRunning }
        precondition(!obsoletePage && navigation.context == next)
        precondition(switchingCache.cachedImage(for: identity("old")) == nil && switchingCache.cachedImage(for: identity("new")) === blue)
        print("PASS current-folder pagination, duplicate/cycle protection and navigation cancelling obsolete work")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeThumbnailFixture-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let png = root.appendingPathComponent("Generated.png")
        try (red.representations.first as! NSBitmapImageRep).representation(using: .png, properties: [:])!.write(to: png)
        let provider = ICloudDriveProvider(rootURL: root, kind: .local)
        var warmed: [NativeMediaSourceIdentity] = []
        let browserCache = NativeThumbnailCache { key in warmed.append(key); return await NativeThumbnailGenerator.load(key) }
        let browser = NativeDriveModel(kind: .local, thumbnailCache: browserCache)
        defer { browser.close() }
        browser.connect(provider)
        try await until { !browser.isLoading && !warmed.isEmpty }
        let key = warmed[0]
        try await until { browserCache.cachedImage(for: key) != nil }
        precondition(key.rootID == provider.root.id && key.url == png)
        let image = await browserCache.image(for: key)
        precondition(image != nil && warmed.count == 1, "Browsing a folder must warm real Quick Look artwork before selection")
        browser.disconnect()
        print("PASS native browser automatically warms a generated file through real Quick Look, without selecting or materializing it")
    }
}

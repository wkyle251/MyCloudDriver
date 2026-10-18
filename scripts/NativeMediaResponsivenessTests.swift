import AppKit
import Foundation

private final class GeneratedMetadataGate: @unchecked Sendable {
    private let lock = NSLock()
    private let resume = DispatchSemaphore(value: 0)
    private var count = 0
    private var blocked = false
    private var released = false
    private var completed = false
    let target: URL
    init(_ target: URL) { self.target = target }
    var started: Bool { lock.lock(); defer { lock.unlock() }; return blocked }
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return completed }
    var probes: Int { lock.lock(); defer { lock.unlock() }; return count }
    func inspect(_ url: URL) -> ExternalVolume.Kind? {
        precondition(!Thread.isMainThread, "Source metadata must not run on AppKit")
        lock.lock(); count += 1
        let shouldBlock = url.path == target.path
        if shouldBlock { blocked = true }
        lock.unlock()
        if shouldBlock {
            precondition(resume.wait(timeout: .now() + 5) == .success)
            lock.lock(); completed = true; lock.unlock()
        }
        return nil
    }
    func finish() { lock.lock(); let signal = !released; released = true; lock.unlock(); if signal { resume.signal() } }
}

@main @MainActor struct NativeMediaResponsivenessTests {
    static func until(_ check: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !check() {
            precondition(ProcessInfo.processInfo.systemUptime < deadline, "Generated preview did not settle")
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
    static func main() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("NativeMediaResponsiveness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let header = Data([0, 0, 0, 16, 102, 116, 121, 112, 105, 115, 111, 109, 0, 0, 0, 0])
        for number in 0..<3 { try header.write(to: root.appendingPathComponent("Generated-\(number).mp4")) }
        let provider = try await NativeFileWork.run { ICloudDriveProvider(rootURL: root, kind: .local) }
        let domain = "NativeMediaResponsiveness.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let browser = NativeDriveModel(kind: .local, temporaryRoot: root.appendingPathComponent("staging"),
            playbackSettings: .init(defaults: defaults), thumbnailCache: .init(load: { _ in nil }), preferences: defaults)
        defer { browser.close() }
        browser.setThumbnailPrefetchActive(false)
        browser.mediaPreview.selectionDelayNanoseconds = 0
        browser.connect(provider)
        try await until { !browser.isLoading && browser.visibleRows.count == 3 }

        // A Down-arrow starts a slow source; the next Down must remain usable
        // and finish its own preview before the previous storage call returns.
        let gate = GeneratedMetadataGate(browser.visibleRows[0].item.url!)
        defer { gate.finish() }
        browser.mediaPreview.bufferedVolume = { gate.inspect($0) }
        let prepareAt = ProcessInfo.processInfo.systemUptime
        browser.moveSelection(1); browser.selectionChanged()
        browser.mediaPreview.prepare(browser.focusedItem!, provider: provider)
        precondition(ProcessInfo.processInfo.systemUptime - prepareAt < 0.2)
        try await until { gate.started }
        var heartbeats = 0
        for _ in 0..<10 { try await Task.sleep(nanoseconds: 10_000_000); heartbeats += 1 }
        precondition(heartbeats == 10 && !gate.finished)
        browser.moveSelection(1); browser.selectionChanged()
        let current = browser.focusedItem!
        browser.mediaPreview.prepare(current, provider: provider)
        try await until { browser.mediaPreview.ready }
        precondition(browser.mediaPreview.matches(current, provider: provider) && !gate.finished,
                     "New arrows must proceed without waiting for canceled metadata")
        precondition(gate.probes == 2, "Each original needs one volume probe, rather than three")
        gate.finish(); try await until { gate.finished }
        try await Task.sleep(nanoseconds: 40_000_000)
        precondition(browser.mediaPreview.matches(current, provider: provider) && browser.mediaPreview.ready)
        print("PASS Down/Down selection and UI heartbeat continue during blocked metadata; late results cannot replace the current preview")

        browser.mediaPreview.clear()
        let timeoutGate = GeneratedMetadataGate(browser.visibleRows[2].item.url!)
        defer { timeoutGate.finish() }
        browser.mediaPreview.bufferedVolume = { timeoutGate.inspect($0) }
        browser.mediaPreview.preparationTimeout = 0.15
        browser.moveSelection(1); browser.selectionChanged()
        browser.mediaPreview.prepare(browser.focusedItem!, provider: provider)
        try await until { timeoutGate.started }
        let timeoutAt = ProcessInfo.processInfo.systemUptime
        try await until { browser.mediaPreview.failure != nil }
        precondition(ProcessInfo.processInfo.systemUptime - timeoutAt < 1 && !timeoutGate.finished)
        browser.mediaPreview.clear()
        timeoutGate.finish(); try await until { timeoutGate.finished }
        try await Task.sleep(nanoseconds: 40_000_000)
        precondition(browser.mediaPreview.sourceIdentity == nil && browser.mediaPreview.playback.player == nil)
        print("PASS unavailable storage reaches a finite preview failure; closing rejects the late completion")
    }
}

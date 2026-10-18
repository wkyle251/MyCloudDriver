import AppKit
import Foundation

private final class BrowserValidationGate: @unchecked Sendable {
    private let lock = NSLock(), released = DispatchSemaphore(value: 0)
    private var entered = false
    private var calls = 0
    var started: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    func block() {
        lock.lock(); entered = true; lock.unlock()
        precondition(released.wait(timeout: .now() + 8) == .success, "Generated validation fixture was not released")
    }
    func finish() { released.signal() }
    func blockFirst() {
        lock.lock(); calls += 1; let first = calls == 1; lock.unlock()
        if first { block() }
    }
}

@main @MainActor struct NativeBrowserResponsivenessTests {
    static func until(_ check: () -> Bool, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !check() && Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(check(), "Generated browser fixture timed out at line \(line)")
    }
    static func main() async throws {
        _ = NSApplication.shared
        let manager = FileManager.default
        let root = manager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("GeneratedBrowser-\(UUID())")
        let first = root.appendingPathComponent("A", isDirectory: true), second = root.appendingPathComponent("B", isDirectory: true)
        try manager.createDirectory(at: first, withIntermediateDirectories: true)
        try manager.createDirectory(at: second, withIntermediateDirectories: true)
        try Data("generated".utf8).write(to: second.appendingPathComponent("Generated.txt"))
        defer { try? manager.removeItem(at: root) }
        let suite = "GeneratedBrowser.\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstDrive = ICloudDriveProvider(rootURL: first, kind: .local)
        let secondDrive = ICloudDriveProvider(rootURL: second, kind: .local)
        let gate = BrowserValidationGate()
        let model = NativeDriveModel(kind: .local, thumbnailCache: NativeThumbnailCache { _ in nil }, preferences: defaults,
            availabilityValidation: { drive in if drive === firstDrive { gate.block() }; try drive.validateAccess() })
        defer { model.close() }
        model.setThumbnailPrefetchActive(false)
        model.connect(firstDrive)
        precondition(model.isLoading, "Connection must be visibly pending before its worker is scheduled")
        try await until { gate.started }
        for _ in 0..<6 { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(model.isCheckingAvailability && model.isLoading, "Main-actor work must run while the generated disk check is blocked")
        model.connect(secondDrive)
        try await until { !model.isLoading }
        precondition(model.provider === secondDrive && model.isConnected && model.items.count == 1)
        gate.finish()
        try await Task.sleep(nanoseconds: 30_000_000)
        precondition(model.provider === secondDrive && model.isConnected && !model.isCheckingAvailability)
        print("PASS blocked drive validation leaves the main actor responsive; reconnect rejects its late result")

        let recoveryGate = BrowserValidationGate()
        let retained = NativeDriveModel(kind: .local, preferences: defaults,
            availabilityValidation: { drive in recoveryGate.blockFirst(); try drive.validateAccess() })
        retained.setThumbnailPrefetchActive(false)
        retained.connect(firstDrive)
        try await until { recoveryGate.started }
        retained.beginConnectionCheck()
        retained.finishConnectionCheck(error: CloudDriveError.message("Generated replacement connection failed"))
        try await until { !retained.isLoading }
        precondition(retained.provider === firstDrive && retained.isConnected && !retained.isCheckingAvailability,
            "A failed replacement must restart a retained provider's interrupted initial validation")
        recoveryGate.finish(); retained.close()
        print("PASS failed replacement resumes initial validation of the retained provider")

        let sharedGate = BrowserValidationGate()
        let shared = NativeDriveModel(kind: .local, preferences: defaults,
            availabilityValidation: { drive in sharedGate.blockFirst(); try drive.validateAccess() })
        shared.setThumbnailPrefetchActive(false)
        shared.connect(secondDrive)
        try await until { sharedGate.started }
        // Mount notifications and navigation can arrive in either order while
        // the same check is pending. Keep replacing their consumers, then let
        // the original worker finish and ensure the current listing wins.
        for _ in 0..<6 { shared.refreshAvailability(); shared.reload(); await Task.yield() }
        sharedGate.finish()
        for _ in 0..<6 { shared.refreshAvailability(); shared.reload(); await Task.yield() }
        try await until { !shared.isLoading && !shared.isCheckingAvailability }
        precondition(shared.provider === secondDrive && shared.isConnected && shared.items.count == 1 && shared.error == nil)
        shared.close()
        print("PASS coalesced refresh/reload consumers preserve the newest listing after their shared check completes")

        let timeoutGate = BrowserValidationGate()
        let timeoutModel = NativeDriveModel(kind: .local, preferences: defaults, availabilityTimeout: 0.08,
            availabilityValidation: { drive in timeoutGate.block(); try drive.validateAccess() })
        timeoutModel.setThumbnailPrefetchActive(false)
        timeoutModel.connect(firstDrive)
        try await until { timeoutGate.started }
        try await until { !timeoutModel.isLoading }
        precondition(!timeoutModel.isConnected && timeoutModel.availabilityMessage != nil && !timeoutModel.isCheckingAvailability)
        timeoutGate.finish(); timeoutModel.close()
        let identityModel = NativeDriveModel(kind: .local, preferences: defaults)
        identityModel.connect(ICloudDriveProvider(rootURL: second, kind: .local, volumeID: "generated-wrong-volume"))
        try await until { !identityModel.isLoading }
        precondition(!identityModel.isConnected && identityModel.items.isEmpty, "Background validation must retain mounted-volume identity checks")
        identityModel.close()
        print("PASS validation timeout releases loading state and the original-disk identity check remains enforced")

        let generated = await Task.detached {
            (0..<100_000).map { index in CloudDriveItem(id: "generated-\(index)", name: "Generated-\(index).\(index % 2 == 0 ? "txt" : "png")", isFolder: false) }
        }.value
        let published = await model.tree.replaceRootsPrepared(generated)
        precondition(published && model.tree.rows.count == generated.count)
        for index in [0, 50_000, 99_999] {
            let row = model.tree.rows[index]
            precondition(model.tree.rowIndices[row.id] == index && model.tree.rootRowIndices[row.id] == index)
            precondition(model.tree.firstRowIDs[row.item.id] == row.id && model.tree.rowByID[row.id]?.item.id == row.item.id)
        }
        model.select(model.tree.rows[99_998], extending: false, toggling: false)
        for _ in 0..<20 { model.moveSelection(1); model.moveSelection(-1) }
        precondition(model.focusedItemID == generated[99_998].id)
        model.selection = [generated[99_999].id, generated[0].id]
        precondition(model.selectedItems.map(\.id) == [generated[0].id, generated[99_999].id])
        model.fileTypeFilter = .fileExtension("txt")
        model.select(model.tree.rows[50_000], extending: false, toggling: false)
        model.moveSelection(1)
        precondition(model.focusedItemID == generated[50_002].id && model.visibleRows.count == 50_000)
        var current = true, checked = 0
        let stale = Task { await model.tree.replaceRootsPrepared(generated) { checked += 1; return current } }
        while checked == 0 { await Task.yield() }
        current = false; model.tree.reset(provider: secondDrive)
        let stalePublished = await stale.value
        precondition(!stalePublished && model.tree.rows.isEmpty, "A superseded prepared snapshot must not republish an old listing")
        print("PASS 100k prepared rows publish complete indexes, preserve ordered/filtered arrow selection and discard stale generations")

        var loads = 0, pages = 0
        let prefetcher = NativeFolderThumbnailPrefetcher(cache: NativeThumbnailCache { _ in loads += 1; return nil })
        let folders = generated.map { item in CloudDriveItem(id: item.id, name: "Generated folder", isFolder: true) }
        let context = NativeFolderThumbnailPrefetcher.Context(kind: .local, rootID: "generated-root", folderID: "generated-folder", query: "")
        prefetcher.start(context: context, items: folders, nextOffset: 1) { _ in pages += 1; return .init(items: folders, nextOffset: nil) }
        try await until { !prefetcher.isRunning }
        precondition(loads == 0 && pages == 0, "Folder-only discovery is bounded and must not scan all metadata pages")
        prefetcher.start(context: context, items: [], nextOffset: 1) { _ in pages += 1; return .init(items: [], nextOffset: nil) }
        await Task.yield()
        precondition(pages == 0, "Unchanged context must not restart/reorder prefetch")
        prefetcher.cancel()
        print("PASS folder-only prefetch is bounded and unchanged-folder requests do not restart it")
    }
}

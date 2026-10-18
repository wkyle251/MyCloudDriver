import AppKit
import Foundation

/// Generated metadata providers exercise the shipping palette and Browser
/// integration without opening a real local, network, cloud or external disk.
private final class SearchIntegrationDrive: NativeCloudDrive, @unchecked Sendable {
    let kind = CloudDriveKind.local
    let root: CloudDriveLocation
    private var pages: [String: [CloudDriveItem]]
    var searchDelay: UInt64 = 0
    var deniedFolders = Set<String>()
    private let lock = NSLock()
    private var listCount = 0, searchCount = 0, contentCount = 0
    var counts: (list: Int, search: Int, content: Int) {
        lock.lock(); defer { lock.unlock() }; return (listCount,searchCount,contentCount)
    }
    init(rootURL: URL, prefix: String = "") {
        root = .init(id: prefix + "root", title: "Generated Disk", url: rootURL)
        func item(_ id: String, _ name: String, folder: Bool = false, parent: String = "") -> CloudDriveItem {
            .init(id: prefix + id, name: name, isFolder: folder, bytes: folder ? nil : 100,
                url: rootURL.appendingPathComponent(parent).appendingPathComponent(name, isDirectory: folder))
        }
        pages = [
            prefix + "root": [item("reports", "Reports", folder: true),item("resume", "Résumé.txt")],
            prefix + "reports": [item("deep-visible", "Deep Visible.txt", parent: "Reports"),item("nested", "Nested", folder: true, parent: "Reports")],
            prefix + "nested": [item("hidden-deep", "Hidden Deep.txt", parent: "Reports/Nested")]
        ]
    }
    private func count(_ search: Bool) { lock.lock(); if search { searchCount += 1 } else { listCount += 1 }; lock.unlock() }
    private func countContent() { lock.lock(); contentCount += 1; lock.unlock() }
    private func pageItems(_ id: String) -> [CloudDriveItem] { lock.lock(); defer { lock.unlock() }; return pages[id] ?? [] }
    func remove(_ id: String) {
        lock.lock(); pages = pages.mapValues { $0.filter { $0.id != id } }; lock.unlock()
    }
    func list(_ location: CloudDriveLocation, offset: Int, search: String) async throws -> CloudDrivePage {
        count(false)
        let items = pageItems(location.id).filter { search.isEmpty || $0.name.localizedStandardContains(search) }
        return .init(items: items, total: items.count)
    }
    func searchPage(_ location: CloudDriveLocation, offset: Int) async throws -> CloudDrivePage {
        count(true)
        if searchDelay > 0 { try await Task.sleep(nanoseconds: searchDelay) }
        if deniedFolders.contains(location.id) { throw CloudDriveError.message("Generated folder permission denied") }
        let items = pageItems(location.id)
        return .init(items: items, total: items.count)
    }
    func scanItems(_ items: [CloudDriveItem], location: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> [CloudDriveItem] { throw CocoaError(.featureUnsupported) }
    func materialize(_ item: CloudDriveItem, directory: URL, progress: @escaping CloudDriveProgressHandler) async throws -> URL {
        countContent(); throw CocoaError(.featureUnsupported)
    }
    func createContainer(_ name: String, in location: CloudDriveLocation) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
    func rename(_ item: CloudDriveItem, to name: String) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
    func relocate(_ items: [CloudDriveItem], from: CloudDriveLocation, to: CloudDriveLocation, copy: Bool, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
    func importFiles(_ urls: [URL], into location: CloudDriveLocation, progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
    func delete(_ items: [CloudDriveItem], progress: @escaping CloudDriveProgressHandler) async throws -> CloudDriveUndo? { throw CocoaError(.featureUnsupported) }
}

private final class SearchValidationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let resumed = DispatchSemaphore(value: 0)
    private var entered = false, exited = false
    var isWaiting: Bool { lock.lock(); defer { lock.unlock() }; return entered && !exited }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return exited }
    func wait() throws {
        lock.lock(); entered = true; lock.unlock()
        let result = resumed.wait(timeout: .now() + 10)
        lock.lock(); exited = true; lock.unlock()
        guard result == .success else { throw CloudDriveError.message("Generated validation gate timed out") }
    }
    func release() { resumed.signal() }
}

private final class SearchValidationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var nextGate: SearchValidationGate?
    func pauseNext() -> SearchValidationGate {
        let gate = SearchValidationGate()
        lock.lock(); nextGate = gate; lock.unlock()
        return gate
    }
    func validate(_ disk: ICloudDriveProvider) throws {
        lock.lock(); count += 1; let gate = nextGate; nextGate = nil; lock.unlock()
        try gate?.wait()
        try disk.validateAccess()
    }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

@main struct NativeFileSearchIntegrationTests {
    @MainActor static func until(_ condition: () -> Bool, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(condition(), "Generated native search timed out at line \(line)")
    }
    @MainActor static func main() async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited); setbuf(stdout, nil)
        let fm = FileManager.default, root = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("NativeSearchIntegration-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let drive = SearchIntegrationDrive(rootURL: root.appendingPathComponent("generated-network-share"))
        let model = NativeDriveModel(kind: .local); defer { model.close() }
        model.setThumbnailPrefetchActive(false); model.connect(drive)
        try await until { !model.isLoading && model.visibleRows.count == 2 }
        model.tree.toggle(model.tree.rootRows.first { $0.item.id == "reports" }!)
        try await until { !model.tree.isLoading && model.visibleRows.count == 4 }
        let beforeExpanded = drive.counts
        model.query = "existing-browser-filter"
        precondition(model.presentFileSearch(scope: .expanded))
        model.fileSearch.updateQuery("resume")
        try await until { model.fileSearch.results.first?.item.id == "resume" }
        precondition(model.fileSearch.indexedItems == 4 && !model.fileSearch.isScanning && model.fileSearch.isNative)
        precondition(model.fileSearch.scopeTitle == "Current expanded items" && model.fileSearch.sourceName == "Local Disk")
        model.fileSearch.updateQuery("Deep Visible")
        try await until { model.fileSearch.results.first?.item.id == "deep-visible" }
        model.fileSearch.openSelection(reveal: model.revealFileSearch)
        try await until { model.focusedItemID == "deep-visible" }
        precondition(model.query == "existing-browser-filter" && drive.counts.list == beforeExpanded.list
                     && drive.counts.search == 0 && drive.counts.content == 0,
                     "Expanded search and reveal must use only rendered metadata and leave Browser filtering unchanged")
        print("PASS native expanded palette: visible outline only, Unicode matching, keyboard selection/reveal and zero storage/content calls")

        precondition(model.presentFileSearch(scope: .root))
        model.fileSearch.updateQuery("Hidden Deep")
        try await until { model.fileSearch.isComplete && model.fileSearch.results.first?.item.id == "hidden-deep" }
        precondition(model.query == "existing-browser-filter" && model.fileSearch.indexedItems == 5
                     && model.fileSearch.scopeTitle == "Search from Local Disk root")
        let rootCalls = drive.counts
        model.fileSearch.openSelection(reveal: model.revealFileSearch)
        try await until { model.location.id == "nested" && model.focusedItemID == "hidden-deep" }
        precondition(model.history.map(\.id) == ["root","reports","nested"] && model.query.isEmpty
                     && drive.counts.list == rootCalls.list && drive.counts.search == rootCalls.search && drive.counts.content == 0,
                     "Deep reveal must seed the indexed parent and ancestry without foreground listings or content reads")
        model.presentFileSearch(scope: .expanded)
        model.fileSearch.close()
        model.presentFileSearch(scope: .root)
        model.fileSearch.updateQuery("Résumé")
        try await until { model.fileSearch.results.first?.item.id == "resume" && model.fileSearch.isComplete }
        model.fileSearch.openSelection(reveal: model.revealFileSearch)
        try await until { model.location.id == "root" && model.focusedItemID == "resume" }
        precondition(drive.counts.search == rootCalls.search && drive.counts.list == rootCalls.list,
                     "Reopening a complete root cache after expanded search must retain its original-item metadata")
        print("PASS recursive captured-root palette: deep file/folder metadata, source labels, cached ancestor/sibling reveal and reopen cache reuse")

        model.presentFileSearch(scope: .root); model.fileSearch.updateQuery("Hidden Deep")
        try await until { model.fileSearch.results.first?.item.id == "hidden-deep" }
        var previousNavigation: FileSearchNavigation?
        model.fileSearch.openSelection { previousNavigation = $0 }
        try await until { previousNavigation != nil }
        drive.deniedFolders = ["nested"]
        model.presentFileSearch(scope: .root); model.fileSearch.scanAgain()
        try await until { !model.fileSearch.isScanning && !model.fileSearch.failures.isEmpty }
        precondition(model.fileSearch.results.contains { $0.item.id == "hidden-deep" })
        let beforePartialReveal = drive.counts
        model.revealFileSearch(previousNavigation!)
        try await until { model.focusedItemID == "hidden-deep" }
        precondition(drive.counts.list == beforePartialReveal.list && drive.counts.content == 0,
                     "An incomplete rescan must preserve original metadata for its honestly cached partial matches")
        model.fileSearch.close(); drive.deniedFolders = []; drive.remove("hidden-deep")
        model.presentFileSearch(scope: .root); model.fileSearch.scanAgain()
        try await until { model.fileSearch.isComplete && !model.fileSearch.isScanning && model.fileSearch.results.isEmpty }
        model.selection = []; model.error = nil
        model.revealFileSearch(previousNavigation!)
        try await until { model.error?.contains("no longer available") == true }
        precondition(model.focusedItemID == nil && drive.counts.content == 0,
                     "A completed rescan must prune removed originals so an old captured navigation cannot reveal them")
        model.fileSearch.close()
        print("PASS incomplete rescans retain cached metadata; complete rescans prune removed original bindings and reject stale navigation")

        let slow = SearchIntegrationDrive(rootURL: root.appendingPathComponent("slow-external-disk"), prefix: "old-")
        slow.searchDelay = 500_000_000
        model.connect(slow); try await until { !model.isLoading }
        model.presentFileSearch(scope: .root); model.fileSearch.updateQuery("Hidden")
        try await until { model.fileSearch.isScanning && slow.counts.search > 0 }
        let replacement = SearchIntegrationDrive(rootURL: root.appendingPathComponent("replacement-network-share"), prefix: "new-")
        model.connect(replacement); try await until { !model.isLoading }
        precondition(!model.fileSearch.isPresented && model.fileSearch.query.isEmpty && model.fileSearch.results.isEmpty)
        model.presentFileSearch(scope: .root); model.fileSearch.updateQuery("Hidden")
        try await until { model.fileSearch.isComplete && model.fileSearch.results.first?.item.id == "new-hidden-deep" }
        precondition(!model.fileSearch.results.contains { $0.item.id.hasPrefix("old-") } && replacement.counts.content == 0)
        model.fileSearch.close()
        let denied = SearchIntegrationDrive(rootURL: root.appendingPathComponent("denied-network-folder"))
        denied.deniedFolders = ["nested"]
        model.connect(denied); try await until { !model.isLoading }
        model.presentFileSearch(scope: .root); model.fileSearch.updateQuery("Visible")
        try await until { !model.fileSearch.failures.isEmpty && !model.fileSearch.isScanning }
        precondition(!model.fileSearch.isComplete && model.fileSearch.results.contains { $0.item.id == "deep-visible" })
        model.fileSearch.close()
        print("PASS reconnect cancels stale network scans and resets cache; denied folders retain honest partial matches and diagnostics")

        let actualRoot = root.appendingPathComponent("actual-generated-disk"), folder = actualRoot.appendingPathComponent("Nested")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("Generated metadata-search original".utf8).write(to: folder.appendingPathComponent("Target.txt"))
        try Data("Generated visible metadata-search original".utf8).write(to: actualRoot.appendingPathComponent("Visible.txt"))
        let validations = SearchValidationCounter()
        let actual = NativeDriveModel(kind: .local, availabilityValidation: { disk in try validations.validate(disk) })
        defer { actual.close() }
        actual.setThumbnailPrefetchActive(false); actual.connect(ICloudDriveProvider(rootURL: actualRoot, kind: .local))
        try await until { !actual.isLoading }
        actual.presentFileSearch(scope: .root); actual.fileSearch.updateQuery("Target")
        try await until { actual.fileSearch.isComplete && actual.fileSearch.results.count == 1 }
        let beforeReveal = validations.value
        var rootNavigation: FileSearchNavigation?
        actual.fileSearch.openSelection { rootNavigation = $0; actual.revealFileSearch($0) }
        try await until { actual.focusedItem?.name == "Target.txt" }
        let revealValidations = validations.value - beforeReveal
        precondition(revealValidations == 1, "Cached filesystem reveal validation count: \(revealValidations), expected 1")
        precondition(actual.location.url?.standardizedFileURL.path == folder.standardizedFileURL.path,
                     "Cached filesystem reveal must navigate to the generated original's parent folder")

        let navigationGate = validations.pauseNext()
        actual.revealFileSearch(rootNavigation!)
        try await until { navigationGate.isWaiting }
        actual.root()
        navigationGate.release()
        try await until { navigationGate.isFinished && !actual.isLoading && !actual.isCheckingAvailability }
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(actual.location.id == actual.provider?.root.id && actual.history.count == 1 && actual.focusedItemID == nil,
                     "Ordinary navigation must supersede a root search reveal waiting for its captured volume")

        actual.presentFileSearch(scope: .expanded); actual.fileSearch.updateQuery("Visible")
        try await until { actual.fileSearch.results.count == 1 }
        var expandedNavigation: FileSearchNavigation?
        actual.fileSearch.openSelection { expandedNavigation = $0 }
        let expandedGate = validations.pauseNext(), beforeExpandedReveal = validations.value
        actual.revealFileSearch(rootNavigation!)
        try await until { expandedGate.isWaiting }
        actual.revealFileSearch(expandedNavigation!)
        precondition(actual.focusedItem?.name == "Visible.txt" && !actual.isLoading,
                     "Expanded reveal must immediately supersede pending root navigation without taking loading ownership")
        expandedGate.release()
        try await until { expandedGate.isFinished && !actual.isLoading && !actual.isCheckingAvailability }
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(actual.location.id == actual.provider?.root.id && actual.focusedItem?.name == "Visible.txt"
                     && validations.value == beforeExpandedReveal + 1,
                     "Canceled root reveal must preserve newer expanded selection, release validation state and add no storage reads")
        print("PASS ordinary navigation and expanded reveal supersede delayed root reveal; loading and shared validation settle")
        actual.close()
        precondition(!actual.presentFileSearch(scope: .root))
        let photos = NativeDriveModel(kind: .photos); defer { photos.close() }
        precondition(!photos.presentFileSearch(scope: .expanded), "Photos retains its existing search flow")
        let disconnected = NativeDriveModel(kind: .local); defer { disconnected.close() }
        precondition(disconnected.presentFileSearch(scope: .root) && !disconnected.fileSearch.failures.isEmpty
                     && !disconnected.fileSearch.canScan, "Disconnected filesystem search must show actionable attention details")
        print("PASS generated filesystem deep reveal validates its captured volume once; closed models and legacy Photos remain isolated")
    }
}

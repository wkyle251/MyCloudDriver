import AppKit
import Foundation
import UniformTypeIdentifiers

@main
struct FileSearchTests {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }
    }

    static func event(_ json: [String: Any]) throws -> FileSearchEvent {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(FileSearchEvent.self, from: JSONSerialization.data(withJSONObject: json))
    }

    static func item(_ id: String, _ name: String, folder: Bool = false) -> [String: Any] {
        ["id": id, "name": name, "kind": folder ? "drive#folder" : "drive#file", "size": 42]
    }

    @MainActor
    static func main() async throws {
        let p = ["indexed_items": 502, "scanned_folders": 2, "discovered_folders": 2, "failed_folders": 0]
        let index = FileSearchIndex()
        index.beginScan()
        try index.ingest(event(["event": "page", "parent_id": "", "ancestors": [],
                               "items": [item("folder", "Reports", folder: true)], "progress": p]))
        let ancestry = [["id": "folder", "name": "Reports"]]
        let files = (0..<500).map { item("\($0)", "Report \($0).txt") }
            + [item("unicode", "Résumé 報告.txt")]
        try index.ingest(event(["event": "page", "parent_id": "folder", "ancestors": ancestry,
                               "items": files, "progress": p]))
        let many = index.search("report", limit: 100)
        require(many.total == 501 && many.matches.count == 100, "search must include all pages, with honest visible limit")
        require(index.search("REPORT 499", limit: 100).matches.first?.id == "499", "files beyond page 200 are searchable")
        require(index.search("  resume  ", limit: 100).matches.first?.id == "unicode", "accent/case folding")
        require(index.search("報告", limit: 100).matches.first?.id == "unicode", "Unicode names")
        require(index.search("rpt", limit: 100).total == 501, "fuzzy abbreviations")
        require(index.search("", limit: 100).total == 0, "empty queries must not flood the UI")
        let result = index.search("Report 499", limit: 100).matches[0]
        require(result.fullPath == "PikPak › Reports › Report 499.txt", "full ancestry displayed")
        let navigation = index.navigation(for: result)
        require(navigation.items.count == 501 && navigation.ancestors.last?.id == "folder", "reveal uses IDs and complete indexed sibling list")
        require(navigation.directories.map(\.parentID) == ["", "folder"], "reveal carries every ancestor listing from root")
        let folderNavigation = index.navigation(for: index.search("Reports", limit: 100).matches.first { $0.id == "folder" }!)
        require(folderNavigation.ancestors.isEmpty && folderNavigation.items.contains { $0.id == "folder" }, "folder results reveal their own row instead of entering them")
        try index.ingest(event(["event": "finished", "progress": p]))
        require(index.complete, "complete scan")
        index.beginScan()
        try index.ingest(event(["event": "page", "parent_id": "", "ancestors": [],
                               "items": [item("new", "New.txt")], "progress": p]))
        try index.ingest(event(["event": "finished", "progress": p]))
        require(index.count == 1 && index.search("report", limit: 100).total == 0, "successful rescan prunes stale entries")
        require(!FileSearchIndex.redacted("refresh_token: secret authorization=secret Bearer secret").contains("secret"), "diagnostics redact credentials")
        print("PASS search: pagination, Unicode, ranking, limits, paths, navigation, cache replacement, redaction")

        let visibleItem = FileSearchItem(id: "visible", name: "Visible Report.txt", kind: "drive#file",
                                         size: 10, mimeType: nil, modifiedTime: nil)
        let localMatch = FileSearchMatch(item: visibleItem, ancestors: [.init(id: "open", name: "Open")], score: 0)
        let firstLink = UUID(), secondLink = UUID()
        let linkMatches = [firstLink, secondLink].map { (linkID: UUID) in
            FileSearchMatch(item: visibleItem, ancestors: [], score: 0, linkID: linkID, sourceName: "Link \(linkID.uuidString)")
        }
        let localIndex = FileSearchIndex()
        localIndex.replaceExpandedItems([localMatch] + linkMatches)
        let foundLocal = localIndex.search("report", limit: 100).matches
        require(foundLocal.count == 3 && Set(foundLocal.map(\.id)).count == 3, "same file id in two links and account stays distinct")
        let linkNavigation = localIndex.navigation(for: foundLocal.first { $0.linkID == secondLink }!, scope: .expanded)
        require(linkNavigation.match.linkID == secondLink && linkNavigation.directories.isEmpty, "local reveal preserves its exact link and never fabricates root listings")

        let localModel = FileSearchModel()
        localModel.present(scope: .expanded, expandedItems: [localMatch])
        localModel.updateQuery("report")
        try await waitUntil { localModel.results.count == 1 }
        require(!localModel.isScanning && !localModel.canScan && localModel.isComplete, "expanded search works offline and never starts a helper")
        var localOpened: FileSearchNavigation?
        localModel.openSelection(localModel.results[0]) { localOpened = $0 }
        try await waitUntil { localOpened != nil }
        require(localOpened?.scope == .expanded && localOpened?.match.id == "visible", "click reveals the local result")
        localModel.present(scope: .expanded, expandedItems: [])
        try await waitUntil { localModel.indexedItems == 0 && localModel.results.isEmpty }
        require(!localModel.isScanning, "reopening current search takes a fresh snapshot, dropping collapsed/deleted rows")
        localModel.close()
        print("PASS local search: offline scope, fresh visible snapshots, duplicate link identities, click reveal")

        #if FILE_SEARCH_TESTS
        DownloaderModel.testFileSearchReveal()
        #endif

        struct Request { let destination: String; let roots: [Int] }
        var requests = (0..<42).map { Request(destination: "A", roots: [$0]) }
        requests.insert(Request(destination: "B", roots: [99]), at: 3)
        let batch = DownloadQueueBatching.takeNext(from: &requests) { a, b in
            guard a.destination == b.destination else { return nil }
            return Request(destination: a.destination, roots: a.roots + b.roots)
        }
        require(batch?.roots == Array(0..<42), "42 compatible clicks must feed one concurrent batch")
        require(requests.count == 1 && requests[0].destination == "B", "other destinations remain queued")
        require(DownloadQueueBatching.relativeParents(for: ["/A/one.txt", "/B/two.txt"]) == [["A"], ["B"]], "multi-folder selection preserves its hierarchy")
        require(DownloadQueueBatching.relativeParents(for: ["/A/one.txt"]) == [[]], "single click preserves its exact chosen destination")
        require(DownloadQueueBatching.destinationsOverlap([["Folder"]], [["folder", "file.txt"]]), "overlapping trees cannot race their local writes")
        require(DownloadQueueBatching.destinationsOverlap([["FILE.txt"]], [["file.txt"]]), "case-insensitive output collision")
        require(!DownloadQueueBatching.destinationsOverlap([["Folder A", "file.txt"]], [["Folder B", "file.txt"]]), "independent output folders can share workers")
        require(UploadAvailability.allowsStart(hasSession: true, uploadActive: false,
                    conflictingMutation: false, foregroundAllows: true), "downloads/read-only activity do not block upload policy")
        require(!UploadAvailability.allowsStart(hasSession: true, uploadActive: true,
                    conflictingMutation: false, foregroundAllows: true), "an active upload remains protected")
        require(!UploadAvailability.allowsStart(hasSession: false, uploadActive: false,
                    conflictingMutation: false, foregroundAllows: true), "authentication remains required")
        print("PASS transfers: compatible batches share workers; destinations and upload state stay isolated")

        let urls = [URL(fileURLWithPath: "/private/tmp/Example Folder"),
                    URL(fileURLWithPath: "/private/tmp/Résumé 報告.txt")]
        require(LocalUploadFileURLLoader.localFileURL(from: urls[0] as NSURL) == urls[0], "Finder NSURL")
        require(LocalUploadFileURLLoader.localFileURL(from: urls[1].dataRepresentation as NSData) == urls[1], "Finder data with Unicode and spaces")
        require(LocalUploadFileURLLoader.localFileURL(from: urls[1].absoluteString as NSString) == urls[1], "Finder NSString")
        let providers = urls.map { NSItemProvider(item: $0 as NSURL, typeIdentifier: UTType.fileURL.identifier) }
        let loaded: [URL] = await withCheckedContinuation { continuation in
            LocalUploadFileURLLoader.load(providers) { continuation.resume(returning: $0) }
        }
        require(loaded == urls, "multi-file/folder drop maintains provider order")
        print("PASS Finder drop: multiple URLs, folder URL, Unicode names, serialized formats")

        guard CommandLine.arguments.count > 1 else { return }
        let configuration = FileSearchConfiguration(
            executable: URL(fileURLWithPath: CommandLine.arguments[1]),
            directory: URL(fileURLWithPath: "/private/tmp"), environment: [:])
        let model = FileSearchModel()
        require(!model.isPresented, "search hidden initially")
        model.present(configuration: configuration)
        require(model.isPresented && !model.isScanning, "opening empty palette does not crawl immediately")
        model.updateQuery("report")
        try await waitUntil { model.isScanning && !model.results.isEmpty }
        require(model.totalMatches > 0 && model.isScanning, "incremental results appear before the helper exits")
        try await waitUntil { !model.isScanning && model.isComplete }
        require(model.totalMatches == 241 && model.results.count == 100, "all streamed pages indexed")
        model.moveSelection(1)
        require(model.selectedID == model.results[1].id, "arrow navigation")
        model.showMore()
        try await waitUntil { model.results.count == 200 }
        model.updateQuery("Report 239")
        require(model.results.isEmpty, "old matches cannot open after a query changes")
        try await waitUntil { model.results.first?.id == "report-239" }
        var opened: FileSearchNavigation?
        model.openSelection { opened = $0 }
        try await waitUntil { opened != nil }
        require(!model.isPresented && opened?.match.id == "report-239", "Enter closes and reveals selected item")
        model.present(configuration: configuration)
        require(!model.isScanning, "complete index reused on reopen")
        model.present(scope: .expanded, expandedItems: [localMatch])
        require(model.results.isEmpty && !model.isScanning, "scope switch immediately clears stale root results")
        model.updateQuery("report")
        try await waitUntil { model.results.count == 1 && model.results[0].id == "visible" }
        model.present(scope: .root, configuration: configuration)
        require(!model.isScanning, "returning to completed root scope reuses its independent cache")
        try await waitUntil { model.totalMatches == 241 }
        require(!model.results.contains { $0.id == "visible" }, "local rows cannot leak into root search")
        model.scanAgain()
        try await waitUntil { model.isScanning }
        model.present(scope: .expanded, expandedItems: [localMatch])
        try await waitUntil { model.results.count == 1 && model.results[0].id == "visible" }
        try await Task.sleep(nanoseconds: 500_000_000)
        require(!model.isScanning && model.totalMatches == 1 && model.scope == .expanded, "cancelled root scan output cannot overwrite expanded scope")
        model.present(scope: .root, configuration: configuration)
        try await waitUntil { model.isScanning }
        model.close()
        try await Task.sleep(nanoseconds: 400_000_000)
        require(!model.isPresented && !model.isScanning, "Escape cancels without reopening from late output")
        model.reset()
        try await Task.sleep(nanoseconds: 250_000_000)
        require(model.indexedItems == 0 && model.results.isEmpty, "account reset discards cache and rejects late output")
        print("PASS live helper: progressive root results, keyboard reveal, scope/cache isolation, show more, cancel/reset races")
    }

    @MainActor
    static func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<120 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        fatalError("timed out waiting for asynchronous search state")
    }
}

import Foundation

@main struct NativeFileSearchTests {
    static func require(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fatalError(message) }
    }
    static func item(_ id: String, _ name: String, folder: Bool = false) -> FileSearchItem {
        .init(id: id, name: name, kind: folder ? "drive#folder" : "drive#file", size: 42,
              mimeType: nil, modifiedTime: nil)
    }
    static func waitUntil(_ predicate: () async -> Bool) async {
        let end = Date().addingTimeInterval(5)
        while !(await predicate()) {
            require(Date() < end, "Timed out waiting for generated native search")
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [FileSearchEvent] = []
        private var finishes = 0
        func event(_ value: FileSearchEvent) { lock.lock(); values.append(value); lock.unlock() }
        func finish() { lock.lock(); finishes += 1; lock.unlock() }
        var events: [FileSearchEvent] { lock.lock(); defer { lock.unlock() }; return values }
        var completed: Bool { lock.lock(); defer { lock.unlock() }; return finishes > 0 }
        var count: Int { lock.lock(); defer { lock.unlock() }; return finishes }
    }
    actor Gate {
        private var open = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            guard !open else { return }
            await withCheckedContinuation { waiters.append($0) }
        }
        func release() {
            open = true
            let pending = waiters; waiters = []
            pending.forEach { $0.resume() }
        }
    }
    actor Fixture {
        let gate: Gate?
        private(set) var active = 0
        private(set) var maximum = 0
        private(set) var requests = 0
        init(gate: Gate? = nil) { self.gate = gate }
        func load(_ parent: String, _ offset: Int) async throws -> NativeFileSearchPage {
            requests += 1; active += 1; maximum = max(maximum, active)
            defer { active -= 1 }
            if parent == "slow" { await gate?.wait() }
            if parent == "broken" {
                throw NSError(domain: "GeneratedSearch", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Generated denied folder access_token: secret"])
            }
            try Task.checkCancellation()
            switch (parent, offset) {
            case ("root", 0):
                return .init(items: [item("unmatched", "Unmatched Folder", folder: true),
                                     item("slow", "Slow Folder", folder: true), item("broken", "Denied Folder", folder: true),
                                     item("root", "Cycle", folder: true)], nextOffset: 10)
            case ("root", 10):
                return .init(items: [item("root-file", "Root Report.txt")])
            case ("unmatched", 0):
                return .init(items: (0..<501).map { item("generated-\($0)", "Report \($0).txt") }
                             + [item("unicode", "Résumé 報告.txt")])
            case ("slow", 0): return .init(items: [item("late", "Late Report.txt")])
            default: fatalError("Unexpected generated search request")
            }
        }
    }

    @MainActor static func main() async {
        await scanner()
        await cyclesAndPagination()
        await modelLifecycle()
        await cancellationAndContextChange()
        print("PASS native search scanner: incremental metadata, bounded requests, pagination, cycles, partial failures")
        print("PASS native search model: offline expanded scope, Unicode ranking, root cache, explicit retry, context isolation, cancellation")
    }

    static func scanner() async {
        let gate = Gate()
        // A separate blocked branch proves another branch becomes searchable
        // before the root traversal has completed.
        let provider = Fixture(gate: gate)
        let recorder = Recorder()
        let factory = NativeFileSearch.scanFactory(rootID: "root") { try await provider.load($0, $1) }
        let job = factory(recorder.event) { _, _ in recorder.finish() }
        await waitUntil { recorder.events.contains { $0.items?.contains { $0.id == "generated-500" } == true } }
        require(!recorder.completed, "Early native metadata must not wait for a blocked sibling")
        let maximum = await provider.maximum
        require(maximum <= 2, "Native search exceeded its two storage requests")
        await gate.release()
        await waitUntil { recorder.completed }
        let index = FileSearchIndex()
        index.beginScan()
        recorder.events.forEach { index.ingest($0, sourceName: "Generated Disk") }
        require(index.count == 507, "Native traversal lost files or folder rows")
        require(!index.complete && index.progress.failedFolders == 1, "Partial native search claimed completeness")
        require(!index.failures.joined().contains("secret"), "Native failure leaked a credential-shaped value")
        require(index.search("resume", limit: 100).matches.first?.item.id == "unicode", "Native Unicode ranking changed")
        let deep = index.search("Report 500", limit: 100).matches[0]
        require(deep.parentPath == "Generated Disk › Unmatched Folder", "Native result lost source ancestry")
        let navigation = index.navigation(for: deep)
        require(navigation.directories.map(\.parentID) == ["", "unmatched"], "Native reveal lost indexed ancestors")
        require(navigation.items.count == 502, "Native reveal omitted indexed siblings")
        let folder = index.search("Unmatched Folder", limit: 100).matches[0]
        require(index.navigation(for: folder).ancestors.isEmpty, "Folder search entered the folder instead of revealing its row")
        job.cancel()
    }

    static func cyclesAndPagination() async {
        let recorder = Recorder()
        let factory = NativeFileSearch.scanFactory(rootID: "root") { parent, offset in
            if parent == "folder" {
                return .init(items: [item("root", "Cycle", folder: true), item("deep", "Deep.txt")])
            }
            if offset == 0 {
                return .init(items: [item("folder", "Folder", folder: true), item("one", "One.txt")], nextOffset: 10)
            }
            return .init(items: [item("one", "Duplicate.txt"), item("two", "Two.txt")], nextOffset: 10)
        }
        let job = factory(recorder.event) { _, _ in recorder.finish() }
        await waitUntil { recorder.completed }
        let finished = recorder.events.last!
        require(finished.event == "finished" && finished.progress.indexedItems == 4, "Cycles or overlapping pages changed unique totals")
        require(finished.progress.discoveredFolders == 2 && finished.progress.failedFolders == 1,
                "Repeated native page was not bounded and reported")
        require(recorder.events.filter { $0.event == "page" }.count == 3, "Repeated native offset caused another request")
        job.cancel()
    }

    @MainActor static func modelLifecycle() async {
        let model = FileSearchModel(), loads = Recorder()
        let expanded = FileSearchMatch(item: item("visible", "Visible Résumé.txt"), ancestors: [], score: 0, sourceName: "Generated Disk")
        let factory = NativeFileSearch.scanFactory(rootID: "root") { _, _ in
            loads.finish()
            return .init(items: [item("root-result", "Root Report.txt")])
        }
        model.presentNative(contextID: "generated-one", contextName: "Generated Folder", sourceName: "Generated Disk",
                            symbol: "externaldrive", expandedItems: [expanded], scanFactory: factory)
        model.updateQuery("resume")
        await waitUntil { model.results.count == 1 }
        require(!model.isScanning && model.isComplete && !model.canScan, "Expanded native search started storage work")
        require(!loads.completed, "Expanded matching touched storage")
        require(model.isNative && model.sourceSymbol == "externaldrive" && model.scopeTitle == "Current expanded items",
                "Native search presentation lost source context")
        model.presentNative(scope: .root, contextID: "generated-one", contextName: "Generated Root", sourceName: "Generated Disk",
                            symbol: "externaldrive", scanFactory: factory)
        model.updateQuery("report")
        await waitUntil { model.isComplete && !model.isScanning && model.results.count == 1 }
        require(model.scopeTitle == "Search from Generated Disk root" && model.results[0].sourceName == "Generated Disk",
                "Native root cache is labeled as PikPak")
        model.close()
        var restarted = false
        model.presentNative(scope: .root, contextID: "generated-one", contextName: "Generated Root", sourceName: "Generated Disk",
                            symbol: "externaldrive", scanFactory: { event, finish in restarted = true; return factory(event, finish) })
        await waitUntil { model.results.count == 1 }
        require(!restarted && !model.isScanning, "Reopening a complete native index started another traversal")
        model.presentNative(contextID: "generated-one", contextName: "Generated Folder", sourceName: "Generated Disk",
                            symbol: "externaldrive", expandedItems: [])
        await waitUntil { model.indexedItems == 0 && model.results.isEmpty }
        model.presentNative(scope: .root, contextID: "generated-one", contextName: "Generated Root", sourceName: "Generated Disk",
                            symbol: "externaldrive", scanFactory: factory)
        await waitUntil { model.results.count == 1 }
        require(!model.isScanning && model.isComplete, "Expanded/root transitions dropped the complete native cache")
        let replacement = NativeFileSearch.scanFactory(rootID: "root") { _, _ in
            .init(items: [item("replacement", "Replacement Report.txt")])
        }
        model.presentNative(scope: .root, contextID: "generated-one", contextName: "Generated Root", sourceName: "Generated Disk",
                            symbol: "externaldrive", scanFactory: replacement)
        model.scanAgain()
        await waitUntil { model.isComplete && !model.isScanning && model.results.first?.item.id == "replacement" }
        require(model.indexedItems == 1, "Successful native rescan retained a deleted original")
        model.presentNative(scope: .root, contextID: "generated-two", contextName: "Other Root", sourceName: "Other Disk",
                            symbol: "network", scanFactory: factory)
        require(model.query.isEmpty && model.results.isEmpty && !model.isComplete, "Provider replacement retained stale native metadata")
        model.present(scope: .expanded, expandedItems: [expanded])
        require(!model.isNative && model.sourceName == "PikPak" && model.sourceSymbol == "cloud", "Legacy PikPak presentation changed")
        model.close()
    }

    @MainActor static func cancellationAndContextChange() async {
        let model = FileSearchModel(), gate = Gate(), started = Recorder()
        let blocked = NativeFileSearch.scanFactory(rootID: "root") { _, _ in
            started.finish()
            await gate.wait() // Simulate a network provider that returns after cancellation.
            return .init(items: [item("stale", "Stale Report.txt")])
        }
        model.presentNative(scope: .root, contextID: "old", contextName: "Old Root", sourceName: "Generated Disk",
                            symbol: "network", scanFactory: blocked)
        model.updateQuery("report")
        await waitUntil { started.completed }
        let began = Date()
        model.close()
        require(Date().timeIntervalSince(began) < 0.1 && !model.isScanning, "Closing search waited for a blocked native provider")
        let attempts = Recorder()
        let failing = NativeFileSearch.scanFactory(rootID: "new") { _, _ in
            attempts.finish()
            throw NSError(domain: "GeneratedSearch", code: 1, userInfo: [NSLocalizedDescriptionKey: "Generated provider denied access"])
        }
        model.presentNative(scope: .root, contextID: "new", contextName: "New Root", sourceName: "Other Disk",
                            symbol: "externaldrive", scanFactory: failing)
        model.updateQuery("report")
        await waitUntil { !model.isScanning && !model.failures.isEmpty }
        await gate.release()
        try? await Task.sleep(nanoseconds: 5_200_000_000)
        require(model.results.isEmpty && !model.isComplete && model.canScan, "Late cancelled metadata entered the new provider context")
        require(!model.isScanning && attempts.count == 1, "Failed native search retried without an explicit request")
        model.close()
    }
}

// The focused command compiles the production search model/scanner and its
// real AutomaticRecovery utility without the unrelated transfer subsystem.
// Native searches never call AutomaticRecovery.read or this predicate.
#if NATIVE_FILE_SEARCH_FOCUSED_TESTS
enum TransferFailure { static func isRetryable(_ error: Error) -> Bool { false } }
#endif

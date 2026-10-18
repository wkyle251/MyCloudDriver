import AppKit
import Foundation

/// Entirely generated names and metadata. Never inspects an app, disk or account.
@main @MainActor struct DuplicateResultsResponsivenessTests {
    final class Heartbeat {
        var largestGap = 0.0
        var ticks = 0
        var task: Task<Void, Never>?
        func start() {
            task = Task { @MainActor [weak self] in
                var previous = Date.timeIntervalSinceReferenceDate
                while !Task.isCancelled {
                    do { try await Task.sleep(nanoseconds: 5_000_000) } catch { return }
                    guard let self else { return }
                    let now = Date.timeIntervalSinceReferenceDate
                    self.largestGap = max(self.largestGap, now - previous); self.ticks += 1; previous = now
                }
            }
        }
        func stop() { task?.cancel() }
    }
    static func until(_ ready: () -> Bool, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(40)
        while !ready(), Date() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(ready(), "Generated duplicate fixture timed out at line \(line)")
    }
    static func seconds(_ operation: () -> Void) -> Double {
        let start = Date.timeIntervalSinceReferenceDate; operation()
        return Date.timeIntervalSinceReferenceDate - start
    }
    static func main() async throws {
        setbuf(stdout, nil); _ = NSApplication.shared; NSApp.setActivationPolicy(.prohibited)
        try await nativeResults()
        try await crossDriveResults()
        selectionArithmetic()
        try CrossDriveDuplicatePolicy.testCrossDriveRecommendations()
    }

    static func nativeResults() async throws {
        let report = await Task.detached(priority: .userInitiated) {
            let files = (0..<100_000).map { number in
                let name = String(format: "R%06x.dat", number)
                return SimilarityFile(id: "r\(number)", name: name, path: "/Generated/Q7vK/" + name,
                    bytes: UInt64(number + 1), family: "file", localPath: "/Generated/Q7vK/" + name,
                    cloudId: nil, ancestors: [], state: "ready")
            }
            var groups = [SimilarityGroup(id: "000000", matchKind: "byte_identical", family: "file", minimumScore: nil,
                memberCount: 50_000, members: Array(files.prefix(50_000)))]
            for number in 25_000..<50_000 {
                groups.append(.init(id: String(format: "%06x", number), matchKind: "byte_identical", family: "file", minimumScore: nil,
                    memberCount: 2, members: Array(files[(number * 2)..<(number * 2 + 2)])))
            }
            return SimilarityReport(source: .local, scope: ["Generated"], status: "completed", threshold: 0.9,
                scannedFiles: 100_000, analysedFiles: 100_000, skippedFiles: 0, downloadedBytes: 0,
                totalGroups: UInt64(groups.count), groups: groups, issues: [], truncated: false, coverage: "Generated",
                elapsedSeconds: 1, files: files)
        }.value
        let heartbeat = Heartbeat(); heartbeat.start(); defer { heartbeat.stop() }
        let model = SimilarityResultsModel(); defer { model.reset() }
        model.load(report, configuration: nil)
        try await until { !model.isIndexing && !model.isGrouping && model.roots.count == 25_001 }
        precondition(model.groupedFileCount == 100_000 && model.availableFileCount == 100_000)
        precondition(model.selectedGroup?.members.count == 50_000)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 350, height: 650))
        let outline = NSOutlineView(frame: scroll.bounds), tree = SimilarityFileTree.Coordinator()
        scroll.documentView = outline; scroll.hasVerticalScroller = true
        let column = NSTableColumn(identifier: .init("name")); outline.addTableColumn(column); outline.outlineTableColumn = column
        tree.outline = outline; outline.dataSource = tree; outline.delegate = tree
        tree.select = { model.selectNode($0) }
        func refresh() { tree.update(snapshot: model.tree, selectedID: model.selectedNodeID, searching: !model.query.isEmpty, groupExpansion: model.groupExpansion) }
        let install = seconds { refresh() }
        print(String(format: "Generated native tree installed in %.3fs", install))
        precondition(outline.numberOfRows <= 25_201, "Initial expansion must spend a row budget, not a group budget")
        precondition(!outline.isItemExpanded(model.roots[0]), "A huge group starts collapsed")
        precondition(model.roots[0].children.allSatisfy { $0.children.count <= 200 }, "Large tree branches use bounded file ranges")
        let redraw = seconds { for _ in 0..<1_000 { refresh() } }
        precondition(install < 1 && redraw < 1, "Installing and redrawing prepared results must not walk all 100,000 files")
        let planRequest = seconds { _ = model.keepSmallestPlan(); _ = model.keepLargestPlan(); _ = model.keepSmallestPlan(groupID: model.groups[0].id) }
        precondition(planRequest < 0.1, "Large cleanup plans must only be scheduled on the main actor")
        try await until { model.keepSmallestPlan() != nil && model.keepLargestPlan() != nil && model.keepSmallestPlan(groupID: model.groups[0].id) != nil }
        precondition(model.keepSmallestPlan()!.removals.count == 74_999)
        let built = model.sizeBasedPlanBuildCount
        for _ in 0..<100 { _ = model.keepSmallestPlan(); _ = model.keepLargestPlan() }
        precondition(model.sizeBasedPlanBuildCount == built)

        model.select("r24999")
        try await until { model.related.count == 49_999 && !model.isLoading }
        refresh()
        precondition(outline.numberOfRows < 26_000, "Selecting a distant member must only expose its bounded ancestors")
        precondition((outline.item(atRow: outline.selectedRow) as? SimilarityTreeNode)?.id == "r24999")
        model.setAllGroupsExpanded(false); refresh()
        precondition(outline.numberOfRows == 25_001 && model.selectedGroupID == "group:000000")

        let removed = Set((0..<10).map { "r\($0)" })
        model.setTrashedIDs(removed, true)
        try await until { !model.isGrouping && model.groupedFileCount == 99_990 }
        precondition(model.availableFileCount == 99_990 && model.keepSmallestPlan() == nil)
        model.setTrashedIDs(removed, false)
        try await until { !model.isGrouping && model.groupedFileCount == 100_000 }
        precondition(model.availableFileCount == 100_000)
        model.query = "R0061a7.dat"
        try await until { model.roots.count == 1 && model.roots[0].group?.members.count == 50_000 }
        refresh(); precondition(outline.numberOfRows == 1, "Search must preserve Collapse All")
        let page = ResultPage(total: model.groups[0].members.count, requestedPage: 249)
        precondition(page.range == 49_800..<50_000)
        // Cancel outstanding plans and preparation; neither may restore an old session.
        _ = model.keepSmallestPlan(); model.setTrashedIDs(removed, true); model.reset()
        try await Task.sleep(nanoseconds: 200_000_000)
        precondition(model.index == nil && model.roots.isEmpty && model.groups.isEmpty && !model.preparingSizeBasedPlans)
        precondition(heartbeat.ticks > 10 && heartbeat.largestGap < 0.5, "Large preparation must leave the main actor responsive")
        print(String(format: "PASS 100,000 native results: tree install %.3fs, 1,000 redraws %.3fs, plan request %.3fs, largest UI heartbeat gap %.3fs; large-group selection, search, Trash/Undo and stale-result guards", install, redraw, planRequest, heartbeat.largestGap))
    }

    static func crossDriveResults() async throws {
        let scan = await Task.detached(priority: .userInitiated) {
            let files = (0..<100_000).map { number in
                DuplicateFile(id: "p\(number)", name: String(format: "V%06x.dat", number), path: "/Generated/M3rT/\(number)",
                    size: 1_024, modifiedTime: nil, source: "pikpak", folderCreatedTime: number == 0 ? "2020" : "2026")
            }
            var groups = [DuplicateGroup(id: "large", matchKind: .exactContent, size: 1_024, copies: 50_000,
                reclaimableBytes: 49_999 * 1_024, files: Array(files.prefix(50_000)))]
            for number in 25_000..<50_000 {
                groups.append(.init(id: "g\(number)", matchKind: .exactContent, size: 1_024, copies: 2,
                    reclaimableBytes: 1_024, files: Array(files[(number * 2)..<(number * 2 + 2)])))
            }
            return DuplicateScan(rootPath: "/Generated/M3rT", scannedFiles: 100_000, scannedFolders: 1,
                failedFolders: 0, duplicateFiles: 100_000, exactGroups: groups.count, possibleGroups: 0,
                reclaimableBytes: 74_999 * 1_024, groups: groups)
        }.value
        let output = try await Task.detached(priority: .userInitiated) {
            let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase
            return String(decoding: try encoder.encode(scan), as: UTF8.self)
        }.value
        let model = DownloaderModel.finderWorkspaceFixture(); defer { model.stopForWindowClose() }
        let heartbeat = Heartbeat(); heartbeat.start(); defer { heartbeat.stop() }
        let request = seconds { model.loadDuplicateResultFixture(output) }
        precondition(model.isPreparingDuplicateResults && request < 0.1)
        precondition(model.canBrowse && !model.canScanCurrentFolderForDuplicates && !model.canDeleteSelectedDuplicates,
            "Result preparation leaves browsing available and keeps incomplete cleanup disabled")
        try await until { !model.isPreparingDuplicateResults && model.duplicateScan?.scannedFiles == 100_000 }
        precondition(model.selectedDuplicateFileIDs.count == 74_999 && model.selectedDuplicateBytes == 74_999 * 1_024)
        precondition(model.selectedDuplicateCount(in: "large") == 49_999)
        let paging = seconds {
            var seen = Set<String>()
            for number in 0..<500 {
                let page = ResultPage(total: model.duplicateResultsIndex.fileCount, requestedPage: number)
                let slices = model.duplicateResultsIndex.slices(for: page)
                precondition(slices.reduce(0) { $0 + $1.range.count } == 200)
                for slice in slices { for file in slice.group.files[slice.range] { precondition(seen.insert(file.id).inserted) } }
            }
            precondition(seen.count == 100_000, "Every file must be reachable exactly once across page boundaries")
        }
        let toggling = seconds {
            for _ in 0..<1_000 {
                model.setDuplicateFileSelected("p49999", selected: false)
                precondition(model.selectedDuplicateBytes == 74_998 * 1_024 && model.selectedDuplicateCount(in: "large") == 49_998)
                model.setDuplicateFileSelected("p49999", selected: true)
            }
        }
        precondition(toggling < 1, "One-file selection must not rescan all results")
        model.setDuplicateFileSelected("p0", selected: true)
        precondition(!model.selectedDuplicateFileIDs.contains("p0"), "The last copy must remain protected")
        model.clearDuplicateSelection(); precondition(model.selectedDuplicateBytes == 0 && model.selectedDuplicateCount(in: "large") == 0)
        model.selectRecommendedDuplicates(); precondition(model.selectedDuplicateBytes == 74_999 * 1_024)
        model.updateDuplicateResultFixture(scan, selected: ["p99999"])
        try await until { !model.isPreparingDuplicateResults }
        precondition(model.selectedDuplicateFileIDs == ["p99999"] && model.selectedDuplicateBytes == 1_024)
        // Invalidate a decoding task with a new scan/account state.
        model.loadDuplicateResultFixture(output); model.clearDuplicateResultFixture()
        try await Task.sleep(nanoseconds: 100_000_000)
        precondition(model.duplicateScan == nil && !model.isPreparingDuplicateResults && model.selectedDuplicateBytes == 0)
        precondition(heartbeat.ticks > 10 && heartbeat.largestGap < 0.5)
        print(String(format: "PASS 100,000 cross-drive results: completion request %.3fs, all 500 pages %.3fs, 2,000 selection toggles %.3fs, largest UI heartbeat gap %.3fs; keeper protection, bulk selection, post-Trash indexing and stale decode rejection", request, paging, toggling, heartbeat.largestGap))
    }

    static func selectionArithmetic() {
        let file = DuplicateFile(id: "a", name: "a", path: "/Generated/a", size: .max, modifiedTime: nil)
        let extra = DuplicateFile(id: "b", name: "b", path: "/Generated/b", size: 12, modifiedTime: nil)
        var summary = DuplicateSelectionSummary()
        summary.update(file, groups: ["g"], selected: true); summary.update(extra, groups: ["g"], selected: true)
        precondition(summary.bytes == .max && summary.groupCounts["g"] == 2)
        summary.update(file, groups: ["g"], selected: false)
        precondition(summary.bytes == 12 && summary.groupCounts["g"] == 1)
        precondition(ResultPage(total: 100_001, requestedPage: 999).range == 100_000..<100_001)
        precondition(ResultPage(total: 0, requestedPage: -1).range.isEmpty)
        print("PASS selection byte overflow/reversal and page clamping")
    }
}

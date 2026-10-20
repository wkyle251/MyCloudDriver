import AppKit
import Foundation

#if !SIMILARITY_QUERY_TEST_LIBRARY
@main
#endif
struct SimilarityTreeExpansionTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let files = (0..<500).map { index in
            SimilarityFile(id: "file-\(index)", name: "Image \(index).jpg", path: "/Fixture/Image \(index).jpg",
                bytes: 100, family: "image", localPath: nil, cloudId: nil, ancestors: [], state: "ready")
        }
        let groups = (0..<250).map { index in
            SimilarityResultGroup(id: "group:\(index)", members: Array(files[(index * 2)..<(index * 2 + 2)]),
                minimumScore: 0.95, identical: false)
        }
        let report = SimilarityReport(source: .local, scope: ["Fixture"], status: "completed", threshold: 0.9,
            scannedFiles: 500, analysedFiles: 500, skippedFiles: 0, downloadedBytes: 0,
            totalGroups: 0, groups: [], issues: [], truncated: false, coverage: "Fixture", elapsedSeconds: 1, files: files)
        let model = SimilarityResultsModel()
        model.load(report, configuration: nil)
        while model.isIndexing { try await Task.sleep(nanoseconds: 10_000_000) }
        model.setFixtureGroups(groups, at: 0.9); model.browseGroups = true
        func waitForTree(_ ready: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            while !ready() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
            precondition(ready(), "Timed out waiting for the debounced result tree")
        }
        try await waitForTree { model.roots.count == 250 && model.roots.allSatisfy { $0.group != nil } }

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 350, height: 650))
        let outline = NSOutlineView(frame: scroll.bounds)
        scroll.documentView = outline
        let column = NSTableColumn(identifier: .init("name"))
        outline.addTableColumn(column); outline.outlineTableColumn = column
        let tree = SimilarityFileTree.Coordinator()
        tree.outline = outline; outline.dataSource = tree; outline.delegate = tree
        tree.select = { model.selectNode($0) }
        func refresh() {
            tree.update(snapshot: model.tree, selectedID: model.selectedNodeID,
                searching: !model.query.isEmpty, groupExpansion: model.browseGroups ? model.groupExpansion : nil)
        }
        refresh()
        model.setAllGroupsExpanded(true); refresh()
        precondition(outline.numberOfRows == 750, "Expand All must include groups beyond the initial 200-row expansion budget")
        precondition(model.roots.allSatisfy { outline.isItemExpanded($0) })
        print("PASS expand all: 250 groups and 500 files are visible")

        model.select(files[499].id); refresh()
        model.setAllGroupsExpanded(false); refresh()
        precondition(outline.numberOfRows == 250 && model.selectedGroupID == "group:249" && model.selectedID == nil)
        precondition((outline.item(atRow: outline.selectedRow) as? SimilarityTreeNode)?.id == "group:249")
        for _ in 0..<3 { refresh() }
        precondition(outline.numberOfRows == 250, "Selection updates must not reopen a collapsed group")
        print("PASS collapse all: selected file becomes its visible group and redraws keep groups closed")

        model.query = "Image 499"
        try await waitForTree { model.roots.count == 1 && model.roots[0].id == "group:249" }
        refresh()
        precondition(outline.numberOfRows == 1 && !outline.isItemExpanded(model.roots[0]))
        model.query = ""
        try await waitForTree { model.roots.count == 250 }
        refresh()
        precondition(outline.numberOfRows == 250)
        let merged = SimilarityResultGroup(id: "group:merged", members: Array(files[0..<4]), minimumScore: 0.85, identical: false)
        model.setFixtureGroups([merged] + groups.dropFirst(2), at: 0.8)
        model.minimumScore = 0.8
        try await waitForTree { model.roots.count == 249 && model.roots[0].id == "group:merged" }
        refresh()
        precondition(outline.numberOfRows == 249 && model.roots.allSatisfy { !outline.isItemExpanded($0) })
        print("PASS search and regroup: bulk collapse persists for filtered and newly formed groups")

        model.setAllGroupsExpanded(true); refresh()
        let first = model.roots[0]
        outline.collapseItem(first)
        refresh()
        precondition(!outline.isItemExpanded(first), "A manual toggle must survive unrelated updates")
        let firstRequest = model.groupExpansion?.id
        model.setAllGroupsExpanded(true); refresh()
        precondition(model.groupExpansion?.id != firstRequest && outline.isItemExpanded(first))
        model.browseGroups = false
        try await waitForTree { model.roots.allSatisfy { $0.group == nil } }
        refresh()
        model.browseGroups = true
        try await waitForTree { model.roots.count == 249 && model.roots.allSatisfy { $0.group != nil } }
        refresh()
        precondition(model.roots.allSatisfy { outline.isItemExpanded($0) })
        print("PASS repeated commands, individual toggles and switching between Groups / All files")

        model.select(files[300].id); refresh()
        let selectedRow = outline.selectedRow
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, outline.rect(ofRow: selectedRow).minY - 200)))
        scroll.reflectScrolledClipView(scroll.contentView)
        model.setTrashed(files[300].id, true)
        precondition(model.selectedID == files[302].id, "Skip the remaining singleton and continue in the next surviving group")
        try await waitForTree { model.tree.nodes[files[300].id] == nil }
        refresh()
        precondition((outline.item(atRow: outline.selectedRow) as? SimilarityTreeNode)?.id == files[302].id)
        precondition(scroll.contentView.bounds.minY > 0 && outline.visibleRect.intersects(outline.rect(ofRow: outline.selectedRow)),
            "Deleting a file in the middle must preserve the viewport and reveal its successor")
        model.setTrashed(files[300].id, false)
        precondition(model.selectedID == files[302].id, "Undo must not move the current selection")
        model.select(files[499].id); model.setTrashed(files[499].id, true)
        precondition(model.selectedID == files[497].id, "At the end, select the nearest surviving preceding file")
        print("PASS Trash advances to the next surviving group, preserves the viewport and falls back locally at the end")

        model.showAllFiles()
        try await waitForTree { !model.tree.grouped && model.tree.nodes[files[240].id] != nil }
        model.select(files[240].id); model.setTrashedIDs([files[240].id, files[241].id, files[242].id], true)
        precondition(model.selectedID == files[243].id, "Bulk Trash skips every removed file")
        model.query = "Image 48"
        try await waitForTree { model.tree.nodes[files[480].id] != nil && model.tree.nodes[files[470].id] == nil }
        model.select(files[480].id); model.setTrashed(files[480].id, true)
        precondition(model.selectedID == files[481].id, "Selection follows the filtered display order")
        model.query = "Image 42.jpg"
        try await waitForTree { model.tree.fileIDs == [files[42].id] }
        model.select(files[42].id); model.setTrashed(files[42].id, true)
        precondition(model.selectedID == nil && model.selectedGroupID == nil, "An empty filtered list must not jump to the first group")
        let matches = ["previous", "removed", "next", "last"]
        precondition(SimilarityResultSelection.next(after: "removed", in: matches) { $0 != "removed" } == "next")
        precondition(SimilarityResultSelection.next(after: "last", in: matches) { $0 != "removed" && $0 != "last" } == "next")
        print("PASS bulk and filtered Trash selection, empty results and next-match selection")

        model.setMinimumScoreFromSlider(0.714); precondition(model.minimumScore == 0.71)
        model.setMinimumScoreFromSlider(0.716); precondition(model.minimumScore == 0.72)
        model.setMinimumScoreFromSlider(-1); precondition(model.minimumScore == 0.05)
        model.setMinimumScoreFromSlider(2); precondition(model.minimumScore == 1)
        model.reset(); precondition(model.groupExpansion == nil)
        print("PASS whole-percent cutoff, 5–100% bounds and fresh-scan expansion reset")
    }
}

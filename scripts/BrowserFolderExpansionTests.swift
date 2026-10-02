import Foundation
import AppKit

@main
struct BrowserFolderExpansionTests {
    @MainActor
    static func main() async throws {
        _ = NSApplication.shared
        var requested: [Int?] = []
        let choices = BrowserNativeMenu()
        BrowserFolderExpansionAction.add(to: choices) { requested.append($0) }
        precondition(!choices.autoenablesItems && choices.items.count == 1)
        precondition(choices.items[0].title == "Expand All Levels" && choices.items[0].submenu == nil)
        choices.performActionForItem(at: 0)
        precondition(requested == [nil], "the direct action requests every level")
        choices.items[0].isEnabled = false
        choices.performActionForItem(at: 0)
        precondition(requested.count == 1, "a disabled native action cannot dispatch")
        let reopened = BrowserNativeMenu()
        BrowserFolderExpansionAction.add(to: reopened) { requested.append($0) }
        precondition(reopened !== choices && reopened.items[0] !== choices.items[0] && reopened.items[0].isEnabled,
                     "reopening creates fresh capabilities without changing the old menu")
        print("PASS native folder menu: direct Expand All Levels, no submenu, disabled actions and fresh menu instances")

        let symbols = ["chevron.right", "chevron.down", "folder", "folder.badge.plus",
                       "arrow.triangle.merge", "sum", "eye", "pencil", "arrow.down.circle",
                       "archivebox", "trash", "doc.on.doc", "arrow.clockwise", "xmark.circle"]
        for symbol in symbols {
            let icon = BrowserContextMenuStyle.icon(named: symbol)
            precondition(icon.size == NSSize(width: 16, height: 16))
            precondition(icon.isTemplate && icon.representations.allSatisfy { $0 is NSBitmapImageRep },
                         "fixed bitmap templates, not dynamically sized symbols")
            let representations = icon.representations.compactMap { $0 as? NSBitmapImageRep }
            precondition(representations.count == 2,
                         "both Retina and standard-resolution representations for \(symbol), got \(representations.count)")
            for (index, bitmap) in representations.enumerated() {
                precondition(bitmap.pixelsWide == 16 * (index + 1) && bitmap.pixelsHigh == bitmap.pixelsWide)
                precondition(bitmap.size == icon.size)
                let nonempty = (0..<bitmap.pixelsHigh).contains { y in
                    (0..<bitmap.pixelsWide).contains { x in (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 }
                }
                precondition(nonempty, "menu icon must render at both resolutions: \(symbol)")
            }
            for _ in 0..<20 {
                precondition(BrowserContextMenuStyle.icon(named: symbol) === icon, "reopening menus reuses an immutable, fixed-size icon")
            }
        }
        print("PASS context menu: 14 fixed-size, cached template icons, 1x/2x nonempty pixels")

        let tree = ["R": ["A", "B"], "A": ["C"], "C": ["D"], "B": ["E"], "E": ["F"]]
        for (levels, expected) in [(1, Set(["R", "A", "B"])),
                                   (2, Set(["R", "A", "B", "C", "E"]))] {
            let plan = BrowserFolderExpansionPlan(rootID: "R", rootName: "Root", levels: levels)
            var visited = Set<String>()
            while let folder = plan.nextFolder() {
                visited.insert(folder.id)
                plan.discoverChildren(of: folder.id, folderIDs: tree[folder.id] ?? [])
                plan.finish(folder.id)
            }
            precondition(visited == expected, "exact depth boundaries, selected folder is level zero")
            precondition(plan.isFinished && plan.loadedFolders == expected.count)
        }
        let all = BrowserFolderExpansionPlan(rootID: "R", rootName: "Root", levels: nil)
        var visited = Set<String>()
        while let folder = all.nextFolder() {
            precondition(visited.insert(folder.id).inserted, "one visit per ID")
            all.discoverChildren(of: folder.id, folderIDs: (tree[folder.id] ?? []) + ["R"])
            all.finish(folder.id)
        }
        precondition(visited == Set(["R", "A", "B", "C", "D", "E", "F"]) && all.isFinished)

        let pages = BrowserFolderExpansionPlan(rootID: "R", rootName: "Root", levels: 1)
        precondition(pages.nextFolder()?.id == "R")
        precondition(pages.claimPage(for: "R", token: nil))
        precondition(!pages.claimPage(for: "R", token: nil), "first-page retry loop blocked")
        pages.discoverChildren(of: "R", folderIDs: ["A", "A"])
        precondition(pages.claimPage(for: "R", token: "next"))
        precondition(!pages.claimPage(for: "R", token: "next"), "repeated pagination token blocked")
        pages.discoverChildren(of: "R", folderIDs: ["A", "B"])
        pages.finish("R")
        pages.resume("R")
        while let folder = pages.nextFolder() { pages.finish(folder.id, failed: folder.id == "B") }
        precondition(pages.isFinished && pages.loadedFolders == 2 && pages.failedFolders == 1)
        precondition(pages.progress.discoveredFolders == 3, "duplicate page entries do not inflate totals")
        // A selection of folders expands under one plan, whatever their order
        // and however they overlap.
        let multi = BrowserFolderExpansionPlan(roots: [("A", "A"), ("B", "B")], levels: nil)
        precondition(multi.rootIDs == ["A", "B"] && multi.rootName == "2 folders")
        var reached: [String] = []
        while let folder = multi.nextFolder() {
            reached.append(folder.id)
            multi.discoverChildren(of: folder.id, folderIDs: tree[folder.id] ?? [])
            multi.finish(folder.id)
        }
        precondition(Set(reached) == Set(["A", "C", "D", "B", "E", "F"]) && reached.count == 6,
                     "each selected root and its whole subtree, once")
        precondition(multi.isFinished && multi.progress.loadedFolders == 6)

        let overlapping = BrowserFolderExpansionPlan(roots: [("R", "R"), ("A", "A")], levels: nil)
        var overlapped: [String] = []
        while let folder = overlapping.nextFolder() {
            overlapped.append(folder.id)
            overlapping.discoverChildren(of: folder.id, folderIDs: tree[folder.id] ?? [])
            overlapping.finish(folder.id)
        }
        precondition(Set(overlapped).count == overlapped.count, "a root nested in another root is visited once")
        precondition(Set(overlapped) == Set(["R", "A", "B", "C", "D", "E", "F"]))
        precondition(BrowserFolderExpansionPlan(roots: [("R", "Root")], levels: 1).rootName == "Root",
                     "one folder is still named in the progress bar")

        let selectionMenu = BrowserNativeMenu()
        BrowserFolderExpansionAction.add(to: selectionMenu, folderCount: 3) { _ in }
        precondition(selectionMenu.items[0].title == "Expand All Levels in 3 Folders")
        precondition(BrowserFolderExpansionAction.title(folderCount: 1) == "Expand All Levels")
        print("PASS expansion plan: 1/2/all levels, cycles, duplicate IDs, repeated page tokens, partial failure totals, multi-folder roots")

        #if FOLDER_EXPANSION_TESTS
        try await DownloaderModel.testBrowserFolderExpansion()
        #endif
        #if FINDER_WORKSPACE_TESTS
        try DownloaderModel.testWorkspacePresentation()
        let suite = "com.wky.MyCloudDriver.FolderSelectionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        DownloaderModel.testBrowserFolderSelection(defaults: defaults)
        DownloaderModel.testPreviewKeyboardNavigation(defaults: defaults)
        DownloaderModel.testBrowserFolderToggle(defaults: defaults)
        #endif
    }
}

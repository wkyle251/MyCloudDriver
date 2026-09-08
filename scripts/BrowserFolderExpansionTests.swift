import Foundation
import AppKit

@main
struct BrowserFolderExpansionTests {
    @MainActor
    static func main() async throws {
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
        print("PASS expansion plan: 1/2/all levels, cycles, duplicate IDs, repeated page tokens, partial failure totals")

        #if FOLDER_EXPANSION_TESTS
        try await DownloaderModel.testBrowserFolderExpansion()
        #endif
    }
}

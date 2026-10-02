import AppKit
import Foundation

@main struct BookmarkTests {
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(condition(), "Timed out waiting for synthetic bookmark navigation")
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let suite = "com.wky.BookmarkTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let firstWindow = FinderBookmarkStore(defaults: defaults)
        let secondWindow = FinderBookmarkStore(defaults: defaults)
        let folder = FinderBookmark(provider: "pikpak", scope: "account-A", itemID: "folder", name: "Projects", isFolder: true, parents: [])
        let file = FinderBookmark(provider: "pikpak", scope: "account-A", itemID: "file", name: "Plan.txt", isFolder: false,
                                  parents: [.init(id: "folder", name: "Projects", path: "/Projects")])
        firstWindow.add(folder)
        precondition(secondWindow.bookmarks == [folder], "a second window receives additions immediately")
        secondWindow.add(file)
        firstWindow.add(folder)
        precondition(firstWindow.bookmarks.count == 2 && secondWindow.bookmarks.count == 2, "repeat adds deduplicate; cross-window writes merge")
        let accountB = FinderBookmark(provider: "pikpak", scope: "account-B", itemID: "file", name: "Other.txt", isFolder: false, parents: [])
        secondWindow.add(accountB)
        precondition(firstWindow.items(provider: "pikpak", scope: "account-A").count == 2)
        precondition(firstWindow.items(provider: "pikpak", scope: "account-B") == [accountB])
        precondition(firstWindow.items(provider: "local", scope: "account-A").isEmpty && firstWindow.items(provider: "pikpak", scope: nil).isEmpty)
        firstWindow.rename(provider: "pikpak", scope: "account-A", itemID: "folder", name: "Renamed")
        precondition(secondWindow.items(provider: "pikpak", scope: "account-A").first { $0.itemID == "file" }?.path == "/Renamed/Plan.txt")
        precondition(secondWindow.items(provider: "pikpak", scope: "account-B") == [accountB], "renames never cross account boundaries")
        let restored = FinderBookmarkStore(defaults: defaults)
        precondition(restored.bookmarks == firstWindow.bookmarks, "bookmarks persist across store recreation")
        secondWindow.remove(folder)
        precondition(!restored.contains(provider: "pikpak", scope: "account-A", itemID: "folder"))
        print("PASS bookmark persistence, deduplication, multiwindow updates, account/provider isolation and renamed ancestor paths")
        DownloaderModel.testBookmarkAccountScope(defaults: defaults)

        let pikpak = DownloaderModel.finderWorkspaceFixture(defaults: defaults)
        defer { pikpak.stopForWindowClose() }
        let projects = pikpak.browserItems.first { $0.name == "Projects" }!
        let projectsBookmark = pikpak.bookmark(projects)!
        let design = pikpak.browserTreeEntries.first { $0.item.name == "Design.txt" }!.item
        let designBookmark = pikpak.bookmark(design)!
        precondition(designBookmark.parents.map(\.name) == ["Projects", "Drafts"])
        precondition(pikpak.openBookmark(projectsBookmark, store: firstWindow))
        precondition(pikpak.currentBrowserPath == "/Projects")
        precondition(pikpak.openBookmark(designBookmark, store: firstWindow))
        try await wait { pikpak.selectedBrowserItemID == design.id }
        precondition(pikpak.currentBrowserPath == "/Projects/Drafts" && pikpak.browserItems.contains { $0.name == "Design.txt" })
        precondition(pikpak.previewInfo == nil && pikpak.previewFileID == nil, "revealing a bookmarked file does not request file content")
        let wrongAccount = FinderBookmark(provider: designBookmark.provider, scope: "wrong-account", itemID: designBookmark.itemID,
            name: designBookmark.name, isFolder: false, parents: designBookmark.parents)
        precondition(!pikpak.openBookmark(wrongAccount, store: firstWindow))
        print("PASS PikPak folder opening, nested file ancestry/selection and rejected cross-account navigation with synthetic listings")

        let manager = FileManager.default
        let temporary = manager.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("BookmarkTests-\(UUID().uuidString)")
        let root = temporary.appendingPathComponent("Drive"), other = temporary.appendingPathComponent("Drive-other")
        try manager.createDirectory(at: root.appendingPathComponent("Folder/Nested"), withIntermediateDirectories: true)
        try manager.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: temporary) }
        let fileURL = root.appendingPathComponent("Folder/Nested/Example.txt")
        try Data("Synthetic fixture".utf8).write(to: fileURL)
        let local = NativeDriveModel(kind: .local)
        local.connect(ICloudDriveProvider(rootURL: root, kind: .local))
        defer { local.close() }
        try await wait { !local.isLoading }
        let item = try ICloudDriveProvider.item(fileURL)
        let fileBookmark = local.bookmark(item)!
        precondition(local.openBookmark(fileBookmark, store: firstWindow))
        try await wait { !local.isLoading }
        precondition(local.location.url == fileURL.deletingLastPathComponent() && local.selection == [item.id])
        precondition(local.history.map(\.title) == ["Drive", "Folder", "Nested"])
        let folderItem = try ICloudDriveProvider.item(fileURL.deletingLastPathComponent())
        let folderBookmark = local.bookmark(folderItem)!
        precondition(local.openBookmark(folderBookmark, store: firstWindow))
        try await wait { !local.isLoading }
        precondition(local.location.url == fileURL.deletingLastPathComponent() && local.selection.isEmpty)
        let outside = FinderBookmark(provider: "local", scope: local.bookmarkScope!, itemID: "outside", name: "Outside", isFolder: true, parents: [], url: other)
        precondition(!local.openBookmark(outside, store: firstWindow) && local.error?.contains("outside") == true)
        let missing = FinderBookmark(provider: "local", scope: local.bookmarkScope!, itemID: "missing", name: "Missing.txt", isFolder: false, parents: [], url: root.appendingPathComponent("Missing.txt"))
        precondition(!local.openBookmark(missing, store: firstWindow) && local.error?.contains("no longer available") == true)
        let disconnectedScope = FinderBookmark(provider: "local", scope: other.absoluteString, itemID: item.id, name: item.name, isFolder: false, parents: [], url: fileURL)
        precondition(!local.openBookmark(disconnectedScope, store: firstWindow))
        print("PASS native folder/file navigation, selection, complete breadcrumbs and rejected missing/outside/wrong-root bookmarks")
    }
}

import AppKit
import Foundation

private final class BookmarkCreationGate: @unchecked Sendable {
    private let lock = NSLock(), release = DispatchSemaphore(value: 0)
    private var entered = false
    var started: Bool { lock.lock(); defer { lock.unlock() }; return entered }
    func data(_ url: URL) -> Data {
        lock.lock(); entered = true; lock.unlock()
        precondition(release.wait(timeout: .now() + 8) == .success, "Generated bookmark metadata fixture was not released")
        return Data("generated bookmark metadata".utf8)
    }
    func finish() { release.signal() }
}

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
        precondition(local.openBookmark(outside, store: firstWindow))
        try await wait { !local.isLoading }
        precondition(local.error?.contains("outside") == true)
        let missing = FinderBookmark(provider: "local", scope: local.bookmarkScope!, itemID: "missing", name: "Missing.txt", isFolder: false, parents: [], url: root.appendingPathComponent("Missing.txt"))
        precondition(local.openBookmark(missing, store: firstWindow))
        try await wait { !local.isLoading }
        precondition(local.error?.contains("no longer available") == true)
        let disconnectedScope = FinderBookmark(provider: "local", scope: other.absoluteString, itemID: item.id, name: item.name, isFolder: false, parents: [], url: fileURL)
        precondition(!local.openBookmark(disconnectedScope, store: firstWindow))
        print("PASS native folder/file navigation, selection, complete breadcrumbs and rejected missing/outside/wrong-root bookmarks")

        let writeSuite = "GeneratedBookmarkWrites.\(UUID())", writeDefaults = UserDefaults(suiteName: writeSuite)!
        defer { writeDefaults.removePersistentDomain(forName: writeSuite) }
        let writes = FinderBookmarkStore(defaults: writeDefaults), firstGate = BookmarkCreationGate()
        local.toggleBookmarks([item], store: writes, bookmarkData: { firstGate.data($0) })
        precondition(writes.contains(provider: "local", scope: local.bookmarkScope, itemID: item.id), "The explicit add must be persisted before optional metadata starts")
        try await wait { firstGate.started }
        local.toggleBookmarks([folderItem], store: writes, bookmarkData: { _ in Data([2]) })
        precondition(writes.contains(provider: "local", scope: local.bookmarkScope, itemID: item.id)
            && writes.contains(provider: "local", scope: local.bookmarkScope, itemID: folderItem.id),
            "Adding B while A's metadata is blocked must preserve both explicit additions")
        firstGate.finish()
        try await wait { local.bookmarkWriteTask == nil }
        precondition(writes.contains(provider: "local", scope: local.bookmarkScope, itemID: item.id)
            && writes.contains(provider: "local", scope: local.bookmarkScope, itemID: folderItem.id))

        let pendingURL = root.appendingPathComponent("GeneratedPending.txt")
        try Data("generated".utf8).write(to: pendingURL)
        let pending = try ICloudDriveProvider.item(pendingURL), secondGate = BookmarkCreationGate()
        local.toggleBookmarks([pending], store: writes, bookmarkData: { secondGate.data($0) })
        try await wait { secondGate.started }
        local.toggleBookmarks([pending], store: writes)
        precondition(!writes.contains(provider: "local", scope: local.bookmarkScope, itemID: pending.id))
        secondGate.finish()
        try await Task.sleep(nanoseconds: 30_000_000)
        precondition(!writes.contains(provider: "local", scope: local.bookmarkScope, itemID: pending.id),
            "Late metadata must not re-add a bookmark removed by the second toggle")
        print("PASS blocked bookmark enrichment preserves separate additions and rapid double-toggle remains removed")
    }
}

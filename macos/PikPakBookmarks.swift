import Foundation

extension DownloaderModel {
    var canOpenBookmarks: Bool { !isRunning && !isChangingAccount && (hasAccountSession || canBrowse) }
    func bookmark(_ item: BrowserItem) -> FinderBookmark? {
        guard !isBrowsingSharedLink, let scope = bookmarkScope else { return nil }
        let route = bookmarkLocations(for: item)
        return .init(provider: "pikpak", scope: scope, itemID: item.id, name: item.name,
                     isFolder: item.isFolder, parents: route)
    }

    func toggleBookmark(_ item: BrowserItem, store requestedStore: FinderBookmarkStore? = nil) {
        let store = requestedStore ?? .shared
        guard let bookmark = bookmark(item) else { return }
        if store.contains(provider: bookmark.provider, scope: bookmark.scope, itemID: item.id) {
            store.remove(bookmark)
        } else { store.add(bookmark) }
    }
}

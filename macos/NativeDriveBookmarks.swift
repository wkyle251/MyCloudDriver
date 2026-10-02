import Foundation

extension NativeDriveModel {
    var bookmarkScope: String? { provider?.root.id }

    func bookmark(_ item: CloudDriveItem) -> FinderBookmark? {
        guard let scope = bookmarkScope else { return nil }
        var parents = history
        if let row = visibleRows.first(where: { $0.item.id == item.id }), row.id.path.count > 1 {
            for count in 1..<row.id.path.count {
                if let ancestor = tree.rowByID[.init(path: Array(row.id.path.prefix(count)))] {
                    parents.append(ancestor.item.location)
                }
            }
        }
        return .init(provider: kind.rawValue, scope: scope, itemID: item.id, name: item.name,
            isFolder: item.isFolder,
            parents: parents.map { .init(id: $0.id, name: $0.title, path: $0.url?.path ?? $0.title, url: $0.url) },
            url: item.url, fileBookmark: item.url.flatMap { try? $0.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil) })
    }

    func toggleBookmarks(_ items: [CloudDriveItem], store requestedStore: FinderBookmarkStore? = nil) {
        let store = requestedStore ?? .shared
        let saved = items.compactMap { bookmark($0) }
        let removing = !saved.isEmpty && saved.allSatisfy { store.contains(provider: $0.provider, scope: $0.scope, itemID: $0.itemID) }
        for entry in saved {
            if removing { store.remove(entry) } else { store.add(entry) }
        }
    }
}

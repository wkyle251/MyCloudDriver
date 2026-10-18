import Foundation

extension NativeDriveModel {
    var bookmarkScope: String? { provider?.root.id }

    func bookmark(_ item: CloudDriveItem) -> FinderBookmark? {
        guard let scope = bookmarkScope else { return nil }
        var parents = history
        if let rowID = tree.firstRowIDs[item.id], let row = tree.rowByID[rowID], viewMode == 0, row.id.path.count > 1 {
            for count in 1..<row.id.path.count {
                if let ancestor = tree.rowByID[.init(path: Array(row.id.path.prefix(count)))] {
                    parents.append(ancestor.item.location)
                }
            }
        }
        return .init(provider: kind.rawValue, scope: scope, itemID: item.id, name: item.name,
            isFolder: item.isFolder,
            parents: parents.map { .init(id: $0.id, name: $0.title, path: $0.url?.path ?? $0.title, url: $0.url) },
            url: item.url)
    }

    func cancelBookmarkWrites() {
        bookmarkWriteTask?.cancel(); bookmarkWriteTask = nil; bookmarkWriteRequest = UUID()
    }

    func toggleBookmarks(_ items: [CloudDriveItem], store requestedStore: FinderBookmarkStore? = nil,
                         bookmarkData: @escaping @Sendable (URL) throws -> Data = {
                             try $0.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                         }) {
        let store = requestedStore ?? .shared
        let saved = items.compactMap { bookmark($0) }
        let removing = !saved.isEmpty && saved.allSatisfy { store.contains(provider: $0.provider, scope: $0.scope, itemID: $0.itemID) }
        cancelBookmarkWrites()
        if removing { for entry in saved { store.remove(entry) }; return }
        guard !saved.isEmpty, let provider else { return }
        // The explicit mutation is immediate and contains no filesystem work.
        // Canceling optional bookmark-data enrichment must never lose an add,
        // and a second toggle must be able to remove this pending snapshot.
        for var entry in saved {
            if let existing = store.bookmarks.first(where: { $0.id == entry.id && $0.url == entry.url }) {
                entry.fileBookmark = existing.fileBookmark
            }
            store.add(entry)
        }
        let ids = Set(saved.map(\.id))
        let snapshots = store.bookmarks.filter { ids.contains($0.id) && $0.url != nil && $0.fileBookmark == nil }
        guard !snapshots.isEmpty else { return }
        let request = UUID(); bookmarkWriteRequest = request
        bookmarkWriteTask = Task { [weak self] in
            do {
                let cancellation = DriveCoordinationCancellation()
                let entries = try await NativeFileWork.run(onCancel: { cancellation.cancel() }) {
                    try snapshots.map { entry in
                        try cancellation.check()
                        var enriched = entry
                        enriched.fileBookmark = entry.url.flatMap { try? bookmarkData($0) }
                        try cancellation.check()
                        return (entry, enriched)
                    }
                }
                guard let self, !Task.isCancelled, self.provider === provider, self.bookmarkWriteRequest == request else { return }
                self.bookmarkWriteTask = nil
                for (snapshot, enriched) in entries where enriched.fileBookmark != nil {
                    // Full equality includes provider/scope, URL and addedAt:
                    // a removed, re-added, renamed or changed bookmark wins.
                    guard store.bookmarks.contains(snapshot) else { continue }
                    store.add(enriched)
                }
            } catch {
                guard let self, !Task.isCancelled, self.provider === provider, self.bookmarkWriteRequest == request else { return }
                // Enrichment is optional; the already persisted URL snapshot
                // remains usable if metadata cannot be read before the deadline.
                self.bookmarkWriteTask = nil
            }
        }
    }
}

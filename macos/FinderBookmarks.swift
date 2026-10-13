import AppKit
import Combine
import Foundation
import SwiftUI

struct FinderBookmarkLocation: Codable, Hashable {
    let id: String
    var name: String
    var path: String
    var url: URL? = nil
}

/// The identity includes both the drive and its account/root. Cloud file IDs
/// can repeat in different accounts, and local roots can change independently.
struct FinderBookmark: Codable, Hashable, Identifiable {
    let provider: String
    let scope: String
    let itemID: String
    var name: String
    let isFolder: Bool
    var parents: [FinderBookmarkLocation]
    var url: URL? = nil
    var fileBookmark: Data? = nil
    var addedAt: Date = Date()
    var id: String { [provider, scope, itemID].map { "\($0.utf8.count):\($0)" }.joined() }
    var kindSortKey: String { isFolder ? "0-folder" : "1-file" }
    var parentPath: String { url?.deletingLastPathComponent().path ?? parents.last?.path ?? "/" }
    var path: String { url?.path ?? (parentPath == "/" ? "/" + name : parentPath + "/" + name) }
}

@MainActor final class FinderBookmarkStore: ObservableObject {
    static let shared = FinderBookmarkStore()
    static let storageKey = "myCloudDriver.fileBookmarks.v1"
    private static let changed = Notification.Name("MyCloudDriverBookmarksChanged")
    @Published private(set) var bookmarks: [FinderBookmark] = []
    private let defaults: UserDefaults
    private var observers: [NSObjectProtocol] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        reload()
        for name in [Self.changed, UserDefaults.didChangeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            })
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func items(provider: String, scope: String?) -> [FinderBookmark] {
        guard let scope else { return [] }
        return bookmarks.filter { $0.provider == provider && $0.scope == scope }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func contains(provider: String, scope: String?, itemID: String) -> Bool {
        guard let scope else { return false }
        return bookmarks.contains { $0.provider == provider && $0.scope == scope && $0.itemID == itemID }
    }
    func add(_ bookmark: FinderBookmark) {
        guard !bookmark.provider.isEmpty, !bookmark.scope.isEmpty, !bookmark.itemID.isEmpty else { return }
        mutate { entries in
            if let index = entries.firstIndex(where: { $0.id == bookmark.id }) {
                var updated = bookmark; updated.addedAt = entries[index].addedAt
                entries[index] = updated
            } else { entries.append(bookmark) }
        }
    }
    func remove(_ bookmark: FinderBookmark) { mutate { $0.removeAll { $0.id == bookmark.id } } }
    func remove(provider: String, scope: String?, itemID: String) {
        guard let scope else { return }
        mutate { $0.removeAll { $0.provider == provider && $0.scope == scope && $0.itemID == itemID } }
    }
    /// Keep bookmarked descendants' breadcrumbs current after a folder rename.
    func rename(provider: String, scope: String?, itemID: String, name: String) {
        guard let scope else { return }
        mutate { entries in
            for index in entries.indices where entries[index].provider == provider && entries[index].scope == scope {
                if entries[index].itemID == itemID { entries[index].name = name }
                if let parent = entries[index].parents.firstIndex(where: { $0.id == itemID }) {
                    entries[index].parents[parent].name = name
                    for offset in parent..<entries[index].parents.count {
                        let previous = offset == 0 ? "/" : entries[index].parents[offset - 1].path
                        let component = entries[index].parents[offset].name
                        entries[index].parents[offset].path = previous == "/" ? "/" + component : previous + "/" + component
                    }
                }
            }
        }
    }
    private func reload() {
        let decoded = defaults.data(forKey: Self.storageKey).flatMap { try? JSONDecoder().decode([FinderBookmark].self, from: $0) } ?? []
        var seen = Set<String>()
        let loaded = decoded.filter { !$0.scope.isEmpty && !$0.itemID.isEmpty && seen.insert($0.id).inserted }
        if bookmarks != loaded { bookmarks = loaded }
    }
    private func mutate(_ operation: (inout [FinderBookmark]) -> Void) {
        // Read the latest saved document before each write so a second window
        // never overwrites a bookmark just added in another window.
        reload()
        var updated = bookmarks
        operation(&updated)
        guard updated != bookmarks, let data = try? JSONEncoder().encode(updated) else { return }
        defaults.set(data, forKey: Self.storageKey)
        bookmarks = updated
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }
}

private struct FinderBookmarkStoreKey: EnvironmentKey {
    static let defaultValue: FinderBookmarkStore? = nil
}

extension EnvironmentValues {
    var finderBookmarkStore: FinderBookmarkStore? {
        get { self[FinderBookmarkStoreKey.self] }
        set { self[FinderBookmarkStoreKey.self] = newValue }
    }
}

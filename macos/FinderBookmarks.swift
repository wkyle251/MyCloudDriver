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
    var parentPath: String { parents.last?.path ?? "/" }
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

struct FinderBookmarksWorkspace: View {
    @ObservedObject var store: FinderBookmarkStore
    let provider: String
    let scope: String?
    let sourceTitle: String
    var canOpen = true
    let open: (FinderBookmark) -> Void
    let showBrowser: () -> Void
    @State private var query = ""
    private var items: [FinderBookmark] {
        let saved = store.items(provider: provider, scope: scope)
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return search.isEmpty ? saved : saved.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.path.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) {
                HStack { title; Spacer(minLength: 8); search.frame(width: 230) }
                VStack(alignment: .leading, spacing: 8) { title; search }
            }.finderCard(padding: 12)
            if items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bookmark").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text(query.isEmpty ? "No bookmarks yet" : "No matching bookmarks").font(.headline)
                    Text(scope == nil ? "Sign in or connect this drive to view its bookmarks." : query.isEmpty ? "Right-click a file or folder in Browser and choose Add to Bookmarks." : "Try a different name or path.")
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Browser", action: showBrowser)
                }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(items) { bookmark in
                            HStack(spacing: 10) {
                                Button { open(bookmark) } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: bookmark.isFolder ? "folder.fill" : "doc").font(.system(size: 22)).foregroundStyle(FinderAppearance.accent)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(bookmark.name).lineLimit(1).truncationMode(.middle)
                                            Text(bookmark.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        }.frame(maxWidth: .infinity, alignment: .leading)
                                    }.contentShape(Rectangle())
                                }.buttonStyle(.plain).pointingHandCursor().disabled(!canOpen)
                                    .help(bookmark.isFolder ? "Open this folder in Browser" : "Show this file in Browser")
                                Button { store.remove(bookmark) } label: { Image(systemName: "bookmark.slash") }
                                    .buttonStyle(.borderless).pointingHandCursor().help("Remove from Bookmarks")
                                    .accessibilityLabel("Remove \(bookmark.name) from Bookmarks")
                            }.padding(12).background(Color.primary.opacity(0.025))
                                .contextMenu {
                                    Button(bookmark.isFolder ? "Open Folder" : "Show in Browser") { open(bookmark) }.disabled(!canOpen)
                                    Divider()
                                    Button("Remove from Bookmarks") { store.remove(bookmark) }
                                }
                        }
                    }
                }.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private var title: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Bookmarks", systemImage: "bookmark").font(.headline)
            Text(sourceTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }
    private var search: some View { TextField("Search bookmarks", text: $query).textFieldStyle(.roundedBorder) }
}

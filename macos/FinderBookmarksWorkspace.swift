import AppKit
import SwiftUI

/// Bookmarks are a virtual Finder location. Opening one presents its real
/// contents in the same workspace; removing a row only removes its bookmark.
struct FinderBookmarksWorkspace: View {
    @ObservedObject var store: FinderBookmarkStore
    let provider: String
    let scope: String?
    let sourceTitle: String
    var canOpen = true
    let open: (FinderBookmark) -> Void
    let showBrowser: () -> Void
    @AppStorage("bookmarkViewMode") private var viewMode = 0
    @AppStorage("bookmarkItemZoom") private var itemZoom = 1.0
    @State private var query = ""
    @State private var selection = Set<String>()
    @State private var sortOrder = [KeyPathComparator(\FinderBookmark.name)]
    @State private var sortColumn: BrowserSortColumn = .name
    @State private var ascending = true
    @State private var focusedID: String?
    @State private var anchorID: String?
    @FocusState private var searchFocused: Bool
    @FocusState private var filesFocused: Bool

    private var zoom: Double { itemZoom.isFinite ? min(1.8, max(0.75, itemZoom)) : 1 }
    private var items: [FinderBookmark] {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.items(provider: provider, scope: scope).filter {
            search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.path.localizedCaseInsensitiveContains(search)
        }.sorted(using: sortOrder + [KeyPathComparator(\FinderBookmark.id)])
    }

    private var selected: [FinderBookmark] { items.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 12) {
            toolbar
            VStack(spacing: 0) {
                if items.isEmpty { emptyState }
                else if viewMode == 1 { thumbnails }
                else { table }
                Divider()
                HStack {
                    Label(sourceTitle, systemImage: "bookmark").lineLimit(1)
                    Spacer()
                    Text(selection.isEmpty ? "\(items.count.formatted()) bookmarks" : "\(selected.count.formatted()) selected")
                }.font(.caption).foregroundStyle(.secondary).padding(10)
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)) }
            .focusable().focused($filesFocused)
            .onMoveCommand { if viewMode == 1 { move($0) } }
            .onExitCommand { selection = [] }
            .onDeleteCommand { removeSelected() }
            .background {
                BrowserKeyboardMonitor(handlesRangeSelection: filesFocused && viewMode == 1, handlesDelete: !selection.isEmpty,
                    handlesZoom: true, handlesQuickLook: false,
                    onShiftMove: { move($0, extending: true) }, onCommandDelete: removeSelected,
                    onZoomIn: { resize(0.15) }, onZoomOut: { resize(-0.15) }, onActualSize: { itemZoom = 1 },
                    onQuickLook: { _ in false }, onCancelQuickLook: { false }, ownsQuickLookPanel: { _ in false },
                    handlesSelectAll: true, onSelectAllFolders: { selection = Set(items.map(\.id)) },
                    handlesOpen: canOpen && selected.count == 1, onOpen: { if let item = selected.first { open(item) } })
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: scope) { _ in selection = []; query = "" }
        .onChange(of: items.map(\.id)) { selection.formIntersection($0) }
        .onAppear { filesFocused = true }
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { location; Spacer(minLength: 8); controls; search.frame(width: 210) }
            VStack(spacing: 8) { HStack { location; Spacer(); controls }; search }
        }.finderCard(padding: 10)
    }
    private var location: some View {
        HStack(spacing: 9) {
            Image(systemName: "bookmark.fill").foregroundStyle(FinderAppearance.accent)
                .frame(width: 30, height: 30)
                .background(FinderAppearance.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text("Bookmarks").font(.callout.weight(.semibold))
                Text(sourceTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
    private var controls: some View {
        HStack(spacing: 9) {
            Picker("Bookmark view", selection: $viewMode) {
                Image(systemName: "list.bullet").accessibilityLabel("List").tag(0)
                Image(systemName: "square.grid.3x3.fill").accessibilityLabel("Thumbnails").tag(1)
            }.labelsHidden().pickerStyle(.segmented).frame(width: 76)
            Menu {
                Button("Make Items Larger") { resize(0.15) }.disabled(zoom >= 1.8)
                Button("Make Items Smaller") { resize(-0.15) }.disabled(zoom <= 0.75)
                Button("Actual Size") { itemZoom = 1 }
                Divider()
                Button("Sort by Name") { sort(.name) }
                Button("Sort by Kind") { sort(.kind) }
                Button("Sort by Date Added") { sort(.modified) }
            } label: { Image(systemName: "textformat.size") }.menuStyle(.borderlessButton)
            Button { if let item = selected.first { open(item) } } label: { Image(systemName: "arrow.up.forward.app") }
                .disabled(!canOpen || selected.count != 1).help("Open the selected bookmark")
            Button(action: removeSelected) { Image(systemName: "bookmark.slash") }
                .disabled(selection.isEmpty).help("Remove selected bookmarks")
        }.pointingHandCursor()
    }
    private var search: some View {
        TextField("Search bookmarks", text: $query).textFieldStyle(.roundedBorder).focused($searchFocused)
    }

    private var table: some View {
        Table(items, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { bookmark in
                HStack(spacing: 8) {
                    if bookmark.isFolder {
                        Button { open(bookmark) } label: { Image(systemName: "chevron.right").font(.caption) }
                            .buttonStyle(.borderless).disabled(!canOpen).help("Open bookmarked folder")
                    } else { Color.clear.frame(width: 12) }
                    Image(systemName: bookmark.isFolder ? "folder.fill" : "doc")
                        .foregroundStyle(FinderAppearance.accent).font(.system(size: 20 * zoom))
                    Text(bookmark.name).lineLimit(1).truncationMode(.middle).help(bookmark.name)
                }
                .contentShape(Rectangle()).onTapGesture(count: 2) { if canOpen { open(bookmark) } }
                .contextMenu { contextMenu(bookmark) }
            }.width(min: 180, ideal: 270, max: .infinity)
            TableColumn("Kind", value: \.kindSortKey) { Text($0.isFolder ? "Folder" : "File") }.width(min: 60, ideal: 75, max: 110)
            TableColumn("Location", value: \.parentPath) { Text($0.parentPath).lineLimit(1).truncationMode(.middle).help($0.path) }
                .width(min: 100, ideal: 220, max: .infinity)
            TableColumn("Date Added", value: \.addedAt) { Text($0.addedAt, style: .date).foregroundStyle(.secondary) }
                .width(min: 90, ideal: 110, max: 140)
        }
        .font(.system(size: 13 * zoom)).accessibilityLabel("Bookmarked files and folders")
        .accessibilityHint("Select items, double-click a folder to browse its contents, or use the open button. Command Delete removes bookmarks and keeps the files.")
    }

    private var thumbnails: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140 * zoom), spacing: 12)], spacing: 12) {
                ForEach(items) { bookmark in
                    VStack(spacing: 9) {
                        Image(systemName: bookmark.isFolder ? "folder.fill" : "doc")
                            .font(.system(size: 50 * zoom)).foregroundStyle(FinderAppearance.accent)
                            .frame(height: 64 * zoom)
                        Text(bookmark.name).font(.system(size: 13 * zoom)).lineLimit(2).multilineTextAlignment(.center)
                        Text(bookmark.parentPath).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .padding(12).frame(maxWidth: .infinity)
                    .background(selection.contains(bookmark.id) ? FinderAppearance.accent.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { if canOpen { open(bookmark) } }
                    .onTapGesture { select(bookmark) }
                    .contextMenu { contextMenu(bookmark) }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("bookmark-" + bookmark.id)
                    .accessibilityAddTraits(selection.contains(bookmark.id) ? [.isButton, .isSelected] : [.isButton])
                    .accessibilityAction { select(bookmark) }
                    .accessibilityAction(named: Text("Open Bookmark")) { if canOpen { open(bookmark) } }
                }
            }.padding(12)
        }.accessibilityLabel("Bookmark thumbnails")
    }
    @ViewBuilder private func contextMenu(_ bookmark: FinderBookmark) -> some View {
        Button(bookmark.isFolder ? "Open Folder" : "Open Location") { open(bookmark) }.disabled(!canOpen)
        Divider()
        Button("Remove from Bookmarks") {
            if selection.contains(bookmark.id) { removeSelected() } else { store.remove(bookmark) }
        }
    }
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bookmark").font(.system(size: 36)).foregroundStyle(.secondary)
            Text(query.isEmpty ? "No bookmarks yet" : "No matching bookmarks").font(.headline)
            Text(scope == nil ? "Sign in or connect this drive to view its bookmarks." : query.isEmpty ? "Right-click a file or folder in Browser and choose Add to Bookmarks." : "Try a different name or path.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Button("Open Browser", action: showBrowser)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    private func resize(_ delta: Double) { itemZoom = min(1.8, max(0.75, zoom + delta)) }
    private func sort(_ column: BrowserSortColumn) {
        if column == sortColumn { ascending.toggle() } else { sortColumn = column; ascending = true }
        let order: SortOrder = ascending ? .forward : .reverse
        switch column {
        case .modified: sortOrder = [KeyPathComparator(\FinderBookmark.addedAt, order: order)]
        case .kind: sortOrder = [KeyPathComparator(\FinderBookmark.kindSortKey, order: order)]
        default: sortOrder = [KeyPathComparator(\FinderBookmark.name, order: order)]
        }
    }
    private func select(_ bookmark: FinderBookmark) {
        filesFocused = true
        focusedID = bookmark.id; anchorID = bookmark.id
        if NSEvent.modifierFlags.contains(.command) {
            if !selection.insert(bookmark.id).inserted { selection.remove(bookmark.id) }
        } else { selection = [bookmark.id] }
    }
    private func move(_ direction: MoveCommandDirection, extending: Bool = false) {
        guard !searchFocused, !items.isEmpty, direction == .up || direction == .down || direction == .left || direction == .right else { return }
        let step = direction == .down || direction == .right ? 1 : -1
        let index = items.firstIndex { $0.id == focusedID } ?? items.firstIndex { selection.contains($0.id) } ?? (step > 0 ? -1 : items.count)
        let next = min(items.count - 1, max(0, index + step))
        if extending {
            let anchor = items.firstIndex { $0.id == anchorID } ?? max(0, min(items.count - 1, index))
            selection = Set(items[min(anchor, next)...max(anchor, next)].map(\.id))
        } else { selection = [items[next].id]; anchorID = items[next].id }
        focusedID = items[next].id
    }
    private func removeSelected() {
        for bookmark in selected { store.remove(bookmark) }
        selection = []
    }
}

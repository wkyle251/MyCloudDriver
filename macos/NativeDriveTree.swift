import Foundation

/// A file can occur in several Photos albums. Identify its row by the full
/// visible path, while file operations continue to use the provider's item ID.
struct NativeDriveRowID: Hashable, Sendable {
    let path: [String]
    var itemID: String { path.last! }
    var parent: Self? { path.count > 1 ? .init(path: Array(path.dropLast())) : nil }
}

struct NativeDriveRow: Identifiable, Sendable {
    let id: NativeDriveRowID
    var item: CloudDriveItem
    var depth: Int { id.path.count - 1 }
}

/// Loads only disclosed folders. The flattened snapshot changes when the tree
/// changes, never during row rendering or scrolling. Metadata requests and
/// sibling sorting run asynchronously; media is not downloaded to expand.
@MainActor final class NativeDriveTree {
    struct Branch {
        var items: [CloudDriveItem] = []
        var loaded = false
        var nextOffset: Int?
        var error: String?
        var request: UUID?
        var revision = UUID()
        var isLoading: Bool { request != nil }
    }
    private struct Load {
        let item: CloudDriveItem
        let offset: Int
        let id: UUID
    }

    private(set) var roots: [CloudDriveItem] = []
    private(set) var rootRows: [NativeDriveRow] = []
    private(set) var rows: [NativeDriveRow] = []
    private(set) var rowByID: [NativeDriveRowID: NativeDriveRow] = [:]
    private(set) var expanded: Set<NativeDriveRowID> = []
    private(set) var search = ""
    var onChange: (() -> Void)?
    var isLoading: Bool { branches.values.contains(where: \.isLoading) }
    private var branches: [String: Branch] = [:]
    private var provider: (any NativeCloudDrive)?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var queue: [Load] = []
    private var generation = UUID()
    private var sortMode = 0
    private var direction = BrowserSortDirection.ascending
    private var sortRevision = UUID()

    func branch(for item: CloudDriveItem) -> Branch { branches[item.id] ?? Branch() }

    func reset(provider: (any NativeCloudDrive)?, search: String = "") {
        cancelRequests()
        self.provider = provider; self.search = search
        roots = []; branches = [:]; expanded = []
        rebuild()
    }

    func replaceRoots(_ items: [CloudDriveItem], refreshChildren: Bool = false) {
        roots = items
        if refreshChildren {
            cancelRequests()
            // Keep the previous rows and selection visible during refresh.
            // The new listing then removes stale children, including after Undo.
            for key in Array(branches.keys) {
                branches[key]?.loaded = false
                branches[key]?.error = nil
                branches[key]?.nextOffset = nil
            }
        }
        rebuild()
    }

    func toggle(_ row: NativeDriveRow) {
        guard row.item.isFolder, rowByID[row.id] != nil else { return }
        if !expanded.insert(row.id).inserted { expanded.remove(row.id) }
        rebuild()
    }

    func loadMore(_ row: NativeDriveRow) {
        guard expanded.contains(row.id), let branch = branches[row.item.id],
              !branch.isLoading, let offset = branch.nextOffset else { return }
        enqueue(row.item, offset: offset); rebuild()
    }

    func retry(_ row: NativeDriveRow) {
        guard rowByID[row.id] != nil, !branch(for: row.item).isLoading else { return }
        expanded.insert(row.id)
        let offset = branch(for: row.item).loaded ? branch(for: row.item).nextOffset ?? 0 : 0
        enqueue(row.item, offset: offset); rebuild()
    }

    func updateSize(_ bytes: UInt64, for itemID: String) {
        for key in Array(branches.keys) {
            if let index = branches[key]?.items.firstIndex(where: { $0.id == itemID }) {
                branches[key]?.items[index].bytes = bytes
                branches[key]?.revision = UUID()
            }
        }
        rebuild()
    }

    func setSort(mode: Int, direction: BrowserSortDirection) {
        guard mode != sortMode || direction != self.direction else { return }
        sortMode = mode; self.direction = direction; sortRevision = UUID()
        let revision = sortRevision, snapshots = branches
        Task { [weak self] in
            let sorted = await Task.detached(priority: .userInitiated) {
                snapshots.mapValues { Self.sorted($0.items, by: mode, direction: direction) }
            }.value
            guard let self, self.sortRevision == revision else { return }
            for (key, items) in sorted where self.branches[key]?.revision == snapshots[key]?.revision {
                self.branches[key]?.items = items
            }
            self.rebuild()
        }
    }

    private func cancelRequests() {
        generation = UUID()
        tasks.values.forEach { $0.cancel() }; tasks = [:]; queue = []
        for key in Array(branches.keys) { branches[key]?.request = nil }
    }

    private func enqueue(_ item: CloudDriveItem, offset: Int = 0) {
        guard provider != nil, !branch(for: item).isLoading else { return }
        let id = UUID()
        var branch = branch(for: item)
        branch.request = id; branch.error = nil; branches[item.id] = branch
        queue.append(.init(item: item, offset: offset, id: id))
    }

    private func rebuild() {
        rootRows = roots.map { .init(id: .init(path: [$0.id]), item: $0) }
        var stack = Array(rootRows.reversed()), visible: [NativeDriveRow] = []
        while let row = stack.popLast() {
            visible.append(row)
            guard row.item.isFolder, expanded.contains(row.id),
                  !row.id.path.dropLast().contains(row.item.id) else { continue }
            let branch = branch(for: row.item)
            if !branch.loaded && !branch.isLoading && branch.error == nil { enqueue(row.item) }
            for child in branch.items.reversed() {
                stack.append(.init(id: .init(path: row.id.path + [child.id]), item: child))
            }
        }
        rows = visible; rowByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let wanted = Set(rows.filter { $0.item.isFolder && expanded.contains($0.id) }.map { $0.item.id })
        for key in Array(branches.keys) where !wanted.contains(key) {
            tasks.removeValue(forKey: key)?.cancel(); branches[key]?.request = nil
        }
        queue.removeAll { !wanted.contains($0.item.id) }
        startRequests()
        onChange?()
    }

    private func startRequests() {
        guard let provider else { return }
        while tasks.count < 4 && !queue.isEmpty {
            let load = queue.removeFirst(), generation = generation
            tasks[load.item.id] = Task { [weak self] in
                do {
                    let page = try await AutomaticRecovery.read {
                        try await provider.list(load.item.location, offset: load.offset, search: "")
                    }
                    try Task.checkCancellation()
                    guard let self, self.generation == generation, self.branches[load.item.id]?.request == load.id else { return }
                    var seen = Set<String>()
                    let existing = load.offset == 0 ? [] : self.branch(for: load.item).items
                    let merged = (existing + page.items).filter { seen.insert($0.id).inserted }
                    // A sort change during I/O must also apply to the arriving page.
                    while true {
                        let revision = self.sortRevision, mode = self.sortMode, direction = self.direction
                        let sorted = await Task.detached(priority: .userInitiated) { Self.sorted(merged, by: mode, direction: direction) }.value
                        try Task.checkCancellation()
                        guard self.generation == generation, self.branches[load.item.id]?.request == load.id else { return }
                        if self.sortRevision != revision { continue }
                        self.branches[load.item.id] = Branch(items: sorted, loaded: true, nextOffset: page.nextOffset)
                        self.tasks[load.item.id] = nil; self.rebuild()
                        break
                    }
                } catch {
                    guard let self, self.generation == generation, self.branches[load.item.id]?.request == load.id else { return }
                    self.branches[load.item.id]?.request = nil
                    self.branches[load.item.id]?.error = error.localizedDescription
                    self.tasks[load.item.id] = nil; self.rebuild()
                }
            }
        }
    }

    nonisolated static func sorted(_ items: [CloudDriveItem], by mode: Int, direction: BrowserSortDirection) -> [CloudDriveItem] {
        let kinds = mode == 3 ? Dictionary(items.map { ($0.id, $0.kindLabel) }, uniquingKeysWith: { a, _ in a }) : [:]
        return items.sorted {
            if $0.isFolder != $1.isFolder { return $0.isFolder }
            var comparison = ComparisonResult.orderedSame
            if mode == 1 {
                let a = $0.modified ?? .distantPast, b = $1.modified ?? .distantPast
                if a != b { comparison = a < b ? .orderedAscending : .orderedDescending }
            } else if mode == 2 {
                let a = $0.bytes ?? 0, b = $1.bytes ?? 0
                if a != b { comparison = a < b ? .orderedAscending : .orderedDescending }
            } else if mode == 3 { comparison = (kinds[$0.id] ?? "").localizedStandardCompare(kinds[$1.id] ?? "") }
            if comparison == .orderedSame { comparison = $0.name.localizedStandardCompare($1.name) }
            if comparison == .orderedSame && $0.id != $1.id { comparison = $0.id < $1.id ? .orderedAscending : .orderedDescending }
            return comparison == (direction == .ascending ? .orderedAscending : .orderedDescending)
        }
    }
}

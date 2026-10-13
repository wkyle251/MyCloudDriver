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
    private static let stoppedExpansionError = "Expansion stopped. Retry this folder to continue."
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
    /// Folders whose every level is being opened, in selection order. No root is nested under another.
    private(set) var expandingAllRoots: [NativeDriveRowID] = []
    private(set) var search = ""
    var onChange: (() -> Void)?
    var isLoading: Bool { !expandingAllRoots.isEmpty || deferredPublication != nil || branches.values.contains(where: \.isLoading) }
    private var branches: [String: Branch] = [:]
    private var measuredSizes: [String: UInt64] = [:]
    private var provider: (any NativeCloudDrive)?
    private var tasks: [String: Task<Void, Never>] = [:]
    private var queue: [Load] = []
    private var queueOffset = 0
    private var recursiveVisited = Set<NativeDriveRowID>()
    private var recursivePublication: Task<Void, Never>?
    /// Outside Expand All, the first reply is published at once and the replies that follow within this
    /// interval share one rebuild, so a burst of folders does not rebuild every row once per reply.
    private static let publicationInterval: TimeInterval = 0.05
    private var lastPublication = Date.distantPast
    private var deferredPublication: Task<Void, Never>?
    private var generation = UUID()
    private var sortMode = 0
    private var direction = BrowserSortDirection.ascending
    private var sortRevision = UUID()

    func branch(for item: CloudDriveItem) -> Branch { branches[item.id] ?? Branch() }

    /// A folder's complete listing, or nil while it is not fully known: never opened, loading, failed or paged.
    /// Cached listings of collapsed folders count, and nothing is fetched to answer.
    func knownChildren(ofFolderID id: String) -> [CloudDriveItem]? {
        guard let branch = branches[id], branch.loaded, branch.error == nil, !branch.isLoading, branch.nextOffset == nil else { return nil }
        return branch.items
    }

    func reset(provider: (any NativeCloudDrive)?, search: String = "") {
        cancelRequests()
        self.provider = provider; self.search = search
        roots = []; branches = [:]; expanded = []; measuredSizes = [:]
        rebuild()
    }

    func replaceRoots(_ items: [CloudDriveItem], refreshChildren: Bool = false) {
        roots = items
        if refreshChildren {
            cancelRequests()
            measuredSizes = [:]
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
        if !expanded.contains(row.id), branches[row.item.id]?.loaded != true,
           branches[row.item.id]?.error == Self.stoppedExpansionError {
            branches[row.item.id]?.error = nil
        }
        if expanded.contains(row.id) {
            // Closing a folder inside, or above, an expanding root stops that root alone.
            cancelExpandAll(roots: expandingAllRoots.filter {
                row.id.path.starts(with: $0.path) || $0.path.starts(with: row.id.path)
            }, publish: false)
        }
        if !expanded.insert(row.id).inserted { expanded.remove(row.id) }
        rebuild()
    }

    func expandAllLevels(_ row: NativeDriveRow) { expandAllLevels([row]) }

    /// Opens every level under each folder as one pass sharing the request lanes. A folder listed twice,
    /// or nested under another selected folder, is covered by that folder's own expansion.
    func expandAllLevels(_ rows: [NativeDriveRow]) {
        var seen = Set<NativeDriveRowID>()
        let folders = rows.filter { $0.item.isFolder && rowByID[$0.id] != nil && seen.insert($0.id).inserted }
        let roots = folders.filter { folder in
            !(1..<max(1, folder.id.path.count)).contains { seen.contains(.init(path: Array(folder.id.path.prefix($0)))) }
        }
        guard !roots.isEmpty, provider != nil else { return }
        if !expandingAllRoots.isEmpty { cancelExpandAll(publish: false) }
        expandingAllRoots = roots.map(\.id)
        recursiveVisited = []
        rebuild()
    }

    func isExpandingAll(_ id: NativeDriveRowID) -> Bool {
        expandingAllRoots.contains { id.path.starts(with: $0.path) }
    }

    /// Stop discovery while retaining already disclosed metadata. An unloaded
    /// cancelled branch needs an explicit retry, rather than immediately
    /// restarting its request during the next normal tree rebuild.
    func cancelExpandAll(publish: Bool = true) { cancelExpandAll(roots: expandingAllRoots, publish: publish) }

    /// Stops the given roots and leaves any other root expanding.
    private func cancelExpandAll(roots cancelled: [NativeDriveRowID], publish: Bool) {
        guard !cancelled.isEmpty, !expandingAllRoots.isEmpty else { return }
        let covered = { (id: NativeDriveRowID) in cancelled.contains { id.path.starts(with: $0.path) } }
        expandingAllRoots.removeAll { cancelled.contains($0) }
        if expandingAllRoots.isEmpty {
            recursiveVisited = []
            recursivePublication?.cancel(); recursivePublication = nil
        } else {
            recursiveVisited = recursiveVisited.filter { !covered($0) }
        }
        let owned = Set(rows.filter { $0.item.isFolder && covered($0.id) }.map { $0.item.id })
        for key in owned where branches[key]?.isLoading == true {
            tasks.removeValue(forKey: key)?.cancel()
            branches[key]?.request = nil
            if branches[key]?.loaded != true { branches[key]?.error = Self.stoppedExpansionError }
        }
        queue = Array(queue.dropFirst(queueOffset)).filter { !owned.contains($0.item.id) }; queueOffset = 0
        if publish { rebuild() }
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

    /// Sizes measured for folders, applied to the rows already loaded and kept for
    /// folders listed later. A refresh or reset discards them with the listing they describe.
    func updateSizes(_ sizes: [String: UInt64]) {
        guard !sizes.isEmpty else { return }
        measuredSizes.merge(sizes) { _, new in new }
        for key in Array(branches.keys) {
            guard let items = branches[key]?.items else { continue }
            var changed = false
            for index in items.indices {
                if let bytes = sizes[items[index].id], items[index].bytes != bytes {
                    branches[key]?.items[index].bytes = bytes; changed = true
                }
            }
            if changed { branches[key]?.revision = UUID() }
        }
        rebuild()
    }
    private func sized(_ item: CloudDriveItem) -> CloudDriveItem {
        guard item.isFolder, item.bytes == nil, let bytes = measuredSizes[item.id] else { return item }
        var item = item; item.bytes = bytes
        return item
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
        deferredPublication?.cancel(); deferredPublication = nil
        recursivePublication?.cancel(); recursivePublication = nil
        expandingAllRoots = []; recursiveVisited = []
        tasks.values.forEach { $0.cancel() }; tasks = [:]; queue = []; queueOffset = 0
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
        // Whatever was waiting to be published is included in this rebuild.
        deferredPublication?.cancel(); deferredPublication = nil
        rootRows = roots.map { .init(id: .init(path: [$0.id]), item: $0) }
        // Rows under an expanding root inherit its flag down the walk, so a selection of many folders
        // costs one set lookup per row instead of a path comparison against every root.
        let expandingRoots = Set(expandingAllRoots)
        var stack = rootRows.reversed().map { (row: $0, recursive: false) }, visible: [NativeDriveRow] = []
        var pending = false
        while let (row, inherited) = stack.popLast() {
            visible.append(row)
            let recursive = inherited || expandingRoots.contains(row.id)
            let cycle = row.id.path.dropLast().contains(row.item.id)
            if recursive, row.item.isFolder, !cycle {
                expanded.insert(row.id)
                if recursiveVisited.insert(row.id).inserted { branches[row.item.id]?.error = nil }
            }
            guard row.item.isFolder, expanded.contains(row.id),
                  !cycle else { continue }
            let branch = branch(for: row.item)
            if recursive, branch.error == nil, !branch.loaded || branch.isLoading || branch.nextOffset != nil { pending = true }
            if !branch.loaded && !branch.isLoading && branch.error == nil { enqueue(row.item) }
            else if recursive, !branch.isLoading, branch.error == nil, let offset = branch.nextOffset {
                enqueue(row.item, offset: offset)
            }
            for child in branch.items.reversed() {
                stack.append((.init(id: .init(path: row.id.path + [child.id]), item: child), recursive))
            }
        }
        rows = visible; rowByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let wanted = Set(rows.filter { $0.item.isFolder && expanded.contains($0.id) }.map { $0.item.id })
        for key in Array(branches.keys) where !wanted.contains(key) {
            tasks.removeValue(forKey: key)?.cancel(); branches[key]?.request = nil
        }
        queue = Array(queue.dropFirst(queueOffset)).filter { wanted.contains($0.item.id) }; queueOffset = 0
        if !expandingAllRoots.isEmpty, !pending { expandingAllRoots = []; recursiveVisited = [] }
        startRequests()
        onChange?()
    }

    private func publishLoadedBranches() {
        guard !expandingAllRoots.isEmpty else {
            let remaining = Self.publicationInterval - Date().timeIntervalSince(lastPublication)
            guard remaining > 0 else { lastPublication = Date(); rebuild(); return }
            startRequests()
            guard deferredPublication == nil else { return }
            let generation = generation
            deferredPublication = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) } catch { return }
                guard let self, self.generation == generation, !Task.isCancelled else { return }
                self.deferredPublication = nil
                self.lastPublication = Date()
                self.rebuild()
            }
            return
        }
        // Keep the I/O slots full, while merging many arriving folders into
        // one tree/selection/SwiftUI publication instead of rebuilding per node.
        startRequests()
        guard recursivePublication == nil else { return }
        let generation = generation
        recursivePublication = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
            guard let self, self.generation == generation, !Task.isCancelled else { return }
            self.recursivePublication = nil
            self.rebuild()
        }
    }

    private func startRequests() {
        guard let provider else { return }
        while tasks.count < 4 && queueOffset < queue.count {
            let load = queue[queueOffset], generation = generation
            queueOffset += 1
            tasks[load.item.id] = Task { [weak self] in
                do {
                    let page = try await AutomaticRecovery.read {
                        try await provider.list(load.item.location, offset: load.offset, search: "")
                    }
                    try Task.checkCancellation()
                    guard let self, self.generation == generation, self.branches[load.item.id]?.request == load.id else { return }
                    if let next = page.nextOffset, next <= load.offset {
                        throw CloudDriveError.message("This folder's next page did not advance. Retry the folder to continue.")
                    }
                    var seen = Set<String>()
                    let existing = load.offset == 0 ? [] : self.branch(for: load.item).items
                    let merged = (existing + page.items).filter { seen.insert($0.id).inserted }.map { self.sized($0) }
                    // A sort change during I/O must also apply to the arriving page.
                    while true {
                        let revision = self.sortRevision, mode = self.sortMode, direction = self.direction
                        let sorted = await Task.detached(priority: .userInitiated) { Self.sorted(merged, by: mode, direction: direction) }.value
                        try Task.checkCancellation()
                        guard self.generation == generation, self.branches[load.item.id]?.request == load.id else { return }
                        if self.sortRevision != revision { continue }
                        self.branches[load.item.id] = Branch(items: sorted, loaded: true, nextOffset: page.nextOffset)
                        self.tasks[load.item.id] = nil; self.publishLoadedBranches()
                        break
                    }
                } catch {
                    guard let self, self.generation == generation, self.branches[load.item.id]?.request == load.id else { return }
                    self.branches[load.item.id]?.request = nil
                    self.branches[load.item.id]?.error = error.localizedDescription
                    self.tasks[load.item.id] = nil; self.publishLoadedBranches()
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

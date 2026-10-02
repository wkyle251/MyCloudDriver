import Foundation

struct FolderMeasurement: Codable, Equatable {
    let totalBytes: UInt64
    let fileCount: UInt64
    let folderCount: UInt64

    static let zero = Self(totalBytes: 0, fileCount: 0, folderCount: 0)

    /// Never wrap or clamp corrupt/stale totals into a plausible cached size.
    func replacing(_ old: Self, with new: Self) -> Self? {
        func replace(_ value: UInt64, _ before: UInt64, _ after: UInt64) -> UInt64? {
            guard value >= before else { return nil }
            let (result, overflow) = (value - before).addingReportingOverflow(after)
            return overflow ? nil : result
        }
        guard let bytes = replace(totalBytes, old.totalBytes, new.totalBytes),
              let files = replace(fileCount, old.fileCount, new.fileCount),
              let folders = replace(folderCount, old.folderCount, new.folderCount) else { return nil }
        return Self(totalBytes: bytes, fileCount: files, folderCount: folders)
    }
}

/// Only opaque IDs and sizes are persisted; no names, URLs, or credentials.
struct FolderSizeEntry: Codable, Equatable {
    let id: String
    let size: UInt64
    let isFolder: Bool
}

/// Account-local, value-type index. Shared-link measurements remain separately
/// namespaced by the model and can never be changed by account mutations.
struct FolderSizeIndex: Codable, Equatable {
    var measurements: [String: FolderMeasurement] = [:]
    var parents: [String: String] = [:]
    var listings: [String: [String: FolderSizeEntry]] = [:]
    var dirty: Set<String> = []

    var usableMeasurements: [String: FolderMeasurement] {
        measurements.filter { !dirty.contains($0.key) }
    }

    /// Clean measurements a scan of `rootID` can reuse: only its known
    /// descendants, so a seed stays small however much of the account is cached.
    func seedMeasurements(under rootID: String) -> [String: FolderMeasurement] {
        var isDescendant = [rootID: true]
        func reachesRoot(_ id: String) -> Bool {
            var path: [String] = []
            var next: String? = id
            var result = false
            while let current = next {
                if let known = isDescendant[current] { result = known; break }
                // A malformed parent cycle can never reach the root.
                if path.contains(current) { break }
                path.append(current)
                next = parents[current]
            }
            for visited in path { isDescendant[visited] = result }
            return result
        }
        return measurements.filter { id, _ in
            id != rootID && !dirty.contains(id) && reachesRoot(id)
        }
    }

    func ancestors(of folderID: String) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        var next: String? = folderID
        while let id = next, seen.insert(id).inserted {
            result.append(id)
            next = parents[id]
        }
        return result
    }

    /// Repair the highest previously measured ancestor. The engine will only
    /// list dirty branches; all unaffected measured children are reused.
    func repairRoot(for folderID: String) -> String? {
        ancestors(of: folderID).last { measurements[$0] != nil }
    }

    mutating func markChanged(_ folderID: String) {
        dirty.formUnion(ancestors(of: folderID))
    }

    func entry(_ id: String) -> FolderSizeEntry? {
        guard let parent = parents[id] else { return nil }
        return listings[parent]?[id]
    }

    func contribution(_ entry: FolderSizeEntry) -> FolderMeasurement? {
        if !entry.isFolder {
            return FolderMeasurement(totalBytes: entry.size, fileCount: 1, folderCount: 0)
        }
        guard !dirty.contains(entry.id), let size = measurements[entry.id] else { return nil }
        return size.replacing(.zero, with: FolderMeasurement(totalBytes: 0, fileCount: 0, folderCount: 1))
    }

    private mutating func adjustAncestors(
        from parent: String, removing old: FolderMeasurement, adding new: FolderMeasurement
    ) {
        for id in ancestors(of: parent) {
            guard !dirty.contains(id), let value = measurements[id] else { continue }
            if let adjusted = value.replacing(old, with: new) {
                measurements[id] = adjusted
            } else {
                markChanged(id)
            }
        }
    }

    /// Only confirmed API removals call this. Roots are de-overlapped before
    /// any subtraction so selecting a folder and its descendants counts once.
    mutating func remove(_ ids: Set<String>) {
        let childrenByParent = Dictionary(grouping: parents.keys, by: { parents[$0]! })
        let roots = ids.filter { id in
            guard let parent = parents[id] else { return true }
            return !ancestors(of: parent).contains(where: ids.contains)
        }
        for id in roots {
            if let parent = parents[id] {
                let old = entry(id)
                if let old, let amount = contribution(old) {
                    adjustAncestors(from: parent, removing: amount, adding: .zero)
                } else if old != nil || listings[parent] == nil {
                    // An aggregate-only legacy cache cannot prove this item
                    // was included. Refresh this branch instead of subtracting
                    // an unverified size. An indexed non-member contributes 0.
                    markChanged(parent)
                }
                listings[parent]?.removeValue(forKey: id)
            }
            var pending = [id]
            var removed = Set<String>()
            while let next = pending.popLast() {
                guard removed.insert(next).inserted else { continue }
                pending.append(contentsOf: listings[next]?.keys.map { $0 } ?? [])
                // Legacy caches may know parents without complete listings.
                pending.append(contentsOf: childrenByParent[next] ?? [])
                listings.removeValue(forKey: next)
                measurements.removeValue(forKey: next)
                dirty.remove(next)
                parents.removeValue(forKey: next)
            }
        }
    }

    mutating func insertEmptyFolder(id: String, parent: String) {
        // Idempotent for a replayed response / resumed operation.
        guard entry(id) == nil, measurements[id] == nil else { return }
        let item = FolderSizeEntry(id: id, size: 0, isFolder: true)
        parents[id] = parent
        measurements[id] = .zero
        listings[id] = [:]
        dirty.remove(id)
        listings[parent]?[id] = item
        adjustAncestors(from: parent, removing: .zero,
                        adding: FolderMeasurement(totalBytes: 0, fileCount: 0, folderCount: 1))
    }

    mutating func move(_ entries: [FolderSizeEntry], to destination: String) {
        let ids = Set(entries.map(\.id))
        let roots = entries.filter { item in
            guard let parent = parents[item.id] else { return true }
            return !ancestors(of: parent).contains(where: ids.contains)
        }
        for item in roots {
            guard parents[item.id] != destination else { continue }
            let oldParent = parents[item.id]
            if let indexed = entry(item.id), let amount = contribution(indexed) {
                if let oldParent { adjustAncestors(from: oldParent, removing: amount, adding: .zero) }
                adjustAncestors(from: destination, removing: .zero, adding: amount)
            } else {
                if let oldParent { markChanged(oldParent) }
                markChanged(destination)
            }
            if let oldParent { listings[oldParent]?.removeValue(forKey: item.id) }
            parents[item.id] = destination
            listings[destination]?[item.id] = item
        }
    }

    /// Only use a complete, successfully fetched listing (never a single page).
    /// Refreshes can detect changes made outside this app without a full scan.
    @discardableResult
    mutating func reconcile(folderID: String, entries: [FolderSizeEntry]) -> Bool {
        let entries = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        guard listings[folderID] != entries else { return false }
        let previous = measurements[folderID]
        let wasDirty = dirty.contains(folderID)
        let oldIDs = Set(listings[folderID]?.keys.map { $0 } ?? [])
        listings[folderID] = entries
        for id in oldIDs.subtracting(entries.keys) where parents[id] == folderID {
            parents.removeValue(forKey: id)
        }
        for entry in entries.values { parents[entry.id] = folderID }
        var total = FolderMeasurement.zero
        for entry in entries.values {
            guard let amount = contribution(entry), let next = total.replacing(.zero, with: amount) else {
                markChanged(folderID)
                return true
            }
            total = next
        }
        measurements[folderID] = total
        dirty.remove(folderID)
        if let parent = parents[folderID] {
            if let previous, !wasDirty {
                adjustAncestors(from: parent, removing: previous, adding: total)
            } else {
                rebuildAncestors(from: parent)
            }
        }
        return true
    }

    /// Every scanned entry's parent comes from `scannedListings`, which hold
    /// the complete direct contents of each folder the scan listed.
    mutating func applyScan(
        rootID: String, folders: [String: FolderMeasurement],
        scannedListings: [String: [FolderSizeEntry]]
    ) {
        let previous = measurements[rootID]
        let wasDirty = dirty.contains(rootID)
        measurements.merge(folders) { _, new in new }
        dirty.subtract(folders.keys)
        for (folder, items) in scannedListings {
            let new = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
            for id in listings[folder]?.keys.map({ $0 }) ?? []
                where new[id] == nil && parents[id] == folder {
                parents.removeValue(forKey: id)
            }
            listings[folder] = new
            for item in items { parents[item.id] = folder }
        }
        if let parent = parents[rootID] {
            if let previous, let next = folders[rootID], !wasDirty {
                adjustAncestors(from: parent, removing: previous, adding: next)
            } else {
                rebuildAncestors(from: parent)
            }
        }
    }

    private mutating func rebuildAncestors(from parent: String) {
        for id in ancestors(of: parent) {
            guard let entries = listings[id] else { markChanged(id); continue }
            var total: FolderMeasurement? = .zero
            for item in entries.values {
                guard let amount = contribution(item) else { total = nil; break }
                total = total?.replacing(.zero, with: amount)
            }
            if let total {
                measurements[id] = total
                dirty.remove(id)
            } else { markChanged(id) }
        }
    }
}

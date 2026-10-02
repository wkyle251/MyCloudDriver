import Foundation

/// Which completed files may be uploaded, and which uploaded files may leave RAM.
///
/// Removal is the delicate half. A torrent's files are laid end to end, so one
/// piece often carries bytes for several files — in the torrents this feature
/// exists for, the median file is smaller than a single piece. aria2 writes a
/// piece to every file it overlaps, so deleting a file whose covering pieces
/// are still wanted by an incomplete neighbour merely recreates the file and
/// downloads it a second time. Only files whose every covering piece is fully
/// accounted for may go.
enum TorrentRelayDrain {
    /// Byte layout of the torrent, over every file it contains — selected or
    /// not, because unselected neighbours still share boundary pieces.
    struct Layout {
        let files: [LocalTorrentFile]
        let pieceLength: UInt64
        private let starts: [UInt64]
        private let ends: [UInt64]
        private let position: [Int: Int]

        init(files: [LocalTorrentFile], pieceLength: UInt64) {
            let ordered = files.sorted { $0.index < $1.index }
            var starts: [UInt64] = [], ends: [UInt64] = [], next: UInt64 = 0
            starts.reserveCapacity(ordered.count); ends.reserveCapacity(ordered.count)
            for file in ordered {
                starts.append(next)
                next = next.addingReportingOverflow(file.length).partialValue
                ends.append(next)
            }
            self.files = ordered
            self.starts = starts
            self.ends = ends
            self.pieceLength = max(1, pieceLength)
            self.position = Dictionary(ordered.enumerated().map { ($0.element.index, $0.offset) },
                                       uniquingKeysWith: { first, _ in first })
        }

        func slot(of index: Int) -> Int? { position[index] }

        /// The byte range of every piece carrying any of this file's bytes.
        /// A zero-length file occupies no piece and returns an empty range.
        func pieceBytes(_ slot: Int) -> Range<UInt64> {
            let start = starts[slot], end = ends[slot]
            guard end > start else { return start..<start }
            let first = start / pieceLength * pieceLength
            let last = ((end - 1) / pieceLength + 1) * pieceLength
            return first..<last
        }

        /// Slots of the files holding bytes inside `range`. Contiguous, because
        /// torrent files are concatenated, so this is two binary searches.
        func touching(_ range: Range<UInt64>) -> Range<Int> {
            guard !range.isEmpty else { return 0..<0 }
            var low = 0, high = files.count
            while low < high {
                let mid = (low + high) / 2
                if ends[mid] <= range.lowerBound { low = mid + 1 } else { high = mid }
            }
            let first = low
            low = 0; high = files.count
            while low < high {
                let mid = (low + high) / 2
                if starts[mid] < range.upperBound { low = mid + 1 } else { high = mid }
            }
            return first..<Swift.max(first, low)
        }
    }

    /// Files that may be deselected and unlinked, in index order.
    ///
    /// - `complete`: aria2 reports `completedLength == length`
    /// - `committed`: the relay helper wrote a cloud receipt
    /// - `removed`: already unlinked, so no further write is expected
    static func removable(layout: Layout, complete: Set<Int>, committed: Set<Int>, removed: Set<Int>,
                          active: Set<Int>? = nil) -> [Int] {
        var result: [Int] = []
        for (slot, file) in layout.files.enumerated() {
            guard committed.contains(file.index), !removed.contains(file.index),
                  complete.contains(file.index) else { continue }
            let span = layout.pieceBytes(slot)
            if span.isEmpty { result.append(file.index); continue }
            var safe = true
            for other in layout.touching(span) where other != slot {
                let index = layout.files[other].index
                // An unadmitted neighbour must not pin the frontier forever.
                // Its shared boundary can be fetched again when it is admitted.
                if !complete.contains(index) && !removed.contains(index) && (active?.contains(index) ?? true) {
                    safe = false; break
                }
            }
            if safe { result.append(file.index) }
        }
        return result
    }

    static let flushFileLimit = 32
    static let flushByteLimit: UInt64 = 256 * 1024 * 1024
    static let flushWait: TimeInterval = 180
    /// How full the RAM volume may get before a queued file stops waiting for
    /// company. Bytes already saved to PikPak are the cheapest space a transfer
    /// can reclaim, and holding them for the three-minute timer while the
    /// buffer fills starves the download of somewhere to put the next piece.
    static let flushPressure = 0.75

    /// Reserve whole files, including the unwritten part of every active file.
    /// Real free space alone would over-admit sparse, partly downloaded files.
    struct Admission {
        let selection: [Int]
        let blockedOnSpace: Bool
        var reservedBytes: UInt64 = 0
    }

    static let storageGB: UInt64 = 1_000_000_000
    static func storageLimit(capacity: UInt64, configured: UInt64?) -> UInt64 {
        if let configured { return min(capacity, configured) }
        return capacity - min(capacity, 100 * storageGB)
    }

    /// Sharing never competes with space already promised to incomplete files
    /// or the next file waiting for admission. Arithmetic saturates for large
    /// manifests rather than allowing an overflow to erase the reservation.
    static func storageReleaseTarget(available: UInt64, used: UInt64, limit: UInt64, reserved: UInt64,
                                     nextFile: UInt64?, pieceLength: UInt64) -> UInt64 {
        var needed: UInt64 = 0
        let piece = max(16_384, pieceLength == 0 ? 16 * 1024 * 1024 : pieceLength)
        let costs: [UInt64] = [reserved, 16 * 1024 * 1024] + (nextFile.map { [$0, piece, piece, 4096] } ?? [])
        for bytes in costs {
            let sum = needed.addingReportingOverflow(bytes)
            needed = sum.overflow ? .max : sum.partialValue
        }
        let headroom = min(available, limit - min(limit, used))
        let excess = used - min(used, limit)
        let sum = excess.addingReportingOverflow(needed - min(needed, headroom))
        return sum.overflow ? .max : sum.partialValue
    }

    /// Shrinking the limit stops starting more files. Preserve all partial
    /// data, concentrating on the nearest-to-complete file so it can upload
    /// and release space. A partial file can temporarily exceed the new limit.
    static func admitStorage(files: [LocalTorrentFile], wanted: Set<Int>, uploaded: Set<Int>, active: Set<Int>,
                             progress: [Int: UInt64], available: UInt64, used: UInt64, limit: UInt64,
                             pieceLength: UInt64, starting: Bool) -> Admission {
        let headroom = min(available, limit - min(limit, used))
        let normal = admit(files: files, wanted: wanted, uploaded: uploaded, active: active,
            progress: progress, available: headroom, budget: nil, pieceLength: pieceLength)
        // At startup the old selection must load its checkpoint before we can
        // distinguish partial files from whole ones. The first census resizes.
        guard !starting, normal.reservedBytes > headroom || used > limit else { return normal }
        let unfinished = files.filter { wanted.contains($0.index) && !uploaded.contains($0.index) &&
            (progress[$0.index] ?? 0) < $0.length }
        let partial = unfinished.filter { (progress[$0.index] ?? 0) > 0 }
        let nearest = (partial.isEmpty ? unfinished.filter { active.contains($0.index) } : partial).min {
            let left = $0.length - min($0.length, progress[$0.index] ?? 0)
            let right = $1.length - min($1.length, progress[$1.index] ?? 0)
            return left == right ? $0.index < $1.index : left < right
        }
        // Completed unuploaded files remain eligible for immediate draining.
        var selection = Set(files.filter { active.contains($0.index) &&
            (uploaded.contains($0.index) || (progress[$0.index] ?? 0) >= $0.length) }.map(\.index))
        if let nearest, !partial.isEmpty || (selection.isEmpty && used < limit) { selection.insert(nearest.index) }
        // Never send an empty select-file filter (aria2 interprets it as all).
        if selection.isEmpty { selection = active }
        let narrowed = admit(files: files, wanted: selection, uploaded: uploaded, active: selection,
            progress: progress, available: 0, budget: nil, pieceLength: pieceLength)
        return .init(selection: narrowed.selection, blockedOnSpace: true, reservedBytes: narrowed.reservedBytes)
    }

    /// Reopening an aria2 selection disconnects its peers. Keep useful work
    /// running while the buffer has headroom; advance before work runs out,
    /// when a meaningful amount can be reclaimed, or under space pressure.
    /// Storage uses measured free space plus allocated payload as capacity.
    /// Its live file cleanup is independent of this window-growth policy.
    static func shouldAdvanceWindow(hasPendingFiles: Bool, remainingBytes: UInt64,
                                    reclaimableBytes: UInt64, used: UInt64, capacity: UInt64) -> Bool {
        guard capacity > 0 else { return true }
        if remainingBytes == 0 || used >= capacity / 4 * 3 { return true }
        guard hasPendingFiles else { return false }
        return remainingBytes <= capacity / 4 || reclaimableBytes >= capacity / 8
    }

    static func admit(files: [LocalTorrentFile], wanted: Set<Int>, uploaded: Set<Int>, active: Set<Int>,
                      progress: [Int: UInt64], available: UInt64, budget: UInt64?, pieceLength: UInt64) -> Admission {
        let ordered = files.sorted { $0.index < $1.index }
        let piece = max(16_384, pieceLength == 0 ? 16 * 1024 * 1024 : pieceLength)
        // Known virtual padding does not separate two payload runs or require
        // another two real boundary pieces of disk space. Unknown index gaps
        // and unselected ordinary files still do.
        var predecessor: [Int: Int] = [:], successor: [Int: Int] = [:]
        var previousIndex: Int?, previousPayload: Int?
        for file in ordered {
            if let previousIndex, file.index - 1 != previousIndex { previousPayload = nil }
            if !file.isPadding {
                if let previousPayload { predecessor[file.index] = previousPayload; successor[previousPayload] = file.index }
                previousPayload = file.index
            }
            previousIndex = file.index
        }
        // Storage has no fixed buffer ceiling. Both modes still reserve every
        // unfinished byte, boundary pieces and metadata against real free space.
        let capacity = budget.map { $0 / 100 * 85 } ?? UInt64.max
        let safety: UInt64 = 16 * 1024 * 1024
        let free = available > safety ? available - safety : 0
        var selection = active.intersection(wanted)
        func reservation(_ indexes: Set<Int>) -> (full: UInt64, remaining: UInt64) {
            var full: UInt64 = 0, remaining: UInt64 = 0, previous: Int?
            for file in ordered where indexes.contains(file.index) {
                let adjacent = previous.map { predecessor[file.index] == $0 } ?? false
                let overhead: UInt64 = 4096 + (adjacent ? 0 : piece * 2)
                let size = file.length.addingReportingOverflow(overhead)
                guard !size.overflow, full <= UInt64.max - size.partialValue else { return (.max, .max) }
                full += size.partialValue
                remaining += size.partialValue - (uploaded.contains(file.index) ? file.length : min(file.length, progress[file.index] ?? 0))
                previous = file.index
            }
            return (full, remaining)
        }
        var cost = reservation(selection), blocked = false
        for file in ordered where wanted.contains(file.index) && !uploaded.contains(file.index) && !selection.contains(file.index) {
            let base = file.length.addingReportingOverflow(4096)
            guard !base.overflow, cost.full <= UInt64.max - base.partialValue else { blocked = true; break }
            var full = cost.full + base.partialValue
            var remaining = cost.remaining + base.partialValue - min(file.length, progress[file.index] ?? 0)
            let before = predecessor[file.index].map { selection.contains($0) } ?? false
            let after = successor[file.index].map { selection.contains($0) } ?? false
            if !before && !after {
                guard full <= UInt64.max - piece * 2 else { blocked = true; break }
                full += piece * 2; remaining += piece * 2
            } else if before && after {
                full -= piece * 2; remaining -= piece * 2
            }
            guard full <= capacity, remaining <= free else { blocked = true; break }
            selection.insert(file.index); cost = (full, remaining)
        }
        return .init(selection: selection.sorted(), blockedOnSpace: blocked, reservedBytes: cost.remaining)
    }

    /// Whether the queued completed files are worth one uploader spawn. The
    /// wait trigger is what keeps a slow swarm showing steady progress.
    ///
    /// `used` and `capacity` describe the RAM volume. A `capacity` of zero
    /// means it could not be read, and leaves the ordinary limits in charge.
    static func shouldFlush(count: Int, bytes: UInt64, waiting: TimeInterval, windowComplete: Bool,
                            fileLimit: Int = flushFileLimit, byteLimit: UInt64 = flushByteLimit,
                            wait: TimeInterval = flushWait,
                            used: UInt64 = 0, capacity: UInt64 = 0, blockedOnSpace: Bool = false) -> Bool {
        guard count > 0 else { return false }
        if windowComplete || blockedOnSpace { return true }
        if capacity > 0, Double(used) / Double(capacity) >= flushPressure { return true }
        return count >= fileLimit || bytes >= byteLimit || waiting >= wait
    }
}

extension Array where Element == Int {
    /// Union preserving ascending order, for the persisted drained list.
    func appendingUnique(_ values: [Int]) -> [Int] { Array(Set(self).union(values)).sorted() }
}

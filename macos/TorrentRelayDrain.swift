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
    static func removable(layout: Layout, complete: Set<Int>, committed: Set<Int>, removed: Set<Int>) -> [Int] {
        var result: [Int] = []
        for (slot, file) in layout.files.enumerated() {
            guard committed.contains(file.index), !removed.contains(file.index),
                  complete.contains(file.index) else { continue }
            let span = layout.pieceBytes(slot)
            if span.isEmpty { result.append(file.index); continue }
            var safe = true
            for other in layout.touching(span) where other != slot {
                let index = layout.files[other].index
                if !complete.contains(index) && !removed.contains(index) { safe = false; break }
            }
            if safe { result.append(file.index) }
        }
        return result
    }

    static let flushFileLimit = 32
    static let flushByteLimit: UInt64 = 256 * 1024 * 1024
    static let flushWait: TimeInterval = 180

    /// Whether the queued completed files are worth one uploader spawn. The
    /// wait trigger is what keeps a slow swarm showing steady progress.
    static func shouldFlush(count: Int, bytes: UInt64, waiting: TimeInterval, windowComplete: Bool) -> Bool {
        guard count > 0 else { return false }
        if windowComplete { return true }
        return count >= flushFileLimit || bytes >= flushByteLimit || waiting >= flushWait
    }
}

extension Array where Element == Int {
    /// Union preserving ascending order, for the persisted drained list.
    func appendingUnique(_ values: [Int]) -> [Int] { Array(Set(self).union(values)).sorted() }
}

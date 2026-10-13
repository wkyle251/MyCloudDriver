import Foundation

/// A file's bytes held in RAM as fixed blocks, within a budget. It keeps a window
/// around the playhead: when full, the block farthest behind the playhead goes
/// first, then the farthest ahead. Nothing is ever written to disk.
final class MemoryRangeBuffer: @unchecked Sendable {
    let contentLength: Int64
    let blockSize: Int
    let maximumBlocks: Int
    private let lock = NSLock()
    private var blocks: [Int: Data] = [:]
    private var anchor = 0
    private var resident: Int64 = 0

    /// One sixteenth of the Mac's RAM, between 64 MiB and 1 GiB.
    static func automaticBudget(physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory) -> Int64 {
        let mebibyte: Int64 = 1 << 20
        return min(1 << 30, max(64 * mebibyte, Int64(clamping: physicalMemory / 16)))
    }

    /// Always room for the playhead's block and the block being read next.
    init(contentLength: Int64, budgetBytes: Int64, blockSize: Int = 1 << 20) {
        precondition(contentLength >= 0 && blockSize > 0)
        self.contentLength = contentLength
        self.blockSize = blockSize
        maximumBlocks = max(2, Int(max(0, budgetBytes) / Int64(blockSize)))
    }

    var blockCount: Int { Int((contentLength + Int64(blockSize) - 1) / Int64(blockSize)) }
    var residentBytes: Int64 { lock.lock(); defer { lock.unlock() }; return resident }
    var playheadBlock: Int { lock.lock(); defer { lock.unlock() }; return anchor }

    func blockRange(_ index: Int) -> Range<Int64> {
        let start = Int64(index) * Int64(blockSize)
        return start ..< min(contentLength, start + Int64(blockSize))
    }
    func contains(_ index: Int) -> Bool { lock.lock(); defer { lock.unlock() }; return blocks[index] != nil }

    /// Where the player is reading. Eviction keeps this block and favours what lies ahead of it.
    func setAnchor(_ offset: Int64) {
        guard blockCount > 0 else { return }
        lock.lock(); anchor = min(blockCount - 1, max(0, Int(offset / Int64(blockSize)))); lock.unlock()
    }

    /// Stores one whole block, evicting if the budget is exceeded. False if the block is out of range or the wrong length.
    @discardableResult
    func store(_ data: Data, block index: Int) -> Bool {
        guard index >= 0, index < blockCount, Int64(data.count) == Int64(blockRange(index).count) else { return false }
        lock.lock(); defer { lock.unlock() }
        if blocks[index] == nil { resident += Int64(data.count) }
        else { resident += Int64(data.count) - Int64(blocks[index]!.count) }
        blocks[index] = data
        while blocks.count > maximumBlocks {
            // Behind the playhead counts three times as far as ahead, so the past is dropped before the future.
            let victim = blocks.keys.filter { $0 != anchor && $0 != index }.max {
                (weight($0), $1) < (weight($1), $0)
            }
            guard let victim else { break }
            resident -= Int64(blocks.removeValue(forKey: victim)!.count)
        }
        return true
    }
    private func weight(_ index: Int) -> Int { index < anchor ? (anchor - index) * 3 : index - anchor }

    /// The resident bytes that follow `offset` without a gap, up to `maxLength`. Nil if `offset` itself is not resident.
    func data(from offset: Int64, maxLength: Int) -> Data? {
        guard offset >= 0, offset < contentLength, maxLength > 0 else { return nil }
        lock.lock(); defer { lock.unlock() }
        var result = Data(), position = offset
        while result.count < maxLength, position < contentLength {
            let index = Int(position / Int64(blockSize))
            guard let block = blocks[index] else { break }
            let start = Int(position - Int64(index) * Int64(blockSize))
            let end = min(block.count, start + (maxLength - result.count))
            result.append(block.subdata(in: start ..< end))
            position += Int64(end - start)
        }
        return result.isEmpty ? nil : result
    }

    /// The first block not resident among `count` blocks starting at `start`, optionally wrapping past the end.
    func firstMissing(from start: Int, count: Int, wrapping: Bool) -> Int? {
        let total = blockCount
        guard total > 0 else { return nil }
        lock.lock(); defer { lock.unlock() }
        for step in 0 ..< min(count, total) {
            var index = start + step
            if index >= total { guard wrapping else { return nil }; index -= total }
            if blocks[index] == nil { return index }
        }
        return nil
    }

    /// Resident byte ranges, ordered and merged where blocks touch.
    var snapshot: PreviewResourceCacheSnapshot {
        lock.lock(); defer { lock.unlock() }
        var ranges: [Range<Int64>] = []
        for index in blocks.keys.sorted() {
            let range = blockRange(index)
            if let last = ranges.last, last.upperBound == range.lowerBound { ranges[ranges.count - 1] = last.lowerBound ..< range.upperBound }
            else { ranges.append(range) }
        }
        return PreviewResourceCacheSnapshot(cachedBytes: resident, contentLength: contentLength, ranges: ranges)
    }

    func removeAll() {
        lock.lock(); blocks = [:]; resident = 0; lock.unlock()
    }
}

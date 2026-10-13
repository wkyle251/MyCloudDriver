import Foundation

/// Generated integers only; never loads persisted queues or user files.
@main struct TransferRowPaginationTests {
    static func checkPages(_ count: Int, expectedPages: Int, lastPageCount: Int) {
        precondition(TransferRowPagination.pageCount(itemCount: count) == expectedPages)
        let original = Array(0..<count)
        var covered = 0
        for page in 0..<expectedPages {
            let bounds = TransferRowPagination.range(page, itemCount: count)
            precondition(bounds.lowerBound == covered && bounds.count <= 50)
            let visible = Array(original[bounds])
            precondition(visible.count == bounds.count)
            if !visible.isEmpty {
                precondition(visible.first == covered && visible.last == bounds.upperBound - 1)
            }
            covered += visible.count
        }
        precondition(covered == count && original == Array(0..<count), "Paging must preserve every queued item")
        precondition(TransferRowPagination.range(expectedPages - 1, itemCount: count).count == lastPageCount)
    }

    static func main() {
        precondition(TransferRowPagination.pageSize == 50)
        for count in [Int.min, -1, 0] {
            precondition(TransferRowPagination.pageCount(itemCount: count) == 0)
            precondition(TransferRowPagination.range(Int.max, itemCount: count) == 0..<0)
            precondition(TransferRowPagination.clampedPage(Int.min, itemCount: count) == 0)
        }
        checkPages(1, expectedPages: 1, lastPageCount: 1)
        checkPages(49, expectedPages: 1, lastPageCount: 49)
        checkPages(50, expectedPages: 1, lastPageCount: 50)
        checkPages(51, expectedPages: 2, lastPageCount: 1)
        checkPages(2_179, expectedPages: 44, lastPageCount: 29)
        checkPages(100_000, expectedPages: 2_000, lastPageCount: 50)
        print("PASS fixed 50-row pages cover generated 2,179 and 100,000 item queues without modifying or losing items")

        precondition(TransferRowPagination.range(-1, itemCount: 2_179) == 0..<50)
        precondition(TransferRowPagination.range(Int.max, itemCount: 2_179) == 2_150..<2_179)
        precondition(TransferRowPagination.clampedPage(43, itemCount: 100) == 1)
        precondition(TransferRowPagination.range(43, itemCount: 100) == 50..<100)
        precondition(TransferRowPagination.clampedPage(43, itemCount: 50) == 0)
        precondition(TransferRowPagination.range(43, itemCount: 0).isEmpty)
        print("PASS stale pages clamp when a queue shrinks, clears or receives invalid page indexes")

        let pages = TransferRowPagination.pageCount(itemCount: Int.max)
        precondition(pages > 0)
        let last = TransferRowPagination.range(Int.max, itemCount: Int.max)
        precondition(last.upperBound == Int.max && last.count > 0 && last.count <= 50)
        precondition(last.lowerBound == (pages - 1) * 50)
        precondition(TransferRowPagination.range(Int.min, itemCount: Int.max) == 0..<50)
        print("PASS overflow-safe bounds at Int.max without constructing a large collection")

        for count in [2_179, 100_000] {
            let source = Array(0..<count)
            let lastPage = TransferRowPagination.pageCount(itemCount: count) - 1
            for page in [0, 1, lastPage, Int.max] {
                var accessed: [Int] = []
                let visible = TransferRowPagination.window(page, itemCount: source.count) { index in
                    accessed.append(index)
                    return source[index]
                }
                let bounds = TransferRowPagination.range(page, itemCount: count)
                precondition(accessed == Array(bounds) && accessed.count <= 50,
                             "A page must not access or map rows outside its visible window")
                precondition(visible == Array(source[bounds]))
                let reversed = source.reversed()
                var reverseAccesses = 0
                let reversedPage = TransferRowPagination.window(page, itemCount: reversed.count) { index in
                    reverseAccesses += 1
                    return reversed[reversed.index(reversed.startIndex, offsetBy: index)]
                }
                precondition(reverseAccesses <= 50 && reversedPage == bounds.map { count - 1 - $0 })
            }
        }
        var emptyAccesses = 0
        let empty = TransferRowPagination.window(100, itemCount: 0) { index in emptyAccesses += 1; return index }
        precondition(empty.isEmpty && emptyAccesses == 0)
        print("PASS lazy indexed pages touch at most fifty generated queue/history rows, including reversed histories and empty queues")
    }
}

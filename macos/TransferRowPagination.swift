import SwiftUI

/// Display pagination only. Transfer scheduling and persisted queues always
/// retain the entire source collection.
enum TransferRowPagination {
    static let pageSize = 50

    static func pageCount(itemCount: Int) -> Int {
        let count = max(0, itemCount)
        return count / pageSize + (count % pageSize == 0 ? 0 : 1)
    }

    static func clampedPage(_ page: Int, itemCount: Int) -> Int {
        min(max(0, page), max(0, pageCount(itemCount: itemCount) - 1))
    }

    static func range(_ page: Int, itemCount: Int) -> Range<Int> {
        let count = max(0, itemCount)
        let start = clampedPage(page, itemCount: count) * pageSize
        // Subtract first so the final partial page also works at Int.max.
        return start..<(start + min(pageSize, count - start))
    }

    /// Materialize just the visible page, including when the caller combines
    /// several queues or presents a reversed collection without copying it.
    static func window<Item>(_ page: Int, itemCount: Int, itemAt: (Int) -> Item) -> [Item] {
        range(page, itemCount: itemCount).map(itemAt)
    }
}

/// A plain transfer list that constructs at most fifty rows. Each board
/// section owns its own page; changing the page never changes queue contents.
struct TransferPagedRows<Item: Identifiable, Row: View>: View {
    private let itemCount: Int
    private let itemAt: (Int) -> Item
    private let row: (Item) -> Row
    @State private var page = 0

    init<Items: RandomAccessCollection>(items: Items, @ViewBuilder row: @escaping (Item) -> Row) where Items.Element == Item {
        itemCount = items.count
        itemAt = { items[items.index(items.startIndex, offsetBy: $0)] }
        self.row = row
    }

    init(itemCount: Int, itemAt: @escaping (Int) -> Item, @ViewBuilder row: @escaping (Item) -> Row) {
        self.itemCount = max(0, itemCount)
        self.itemAt = itemAt
        self.row = row
    }

    var body: some View {
        let currentPage = TransferRowPagination.clampedPage(page, itemCount: itemCount)
        let bounds = TransferRowPagination.range(currentPage, itemCount: itemCount)
        let visible = TransferRowPagination.window(currentPage, itemCount: itemCount, itemAt: itemAt)
        VStack(spacing: 0) {
            List {
                ForEach(visible) { item in row(item) }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            if itemCount > TransferRowPagination.pageSize {
                Divider()
                HStack(spacing: 10) {
                    Button {
                        page = currentPage - 1
                    } label: {
                        Label("Previous", systemImage: "chevron.left")
                    }
                    .disabled(currentPage == 0)
                    Spacer(minLength: 0)
                    Text("\((bounds.lowerBound + 1).formatted())–\(bounds.upperBound.formatted()) of \(itemCount.formatted())")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Button {
                        page = currentPage + 1
                    } label: {
                        Label("Next", systemImage: "chevron.right")
                    }
                    .disabled(currentPage + 1 >= TransferRowPagination.pageCount(itemCount: itemCount))
                }
                .font(.caption)
                .buttonStyle(.borderless)
                .controlSize(.small)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Transfer pages")
            }
        }
        .onChange(of: itemCount) { count in
            page = TransferRowPagination.clampedPage(page, itemCount: count)
        }
    }
}

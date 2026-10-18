import SwiftUI

/// A bounded window into results; changing pages never changes the selection.
struct ResultPage {
    let total: Int
    let size: Int
    let index: Int
    var count: Int { total == 0 ? 1 : (total - 1) / size + 1 }
    var range: Range<Int> { let start = index * size; return start..<min(start + size, total) }
    init(total: Int, requestedPage: Int, size: Int = 200) {
        self.total = max(0, total); self.size = max(1, size)
        let last = total > 0 ? (total - 1) / self.size : 0
        index = min(max(0, requestedPage), last)
    }
}

struct ResultPageControls: View {
    let page: ResultPage
    @Binding var selection: Int
    var body: some View {
        HStack(spacing: 12) {
            Text("\((page.range.lowerBound + 1).formatted())–\(page.range.upperBound.formatted()) of \(page.total.formatted()) files")
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button("Previous") { selection = page.index - 1 }.disabled(page.index == 0)
            Text("\((page.index + 1).formatted()) / \(page.count.formatted())").font(.caption.monospacedDigit())
            Button("Next") { selection = page.index + 1 }.disabled(page.index + 1 >= page.count)
        }.controlSize(.small)
    }
}

/// Off-main preparation makes displaying a page and toggling one file
/// independent of the total number of duplicate files.
struct DuplicateResultsIndex {
    struct Slice: Identifiable {
        let group: DuplicateGroup
        let range: Range<Int>
        var id: String { group.id }
    }
    let id = UUID()
    let groups: [DuplicateGroup]
    let filesByID: [String: DuplicateFile]
    let groupsForFile: [String: [String]]
    let groupSizes: [String: Int]
    let recommendedIDs: Set<String>
    let recommendedSelection: DuplicateSelectionSummary
    let offsets: [Int]
    var fileCount: Int { offsets.last ?? 0 }

    init(groups: [DuplicateGroup]) {
        self.groups = groups
        var files: [String: DuplicateFile] = [:], membership: [String: [String]] = [:], sizes: [String: Int] = [:]
        var offsets = [0], recommended = Set<String>()
        for group in groups {
            offsets.append(offsets.last! + group.files.count); sizes[group.id] = group.files.count
            for file in group.files { files[file.id] = file; membership[file.id, default: []].append(group.id) }
            if group.matchKind == .exactContent { recommended.formUnion(CrossDriveDuplicatePolicy.recommendedIDs(group.files)) }
        }
        filesByID = files; groupsForFile = membership; groupSizes = sizes
        self.offsets = offsets; recommendedIDs = recommended
        var summary = DuplicateSelectionSummary()
        for id in recommended {
            if let file = files[id] { summary.update(file, groups: membership[id] ?? [], selected: true) }
        }
        recommendedSelection = summary
    }

    func slices(for page: ResultPage) -> [Slice] {
        guard !groups.isEmpty, !page.range.isEmpty else { return [] }
        // Find the first intersecting group without walking all preceding files.
        var lower = 0, upper = groups.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if offsets[middle + 1] <= page.range.lowerBound { lower = middle + 1 } else { upper = middle }
        }
        var slices: [Slice] = [], index = lower
        while index < groups.count, offsets[index] < page.range.upperBound {
            let start = max(0, page.range.lowerBound - offsets[index])
            let end = min(groups[index].files.count, page.range.upperBound - offsets[index])
            if start < end { slices.append(.init(group: groups[index], range: start..<end)) }
            index += 1
        }
        return slices
    }
    static let empty = Self(groups: [])
}

struct DuplicateSelectionSummary {
    private var lowBytes: UInt64 = 0
    private var highBytes: UInt64 = 0
    private(set) var groupCounts: [String: Int] = [:]
    var bytes: UInt64 { highBytes == 0 ? lowBytes : .max }
    mutating func update(_ file: DuplicateFile, groups: [String], selected: Bool) {
        // Retain the carry so removing a file after saturation is still exact.
        if selected {
            let sum = lowBytes.addingReportingOverflow(file.size)
            lowBytes = sum.partialValue; if sum.overflow { highBytes += 1 }
        } else {
            let difference = lowBytes.subtractingReportingOverflow(file.size)
            lowBytes = difference.partialValue; if difference.overflow { highBytes -= 1 }
        }
        for group in groups { groupCounts[group, default: 0] += selected ? 1 : -1 }
    }
}

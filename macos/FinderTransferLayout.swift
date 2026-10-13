import SwiftUI

/// The transfer page responds to its pane, which can be much smaller than the
/// window after the sidebar is accounted for. Lists retain usable row heights
/// and the page scrolls vertically when a short window cannot fit them all.
enum FinderTransferGeometry {
    static let spacing: CGFloat = 12
    static let laneMinimumWidth: CGFloat = 300
    static let overviewMinimumWidth: CGFloat = 920

    static func overviewCardWidths(for width: CGFloat, emphasizeProgress: Bool = false) -> (setup: CGFloat, progress: CGFloat)? {
        let width = width.isFinite ? max(0, width) : 0
        if emphasizeProgress {
            let setupMinimum: CGFloat = 320, progressMinimum: CGFloat = 640
            guard width >= setupMinimum + progressMinimum + spacing else { return nil }
            let available = width - spacing
            let progress = max(progressMinimum, min(available - setupMinimum, available * 0.6))
            return (available - progress, progress)
        }
        guard width >= overviewMinimumWidth else { return nil }
        return (width - spacing - 400, 400)
    }

    static func metricColumns(for width: CGFloat) -> Int {
        guard width.isFinite else { return 1 }
        if width >= 600 { return 4 }
        if width >= 300 { return 2 }
        return 1
    }

    static func metricColumnWidth(for width: CGFloat) -> CGFloat {
        let width = width.isFinite ? max(0, width) : 0
        let columns = metricColumns(for: width)
        return max(0, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
    }

    static func metricFrames(width: CGFloat, heights: [CGFloat]) -> [CGRect] {
        let width = width.isFinite ? max(0, width) : 0
        let columns = metricColumns(for: width), columnWidth = metricColumnWidth(for: width)
        var frames: [CGRect] = []
        var y: CGFloat = 0
        for start in stride(from: 0, to: heights.count, by: columns) {
            let end = min(heights.count, start + columns)
            let rowHeight = heights[start..<end].map { $0.isFinite ? max(0, $0) : 0 }.max() ?? 0
            for index in start..<end {
                frames.append(.init(x: CGFloat(index - start) * (columnWidth + spacing), y: y,
                    width: columnWidth, height: rowHeight))
            }
            y += rowHeight + spacing
        }
        return frames
    }

    static func columns(for width: CGFloat) -> Int {
        let width = width.isFinite ? max(0, width) : 0
        if width >= laneMinimumWidth * 3 + spacing * 2 { return 3 }
        if width >= laneMinimumWidth * 2 + spacing { return 2 }
        return 1
    }

    static func laneFrames(width: CGFloat, height: CGFloat, finishedMinimumHeight: CGFloat = 210) -> [CGRect] {
        let width = width.isFinite ? max(0, width) : 0
        let height = height.isFinite ? max(0, height) : 0
        switch columns(for: width) {
        case 3:
            let laneWidth = max(0, (width - spacing * 2) / 3)
            return (0..<3).map { CGRect(x: CGFloat($0) * (laneWidth + spacing), y: 0, width: laneWidth, height: height) }
        case 2:
            let laneWidth = max(0, (width - spacing) / 2)
            let extra = max(0, height - spacing - 210 - finishedMinimumHeight) / 2
            let rowHeight = 210 + extra
            let finishedHeight = finishedMinimumHeight + extra
            return [CGRect(x: 0, y: 0, width: laneWidth, height: rowHeight),
                    CGRect(x: laneWidth + spacing, y: 0, width: laneWidth, height: rowHeight),
                    CGRect(x: 0, y: rowHeight + spacing, width: width, height: finishedHeight)]
        default:
            let extra = max(0, height - spacing * 2 - 420 - finishedMinimumHeight) / 3
            let rowHeight = 210 + extra
            return (0..<3).map { CGRect(x: 0, y: CGFloat($0) * (rowHeight + spacing), width: width,
                height: $0 == 2 ? finishedMinimumHeight + extra : rowHeight) }
        }
    }

    static func minimumBoardHeight(for width: CGFloat, finishedMinimumHeight: CGFloat = 210) -> CGFloat {
        switch columns(for: width) {
        case 3: return max(260, finishedMinimumHeight)
        case 2: return 210 + finishedMinimumHeight + spacing
        default: return 420 + finishedMinimumHeight + spacing * 2
        }
    }

    static func actionFrames(width: CGFloat, sizes: [CGSize], spacing: CGFloat = 8) -> [CGRect] {
        let width = width.isFinite ? max(0, width) : 0
        var result: [CGRect] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for size in sizes {
            let itemWidth = min(width, max(0, size.width))
            if x > 0, x + itemWidth > width {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            result.append(.init(x: x, y: y, width: itemWidth, height: size.height))
            x += itemWidth + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return result
    }
}

private struct FinderTransferViewportKey: EnvironmentKey {
    static let defaultValue = CGSize.zero
}

extension EnvironmentValues {
    var finderTransferViewport: CGSize {
        get { self[FinderTransferViewportKey.self] }
        set { self[FinderTransferViewportKey.self] = newValue }
    }
}

struct FinderTransferWorkspace<Content: View>: View {
    @Environment(\.finderTransferViewport) private var viewport
    var spacing: CGFloat = FinderTransferGeometry.spacing
    var fillsViewport = true
    @ViewBuilder var content: () -> Content
    var body: some View {
        FinderTransferFillLayout(minimumHeight: fillsViewport ? viewport.height : 0, spacing: spacing) {
            content()
        }
    }
}

struct FinderTransferExpandsVerticallyKey: LayoutValueKey {
    static let defaultValue = false
}

/// Cards use their natural heights. The marked transfer board (or the final
/// child by default) fills the remaining space, including with a chart below it.
struct FinderTransferFillLayout: Layout {
    var minimumHeight: CGFloat
    var spacing: CGFloat = 12

    private func dimensions(_ proposal: ProposedViewSize, _ subviews: Subviews) -> [CGSize] {
        let width = max(0, proposal.width ?? 0)
        var sizes = subviews.map { $0.sizeThatFits(.init(width: width, height: nil)) }
        let naturalHeight = sizes.reduce(0) { $0 + $1.height } + CGFloat(max(0, sizes.count - 1)) * spacing
        if let index = subviews.lastIndex(where: { $0[FinderTransferExpandsVerticallyKey.self] }) ?? sizes.indices.last {
            sizes[index].height += max(0, minimumHeight - naturalHeight)
        }
        return sizes
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = dimensions(proposal, subviews)
        return .init(width: max(0, proposal.width ?? 0),
            height: sizes.reduce(0) { $0 + $1.height } + CGFloat(max(0, sizes.count - 1)) * spacing)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = dimensions(.init(width: bounds.width, height: bounds.height), subviews)
        var y = bounds.minY
        for (index, subview) in subviews.enumerated() {
            subview.place(at: .init(x: bounds.minX, y: y), anchor: .topLeading,
                proposal: .init(width: bounds.width, height: sizes[index].height))
            y += sizes[index].height + spacing
        }
    }
}

struct FinderTransferBoardLayout: Layout {
    var finishedMinimumHeight: CGFloat = 210
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(0, proposal.width ?? 0)
        return .init(width: width, height: max(FinderTransferGeometry.minimumBoardHeight(for: width,
            finishedMinimumHeight: finishedMinimumHeight), proposal.height ?? 0))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = FinderTransferGeometry.laneFrames(width: bounds.width, height: bounds.height,
            finishedMinimumHeight: finishedMinimumHeight)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: .init(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                proposal: .init(width: frame.width, height: frame.height))
        }
    }
}

/// A growing toolbar wraps actions onto additional lines without hiding them
/// behind a horizontal scroller or truncating the primary action.
struct FinderTransferActionLayout: Layout {
    var spacing: CGFloat = 8

    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        FinderTransferGeometry.actionFrames(width: width,
            sizes: subviews.map { $0.sizeThatFits(.init(width: width, height: nil)) }, spacing: spacing)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(0, proposal.width ?? 0)
        return .init(width: width, height: frames(width: width, subviews: subviews).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            subview.place(at: .init(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                proposal: .init(width: frame.width, height: frame.height))
        }
    }
}

/// Four download metrics share a row when the pane has room. Narrow panes
/// wrap complete metric cells, including multiline values, without clipping.
struct FinderTransferMetricLayout: Layout {
    private func frames(width: CGFloat, subviews: Subviews) -> [CGRect] {
        let columnWidth = FinderTransferGeometry.metricColumnWidth(for: width)
        return FinderTransferGeometry.metricFrames(width: width,
            heights: subviews.map { $0.sizeThatFits(.init(width: columnWidth, height: nil)).height })
    }
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = max(0, proposal.width ?? 0)
        return .init(width: width, height: frames(width: width, subviews: subviews).map(\.maxY).max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(width: bounds.width, subviews: subviews)) {
            subview.place(at: .init(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                proposal: .init(width: frame.width, height: frame.height))
        }
    }
}

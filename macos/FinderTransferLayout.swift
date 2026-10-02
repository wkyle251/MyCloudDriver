import SwiftUI

/// The transfer page responds to its pane, which can be much smaller than the
/// window after the sidebar is accounted for. Lists retain usable row heights
/// and the page scrolls vertically when a short window cannot fit them all.
enum FinderTransferGeometry {
    static let spacing: CGFloat = 12
    static let laneMinimumWidth: CGFloat = 300
    static let overviewMinimumWidth: CGFloat = 920

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
    @ViewBuilder var content: () -> Content
    var body: some View {
        FinderTransferFillLayout(minimumHeight: viewport.height, spacing: spacing) {
            content()
        }
    }
}

/// Top cards use their natural heights. The final transfer board uses the
/// remaining space, instead of leaving blank space under a fixed-height list.
struct FinderTransferFillLayout: Layout {
    var minimumHeight: CGFloat
    var spacing: CGFloat = 12

    private func dimensions(_ proposal: ProposedViewSize, _ subviews: Subviews) -> [CGSize] {
        let width = max(0, proposal.width ?? 0)
        var sizes = subviews.map { $0.sizeThatFits(.init(width: width, height: nil)) }
        let naturalHeight = sizes.reduce(0) { $0 + $1.height } + CGFloat(max(0, sizes.count - 1)) * spacing
        if !sizes.isEmpty { sizes[sizes.count - 1].height += max(0, minimumHeight - naturalHeight) }
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

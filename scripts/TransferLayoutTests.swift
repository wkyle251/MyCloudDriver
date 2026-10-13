import Foundation

@main struct TransferLayoutTests {
    static func main() {
        // Test the pane widths as well as window presets: the sidebar consumes
        // another ~220 points before the transfer layout receives its proposal.
        for width: CGFloat in [300, 360, 400, 500, 600, 611, 612, 720, 923, 924, 1_100, 1_400] {
            let minimum = FinderTransferGeometry.minimumBoardHeight(for: width)
            for height in [minimum, minimum + 400] {
                let frames = FinderTransferGeometry.laneFrames(width: width, height: height)
                precondition(frames.count == 3)
                for frame in frames {
                    precondition(frame.minX >= 0 && frame.maxX <= width + 0.001)
                    precondition(frame.minY >= 0 && frame.maxY <= height + 0.001)
                    precondition(frame.height >= 210)
                }
                for i in 0..<frames.count {
                    for j in (i + 1)..<frames.count { precondition(!frames[i].intersects(frames[j])) }
                }
                precondition(abs(frames.map(\.maxY).max()! - height) < 0.001)
            }
        }
        precondition(FinderTransferGeometry.columns(for: 611) == 1)
        precondition(FinderTransferGeometry.columns(for: 612) == 2)
        precondition(FinderTransferGeometry.columns(for: 923) == 2)
        precondition(FinderTransferGeometry.columns(for: 924) == 3)
        precondition(FinderTransferGeometry.columns(for: .nan) == 1)
        for width: CGFloat in [300, 360, 611, 612, 720, 923, 924, 1_100] {
            // Completed alone, Completed with Retry/Failed, and all three
            // sections must fit the last lane at every layout breakpoint.
            for finishedMinimumHeight: CGFloat in [210, 370, 530] {
                let minimum = FinderTransferGeometry.minimumBoardHeight(for: width,
                    finishedMinimumHeight: finishedMinimumHeight)
                for height in [minimum, minimum + 400] {
                    let lanes = FinderTransferGeometry.laneFrames(width: width, height: height,
                        finishedMinimumHeight: finishedMinimumHeight)
                    precondition(lanes.count == 3)
                    precondition(lanes[2].height >= finishedMinimumHeight,
                        "Retry, Completed and Failed must remain reachable in the last lane")
                    for lane in lanes {
                        precondition(lane.minX >= 0 && lane.maxX <= width + 0.001)
                        precondition(lane.minY >= 0 && lane.maxY <= height + 0.001)
                    }
                    for i in 0..<lanes.count {
                        for j in (i + 1)..<lanes.count { precondition(!lanes[i].intersects(lanes[j])) }
                    }
                    if FinderTransferGeometry.columns(for: width) == 1 {
                        precondition(lanes[2].minY >= lanes[1].maxY + FinderTransferGeometry.spacing,
                            "A narrow pane stacks the finished sections after Queue")
                    } else if FinderTransferGeometry.columns(for: width) == 2 {
                        precondition(lanes[2].width == width && lanes[2].minY >= lanes[0].maxY + FinderTransferGeometry.spacing,
                            "A medium pane keeps Retry/Completed/Failed full width below active lanes")
                    }
                    precondition(abs(lanes.map(\.maxY).max()! - height) < 0.001)
                }
            }
        }
        print("PASS transfer board adaptation: narrow/medium/wide panes, bounded lanes, usable list heights and remaining vertical space")

        let actions = [CGSize(width: 205, height: 24), .init(width: 132, height: 24),
            .init(width: 130, height: 24), .init(width: 170, height: 24)]
        for width: CGFloat in [300, 360, 500, 720, 1_100] {
            let frames = FinderTransferGeometry.actionFrames(width: width, sizes: actions)
            precondition(frames.count == actions.count)
            for frame in frames { precondition(frame.minX >= 0 && frame.maxX <= width) }
            for i in 0..<frames.count {
                for j in (i + 1)..<frames.count { precondition(!frames[i].intersects(frames[j])) }
            }
        }
        let wrapped = FinderTransferGeometry.actionFrames(width: 360, sizes: actions)
        precondition(wrapped[0].minY == 0 && wrapped[1].minY == 0)
        precondition(wrapped[2].minY == 32 && wrapped[3].minY == 32)
        let wide = FinderTransferGeometry.actionFrames(width: 720, sizes: actions)
        precondition(wide.allSatisfy { $0.minY == 0 })
        print("PASS transfer actions: wrapping preserves every action and pane bounds at resized widths")

        for width: CGFloat in [240, 300, 400, 600, 920, 971, 972, 1_000, 1_100, 1_400, 1_700] {
            let download = FinderTransferGeometry.overviewCardWidths(for: width, emphasizeProgress: true)
            if width < 972 {
                precondition(download == nil, "Narrow Downloads panes stack complete setup and progress cards")
            } else {
                let widths = download!
                precondition(widths.setup >= 320 && widths.progress >= 640 && widths.progress > widths.setup)
                precondition(abs(widths.setup + FinderTransferGeometry.spacing + widths.progress - width) < 0.001)
                precondition(FinderTransferGeometry.metricColumns(for: widths.progress - 24) == 4,
                    "Every side-by-side download progress card fits all four metrics in one row")
                if width >= 1_100 {
                    precondition(abs(widths.progress / (width - FinderTransferGeometry.spacing) - 0.6) < 0.001)
                }
            }
            let standard = FinderTransferGeometry.overviewCardWidths(for: width)
            if width < 920 { precondition(standard == nil) }
            else {
                precondition(standard!.progress == 400 && standard!.setup == width - 412,
                    "Other transfer overview layouts keep their existing sizing")
            }
        }
        precondition(FinderTransferGeometry.overviewCardWidths(for: .nan, emphasizeProgress: true) == nil)
        print("PASS download overview: wider progress, compact setup, minimum usable card widths and unchanged other transfer modes")

        // Unequal heights model wrapped discovery/remaining labels and large
        // file counts. A metric remains whole when the pane changes columns.
        let metricHeights: [CGFloat] = [46, 30, 62, 50]
        for width: CGFloat in [240, 299, 300, 360, 599, 600, 616, 800, 1_100] {
            let frames = FinderTransferGeometry.metricFrames(width: width, heights: metricHeights)
            let columns = FinderTransferGeometry.metricColumns(for: width)
            precondition(frames.count == 4)
            for (index, frame) in frames.enumerated() {
                precondition(frame.minX >= 0 && frame.maxX <= width + 0.001)
                precondition(frame.height >= metricHeights[index], "Wrapped values remain visible")
            }
            for i in frames.indices {
                for j in (i + 1)..<frames.count { precondition(!frames[i].intersects(frames[j])) }
            }
            if width >= 600 {
                precondition(columns == 4 && frames.allSatisfy { $0.minY == 0 })
                precondition(frames.allSatisfy { $0.height == 62 }, "The single metric row fits its tallest wrapped value")
            } else if width >= 300 {
                precondition(columns == 2 && frames[2].minY == frames[0].maxY + FinderTransferGeometry.spacing)
            } else {
                precondition(columns == 1 && frames.allSatisfy { $0.width == width })
                precondition(frames[3].minY >= frames[2].maxY + FinderTransferGeometry.spacing)
            }
        }
        precondition(FinderTransferGeometry.metricFrames(width: 600, heights: []).isEmpty)
        precondition(FinderTransferGeometry.metricColumns(for: .nan) == 1)
        print("PASS download metrics: one row at normal width; narrow wrapping preserves every metric without overlap or clipping")
    }
}

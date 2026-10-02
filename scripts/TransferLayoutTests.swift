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
        for width: CGFloat in [360, 720, 1_100] {
            let height = FinderTransferGeometry.minimumBoardHeight(for: width, finishedMinimumHeight: 330)
            let lanes = FinderTransferGeometry.laneFrames(width: width, height: height, finishedMinimumHeight: 330)
            precondition(lanes[2].height >= 330, "completed and failed cards must both remain usable")
            precondition(abs(lanes.map(\.maxY).max()! - height) < 0.001)
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
    }
}

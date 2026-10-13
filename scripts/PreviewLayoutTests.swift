import Foundation

@main struct PreviewLayoutTests {
    static func main() {
        let oversized = FinderPreviewGeometry(available: .init(width: 300, height: 420), requestedHeight: 2_000)
        precondition(oversized.size == CGSize(width: 300, height: 406), "Details live in the popover, so the media keeps all but the handle")
        precondition(oversized.size.height + oversized.verticalHandle == 420)
        let normal = FinderPreviewGeometry(available: .init(width: 500, height: 700), requestedHeight: 440)
        precondition(normal.size == CGSize(width: 500, height: 440))
        precondition(normal.resizedHeight(from: normal.size.height, translation: .init(width: -120, height: -100)) == 340)
        precondition(normal.resizedHeight(from: normal.size.height, translation: .init(width: -120, height: 0)) == 440)
        precondition(normal.resizedHeight(from: normal.size.height, translation: .init(width: CGFloat.nan, height: -100)) == 340)
        precondition(normal.resizedHeight(from: normal.size.height, translation: .init(width: 5_000, height: 5_000)) == normal.maximum.height)
        precondition(normal.resizedHeight(from: normal.size.height, translation: .init(width: -5_000, height: -5_000)) == 180)
        precondition(normal.resizedHeight(from: normal.size.height, translation: .init(width: 0, height: CGFloat.nan)) == 440)
        print("PASS preview resizing: height-only drags, usable minimum, overshoot bounds and reachable bottom handle")

        let savedHeight: CGFloat = 800
        let smaller = FinderPreviewGeometry(available: .init(width: 400, height: 450), requestedHeight: savedHeight)
        let larger = FinderPreviewGeometry(available: .init(width: 1_100, height: 1_000), requestedHeight: savedHeight)
        precondition(smaller.size == CGSize(width: 400, height: 436) && larger.size == CGSize(width: 1_100, height: 800))
        for size in [CGSize.zero, .init(width: 80, height: 80), .init(width: 220, height: 220)] {
            let layout = FinderPreviewGeometry(available: size, requestedHeight: 1)
            precondition(layout.size.width >= 0 && layout.size.height >= 0)
            precondition(layout.size.width == size.width)
            precondition(layout.size.height + layout.verticalHandle <= size.height)
        }
        let invalid = FinderPreviewGeometry(available: .init(width: 1_000, height: 1_000), requestedHeight: .infinity)
        precondition(invalid.size == CGSize(width: 1_000, height: 440))
        let invalidViewport = FinderPreviewGeometry(available: .init(width: CGFloat.nan, height: CGFloat.infinity), requestedHeight: savedHeight)
        precondition(invalidViewport.size == .zero)
        print("PASS preview adaptation: width always fills the pane, shrinking/growing windows retain preferred height, tiny panes stay bounded, invalid heights recover")

        // One layout for every drive and both placements: metadata and actions are in the header's information
        // popover, so the media area is the pane minus the height grip.
        let shortWide = FinderPreviewGeometry(available: .init(width: 1_000, height: 300), requestedHeight: 440)
        precondition(shortWide.size == CGSize(width: 1_000, height: 286))
        precondition(shortWide.size.height + shortWide.verticalHandle == 300)
        precondition(shortWide.resizedHeight(from: shortWide.size.height, translation: .init(width: 500, height: -80)) == 206)
        let tiny = FinderPreviewGeometry(available: .init(width: 600, height: 80), requestedHeight: 440)
        precondition(tiny.size == CGSize(width: 600, height: 66) && tiny.verticalHandle == 14)
        print("PASS preview layout: details in the popover for every drive, media reclaims the height, full width and height drag remain, short panes stay bounded")
    }
}

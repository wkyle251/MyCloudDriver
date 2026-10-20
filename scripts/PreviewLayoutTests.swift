import AppKit
import SwiftUI

private final class LayoutPaneHandles {
    var files: NSScrollView?
    var preview: NSView?
}
private final class FlippedLayoutDocument: NSView {
    override var isFlipped: Bool { true }
}
private struct LayoutFilesProbe: NSViewRepresentable {
    let handles: LayoutPaneHandles
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.documentView = FlippedLayoutDocument(frame: .init(x: 0, y: 0, width: 1_000, height: 3_000))
        scroll.hasVerticalScroller = true
        handles.files = scroll
        return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) {}
}
private struct LayoutPreviewProbe: NSViewRepresentable {
    let handles: LayoutPaneHandles
    func makeNSView(context: Context) -> NSView {
        let view = NSView(); handles.preview = view; return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
}

@main @MainActor struct PreviewLayoutTests {
    static func placementSettings(_ defaults: UserDefaults) {
        for placement in FinderPreviewPlacement.allCases {
            let settings = FinderSettings(defaults: defaults)
            settings.previewPlacement = placement
            let restored = FinderSettings(defaults: defaults)
            precondition(restored.previewPlacement == placement && restored.previewLayout == placement.layout)
            settings.previewLayout = placement.layout == .sideBySide ? .topAndBottom : .sideBySide
            precondition(settings.previewPlacement.previewFirst == placement.previewFirst,
                "Changing orientation preserves whether the preview or file browser is first")
            precondition(FinderSettings(defaults: defaults).previewPlacement == settings.previewPlacement)
        }
        for legacy in ["right", "bottom"] {
            defaults.set(legacy, forKey: "finderPreviewPlacement")
            precondition(FinderSettings(defaults: defaults).previewPlacement.rawValue == legacy,
                "Existing Right and Bottom preferences keep their layout")
        }
        let settings = FinderSettings(defaults: defaults)
        settings.previewPlacement = .top
        settings.resetLayout()
        precondition(settings.previewPlacement == .right && settings.previewLayout == .sideBySide)
        defaults.set("invalid", forKey: "finderPreviewPlacement")
        precondition(FinderSettings(defaults: defaults).previewPlacement == .right)
        print("PASS placement preferences: four positions persist, orientation preserves pane order, legacy layouts remain and Reset Layout restores Right")
    }

    static func splitGeometry() {
        for placement in FinderPreviewPlacement.allCases {
            for viewport in [CGSize(width: 1_200, height: 900), .init(width: 240, height: 180), .zero] {
                for fraction in [-1.0, 0, 0.45, 0.64, 1, 2, .nan, .infinity] {
                    let layout = FinderBrowserSplitGeometry(viewport: viewport, placement: placement, fraction: fraction)
                    for frame in [layout.files, layout.divider, layout.preview] {
                        precondition(frame.width.isFinite && frame.height.isFinite && frame.width >= 0 && frame.height >= 0)
                        precondition(frame.minX >= 0 && frame.minY >= 0)
                        precondition(frame.maxX <= layout.contentSize.width + 0.001 && frame.maxY <= layout.contentSize.height + 0.001)
                    }
                    precondition(!layout.files.intersects(layout.preview))
                    precondition(layout.fileExtent >= layout.fileMinimum && layout.available - layout.fileExtent >= layout.previewMinimum - 0.001)
                    if layout.stacked {
                        precondition(layout.files.width == viewport.width && layout.preview.width == viewport.width)
                        precondition((layout.preview.minY < layout.files.minY) == placement.previewFirst)
                    } else {
                        precondition(layout.files.height == viewport.height && layout.preview.height == viewport.height)
                        precondition((layout.preview.minX < layout.files.minX) == placement.previewFirst)
                    }
                }
            }
            let layout = FinderBrowserSplitGeometry(viewport: .init(width: 1_200, height: 900), placement: placement, fraction: 0.55)
            let dragged = layout.resizedFileFraction(from: layout.fileExtent, translation: .init(width: 50, height: 50))
            precondition((dragged < layout.fileFraction) == placement.previewFirst,
                "Dragging right/down grows whichever pane precedes the divider")
            for delta in [-100_000.0, 100_000.0] {
                let fraction = layout.resizedFileFraction(from: layout.fileExtent, translation: .init(width: delta, height: delta))
                precondition(fraction >= Double(layout.fileMinimum / layout.available) - 0.000001 && fraction <= Double(1 - layout.previewMinimum / layout.available) + 0.000001)
            }
            precondition(layout.resizedFileFraction(from: layout.fileExtent, translation: .init(width: CGFloat.nan, height: CGFloat.nan)) == layout.fileFraction)
        }
        print("PASS split frames: all four orders, tiny windows, invalid preferences, nonoverlapping panes and divider direction/bounds")
    }

    static func hostedPaneIdentity(_ defaults: UserDefaults) async throws {
        _ = NSApplication.shared
        defaults.set("right", forKey: "finderPreviewPlacement")
        let handles = LayoutPaneHandles()
        let content = FinderBrowserSplit(showsPreview: true) {
            LayoutFilesProbe(handles: handles)
        } preview: { LayoutPreviewProbe(handles: handles) }
        let host = NSHostingView(rootView: content.defaultAppStorage(defaults))
        let window = NSWindow(contentRect: .init(x: -3_000, y: -3_000, width: 1_200, height: 900),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0.01; window.ignoresMouseEvents = true
        window.contentView = host; window.orderFrontRegardless()
        defer { window.close() }
        func correct(_ placement: FinderPreviewPlacement) -> Bool {
            host.layoutSubtreeIfNeeded()
            guard let files = handles.files, let preview = handles.preview else { return false }
            let f = files.convert(files.bounds, to: host), p = preview.convert(preview.bounds, to: host)
            if placement.layout == .sideBySide {
                return abs(p.minX - f.minX) > 1 && abs(p.minY - f.minY) < 1 &&
                    (p.minX < f.minX) == placement.previewFirst && f.width > 0 && p.width > 0
            }
            let previewAbove = host.isFlipped ? p.minY < f.minY : p.maxY > f.maxY
            return abs(p.minY - f.minY) > 1 && abs(p.minX - f.minX) < 1 &&
                previewAbove == placement.previewFirst && f.height > 0 && p.height > 0
        }
        for _ in 0..<100 where !correct(.right) { try await Task.sleep(nanoseconds: 20_000_000) }
        precondition(correct(.right))
        let files = handles.files!, preview = handles.preview!
        files.contentView.scroll(to: .init(x: 0, y: 350)); files.reflectScrolledClipView(files.contentView)
        let offset = files.contentView.bounds.origin.y
        for placement in [FinderPreviewPlacement.left, .top, .bottom, .right] {
            defaults.set(placement.rawValue, forKey: "finderPreviewPlacement")
            for _ in 0..<100 where !correct(placement) { try await Task.sleep(nanoseconds: 20_000_000) }
            precondition(correct(placement), "The hosted panes must physically occupy the chosen positions")
            precondition(handles.files === files && handles.preview === preview,
                "Swapping sides or orientation must keep the same native pane instances")
            precondition(abs(files.contentView.bounds.origin.y - offset) < 1,
                "Changing placement must preserve the file browser's scroll position")
        }
        print("PASS hosted split: real pane frames follow all four placements, native views stay mounted and the browser retains its scroll position")
    }

    static func maximizedMedia(_ defaults: UserDefaults) async throws {
        let handles = LayoutPaneHandles()
        let pane = FinderPreviewPane {
            Color.clear.frame(height: 30)
        } media: {
            LayoutPreviewProbe(handles: handles)
        } details: { Text("Generated file details") }
        let host = NSHostingView(rootView: pane.defaultAppStorage(defaults))
        let window = NSWindow(contentRect: .init(x: -3_000, y: -3_000, width: 500, height: 700),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.alphaValue = 0.01; window.ignoresMouseEvents = true
        window.contentView = host; window.orderFrontRegardless()
        defer { window.close() }
        var original: NSView?
        for placement in FinderPreviewPlacement.allCases {
            defaults.set(placement.rawValue, forKey: "finderPreviewPlacement")
            let inset: CGFloat = placement.layout == .topAndBottom ? 10 : 16
            for size in [CGSize(width: 300, height: 420), .init(width: 1_100, height: 900), .init(width: 600, height: 220)] {
                // The retired manual-size preference must never leave unused space.
                defaults.set(size.height > 500 ? 1.0 : 2_000.0, forKey: "previewCanvasHeight")
                window.setContentSize(size)
                func fillsPane() -> Bool {
                    host.layoutSubtreeIfNeeded()
                    guard let media = handles.preview else { return false }
                    let frame = media.convert(media.bounds, to: host)
                    let bottom = host.isFlipped ? host.bounds.maxY - frame.maxY : frame.minY - host.bounds.minY
                    return abs(frame.width - (host.bounds.width - 2 * inset)) < 1 &&
                        abs(bottom - inset) < 1 && frame.height > 0
                }
                for _ in 0..<100 where !fillsPane() { try await Task.sleep(nanoseconds: 20_000_000) }
                precondition(fillsPane(), "Media must fill the entire available pane below its header")
                if let original { precondition(handles.preview === original, "Growing the preview must not replace its media surface") }
                else { original = handles.preview }
            }
        }
        print("PASS maximized preview: media fills every placement and window size, ignores legacy manual heights and retains its native surface")
    }

    static func main() async throws {
        setbuf(stdout, nil)
        let suite = "PreviewLayoutTests-\(UUID())", defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        placementSettings(defaults)
        splitGeometry()
        try await hostedPaneIdentity(defaults)
        try await maximizedMedia(defaults)
    }
}

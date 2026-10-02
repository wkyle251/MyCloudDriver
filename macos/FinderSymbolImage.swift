import AppKit
import SwiftUI

/// Native menus and Settings tabs must not renegotiate a live SF Symbol's
/// optical size on hover, selection or an unrelated SwiftUI update. Cache
/// fixed-size templates with both standard and Retina bitmap representations.
@MainActor enum FinderSymbolImage {
    enum Style: Hashable {
        case menu, settingsTab
        var side: Int { self == .menu ? 16 : 24 }
        var pointSize: CGFloat { self == .menu ? 13 : 20 }
        var inset: CGFloat { self == .menu ? 1 : 2 }
    }
    private struct Key: Hashable {
        let name: String
        let style: Style
    }
    private static var images: [Key: NSImage] = [:]

    static func template(named name: String, style: Style) -> NSImage {
        let key = Key(name: name, style: style)
        if let cached = images[key] { return cached }
        let side = CGFloat(style.side)
        let canvas = NSSize(width: side, height: side)
        let result = NSImage(size: canvas)
        if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: style.pointSize, weight: .regular)) {
            for scale in [1, 2] {
                guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                    pixelsWide: style.side * scale, pixelsHigh: style.side * scale,
                    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                    let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = context
                context.cgContext.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
                let content = side - style.inset * 2
                let ratio = min(content / max(symbol.size.width, 1), content / max(symbol.size.height, 1))
                let size = NSSize(width: symbol.size.width * ratio, height: symbol.size.height * ratio)
                symbol.draw(in: NSRect(x: (side - size.width) / 2, y: (side - size.height) / 2,
                                      width: size.width, height: size.height),
                            from: .zero, operation: .sourceOver, fraction: 1)
                NSGraphicsContext.restoreGraphicsState()
                bitmap.size = canvas
                result.addRepresentation(bitmap)
            }
        }
        result.isTemplate = true
        result.accessibilityDescription = nil
        images[key] = result
        return result
    }

    static func settingsLabel(_ title: String, systemImage: String) -> Label<Text, Image> {
        Label { Text(verbatim: title) } icon: {
            Image(nsImage: template(named: systemImage, style: .settingsTab))
        }
    }
}
